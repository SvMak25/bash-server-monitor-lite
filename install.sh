#!/usr/bin/env bash
set -Eeuo pipefail

early_error() {
  echo "[FATAL] line=$2 cmd='$3' exit=$1" >&2
  exit "$1"
}
trap 'early_error $? $LINENO "$BASH_COMMAND"' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="monitor-lite"
ALLOW_ROOT_FALLBACK="${ALLOW_ROOT_FALLBACK:-0}"

log() {
  printf '[install] %s\n' "$*" >&2
}

if [[ -x "${SCRIPT_DIR}/bootstrap.sh" ]]; then
  log "Running bootstrap.sh"
  "${SCRIPT_DIR}/bootstrap.sh"
fi

if [[ "$EUID" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

if [[ "$EUID" -ne 0 && "$SUDO" == "" ]]; then
  TARGET_DIR="${HOME}/monitor-lite"
else
  TARGET_DIR="/opt/monitor"
fi

log "Installing to ${TARGET_DIR}"
$SUDO mkdir -p "$TARGET_DIR"
$SUDO cp "${SCRIPT_DIR}/monitor.sh" "${TARGET_DIR}/monitor.sh"
$SUDO chmod +x "${TARGET_DIR}/monitor.sh"  # при строгих политиках можно заменить на: $SUDO chmod u+x "${TARGET_DIR}/monitor.sh"

if [[ "$SUDO" != "sudo" ]]; then
  chmod 700 "$TARGET_DIR"
else
  $SUDO chmod 700 "$TARGET_DIR"
fi

if [[ ! -f "${TARGET_DIR}/.env" ]]; then
  log "Creating ${TARGET_DIR}/.env from .env.example"
  $SUDO cp "${SCRIPT_DIR}/.env.example" "${TARGET_DIR}/.env"
fi

STATE_DIR="${TARGET_DIR}/state"
$SUDO mkdir -p "$STATE_DIR"
$SUDO chmod 700 "$STATE_DIR"
$SUDO sed -i \
  -e "s|^STATE_FILE=.*|STATE_FILE=\"${STATE_DIR}/state.json\"|" \
  -e "s|^LOG_FILE=.*|LOG_FILE=\"${STATE_DIR}/monitor.log\"|" \
  -e "s|^LOCK_FILE=.*|LOCK_FILE=\"${STATE_DIR}/monitor.lock\"|" \
  "${TARGET_DIR}/.env"
$SUDO chmod 600 "${TARGET_DIR}/.env"

HAS_PRIVILEGE="1"
if [[ "$SUDO" != "" || "$EUID" -eq 0 ]]; then
  HAS_PRIVILEGE="1"
else
  HAS_PRIVILEGE="0"
fi

if [[ "$HAS_PRIVILEGE" == "1" ]] && command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  log "systemd detected, installing timer"
  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
  TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"

  if ! systemctl list-unit-files "${SERVICE_NAME}.service" --no-legend --no-pager 2>/dev/null | awk 'NF{print $1}' | grep -q "${SERVICE_NAME}.service"; then
    $SUDO tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Monitor Lite

[Service]
Type=oneshot
WorkingDirectory=${TARGET_DIR}
ExecStart=${TARGET_DIR}/monitor.sh
User=${SERVICE_NAME}
EOF
  fi

  if ! systemctl list-unit-files "${SERVICE_NAME}.timer" --no-legend --no-pager 2>/dev/null | awk 'NF{print $1}' | grep -q "${SERVICE_NAME}.timer"; then
    $SUDO tee "$TIMER_FILE" >/dev/null <<EOF
[Unit]
Description=Run Monitor Lite every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  fi

  SERVICE_USER="${SERVICE_NAME}"
  if id "${SERVICE_NAME}" >/dev/null 2>&1; then
    :
  else
    if $SUDO useradd -r -s /usr/sbin/nologin -d "${TARGET_DIR}" "${SERVICE_NAME}"; then
      :
    else
      if [[ "$ALLOW_ROOT_FALLBACK" == "1" ]]; then
        log "useradd failed, falling back to root (ALLOW_ROOT_FALLBACK=1)"
        SERVICE_USER="root"
      else
        log "useradd failed; refusing to run as root (set ALLOW_ROOT_FALLBACK=1 to override)"
        exit 1
      fi
    fi
  fi

  if [[ "$SERVICE_USER" == "${SERVICE_NAME}" ]]; then
    $SUDO chown -R "${SERVICE_NAME}:${SERVICE_NAME}" "${TARGET_DIR}"
  fi

  if [[ "$SERVICE_USER" != "${SERVICE_NAME}" ]]; then
    if $SUDO grep -q '^User=' "$SERVICE_FILE"; then
      $SUDO sed -i 's/^User=.*/User=root/' "$SERVICE_FILE"
    else
      $SUDO sed -i '/^ExecStart=/a User=root' "$SERVICE_FILE"
    fi
  fi

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now "${SERVICE_NAME}.timer"
  log "Timer enabled: ${SERVICE_NAME}.timer"
  exit 0
fi

if command -v crontab >/dev/null 2>&1; then
  log "Installing cron for current user"
  CRON_SPEC="* * * * * ${TARGET_DIR}/monitor.sh >/dev/null 2>&1"
  crontab -l 2>/dev/null | grep -v "${TARGET_DIR}/monitor.sh" | { cat; echo "$CRON_SPEC"; } | crontab -
  log "Cron installed for current user"
else
  log "No systemd or cron detected; automatic scheduling is not available"
  RUNNER="${TARGET_DIR}/run.sh"
  $SUDO tee "$RUNNER" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

while true; do
  "${SCRIPT_DIR}/monitor.sh" || true
  sleep 60
done
EOF
  $SUDO chmod +x "$RUNNER"  # при строгих политиках можно заменить на: $SUDO chmod u+x "$RUNNER"
  log "Created runner: ${RUNNER} (start it manually if needed)"
fi
