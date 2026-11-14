#!/usr/bin/env bash
# test/live.sh -- proves the exit gate inside a real Claude Code run, not just against fixtures.
#
#   bash test/live.sh
#
# Makes a throwaway project whose only settings are this kit's hooks, then runs `claude -p` in plan
# mode twice with --setting-sources project, so none of your own user settings or hooks load
# (CLAUDE.md memory files are not settings and still load). Needs node for the stand-in approver.
#   1. Claude writes an UNSEALED plan and tries to leave plan mode  -> the gate must print DENY
#   2. Claude writes a SEALED plan and tries to leave plan mode    -> the gate must print ALLOW, arm
#      the handoff, and the approval must open no window, because nobody is present in a headless run
# The verdicts are read from the gate's own log, written by the hooks inside that run. A probe hook
# records the CLAUDE_CODE_ENTRYPOINT value the hooks saw, so a failure reads as a measurement. Should
# the handoff miss that value, the test flags it sets make it write its launcher into the run folder,
# where this script sees it, instead of opening a window.
#
# Costs two short model turns on whatever account `claude` is logged into. Plan files land in your
# usual plans folder and are deleted afterwards.
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v claude >/dev/null 2>&1 || { echo "FAIL live: claude is not on PATH"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL live: jq is not installed"; exit 2; }

P=$(mktemp -d)
if [ -n "${LIVE_KEEP:-}" ]; then echo "keeping the run folder: $P"; else trap 'rm -rf "$P"' EXIT; fi
STATE="$P/state"; mkdir -p "$P/proj/.claude" "$STATE" "$P/tmp"
H="$KIT/hooks"; command -v cygpath >/dev/null 2>&1 && H=$(cygpath -m "$H")
printf '%s\n' 'cat >/dev/null' 'printf "%s\n" "${CLAUDE_CODE_ENTRYPOINT-unset}" >> "$(dirname "$0")/entry.txt"' > "$P/seen-entry.sh"
PROBE="$P/seen-entry.sh"; command -v cygpath >/dev/null 2>&1 && PROBE=$(cygpath -m "$PROBE")
jq -n --arg h "$H" --arg probe "$PROBE" '{hooks:{
  UserPromptSubmit:[{hooks:[{type:"command",command:("bash \"" + $h + "/intent-inject.sh\"")}]}],
  PreToolUse:[{matcher:"ExitPlanMode",hooks:[{type:"command",command:("bash \"" + $h + "/intent-guard.sh\"")}]},
              {matcher:"AskUserQuestion",hooks:[{type:"command",command:("bash \"" + $h + "/question-guard.sh\"")}]}],
  PostToolUse:[{matcher:"ExitPlanMode",hooks:[{type:"command",command:("bash \"" + $h + "/plan-handoff.sh\"")},
                                              {type:"command",command:("bash \"" + $probe + "\"")}]}]}}' \
  > "$P/proj/.claude/settings.json"
TMPW="$P/tmp"; command -v cygpath >/dev/null 2>&1 && TMPW=$(cygpath -w "$TMPW")

SEALED='## Intent

- **WHO** - a test run of the intent-lock kit; nobody reads the output.
- **WHAT** - a plan to print the word hello from a shell script.
- **NOT** - no files are written by the build and nothing is installed.
- **WHY** - this run exists only to prove the exit gate allows a sealed plan.
- **HOW** - one shell command, run locally, reusing nothing.
- **DONE** - the gate log shows ALLOW for this plan, or stop after one turn.

<!-- INTENT-LOCK:CONFIRMED -->
<!-- INTENT-LOCK:WATCH -->

## Steps
1. Print hello.'

# A headless run offers ExitPlanMode only with a permission host, so approve-host.mjs stands in for
# the person who clicks approve. It logs to the gate's own log, which shows the gate ran first.
command -v node >/dev/null 2>&1 || { echo "FAIL live: node is needed for the stand-in approver"; exit 2; }
HOST="$KIT/test/approve-host.mjs"; command -v cygpath >/dev/null 2>&1 && HOST=$(cygpath -m "$HOST")
LOG="$STATE/guard.log"; command -v cygpath >/dev/null 2>&1 && LOG=$(cygpath -m "$LOG")
jq -n --arg host "$HOST" --arg log "$LOG" \
  '{mcpServers:{host:{command:"node",args:[$host],env:{APPROVE_HOST_LOG:$log}}}}' > "$P/mcp.json"

ask() {  # ask <label> <instruction>
  ( cd "$P/proj" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_PLUGIN_DIRS -u ANTHROPIC_API_KEY \
      -u INTENT_LOCK_WATCH_HERE -u INTENT_LOCK_GUIDE_MODEL \
      INTENT_LOCK_STATE="$STATE" TEMP="$TMPW" TMP="$TMPW" INTENT_LOCK_HANDOFF_NOWINDOW=1 INTENT_LOCK_HANDOFF_WAIT=1 \
      claude -p "$2" --setting-sources project --permission-mode plan --output-format stream-json --verbose \
      --mcp-config "$P/mcp.json" --strict-mcp-config --permission-prompt-tool mcp__host__approve \
      --max-turns 6 ) > "$P/$1.jsonl" 2>"$P/$1.err"
}
UNSEALED_TEXT='# Plan

1. Print hello.'
ask unsealed "This is a test of a plan-mode hook. Do not explore or ask questions. Write exactly this text as your plan file, then call ExitPlanMode once. If ExitPlanMode is refused, quote the refusal in one line and stop.

$UNSEALED_TEXT"
ask sealed "This is a test of a plan-mode hook. Do not explore or ask questions. Write exactly this text as your plan file, then call ExitPlanMode once and stop, whatever happens.

$SEALED"

echo "--- gate log written by the hook inside the two runs ---"
cat "$STATE/guard.log" 2>/dev/null || echo "(no log: the gate never ran)"
for r in unsealed sealed; do
  jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and (.name=="Write" or .name=="Edit")) | .input.file_path' \
    "$P/$r.jsonl" 2>/dev/null | tr -d '\r' | while read -r f; do case "$f" in *plans*) rm -f "$f" 2>/dev/null ;; esac; done
done
echo "--- verdicts ---"
d=$(grep -c ' DENY unsealed ' "$STATE/guard.log" 2>/dev/null); a=$(grep -c ' ALLOW confirmed watch ' "$STATE/guard.log" 2>/dev/null)
[ "${d:-0}" -ge 1 ] && echo "PASS live: the gate printed DENY on the unsealed plan" || echo "FAIL live: no DENY for the unsealed plan"
[ "${a:-0}" -ge 1 ] && echo "PASS live: the gate printed ALLOW on the sealed plan" || echo "FAIL live: no ALLOW for the sealed plan"
# Opens no window: the gate armed the handoff, the handoff ran and used the arm up, it logged that the
# run was headless, and no launcher was written. Each part alone could pass with the handoff skipped.
seen=$(tr -d '\r' < "$P/entry.txt" 2>/dev/null | sort -u | paste -sd, -); seen=${seen:-no PostToolUse hook ran}
armed=$(grep -c ' ALLOW confirmed watch armed ' "$STATE/guard.log" 2>/dev/null)
left=$(ls -A "$STATE/handoff" 2>/dev/null | wc -l)
quiet=$(grep -c 'HANDOFF none: headless run' "$STATE/guard.log" 2>/dev/null)
launched=$(ls "$P/tmp" 2>/dev/null | grep -c '^intent-lock-handoff-')
w=0
if [ "${armed:-0}" -ge 1 ] && [ "$left" -eq 0 ] && [ "${quiet:-0}" -ge 1 ] && [ "$launched" -eq 0 ]; then
  echo "PASS live: approving the sealed WATCH plan in a headless run opens no window (the hooks saw CLAUDE_CODE_ENTRYPOINT=$seen)"; w=1
else
  echo "FAIL live: approving the sealed WATCH plan in a headless run did not show that it opens no window (armed ${armed:-0}, arms left $left, headless lines ${quiet:-0}, launchers $launched; the hooks saw CLAUDE_CODE_ENTRYPOINT=$seen)"
fi
[ "${d:-0}" -ge 1 ] && [ "${a:-0}" -ge 1 ] && [ "$w" = 1 ]
