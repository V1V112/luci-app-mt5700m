#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TRAFFIC="${ROOT}/root/usr/sbin/mt5700m-traffic"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "${FIXTURE}"' EXIT INT TERM

USB_HELPER="${FIXTURE}/usb.sh"
NETDEV_FILE="${FIXTURE}/netdev"
RUNTIME_DIR="${FIXTURE}/runtime"
HISTORY_FILE="${FIXTURE}/traffic-history"

cat > "${USB_HELPER}" <<'EOF'
#!/bin/sh

mt5700m_netdev() {
	cat "${FAKE_NETDEV_FILE:?}"
}
EOF
sed -i 's/\r$//' "${USB_HELPER}"
chmod 0755 "${USB_HELPER}"
printf '%s\n' 'eth1' > "${NETDEV_FILE}"

run_traffic() {
	FAKE_NETDEV_FILE="${NETDEV_FILE}" \
	MT5700M_USB_HELPER="${USB_HELPER}" \
	MT5700M_TRAFFIC_RUNTIME_DIR="${RUNTIME_DIR}" \
	MT5700M_TRAFFIC_HISTORY_FILE="${HISTORY_FILE}" \
		sh "${TRAFFIC}" "$@"
}

output="$(run_traffic json)"
printf '%s\n' "${output}" | grep -q '"name":"eth1"'
if printf '%s\n' "${output}" | grep -q '"name":"eth2"'; then
	echo 'FAIL: traffic collector still used the legacy eth2 default' >&2
	exit 1
fi

run_traffic update eth1 12 34 2026-07-24 10:30
grep -q '^total eth1 12 34$' "${RUNTIME_DIR}/history"

printf '%s\n' 'wwan0' > "${NETDEV_FILE}"
run_traffic update wwan0 5 7 2026-07-24 10:31
output="$(run_traffic json)"
printf '%s\n' "${output}" | grep -q '"name":"wwan0"'
printf '%s\n' "${output}" | grep -q '"name":"eth1"'
grep -q '^total eth1 12 34$' "${RUNTIME_DIR}/history"
grep -q '^total wwan0 5 7$' "${RUNTIME_DIR}/history"

mkdir -p "${RUNTIME_DIR}"
printf '%s\n' '100 200' > "${RUNTIME_DIR}/last-wwan0"
run_traffic reset wwan0
[ ! -e "${RUNTIME_DIR}/last-wwan0" ]

output="$(
	FAKE_NETDEV_FILE="${NETDEV_FILE}" \
	MT5700M_USB_HELPER="${USB_HELPER}" \
	MT5700M_TRAFFIC_INTERFACES='rmnet-test' \
	MT5700M_TRAFFIC_RUNTIME_DIR="${RUNTIME_DIR}" \
	MT5700M_TRAFFIC_HISTORY_FILE="${HISTORY_FILE}" \
		sh "${TRAFFIC}" json
)"
printf '%s\n' "${output}" | grep -q '"name":"rmnet-test"'

UCI_RUNTIME_DIR="${FIXTURE}/uci-runtime"
UCI_HISTORY_FILE="${FIXTURE}/uci-history"
mkdir -p "${FIXTURE}/bin" "${UCI_RUNTIME_DIR}"
cat >"${FIXTURE}/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q get network.MT5700M.device') echo wwan42 ;;
	*) exit 1 ;;
esac
EOF
chmod 0755 "${FIXTURE}/bin/uci"

PATH="${FIXTURE}/bin:${PATH}" \
MT5700M_USB_HELPER="${FIXTURE}/missing-usb.sh" \
MT5700M_TRAFFIC_RUNTIME_DIR="${UCI_RUNTIME_DIR}" \
MT5700M_TRAFFIC_HISTORY_FILE="${UCI_HISTORY_FILE}" \
	sh "${TRAFFIC}" update '' 10 20 2026-07-30 12:00

output="$(PATH="${FIXTURE}/bin:${PATH}" \
	MT5700M_USB_HELPER="${FIXTURE}/missing-usb.sh" \
	MT5700M_TRAFFIC_RUNTIME_DIR="${UCI_RUNTIME_DIR}" \
	MT5700M_TRAFFIC_HISTORY_FILE="${UCI_HISTORY_FILE}" \
	sh "${TRAFFIC}" json)"
printf '%s\n' "${output}" | grep -q '"name":"wwan42"'
printf '%s\n' "${output}" | grep -q '"rx":10'
printf '%s\n' "${output}" | grep -q '"tx":20'

echo 'dynamic traffic interface tests passed'
