#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MANAGER="${ROOT}/root/usr/sbin/mt5700m-manager"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "${FIXTURE}"' EXIT INT TERM

BIN="${FIXTURE}/bin"
UCI_DB="${FIXTURE}/uci.db"
UCI_LOG="${FIXTURE}/uci.log"
COMMAND_LOG="${FIXTURE}/commands.log"
USB_HELPER="${FIXTURE}/usb.sh"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

mkdir -p "${BIN}" "${FIXTURE}/state"
: > "${UCI_LOG}"
: > "${COMMAND_LOG}"

cat > "${UCI_DB}" <<'EOF'
network.loopback=interface
network.loopback.device=lo
network.loopback.proto=static
network.lan=interface
network.lan.device=br-lan
network.lan.proto=static
network.Modem_v4=interface
network.Modem_v4.proto=dhcp
network.Modem_v4.device=eth1
network.Modem_v4.peerdns=0
network.Modem_v6=interface
network.Modem_v6.proto=dhcpv6
network.Modem_v6.device=@Modem_v4
network.Modem_v6.auto=0
network.Modem_v6.extendprefix=1
network.MT5700M=interface
network.MT5700M.managed_by=mt5700m
network.MT5700M.proto=dhcp
network.MT5700M.device=eth1
network.MT5700M.ifname=eth1
network.MT5700Mv6=interface
network.MT5700Mv6.managed_by=mt5700m
network.MT5700Mv6.proto=dhcpv6
network.MT5700Mv6.device=@MT5700M
network.MT5700Mv6.ifname=@MT5700M
network.MT5700Mv6.auto=0
mt5700m.connection=connection
mt5700m.connection.enabled=1
mt5700m.connection.pdp_type=ipv4v6
mt5700m.connection.metric=50
h5000m_netmode.settings=settings
h5000m_netmode.settings.mode=wan_first
h5000m_netmode.settings.ipv6_owner=wan
firewall.wan=zone
firewall.wan.name=wan
firewall.wan.network=MT5700M MT5700Mv6
EOF

cat > "${BIN}/uci" <<'EOF'
#!/bin/sh

set -eu

db="${FAKE_UCI_DB:?}"
log="${FAKE_UCI_LOG:?}"

[ "${1:-}" != '-q' ] || shift
action="${1:-}"
[ "$#" -eq 0 ] || shift

get_value() {
	awk -F= -v key="$1" '
		$1 == key {
			print substr($0, length($1) + 2)
			found = 1
		}
		END { if (!found) exit 1 }
	' "${db}"
}

set_value() {
	key="$1"
	value="$2"
	tmp="${db}.$$"
	awk -F= -v key="${key}" -v value="${value}" '
		$1 == key {
			if (!found)
				print key "=" value
			found = 1
			next
		}
		{ print }
		END {
			if (!found)
				print key "=" value
		}
	' "${db}" > "${tmp}"
	mv "${tmp}" "${db}"
}

case "${action}" in
	get)
		get_value "${1:?}"
		;;
	show)
		prefix="${1:-}"
		while IFS='=' read -r key value; do
			if [ -n "${prefix}" ]; then
				case "${key}" in
					"${prefix}"|"${prefix}".*) ;;
					*) continue ;;
				esac
			fi
			case "${key#*.}" in
				*.*) printf "%s='%s'\n" "${key}" "${value}" ;;
				*) printf '%s=%s\n' "${key}" "${value}" ;;
			esac
		done < "${db}"
		;;
	set)
		assignment="${1:?}"
		key="${assignment%%=*}"
		value="${assignment#*=}"
		set_value "${key}" "${value}"
		printf 'set %s=%s\n' "${key}" "${value}" >> "${log}"
		;;
	delete)
		key="${1:?}"
		tmp="${db}.$$"
		awk -F= -v key="${key}" '
			$1 != key && index($1, key ".") != 1 { print }
		' "${db}" > "${tmp}"
		mv "${tmp}" "${db}"
		printf 'delete %s\n' "${key}" >> "${log}"
		;;
	add_list)
		assignment="${1:?}"
		key="${assignment%%=*}"
		value="${assignment#*=}"
		current="$(get_value "${key}" 2>/dev/null || true)"
		case " ${current} " in
			*" ${value} "*) ;;
			*)
				[ -z "${current}" ] || value="${current} ${value}"
				set_value "${key}" "${value}"
				;;
		esac
		printf 'add_list %s=%s\n' "${key}" "${assignment#*=}" >> "${log}"
		;;
	del_list)
		assignment="${1:?}"
		key="${assignment%%=*}"
		value="${assignment#*=}"
		current="$(get_value "${key}" 2>/dev/null || true)"
		remaining=''
		for item in ${current}; do
			[ "${item}" = "${value}" ] && continue
			remaining="${remaining}${remaining:+ }${item}"
		done
		if [ -n "${remaining}" ]; then
			set_value "${key}" "${remaining}"
		else
			tmp="${db}.$$"
			awk -F= -v key="${key}" '$1 != key { print }' "${db}" > "${tmp}"
			mv "${tmp}" "${db}"
		fi
		printf 'del_list %s=%s\n' "${key}" "${value}" >> "${log}"
		;;
	commit)
		printf 'commit %s\n' "${1:-}" >> "${log}"
		;;
	*)
		echo "unsupported fake uci action: ${action}" >&2
		exit 64
		;;
esac
EOF

cat > "${USB_HELPER}" <<'EOF'
#!/bin/sh

mt5700m_usb_info() {
	printf '%s\n' 'normal|3301|1-1'
}

mt5700m_bind_network_driver() {
	return 0
}

mt5700m_pcui_port() {
	return 0
}

mt5700m_bind_serial_driver() {
	return 0
}

mt5700m_netdev() {
	printf '%s\n' 'eth1'
}
EOF

cat > "${BIN}/ubus" <<'EOF'
#!/bin/sh
printf '%s\n' '{"up":false}'
EOF

cat > "${BIN}/jsonfilter" <<'EOF'
#!/bin/sh
printf '%s\n' 'false'
EOF

for command in ifup ifdown logger modprobe; do
	cat > "${BIN}/${command}" <<'EOF'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "${FAKE_COMMAND_LOG:?}"
EOF
done

# Keep generated fixture executables usable when the checkout itself has CRLF
# line endings (for example under Git for Windows).
sed -i 's/\r$//' "${BIN}/uci" "${USB_HELPER}" "${BIN}/ubus" \
	"${BIN}/jsonfilter" "${BIN}/ifup" "${BIN}/ifdown" \
	"${BIN}/logger" "${BIN}/modprobe"
chmod 0755 "${BIN}/uci" "${USB_HELPER}" "${BIN}/ubus" \
	"${BIN}/jsonfilter" "${BIN}/ifup" "${BIN}/ifdown" \
	"${BIN}/logger" "${BIN}/modprobe"

export FAKE_UCI_DB="${UCI_DB}"
export FAKE_UCI_LOG="${UCI_LOG}"
export FAKE_COMMAND_LOG="${COMMAND_LOG}"
export PATH="${BIN}:${PATH}"

MT5700M_MANAGER_LOCK="${FIXTURE}/manager.lock" \
MT5700M_MANAGER_STATE="${FIXTURE}/state" \
MT5700M_MANAGER_LOG="${FIXTURE}/manager.log" \
MT5700M_USB_HELPER="${USB_HELPER}" \
	sh "${MANAGER}" sync

[ "$(uci -q get network.Modem_v4.device)" = 'eth1' ] ||
	fail 'the existing IPv4 interface was not reused'
[ "$(uci -q get network.Modem_v6.device)" = '@Modem_v4' ] ||
	fail 'the existing IPv6 interface was not reused'
[ "$(uci -q get network.Modem_v6.auto)" = '1' ] ||
	fail 'IPv6 autostart was not enabled when ipv6_owner=wan'
[ "$(uci -q get network.Modem_v6.defaultroute)" = '0' ] ||
	fail 'wan_first unexpectedly installed a modem IPv6 default route'
[ "$(uci -q get network.Modem_v4.peerdns)" = '0' ] ||
	fail 'the reused IPv4 interface lost its existing DNS policy'
if uci -q get network.Modem_v4.ifname >/dev/null 2>&1; then
	fail 'a legacy ifname option was added to the reused IPv4 interface'
fi
if uci -q get network.Modem_v6.ifname >/dev/null 2>&1; then
	fail 'a legacy ifname option was added to the reused IPv6 interface'
fi

if uci -q get network.MT5700M >/dev/null 2>&1; then
	fail 'an extra MT5700M IPv4 interface was created'
fi
if uci -q get network.MT5700Mv6 >/dev/null 2>&1; then
	fail 'an extra MT5700M IPv6 interface was created'
fi

firewall_networks="$(uci -q get firewall.wan.network)"
case " ${firewall_networks} " in
	*" MT5700M "*|*" MT5700Mv6 "*)
		fail 'removed MT5700M interfaces remain in the wan firewall zone'
		;;
esac
case " ${firewall_networks} " in
	*" Modem_v4 "*) ;;
	*) fail 'the reused IPv4 interface was not added to the wan firewall zone' ;;
esac
case " ${firewall_networks} " in
	*" Modem_v6 "*) ;;
	*) fail 'the reused IPv6 interface was not added to the wan firewall zone' ;;
esac

uci -q set mt5700m.connection.pdp_type=ip
: > "${COMMAND_LOG}"
MT5700M_MANAGER_LOCK="${FIXTURE}/manager.lock" \
MT5700M_MANAGER_STATE="${FIXTURE}/state" \
MT5700M_MANAGER_LOG="${FIXTURE}/manager.log" \
MT5700M_USB_HELPER="${USB_HELPER}" \
	sh "${MANAGER}" sync
grep -qx 'ifdown Modem_v6' "${COMMAND_LOG}" ||
	fail 'IPv4-only mode did not stop the reused IPv6 interface'
uci -q get network.Modem_v6 >/dev/null 2>&1 ||
	fail 'IPv4-only mode deleted the user-owned IPv6 interface'

cat > "${UCI_DB}" <<'EOF'
network.Modem_v4=interface
network.Modem_v4.proto=dhcp
network.Modem_v4.device=eth1
network.Modem_v6=interface
network.Modem_v6.proto=dhcpv6
network.Modem_v6.device=eth1
network.stale_v6=interface
network.stale_v6.managed_by=mt5700m
network.stale_v6.proto=dhcpv6
network.stale_v6.device=@Modem_v4
mt5700m.connection=connection
mt5700m.connection.enabled=1
mt5700m.connection.pdp_type=ipv4v6
mt5700m.connection.metric=50
h5000m_netmode.settings=settings
h5000m_netmode.settings.mode=wan_first
firewall.wan=zone
firewall.wan.name=wan
firewall.wan.network=Modem_v4 Modem_v6 stale_v6
EOF
MT5700M_MANAGER_LOCK="${FIXTURE}/manager.lock" \
MT5700M_MANAGER_STATE="${FIXTURE}/state" \
MT5700M_MANAGER_LOG="${FIXTURE}/manager.log" \
MT5700M_USB_HELPER="${USB_HELPER}" \
	sh "${MANAGER}" sync
[ "$(uci -q get network.Modem_v6.device)" = '@Modem_v4' ] ||
	fail 'a directly bound user IPv6 interface was not preferred and normalized'
if uci -q get network.stale_v6 >/dev/null 2>&1; then
	fail 'an app-owned IPv6 sibling remained beside the reused user interface'
fi
case " $(uci -q get firewall.wan.network) " in
	*" stale_v6 "*) fail 'the removed IPv6 sibling remains in the wan firewall zone' ;;
esac

echo 'network policy tests passed'
