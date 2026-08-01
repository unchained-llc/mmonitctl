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
      shift 2
      ;;
    --user|-u)
      shift 2
      ;;
    --header|-H)
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
    body='{"totalRecords":3,"records":[{"id":1,"hostname":"host-a","status":"Active"},{"id":2,"hostname":"host-b","status":"Active"},{"id":3,"hostname":"host-c","status":"Inactive"}]}'
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

output=$("$ROOT/bin/mmonitctl" check)
printf '%s' "$output" | grep -F 'No active monitoring alert events.' >/dev/null || fail "check output"

if MOCK_CHECK_FAIL=1 "$ROOT/bin/mmonitctl" check >/dev/null 2>&1; then
  fail "check should fail when host is red/orange"
fi

if "$ROOT/bin/mmonitctl" check --invert-exit >/dev/null 2>&1; then
  fail "check --invert-exit should fail when all hosts are healthy"
fi

if ! MOCK_CHECK_FAIL=1 "$ROOT/bin/mmonitctl" check --invert-exit >/dev/null 2>&1; then
  fail "check --invert-exit should succeed when host is red/orange"
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
"$ROOT/bin/mmonitctl" --help | grep -F 'mmonitctl check' >/dev/null || fail "help check"
"$ROOT/bin/mmonitctl" --help | grep -F -- '--invert-exit' >/dev/null || fail "help invert-exit"

printf 'OK\n'
