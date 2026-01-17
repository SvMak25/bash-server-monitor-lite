#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${ROOT}/.tmp.test.XXXXXX")"
TEST_HOME="${TMP_DIR}/home"
mkdir -p "$TEST_HOME"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cp "${ROOT}/monitor.sh" "${TMP_DIR}/monitor.sh"
chmod +x "${TMP_DIR}/monitor.sh"

export PATH="${ROOT}/tests/mocks:${PATH}"

echo "[test] run without .env"
ENABLE_HTTP_MONITOR=0 \
ENABLE_HOST_MONITOR=0 \
ENABLE_DOCKER_MONITOR=0 \
STATE_FILE="${TMP_DIR}/state.json" \
LOG_FILE="${TMP_DIR}/monitor.log" \
LOCK_FILE="${TMP_DIR}/monitor.lock" \
HOME="${TEST_HOME}" \
bash "${TMP_DIR}/monitor.sh" >/dev/null

test -f "${TMP_DIR}/monitor.log"

echo "[test] http down marks state"
ENABLE_HTTP_MONITOR=1 \
ENABLE_HOST_MONITOR=0 \
ENABLE_DOCKER_MONITOR=0 \
HTTP_FAIL_THRESHOLD=1 \
URL="http://example.com/" \
MOCK_HTTP_CODE=500 \
MOCK_HTTP_TIME=0.1 \
STATE_FILE="${TMP_DIR}/state2.json" \
LOG_FILE="${TMP_DIR}/monitor2.log" \
LOCK_FILE="${TMP_DIR}/monitor2.lock" \
HOME="${TEST_HOME}" \
bash "${TMP_DIR}/monitor.sh" >/dev/null

jq -e '.http.down == true' "${TMP_DIR}/state2.json" >/dev/null

echo "[test] OK"
