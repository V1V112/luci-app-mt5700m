#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
READ_HELPER="${ROOT}/root/usr/sbin/mt5700m-read"
TMP="$(mktemp -d)"
lock_pid=''
cleanup() {
	[ -z "${lock_pid}" ] || kill "${lock_pid}" 2>/dev/null || true
	rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

cat >"${TMP}/fake-at" <<'EOF'
#!/bin/sh
count="$(cat "${MT5700M_TEST_COUNT}" 2>/dev/null || echo 0)"
count=$((count + 1))
printf '%s\n' "${count}" >"${MT5700M_TEST_COUNT}"
sleep "${MT5700M_TEST_DELAY:-0}"
[ "${MT5700M_TEST_FAIL:-0}" != 1 ] || exit 1
printf 'snapshot=%s\n' "${count}"
printf 'action=%s\n' "$*"
if [ "$1" = radio-status ]; then
	case "${MT5700M_TEST_RADIO:-valid}" in
		missing) printf 'carrier_count=2\n' ;;
		malformed) printf 'carrier_count=1\ncarrier_1=NR|n78|640000\n' ;;
		zero) printf 'carrier_count=0\n' ;;
		*) printf 'carrier_count=1\ncarrier_1=NR|n78|640000|3500.00|100.0|640000|3400.00|100.0\n' ;;
	esac
	printf 'snapshot_at=1\n'
fi
EOF
chmod 0755 "${TMP}/fake-at"

export MT5700M_AT_HELPER="${TMP}/fake-at"
export MT5700M_ACTION_LOCK="${TMP}/action.lock"
export MT5700M_READ_CACHE_DIR="${TMP}/cache"
export MT5700M_READ_CACHE_TTL=60
export MT5700M_READ_CACHE_MAX_STALE=30
export MT5700M_TEST_COUNT="${TMP}/count"
export MT5700M_TEST_DELAY=1

# Exercise the actual cache-only path even on hosts without Linux flock.
mkdir -p "${MT5700M_READ_CACHE_DIR}"
for key in status session radio; do
	printf 'cached=%s\n' "${key}" >"${MT5700M_READ_CACHE_DIR}/${key}.cache"
	date +%s >"${MT5700M_READ_CACHE_DIR}/${key}.time"
done
[ "$(sh "${READ_HELPER}" status)" = cached=status ] || fail 'status cache hit failed'
[ "$(sh "${READ_HELPER}" advanced session)" = cached=session ] || fail 'session cache hit failed'
[ "$(sh "${READ_HELPER}" radio-status)" = cached=radio ] || fail 'radio cache hit failed'
[ ! -f "${MT5700M_TEST_COUNT}" ] || fail 'cache hits invoked the modem'
grep -q '"${READ_CACHE_DIR}/radio.cache" "${READ_CACHE_DIR}/radio.time"' \
	"${ROOT}/root/usr/sbin/mt5700m-at" || fail 'writes do not invalidate radio cache'
echo 'MT5700M read cache hits and radio write invalidation checks passed'
if ! command -v flock >/dev/null 2>&1; then
	echo 'SKIP: cache refresh/concurrency tests require Linux flock'
	exit 0
fi
for key in status session radio; do
	rm -f "${MT5700M_READ_CACHE_DIR}/${key}.cache" "${MT5700M_READ_CACHE_DIR}/${key}.time"
done
export MT5700M_READ_CACHE_TTL=1

first="$(sh "${READ_HELPER}" status)"
printf '%s\n' "${first}" | grep -qx 'snapshot=1' || fail 'first status snapshot is missing'
printf '%s\n' "${first}" | grep -qx 'action=status' || fail 'status action was not forwarded'
[ "$(cat "${MT5700M_TEST_COUNT}")" = 1 ] || fail 'first status read ran more than once'
permissions="$(ls -l "${MT5700M_READ_CACHE_DIR}/status.cache" | awk '{ print $1 }')"
[ "${permissions}" = '-rw-------' ] || fail 'snapshot permissions are not private'

second="$(sh "${READ_HELPER}" status)"
[ "${second}" = "${first}" ] || fail 'fresh cache did not return the same snapshot'
[ "$(cat "${MT5700M_TEST_COUNT}")" = 1 ] || fail 'fresh cache invoked the modem again'

sleep 2
stale="$(sh "${READ_HELPER}" status)"
[ "${stale}" = "${first}" ] || fail 'stale cache was not returned immediately'

attempt=0
while [ "$(cat "${MT5700M_TEST_COUNT}")" -lt 2 ]; do
	attempt=$((attempt + 1))
	[ "${attempt}" -lt 5 ] || fail 'background refresh did not start'
	sleep 1
done
sleep 1
refreshed="$(sh "${READ_HELPER}" status)"
printf '%s\n' "${refreshed}" | grep -qx 'snapshot=2' || fail 'background refresh did not replace the snapshot'

session="$(sh "${READ_HELPER}" advanced session)"
printf '%s\n' "${session}" | grep -qx 'action=advanced session' || fail 'session action was not cached independently'
[ -f "${MT5700M_READ_CACHE_DIR}/session.cache" ] || fail 'session cache was not created'
[ -f "${MT5700M_READ_CACHE_DIR}/session.time" ] || fail 'session timestamp was not created'

# Carrier/MCS reads share one independent radio snapshot across page sessions.
export MT5700M_READ_CACHE_TTL=5
radio="$(sh "${READ_HELPER}" radio-status)"
printf '%s\n' "${radio}" | grep -qx 'action=radio-status' || fail 'radio action was not forwarded'
printf '%s\n' "${radio}" | grep -qx 'carrier_count=1' || fail 'radio carrier data is missing'
[ -f "${MT5700M_READ_CACHE_DIR}/radio.time" ] || fail 'radio timestamp was not created'
[ "$(printf '%s\n' "${radio}" | grep -c '^snapshot_at=')" = 1 ] || fail 'radio snapshot has duplicate timestamps'
count="$(cat "${MT5700M_TEST_COUNT}")"
[ "$(sh "${READ_HELPER}" radio-status)" = "${radio}" ] || fail 'fresh radio cache changed'
[ "$(cat "${MT5700M_TEST_COUNT}")" = "${count}" ] || fail 'radio cache hit invoked the modem'
[ "$(cat "${MT5700M_READ_CACHE_DIR}/status.cache")" = "${refreshed}" ] || fail 'radio cache replaced status'

# Equality is expired: a five-second poll receives this refresh synchronously.
printf '%s\n' "$(( $(date +%s) - 5 ))" >"${MT5700M_READ_CACHE_DIR}/radio.time"
radio="$(sh "${READ_HELPER}" radio-status)"
count=$((count + 1))
printf '%s\n' "${radio}" | grep -qx "snapshot=${count}" || fail 'radio expiry returned the previous snapshot'
[ "$(cat "${MT5700M_TEST_COUNT}")" = "${count}" ] || fail 'radio expiry did not refresh once'

# Concurrent cold reads run one query batch, then return the same publication.
rm -f "${MT5700M_READ_CACHE_DIR}/radio.cache" "${MT5700M_READ_CACHE_DIR}/radio.time"
sh "${READ_HELPER}" radio-status >"${TMP}/radio-a" &
first_pid=$!
sh "${READ_HELPER}" radio-status >"${TMP}/radio-b" &
second_pid=$!
wait "${first_pid}" || fail 'first concurrent radio read failed'
wait "${second_pid}" || fail 'second concurrent radio read failed'
cmp "${TMP}/radio-a" "${TMP}/radio-b" || fail 'concurrent radio reads received different snapshots'
count=$((count + 1))
[ "$(cat "${MT5700M_TEST_COUNT}")" = "${count}" ] || fail 'concurrent radio reads duplicated modem queries'
cp "${MT5700M_READ_CACHE_DIR}/radio.cache" "${TMP}/radio-before"
export MT5700M_TEST_DELAY=0

expire_radio() {
	printf '%s\n' "$(( $(date +%s) - 6 ))" >"${MT5700M_READ_CACHE_DIR}/radio.time"
}

# Transport errors or incomplete carrier replies must preserve the last valid
# cache; missing MCS is allowed (the overview retains the previous MCS values).
for mode in missing malformed zero; do
	expire_radio
	MT5700M_TEST_RADIO="${mode}" sh "${READ_HELPER}" radio-status >"${TMP}/radio-failed"
	cmp "${TMP}/radio-before" "${TMP}/radio-failed" || fail "${mode} radio reply replaced the last valid snapshot"
	cmp "${TMP}/radio-before" "${MT5700M_READ_CACHE_DIR}/radio.cache" || fail "${mode} radio reply changed the cache"
done
expire_radio
MT5700M_TEST_FAIL=1 sh "${READ_HELPER}" radio-status >"${TMP}/radio-failed"
cmp "${TMP}/radio-before" "${TMP}/radio-failed" || fail 'failed radio query lost the last valid snapshot'

# A write/SMS owns fd 9: radio returns old data without waiting or querying AT.
expire_radio
count="$(cat "${MT5700M_TEST_COUNT}")"
(
	exec 9>"${MT5700M_ACTION_LOCK}"
	flock -n 9 || exit 1
	touch "${TMP}/action-held"
	while [ ! -f "${TMP}/action-release" ]; do sleep 1; done
) &
lock_pid=$!
attempt=0
while [ ! -f "${TMP}/action-held" ]; do
	attempt=$((attempt + 1))
	[ "${attempt}" -lt 5 ] || fail 'action-lock holder did not start'
	sleep 1
done
before="$(date +%s)"
sh "${READ_HELPER}" radio-status >"${TMP}/radio-busy"
[ "$(( $(date +%s) - before ))" -lt 2 ] || fail 'radio queued behind a write/SMS'
cmp "${TMP}/radio-before" "${TMP}/radio-busy" || fail 'busy action lock lost the last valid snapshot'
[ "$(cat "${MT5700M_TEST_COUNT}")" = "${count}" ] || fail 'busy action lock invoked the modem'
touch "${TMP}/action-release"
wait "${lock_pid}" || fail 'action-lock holder failed'
lock_pid=''

# Failed refreshes cannot extend the maximum age of the last valid snapshot.
printf '%s\n' "$(( $(date +%s) - 31 ))" >"${MT5700M_READ_CACHE_DIR}/radio.time"
if MT5700M_TEST_FAIL=1 sh "${READ_HELPER}" radio-status >"${TMP}/radio-too-old"; then
	fail 'radio accepted a cache older than MAX_STALE after a failed refresh'
fi
[ ! -s "${TMP}/radio-too-old" ] || fail 'radio returned data older than MAX_STALE'

echo 'MT5700M read cache tests passed'
