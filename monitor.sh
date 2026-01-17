#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
elif [[ -z "${PATH:-}" ]]; then
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
else
  PATH="${PATH}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
fi

resolve_home() {
  local uid
  uid="$(id -u)"
  if command -v getent >/dev/null 2>&1; then
    getent passwd "$uid" | cut -d: -f6
  else
    awk -F: -v uid="$uid" '$3==uid{print $6}' /etc/passwd 2>/dev/null
  fi
}

if [[ -z "${HOME:-}" || "$HOME" == *'$'* ]]; then
  RESOLVED_HOME="$(resolve_home)"
  if [[ -n "$RESOLVED_HOME" ]]; then
    HOME="$RESOLVED_HOME"
    export HOME
  fi
fi

render_msg() {
  local tpl="$1"; shift
  local key val
  while (( $# >= 2 )); do
    key="$1"; val="$2"
    tpl="${tpl//\{$key\}/$val}"
    shift 2
  done
  printf '%s' "$tpl"
}

# shellcheck disable=SC2317,SC2329
early_error() {
  local now
  now="$(date '+%F %T')"
  printf '%s\n' "$(render_msg "${ERR_EARLY_STDERR:-${now} [FATAL][EARLY] line={LINE} cmd='{CMD}' exit={EXIT}}" \
    TIME "$now" LINE "$2" CMD "$3" EXIT "$1")" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s\n' "$(render_msg "${LOG_EARLY:-${now} [FATAL][EARLY] line={LINE} cmd='{CMD}' exit={EXIT}}" \
      TIME "$now" LINE "$2" CMD "$3" EXIT "$1")" >>"$LOG_FILE" || true
  fi
  exit "$1"
}
trap 'early_error $? $LINENO "$BASH_COMMAND"' ERR

# ============================================================
# LOAD ENV
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_MISSING="0"
ENV_INSECURE="0"
ENV_INSECURE_REASON=""

env_is_secure() {
  local file="$1"
  ENV_INSECURE_REASON=""

  if [[ -L "$file" ]]; then
    ENV_INSECURE_REASON="symlink"
    return 1
  fi
  if [[ ! -f "$file" ]]; then
    ENV_INSECURE_REASON="not a regular file"
    return 1
  fi
  if ! command -v stat >/dev/null 2>&1; then
    return 0
  fi

  local mode owner type uid
  read -r mode owner type < <(stat -c '%a %u %F' "$file" 2>/dev/null || echo "??? ??? ???")
  uid="$(id -u)"

  if [[ "$type" != "regular file" ]]; then
    ENV_INSECURE_REASON="not a regular file"
    return 1
  fi
  if [[ "$owner" != "$uid" ]]; then
    ENV_INSECURE_REASON="owner=${owner} expected=${uid}"
    return 1
  fi
  if (( mode % 100 != 0 )); then
    ENV_INSECURE_REASON="mode=${mode} expected 600/400"
    return 1
  fi
  return 0
}

load_env_file() {
  local file="$1"
  local line key val

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" == export* ]]; then
      line="${line#export}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      key="${line%%=*}"
      val="${line#*=}"
      if [[ "$val" == \"*\" && "$val" == *\" ]]; then
        val="${val:1:${#val}-2}"
      elif [[ "$val" == \'*\' && "$val" == *\' ]]; then
        val="${val:1:${#val}-2}"
      fi
      if [[ -n "${HOME:-}" ]]; then
        val="${val//\$\{HOME\}/$HOME}"
        val="${val//\$HOME/$HOME}"
      fi
      printf -v "$key" '%s' "$val"
      export "${key?}"
    fi
  done < "$file"
}

if [[ -f "$ENV_FILE" ]]; then
  if [[ "${ENV_ALLOW_INSECURE:-0}" == "1" ]] || env_is_secure "$ENV_FILE"; then
    load_env_file "$ENV_FILE"
  else
    ENV_INSECURE="1"
  fi
else
  ENV_MISSING="1"
fi

# ============================================================
# DEFAULTS
# ============================================================
: "${PREFIX:="[monitor]"}"
: "${TG_TOKEN:=""}"  # однофайловый режим: впишите токен сюда при необходимости
: "${TG_CHAT:=""}"   # однофайловый режим: впишите chat id сюда при необходимости

: "${MSG_HTTP_DOWN_SERVICE_UP:="❌ Сайт недоступен: {URL}. HTTP {CODE}. Ошибка {FAILS}-й раз подряд. Активные: {WEB_ACTIVE}. Неактивные: {WEB_INACTIVE}."}"
: "${MSG_HTTP_DOWN_SERVICE_DOWN:="❌ Сайт недоступен: {URL}. HTTP {CODE}. Ошибка {FAILS}-й раз подряд. Активные: {WEB_ACTIVE}. Неактивные: {WEB_INACTIVE}."}"
: "${MSG_HTTP_DOWN_NO_SERVICE:="❌ Сайт недоступен: {URL}. HTTP {CODE}. Ошибка {FAILS}-й раз подряд. Веб-сервис на сервере не обнаружен."}"
: "${MSG_HTTP_RECOVERED:="✅ Сайт восстановился: {URL}. Код: {CODE}. Время ответа: {TIME} сек"}"
: "${MSG_HTTP_UP_SERVICE_DOWN:="⚠️ Сайт доступен: {URL}. Но службы остановлены: {WEB_INACTIVE}."}"
: "${MSG_HTTP_UP_SERVICE_RECOVER:="✅ Сайт доступен: {URL}. Службы восстановлены: {WEB_ACTIVE}."}"
: "${MSG_METRIC_ALERT:="⚠️ {NAME}: {VALUE}% (порог {WARN}%)"}"
: "${MSG_METRIC_RECOVERED:="✅ {NAME} нормализовался: {VALUE}%"}"
: "${MSG_CONTAINER_DOWN:="❌ Контейнер {CT} остановлен"}"
: "${MSG_CONTAINER_UP:="✅ Контейнер {CT} снова запущен"}"
: "${MSG_SERVICE_RECOVER_HTTP_DOWN:="⚠️ Службы восстановились: {WEB_ACTIVE}. Но сайт все еще недоступен."}"
: "${MSG_SERVICE_STOPPED_AFTER_HTTP_DOWN:="❌ Сайт недоступен и службы остановились: {WEB_INACTIVE}."}"

: "${NAME_CPU:="Нагрузка CPU"}"
: "${NAME_RAM:="Оперативная память"}"
: "${NAME_DISK:="Диск /"}"
: "${NAME_SWAP:="Swap-память"}"

: "${ERR_EARLY_STDERR:="{TIME} [FATAL][EARLY] line={LINE} cmd='{CMD}' exit={EXIT}"}"
: "${LOG_EARLY:="{TIME} [FATAL][EARLY] line={LINE} cmd='{CMD}' exit={EXIT}"}"
: "${WARN_ENV_MISSING:="WARN: .env not found: {FILE}. Using defaults."}"
: "${WARN_ENV_INSECURE:="WARN: .env not loaded (insecure permissions): {FILE} ({REASON})"}"
: "${LOG_ENV_MISSING:=".env not found: {FILE}. Using defaults."}"
: "${LOG_ENV_INSECURE:=".env not loaded (insecure permissions): {FILE} ({REASON})"}"
: "${ERR_CMD_REQUIRED:="FATAL: {CMD} is required"}"
: "${ERR_UNSAFE_PATH:="FATAL: insecure path {FILE} (dir={DIR} reason={REASON})"}"
: "${ERR_FATAL_STDERR:="[FATAL] line={LINE} cmd='{CMD}' exit={EXIT}"}"
: "${LOG_FATAL_ON_ERROR:="{HOST}:{SCRIPT}:{LINE} cmd='{CMD}' exit={EXIT}"}"

: "${WARN_TG_NOT_CONFIGURED:="WARN: Telegram is not configured (TG_TOKEN/TG_CHAT are empty)"}"
: "${WARN_URL_MISSING_HTTP_ENABLED:="WARN: ENABLE_HTTP_MONITOR=1 but URLS is not set"}"
: "${WARN_URL_AND_NO_WEB:="WARN: URLS is not set and no web service detected"}"

: "${LOG_TG_NOT_CONFIGURED:="Telegram is not configured (TG_TOKEN/TG_CHAT are empty)"}"
: "${LOG_HTTP_FAIL:="HTTP check failed for {URL}: code={CODE}, fails={FAILS}, threshold={THRESHOLD}"}"
: "${LOG_URL_DOWN_SERVICE_UP:="URL down for {URL}, service {WEB} is running"}"
: "${LOG_URL_DOWN_SERVICE_DOWN:="URL down for {URL}, service {WEB} is not running"}"
: "${LOG_URL_DOWN_NO_SERVICE:="URL down for {URL}, no web service detected"}"
: "${LOG_HTTP_UP_SERVICE_DOWN:="URL up for {URL}, but services stopped: {WEB_INACTIVE}"}"
: "${LOG_HTTP_UP_SERVICE_RECOVER:="URL up for {URL}, services recovered: {WEB_ACTIVE}"}"
: "${LOG_METRIC_ALERT:="{NAME} alert: {VALUE}%"}"
: "${LOG_CONTAINER_STOPPED:="Container {CT} stopped"}"
: "${LOG_SERVICE_RECOVER_HTTP_DOWN:="Service {WEB} recovered but HTTP is still down for {URLS}"}"
: "${LOG_WEB_ACTIVE:="Web services active: {WEB_ACTIVE}"}"
: "${LOG_WEB_INACTIVE:="Web services inactive: {WEB_INACTIVE}"}"
: "${LOG_ROTATED:="Log rotated (kept last {LINES} lines)"}"
: "${LOG_STATE_CREATED:="State file created"}"
: "${LOG_TG_SEND_FAILED:="Failed to send Telegram message"}"
: "${LOG_HTTP_DOWN_CONFIRMED:="HTTP DOWN confirmed for {URL} (code={CODE})"}"
: "${LOG_HTTP_RECOVERED:="HTTP recovered for {URL}, time={TIME}s, code={CODE}"}"
: "${LOG_METRIC_RECOVERED:="{NAME} recovered: {VALUE}%"}"
: "${LOG_CONTAINER_STARTED:="Container {CT} started"}"
: "${LOG_MONITOR_STARTED:="Monitor run started"}"
: "${LOG_MONITOR_FINISHED:="Monitor run finished"}"
: "${LOG_HTTP_AND_SERVICE_DOWN:="HTTP already down for {URLS} and service {WEB} is now stopped"}"
: "${LOG_ANOTHER_INSTANCE:="Another instance is running, exiting"}"

: "${STATE_FILE:=$HOME/.local/state/monitor/state.json}"
: "${LOG_FILE:=$HOME/.local/state/monitor/monitor.log}"
: "${LOCK_FILE:=$HOME/.local/state/monitor/monitor.lock}"

: "${ENABLE_HTTP_MONITOR:=0}"
: "${ENABLE_HOST_MONITOR:=1}"
: "${ENABLE_DOCKER_MONITOR:=0}"

: "${URLS:=""}"

: "${HTTP_TIMEOUT:=5}"
: "${HTTP_FAIL_THRESHOLD:=3}"
: "${HTTP_OK_MIN:=200}"
: "${HTTP_OK_MAX:=399}"   # 2xx + 3xx (редиректы НЕ ошибка)

: "${CPU_WARN:=90}"
: "${MEM_WARN:=90}"
: "${DISK_WARN:=80}"
: "${SWAP_WARN:=60}"

: "${CONTAINERS:=}"
: "${ENV_ALLOW_INSECURE:=0}"

# ============================================================
# PREPARE DIRS
# ============================================================
assert_safe_dir() {
  local dir="$1"
  local file="$2"
  PATH_UNSAFE_REASON=""
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || return 0
  [[ -n "$dir" ]] || return 1
  if [[ -L "$dir" ]]; then
    PATH_UNSAFE_REASON="symlink"
    return 1
  fi
  [[ -d "$dir" ]] || return 0
  if ! command -v stat >/dev/null 2>&1; then
    return 0
  fi
  local mode owner type group_digit other_digit
  read -r mode owner type < <(stat -c '%a %u %F' "$dir" 2>/dev/null || echo "??? ??? ???")
  if [[ "$type" != "directory" ]]; then
    PATH_UNSAFE_REASON="not a directory"
    return 1
  fi
  if [[ "$owner" != "0" ]]; then
    PATH_UNSAFE_REASON="owner=${owner} expected=0"
    return 1
  fi
  group_digit=$(( (mode / 10) % 10 ))
  other_digit=$(( mode % 10 ))
  if (( (group_digit & 2) || (other_digit & 2) )); then
    PATH_UNSAFE_REASON="mode=${mode} group/other writable"
    return 1
  fi
  return 0
}

STATE_DIR="$(dirname "$STATE_FILE")"
LOG_DIR="$(dirname "$LOG_FILE")"
LOCK_DIR="$(dirname "$LOCK_FILE")"
mkdir -p "$STATE_DIR" "$LOG_DIR" "$LOCK_DIR"
if ! assert_safe_dir "$STATE_DIR" "$STATE_FILE"; then
  printf '%s\n' "$(render_msg "$ERR_UNSAFE_PATH" FILE "$STATE_FILE" DIR "$STATE_DIR" REASON "$PATH_UNSAFE_REASON")" >&2
  exit 1
fi
if ! assert_safe_dir "$LOG_DIR" "$LOG_FILE"; then
  printf '%s\n' "$(render_msg "$ERR_UNSAFE_PATH" FILE "$LOG_FILE" DIR "$LOG_DIR" REASON "$PATH_UNSAFE_REASON")" >&2
  exit 1
fi
if ! assert_safe_dir "$LOCK_DIR" "$LOCK_FILE"; then
  printf '%s\n' "$(render_msg "$ERR_UNSAFE_PATH" FILE "$LOCK_FILE" DIR "$LOCK_DIR" REASON "$PATH_UNSAFE_REASON")" >&2
  exit 1
fi
touch "$LOG_FILE" 2>/dev/null || true

# ============================================================
# LOGGING
# ============================================================
log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$LOG_FILE" || true
}

if [[ "$ENV_MISSING" == "1" ]]; then
  printf '%s\n' "$(render_msg "$WARN_ENV_MISSING" FILE "$ENV_FILE")" >&2
  log WARN "$(render_msg "$LOG_ENV_MISSING" FILE "$ENV_FILE")"
fi
if [[ "$ENV_INSECURE" == "1" ]]; then
  printf '%s\n' "$(render_msg "$WARN_ENV_INSECURE" FILE "$ENV_FILE" REASON "$ENV_INSECURE_REASON")" >&2
  log WARN "$(render_msg "$LOG_ENV_INSECURE" FILE "$ENV_FILE" REASON "$ENV_INSECURE_REASON")"
fi

# ============================================================
# REQUIREMENTS
# ============================================================
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '%s\n' "$(render_msg "$ERR_CMD_REQUIRED" CMD "$1")" >&2
    exit 1
  }
}
require_cmd jq
require_cmd curl
require_cmd flock
require_cmd awk
require_cmd df
require_cmd sed

# shellcheck disable=SC2317,SC2329
on_error() {
  trap - ERR
  log FATAL "$(render_msg "$LOG_FATAL_ON_ERROR" HOST "$(hostname)" SCRIPT "$0" LINE "$2" CMD "$3" EXIT "$1")" || true
  printf '%s\n' "$(render_msg "$ERR_FATAL_STDERR" LINE "$2" CMD "$3" EXIT "$1")" >&2
  exit "$1"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ============================================================
# LOG ROTATION (simple)
# ============================================================
LOG_MAX_SIZE=$((512 * 1024))   # 512 KB
LOG_KEEP_LINES=6000

rotate_log_if_needed() {
  [[ -f "$LOG_FILE" ]] || return 0

  local size
  size=$(wc -c <"$LOG_FILE" || echo 0)

  if [[ "$size" -gt "$LOG_MAX_SIZE" ]]; then
    tail -n "$LOG_KEEP_LINES" "$LOG_FILE" >"${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    log INFO "$(render_msg "$LOG_ROTATED" LINES "$LOG_KEEP_LINES")"
  fi
}

# ============================================================
# STATE
# ============================================================
init_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    jq -n '{
      http: { down: false, targets: {}, urls: [] },
      host: {
        cpu:  { alert: false, last: 0 },
        ram:  { alert: false, last: 0 },
        disk: { alert: false, last: 0 },
        swap: { alert: false, last: 0 }
      },
      containers: {},
      telegram: { warn_missing_ts: 0 },
      warnings: {},
      web: { down: false, name: "", services: { active: [], inactive: [] } }
    }' >"$STATE_FILE"
    log INFO "$(render_msg "$LOG_STATE_CREATED")"
  fi
}

state_get() {
  # важно: false НЕ должен превращаться в empty
  jq -r "$1 | if . == null then empty else . end" "$STATE_FILE"
}

state_apply() {
  local filter="$1"; shift
  local tmp
  tmp="$(mktemp "$(dirname "$STATE_FILE")/state.tmp.XXXXXX")"
  jq "$filter" "$STATE_FILE" "$@" >"$tmp" && mv "$tmp" "$STATE_FILE"
}

send_msg() {
  if [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT:-}" ]]; then
    return 0
  fi
  curl -sS -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="${TG_CHAT}" \
    --data-urlencode text="${PREFIX} $1" >/dev/null || log ERROR "$(render_msg "$LOG_TG_SEND_FAILED")"
}

# ============================================================
# METRICS
# ============================================================
cpu_usage_pct() {
  # delta over short interval (иначе будет "среднее с момента загрузки")
  local -i idle1 total1 idle2 total2
  local user nice system idle iowait irq softirq steal

  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
  idle1=$((idle + iowait))

  sleep 0.2

  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
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
# WEB SERVICE DETECTION
# ============================================================
WEB_FOUND="false"
WEB_ACTIVE="false"
WEB_NAME=""
WEB_ACTIVE_LIST=""
WEB_INACTIVE_LIST=""
WEB_ACTIVE_UNITS=()
WEB_INACTIVE_UNITS=()

detect_web_service() {
  WEB_FOUND="false"
  WEB_ACTIVE="false"
  WEB_NAME=""
  WEB_ACTIVE_LIST=""
  WEB_INACTIVE_LIST=""
  WEB_ACTIVE_UNITS=()
  WEB_INACTIVE_UNITS=()

  local unit
  local found_units=()
  local active_units=()
  local inactive_units=()
  if command -v systemctl >/dev/null 2>&1; then
    local KNOWN_WEB_UNITS=(
      nginx
      nginx@
      apache2
      apache2@
      httpd
      httpd@
      caddy
      traefik
      haproxy
      envoy
      lighttpd
      openresty
    )
    for unit in "${KNOWN_WEB_UNITS[@]}"; do
      if [[ "$unit" == *@ ]]; then
        local unit_hits
        unit_hits="$(systemctl list-unit-files "${unit}.service" --no-legend --no-pager 2>/dev/null | awk 'NF{print $1}' || true)"
        if [[ -n "$unit_hits" ]]; then
          found_units+=("${unit}.service")
          while read -r inst active_state _; do
            [[ -n "$inst" ]] || continue
            if [[ "$active_state" == "active" ]]; then
              active_units+=("$inst")
            else
              inactive_units+=("$inst")
            fi
          done < <(systemctl list-units --all "${unit}*.service" --no-legend --no-pager 2>/dev/null | awk '{print $1, $3}')
          if (( ${#active_units[@]} == 0 )) && (( ${#inactive_units[@]} == 0 )); then
            inactive_units+=("${unit}.service")
          fi
        fi
      else
        local unit_hits
        unit_hits="$(systemctl list-unit-files "${unit}.service" --no-legend --no-pager 2>/dev/null | awk 'NF{print $1}' || true)"
        if [[ -n "$unit_hits" ]]; then
          found_units+=("${unit}.service")
          if systemctl is-active --quiet "${unit}.service"; then
            active_units+=("${unit}.service")
          else
            inactive_units+=("${unit}.service")
          fi
        fi
      fi
    done
    if (( ${#found_units[@]} > 0 )); then
      WEB_FOUND="true"
      if (( ${#active_units[@]} > 0 )); then
        WEB_ACTIVE="true"
        WEB_ACTIVE_UNITS=("${active_units[@]}")
        WEB_INACTIVE_UNITS=("${inactive_units[@]}")
        WEB_ACTIVE_LIST="$(IFS=,; echo "${active_units[*]}")"
        WEB_INACTIVE_LIST="$(IFS=,; echo "${inactive_units[*]}")"
        WEB_NAME="$WEB_ACTIVE_LIST"
      else
        WEB_INACTIVE_UNITS=("${inactive_units[@]}")
        WEB_INACTIVE_LIST="$(IFS=,; echo "${inactive_units[*]}")"
        WEB_NAME="$WEB_INACTIVE_LIST"
      fi
      return 0
    fi
  fi

  local line proc pid unit_from_pid
  if command -v ss >/dev/null 2>&1; then
    line="$(ss -ltnp '( sport = :80 or sport = :443 )' 2>/dev/null | awk 'NR>1 {print; exit}' || true)"
  elif command -v lsof >/dev/null 2>&1; then
    line="$(lsof -nP -iTCP:80 -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $0; exit}' || true)"
    [[ -n "$line" ]] || line="$(lsof -nP -iTCP:443 -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $0; exit}' || true)"
  fi

  if [[ -n "${line:-}" ]]; then
    proc="$(echo "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')"
    pid="$(echo "$line" | sed -n 's/.*pid=\([0-9]\+\).*/\1/p')"
    if [[ -z "$pid" && -n "$line" ]]; then
      pid="$(echo "$line" | awk '{print $2}')"
    fi
    if [[ -z "$proc" && -n "$line" ]]; then
      proc="$(echo "$line" | awk '{print $1}')"
    fi

    if [[ -n "$pid" ]] && command -v systemctl >/dev/null 2>&1; then
      unit_from_pid="$(systemctl status "$pid" --no-pager 2>/dev/null | awk 'NR==1 {gsub("●",""); print $1}')"
      if [[ -n "$unit_from_pid" ]]; then
        WEB_NAME="$unit_from_pid"
      else
        WEB_NAME="$proc"
      fi
    else
      WEB_NAME="$proc"
    fi

    WEB_FOUND="true"
    WEB_ACTIVE="true"
    WEB_ACTIVE_UNITS=("$WEB_NAME")
    WEB_ACTIVE_LIST="$WEB_NAME"
  fi
}

# ============================================================
# HTTP CHECK
# ============================================================
build_url_list() {
  URL_LIST=()
  if [[ -n "${URLS//[[:space:]]/}" ]]; then
    local raw
    raw="${URLS//,/ }"
    read -ra URL_LIST <<<"$raw"
  fi
}

http_check_one() {
  local url="$1"
  local CODE TIME code_int
  read -r CODE TIME <<<"$(curl -sS -o /dev/null -w "%{http_code} %{time_total}" \
    --max-time "$HTTP_TIMEOUT" "$url" || echo "000 0")"

  if ! printf -v TIME_FMT "%.1f" "${TIME:-0}" 2>/dev/null; then
    TIME_FMT="${TIME:-0}"
  fi

  code_int=$((10#${CODE:-0}))

  local key path FAILS DOWN
  key="${url//[^a-zA-Z0-9]/_}"
  path=".http.targets[\"$key\"]"
  state_apply "${path} //= { down: false, fail_count: 0, alert_service_down: false, url: \$url }" --arg url "$url"

  FAILS="$(state_get "${path}.fail_count")"; FAILS="${FAILS:-0}"
  DOWN="$(state_get "${path}.down")";       DOWN="${DOWN:-false}"

  if (( code_int < HTTP_OK_MIN || code_int > HTTP_OK_MAX )); then
    FAILS=$((FAILS + 1))
    state_apply "${path}.fail_count = \$fails | ${path}.alert_service_down = \$flag" \
      --argjson fails "$FAILS" --argjson flag false

    if (( FAILS == 1 )); then
      log WARN "$(render_msg "$LOG_HTTP_FAIL" CODE "$CODE" FAILS "$FAILS" THRESHOLD "$HTTP_FAIL_THRESHOLD" URL "$url")"
    fi

    if (( FAILS >= HTTP_FAIL_THRESHOLD )) && [[ "$DOWN" == "false" ]]; then
      state_apply "${path}.down = \$flag" --argjson flag true
      log ERROR "$(render_msg "$LOG_HTTP_DOWN_CONFIRMED" CODE "$CODE" URL "$url")"
      if [[ "$WEB_FOUND" == "true" ]]; then
        if [[ "$WEB_ACTIVE" == "true" ]]; then
          log WARN "$(render_msg "$LOG_URL_DOWN_SERVICE_UP" WEB "$WEB_NAME" URL "$url")"
          send_msg "$(render_msg "$MSG_HTTP_DOWN_SERVICE_UP" CODE "$CODE" FAILS "$FAILS" WEB "$WEB_NAME" URL "$url" WEB_ACTIVE "$WEB_ACTIVE_LIST" WEB_INACTIVE "$WEB_INACTIVE_LIST")"
        else
          log ERROR "$(render_msg "$LOG_URL_DOWN_SERVICE_DOWN" WEB "$WEB_NAME" URL "$url")"
          send_msg "$(render_msg "$MSG_HTTP_DOWN_SERVICE_DOWN" CODE "$CODE" FAILS "$FAILS" WEB "$WEB_NAME" URL "$url" WEB_ACTIVE "$WEB_ACTIVE_LIST" WEB_INACTIVE "$WEB_INACTIVE_LIST")"
        fi
      else
        log WARN "$(render_msg "$LOG_URL_DOWN_NO_SERVICE" URL "$url")"
        send_msg "$(render_msg "$MSG_HTTP_DOWN_NO_SERVICE" CODE "$CODE" FAILS "$FAILS" URL "$url")"
      fi
    fi
    return 0
  fi

  if (( FAILS != 0 )) || [[ "$DOWN" == "true" ]]; then
    state_apply "${path}.fail_count = \$fails | ${path}.down = \$flag" \
      --argjson fails 0 --argjson flag false
  fi

  if [[ "$DOWN" == "true" ]]; then
    log INFO "$(render_msg "$LOG_HTTP_RECOVERED" TIME "$TIME_FMT" CODE "$CODE" URL "$url")"
    send_msg "$(render_msg "$MSG_HTTP_RECOVERED" CODE "$CODE" TIME "$TIME_FMT" URL "$url")"
  fi

  if [[ "$WEB_FOUND" == "true" && "$WEB_ACTIVE" != "true" ]]; then
    local alert_service_down
    alert_service_down="$(state_get "${path}.alert_service_down")"; alert_service_down="${alert_service_down:-false}"
    if [[ "$alert_service_down" == "false" ]]; then
      log WARN "$(render_msg "$LOG_HTTP_UP_SERVICE_DOWN" URL "$url" WEB_INACTIVE "$WEB_INACTIVE_LIST")"
      send_msg "$(render_msg "$MSG_HTTP_UP_SERVICE_DOWN" URL "$url" WEB_INACTIVE "$WEB_INACTIVE_LIST")"
      state_apply "${path}.alert_service_down = \$flag" --argjson flag true
    fi
  else
    local alert_service_down
    alert_service_down="$(state_get "${path}.alert_service_down")"; alert_service_down="${alert_service_down:-false}"
    if [[ "$alert_service_down" == "true" && "$WEB_FOUND" == "true" && "$WEB_ACTIVE" == "true" ]]; then
      log INFO "$(render_msg "$LOG_HTTP_UP_SERVICE_RECOVER" URL "$url" WEB_ACTIVE "$WEB_ACTIVE_LIST")"
      send_msg "$(render_msg "$MSG_HTTP_UP_SERVICE_RECOVER" URL "$url" WEB_ACTIVE "$WEB_ACTIVE_LIST")"
    fi
    state_apply "${path}.alert_service_down = \$flag" --argjson flag false
  fi
}

http_check() {
  [[ "$ENABLE_HTTP_MONITOR" -eq 1 ]] || return 0
  build_url_list
  if (( ${#URL_LIST[@]} == 0 )); then
    state_apply '.http.down = false | .http.targets = {} | .http.urls = []'
    return 0
  fi

  local any_down="false"
  local url key down
  for url in "${URL_LIST[@]}"; do
    [[ -n "${url//[[:space:]]/}" ]] || continue
    http_check_one "$url"
    key="${url//[^a-zA-Z0-9]/_}"
    down="$(state_get ".http.targets[\"$key\"].down")"; down="${down:-false}"
    if [[ "$down" == "true" ]]; then
      any_down="true"
    fi
  done

  local urls_json keys_json
  urls_json="$(printf '%s\n' "${URL_LIST[@]}" | jq -R . | jq -s .)"
  keys_json="$(printf '%s\n' "${URL_LIST[@]}" | jq -R 'gsub("[^a-zA-Z0-9]"; "_")' | jq -s .)"
  state_apply ".http.urls = \$urls | .http.down = \$down | .http.targets |= with_entries(select(.key as \$k | \$keys | index(\$k)))" \
    --argjson urls "$urls_json" --argjson down "$any_down" --argjson keys "$keys_json"
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
    state_apply "${path}.alert = \$alert | ${path}.last = \$val" \
      --argjson alert true --argjson val "$value"
    log WARN "$(render_msg "$LOG_METRIC_ALERT" NAME "$name" VALUE "$value")"
    send_msg "$(render_msg "$MSG_METRIC_ALERT" NAME "$name" VALUE "$value" WARN "$warn")"
  elif (( value <= recover )) && [[ "$alert" == "true" ]]; then
    state_apply "${path}.alert = \$alert | ${path}.last = \$val" \
      --argjson alert false --argjson val "$value"
    log INFO "$(render_msg "$LOG_METRIC_RECOVERED" NAME "$name" VALUE "$value")"
    send_msg "$(render_msg "$MSG_METRIC_RECOVERED" NAME "$name" VALUE "$value")"
  fi
}

host_check() {
  [[ "$ENABLE_HOST_MONITOR" -eq 1 ]] || return 0

  local CPU RAM DISK SWAP
  CPU="$(cpu_usage_pct)"
  RAM="$(ram_usage_pct)"
  DISK="$(disk_usage_pct)"
  SWAP="$(swap_usage_pct)"

  check_metric "$NAME_CPU"   "$CPU"  "$CPU_WARN"  "$((CPU_WARN-10))"   ".host.cpu"
  check_metric "$NAME_RAM"   "$RAM"  "$MEM_WARN"  "$((MEM_WARN-10))"   ".host.ram"
  check_metric "$NAME_DISK"  "$DISK" "$DISK_WARN" "$((DISK_WARN-5))"   ".host.disk"
  check_metric "$NAME_SWAP"  "$SWAP" "$SWAP_WARN" "$((SWAP_WARN-10))"  ".host.swap"
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

    key="${ct//[^a-zA-Z0-9]/_}"
    state_apply ".containers[\$key] //= { down: false }" --arg key "$key"

    DOWN="$(state_get ".containers[\"$key\"].down")"; DOWN="${DOWN:-false}"
    RUNNING="$(docker inspect -f '{{.State.Running}}' "$ct" 2>/dev/null || echo false)"

    if [[ "$RUNNING" != "true" && "$DOWN" == "false" ]]; then
      state_apply ".containers[\$key].down = \$flag" --arg key "$key" --argjson flag true
      log WARN "$(render_msg "$LOG_CONTAINER_STOPPED" CT "$ct")"
      send_msg "$(render_msg "$MSG_CONTAINER_DOWN" CT "$ct")"
    elif [[ "$RUNNING" == "true" && "$DOWN" == "true" ]]; then
      state_apply ".containers[\$key].down = \$flag" --arg key "$key" --argjson flag false
      log INFO "$(render_msg "$LOG_CONTAINER_STARTED" CT "$ct")"
      send_msg "$(render_msg "$MSG_CONTAINER_UP" CT "$ct")"
    fi
  done
}

# ============================================================
# MAIN
# ============================================================
exec 9>"$LOCK_FILE"
flock -n 9 || { log WARN "$(render_msg "$LOG_ANOTHER_INSTANCE")"; exit 0; }

init_state
rotate_log_if_needed

log INFO "$(render_msg "$LOG_MONITOR_STARTED")"
now_ts="$(date +%s)"
if [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT:-}" ]]; then
  echo "$WARN_TG_NOT_CONFIGURED" >&2
  state_apply '.telegram.warn_missing_ts //= 0'
  last_warn="$(state_get '.telegram.warn_missing_ts')"
  last_warn="${last_warn:-0}"
  if (( now_ts - last_warn >= 86400 )); then
    log WARN "$(render_msg "$LOG_TG_NOT_CONFIGURED")"
    state_apply ".telegram.warn_missing_ts = \$ts" --argjson ts "$now_ts"
  fi
fi
detect_web_service
state_apply '.web.down //= false | .web.name //= "" | .web.services.active //= [] | .web.services.inactive //= []'
prev_web_down="$(state_get '.web.down')"; prev_web_down="${prev_web_down:-false}"
prev_web_name="$(state_get '.web.name')"; prev_web_name="${prev_web_name:-}"
prev_web_active="$(state_get '.web.services.active | join(",")')"
prev_web_inactive="$(state_get '.web.services.inactive | join(",")')"
active_json="[]"
inactive_json="[]"
if (( ${#WEB_ACTIVE_UNITS[@]} > 0 )); then
  active_json="$(printf '%s\n' "${WEB_ACTIVE_UNITS[@]}" | jq -R . | jq -s .)"
fi
if (( ${#WEB_INACTIVE_UNITS[@]} > 0 )); then
  inactive_json="$(printf '%s\n' "${WEB_INACTIVE_UNITS[@]}" | jq -R . | jq -s .)"
fi
if [[ "$WEB_FOUND" == "true" ]]; then
  state_apply ".web.services.active = \$active | .web.services.inactive = \$inactive | .web.name = \$name" \
    --argjson active "$active_json" --argjson inactive "$inactive_json" --arg name "$WEB_NAME"
  if [[ -n "${WEB_ACTIVE_LIST//[[:space:]]/}" && "$WEB_ACTIVE_LIST" != "$prev_web_active" ]]; then
    log INFO "$(render_msg "$LOG_WEB_ACTIVE" WEB_ACTIVE "$WEB_ACTIVE_LIST")"
  fi
  if [[ -n "${WEB_INACTIVE_LIST//[[:space:]]/}" && "$WEB_INACTIVE_LIST" != "$prev_web_inactive" ]]; then
    log WARN "$(render_msg "$LOG_WEB_INACTIVE" WEB_INACTIVE "$WEB_INACTIVE_LIST")"
  fi
    if [[ "$WEB_ACTIVE" == "true" ]]; then
      if [[ "$prev_web_down" == "true" ]]; then
        state_apply ".web.down = \$flag" --argjson flag false
        http_down_now="$(state_get '.http.down')"; http_down_now="${http_down_now:-false}"
        if [[ "$http_down_now" == "true" ]]; then
          urls_for_log="${URLS:-}"
          if [[ -z "${urls_for_log//[[:space:]]/}" ]]; then
            urls_for_log="$(state_get '.http.urls | join(" ")')"
          fi
          log WARN "$(render_msg "$LOG_SERVICE_RECOVER_HTTP_DOWN" WEB "$WEB_NAME" URLS "$urls_for_log")"
          send_msg "$(render_msg "$MSG_SERVICE_RECOVER_HTTP_DOWN" WEB "$WEB_NAME" WEB_ACTIVE "$WEB_ACTIVE_LIST" WEB_INACTIVE "$WEB_INACTIVE_LIST")"
        fi
      fi
    else
    if [[ "$prev_web_down" == "false" ]]; then
      state_apply ".web.down = \$flag" --argjson flag true
    fi
    http_down_now="$(state_get '.http.down')"; http_down_now="${http_down_now:-false}"
    if [[ "$http_down_now" == "true" && "$prev_web_down" == "false" ]]; then
      urls_for_log="${URLS:-}"
      if [[ -z "${urls_for_log//[[:space:]]/}" ]]; then
        urls_for_log="$(state_get '.http.urls | join(" ")')"
      fi
      log ERROR "$(render_msg "$LOG_HTTP_AND_SERVICE_DOWN" WEB "$WEB_NAME" URLS "$urls_for_log")"
      send_msg "$(render_msg "$MSG_SERVICE_STOPPED_AFTER_HTTP_DOWN" WEB "$WEB_NAME" WEB_ACTIVE "$WEB_ACTIVE_LIST" WEB_INACTIVE "$WEB_INACTIVE_LIST")"
    fi
  fi
else
  if [[ "$prev_web_down" == "true" || -n "$prev_web_name" ]]; then
    state_apply ".web.down = \$flag | .web.name = \$name | .web.services.active = [] | .web.services.inactive = []" \
      --argjson flag false --arg name ""
  fi
fi
state_apply '.warnings.missing_url_ts //= 0 | .warnings.no_web_service_ts //= 0'
if [[ "${ENABLE_HTTP_MONITOR:-0}" -eq 1 && -z "${URLS//[[:space:]]/}" ]]; then
  echo "$WARN_URL_MISSING_HTTP_ENABLED" >&2
  last_warn="$(state_get '.warnings.missing_url_ts')"; last_warn="${last_warn:-0}"
  if (( now_ts - last_warn >= 86400 )); then
    log WARN "$(render_msg "$WARN_URL_MISSING_HTTP_ENABLED")"
    state_apply ".warnings.missing_url_ts = \$ts" --argjson ts "$now_ts"
  fi
fi
if [[ "$WEB_FOUND" == "false" && -z "${URLS//[[:space:]]/}" ]]; then
  echo "$WARN_URL_AND_NO_WEB" >&2
  last_warn="$(state_get '.warnings.no_web_service_ts')"; last_warn="${last_warn:-0}"
  if (( now_ts - last_warn >= 86400 )); then
    log WARN "$(render_msg "$WARN_URL_AND_NO_WEB")"
    state_apply ".warnings.no_web_service_ts = \$ts" --argjson ts "$now_ts"
  fi
fi
http_check
host_check
container_check
log INFO "$(render_msg "$LOG_MONITOR_FINISHED")"
exit 0
