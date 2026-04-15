#!/usr/bin/env bash
set -uo pipefail

REPO_OWNER="hynize"
REPO_NAME="singbox-manager"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"
INSTALL_BIN="/usr/local/bin/sbm"
BASE_DIR="/usr/local/etc/singbox-manager"
WATCHDOG_PATH="${BASE_DIR}/watchdog.sh"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

mkdir -p "${BASE_DIR}"

download() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "curl or wget is required."
    exit 1
  fi
}

download "${RAW_BASE}/sb.sh" "${INSTALL_BIN}"
download "${RAW_BASE}/scripts/watchdog.sh" "${WATCHDOG_PATH}"

chmod +x "${INSTALL_BIN}" "${WATCHDOG_PATH}"

echo "Singbox Manager installed: ${INSTALL_BIN}"
exec "${INSTALL_BIN}"
