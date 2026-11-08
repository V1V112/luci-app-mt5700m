#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk_version="${SDK_VERSION:-25.12.6}"
sdk_target="${SDK_TARGET:-mediatek/filogic}"
case "${sdk_target}" in
  mediatek/filogic) expected_arch='aarch64_cortex-a53' ;;
  rockchip/armv8) expected_arch='aarch64_generic' ;;
  *) printf 'Unsupported SDK_TARGET: %s\n' "${sdk_target}" >&2; exit 1 ;;
esac
[[ "${sdk_version}" =~ ^[0-9][A-Za-z0-9._-]*$ ]] || {
  printf 'Invalid SDK_VERSION: %s\n' "${sdk_version}" >&2
  exit 1
}
sdk_board="${sdk_target%/*}"
sdk_subtarget="${sdk_target#*/}"
target_id="${sdk_board}-${sdk_subtarget}"
work_dir="${RUNNER_TEMP:-/tmp}/mt5700m-sdk-${sdk_version}-${target_id}"
sdk_cache_dir="${SDK_DOWNLOAD_CACHE_DIR:-${RUNNER_TEMP:-/tmp}/mt5700m-sdk-downloads}/${sdk_version}-${target_id}"
output_dir="${repo_dir}/dist-release"
base_url="https://downloads.openwrt.org/releases/${sdk_version}/targets/${sdk_target}"

mkdir -p "${work_dir}" "${sdk_cache_dir}" "${output_dir}"
sdk_cache_dir="$(cd "${sdk_cache_dir}" && pwd)"
find "${output_dir}" -mindepth 1 -maxdepth 1 -delete
cd "${work_dir}"
printf 'Fetching official SDK checksums: %s\n' "${base_url}/sha256sums"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 120 \
  "${base_url}/sha256sums" -o sha256sums.tmp
mv -f sha256sums.tmp sha256sums
archive="$(awk -v prefix="openwrt-sdk-${sdk_version}-${target_id}_" '
  { name = $2; sub(/^\*/, "", name) }
  index(name, prefix) == 1 && name !~ /\// && name ~ /\.Linux-x86_64\.tar\.zst$/ { print name; exit }
' sha256sums)"
test -n "${archive}"
checksum="$(awk -v archive="${archive}" '$2 == archive || $2 == "*" archive { print $1; exit }' sha256sums)"
[[ "${checksum}" =~ ^[A-Fa-f0-9]{64}$ ]] || { printf 'Invalid official SDK checksum\n' >&2; exit 1; }
archive_path="${sdk_cache_dir}/${archive}"
partial_path="${archive_path}.part"
verify_sdk() { printf '%s  %s\n' "${checksum}" "$1" | sha256sum -c -; }
download_sdk() {
  # A partial file without aria2 metadata is a sequential curl prefix.
  if command -v aria2c >/dev/null 2>&1 && { [ ! -f "${partial_path}" ] || [ -f "${partial_path}.aria2" ]; }; then
    printf 'Downloading SDK with four connections: %s\n' "${base_url}/${archive}"
    if aria2c --continue=true --allow-overwrite=true --auto-file-renaming=false \
      --max-connection-per-server=4 --split=4 --min-split-size=20M --file-allocation=none \
      --max-tries=5 --retry-wait=2 --connect-timeout=20 --timeout=60 --summary-interval=10 \
      --dir="${sdk_cache_dir}" --out="${archive}.part" "${base_url}/${archive}"; then
      return 0
    fi
    printf 'Parallel SDK download failed; retrying with curl.\n' >&2
    # aria2 partial files may contain noncontiguous chunks; curl requires a prefix.
    rm -f "${partial_path}" "${partial_path}.aria2"
  fi
  printf 'Downloading SDK with curl (resume and retries enabled): %s\n' "${base_url}/${archive}"
  if curl -fL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 20 \
    --speed-time 60 --speed-limit 1024 --continue-at - "${base_url}/${archive}" -o "${partial_path}"; then
    return 0
  fi
  printf 'SDK resume failed; retrying curl from the beginning.\n' >&2
  rm -f "${partial_path}"
  curl -fL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 20 \
    --speed-time 60 --speed-limit 1024 --continue-at - "${base_url}/${archive}" -o "${partial_path}"
}
if [ -f "${archive_path}" ] && verify_sdk "${archive_path}" >/dev/null 2>&1; then
  printf 'Reusing cached SDK (official SHA256 verified): %s\n' "${archive_path}"
else
  if [ -f "${archive_path}" ]; then
    printf 'Cached SDK failed SHA256 verification; downloading a replacement.\n' >&2
    rm -f "${archive_path}" "${partial_path}" "${partial_path}.aria2"
  fi
  download_sdk
  if ! verify_sdk "${partial_path}"; then
    rm -f "${partial_path}" "${partial_path}.aria2"
    exit 1
  fi
  mv -f "${partial_path}" "${archive_path}"
  rm -f "${partial_path}.aria2"
fi
printf 'Extracting verified SDK: %s\n' "${archive}"
tar --zstd -xf "${archive_path}"
sdk_dir="${work_dir}/${archive%.tar.zst}"
test -d "${sdk_dir}"

cd "${sdk_dir}"
./scripts/feeds update -a
./scripts/feeds install luci-base

perl -0pi -e 's/(config ALL\n\s+bool "Select all userspace packages by default"\n\s+default )y/${1}n/' Config.in
SDK_CONFIG_TARGET="${sdk_board}_${sdk_subtarget}" perl -0pi -e 's/(config TARGET_MULTI_PROFILE\n\s+bool\n\s+default )y/${1}n/; s/(config TARGET_ALL_PROFILES\n\s+bool\n\s+default )y/${1}n/; s/(config TARGET_DEVICE_\Q$ENV{SDK_CONFIG_TARGET}\E_DEVICE_[^\n]+\n\s+bool\n\s+default )y/${1}n/g' Config-build.in
sed -i 's/^[[:space:]]*default m$/\tdefault n/' Config-build.in

mkdir -p package/h5000m-custom
cp -a "${repo_dir}/luci-app-mt5700m" package/h5000m-custom/
cp -a "${repo_dir}/mt5700m-transport" package/h5000m-custom/
cat > .config <<EOF
CONFIG_TARGET_${sdk_board}=y
CONFIG_TARGET_${sdk_board}_${sdk_subtarget}=y
# CONFIG_ALL is not set
# CONFIG_ALL_KMODS is not set
# CONFIG_ALL_NONSHARED is not set
CONFIG_PACKAGE_luci-app-mt5700m=m
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_PACKAGE_mt5700m-transport=m
# CONFIG_PACKAGE_luci-app-qmodem is not set
# CONFIG_PACKAGE_luci-app-qmodem-next is not set
# CONFIG_PACKAGE_qmodem is not set
# CONFIG_PACKAGE_modem_scan is not set
# CONFIG_PACKAGE_tom_modem is not set
EOF
make defconfig
grep -qx "CONFIG_TARGET_${sdk_board}=y" .config
grep -qx "CONFIG_TARGET_${sdk_board}_${sdk_subtarget}=y" .config
package_arch="$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\([^"]*\)"$/\1/p' .config)"
if [ "${package_arch}" != "${expected_arch}" ]; then
  printf 'Unexpected package architecture for %s: %s (expected %s)\n' "${sdk_target}" "${package_arch}" "${expected_arch}" >&2
  exit 1
fi
make package/h5000m-custom/mt5700m-transport/compile -j"$(nproc)" V=s
make package/h5000m-custom/luci-app-mt5700m/compile -j"$(nproc)" V=s

find bin -type f \( -name 'luci-app-mt5700m-*.apk' -o -name 'luci-app-mt5700m_*.ipk' -o -name 'luci-i18n-mt5700m-zh-cn-*.apk' -o -name 'luci-i18n-mt5700m-zh-cn_*.ipk' -o -name 'mt5700m-transport-*.apk' -o -name 'mt5700m-transport_*.ipk' \) -exec cp -f {} "${output_dir}/" \;
test "$(find "${output_dir}" -type f \( -name '*.apk' -o -name '*.ipk' \) | wc -l)" -ge 3
if find "${output_dir}" -name '*.apk' | grep -q .; then
  cp public-key.pem "${output_dir}/openwrt-sdk-build.pem"
  mkdir -p "${work_dir}/verification-keys"
  cp public-key.pem "${work_dir}/verification-keys/build.pem"
  for package in "${output_dir}"/*.apk; do
    # Input is our just-built unsigned package, not a downloaded dependency.
    # Only signing accepts unsigned input; the following verification is strict.
    staging_dir/host/bin/apk adbsign --allow-untrusted --sign-key private-key.pem "$package"
    staging_dir/host/bin/apk --keys-dir "${work_dir}/verification-keys" verify "$package"
  done
fi
printf 'SDK=%s\nSOURCE_COMMIT=%s\nTARGET=%s\nPACKAGE_ARCH=%s\nSDK_URL=%s\n' "${sdk_version}" "$(git -C "${repo_dir}" rev-parse HEAD)" "${sdk_target}" "${package_arch}" "${base_url}/${archive}" > "${output_dir}/BUILD-INFO.txt"
grep "[ *]${archive}$" "${work_dir}/sha256sums" >> "${output_dir}/BUILD-INFO.txt"
(cd "${output_dir}" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
