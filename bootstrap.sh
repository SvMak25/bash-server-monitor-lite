#!/usr/bin/env bash
set -Eeuo pipefail

early_error() {
  echo "[FATAL] Early error at line $2: $3" >&2
  exit "$1"
}

trap 'early_error $? $LINENO "$BASH_COMMAND"' ERR

# ============================================================
# CONFIG
# ============================================================
REQUIRED_CMDS=(
  jq
  curl
  flock
  awk
  df
  sed
)

# ============================================================
# LOGGING
# ============================================================
log() {
  printf '[bootstrap] %s\n' "$*" >&2
}

fatal() {
  printf '[bootstrap][FATAL] %s\n' "$*" >&2
  exit 1
}

# ============================================================
# OS DETECTION
# ============================================================
if [ -r /etc/os-release ]; then
  . /etc/os-release
else
  fatal "/etc/os-release not found"
fi

OS_ID="${ID:-}"
OS_LIKE="${ID_LIKE:-}"

log "Detected OS: ${OS_ID}"

# ============================================================
# PACKAGE MANAGER DETECTION
# ============================================================
PKG_MANAGER=""
INSTALL_CMD=""

case "$OS_ID" in
  ubuntu|debian)
    PKG_MANAGER="apt"
    INSTALL_CMD="apt-get update -y && apt-get install -y"
    ;;
  fedora)
    PKG_MANAGER="dnf"
    INSTALL_CMD="dnf install -y"
    ;;
  centos|rhel|rocky|almalinux)
    PKG_MANAGER="dnf"
    INSTALL_CMD="dnf install -y"
    ;;
  arch)
    PKG_MANAGER="pacman"
    INSTALL_CMD="pacman -Sy --noconfirm"
    ;;
  *)
    case "$OS_LIKE" in
      *debian*)
        PKG_MANAGER="apt"
        INSTALL_CMD="apt-get update -y && apt-get install -y"
        ;;
      *rhel*|*fedora*)
        PKG_MANAGER="dnf"
        INSTALL_CMD="dnf install -y"
        ;;
      *)
        fatal "Unsupported Linux distribution: ${OS_ID}"
        ;;
    esac
    ;;
esac

log "Using package manager: ${PKG_MANAGER}"

# ============================================================
# PACKAGE NAME MAP
# ============================================================
pkg_name() {
  local cmd="$1"

  case "$cmd" in
    jq) echo jq ;;
    curl) echo curl ;;
    df) echo coreutils ;;
    awk) echo gawk ;;
    sed) echo sed ;;
    flock) echo util-linux ;;
    *)
      echo "$cmd"
      ;;
  esac
}

# ============================================================
# INSTALL MISSING TOOLS
# ============================================================
MISSING_PKGS=()

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    pkg="$(pkg_name "$cmd")"
    MISSING_PKGS+=("$pkg")
  fi
done

if [ "${#MISSING_PKGS[@]}" -eq 0 ]; then
  log "All required tools already installed"
  exit 0
fi

log "Missing packages: ${MISSING_PKGS[*]}"

# ============================================================
# INSTALL
# ============================================================
if [ "$EUID" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

log "Installing packages..."
$SUDO sh -c "$INSTALL_CMD ${MISSING_PKGS[*]}"

log "Bootstrap completed successfully"
