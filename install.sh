#!/usr/bin/env bash
set -eEuo pipefail

umask 077

REPO_OWNER="hynize"
REPO_NAME="singbox-manager"
PROJECT_VERSION="v0.2.2"
PACKAGE_NAME="singbox-manager-v0.2.2.tar.gz"
PACKAGE_SHA256="4be3a2bff8b27a1ff96027790da27c28ee1b80eff5eeaae89334c4e27ddf8631"
PACKAGE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${PROJECT_VERSION}/${PACKAGE_NAME}"

INSTALL_BIN="/usr/local/bin/sbm"
LIB_DIR="/usr/local/lib/singbox-manager"
BASE_DIR="/usr/local/etc/singbox-manager"
WATCHDOG_PATH="${BASE_DIR}/watchdog.sh"
UPSTREAM_ENV="${LIB_DIR}/upstream.env"
COMMON_LIB="${LIB_DIR}/common.sh"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Please run as root." >&2
  exit 1
fi

download() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "curl or wget is required." >&2
    exit 1
  fi
}

sha256_file() {
  local target="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$target" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$target" | awk '{print $1}'
  else
    openssl dgst -sha256 "$target" | awk '{print $2}'
  fi
}

verify_bundle() {
  local bundle="$1"
  local actual
  actual="$(sha256_file "$bundle")"
  if [ "$actual" != "$PACKAGE_SHA256" ]; then
    echo "Bundle checksum mismatch." >&2
    echo "Expected: $PACKAGE_SHA256" >&2
    echo "Actual:   $actual" >&2
    exit 1
  fi
}

install_bundle() {
  local bundle="$1"
  local tmpdir root_dir

  tmpdir="$(mktemp -d)"
  tar -xzf "$bundle" -C "$tmpdir"
  root_dir="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

  install -d -m 700 "$LIB_DIR" "$BASE_DIR"
  install -m 0755 "${root_dir}/sb.sh" "${INSTALL_BIN}"
  install -m 0644 "${root_dir}/lib/common.sh" "${COMMON_LIB}"
  install -m 0644 "${root_dir}/metadata/upstream.env" "${UPSTREAM_ENV}"
  install -m 0755 "${root_dir}/scripts/watchdog.sh" "${WATCHDOG_PATH}"

  chmod 0755 "${INSTALL_BIN}" "${WATCHDOG_PATH}"
  chmod 0644 "${COMMON_LIB}" "${UPSTREAM_ENV}"
  rm -rf "$tmpdir"
}

main() {
  local bundle
  bundle="$(mktemp)"
  download "${PACKAGE_URL}" "${bundle}"
  verify_bundle "${bundle}"
  install_bundle "${bundle}"
  rm -f "${bundle}"
  echo "Singbox Manager ${PROJECT_VERSION} installed: ${INSTALL_BIN}"
  exec "${INSTALL_BIN}"
}

main "$@"
