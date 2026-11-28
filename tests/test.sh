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
header_file=""

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
    --connect-timeout|--max-time)
      shift 2
      ;;
    --dump-header)
      header_file=$2
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
printf '%s %s\n' "$method" "${url#https://mock.invalid}" >> "$MOCK_CALL_LOG"

# Every API command must initialize a session before reading or updating.
case "$url" in
  *"/api/2/session/get") ;;
  *)
    if [ -z "$cookie_file" ] || ! grep -F 'zsessionid' "$cookie_file" >/dev/null 2>&1; then
      printf '%s' '{"error":"session cookie required"}' > "$output"
      printf '500'
      exit 0
    fi
    session_id=$(awk '$6 ~ /^(__Secure-|__Host-)?zsessionid$/ {print $7}' "$cookie_file")
    [ -f "$MOCK_SESSION_STATE/$session_id" ] || exit 1
    ;;
esac
if [ "$method" = POST ]; then
  if [ "${MOCK_V44:-0}" = 1 ]; then
    [ -z "$csrf" ] || exit 1
  else
    [ "$csrf" = 'CSRFToken: token-123' ] || exit 1
  fi
fi

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
    [ "$method" = POST ] || exit 1
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
    [ "${MOCK_V44:-0}" != 1 ] || body='{}'
    [ "${MOCK_SESSION_INVALID:-0}" != 1 ] || body='not-json'
    [ "${MOCK_SESSION_DENIED:-0}" != 1 ] || { status=401; body='{"error":"unauthorized"}'; }
    ;;
  *"/api/2/session/invalidate")
    [ "$method" = POST ] || exit 1
    session_id=$(awk '$6 ~ /^(__Secure-|__Host-)?zsessionid$/ {print $7}' "$cookie_file")
    [ -f "$MOCK_SESSION_STATE/$session_id" ] || exit 1
    if [ "${MOCK_LOGOUT_FAIL:-0}" = 1 ]; then
      status=500; body='{"error":"logout failed"}'
    else
      rm "$MOCK_SESSION_STATE/$session_id"
      body=''
      if [ "${MOCK_V44:-0}" = 1 ]; then
        status=302
        printf 'HTTP/1.1 302 Found\r\nLocation: %s\r\n' "${MOCK_LOGOUT_LOCATION:-https://mock.invalid/}" > "$header_file"
      fi
    fi
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
    if [ "${MOCK_V44:-0}" = 1 ]; then
      case "$url" in
        *'?startindex='*'&results=200') ;;
        *) exit 1 ;;
      esac
      offset=${url#*startindex=}; offset=${offset%%&*}
      [ "${MOCK_PAGE_REPEAT:-0}" != 1 ] || offset=0
      body=$(printf '%s' "$body" | jq --argjson offset "$offset" \
        '.records = .records[$offset:($offset + 2)] | .pageSize = 2 | .startIndex = $offset | .recordsReturned = (.records|length)')
      if [ "${MOCK_PAGE_EMPTY:-0}" = 1 ] && [ "$offset" -gt 0 ]; then
        body='{"totalRecords":3,"records":[]}'
      fi
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

if [ "${MOCK_V44:-0}" = 1 ]; then
  case "$url" in
    *"/api/2/admin/hosts/get?id="*)
      body=$(printf '%s' "$body" | jq '.monitpassword = "........"')
      ;;
    *"/api/2/admin/hosts/update")
      case "$data" in *'monitpassword=........&'*) ;; *) exit 1 ;; esac
      ;;
  esac
  # 4.4.0 updates succeed with an empty response body.
  [ "$method" != POST ] || [ "$status" != 200 ] || body=''
fi

if [ -n "$cookie_jar" ]; then
  if [ "$status" = 200 ]; then
    session_id=${cookie_jar##*/}
    cookie_name=${MOCK_COOKIE_NAME:-zsessionid}
    [ "${MOCK_V44:-0}" != 1 ] || cookie_name=${MOCK_COOKIE_NAME:-__Secure-zsessionid}
    printf '#HttpOnly_mmonit\tTRUE\t/\tFALSE\t0\t%s\t%s\n' "$cookie_name" "$session_id" > "$cookie_jar"
    : > "$MOCK_SESSION_STATE/$session_id"
  fi
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
export MOCK_CALL_LOG="$TMP/calls.log" MOCK_SESSION_STATE="$TMP/sessions"
mkdir -p "$MOCK_SESSION_STATE"
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

# Keep CLI temporary files separate from fixtures, including a path with spaces.
export TMPDIR="$TMP/temp files"
mkdir -p "$TMPDIR"
assert_no_temp_files() {
  [ -z "$(ls -A "$TMPDIR")" ] || fail "CLI left temporary files behind"
}
for iteration in 1 2 3; do
  "$ROOT/bin/mmonitctl" health >/dev/null || fail "repeated health"
  assert_no_temp_files
done

# Exercise the actual key decoder with file input instead of a terminal.
(
  awk '/^read_key\(\) \{/ { copying=1 } copying { print } copying && /^\}/ { exit }' \
    "$ROOT/bin/mmonitctl" | sed 's@< /dev/tty@< "$TEST_KEY_FILE"@g' > "$TMP/read-key.sh"
  . "$TMP/read-key.sh"
  TEST_KEY_FILE="$TMP/key-input"
  for filter_mode in false true; do
    for input in k j q A; do
      printf '%s' "$input" > "$TEST_KEY_FILE"
      read_key || fail "read key $input"
      if [ "$filter_mode" = true ]; then
        [ "$KEY" = char ] && [ "$KEY_TEXT" = "$input" ] || fail "search must accept $input"
      else
        case "$input" in k) expected=up ;; j) expected=down ;; q) expected=quit ;; A) expected=all ;; esac
        [ "$KEY" = "$expected" ] || fail "normal shortcut $input"
      fi
    done
    for mapping in '020 up' '016 down' '177 backspace' '010 backspace' '012 enter' '040 space' '057 filter'; do
      code=${mapping% *}; expected=${mapping#* }
      printf '%b' "\\$code" > "$TEST_KEY_FILE"
      read_key || fail "read control key $code"
      [ "$KEY" = "$expected" ] || fail "control key $code in filter_mode=$filter_mode"
    done
  done
)

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

# M/Monit 4.4.0: tokenless sessions, clamped pages, password sentinel,
# empty update bodies, and all group name/ID combinations.
export MOCK_V44=1
for action in stop-all start-all 'stop-group web' 'stop-group 10' 'start-group web' 'start-group 10'; do
  : > "$MOCK_LOG"
  output=$("$ROOT/bin/mmonitctl" $action) || fail "4.4.0 $action"
  case "$action" in
    stop-all) expected_count=2; expected_status=2 ;;
    stop-group*) expected_count=1; expected_status=2 ;;
    *) expected_count=1; expected_status=0 ;;
  esac
  [ "$(wc -l < "$MOCK_LOG" | tr -d ' ')" = "$expected_count" ] || fail "4.4.0 $action count"
  grep -F "status=$expected_status" "$MOCK_LOG" >/dev/null || fail "4.4.0 $action status"
  grep -F 'monitpassword=........' "$MOCK_LOG" >/dev/null || fail "4.4.0 password sentinel"
done
output=$("$ROOT/bin/mmonitctl" status 2>&1) && fail "4.4.0 status must include inactive host on second page"
printf '%s' "$output" | grep -F '(2/3 Active)' >/dev/null || fail "4.4.0 status pagination"
MOCK_HOSTS_ACTIVE=1 "$ROOT/bin/mmonitctl" status >/dev/null || fail "4.4.0 active status"
"$ROOT/bin/mmonitctl" health >/dev/null || fail "4.4.0 health session"
if MOCK_CHECK_FAIL=1 "$ROOT/bin/mmonitctl" health >/dev/null 2>&1; then fail "4.4.0 health errors"; fi
for paging_failure in MOCK_PAGE_REPEAT MOCK_PAGE_EMPTY; do
  : > "$MOCK_LOG"
  if env "$paging_failure=1" "$ROOT/bin/mmonitctl" stop-all >/dev/null 2>&1; then fail "4.4.0 incomplete paging $paging_failure"; fi
  [ ! -s "$MOCK_LOG" ] || fail "incomplete pages must not update hosts"
done
for session_failure in MOCK_SESSION_INVALID MOCK_SESSION_DENIED; do
  : > "$MOCK_LOG"
  if env "$session_failure=1" "$ROOT/bin/mmonitctl" stop-all >/dev/null 2>&1; then fail "invalid session $session_failure"; fi
  [ ! -s "$MOCK_LOG" ] || fail "invalid session must not update hosts"
done
"$ROOT/bin/mmonitctl" alerts-off-all >/dev/null || fail "4.4.0 alerts off"
"$ROOT/bin/mmonitctl" alerts-on-all >/dev/null || fail "4.4.0 alerts on"
if MOCK_ALERT_FAIL=1 "$ROOT/bin/mmonitctl" alerts-off-all >/dev/null 2>&1; then fail "4.4.0 alert HTTP failure"; fi
unset MOCK_V44

# Every completed command owns and invalidates exactly one session. This also
# checks that parallel workers never invalidate the parent's shared session.
[ -z "$(ls -A "$MOCK_SESSION_STATE")" ] || fail "earlier commands leaked sessions"
for server_version in 0 1; do
  export MOCK_V44=$server_version
  for action in health status stop-all start-all 'stop-group web' 'start-group 10' alerts-off-all; do
    : > "$MOCK_CALL_LOG"
    command_rc=0
    "$ROOT/bin/mmonitctl" $action >/dev/null 2>&1 || command_rc=$?
    case "$action" in status) expected_rc=1 ;; *) expected_rc=0 ;; esac
    [ "$command_rc" = "$expected_rc" ] || fail "session cleanup changed $action exit code"
    [ "$(grep -c '^GET /api/2/session/get$' "$MOCK_CALL_LOG")" = 1 ] || fail "session initialization count"
    [ "$(grep -c '^POST /api/2/session/invalidate$' "$MOCK_CALL_LOG")" = 1 ] || fail "session invalidation count"
    [ "$(tail -1 "$MOCK_CALL_LOG")" = 'POST /api/2/session/invalidate' ] || fail "logout ran before command finished"
    [ -z "$(ls -A "$MOCK_SESSION_STATE")" ] || fail "$action leaked sessions"
  done
  for iteration in 1 2 3 4 5; do
    "$ROOT/bin/mmonitctl" health >/dev/null || fail "repeated health"
  done
  [ -z "$(ls -A "$MOCK_SESSION_STATE")" ] || fail "repeated health leaked sessions"
  if MOCK_CHECK_FAIL=1 "$ROOT/bin/mmonitctl" health >/dev/null 2>&1; then fail "cleanup changed health error"; fi
  if "$ROOT/bin/mmonitctl" health --invert-exit >/dev/null 2>&1; then fail "cleanup changed inverted health"; fi
  [ -z "$(ls -A "$MOCK_SESSION_STATE")" ] || fail "health errors leaked sessions"
done

cat > "$TMP/interrupted.sh" <<'EOF'
#!/bin/sh
. "$TEST_FUNCTIONS"
load_config || exit 1
initialize_session || exit 1
(
  trap - 0 HUP INT TERM
  sleep 1
  api_request GET /api/2/admin/hosts/get?id=1 >/dev/null && : > "$TEST_WORKER_DONE"
) &
kill -s "$TEST_SIGNAL" "$$"
exit 99
EOF
# Refresh the sourced functions after any implementation changes.
sed '$d' "$ROOT/bin/mmonitctl" > "$TEST_FUNCTIONS"
export TEST_WORKER_DONE="$TMP/worker-done"
for signal_case in 'HUP 129' 'INT 130' 'TERM 143'; do
  export TEST_SIGNAL=${signal_case% *}
  expected_rc=${signal_case#* }
  rm -f "$TEST_WORKER_DONE"
  command_rc=0
  sh "$TMP/interrupted.sh" >/dev/null 2>&1 || command_rc=$?
  [ "$command_rc" = "$expected_rc" ] || fail "$TEST_SIGNAL exit code"
  [ -f "$TEST_WORKER_DONE" ] || fail "$TEST_SIGNAL invalidated a running worker's session"
  [ -z "$(ls -A "$MOCK_SESSION_STATE")" ] || fail "$TEST_SIGNAL leaked sessions"
  assert_no_temp_files
done
if MOCK_LOGOUT_FAIL=1 "$ROOT/bin/mmonitctl" health >"$TMP/logout-failure" 2>&1; then fail "logout failure must fail command"; fi
grep -F 'Could not invalidate M/Monit session (500)' "$TMP/logout-failure" >/dev/null || fail "logout error not reported"
rm -f "$MOCK_SESSION_STATE/"*
MOCK_COOKIE_NAME=__Host-zsessionid "$ROOT/bin/mmonitctl" health >/dev/null || fail "host-prefixed session cookie"
MOCK_LOGOUT_LOCATION=/ "$ROOT/bin/mmonitctl" health >/dev/null || fail "relative logout redirect"
if MOCK_LOGOUT_LOCATION=https://sso.invalid/login "$ROOT/bin/mmonitctl" health >/dev/null 2>&1; then fail "SSO redirect must not count as logout success"; fi
: > "$MOCK_CALL_LOG"
if MOCK_SESSION_DENIED=1 "$ROOT/bin/mmonitctl" health >/dev/null 2>&1; then fail "denied session"; fi
if grep -q 'session/invalidate' "$MOCK_CALL_LOG"; then fail "must not logout without a session cookie"; fi
unset MOCK_V44

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

# Concurrent invocations must remove only their own directory.
printf 'keep\n' > "$TMPDIR/unrelated"
"$ROOT/bin/mmonitctl" health >/dev/null &
first_pid=$!
"$ROOT/bin/mmonitctl" health >/dev/null &
second_pid=$!
wait "$first_pid" || fail "first concurrent health"
wait "$second_pid" || fail "second concurrent health"
[ "$(cat "$TMPDIR/unrelated")" = keep ] || fail "removed unrelated temporary file"
rm "$TMPDIR/unrelated"
assert_no_temp_files
if TMPDIR="$TMP/missing" "$ROOT/bin/mmonitctl" health >/dev/null 2>&1; then
  fail "temporary directory creation failure must fail the command"
fi
assert_no_temp_files
printf 'OK\n'
