#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mmonitctl-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/mockbin"

cat > "$TMP/mockbin/curl" <<'EOF'
#!/bin/sh
output=""
method="GET"
url=""
data=""
write_out=""
cookie_jar=""
cookie_file=""
csrf=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      output=$2
      shift 2
      ;;
    --request)
      method=$2
      shift 2
      ;;
    --data-urlencode|-d)
      if [ -n "$data" ]; then data="$data&$2"; else data=$2; fi
      shift 2
      ;;
    --write-out)
      write_out=$2
      shift 2
      ;;
    --cookie-jar|-c)
      cookie_jar=$2
      shift 2
      ;;
    --cookie|-b)
      cookie_file=$2
      shift 2
      ;;
    --user|-u)
      shift 2
      ;;
    --header|-H)
      case "$2" in CSRFToken:*) csrf=$2 ;; esac
      shift 2
      ;;
    --silent|--show-error|--compressed)
      shift
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done

status=200
body='{}'

case "$url" in
  *"/admin/alerts/list")
    if [ "${MOCK_ALERT_INVALID:-0}" = 1 ]; then
      body='{"unexpected":true}'
    elif [ "${MOCK_ALERT_EMPTY:-0}" = 1 ]; then
      body='[]'
    else
      active_a=true; active_b=false
      [ ! -f "$MOCK_ALERT_STATE/41" ] || active_a=$(cat "$MOCK_ALERT_STATE/41")
      [ ! -f "$MOCK_ALERT_STATE/42" ] || active_b=$(cat "$MOCK_ALERT_STATE/42")
      body="[{\"id\":41,\"description\":\"Slack #web\",\"active\":$active_a},{\"id\":42,\"description\":\"Slack #ops\",\"active\":$active_b}]"
    fi
    ;;
  *"/admin/alerts/updateactive")
    [ "$method" = POST ] && [ "$csrf" = 'CSRFToken: token-123' ] || exit 1
    if [ -z "$cookie_file" ] || ! grep -F 'zsessionid' "$cookie_file" >/dev/null 2>&1; then
      status=403; body='{"error":"session cookie required"}'
      printf '%s' "$body" > "$output"
      printf '%s' "$status"
      exit 0
    fi
    printf '%s\n' "$data" >> "$MOCK_LOG"
    if [ "${MOCK_ALERT_FAIL:-0}" = 1 ]; then
      status=500; body='{"error":"update failed"}'
    elif [ "${MOCK_ALERT_NO_CHANGE:-0}" != 1 ]; then
      id=${data%%&*}; id=${id#id=}
      active=${data##*&active=}
      case "$active" in 1) active=true ;; 0) active=false ;; *) exit 1 ;; esac
      printf '%s' "$active" > "$MOCK_ALERT_STATE/$id"
    fi
    ;;
  *"/index.csp")
    body='ok'
    ;;
  *"/z_security_check")
    body='logged'
    ;;
  *"/api/2/session/get")
    body='{"CSRFToken":"token-123"}'
    ;;
  *"/api/2/reports/events/list?active=1&state=1")
    if [ "${MOCK_CHECK_FAIL:-0}" = "1" ]; then
      body='{"records":[{"id":1001}],"recordsReturned":1}'
    else
      body='{"records":[],"recordsReturned":0}'
    fi
    ;;
  *"/api/2/admin/hosts/list"*)
    if [ "${MOCK_HOSTS_ACTIVE:-0}" = "1" ]; then
      body='{"totalRecords":3,"records":[{"id":1,"hostname":"host-a","status":"Active"},{"id":2,"hostname":"host-b","status":"Active"},{"id":3,"hostname":"host-c","status":"Active"}]}'
    else
      body='{"totalRecords":3,"records":[{"id":1,"hostname":"host-a","status":"Active"},{"id":2,"hostname":"host-b","status":"Active"},{"id":3,"hostname":"host-c","status":"Inactive"}]}'
    fi
    ;;
  *"/api/2/admin/groups/list")
    body='{"hosts":[{"id":1,"name":"host-a"},{"id":2,"name":"host-b"},{"id":3,"name":"host-c"}],"groups":[{"id":10,"name":"web","hosts":[{"id":2},{"id":3}]},{"id":11,"name":"empty","hosts":[]}]}'
    ;;
  *"/api/2/admin/hosts/get?id=1")
    body='{"id":1,"hostname":"host-a","monituser":"mu1","monitpassword":"mp1","ipaddrout":"","portout":-1,"keepname":0,"skew":3,"description":"desc-a","status":0}'
    ;;
  *"/api/2/admin/hosts/get?id=2")
    body='{"id":2,"hostname":"host-b","monituser":"mu2","monitpassword":"mp2","ipaddrout":"","portout":-1,"keepname":0,"skew":3,"description":"desc-b","status":0}'
    ;;
  *"/api/2/admin/hosts/get?id=3")
    body='{"id":3,"hostname":"host-c","monituser":"mu3","monitpassword":"mp3","ipaddrout":"","portout":-1,"keepname":1,"skew":5,"description":"desc-c","status":2}'
    ;;
  *"/api/2/admin/hosts/update")
    printf '%s\n' "$data" >> "$MOCK_LOG"
    body='{}'
    ;;
  *)
    status=404
    body='{"error":"not found"}'
    ;;
esac

if [ -n "$cookie_jar" ]; then
  printf '#HttpOnly_mmonit\tTRUE\t/\tFALSE\t0\tzsessionid\tmock\n' > "$cookie_jar"
fi

if [ -n "$output" ]; then
  printf '%s' "$body" > "$output"
else
  printf '%s' "$body"
fi

if [ "$write_out" = "%{http_code}" ]; then
  printf '%s' "$status"
fi
EOF
chmod +x "$TMP/mockbin/curl"

export PATH="$TMP/mockbin:$PATH"
export MOCK_LOG="$TMP/requests.log"
export MMONIT_BASE_URL="https://mock.invalid"
export MMONIT_USERNAME="admin"
export MMONIT_PASSWORD="secret"
export MMONIT_CONCURRENCY=2
export MOCK_ALERT_STATE="$TMP/alert-state"
mkdir -p "$MOCK_ALERT_STATE"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

output=$("$ROOT/bin/mmonitctl" stop-all --yes)
printf '%s' "$output" | grep -F '2 hosts updated, 1 skipped.' >/dev/null || fail "stop-all output"
[ "$(wc -l < "$MOCK_LOG" | tr -d ' ')" = "2" ] || fail "stop-all request count"
grep -F 'id=1' "$MOCK_LOG" >/dev/null || fail "missing host id=1"
grep -F 'id=2' "$MOCK_LOG" >/dev/null || fail "missing host id=2"
grep -F 'status=2' "$MOCK_LOG" >/dev/null || fail "stop-all did not set status=2"

: > "$MOCK_LOG"
output=$("$ROOT/bin/mmonitctl" stop-group 10 --yes)
printf '%s' "$output" | grep -F '1 hosts updated, 1 skipped.' >/dev/null || fail "stop-group output"
[ "$(wc -l < "$MOCK_LOG" | tr -d ' ')" = "1" ] || fail "stop-group request count"
grep -F 'id=2' "$MOCK_LOG" >/dev/null || fail "stop-group should only update host id=2"
grep -F 'status=2' "$MOCK_LOG" >/dev/null || fail "stop-group did not set status=2"

: > "$MOCK_LOG"
output=$("$ROOT/bin/mmonitctl" start-group web --yes)
printf '%s' "$output" | grep -F '1 hosts updated, 1 skipped.' >/dev/null || fail "start-group output"
[ "$(wc -l < "$MOCK_LOG" | tr -d ' ')" = "1" ] || fail "start-group request count"
grep -F 'id=3' "$MOCK_LOG" >/dev/null || fail "start-group should only update host id=3"
grep -F 'status=0' "$MOCK_LOG" >/dev/null || fail "start-group did not set status=0"

: > "$MOCK_LOG"
output=$("$ROOT/bin/mmonitctl" start-all)
printf '%s' "$output" | grep -F '1 hosts updated, 2 skipped.' >/dev/null || fail "start-all output"
grep -F 'status=0' "$MOCK_LOG" >/dev/null || fail "start-all status"
for command in 'stop-group web' 'start-group 10'; do
  # Intentional splitting of the fixed command and group arguments.
  "$ROOT/bin/mmonitctl" $command >/dev/null || fail "$command"
done

: > "$MOCK_LOG"
output=$("$ROOT/bin/mmonitctl" alerts-off-all)
printf '%s' "$output" | grep -F '1 alerts updated, 1 skipped.' >/dev/null || fail "alerts-off-all output"
[ "$(cat "$MOCK_LOG")" = 'id=41&active=0' ] || fail "alerts-off-all payload"
: > "$MOCK_LOG"
output=$("$ROOT/bin/mmonitctl" alerts-on-all)
printf '%s' "$output" | grep -F '2 alerts updated, 0 skipped.' >/dev/null || fail "alerts-on-all output"
[ "$(wc -l < "$MOCK_LOG" | tr -d ' ')" = 2 ] || fail "alerts-on-all count"
grep -Fx 'id=41&active=1' "$MOCK_LOG" >/dev/null || fail "alerts-on-all first payload"
grep -Fx 'id=42&active=1' "$MOCK_LOG" >/dev/null || fail "alerts-on-all second payload"
: > "$MOCK_LOG"
"$ROOT/bin/mmonitctl" alerts-on-all >/dev/null || fail "alerts-on-all no-op"
[ ! -s "$MOCK_LOG" ] || fail "already active alerts must skip POST"
if MOCK_ALERT_FAIL=1 "$ROOT/bin/mmonitctl" alerts-off-all >/dev/null 2>&1; then fail "alert HTTP failure"; fi
if MOCK_ALERT_NO_CHANGE=1 "$ROOT/bin/mmonitctl" alerts-off-all >/dev/null 2>&1; then fail "unverified alert update"; fi
: > "$MOCK_LOG"
if MOCK_ALERT_INVALID=1 "$ROOT/bin/mmonitctl" alerts-off-all >/dev/null 2>&1; then fail "invalid alert list"; fi
[ ! -s "$MOCK_LOG" ] || fail "invalid alert list must not update"
MOCK_ALERT_EMPTY=1 "$ROOT/bin/mmonitctl" alerts-off-all >/dev/null || fail "empty alert list"

# Exercise the real search/selection mapping without requiring a terminal.
sed '$d' "$ROOT/bin/mmonitctl" > "$TMP/functions.sh"
cat > "$TMP/select-alerts.sh" <<'EOF'
#!/bin/sh
. "$TEST_FUNCTIONS"
select_hosts() {
  [ "$4" = alerts ] || return 1
  build_filtered_hosts "$1" '#web' "$TEST_VISIBLE"
  [ "$(awk 'END {print NR}' "$TEST_VISIBLE")" = 1 ] || return 1
  select_all_visible "$TEST_VISIBLE" "$2"
}
main "$@"
EOF
export TEST_FUNCTIONS="$TMP/functions.sh" TEST_VISIBLE="$TMP/visible.tsv"
: > "$MOCK_LOG"
sh "$TMP/select-alerts.sh" alerts-off >/dev/null || fail "search/select alerts off"
[ "$(cat "$MOCK_LOG")" = 'id=41&active=0' ] || fail "search off changed other alerts"
: > "$MOCK_LOG"
sh "$TMP/select-alerts.sh" alerts-on >/dev/null || fail "search/select alerts on"
[ "$(cat "$MOCK_LOG")" = 'id=41&active=1' ] || fail "search on changed other alerts"

output=$("$ROOT/bin/mmonitctl" status 2>&1) && fail "status should fail when a host is inactive"
printf '%s' "$output" | grep -F 'Monitoring is not active on all hosts (2/3 Active).' >/dev/null || fail "status inactive output"
MOCK_HOSTS_ACTIVE=1 "$ROOT/bin/mmonitctl" status >/dev/null || fail "status should succeed when all hosts are active"

output=$("$ROOT/bin/mmonitctl" health)
printf '%s' "$output" | grep -F 'No active monitoring alert events.' >/dev/null || fail "health output"

if MOCK_CHECK_FAIL=1 "$ROOT/bin/mmonitctl" health >/dev/null 2>&1; then
  fail "health should fail when host is red/orange"
fi

if "$ROOT/bin/mmonitctl" health --invert-exit >/dev/null 2>&1; then
  fail "health --invert-exit should fail when all hosts are healthy"
fi

if ! MOCK_CHECK_FAIL=1 "$ROOT/bin/mmonitctl" health --invert-exit >/dev/null 2>&1; then
  fail "health --invert-exit should succeed when host is red/orange"
fi

"$ROOT/bin/mmonitctl" --version | grep -F 'mmonitctl 0.1.0' >/dev/null || fail "version"
"$ROOT/bin/mmonitctl" --help | grep -F 'mmonitctl stop-group <group>' >/dev/null || fail "help stop-group"
"$ROOT/bin/mmonitctl" --help | grep -F 'mmonitctl start-group <group>' >/dev/null || fail "help start-group"
"$ROOT/bin/mmonitctl" --help | grep -F 'mmonitctl start [--yes]' >/dev/null || fail "help start"
if "$ROOT/bin/mmonitctl" resume-all >/dev/null 2>&1; then
  fail "resume-all should be removed"
fi
if "$ROOT/bin/mmonitctl" resume >/dev/null 2>&1; then
  fail "resume should be removed"
fi
if "$ROOT/bin/mmonitctl" resume-group web >/dev/null 2>&1; then
  fail "resume-group should be removed"
fi
"$ROOT/bin/mmonitctl" --help | grep -F 'mmonitctl start-all [--yes]' >/dev/null || fail "help start-all"
"$ROOT/bin/mmonitctl" --help | grep -F 'mmonitctl status' >/dev/null || fail "help status"
"$ROOT/bin/mmonitctl" --help | grep -F -- '--invert-exit' >/dev/null || fail "help invert-exit"

printf 'OK\n'
