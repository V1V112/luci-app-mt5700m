#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
AT_HELPER="${ROOT}/root/usr/sbin/mt5700m-at"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "${FIXTURE}"' EXIT INT TERM

BIN="${FIXTURE}/bin"
USB_HELPER="${FIXTURE}/usb.sh"
COMMAND_LOG="${FIXTURE}/commands.log"
TIMEOUT_LOG="${FIXTURE}/timeouts.log"
mkdir -p "${BIN}"

cat > "${USB_HELPER}" <<'EOF'
#!/bin/sh

mt5700m_netdev() {
	printf '%s\n' 'eth1'
}
EOF

cat > "${BIN}/uci" <<'EOF'
#!/bin/sh

[ "${1:-}" != '-q' ] || shift
[ "${1:-}" = 'get' ] || exit 1
case "${2:-}" in
	mt5700m.settings.enabled) printf '%s\n' '1' ;;
	mt5700m.settings.mode) printf '%s\n' 'network' ;;
	mt5700m.settings.at_port) printf '%s\n' '' ;;
	mt5700m.settings.host) printf '%s\n' '192.168.8.1' ;;
	mt5700m.settings.port) printf '%s\n' '20249' ;;
	mt5700m.settings.timeout) printf '%s\n' '8' ;;
	*) exit 1 ;;
esac
EOF

cat > "${BIN}/ip" <<'EOF'
#!/bin/sh

[ "$*" = '-4 route show default' ] || exit 1
printf '%s\n' 'default via 10.23.0.1 dev eth1 metric 50'
EOF

cat > "${BIN}/nc" <<'EOF'
#!/bin/sh

command="$(cat | tr -d '\r\n')"
printf '%s\n' "${command}" >> "${FAKE_COMMAND_LOG:?}"
case "${command}" in
	'AT^HCSQ?')
		printf '%s\n' '^HCSQ: "NR",51,151,20' 'OK'
		;;
	'AT^HFREQINFO?')
		printf '%s\n' '^HFREQINFO: 0,7,78,640000,3500000,100000,640000,3400000,100000' 'OK'
		;;
	'AT^CASCELLINFO?')
		printf '%s\n' '^CASCELLINFO: 0,0,0,0,0,3,1650,1300,19500,18400,5,5' 'OK'
		;;
	'AT^MONSSC')
		printf '%s\n' '^MONSSC: NR,1' 'OK'
		;;
	*)
		printf '%s\n' 'ERROR'
		exit 1
		;;
esac
EOF

cat > "${BIN}/timeout" <<'EOF'
#!/bin/sh

printf '%s\n' "${1:-}" >> "${FAKE_TIMEOUT_LOG:?}"
shift
exec "$@"
EOF

sed -i 's/\r$//' "${USB_HELPER}" "${BIN}/uci" "${BIN}/ip" "${BIN}/nc" "${BIN}/timeout"
chmod 0755 "${USB_HELPER}" "${BIN}/uci" "${BIN}/ip" "${BIN}/nc" "${BIN}/timeout"

output="$(
	FAKE_COMMAND_LOG="${COMMAND_LOG}" \
	FAKE_TIMEOUT_LOG="${TIMEOUT_LOG}" \
	MT5700M_USB_HELPER="${USB_HELPER}" \
	PATH="${BIN}:${PATH}" \
		sh "${AT_HELPER}" radio-status
)"

printf '%s\n' "${output}" | grep -qx 'sysmode=NR'
printf '%s\n' "${output}" | grep -qx 'rsrp=-90'
printf '%s\n' "${output}" | grep -qx 'sinr=10.0'
printf '%s\n' "${output}" | grep -qx 'rsrq=-10.0'
printf '%s\n' "${output}" | grep -qx 'carrier_count=2'
printf '%s\n' "${output}" | grep -qx 'ca_active=1'
printf '%s\n' "${output}" | grep -qx 'dc_active=1'
printf '%s\n' "${output}" | grep -qx 'ca_mode=EN-DC + CA'
printf '%s\n' "${output}" | grep -qx 'ca_dl_bandwidth=120.0'
printf '%s\n' "${output}" | grep -qx 'ca_ul_bandwidth=120.0'

[ "$(wc -l < "${COMMAND_LOG}" | tr -d ' ')" = '4' ]
grep -qx 'AT^HCSQ?' "${COMMAND_LOG}"
grep -qx 'AT^HFREQINFO?' "${COMMAND_LOG}"
grep -qx 'AT^CASCELLINFO?' "${COMMAND_LOG}"
grep -qx 'AT^MONSSC' "${COMMAND_LOG}"
[ "$(wc -l < "${TIMEOUT_LOG}" | tr -d ' ')" = '4' ]
if grep -vx '2' "${TIMEOUT_LOG}"; then
	echo 'FAIL: radio refresh did not cap an AT request at two seconds' >&2
	exit 1
fi

echo 'radio refresh tests passed'
