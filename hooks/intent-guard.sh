#!/usr/bin/env bash
# intent-guard.sh -- PreToolUse hook on ExitPlanMode, part of the intent-lock kit (MIT, Ian Provencher).
#
# Refuses to leave plan mode until the plan file is sealed:
#   1. an `## Intent` section closed by <!-- INTENT-LOCK:CONFIRMED -->, or <!-- INTENT-LOCK:WAIVED -->
#   2. exactly one of <!-- INTENT-LOCK:WATCH --> or <!-- INTENT-LOCK:WALK -->
# A WALK plan arms plan-handoff.sh for this session, which opens a fresh auto-mode session on approval.
# A WALK passes only when plan-handoff.sh --check-done can build a /goal from the plan's DONE line.
#
# Claude Code injects the plan's path (tool_input.planFilePath) and text (tool_input.plan) into this
# hook's input. Markers count only on a line of their own, outside fenced or indented code, so a plan
# that quotes the marker while explaining it is not sealed by accident.
#
# Fails open, loudly: when it cannot read the plan or lacks jq, the exit is allowed and a warning goes
# to stderr and the log, so an unchecked exit never reads as a checked one.
#
# Verdicts are logged to $INTENT_LOCK_STATE/guard.log (default ~/.claude/intent-lock-state/).
# Switch off for good:  touch ~/.claude/.intent-off
set -u

STATE="${INTENT_LOCK_STATE:-$HOME/.claude/intent-lock-state}"
input=$(cat 2>/dev/null) || input=''

warn() { printf 'intent-lock: %s\n' "$1" >&2; }
log()  { mkdir -p "$STATE" 2>/dev/null
         printf '%s  %s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)" "$1" >> "$STATE/guard.log" 2>/dev/null; }

if ! command -v jq >/dev/null 2>&1; then
  warn "jq is not installed, so this plan exit was NOT checked"
  exit 0
fi
field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null | tr -d '\r'; }

[ "$(field .tool_name)" = "ExitPlanMode" ] || exit 0

if [ -f "$HOME/.claude/.intent-off" ]; then
  warn "switched off by ~/.claude/.intent-off; this plan exit was NOT checked"
  log "OFF unchecked exit"
  exit 0
fi

sid=$(field .session_id); sid="${sid//[^A-Za-z0-9._-]/_}"
pf=$(field .tool_input.planFilePath)
plan=''
if [ -n "$pf" ] && { : < "$pf"; } 2>/dev/null; then
  plan=$(cat "$pf" 2>/dev/null)
else
  plan=$(printf '%s' "$input" | jq -r '.tool_input.plan // empty' 2>/dev/null)
fi
name="${pf##*[/\\]}"; [ -n "$name" ] || name="the plan"

if [ -z "${plan//[[:space:]]/}" ]; then
  warn "could not read the plan (no readable planFilePath and no plan text), so this exit was NOT checked"
  log "UNCHECKED no plan text  $name"
  exit 0
fi

deny() {
  log "DENY $1  $name"
  warn "DENY $1  $name"
  jq -cn --arg r "intent-lock: $2 To switch the gate off: touch ~/.claude/.intent-off" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Marker on a line of its own, outside ``` / ~~~ fences and indented code blocks.
has() {
  printf '%s\n' "$plan" | awk -v want="$1" '
    { sub(/\r$/, "") }
    fence != "" { if ($0 ~ ("^[ \t]*" fence)) fence = ""; next }
    /^[ \t]*```/ { fence = "```"; next }
    /^[ \t]*~~~/ { fence = "~~~"; next }
    /^(    |\t)/ { next }
    $0 ~ ("^[ \t]*<!-- INTENT-LOCK:" want " -->[ \t]*$") { found = 1; exit }
    END { exit(found ? 0 : 1) }'
}

# Words under an "## Intent" heading, up to the seal. A seal over an empty section is not a seal.
intent_words() {
  printf '%s\n' "$plan" | awk '
    /^[ \t]*```/ { f = !f; next }
    f { next }
    /^[ \t]*<!-- INTENT-LOCK:(CONFIRMED|WAIVED) -->[ \t]*$/ { stop = 1 }
    /^#+[ \t]*[Ii]ntent/ && !stop { inh = 1; next }
    /^#+[ \t]/ && inh && !stop { inh = 0 }
    inh && !stop && !/^[ \t]*$/ && !/^[ \t]*<!--/ { n += NF }
    END { print n + 0 }'
}

if has CONFIRMED; then
  words=$(intent_words)
  [ "${words:-0}" -ge 40 ] || deny "hollow" "$name carries the CONFIRMED seal, but its Intent section holds only ${words:-0} words, so the seal landed and the answers did not. Write WHO / WHAT / NOT / WHY / HOW / DONE under an '## Intent' heading above the seal, then exit plan mode again."
  seal=confirmed
elif has WAIVED; then
  seal=waived
else
  deny "unsealed" "$name has no confirmed intent, so this plan may be built on assumed intent. Interrogate until the ledger is empty and the user confirms a restatement (put it inside the question box), then write WHO / WHAT / NOT / WHY / HOW / DONE as an '## Intent' section at the top of the plan file, sealed with the line <!-- INTENT-LOCK:CONFIRMED -->. To skip the gate for this one plan, the user can have you write <!-- INTENT-LOCK:WAIVED --> instead."
fi

how=''
has WATCH && how=watch
if has WALK; then
  [ -z "$how" ] || deny "two-answers" "$name carries both <!-- INTENT-LOCK:WATCH --> and <!-- INTENT-LOCK:WALK -->. Keep the line matching the user's answer, delete the other, then exit plan mode again."
  how=walk
fi
[ -n "$how" ] || deny "no-watch-walk" "$name is sealed, and one question is left. Ask the user in the question box: \"Will you watch this build in this window, or walk away from it?\" Watching: approval continues in this window as normal. Walking away: approval opens a fresh auto-mode session that builds the plan under a /goal check made from the DONE slot. Write the answer into the plan as a line of its own, <!-- INTENT-LOCK:WATCH --> or <!-- INTENT-LOCK:WALK -->, then exit plan mode again."

# A walk-away exists to have a separate grader watch the build, so it passes only when the handoff
# says it can build the /goal from this plan. The handoff answers for itself rather than this file
# keeping a copy of its DONE pattern. The words are required as well as the exit code, so a missing
# or stand-in handoff that exits 0 having checked nothing does not count.
if [ "$how" = walk ]; then
  ho="$(dirname "${BASH_SOURCE[0]}")/plan-handoff.sh"
  [ -f "$ho" ] || deny "walk-unchecked" "$name is answered walk away, but plan-handoff.sh is missing beside this hook ($ho), so no fresh session can open. Ask the user whether to watch here instead, and change the plan's line to <!-- INTENT-LOCK:WATCH --> if they agree."
  said=$(printf '%s' "$plan" | bash "$ho" --check-done "${pf:-(the plan)}" 2>&1); rc=$?
  said=${said//$'\r'/}
  [ "$rc" -eq 0 ] && [[ $said == *'goal set from DONE'* ]] \
    || deny "walk-no-goal" "$name is answered walk away, but the handoff answered \"${said:0:240}\", so the fresh session would open with no grader. Write the DONE slot as its own labelled line, such as '- **DONE:** <the check that settles it>', then exit plan mode again."
fi

rec="$STATE/handoff/$sid"
if [ "$how" = walk ]; then
  if [ -z "$sid" ]; then
    warn "no session id in the hook input, so the walk-away handoff could not be armed; approval will continue in this window"
  elif ! { mkdir -p "$STATE/handoff" && printf '%s\n' "${pf:--}" > "$rec"; } 2>/dev/null; then
    warn "could not write $rec, so the walk-away handoff is NOT armed; approval will continue in this window"
  fi
else
  [ -n "$sid" ] && rm -f "$rec" 2>/dev/null
fi

log "ALLOW $seal $how  $name"
warn "ALLOW $seal $how  $name"
exit 0
