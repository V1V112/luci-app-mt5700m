#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
AT_HELPER="${ROOT}/root/usr/sbin/mt5700m-at"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "${FIXTURE}"' EXIT INT TERM

BIN="${FIXTURE}/bin"
USB_HELPER="${FIXTURE}/usb.sh"
READ_HELPER="${FIXTURE}/read-cache"
COMMAND_LOG="${FIXTURE}/commands.log"
TIMEOUT_LOG="${FIXTURE}/timeouts.log"
SIGNAL_READ_LOG="${FIXTURE}/signal-reads.log"
mkdir -p "${BIN}"

cat > "${USB_HELPER}" <<'EOF'
#!/bin/sh

mt5700m_netdev() {
	printf '%s\n' 'eth1'
}
EOF

cat > "${READ_HELPER}" <<'EOF'
#!/bin/sh

[ "$#" -eq 1 ] && [ "$1" = signal ] || exit 64
printf '%s\n' "$1" >> "${FAKE_SIGNAL_READ_LOG:?}"
[ "${FAKE_SIGNAL_MISSING:-0}" != 1 ] || exit 75
printf '%s\n' 'sysmode=NR' 'rsrp=-90' 'sinr=10.0' 'rsrq=-10.0' 'sampled_at=123'
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

cat > "${BIN}/mt5700m-transport" <<'EOF'
#!/bin/sh

timeout=''
while [ "$#" -gt 0 ]; do
	case "$1" in
		-h) [ "$2" = '192.168.8.1' ] || exit 64; shift 2 ;;
		-p) [ "$2" = '20249' ] || exit 64; shift 2 ;;
		-t) timeout="$2"; shift 2 ;;
		at) shift; [ "$#" -eq 1 ] || exit 64; command="$1"; break ;;
		*) exit 64 ;;
	esac
done
printf '%s\n' "${timeout}" >> "${FAKE_TIMEOUT_LOG:?}"
printf '%s\n' "${command}" >> "${FAKE_COMMAND_LOG:?}"
case "${command}" in
	'AT^HFREQINFO?')
		printf '%s\n' '^HFREQINFO: 0,7,78,640000,3500000,100000,640000,3400000,100000' 'OK'
		;;
	'AT^CASCELLINFO?')
		printf '%s\n' '^CASCELLINFO: 0,0,0,0,0,3,1650,1300,19500,18400,5,5' 'OK'
		;;
	'AT^MONSSC')
		printf '%s\n' '^MONSSC: NR,1' 'OK'
		;;
	'AT^MCS=0')
		printf '%s\n' '^MCS: 0,1,0,15,31' '^MCS: 0,0,1,7,29' 'OK'
		;;
	'AT^MCS=1')
		printf '%s\n' '^MCS: 1,1,1,26,30' '^MCS: 1,0,0,18,28' 'OK'
		;;
	*)
		printf '%s\n' 'ERROR'
		exit 1
		;;
esac
EOF

sed -i 's/\r$//' "${USB_HELPER}" "${READ_HELPER}" "${BIN}/uci" "${BIN}/ip" "${BIN}/mt5700m-transport"
chmod 0755 "${USB_HELPER}" "${READ_HELPER}" "${BIN}/uci" "${BIN}/ip" "${BIN}/mt5700m-transport"

run_radio() {
	FAKE_COMMAND_LOG="${COMMAND_LOG}" \
	FAKE_TIMEOUT_LOG="${TIMEOUT_LOG}" \
	FAKE_SIGNAL_READ_LOG="${SIGNAL_READ_LOG}" \
	MT5700M_USB_HELPER="${USB_HELPER}" \
	MT5700M_READ_HELPER="${READ_HELPER}" \
	MT5700M_ACTION_LOCK="${FIXTURE}/action.lock" \
	PATH="${BIN}:${PATH}" \
		sh "${AT_HELPER}" radio-status
}

before="$(date +%s)"
output="$(run_radio)"
after="$(date +%s)"

printf '%s\n' "${output}" | grep -qx 'sysmode=NR'
printf '%s\n' "${output}" | grep -qx 'rsrp=-90'
printf '%s\n' "${output}" | grep -qx 'sinr=10.0'
printf '%s\n' "${output}" | grep -qx 'rsrq=-10.0'
printf '%s\n' "${output}" | grep -qx 'sampled_at=123'
printf '%s\n' "${output}" | grep -qx 'carrier_count=2'
printf '%s\n' "${output}" | grep -qx 'ca_active=1'
printf '%s\n' "${output}" | grep -qx 'dc_active=1'
printf '%s\n' "${output}" | grep -qx 'ca_mode=EN-DC + CA'
printf '%s\n' "${output}" | grep -qx 'carrier_1=NR|n78|640000|3500.00|100.0|640000|3400.00|100.0'
printf '%s\n' "${output}" | grep -qx 'carrier_2=LTE|B3|1300|1840.00|20.0|1650|1950.00|20.0'
printf '%s\n' "${output}" | grep -qx 'ca_dl_bandwidth=120.0'
printf '%s\n' "${output}" | grep -qx 'ca_ul_bandwidth=120.0'
printf '%s\n' "${output}" | grep -qx 'uplink_mcs=0,1,0,15,31|0,0,1,7,29'
printf '%s\n' "${output}" | grep -qx 'downlink_mcs=1,1,1,26,30|1,0,0,18,28'

[ "$(wc -l < "${COMMAND_LOG}" | tr -d ' ')" = '5' ]
! grep -q 'AT\^HCSQ?' "${COMMAND_LOG}"
grep -qx 'AT^HFREQINFO?' "${COMMAND_LOG}"
grep -qx 'AT^CASCELLINFO?' "${COMMAND_LOG}"
grep -qx 'AT^MONSSC' "${COMMAND_LOG}"
grep -qx 'AT^MCS=0' "${COMMAND_LOG}"
grep -qx 'AT^MCS=1' "${COMMAND_LOG}"
[ "$(wc -l < "${TIMEOUT_LOG}" | tr -d ' ')" = '5' ]
if grep -vx '2' "${TIMEOUT_LOG}"; then
	echo 'FAIL: radio refresh did not cap an AT request at two seconds' >&2
	exit 1
fi

stamp="$(printf '%s\n' "${output}" | sed -n 's/^snapshot_at=//p')"
case "${stamp}" in ''|*[!0-9]*) echo 'FAIL: radio snapshot timestamp is missing' >&2; exit 1 ;; esac
[ "${stamp}" -ge "${before}" ] && [ "${stamp}" -le "${after}" ]
[ "$(printf '%s\n' "${output}" | tail -n 1)" = "snapshot_at=${stamp}" ]

# A missing collector snapshot must not suppress the independent carrier/MCS
# query batch or cause a fallback HCSQ query.
: > "${COMMAND_LOG}"
: > "${TIMEOUT_LOG}"
output="$(FAKE_SIGNAL_MISSING=1 run_radio)"
! printf '%s\n' "${output}" | grep -q '^sysmode='
printf '%s\n' "${output}" | grep -qx 'carrier_count=2'
printf '%s\n' "${output}" | grep -qx 'uplink_mcs=0,1,0,15,31|0,0,1,7,29'
printf '%s\n' "${output}" | grep -qx 'downlink_mcs=1,1,1,26,30|1,0,0,18,28'
printf '%s\n' "${output}" | tail -n 1 | grep -Eq '^snapshot_at=[0-9]+$'
[ "$(wc -l < "${COMMAND_LOG}" | tr -d ' ')" = '5' ]
! grep -q 'AT\^HCSQ?' "${COMMAND_LOG}"
[ "$(wc -l < "${SIGNAL_READ_LOG}" | tr -d ' ')" = '2' ]

echo 'radio refresh tests passed: shared signal cache, five bounded carrier/MCS queries, backend timestamp and cold-cache fallback'
