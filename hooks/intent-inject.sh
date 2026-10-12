#!/usr/bin/env bash
# intent-inject.sh -- UserPromptSubmit hook, part of the intent-lock kit (MIT, Ian Provencher).
#
# When a prompt is submitted in plan mode, prints the intent-lock method and the question rules so
# Claude reads them before planning. The full text is sent once per session; later plan-mode turns
# get a one-paragraph reminder. Plain stdout from this event is added to Claude's context.
#
# Fails open: if it cannot read its input or its files, the prompt goes through untouched and a
# warning goes to stderr (and, where it can, into Claude's context), so a missing method never
# reads as a method that ran.
#
# Switch off for good:  touch ~/.claude/.intent-off
set -u

KIT="${INTENT_LOCK_KIT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
STATE="${INTENT_LOCK_STATE:-$HOME/.claude/intent-lock-state}"
skill="$KIT/skill/intent-lock/SKILL.md"
rules="$KIT/rules/questions.md"

input=$(cat 2>/dev/null) || input=''
warn() { printf 'intent-lock: %s\n' "$1" >&2; }

if ! command -v jq >/dev/null 2>&1; then
  warn "jq is not installed, so plan mode is running WITHOUT the intent-lock method"
  exit 0
fi
mode=$(printf '%s' "$input" | jq -r '.permission_mode // empty' 2>/dev/null | tr -d '\r')
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r')
[ "$mode" = "plan" ] || exit 0

if [ -f "$HOME/.claude/.intent-off" ]; then
  warn "switched off by ~/.claude/.intent-off; plan mode is running without the method"
  exit 0
fi

body=''
{ : < "$skill"; } 2>/dev/null && body=$(sed -n '/INTENT-INJECT:START/,/INTENT-INJECT:END/{//!p;}' "$skill" 2>/dev/null)
if [ -z "${body//[[:space:]]/}" ]; then
  msg="intent-lock method NOT LOADED: $skill is missing or has no INTENT-INJECT block. Tell the user before planning further."
  warn "$msg"; printf '%s\n' "$msg"
  exit 0
fi

# Once per session: mkdir is atomic, so two prompts racing cannot both win the full send.
full=1
if [ -n "$sid" ]; then
  safe="${sid//[^A-Za-z0-9._-]/_}"
  mkdir -p "$STATE/sessions" 2>/dev/null
  find "$STATE/sessions" -mindepth 1 -maxdepth 1 -type d -mmin +720 -exec rm -rf {} + 2>/dev/null
  mkdir "$STATE/sessions/$safe" 2>/dev/null || full=0
fi

if [ "$full" = 0 ]; then
  printf '%s\n' "intent-lock is active; its method loaded earlier this session. Ask whatever would most change the build, keep the ledger, put the restatement inside the question box, then seal the plan with <!-- INTENT-LOCK:CONFIRMED --> and a WATCH or WALK line."
  exit 0
fi

printf '%s\n\n' "Plan mode: apply intent-lock before committing to a build direction. Do not plan on assumed intent."
printf '%s\n' "$body"
if { : < "$rules"; } 2>/dev/null; then
  printf '\n## Question rules\n\n'
  sed '1,/^- /{/^- /!d}' "$rules"
else
  warn "question rules not found at $rules; the method loaded without them"
fi
exit 0
