#!/usr/bin/env bash
set -euo pipefail

herdr=${HERDR_BIN_PATH:-herdr}
plugin_id=${HERDR_PLUGIN_ID:-local.auto-rename}
source_id="plugin:$plugin_id"
pane_id=${HERDR_ACTIVE_PANE_ID:-}
title=${1:-}

[ -n "$pane_id" ] || {
  printf 'No active Herdr pane.\n' >&2
  exit 1
}

if [ -z "$title" ]; then
  printf 'Pane title: '
  IFS= read -r title
fi

title=$(printf '%s\n' "$title" | awk '{$1=$1; print}')
[ -n "$title" ] || exit 0

pane_json=$("$herdr" pane get "$pane_id")
agent_json=$("$herdr" agent get "$pane_id")
agent=$(jq -r '.result.agent.agent // ""' <<<"$agent_json")
state_seq=$(jq -r '.result.agent.state_change_seq' <<<"$agent_json")
metadata_seq=$((state_seq + 1))
session_path=$(jq -r '.result.pane.agent_session | select(.kind == "path") | .value // ""' <<<"$pane_json")

[ -n "$agent" ] || {
  printf 'The active pane does not contain a recognized agent.\n' >&2
  exit 1
}

metadata_args=(
  pane report-metadata "$pane_id"
  --source "$source_id"
  --agent "$agent"
  --title "$title"
  --display-agent "$title"
  --seq "$metadata_seq"
)
[ -z "$session_path" ] || metadata_args+=(--token "auto_rename_session=$session_path")
"$herdr" "${metadata_args[@]}" >/dev/null
