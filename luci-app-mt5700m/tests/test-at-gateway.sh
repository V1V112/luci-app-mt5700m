#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
AT_HELPER="${ROOT}/root/usr/sbin/mt5700m-at"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "${FIXTURE}"' EXIT INT TERM

BIN="${FIXTURE}/bin"
USB_HELPER="${FIXTURE}/usb.sh"
NC_LOG="${FIXTURE}/nc.log"
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
	mt5700m.settings.timeout) printf '%s\n' '2' ;;
	*) exit 1 ;;
esac
EOF

cat > "${BIN}/ip" <<'EOF'
#!/bin/sh

[ "$*" = '-4 route show default' ] || exit 1
printf '%s\n' \
	'default via 198.51.100.1 dev eth9 metric 10' \
	'default via 10.23.0.1 dev eth1 metric 50'
EOF

cat > "${BIN}/nc" <<'EOF'
#!/bin/sh

printf '%s %s\n' "${1:-}" "${2:-}" >> "${FAKE_NC_LOG:?}"
cat >/dev/null
printf '%s\n' 'OK'
EOF

cat > "${BIN}/timeout" <<'EOF'
#!/bin/sh

shift
exec "$@"
EOF

sed -i 's/\r$//' "${USB_HELPER}" "${BIN}/uci" "${BIN}/ip" "${BIN}/nc" "${BIN}/timeout"
chmod 0755 "${USB_HELPER}" "${BIN}/uci" "${BIN}/ip" "${BIN}/nc" "${BIN}/timeout"

FAKE_NC_LOG="${NC_LOG}" \
MT5700M_USB_HELPER="${USB_HELPER}" \
PATH="${BIN}:${PATH}" \
	sh "${AT_HELPER}" command AT >/dev/null

grep -qx '10.23.0.1 20249' "${NC_LOG}"
if grep -q '^198\.51\.100\.1 ' "${NC_LOG}"; then
	echo 'FAIL: AT gateway detection selected another WAN interface' >&2
	exit 1
fi

echo 'AT gateway tests passed'
