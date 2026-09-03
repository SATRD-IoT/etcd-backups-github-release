#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Configuration
# =========================

# GitHub target repo and release tag
export GH_TOKEN="<github-personal-access-token>"
GITHUB_REPO="<github-repository-to-store-etcd-backups-in-releases>"
RELEASE_TAG="<release-tag>"

# How many backups to keep remotely
KEEP_REMOTE=7

# Local working directory
WORK_DIR="/data/etcd-backup"
TMP_DIR="${WORK_DIR}/tmp" #/tmp

# Snapshot naming
HOSTNAME_SHORT="$(hostname -s)"
TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
BASENAME="etcd-${HOSTNAME_SHORT}-${TS}"

# Output files
SNAPSHOT_DB="${TMP_DIR}/${BASENAME}.db"
# SNAPSHOT_TGZ="${TMP_DIR}/${BASENAME}.db.tar.gz"
SNAPSHOT_GZ="${SNAPSHOT_DB}.gz"
# CHECKSUM_FILE="${TMP_DIR}/${BASENAME}.db.tar.gz.sha256"
CHECKSUM_FILE="${TMP_DIR}/${BASENAME}.gz.sha256"
METADATA_FILE="${TMP_DIR}/${BASENAME}.metadata.txt"

# Optional encryption with age
# Set to "true" to enable encryption
ENABLE_AGE_ENCRYPTION="false"

# Public key generated with: age-keygen -o key.txt
# Public key looks like: age1...
AGE_RECIPIENT="<public-age-key-for-encryption>"

# If encryption enabled:
ENCRYPTED_FILE="${SNAPSHOT_TGZ}.age"
ENCRYPTED_CHECKSUM_FILE="${ENCRYPTED_FILE}.sha256"

# etcdctl access
export ETCDCTL_API=3
ETCD_ENDPOINT="https://127.0.0.1:2379"
ETCD_CACERT="/etc/kubernetes/pki/etcd/ca.crt"
ETCD_CERT="/etc/kubernetes/pki/etcd/server.crt"
ETCD_KEY="/etc/kubernetes/pki/etcd/server.key"

# =========================
# Helpers
# =========================

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# =========================
# Pre-flight checks
# =========================

need_cmd etcdctl
need_cmd tar
need_cmd gzip
need_cmd sha256sum
need_cmd gh
need_cmd jq

if [[ "${ENABLE_AGE_ENCRYPTION}" == "true" ]]; then
  need_cmd age
fi

mkdir -p "${TMP_DIR}"

# Verify gh auth works
gh auth status >/dev/null 2>&1 || {
  echo "ERROR: gh is not authenticated. Run: gh auth login" >&2
  exit 1
}

# =========================
# Ensure release exists
# =========================

ensure_release() {
  if ! gh release view "${RELEASE_TAG}" --repo "${GITHUB_REPO}" >/dev/null 2>&1; then
    log "Release ${RELEASE_TAG} does not exist. Creating it..."
    gh release create "${RELEASE_TAG}" \
      --repo "${GITHUB_REPO}" \
      --title "etcd backups" \
      --notes "Rolling etcd backup assets" \
      >/dev/null
  fi
}

# =========================
# Create snapshot
# =========================

create_snapshot() {
  log "Creating etcd snapshot: ${SNAPSHOT_DB}"

  etcdctl \
    --endpoints="${ETCD_ENDPOINT}" \
    --cacert="${ETCD_CACERT}" \
    --cert="${ETCD_CERT}" \
    --key="${ETCD_KEY}" \
    snapshot save "${SNAPSHOT_DB}"

  log "Verifying snapshot status"
  etcdutl snapshot status "${SNAPSHOT_DB}" -w table
}

# =========================
# Package and checksum
# =========================

package_snapshot() {
  log "Compressing snapshot"
  # tar -C "${TMP_DIR}" -czf "${SNAPSHOT_TGZ}" "$(basename "${SNAPSHOT_DB}")"
  gzip -9 "${SNAPSHOT_DB}"

  log "Creating checksum"
  # sha256sum "${SNAPSHOT_TGZ}" > "${CHECKSUM_FILE}"
  sha256sum "${SNAPSHOT_GZ}" > "${CHECKSUM_FILE}"

  log "Writing metadata"
  cat > "${METADATA_FILE}" <<EOF
timestamp_utc=${TS}
hostname=${HOSTNAME_SHORT}
github_repo=${GITHUB_REPO}
release_tag=${RELEASE_TAG}
etcd_endpoint=${ETCD_ENDPOINT}
snapshot_file=$(basename "${SNAPSHOT_GZ}")
checksum_file=$(basename "${CHECKSUM_FILE}")
EOF
}

# =========================
# Optional encryption
# =========================

encrypt_if_enabled() {
  if [[ "${ENABLE_AGE_ENCRYPTION}" == "true" ]]; then
    log "Encrypting backup with age"
    # age -r "${AGE_RECIPIENT}" -o "${ENCRYPTED_FILE}" "${SNAPSHOT_TGZ}"
    age -r "${AGE_RECIPIENT}" -o "${ENCRYPTED_FILE}" "${SNAPSHOT_GZ}"
    sha256sum "${ENCRYPTED_FILE}" > "${ENCRYPTED_CHECKSUM_FILE}"
  fi
}

# =========================
# Upload assets
# =========================

upload_assets() {
  log "Uploading assets to GitHub release ${RELEASE_TAG}"

  if [[ "${ENABLE_AGE_ENCRYPTION}" == "true" ]]; then
    gh release upload "${RELEASE_TAG}" \
      "${ENCRYPTED_FILE}" \
      "${ENCRYPTED_CHECKSUM_FILE}" \
      "${METADATA_FILE}" \
      --repo "${GITHUB_REPO}" \
      --clobber
  else
    gh release upload "${RELEASE_TAG}" \
      "${SNAPSHOT_GZ}" \
      "${CHECKSUM_FILE}" \
      "${METADATA_FILE}" \
      --repo "${GITHUB_REPO}" \
      --clobber
  fi
}

# =========================
# Prune old assets
# =========================

prune_old_assets() {
  log "Pruning old assets, keeping latest ${KEEP_REMOTE} backups"

  # We group assets by backup prefix, derived from metadata filenames:
  #   etcd-host-2026-03-12T02-00-00Z.metadata.txt
  #
  # Then we sort groups newest-first by the embedded timestamp in the basename.

  local assets_json
  assets_json="$(gh release view "${RELEASE_TAG}" \
    --repo "${GITHUB_REPO}" \
    --json assets \
    --jq '.assets[].name')"

  # Build unique backup groups from metadata files only
  mapfile -t groups < <(
    printf '%s\n' "${assets_json}" \
      | sed 's/^"//; s/"$//' \
      | grep '\.metadata\.txt$' \
      | sed 's/\.metadata\.txt$//' \
      | sort -r
  )

  local total_groups="${#groups[@]}"
  if (( total_groups <= KEEP_REMOTE )); then
    log "Nothing to prune (${total_groups} backup sets present)"
    return 0
  fi

  for (( i=KEEP_REMOTE; i<total_groups; i++ )); do
    local group="${groups[$i]}"
    log "Deleting old backup set: ${group}"

    # Delete matching assets for that group
    while IFS= read -r asset_name; do
      [[ -z "${asset_name}" ]] && continue
      gh release delete-asset "${RELEASE_TAG}" "${asset_name}" \
        --repo "${GITHUB_REPO}" \
        --yes
    done < <(
      printf '%s\n' "${assets_json}" \
        | sed 's/^"//; s/"$//' \
        | grep "^${group}\."
    )
  done
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