#!/usr/bin/env bash
set -euo pipefail

# Usage:
# ./download-etcd-backup-from-github-release.sh OWNER REPO TAG ASSET [OUTPUT]
#
# Example:
# ./download-etcd-backup-from-github-release.sh my-org my-repo my-cluster etcd-control-plane-node-2026-10-27T02-00-00Z.db.gz

OWNER="${1:?Missing repository owner}"
REPO="${2:?Missing repository name}"
TAG="${3:?Missing release tag}"
ASSET="${4:?Missing asset filename}"
OUTPUT="${5:-$ASSET}"

GH_TOKEN="${GH_TOKEN:?GH_TOKEN environment variable is required}"

API_URL="https://api.github.com/repos/${OWNER}/${REPO}"

# Temporary file for API response
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

echo "Fetching release information for ${OWNER}/${REPO} (${TAG})..."

# Retrieve release metadata
wget -q \
    --header="Authorization: Bearer ${GH_TOKEN}" \
    --header="Accept: application/vnd.github+json" \
    -O "$TMP_FILE" \
    "${API_URL}/releases/tags/${TAG}"

# Find asset ID
ASSET_ID=$(jq -r --arg name "$ASSET" \
    '.assets[] | select(.name == $name) | .id' "$TMP_FILE")

if [[ -z "$ASSET_ID" ]]; then
    echo "Error: Asset '${ASSET}' not found in release '${TAG}'." >&2
    exit 1
fi

echo "Found asset ID: ${ASSET_ID}"
echo "Downloading ${ASSET}..."

# Download asset
wget \
    --header="Authorization: Bearer ${GH_TOKEN}" \
    --header="Accept: application/octet-stream" \
    -O "$OUTPUT" \
    "${API_URL}/releases/assets/${ASSET_ID}"

echo "Download completed: ${OUTPUT}"