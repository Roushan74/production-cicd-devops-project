#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Roll back the Notes API to the previously deployed image.
#
# The previous image reference is recorded by deploy.sh in
#   /opt/notes-api/state/previous_image
# and is guaranteed to still exist locally, because deploy.sh only prunes
# dangling layers and never deletes tagged images.
#
# Rollback reuses the exact same blue/green procedure as a forward deployment
# (candidate in the idle slot -> health check -> Nginx switch), so a rollback is
# itself verified before it takes traffic.
#
# USAGE
#   ./rollback.sh                 # roll back to the recorded previous image
#   ./rollback.sh --image <ref>   # roll back to a specific image
#   ./rollback.sh --dry-run       # show what would happen
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-/opt/notes-api/state}"
PREVIOUS_IMAGE_FILE="$STATE_DIR/previous_image"
ACTIVE_IMAGE_FILE="$STATE_DIR/active_image"

TARGET_IMAGE=""
DRY_RUN=0

log() { printf '[rollback] %s\n' "$*"; }
die() { printf '[rollback] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)   TARGET_IMAGE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "Unknown argument: $1" ;;
  esac
done

CURRENT="$(cat "$ACTIVE_IMAGE_FILE" 2>/dev/null || echo none)"

if [[ -z "$TARGET_IMAGE" ]]; then
  TARGET_IMAGE="$(cat "$PREVIOUS_IMAGE_FILE" 2>/dev/null || echo '')"
  [[ -n "$TARGET_IMAGE" ]] || die "No previous image recorded in ${PREVIOUS_IMAGE_FILE}. Use --image <ref>."
fi

log "Current image : ${CURRENT}"
log "Rollback to   : ${TARGET_IMAGE}"

if ! docker image inspect "$TARGET_IMAGE" >/dev/null 2>&1; then
  log "Image not present locally - it will be pulled."
  PULL_FLAG=""
else
  log "Image is present locally."
  PULL_FLAG="--no-pull"
fi

if (( DRY_RUN )); then
  log "Dry run: would execute deploy.sh --image ${TARGET_IMAGE} ${PULL_FLAG}"
  exit 0
fi

# Reuse the audited deployment path: pull (if needed) -> candidate slot ->
# health check -> Nginx switch -> verify -> retire old container.
exec "$SCRIPT_DIR/deploy.sh" --image "$TARGET_IMAGE" ${PULL_FLAG}
