#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Blue/green deployment for the Notes API on a single EC2 instance.
#
# WHAT IT DOES
#   1. Pulls the requested immutable image tag.
#   2. Starts it in the INACTIVE slot (blue :3000 / green :3001) - production
#      traffic is untouched while this happens.
#   3. Waits for the candidate's /health to report ready and, optionally, the
#      expected version.
#   4. Rewrites the Nginx upstream file to point at the new slot and reloads
#      Nginx gracefully (in-flight requests drain on the old workers).
#   5. Verifies the public path through Nginx.
#   6. Only then stops the old container. The previous image is recorded so
#      rollback.sh can restore it.
#
#   Any failure before step 4 leaves production untouched. A failure at step 5
#   automatically reverts the upstream file.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   - It never deletes tagged images, so the last known-good version is always
#     available locally for a rollback.
#   - It never runs `docker system prune`, never touches unrelated containers,
#     and never removes volumes.
#
# USAGE
#   ./deploy.sh --image <registry>/<repo>:<tag> [--expect-version 1.0.0]
#                [--timeout 90] [--no-pull]
#
# All paths/ports can be overridden with environment variables, which is how
# this script is exercised locally against a containerised Nginx.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

# --- Configuration (overridable) -------------------------------------------
STATE_DIR="${STATE_DIR:-/opt/notes-api/state}"
UPSTREAM_FILE="${UPSTREAM_FILE:-/etc/nginx/notes-upstream.conf}"
NGINX_TEST_CMD="${NGINX_TEST_CMD:-nginx -t}"
NGINX_RELOAD_CMD="${NGINX_RELOAD_CMD:-nginx -s reload}"
APP_BIND_HOST="${APP_BIND_HOST:-127.0.0.1}"
UPSTREAM_HOST="${UPSTREAM_HOST:-127.0.0.1}"
BLUE_PORT="${BLUE_PORT:-3000}"
GREEN_PORT="${GREEN_PORT:-3001}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-notes-api}"
PUBLIC_HEALTH_URL="${PUBLIC_HEALTH_URL:-http://127.0.0.1/health}"
APP_CONTAINER_PORT="${APP_CONTAINER_PORT:-3000}"

IMAGE=""
EXPECT_VERSION=""
TIMEOUT=90
DO_PULL=1

log()  { printf '[deploy] %s\n' "$*"; }
warn() { printf '[deploy] WARNING: %s\n' "$*" >&2; }
die()  { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- Argument parsing -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)          IMAGE="${2:-}"; shift 2 ;;
    --expect-version) EXPECT_VERSION="${2:-}"; shift 2 ;;
    --timeout)        TIMEOUT="${2:-}"; shift 2 ;;
    --no-pull)        DO_PULL=0; shift ;;
    -h|--help)        usage 0 ;;
    *)                die "Unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$IMAGE" ]] || die "--image is required"
[[ "$IMAGE" == *:* ]] || die "--image must include an explicit tag, e.g. repo:sha (refusing to deploy 'latest' implicitly)"
command -v docker >/dev/null || die "docker is not installed"
command -v curl   >/dev/null || die "curl is not installed"

# --- Helpers ----------------------------------------------------------------
container_name() { echo "${CONTAINER_PREFIX}-$1"; }
slot_port()      { [[ "$1" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT"; }

health_ok() {
  local port="$1" body
  body="$(curl -fsS --max-time 3 "http://127.0.0.1:${port}/health" 2>/dev/null)" || return 1
  grep -q '"status":"ok"' <<<"$body" || return 1
  if [[ -n "$EXPECT_VERSION" ]]; then
    grep -q "\"version\":\"${EXPECT_VERSION}\"" <<<"$body" || return 1
  fi
  return 0
}

wait_for_health() {
  local port="$1" deadline=$(( SECONDS + TIMEOUT ))
  while (( SECONDS < deadline )); do
    if health_ok "$port"; then return 0; fi
    sleep 2
  done
  return 1
}

write_upstream() {
  local port="$1"
  cat >"$UPSTREAM_FILE" <<EOF
# Managed by scripts/deploy.sh - do not edit by hand.
# Active slot port: ${port}
upstream notes_api {
    server ${UPSTREAM_HOST}:${port} max_fails=3 fail_timeout=10s;
    keepalive 16;
}
EOF
}

# --- State ------------------------------------------------------------------
mkdir -p "$STATE_DIR"
ACTIVE_SLOT_FILE="$STATE_DIR/active_slot"
ACTIVE_IMAGE_FILE="$STATE_DIR/active_image"
PREVIOUS_IMAGE_FILE="$STATE_DIR/previous_image"

ACTIVE_SLOT="$(cat "$ACTIVE_SLOT_FILE" 2>/dev/null || echo none)"
ACTIVE_IMAGE="$(cat "$ACTIVE_IMAGE_FILE" 2>/dev/null || echo none)"

if [[ "$ACTIVE_SLOT" == "blue" ]]; then TARGET_SLOT="green"; else TARGET_SLOT="blue"; fi
TARGET_PORT="$(slot_port "$TARGET_SLOT")"
TARGET_NAME="$(container_name "$TARGET_SLOT")"
OLD_PORT="$( [[ "$ACTIVE_SLOT" == "none" ]] && echo "$GREEN_PORT" || slot_port "$ACTIVE_SLOT" )"
OLD_NAME="$(container_name "$ACTIVE_SLOT")"

log "Active slot : ${ACTIVE_SLOT} (${ACTIVE_IMAGE})"
log "Target slot : ${TARGET_SLOT} (port ${TARGET_PORT})"
log "Image       : ${IMAGE}"

# --- 1. Pull ----------------------------------------------------------------
if (( DO_PULL )); then
  log "Pulling image (3 attempts)..."
  for attempt in 1 2 3; do
    if docker pull "$IMAGE" >/dev/null; then break; fi
    warn "pull attempt ${attempt} failed"
    (( attempt == 3 )) && die "Could not pull ${IMAGE}"
    sleep 5
  done
fi

IMAGE_DIGEST="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null | cut -d@ -f2 || true)"
log "Digest      : ${IMAGE_DIGEST:-<none: locally built image>}"

# --- 2. Start candidate in the inactive slot -------------------------------
log "Removing any stale container ${TARGET_NAME}..."
docker rm -f "$TARGET_NAME" >/dev/null 2>&1 || true

log "Starting candidate ${TARGET_NAME} on ${APP_BIND_HOST}:${TARGET_PORT}..."
docker run -d \
  --name "$TARGET_NAME" \
  --restart unless-stopped \
  -p "${APP_BIND_HOST}:${TARGET_PORT}:${APP_CONTAINER_PORT}" \
  --read-only \
  --tmpfs /tmp \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --memory 256m \
  --log-driver json-file \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  "$IMAGE" >/dev/null

CANDIDATE_STARTED=1
SWITCHED=0

cleanup_on_error() {
  local exit_code=$?
  if (( exit_code != 0 )); then
    warn "Deployment failed (exit ${exit_code})."
    if (( CANDIDATE_STARTED )); then
      warn "Removing failed candidate ${TARGET_NAME}"
      docker rm -f "$TARGET_NAME" >/dev/null 2>&1 || true
    fi
    if (( SWITCHED )); then
      warn "Reverting Nginx upstream to the previous slot (:${OLD_PORT})"
      write_upstream "$OLD_PORT"
      $NGINX_TEST_CMD >/dev/null 2>&1 && $NGINX_RELOAD_CMD >/dev/null 2>&1 || warn "Nginx revert failed - manual action required"
    fi
    warn "Production traffic was NOT moved to the new version."
  fi
}
trap cleanup_on_error EXIT

# --- 3. Wait for the candidate to be healthy -------------------------------
log "Waiting up to ${TIMEOUT}s for /health on port ${TARGET_PORT}..."
if ! wait_for_health "$TARGET_PORT"; then
  warn "Candidate health check failed. Last logs:"
  docker logs --tail 40 "$TARGET_NAME" 2>&1 | sed 's/^/    /' >&2 || true
  die "Candidate did not become healthy"
fi
log "Candidate is healthy: $(curl -fsS "http://127.0.0.1:${TARGET_PORT}/health")"

# --- 4. Switch traffic ------------------------------------------------------
log "Pointing Nginx upstream at ${TARGET_PORT}..."
write_upstream "$TARGET_PORT"
$NGINX_TEST_CMD >/dev/null || die "nginx -t rejected the new upstream configuration"
$NGINX_RELOAD_CMD >/dev/null || die "nginx reload failed"
SWITCHED=1
log "Nginx reloaded gracefully"

# --- 5. Verify through the proxy -------------------------------------------
log "Verifying public path ${PUBLIC_HEALTH_URL}..."
PROXY_OK=0
for _ in 1 2 3 4 5; do
  if curl -fsS --max-time 5 "$PUBLIC_HEALTH_URL" 2>/dev/null | grep -q '"status":"ok"'; then
    PROXY_OK=1; break
  fi
  sleep 2
done
(( PROXY_OK )) || die "Health check through Nginx failed after switching traffic"

# --- 6. Commit state --------------------------------------------------------
log "Recording deployment state..."
[[ "$ACTIVE_IMAGE" != "none" ]] && echo "$ACTIVE_IMAGE" >"$PREVIOUS_IMAGE_FILE"
echo "$IMAGE"         >"$ACTIVE_IMAGE_FILE"
echo "$TARGET_SLOT"   >"$ACTIVE_SLOT_FILE"
printf 'deployed_at=%s\nimage=%s\ndigest=%s\nslot=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$IMAGE" "${IMAGE_DIGEST:-unknown}" "$TARGET_SLOT" \
  >"$STATE_DIR/last_deploy.env"

# --- 7. Retire the old container -------------------------------------------
if [[ "$ACTIVE_SLOT" != "none" ]] && docker ps -a --format '{{.Names}}' | grep -qx "$OLD_NAME"; then
  log "Stopping previous container ${OLD_NAME}..."
  docker stop "$OLD_NAME" >/dev/null 2>&1 || warn "could not stop ${OLD_NAME}"
  docker rm   "$OLD_NAME" >/dev/null 2>&1 || warn "could not remove ${OLD_NAME}"
fi

# Dangling layers only - tagged images are kept for rollback.
docker image prune -f >/dev/null 2>&1 || true

trap - EXIT
log "SUCCESS: ${IMAGE} is live in slot ${TARGET_SLOT} (port ${TARGET_PORT})"
log "Previous image retained for rollback: $(cat "$PREVIOUS_IMAGE_FILE" 2>/dev/null || echo none)"
