#!/usr/bin/env bash
set -eEuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '\r\n' < "${ROOT_DIR}/VERSION")"
DIST_DIR="${ROOT_DIR}/dist"
PACKAGE_DIR="${DIST_DIR}/singbox-manager-${VERSION}"
PACKAGE_NAME="singbox-manager-${VERSION}.tar.gz"

rm -rf "${PACKAGE_DIR}"
mkdir -p "${PACKAGE_DIR}" "${DIST_DIR}"

install -m 0755 "${ROOT_DIR}/sb.sh" "${PACKAGE_DIR}/sb.sh"
install -d -m 0755 "${PACKAGE_DIR}/lib" "${PACKAGE_DIR}/metadata" "${PACKAGE_DIR}/scripts"
install -m 0644 "${ROOT_DIR}/lib/common.sh" "${PACKAGE_DIR}/lib/common.sh"
install -m 0644 "${ROOT_DIR}/metadata/upstream.env" "${PACKAGE_DIR}/metadata/upstream.env"
install -m 0755 "${ROOT_DIR}/scripts/watchdog.sh" "${PACKAGE_DIR}/scripts/watchdog.sh"
install -m 0644 "${ROOT_DIR}/README.md" "${PACKAGE_DIR}/README.md"
install -m 0644 "${ROOT_DIR}/VERSION" "${PACKAGE_DIR}/VERSION"

tar -czf "${DIST_DIR}/${PACKAGE_NAME}" -C "${DIST_DIR}" "singbox-manager-${VERSION}"

PACKAGE_SHA256="$(sha256sum "${DIST_DIR}/${PACKAGE_NAME}" | awk '{print $1}')"

echo "${PACKAGE_SHA256}  ${PACKAGE_NAME}" > "${DIST_DIR}/checksums.txt"

sed -e "s/__SHA256_PLACEHOLDER__/${PACKAGE_SHA256}/" \
  "${ROOT_DIR}/install.sh" > "${DIST_DIR}/install.sh"

echo "Built ${DIST_DIR}/${PACKAGE_NAME}"
echo "Generated ${DIST_DIR}/install.sh"
