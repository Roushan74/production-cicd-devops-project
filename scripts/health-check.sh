#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Health check / smoke test for the Notes API.
#
# Works in two modes:
#   * on the EC2 host   -> scripts/health-check.sh --url http://127.0.0.1
#   * from CI or a laptop -> scripts/health-check.sh --url http://<public-ip>
#
# Verifies more than "port answers": it asserts the documented response
# contract of /health and, optionally, the expected version, and it exercises
# one real API read so a container that is up but broken is still caught.
#
# EXIT CODES
#   0  everything passed
#   1  a check failed
#   2  bad usage / missing dependency
# ---------------------------------------------------------------------------
set -Eeuo pipefail

BASE_URL=""
EXPECT_VERSION=""
RETRIES=10
INTERVAL=3
TIMEOUT=5
VERBOSE=0

usage() {
  cat <<'EOF'
Usage: health-check.sh --url <base-url> [options]

  --url <url>            Base URL, e.g. http://127.0.0.1 or http://1.2.3.4
  --expect-version <v>   Fail unless /health reports this exact version
  --retries <n>          Attempts before giving up (default 10)
  --interval <s>         Seconds between attempts (default 3)
  --timeout <s>          Per-request timeout (default 5)
  --verbose              Print the response bodies
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)            BASE_URL="${2:-}"; shift 2 ;;
    --expect-version) EXPECT_VERSION="${2:-}"; shift 2 ;;
    --retries)        RETRIES="${2:-}"; shift 2 ;;
    --interval)       INTERVAL="${2:-}"; shift 2 ;;
    --timeout)        TIMEOUT="${2:-}"; shift 2 ;;
    --verbose)        VERBOSE=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }
[[ -n "$BASE_URL" ]] || { echo "--url is required" >&2; usage; exit 2; }
BASE_URL="${BASE_URL%/}"

pass() { printf '  [PASS] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*" >&2; }

echo "Health check: ${BASE_URL}"

BODY=""
ATTEMPT=0
while (( ATTEMPT < RETRIES )); do
  ATTEMPT=$(( ATTEMPT + 1 ))
  if BODY="$(curl -fsS --max-time "$TIMEOUT" "${BASE_URL}/health" 2>/dev/null)"; then
    break
  fi
  printf '  ... attempt %d/%d not ready\n' "$ATTEMPT" "$RETRIES"
  BODY=""
  sleep "$INTERVAL"
done

if [[ -z "$BODY" ]]; then
  fail "/health did not return HTTP 200 after ${RETRIES} attempts"
  exit 1
fi

(( VERBOSE )) && echo "  body: ${BODY}"

# --- Contract assertions ----------------------------------------------------
failures=0

if grep -q '"status":"ok"' <<<"$BODY"; then
  pass 'status is "ok"'
else
  fail 'status is not "ok"'; failures=$(( failures + 1 ))
fi

if grep -q '"application":"' <<<"$BODY"; then
  pass 'application name present'
else
  fail 'application name missing'; failures=$(( failures + 1 ))
fi

if grep -qE '"version":"[0-9]+\.[0-9]+\.[0-9]+' <<<"$BODY"; then
  pass 'version is a semantic version'
else
  fail 'version missing or malformed'; failures=$(( failures + 1 ))
fi

if [[ -n "$EXPECT_VERSION" ]]; then
  if grep -q "\"version\":\"${EXPECT_VERSION}\"" <<<"$BODY"; then
    pass "version matches expected ${EXPECT_VERSION}"
  else
    fail "version does not match expected ${EXPECT_VERSION}"; failures=$(( failures + 1 ))
  fi
fi

# --- Functional smoke test --------------------------------------------------
NOTES="$(curl -fsS --max-time "$TIMEOUT" "${BASE_URL}/api/notes" 2>/dev/null || true)"
if grep -q '"data":\[' <<<"$NOTES"; then
  pass 'GET /api/notes returns a collection'
else
  fail 'GET /api/notes did not return the expected shape'; failures=$(( failures + 1 ))
fi

STATUS_404="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" \
  "${BASE_URL}/api/notes/3f1b2c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d" 2>/dev/null || echo 000)"
if [[ "$STATUS_404" == "404" ]]; then
  pass 'unknown note id returns 404'
else
  fail "unknown note id returned ${STATUS_404} (expected 404)"; failures=$(( failures + 1 ))
fi

echo
if (( failures > 0 )); then
  echo "RESULT: FAILED (${failures} check(s))"
  exit 1
fi
echo "RESULT: PASSED"
