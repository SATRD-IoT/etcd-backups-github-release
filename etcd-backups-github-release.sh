#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

# =========================
# Configuration
# =========================

# Required:
#   GH_TOKEN must be exported in the environment or gh must already be authenticated.
#
# Optional environment overrides:
#   GITHUB_REPO, RELEASE_TAG, KEEP_REMOTE, WORK_DIR, LOCK_FILE, DRY_RUN
#   ENABLE_AGE_ENCRYPTION, AGE_RECIPIENT
#   ETCD_ENDPOINT, ETCD_CACERT, ETCD_CERT, ETCD_KEY

GITHUB_REPO="${GITHUB_REPO:-your-github-repo/clusters-backups}"
RELEASE_TAG="${RELEASE_TAG:-your-cluster}"
KEEP_REMOTE="${KEEP_REMOTE:-7}"
WORK_DIR="${WORK_DIR:-/data/etcd-backup}"
LOCK_FILE="${LOCK_FILE:-/var/lock/etcd-github-backup.lock}"
DRY_RUN="${DRY_RUN:-false}"

ENABLE_AGE_ENCRYPTION="${ENABLE_AGE_ENCRYPTION:-false}"
# Public key generated with: age-keygen -o key.txt
AGE_RECIPIENT="${AGE_RECIPIENT:-}"

export ETCDCTL_API=3
ETCD_ENDPOINT="${ETCD_ENDPOINT:-https://127.0.0.1:2379}"
ETCD_CACERT="${ETCD_CACERT:-/etc/kubernetes/pki/etcd/ca.crt}"
ETCD_CERT="${ETCD_CERT:-/etc/kubernetes/pki/etcd/server.crt}"
ETCD_KEY="${ETCD_KEY:-/etc/kubernetes/pki/etcd/server.key}"

# =========================
# Helpers
# =========================

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_true() {
  [[ "${1,,}" == "true" || "${1}" == "1" || "${1,,}" == "yes" ]]
}

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" && "${TMP_DIR}" == "${WORK_DIR}"/tmp.* ]]; then
    rm -rf -- "${TMP_DIR}"
  fi
}
trap cleanup EXIT

run_github_write() {
  if is_true "${DRY_RUN}"; then
    log "DRY_RUN: $*"
    return 0
  fi

  "$@"
}

# =========================
# Pre-flight checks
# =========================

need_cmd etcdctl
need_cmd etcdutl
need_cmd flock
need_cmd gzip
need_cmd sha256sum
need_cmd tee
need_cmd gh

if is_true "${ENABLE_AGE_ENCRYPTION}"; then
  need_cmd age
  [[ -n "${AGE_RECIPIENT}" ]] || die "AGE_RECIPIENT must be set when ENABLE_AGE_ENCRYPTION=true"
  [[ "${AGE_RECIPIENT}" == age1* ]] || die "AGE_RECIPIENT must be an age public recipient that starts with age1"
fi

[[ "${KEEP_REMOTE}" =~ ^[0-9]+$ ]] || die "KEEP_REMOTE must be a non-negative integer"
(( KEEP_REMOTE > 0 )) || die "KEEP_REMOTE must be greater than 0"

mkdir -p -- "${WORK_DIR}"
if [[ -n "${GH_CONFIG_DIR:-}" ]]; then
  mkdir -p -- "${GH_CONFIG_DIR}"
fi
if [[ "${LOCK_FILE}" == */* ]]; then
  mkdir -p -- "${LOCK_FILE%/*}"
fi
exec 9>"${LOCK_FILE}"
flock -n 9 || die "backup already running; lock is held at ${LOCK_FILE}"

TMP_DIR="$(mktemp -d "${WORK_DIR}/tmp.XXXXXXXXXX")"
HOSTNAME_SHORT="$(hostname -s)"
TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
BASENAME="etcd-${HOSTNAME_SHORT}-${TS}"

SNAPSHOT_DB="${TMP_DIR}/${BASENAME}.db"
SNAPSHOT_GZ="${SNAPSHOT_DB}.gz"
CHECKSUM_FILE="${TMP_DIR}/${BASENAME}.db.gz.sha256"
METADATA_FILE="${TMP_DIR}/${BASENAME}.metadata.txt"
SNAPSHOT_STATUS_FILE="${TMP_DIR}/${BASENAME}.snapshot-status.txt"
ENCRYPTED_FILE="${SNAPSHOT_GZ}.age"
ENCRYPTED_CHECKSUM_FILE="${ENCRYPTED_FILE}.sha256"

if [[ -n "${GH_TOKEN:-}" ]]; then
  export GH_TOKEN
fi

gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Export GH_TOKEN or run: gh auth login"

# =========================
# Ensure release exists
# =========================

ensure_release() {
  if ! gh release view "${RELEASE_TAG}" --repo "${GITHUB_REPO}" >/dev/null 2>&1; then
    log "Release ${RELEASE_TAG} does not exist. Creating it..."
    run_github_write gh release create "${RELEASE_TAG}" \
      --repo "${GITHUB_REPO}" \
      --title "${RELEASE_TAG}" \
      --notes "Rolling etcd backup assets" \
      >/dev/null
  fi
}

# =========================
# Create snapshot
# =========================

create_snapshot() {
  log "Checking etcd endpoint health"
  etcdctl \
    --endpoints="${ETCD_ENDPOINT}" \
    --cacert="${ETCD_CACERT}" \
    --cert="${ETCD_CERT}" \
    --key="${ETCD_KEY}" \
    endpoint health

  log "Creating etcd snapshot: ${SNAPSHOT_DB}"
  etcdctl \
    --endpoints="${ETCD_ENDPOINT}" \
    --cacert="${ETCD_CACERT}" \
    --cert="${ETCD_CERT}" \
    --key="${ETCD_KEY}" \
    snapshot save "${SNAPSHOT_DB}"

  log "Verifying snapshot status"
  etcdutl snapshot status "${SNAPSHOT_DB}" -w table | tee "${SNAPSHOT_STATUS_FILE}"
}

# =========================
# Package and checksum
# =========================

write_checksum() {
  local file_path="$1"
  local checksum_path="$2"

  (
    cd "${TMP_DIR}"
    sha256sum "$(basename "${file_path}")" > "$(basename "${checksum_path}")"
  )
}

package_snapshot() {
  local encrypted="false"

  if is_true "${ENABLE_AGE_ENCRYPTION}"; then
    encrypted="true"
  fi

  log "Compressing snapshot"
  gzip -9 "${SNAPSHOT_DB}"

  log "Creating checksum"
  write_checksum "${SNAPSHOT_GZ}" "${CHECKSUM_FILE}"

  log "Writing metadata"
  cat > "${METADATA_FILE}" <<EOF
timestamp_utc=${TS}
hostname=${HOSTNAME_SHORT}
github_repo=${GITHUB_REPO}
release_tag=${RELEASE_TAG}
etcd_endpoint=${ETCD_ENDPOINT}
snapshot_file=$(basename "${SNAPSHOT_GZ}")
checksum_file=$(basename "${CHECKSUM_FILE}")
encrypted=${encrypted}
snapshot_status_file=$(basename "${SNAPSHOT_STATUS_FILE}")
EOF
}

# =========================
# Optional encryption
# =========================

encrypt_if_enabled() {
  if is_true "${ENABLE_AGE_ENCRYPTION}"; then
    log "Encrypting backup with age"
    age -r "${AGE_RECIPIENT}" -o "${ENCRYPTED_FILE}" "${SNAPSHOT_GZ}"
    write_checksum "${ENCRYPTED_FILE}" "${ENCRYPTED_CHECKSUM_FILE}"

    cat >> "${METADATA_FILE}" <<EOF
encrypted_file=$(basename "${ENCRYPTED_FILE}")
encrypted_checksum_file=$(basename "${ENCRYPTED_CHECKSUM_FILE}")
EOF
  fi
}

# =========================
# Upload assets
# =========================

upload_assets() {
  log "Uploading assets to GitHub release ${RELEASE_TAG}"

  if is_true "${ENABLE_AGE_ENCRYPTION}"; then
    run_github_write gh release upload "${RELEASE_TAG}" \
      "${ENCRYPTED_FILE}" \
      "${ENCRYPTED_CHECKSUM_FILE}" \
      "${METADATA_FILE}" \
      "${SNAPSHOT_STATUS_FILE}" \
      --repo "${GITHUB_REPO}" \
      --clobber
  else
    run_github_write gh release upload "${RELEASE_TAG}" \
      "${SNAPSHOT_GZ}" \
      "${CHECKSUM_FILE}" \
      "${METADATA_FILE}" \
      "${SNAPSHOT_STATUS_FILE}" \
      --repo "${GITHUB_REPO}" \
      --clobber
  fi
}

# =========================
# Prune old assets
# =========================

metadata_to_group_record() {
  local name="$1"
  local group timestamp host

  [[ "${name}" == *.metadata.txt ]] || return 0

  group="${name%.metadata.txt}"
  if [[ "${group}" =~ ^etcd-(.*)-([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z)$ ]]; then
    host="${BASH_REMATCH[1]}"
    timestamp="${BASH_REMATCH[2]}"
    printf '%s\t%s\t%s\n' "${host}" "${timestamp}" "${group}"
  fi
}

prune_old_assets() {
  log "Pruning old assets, keeping latest ${KEEP_REMOTE} backup sets per cluster"

  local asset_output
  if ! asset_output="$(gh release view "${RELEASE_TAG}" \
    --repo "${GITHUB_REPO}" \
    --json assets \
    --jq '.assets[].name')"; then
    if is_true "${DRY_RUN}"; then
      log "DRY_RUN: release assets are unavailable; skipping prune"
      return 0
    fi

    die "failed to list release assets for ${RELEASE_TAG}"
  fi

  local assets
  mapfile -t assets <<< "${asset_output}"

  local records
  records="$(
    for asset_name in "${assets[@]}"; do
      metadata_to_group_record "${asset_name}"
    done | sort -t $'\t' -k1,1 -k2,2r
  )"

  [[ -n "${records}" ]] || {
    log "No backup metadata assets found"
    return 0
  }

  declare -A seen_by_host=()
  local host timestamp group count asset_name deleted_any=false

  while IFS=$'\t' read -r host timestamp group; do
    [[ -n "${host}" && -n "${timestamp}" && -n "${group}" ]] || continue

    count="${seen_by_host[${host}]:-0}"
    count=$((count + 1))
    seen_by_host["${host}"]="${count}"

    if (( count <= KEEP_REMOTE )); then
      continue
    fi

    deleted_any=true
    log "Deleting old backup set for ${host}: ${group}"
    for asset_name in "${assets[@]}"; do
      if [[ "${asset_name}" == "${group}".* ]]; then
        run_github_write gh release delete-asset "${RELEASE_TAG}" "${asset_name}" \
          --repo "${GITHUB_REPO}" \
          --yes
      fi
    done
  done <<< "${records}"

  if [[ "${deleted_any}" == "false" ]]; then
    log "Nothing to prune"
  fi
}

# =========================
# Main
# =========================

main() {
  ensure_release
  create_snapshot
  package_snapshot
  encrypt_if_enabled
  upload_assets
  prune_old_assets
  log "Done"
}

main "$@"
