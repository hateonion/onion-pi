#!/usr/bin/env bash
set -euo pipefail

plugin_dir=$(cd "$(dirname "$0")" && pwd)
subject="$plugin_dir/rename-pane.sh"
manual_subject="$plugin_dir/rename-title.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
herdr_log="$work/herdr.log"
pi_log="$work/pi.log"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file=$1 text=$2
  grep -F -- "$text" "$file" >/dev/null || fail "missing '$text' in $file"
}

assert_empty() {
  local file=$1
  [ ! -s "$file" ] || fail "expected $file to be empty"
}

cat > "$work/bin/herdr" <<'HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_TEST_LOG"
case "$1 $2" in
  'pane get')
    if [ "${FAKE_PANE_MISSING:-0}" = 1 ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found","message":"pane not found"}}' >&2
      exit 1
    fi
    pane_id=$3
    jq -n \
      --arg pane_id "$pane_id" \
      --arg label "${FAKE_LABEL:-}" \
      --arg agent "${FAKE_AGENT:-pi}" \
      --arg status "${FAKE_STATUS:-idle}" \
      --arg cwd "${FAKE_CWD:-/repo}" \
      --arg title "${FAKE_TERMINAL_TITLE:-Pi agent}" \
      --arg auto_title "${FAKE_TITLE:-}" \
      --arg session_path "${FAKE_SESSION_PATH:-}" \
      --arg rename_session "${FAKE_RENAME_SESSION:-}" \
      --argjson revision "${FAKE_REVISION:-7}" \
      '{result:{pane:{pane_id:$pane_id,label:(if $label == "" then null else $label end),agent:$agent,agent_status:$status,cwd:$cwd,terminal_title:$title,title:(if $auto_title == "" then null else $auto_title end),agent_session:(if $session_path == "" then null else {agent:$agent,kind:"path",source:"herdr:pi",value:$session_path} end),tokens:(if $rename_session == "" then {} else {auto_rename_session:$rename_session} end),revision:$revision}}}'
    ;;
  'agent get')
    pane_id=$3
    jq -n \
      --arg pane_id "$pane_id" \
      --arg agent "${FAKE_AGENT:-pi}" \
      --arg status "${FAKE_STATUS:-idle}" \
      --argjson state_change_seq "${FAKE_STATE_SEQ:-11}" \
      '{result:{agent:{pane_id:$pane_id,agent:$agent,agent_status:$status,state_change_seq:$state_change_seq}}}'
    ;;
  'pane read')
    printf '%s\n' 'Implemented OAuth token refresh and tests.'
    ;;
  'pane report-metadata')
    printf '%s\n' '{"result":{}}'
    ;;
  'agent list')
    jq -n '{result:{agents:[
      {pane_id:"p-idle",agent:"pi",agent_status:"idle"},
      {pane_id:"p-working",agent:"pi",agent_status:"working"}
    ]}}'
    ;;
  *)
    printf 'unexpected Herdr command: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$work/bin/herdr"

cat > "$work/bin/pi" <<'PI'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$PI_TEST_LOG"
printf '%s\n' 'Implement authentication refresh workflow'
PI
chmod +x "$work/bin/pi"

run_event() {
  local status=$1 label=${2:-} title=${3:-} session_path=${4:-} rename_session=${5:-}
  : > "$herdr_log"
  : > "$pi_log"
  HERDR_BIN_PATH="$work/bin/herdr" \
  PI_BIN_PATH="$work/bin/pi" \
  HERDR_TEST_LOG="$herdr_log" \
  PI_TEST_LOG="$pi_log" \
  FAKE_STATUS="$status" \
  FAKE_LABEL="$label" \
  FAKE_TITLE="$title" \
  FAKE_SESSION_PATH="$session_path" \
  FAKE_RENAME_SESSION="$rename_session" \
  HERDR_PLUGIN_ID='local.auto-rename' \
  HERDR_PLUGIN_EVENT='pane.agent_status_changed' \
  HERDR_PLUGIN_EVENT_JSON="{\"event\":\"pane_agent_status_changed\",\"data\":{\"type\":\"pane_agent_status_changed\",\"pane_id\":\"p1\",\"agent_status\":\"$status\"}}" \
    "$subject" event
}

[ -x "$subject" ] || fail "missing executable $subject"

session_file="$work/pi-session.jsonl"
printf '%s\n' \
  '{"type":"session","version":3,"id":"session-1","cwd":"/repo"}' \
  '{"type":"session_info","name":"Pi automatic title"}' \
  '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Fix checkout timeout"}]}}' \
  > "$session_file"

run_event idle '' 'Pi automatic title' "$session_file"
assert_contains "$herdr_log" 'pane get p1'
assert_contains "$herdr_log" 'agent get p1'
assert_contains "$pi_log" '--model opencode-go/deepseek-v4-flash'
assert_contains "$pi_log" 'Fix checkout timeout'
assert_contains "$pi_log" '--no-tools'
assert_contains "$herdr_log" 'pane report-metadata p1 --source plugin:local.auto-rename --agent pi --title Implement authentication refresh --display-agent Implement authentication refresh --seq 11'
assert_contains "$herdr_log" "--token auto_rename_session=$session_file"

run_event idle '' 'Implement authentication refresh' "$session_file" "$session_file"
assert_empty "$pi_log"
if grep -F 'pane report-metadata' "$herdr_log" >/dev/null; then
  fail 'the same Pi session was renamed more than once'
fi

empty_session="$work/empty-pi-session.jsonl"
printf '%s\n' \
  '{"type":"session","version":3,"id":"session-2","cwd":"/repo"}' \
  '{"type":"session_info","name":"Pi automatic title"}' \
  > "$empty_session"
run_event idle '' 'Pi automatic title' "$empty_session"
assert_empty "$pi_log"
if grep -F 'pane report-metadata' "$herdr_log" >/dev/null; then
  fail 'Pi pane was renamed before its first user question'
fi

run_event working
assert_empty "$pi_log"
if grep -F 'pane report-metadata' "$herdr_log" >/dev/null; then
  fail 'working event renamed pane'
fi

run_event blocked 'Manual Name'
assert_empty "$pi_log"
if grep -F 'pane read' "$herdr_log" >/dev/null; then
  fail 'manual pane label was ignored'
fi

: > "$herdr_log"
: > "$pi_log"
HERDR_BIN_PATH="$work/bin/herdr" \
PI_BIN_PATH="$work/bin/pi" \
HERDR_TEST_LOG="$herdr_log" \
PI_TEST_LOG="$pi_log" \
FAKE_STATUS='idle' \
HERDR_PLUGIN_ID='local.auto-rename' \
  "$subject" all
assert_contains "$herdr_log" 'pane get p-idle'
if grep -F 'pane get p-working' "$herdr_log" >/dev/null; then
  fail 'startup sweep processed a working agent'
fi

: > "$herdr_log"
: > "$pi_log"
missing_stderr="$work/missing.stderr"
HERDR_BIN_PATH="$work/bin/herdr" \
PI_BIN_PATH="$work/bin/pi" \
HERDR_TEST_LOG="$herdr_log" \
PI_TEST_LOG="$pi_log" \
FAKE_PANE_MISSING=1 \
HERDR_PLUGIN_ID='local.auto-rename' \
HERDR_PLUGIN_EVENT='pane.agent_status_changed' \
HERDR_PLUGIN_EVENT_JSON='{"data":{"pane_id":"missing","agent_status":"idle"}}' \
  "$subject" event 2>"$missing_stderr"
assert_empty "$pi_log"
assert_empty "$missing_stderr"

: > "$herdr_log"
HERDR_BIN_PATH="$work/bin/herdr" \
HERDR_TEST_LOG="$herdr_log" \
FAKE_STATUS='idle' \
FAKE_SESSION_PATH="$session_file" \
HERDR_ACTIVE_PANE_ID='p1' \
  "$manual_subject" 'Manual Checkout Title'
assert_contains "$herdr_log" 'pane report-metadata p1 --source plugin:local.auto-rename --agent pi --title Manual Checkout Title --display-agent Manual Checkout Title --seq 12'
assert_contains "$herdr_log" "--token auto_rename_session=$session_file"

echo 'auto-rename plugin tests passed'
