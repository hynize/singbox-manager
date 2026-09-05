#!/usr/bin/env bash
set -eEuo pipefail

umask 077

REPO_OWNER="hynize"
REPO_NAME="singbox-manager"
PROJECT_VERSION="v0.2.12"
PACKAGE_NAME="singbox-manager-v0.2.12.tar.gz"
# 发布流程：scripts/build-release-bundle.sh 构建可复现 bundle，其 SHA256 与此处一致
PACKAGE_SHA256="d60b652f892575acca35feae7ded66d34c97d0c90544aa64da22f9769f1e1bd4"
PACKAGE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${PROJECT_VERSION}/${PACKAGE_NAME}"

INSTALL_BIN="/usr/local/bin/sbm"
LIB_DIR="/usr/local/lib/singbox-manager"
BASE_DIR="/usr/local/etc/singbox-manager"
WATCHDOG_PATH="${BASE_DIR}/watchdog.sh"
UPSTREAM_ENV="${LIB_DIR}/upstream.env"
COMMON_LIB="${LIB_DIR}/common.sh"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 用户运行。" >&2
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
    echo "需要安装 curl 或 wget。" >&2
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
    echo "安装包校验失败。" >&2
    echo "预期值: $PACKAGE_SHA256" >&2
    echo "实际值: $actual" >&2
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

resolve_action() {
  # 显式传入动作（rep / ins）优先生效；未传参但检测到节点环境变量时，
  # 默认走非破坏性的 ins（追加），避免残留变量静默触发覆盖式重装
  local action="${1:-}"
  local var
  if [ -n "${action}" ]; then
    printf '%s' "${action}"
    return 0
  fi
  for var in vlrt wspt tupt anypt hypt socks5pt argo; do
    if [ -n "${!var:-}" ]; then
      printf 'ins'
      return 0
    fi
  done
  printf ''
}

main() {
  local bundle action
  bundle="$(mktemp)"
  if ! download "${PACKAGE_URL}" "${bundle}"; then
    rm -f "${bundle}"
    echo "下载发布包失败：${PACKAGE_URL}" >&2
    exit 1
  fi
  verify_bundle "${bundle}"
  install_bundle "${bundle}"
  rm -f "${bundle}"
  echo "Singbox Manager ${PROJECT_VERSION} 安装完成：${INSTALL_BIN}"
  action="$(resolve_action "$@")"
  if [ -n "${action}" ]; then
    exec "${INSTALL_BIN}" "${action}"
  fi
  exec "${INSTALL_BIN}"
}

main "$@"
