#!/usr/bin/env bash
# plan-handoff.sh -- PostToolUse hook on ExitPlanMode, part of the intent-lock kit (MIT, Ian Provencher).
#
# After a plan is approved, and ONLY when intent-guard.sh armed it (the plan said WALK), this opens a
# fresh Claude Code session in auto mode whose first prompt is
#     /goal Carry out the approved plan at <path> ... Done when ... <the plan's DONE slot>
# so a separate grader checks the build against DONE from its first turn, in a clean context.
#
#   Windows   opens a new Windows Terminal tab (or a PowerShell window) running that command
#   Mac/Linux prints the exact command for you to run in a new terminal
#
# With nothing armed it prints nothing and approval behaves exactly as normal. The arm is consumed
# before anything else, so a failure means a normal approval, never a handoff that fires next time.
# Fails open: any problem tells Claude, in one line, to say so and carry on in this window.
#
# INTENT_LOCK_HANDOFF_DRYRUN=1 prints what would be launched instead of launching it.
#
#   plan-handoff.sh --check-done <plan path>   (plan text on stdin)
# launches nothing: it prints "goal set from DONE (N characters)" and exits 0, or "goal NOT set: ..."
# and exits 1. intent-guard.sh asks it before letting a walk-away through, so the DONE pattern lives
# in this file alone.
set -u

STATE="${INTENT_LOCK_STATE:-$HOME/.claude/intent-lock-state}"

# The DONE slot and the lines that continue it, up to a blank line, the next slot label, a heading,
# a comment or a top-level bullet. The label may be bold (**DONE**, **DONE:**, **DONE.**), plain
# (- DONE: ...) or bare (DONE its suite passes). awk matches case-sensitively, so prose such as
# "Done when ..." is never taken for the label.
done_of() {
  printf '%s\n' "$1" | awk '
    BEGIN { lead = "^(\342\200\224|\342\200\223|:|-|\\.)[ \t]*"
            label = "^[ \t]*([-*][ \t]+)?(\\*\\*DONE[:.]?\\*\\*|DONE)" }
    { sub(/\r$/, "") }
    !on && $0 ~ "^[ \t]*([-*][ \t]+)?(\\*\\*DONE[:.]?\\*\\*|DONE([^A-Za-z0-9_]|$))" {
      on = 1; l = $0; sub(label, "", l); sub(/^[ \t]*/, "", l)
      sub(lead, "", l); out = l; next }
    on && (/^[ \t]*$/ || /^[ \t]*([-*][ \t]+)?\*\*[A-Z][A-Za-z ]*[:.]?\*\*/ \
        || /^[ \t]*([-*][ \t]+)?(WHO|WHAT|NOT|WHY|HOW|DONE)([^A-Za-z0-9_]|$)/ \
        || /^[ \t]*([-*][ \t]+)?[A-Z][A-Z]+[ \t]*(:|\342\200\224|\342\200\223)/ \
        || /^[ \t]*#/ || /^[ \t]*<!--/ || /^[-*][ \t]/) { exit }
    on { l = $0; gsub(/^[ \t]+|[ \t]+$/, "", l); out = out " " l }
    END { gsub(/[ \t]+/, " ", out); sub(/^ /, "", out); print out }'
}

# Sets cond and goal_note from the plan text and the path shown to the new session.
goal_for() {
  local d; d=$(done_of "$1"); cond=''
  if [ -n "${d// /}" ]; then
    cond="Carry out the approved plan at $2; read it first, it is sealed, approved and the scope. Done when all of this is shown by output in this conversation: $d"
    if [ "${#cond}" -le 4000 ]; then goal_note="goal set from DONE (${#cond} characters)"
    else goal_note="goal NOT set: the condition would be ${#cond} characters, past the 4,000 /goal accepts"; cond=''; fi
  else
    goal_note="goal NOT set: the plan has no DONE line this hook can read"
  fi
}

if [ "${1:-}" = "--check-done" ]; then
  goal_for "$(cat 2>/dev/null)" "${2:-(the plan)}"
  printf '%s\n' "$goal_note"
  [ -n "$cond" ]; exit
fi

input=$(cat 2>/dev/null) || input=''

re='"session_id"[[:space:]]*:[[:space:]]*"([^"]+)"'
[[ $input =~ $re ]] || exit 0
sid=${BASH_REMATCH[1]//[^A-Za-z0-9._-]/_}
rec="$STATE/handoff/$sid"
[ -f "$rec" ] || exit 0

say() {
  printf 'plan-handoff: %s\n' "$1" >&2
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg c "$1" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
  else
    printf '%s\n' "$1"
  fi
  exit 0
}

recorded=$(head -n 1 "$rec" 2>/dev/null | tr -d '\r')
rm -f "$rec" 2>/dev/null
command -v jq >/dev/null 2>&1 || say "The walk-away handoff was armed, but jq is not installed, so no fresh session was opened. Tell the user in one line and carry on in this window."

plan_path=$(printf '%s' "$input" | jq -r '(.tool_response | objects | .filePath) // .tool_input.planFilePath // empty' 2>/dev/null | tr -d '\r')
[ -n "$plan_path" ] || { [ "$recorded" != "-" ] && plan_path="$recorded"; }
plan=$(printf '%s' "$input" | jq -r '(.tool_response | objects | .plan) // .tool_input.plan // empty' 2>/dev/null)
if [ -z "${plan//[[:space:]]/}" ] && [ -n "$plan_path" ] && { : < "$plan_path"; } 2>/dev/null; then
  plan=$(cat "$plan_path")
fi
[ -n "${plan//[[:space:]]/}" ] || say "The walk-away handoff was armed, but the approved plan could not be read, so no fresh session was opened. Tell the user in one line and carry on in this window."

shown_path="$plan_path"; [ -n "$shown_path" ] || shown_path="(the plan approved in the previous session)"
goal_for "$plan" "$shown_path"
[ -n "$cond" ] && prompt="/goal $cond"
[ -n "${prompt:-}" ] || prompt="Carry out the approved plan at $shown_path. Read it first; it is sealed, approved and the scope. No /goal was set, because ${goal_note#goal NOT set: }, so tell the user no separate grader is watching this build."

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r'); [ -n "$cwd" ] || cwd="$PWD"
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
unix_cmd="cd $(sq "$cwd") && claude --permission-mode auto $(sq "$prompt")"

case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) win=1 ;; *) win=0 ;; esac
[ "${OS:-}" = "Windows_NT" ] && win=1
case "${INTENT_LOCK_PLATFORM:-}" in unix) win=0 ;; windows) win=1 ;; esac

if [ "$win" = 0 ]; then
  [ "${INTENT_LOCK_HANDOFF_DRYRUN:-}" = 1 ] && printf 'DRYRUN unix: %s\n' "$unix_cmd" >&2
  say "THE PLAN HANDOFF IS ARMED ($goal_note). Do not start work on this plan here. Show the user this exact command to run in a new terminal, explain that it opens a fresh auto-mode session that builds the plan, and stop:

    $unix_cmd"
fi

psq() { printf "'%s'" "${1//\'/\'\'}"; }
# Start-Process joins -ArgumentList with plain spaces and adds no quotes, so a path holding a space
# arrives in two pieces (2026-10-13: a folder named "New Bern" reached Windows Terminal as a program
# called "Bern"). psqq hands PowerShell a literal whose value carries its own double quotes.
psqq() { psq "\"$1\""; }
wcwd=$(cygpath -w "$cwd" 2>/dev/null || printf '%s' "$cwd")
tmp=$(cygpath -w "${TEMP:-/tmp}" 2>/dev/null || printf '%s' "${TEMP:-/tmp}")
launcher="$tmp\\intent-lock-handoff-$sid.ps1"
body="Set-Location -LiteralPath $(psq "$wcwd")
Remove-Item -LiteralPath $(psq "$launcher") -Force -ErrorAction SilentlyContinue
claude --permission-mode auto $(psq "$prompt")"

shell=pwsh.exe; command -v pwsh.exe >/dev/null 2>&1 || shell=powershell.exe
# No -d for Windows Terminal: the launcher's first line moves into the folder itself, so the folder
# never has to survive wt.exe's own parsing, where a semicolon also separates commands.
fallback="Start-Process $shell -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File',$(psqq "$launcher") -WorkingDirectory $(psq "$wcwd")"

if [ "${INTENT_LOCK_HANDOFF_DRYRUN:-}" = 1 ]; then
  printf 'DRYRUN windows launcher %s:\n%s\n' "$launcher" "$body" >&2
  printf 'DRYRUN windows terminal: wt.exe %s -NoExit -ExecutionPolicy Bypass -File %s\n' "$shell" "$launcher" >&2
  printf 'DRYRUN windows fallback: powershell.exe -NoProfile -Command %s\n' "$fallback" >&2
  say "DRYRUN: the handoff would open a fresh auto-mode session in $wcwd ($goal_note)."
fi

launcher_u=$(cygpath -u "$launcher" 2>/dev/null || printf '%s' "$launcher")
printf '%s\n' "$body" > "$launcher_u" 2>/dev/null \
  || say "The walk-away handoff was armed, but its launcher could not be written to $launcher, so no fresh session was opened. Tell the user in one line and carry on in this window."
if command -v wt.exe >/dev/null 2>&1; then
  wt.exe "$shell" -NoExit -ExecutionPolicy Bypass -File "$launcher" >/dev/null 2>&1 &
else
  powershell.exe -NoProfile -Command "$fallback" >/dev/null 2>&1 &
fi
# Starting the terminal proves nothing: a launch that fails is reported inside the new window, where
# this hook cannot see it. The launcher deletes itself on its second line, so its disappearance is
# the proof that the new window ran it.
waited=0
while [ -f "$launcher_u" ] && [ "$waited" -lt 25 ]; do sleep 1; waited=$((waited + 1)); done
if [ -f "$launcher_u" ]; then
  say "THE PLAN HANDOFF DID NOT START: a new window was asked for, but within 25 seconds nothing ran its launcher, so no fresh session is building this plan. Tell the user in one line, and give them this command to open it by hand: wt.exe $shell -NoExit -ExecutionPolicy Bypass -File \"$launcher\" . Do not start work on this plan here unless they say so."
fi
say "THE PLAN HANDOFF HAS FIRED: a fresh auto-mode session has started in a new window to build this plan ($goal_note). Do not start work on this plan here, because two sessions building one plan collide. Tell the user the new window has it and this one can be closed, then stop."
