#!/usr/bin/env bash
# Exercise the real release script without downloading an SDK or compiling.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/mt5700m-build-test.XXXXXX")"
test_tmp="$(cd "$test_tmp" && pwd)"
cleanup() {
  case "$test_tmp" in
    /*/mt5700m-build-test.*) rm -rf -- "$test_tmp" ;;
    *) printf 'Refusing to remove unexpected test directory: %s\n' "$test_tmp" >&2 ;;
  esac
}
trap cleanup EXIT
test_repo="$test_tmp/repo"
fake_bin="$test_tmp/bin"
run_log="$test_tmp/build.log"
trace="$test_tmp/trace"
mkdir -p "$test_repo/scripts" "$test_repo/luci-app-mt5700m" "$test_repo/mt5700m-transport" "$fake_bin" "$test_tmp/runner"
cp "$repo_dir/scripts/build-release.sh" "$test_repo/scripts/"
printf 'fixture\n' > "$test_repo/luci-app-mt5700m/Makefile"
printf 'fixture\n' > "$test_repo/mt5700m-transport/Makefile"
git -C "$test_repo" init -q
git -C "$test_repo" -c core.autocrlf=false add .
git -C "$test_repo" -c user.name='Build Test' -c user.email='build-test@example.invalid' commit -qm fixture
source_commit="$(git -C "$test_repo" rev-parse HEAD)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [ -f "$run_log" ]; then cat "$run_log" >&2; fi
  exit 1
}
assert_equal() {
  [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"
}

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
arguments="$*"
url=''
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    --retry|--retry-delay|--connect-timeout|--max-time|--speed-time|--speed-limit|--continue-at) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf 'curl\t%s\t%s\t%s\t%s\n' "$FAKE_EXPECT_VERSION" "$FAKE_EXPECT_TARGET" "$url" "$arguments" >> "$FAKE_TRACE"
base_url="https://downloads.openwrt.org/releases/${FAKE_EXPECT_VERSION}/targets/${FAKE_EXPECT_TARGET}"
archive="openwrt-sdk-${FAKE_EXPECT_VERSION}-${FAKE_EXPECT_TARGET//\//-}_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
payload="fixture SDK ${FAKE_EXPECT_VERSION} ${FAKE_EXPECT_TARGET}"
case "$url" in
  "$base_url/sha256sums")
    checksum="$(printf '%s\n' "$payload" | sha256sum | cut -d ' ' -f 1)"
    {
      printf '%s  %s\n' "$checksum" 'openwrt-sdk-0.0.0-unrelated_gcc_musl.Linux-x86_64.tar.zst'
      printf '%s  %s\n' "$checksum" "$archive"
    } > "${output:-sha256sums}"
    ;;
  "$base_url/$archive")
    [[ "$output" = */"$archive.part" ]]
    [[ "$arguments" = *'--retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 20'* ]]
    [[ "$arguments" = *'--speed-time 60 --speed-limit 1024 --continue-at -'* ]]
    if [ -f "$output" ]; then
      prefix="$(cat "$output")"
      [[ "$payload" = "$prefix"* ]] || { printf 'Invalid prefix reached curl resume\n' >&2; exit 1; }
      printf 'curl-resume\t%s\t%s\n' "$FAKE_EXPECT_VERSION" "$FAKE_EXPECT_TARGET" >> "$FAKE_TRACE"
    fi
    if [ "${FAKE_CURL_FAIL_ONCE:-0}" = 1 ] && [ ! -f "$FAKE_CURL_FAIL_MARK" ]; then
      printf 'fixture SDK' > "$output"
      touch "$FAKE_CURL_FAIL_MARK"
      exit 18
    fi
    if [ "${FAKE_CORRUPT_ARCHIVE:-0}" = 1 ]; then payload='corrupt SDK'; fi
    printf '%s\n' "$payload" > "$output"
    ;;
  *) printf 'Unexpected SDK download: %s\n' "$url" >&2; exit 1 ;;
esac
EOF

cat > "$fake_bin/aria2c" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
arguments="$*"
directory=''
output=''
url=''
for argument in "$@"; do
  case "$argument" in
    --dir=*) directory="${argument#*=}" ;;
    --out=*) output="${argument#*=}" ;;
    --*) ;;
    *) url="$argument" ;;
  esac
done
archive="openwrt-sdk-${FAKE_EXPECT_VERSION}-${FAKE_EXPECT_TARGET//\//-}_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
[ "$url" = "https://downloads.openwrt.org/releases/${FAKE_EXPECT_VERSION}/targets/${FAKE_EXPECT_TARGET}/${archive}" ]
[ "$output" = "$archive.part" ]
[[ "$directory" = */"${FAKE_EXPECT_VERSION}-${FAKE_EXPECT_TARGET//\//-}" ]]
[[ "$arguments" = *'--continue=true --allow-overwrite=true --auto-file-renaming=false'* ]]
[[ "$arguments" = *'--max-connection-per-server=4 --split=4 --min-split-size=20M --file-allocation=none'* ]]
[[ "$arguments" = *'--max-tries=5 --retry-wait=2 --connect-timeout=20 --timeout=60 --summary-interval=10'* ]]
printf 'aria2\t%s\t%s\t%s\n' "$FAKE_EXPECT_VERSION" "$FAKE_EXPECT_TARGET" "$arguments" >> "$FAKE_TRACE"
if [ "${FAKE_ARIA2_FAIL:-0}" = 1 ]; then
  printf 'noncontiguous chunks cannot be resumed by curl\n' > "$directory/$output"
  printf 'aria2 control data\n' > "$directory/$output.aria2"
  exit 1
fi
payload="fixture SDK ${FAKE_EXPECT_VERSION} ${FAKE_EXPECT_TARGET}"
if [ "${FAKE_CORRUPT_ARCHIVE:-0}" = 1 ]; then payload='corrupt SDK'; fi
printf '%s\n' "$payload" > "$directory/$output"
EOF

cat > "$fake_bin/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
archive="${!#}"
[ "$(cat "$archive")" = "fixture SDK ${FAKE_EXPECT_VERSION} ${FAKE_EXPECT_TARGET}" ]
sdk_dir="$(basename "${archive%.tar.zst}")"
printf 'extract\t%s\t%s\t%s\n' "$FAKE_EXPECT_VERSION" "$FAKE_EXPECT_TARGET" "$PWD" >> "$FAKE_TRACE"
# A leftover extraction must never be selected by find | head.
mkdir -p openwrt-sdk-000000-stale/scripts
printf '#!/bin/sh\necho "Selected stale SDK" >&2\nexit 99\n' > openwrt-sdk-000000-stale/scripts/feeds
chmod +x openwrt-sdk-000000-stale/scripts/feeds
mkdir -p "$sdk_dir/scripts" "$sdk_dir/staging_dir/host/bin"
cp "$FAKE_BIN/feeds" "$sdk_dir/scripts/feeds"
cp "$FAKE_BIN/apk" "$sdk_dir/staging_dir/host/bin/apk"
printf '%s\n' "$FAKE_EXPECT_VERSION" "$FAKE_EXPECT_TARGET" > "$sdk_dir/fixture-sdk"
cat > "$sdk_dir/Config.in" <<'CONFIG'
config ALL
	bool "Select all userspace packages by default"
	default y
CONFIG
cat > "$sdk_dir/Config-build.in" <<'CONFIG'
config TARGET_MULTI_PROFILE
	bool
	default y
config TARGET_ALL_PROFILES
	bool
	default y
config TARGET_DEVICE_mediatek_filogic_DEVICE_fixture
	bool
	default y
config TARGET_DEVICE_rockchip_armv8_DEVICE_fixture
	bool
	default y
config PACKAGE_fixture
	tristate
	default m
CONFIG
printf 'fixture public key\n' > "$sdk_dir/public-key.pem"
printf 'fixture private key\n' > "$sdk_dir/private-key.pem"
EOF

cat > "$fake_bin/feeds" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'feeds\t%s\t%s\t%s\n' "$FAKE_EXPECT_VERSION" "$FAKE_EXPECT_TARGET" "$*" >> "$FAKE_TRACE"
case "$*" in 'update -a'|'install luci-base') ;; *) exit 1 ;; esac
[ "$(sed -n '1p' fixture-sdk)" = "$FAKE_EXPECT_VERSION" ]
[ "$(sed -n '2p' fixture-sdk)" = "$FAKE_EXPECT_TARGET" ]
EOF

cat > "$fake_bin/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'make\t%s\t%s\t%s\n' "$FAKE_EXPECT_VERSION" "$FAKE_EXPECT_TARGET" "$*" >> "$FAKE_TRACE"
[ "$(sed -n '1p' fixture-sdk)" = "$FAKE_EXPECT_VERSION" ]
[ "$(sed -n '2p' fixture-sdk)" = "$FAKE_EXPECT_TARGET" ]
board="${FAKE_EXPECT_TARGET%/*}"
subtarget="${FAKE_EXPECT_TARGET#*/}"
grep -qx "CONFIG_TARGET_${board}=y" .config
grep -qx "CONFIG_TARGET_${board}_${subtarget}=y" .config
[ "$(grep -c '^CONFIG_TARGET_.*=y$' .config)" -eq 2 ]
case "$board" in
  mediatek) arch=aarch64_cortex-a53; other=rockchip_armv8 ;;
  rockchip) arch=aarch64_generic; other=mediatek_filogic ;;
  *) exit 1 ;;
esac
if [ "$1" = defconfig ]; then
  # Match entire config blocks so an unrelated default cannot hide a failure.
  perl -0777 -ne 'exit !/config ALL\n\s+bool "Select all userspace packages by default"\n\s+default n/' Config.in
  for symbol in TARGET_MULTI_PROFILE TARGET_ALL_PROFILES "TARGET_DEVICE_${board}_${subtarget}_DEVICE_fixture"; do
    SYMBOL="$symbol" perl -0777 -ne 'exit !/config \Q$ENV{SYMBOL}\E\n\s+bool\n\s+default n/' Config-build.in
  done
  SYMBOL="TARGET_DEVICE_${other}_DEVICE_fixture" perl -0777 -ne 'exit !/config \Q$ENV{SYMBOL}\E\n\s+bool\n\s+default y/' Config-build.in
  ! grep -q 'default m$' Config-build.in
  printf 'CONFIG_TARGET_ARCH_PACKAGES="%s"\n' "${FAKE_ARCH_OVERRIDE:-$arch}" >> .config
  exit 0
fi
[ -f package/h5000m-custom/luci-app-mt5700m/Makefile ]
[ -f package/h5000m-custom/mt5700m-transport/Makefile ]
case "$FAKE_EXPECT_VERSION" in 24.10.*) format=ipk ;; 25.12.*) format=apk ;; *) exit 1 ;; esac
mkdir -p "bin/packages/$arch/custom"
write_package() {
  name="$1"; package_arch="$2"
  if [ "$format" = ipk ]; then filename="${name}_1.0-r1_${package_arch}.ipk"; else filename="${name}-1.0-r1.apk"; fi
  printf 'TARGET=%s\nPACKAGE_ARCH=%s\n' "$FAKE_EXPECT_TARGET" "$package_arch" > "bin/packages/$arch/custom/$filename"
}
case "$1" in
  package/h5000m-custom/mt5700m-transport/compile) write_package mt5700m-transport "$arch" ;;
  package/h5000m-custom/luci-app-mt5700m/compile)
    write_package luci-app-mt5700m all
    write_package luci-i18n-mt5700m-zh-cn all
    ;;
  *) printf 'Unexpected make invocation: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

cat > "$fake_bin/apk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'apk\t%s\t%s\t%s\n' "$FAKE_EXPECT_VERSION" "$FAKE_EXPECT_TARGET" "$*" >> "$FAKE_TRACE"
package="${!#}"
case "$1" in
  adbsign)
    [ "$#" -eq 5 ]
    [ "$2" = --allow-untrusted ]
    [ "$3" = --sign-key ]
    [ "$(cat "$4")" = 'fixture private key' ]
    printf 'SIGNED\n' >> "$package"
    ;;
  --keys-dir)
    [ "$#" -eq 4 ]
    [ "$3" = verify ]
    [ "$(cat "$2/build.pem")" = 'fixture public key' ]
    grep -qx SIGNED "$package"
    ;;
  *) printf 'Unexpected APK invocation: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$fake_bin/"*

export PATH="$fake_bin:$PATH"
export RUNNER_TEMP="$test_tmp/runner"
export FAKE_TRACE="$trace" FAKE_BIN="$fake_bin"
output_dir="$test_repo/dist-release"
mkdir -p "$RUNNER_TEMP/mt5700m-sdk/openwrt-sdk-000000-legacy/scripts" "$output_dir"
printf '#!/bin/sh\nexit 99\n' > "$RUNNER_TEMP/mt5700m-sdk/openwrt-sdk-000000-legacy/scripts/feeds"
chmod +x "$RUNNER_TEMP/mt5700m-sdk/openwrt-sdk-000000-legacy/scripts/feeds"

for sdk_version in 24.10.8 25.12.6; do
  for sdk_target in mediatek/filogic rockchip/armv8; do
    export SDK_VERSION="$sdk_version" SDK_TARGET="$sdk_target"
    export FAKE_EXPECT_VERSION="$sdk_version" FAKE_EXPECT_TARGET="$sdk_target"
    printf 'previous build\n' > "$output_dir/stale-output.ipk"
    if ! bash "$test_repo/scripts/build-release.sh" > "$run_log" 2>&1; then
      fail "release script failed for $sdk_version $sdk_target"
    fi
    case "$sdk_version" in 24.10.*) format=ipk; other_format=apk ;; *) format=apk; other_format=ipk ;; esac
    case "$sdk_target" in mediatek/*) package_arch=aarch64_cortex-a53 ;; *) package_arch=aarch64_generic ;; esac
    assert_equal "$(find "$output_dir" -maxdepth 1 -name "*.$format" | wc -l | tr -d '[:space:]')" 3 'three release packages'
    assert_equal "$(find "$output_dir" -maxdepth 1 -name "*.$other_format" | wc -l | tr -d '[:space:]')" 0 'old package format removed'
    [ ! -e "$output_dir/stale-output.ipk" ] || fail 'stale release output was retained'
    for package in "$output_dir/"*."$format"; do
      grep -qx "TARGET=$sdk_target" "$package" || fail 'wrong target package copied'
    done
    if [ "$format" = ipk ]; then
      transport_package="$output_dir/mt5700m-transport_1.0-r1_${package_arch}.ipk"
      [ ! -e "$output_dir/openwrt-sdk-build.pem" ] || fail 'APK key leaked into IPK output'
    else
      transport_package="$output_dir/mt5700m-transport-1.0-r1.apk"
      cmp "$output_dir/openwrt-sdk-build.pem" <(printf 'fixture public key\n') || fail 'APK public key missing'
      assert_equal "$(grep -c $'^apk\t'"$sdk_version"$'\t'"$sdk_target"$'\tadbsign ' "$trace")" 3 'all APKs signed'
      assert_equal "$(grep $'^apk\t'"$sdk_version"$'\t'"$sdk_target"$'\t--keys-dir ' "$trace" | grep -c ' verify ')" 3 'all APK signatures verified'
      for package in "$output_dir/"*.apk; do grep -qx SIGNED "$package" || fail 'unsigned APK copied'; done
    fi
    grep -qx "PACKAGE_ARCH=$package_arch" "$transport_package" || fail 'wrong transport architecture'
    grep -qx "SDK=$sdk_version" "$output_dir/BUILD-INFO.txt" || fail 'SDK metadata missing'
    grep -qx "SOURCE_COMMIT=$source_commit" "$output_dir/BUILD-INFO.txt" || fail 'source commit metadata missing'
    grep -qx "TARGET=$sdk_target" "$output_dir/BUILD-INFO.txt" || fail 'target metadata missing'
    grep -qx "PACKAGE_ARCH=$package_arch" "$output_dir/BUILD-INFO.txt" || fail 'architecture metadata missing'
    archive="openwrt-sdk-${sdk_version}-${sdk_target//\//-}_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
    checksum="$(printf 'fixture SDK %s %s\n' "$sdk_version" "$sdk_target" | sha256sum | cut -d ' ' -f 1)"
    cache_dir="$RUNNER_TEMP/mt5700m-sdk-downloads/${sdk_version}-${sdk_target//\//-}"
    [ -f "$cache_dir/$archive" ] || fail 'verified SDK archive was not cached'
    [ ! -e "$cache_dir/$archive.part" ] || fail 'completed SDK retained partial download'
    assert_equal "$(find "$cache_dir" -type f | wc -l | tr -d '[:space:]')" 1 'only verified compressed SDK is cached'
    grep -qx "$checksum  $archive" "$output_dir/BUILD-INFO.txt" || fail 'SDK checksum metadata missing'
    grep -qx "SDK_URL=https://downloads.openwrt.org/releases/${sdk_version}/targets/${sdk_target}/${archive}" "$output_dir/BUILD-INFO.txt" || fail 'SDK source URL metadata missing'
    (cd "$output_dir" && sha256sum -c SHA256SUMS) > /dev/null || fail 'release checksums invalid'
    expected_files=4
    [ "$format" = ipk ] || expected_files=5
    assert_equal "$(wc -l < "$output_dir/SHA256SUMS" | tr -d '[:space:]')" "$expected_files" 'all output files checksummed'
  done
done
assert_equal "$(awk -F '\t' '$1 == "extract" { print $4 }' "$trace" | sort -u | wc -l | tr -d '[:space:]')" 4 'SDK version and target work directories isolated'
assert_equal "$(grep -c $'^aria2\t' "$trace")" 4 'four independent SDK archive downloads'
manifest_count="$(awk -F '\t' '$1 == "curl" && $4 ~ /\/sha256sums$/ { count++ } END { print count + 0 }' "$trace")"

# Existing callers keep the same default SDK version and target.
# A valid cached archive avoids another SDK download but rechecks official sums.
unset SDK_VERSION SDK_TARGET
export FAKE_EXPECT_VERSION=25.12.6 FAKE_EXPECT_TARGET=mediatek/filogic
if ! bash "$test_repo/scripts/build-release.sh" > "$run_log" 2>&1; then fail 'default release build failed'; fi
grep -qx 'SDK=25.12.6' "$output_dir/BUILD-INFO.txt" || fail 'default SDK changed'
grep -qx 'TARGET=mediatek/filogic' "$output_dir/BUILD-INFO.txt" || fail 'default target changed'
grep -q 'Reusing cached SDK (official SHA256 verified)' "$run_log" || fail 'verified SDK cache hit was not logged'
assert_equal "$(grep -c $'^aria2\t' "$trace")" 4 'cache hit did not redownload SDK with aria2'
assert_equal "$(awk -F '\t' '$1 == "curl" && $4 ~ /\.tar\.zst$/ { count++ } END { print count + 0 }' "$trace")" 0 'cache hit did not redownload SDK with curl'
assert_equal "$(awk -F '\t' '$1 == "curl" && $4 ~ /\/sha256sums$/ { count++ } END { print count + 0 }' "$trace")" "$((manifest_count + 1))" 'cache hit fetched current official checksums'

# A damaged cached archive is replaced. Noncontiguous aria2 data must be removed
# before curl fallback, and failed curl resume must retry from a clean file.
archive='openwrt-sdk-25.12.6-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst'
cache_dir="$RUNNER_TEMP/mt5700m-sdk-downloads/25.12.6-mediatek-filogic"
printf 'damaged cached SDK\n' > "$cache_dir/$archive"
export FAKE_ARIA2_FAIL=1 FAKE_CURL_FAIL_ONCE=1 FAKE_CURL_FAIL_MARK="$test_tmp/curl-failed-once"
if ! bash "$test_repo/scripts/build-release.sh" > "$run_log" 2>&1; then fail 'damaged SDK cache recovery failed'; fi
grep -q 'Cached SDK failed SHA256 verification' "$run_log" || fail 'damaged cache was not identified'
grep -q 'Parallel SDK download failed; retrying with curl' "$run_log" || fail 'parallel download failure did not fall back to curl'
grep -q 'SDK resume failed; retrying curl from the beginning' "$run_log" || fail 'curl failure did not restart the download'
assert_equal "$(cat "$cache_dir/$archive")" 'fixture SDK 25.12.6 mediatek/filogic' 'damaged SDK was replaced with verified archive'
[ ! -e "$cache_dir/$archive.part" ] && [ ! -e "$cache_dir/$archive.part.aria2" ] || fail 'parallel download leftovers were retained'
unset FAKE_ARIA2_FAIL FAKE_CURL_FAIL_ONCE

# A sequential partial from an interrupted curl download is resumed unchanged.
rm -f "$cache_dir/$archive"
printf 'fixture SDK 25.12.6' > "$cache_dir/$archive.part"
parallel_count="$(grep -c $'^aria2\t' "$trace")"
if ! bash "$test_repo/scripts/build-release.sh" > "$run_log" 2>&1; then fail 'partial SDK resume failed'; fi
assert_equal "$(grep -c $'^aria2\t' "$trace")" "$parallel_count" 'curl partial did not start a new parallel download'
assert_equal "$(grep -c $'^curl-resume\t' "$trace")" 1 'curl resumed the existing sequential prefix'
assert_equal "$(cat "$cache_dir/$archive")" 'fixture SDK 25.12.6 mediatek/filogic' 'resumed SDK was verified before caching'

# A mismatching SDK architecture must stop before either package compile.
compile_count="$(grep -c $'^make\t.*\tpackage/' "$trace")"
export SDK_VERSION=25.12.6 SDK_TARGET=rockchip/armv8
export FAKE_EXPECT_VERSION="$SDK_VERSION" FAKE_EXPECT_TARGET="$SDK_TARGET" FAKE_ARCH_OVERRIDE=aarch64_cortex-a53
if bash "$test_repo/scripts/build-release.sh" > "$run_log" 2>&1; then fail 'wrong SDK architecture was accepted'; fi
assert_equal "$(grep -c $'^make\t.*\tpackage/' "$trace")" "$compile_count" 'wrong architecture rejected before compilation'
unset FAKE_ARCH_OVERRIDE

# Checksum failures must stop before extraction or build.
extract_count="$(grep -c $'^extract\t' "$trace")"
export SDK_VERSION=25.12.6 SDK_TARGET=rockchip/armv8
export FAKE_EXPECT_VERSION="$SDK_VERSION" FAKE_EXPECT_TARGET="$SDK_TARGET" FAKE_CORRUPT_ARCHIVE=1
rm -f "$RUNNER_TEMP/mt5700m-sdk-downloads/25.12.6-rockchip-armv8/"*.tar.zst
if bash "$test_repo/scripts/build-release.sh" > "$run_log" 2>&1; then fail 'corrupt SDK was accepted'; fi
assert_equal "$(grep -c $'^extract\t' "$trace")" "$extract_count" 'corrupt SDK rejected before extraction'
[ -z "$(find "$RUNNER_TEMP/mt5700m-sdk-downloads/25.12.6-rockchip-armv8" -type f -print -quit)" ] || fail 'corrupt SDK retained in download cache'
unset FAKE_CORRUPT_ARCHIVE

# Invalid targets must fail before downloads and before clearing existing output.
mkdir -p "$output_dir"
printf 'keep existing artifacts\n' > "$output_dir/preserve-me.ipk"
trace_before="$(sha256sum "$trace")"
for invalid_target in rockchip mediatek/armv8 rockchip/armv8/extra ../rockchip/armv8; do
  export SDK_TARGET="$invalid_target"
  if bash "$test_repo/scripts/build-release.sh" > "$run_log" 2>&1; then fail "invalid target accepted: $invalid_target"; fi
  assert_equal "$(cat "$output_dir/preserve-me.ipk")" 'keep existing artifacts' 'invalid target preserved release output'
  assert_equal "$(sha256sum "$trace")" "$trace_before" 'invalid target failed before external commands'
done

printf 'PASS: offline SDK matrix, verified archive cache, parallel download, curl fallback/resume/retry, target config, architecture, isolation, checksums, APK signing and invalid-target safety\n'
