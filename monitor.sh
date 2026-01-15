#!/usr/bin/env bash
set -Eeuo pipefail

early_error() {
  echo "$(date '+%F %T') [FATAL][EARLY] line=$2 cmd='$3' exit=$1" >&2
  exit "$1"
}
trap 'early_error $? $LINENO "$BASH_COMMAND"' ERR

# ============================================================
# LOAD ENV
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FATAL: .env not found: $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# ============================================================
# DEFAULTS
# ============================================================
: "${PREFIX:="[monitor]"}"

: "${STATE_FILE:=$HOME/.local/state/monitor/state.json}"
: "${LOG_FILE:=$HOME/.local/state/monitor/monitor.log}"
: "${LOCK_FILE:=$HOME/.local/state/monitor/monitor.lock}"

: "${ENABLE_HTTP_MONITOR:=1}"
: "${ENABLE_HOST_MONITOR:=1}"
: "${ENABLE_DOCKER_MONITOR:=0}"

: "${HTTP_TIMEOUT:=5}"
: "${HTTP_FAIL_THRESHOLD:=3}"
: "${HTTP_OK_MIN:=200}"
: "${HTTP_OK_MAX:=399}"   # 2xx + 3xx (редиректы НЕ ошибка)

: "${CPU_WARN:=90}"
: "${MEM_WARN:=90}"
: "${DISK_WARN:=80}"
: "${SWAP_WARN:=60}"

: "${CONTAINERS:=}"

# ============================================================
# VALIDATION
# ============================================================
: "${TG_TOKEN:?TG_TOKEN is required}"
: "${TG_CHAT:?TG_CHAT is required}"

if [[ "${ENABLE_HTTP_MONITOR:-0}" -eq 1 ]]; then
  : "${URL:?URL is required when ENABLE_HTTP_MONITOR=1}"
fi

# ============================================================
# REQUIREMENTS
# ============================================================
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: $1 is required" >&2; exit 1; }; }
require_cmd jq
require_cmd curl
require_cmd flock
require_cmd awk
require_cmd df
require_cmd sed

# ============================================================
# PREPARE DIRS
# ============================================================
mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG_FILE")"

# ============================================================
# LOGGING
# ============================================================
log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$LOG_FILE"
}

on_error() {
  trap - ERR
  log FATAL "$(hostname):$0:$2 cmd='$3' exit=$1" || true
  echo "[FATAL] line=$2 cmd='$3' exit=$1" >&2
  exit "$1"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ============================================================
# LOG ROTATION (simple)
# ============================================================
LOG_MAX_SIZE=$((512 * 1024))   # 512 KB
LOG_KEEP_LINES=2000

rotate_log_if_needed() {
  [[ -f "$LOG_FILE" ]] || return 0

  local size
  size=$(wc -c <"$LOG_FILE" || echo 0)

  if [[ "$size" -gt "$LOG_MAX_SIZE" ]]; then
    tail -n "$LOG_KEEP_LINES" "$LOG_FILE" >"${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    log INFO "Log rotated (kept last ${LOG_KEEP_LINES} lines)"
  fi
}

# ============================================================
# STATE
# ============================================================
init_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    jq -n '{
      http: { down: false, fail_count: 0 },
      host: {
        cpu:  { alert: false, last: 0 },
        ram:  { alert: false, last: 0 },
        disk: { alert: false, last: 0 },
        swap: { alert: false, last: 0 }
      },
      containers: {}
    }' >"$STATE_FILE"
    log INFO "State file created"
  fi
}

state_get() {
  # важно: false НЕ должен превращаться в empty
  jq -r "$1 | if . == null then empty else . end" "$STATE_FILE"
}

state_apply() {
  local filter="$1"
  local tmp
  tmp="$(mktemp "$(dirname "$STATE_FILE")/state.tmp.XXXXXX")"
  jq "$filter" "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
}

send_msg() {
  curl -sS -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="${TG_CHAT}" \
    --data-urlencode text="${PREFIX} $1" >/dev/null || log ERROR "Failed to send Telegram message"
}

# ============================================================
# METRICS
# ============================================================
cpu_usage_pct() {
  # delta over short interval (иначе будет "среднее с момента загрузки")
  local -i idle1 total1 idle2 total2
  local cpu user nice system idle iowait irq softirq steal

  read -r cpu user nice system idle iowait irq softirq steal _ < /proc/stat
  total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
  idle1=$((idle + iowait))

  sleep 0.2

  read -r cpu user nice system idle iowait irq softirq steal _ < /proc/stat
  total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
  idle2=$((idle + iowait))

  local -i dt=$((total2 - total1))
  local -i di=$((idle2 - idle1))

  if (( dt <= 0 )); then
    echo 0
  else
    echo $(( (dt - di) * 100 / dt ))
  fi
}

ram_usage_pct() {
  local total avail
  total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
  echo $(( (total - avail) * 100 / total ))
}

swap_usage_pct() {
  local total free
  total=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
  free=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
  (( total == 0 )) && echo 0 || echo $(( (total - free) * 100 / total ))
}

disk_usage_pct() {
  df -P / | awk 'NR==2 {gsub("%","",$5); print $5}'
}

# ============================================================
# HTTP CHECK
# ============================================================
http_check() {
  [[ "$ENABLE_HTTP_MONITOR" -eq 1 ]] || return 0

  local CODE TIME code_int
  read -r CODE TIME <<<"$(curl -sS -o /dev/null -w "%{http_code} %{time_total}" \
    --max-time "$HTTP_TIMEOUT" "$URL" || echo "000 0")"

  # форматируем время до 1 знака после точки
  if ! printf -v TIME_FMT "%.1f" "${TIME:-0}" 2>/dev/null; then
    TIME_FMT="${TIME:-0}"
  fi
  
  # безопасное приведение к десятичному int
  code_int=$((10#${CODE:-0}))

  local FAILS DOWN
  FAILS="$(state_get '.http.fail_count')"; FAILS="${FAILS:-0}"
  DOWN="$(state_get '.http.down')";       DOWN="${DOWN:-false}"

  if (( code_int < HTTP_OK_MIN || code_int > HTTP_OK_MAX )); then
    FAILS=$((FAILS + 1))
    state_apply ".http.fail_count = ${FAILS}"

    log WARN "HTTP check failed: code=${CODE}, fails=${FAILS}, threshold=${HTTP_FAIL_THRESHOLD}"

    if (( FAILS >= HTTP_FAIL_THRESHOLD )) && [[ "$DOWN" == "false" ]]; then
      state_apply ".http.down = true"
      log ERROR "HTTP DOWN confirmed (code=${CODE})"
      send_msg "❌ Сайт недоступен. HTTP ${CODE}. Ошибка ${FAILS}-й раз подряд"
    fi
    return 0
  fi

  # success (200..399): reset fails; recover if needed
  if (( FAILS != 0 )); then
    state_apply ".http.fail_count = 0"
  fi

  if [[ "$DOWN" == "true" ]]; then
    state_apply ".http.down = false"
    log INFO "HTTP recovered, time=${TIME_FMT}s, code=${CODE}"
    send_msg "✅ Сайт восстановился. Код: ${CODE}. Время ответа: ${TIME_FMT} сек"
  fi
}

# ============================================================
# HOST CHECKS
# ============================================================
check_metric() {
  local name="$1" value="$2" warn="$3" recover="$4" path="$5"
  local alert
  alert="$(state_get "${path}.alert")"
  alert="${alert:-false}"

  if (( value >= warn )) && [[ "$alert" == "false" ]]; then
    state_apply "${path}.alert = true | ${path}.last = ${value}"
    log WARN "${name} alert: ${value}%"
    send_msg "⚠️ ${name}: ${value}% (порог ${warn}%)"
  elif (( value <= recover )) && [[ "$alert" == "true" ]]; then
    state_apply "${path}.alert = false | ${path}.last = ${value}"
    log INFO "${name} recovered: ${value}%"
    send_msg "✅ ${name} нормализовался: ${value}%"
  fi
}

host_check() {
  [[ "$ENABLE_HOST_MONITOR" -eq 1 ]] || return 0

  local CPU RAM DISK SWAP
  CPU="$(cpu_usage_pct)"
  RAM="$(ram_usage_pct)"
  DISK="$(disk_usage_pct)"
  SWAP="$(swap_usage_pct)"

  check_metric "Нагрузка CPU"        "$CPU"  "$CPU_WARN"  "$((CPU_WARN-10))"   ".host.cpu"
  check_metric "Оперативная память"  "$RAM"  "$MEM_WARN"  "$((MEM_WARN-10))"   ".host.ram"
  check_metric "Диск /"              "$DISK" "$DISK_WARN" "$((DISK_WARN-5))"   ".host.disk"
  check_metric "Swap-память"         "$SWAP" "$SWAP_WARN" "$((SWAP_WARN-10))"  ".host.swap"
}

# ============================================================
# DOCKER CHECK
# ============================================================
container_check() {
  [[ "$ENABLE_DOCKER_MONITOR" -eq 1 ]] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  [[ -n "${CONTAINERS//[[:space:]]/}" ]] || return 0

  local IFS=','
  read -ra CTS <<<"$CONTAINERS"

  local ct key DOWN RUNNING
  for ct in "${CTS[@]}"; do
    ct="${ct//[[:space:]]/}"
    [[ -n "$ct" ]] || continue

    key="$(echo "$ct" | sed 's/[^a-zA-Z0-9]/_/g')"
    state_apply ".containers[\"$key\"] //= { down: false }"

    DOWN="$(state_get ".containers[\"$key\"].down")"; DOWN="${DOWN:-false}"
    RUNNING="$(docker inspect -f '{{.State.Running}}' "$ct" 2>/dev/null || echo false)"

    if [[ "$RUNNING" != "true" && "$DOWN" == "false" ]]; then
      state_apply ".containers[\"$key\"].down = true"
      log WARN "Container ${ct} stopped"
      send_msg "❌ Контейнер ${ct} остановлен"
    elif [[ "$RUNNING" == "true" && "$DOWN" == "true" ]]; then
      state_apply ".containers[\"$key\"].down = false"
      log INFO "Container ${ct} started"
      send_msg "✅ Контейнер ${ct} снова запущен"
    fi
  done
}

# ============================================================
# MAIN
# ============================================================
exec 9>"$LOCK_FILE"
flock -n 9 || { log WARN "Another instance is running, exiting"; exit 0; }

init_state
rotate_log_if_needed

log INFO "Monitor run started"
http_check
host_check
container_check
log INFO "Monitor run finished"
exit 0
