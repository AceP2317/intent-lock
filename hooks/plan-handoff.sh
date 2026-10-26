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
# It fires only for the exit that armed it, named by the id both hooks receive for one ExitPlanMode
# call, and only while the plan as approved still says WALK: the approval dialog can edit the plan,
# and a WALK changed there to WATCH is the user choosing to watch.
# Fails open, loudly: any problem is printed for the user's screen and told to Claude, which says so
# and carries on in this window.
#
# INTENT_LOCK_HANDOFF_DRYRUN=1 prints what would be launched instead of launching it.
#
#   plan-handoff.sh --check-done <plan path>   (plan text on stdin)
# launches nothing: it prints "goal set from DONE (N characters)" and exits 0, or "goal NOT set: ..."
# and exits 1. intent-guard.sh asks it before letting a walk-away through, so the DONE pattern lives
# in this file alone.
set -u

STATE="${INTENT_LOCK_STATE:-$HOME/.claude/intent-lock-state}"

# The DONE slot and the lines that continue it, up to the next slot label, a heading, a comment or a
# top-level bullet. The label may be bold (**DONE**, **DONE:**, **DONE.**, **Done:**), plain
# (- DONE: ..., - Done: ...) or bare (DONE its suite passes). awk matches case-sensitively, so prose
# such as "Done when ..." is never taken for the label. Four rules keep the grader's criteria whole:
#   * a DONE ending in a colon is a lead-in, and the list under it (numbered or bulleted, at the
#     margin or after a blank line) is DONE too;
#   * a line indented deeper than the DONE line continues it whatever word it opens with, so
#     "  - CSV: the export matches" or "  NOT one case slips through" does not cut DONE short;
#   * DONE is looked for in the Intent section first, and never inside a code fence or an HTML
#     comment, so a quoted template or an old draft is not taken for it;
#   * a blank line ends DONE unless text indented under it, or the list under a lead-in, follows.
done_of() {
  printf '%s\n' "$1" | awk '
    BEGIN { lead = "^(\342\200\224|\342\200\223|:|-|\\.)[ \t]*" }
    { sub(/\r$/, ""); L[++n] = $0 }
    function indent(s,   t) { t = s; sub(/^[ \t]+/, "", t); return length(s) - length(t) }
    function islabel(s) {
      return s ~ /^[ \t]*([-*][ \t]+)?\*\*[Dd][Oo][Nn][Ee][:.]?\*\*/ \
          || s ~ /^[ \t]*([-*][ \t]+)?DONE([^A-Za-z0-9_]|$)/ \
          || s ~ /^[ \t]*([-*][ \t]+)?[Dd][Oo][Nn][Ee][ \t]*:/ }
    function slotlabel(s) {
      return s ~ /^[ \t]*([-*][ \t]+)?\*\*[A-Z][A-Za-z ]*[:.]?\*\*/ \
          || s ~ /^[ \t]*([-*][ \t]+)?(WHO|WHAT|NOT|WHY|HOW|DONE)[ \t]*(:|-|\342\200\224|\342\200\223)/ }
    function slotstop(s) {
      return slotlabel(s) || s ~ /^[ \t]*([-*][ \t]+)?(WHO|WHAT|NOT|WHY|HOW|DONE)([^A-Za-z0-9_]|$)/ \
          || s ~ /^[ \t]*([-*][ \t]+)?[A-Z][A-Z]+[ \t]*(:|\342\200\224|\342\200\223)/ \
          || s ~ /^[ \t]*#/ || s ~ /^[ \t]*<!--/ || s ~ /^[-*][ \t]/ || s ~ /^[0-9]+\.[ \t]/ }
    function listitem(s) { return s ~ /^[ \t]*([-*]|[0-9]+[.)])[ \t]/ }
    END {
      for (i = 1; i <= n; i++) {
        s = L[i]; P[i] = 0
        if (com) { if (s ~ /-->/) com = 0; continue }
        if (s ~ /^[ \t]*(```|~~~)/) { fence = !fence; continue }
        if (fence) continue
        if (s ~ /^[ \t]*<!--/) { if (s !~ /-->/) com = 1; continue }
        P[i] = 1
      }
      for (i = 1; i <= n; i++) if (L[i] ~ /^#+[ \t]*Intent([^A-Za-z0-9_]|$)/) {
        lv = match(L[i], /[^#]/) - 1; is = i; ie = n + 1
        for (j = i + 1; j <= n; j++) if (L[j] ~ /^#+[ \t]/ && match(L[j], /[^#]/) - 1 <= lv) { ie = j; break }
        break }
      for (i = is; is && i < ie; i++) if (P[i] && islabel(L[i])) { start = i; break }
      if (!start) for (i = 1; i <= n; i++) if (P[i] && islabel(L[i])) { start = i; break }
      if (!start) { print ""; exit }
      ind = indent(L[start]); out = L[start]
      sub(/^[ \t]*([-*][ \t]+)?(\*\*[Dd][Oo][Nn][Ee][:.]?\*\*|DONE|[Dd][Oo][Nn][Ee])/, "", out)
      sub(/^[ \t]*/, "", out); sub(lead, "", out)
      for (j = start + 1; j <= n; j++) {
        s = L[j]; leadin = inlist || out ~ /:[ \t]*$/
        if (s ~ /^[ \t]*$/) {
          k = j + 1; while (k <= n && L[k] ~ /^[ \t]*$/) k++
          if (k > n || L[k] ~ /^[ \t]*(#|<!--|```|~~~)/) break
          if (indent(L[k]) > ind) continue
          if (leadin && listitem(L[k]) && !slotlabel(L[k])) continue
          break
        }
        if (s ~ /^[ \t]*(#|<!--)/) break
        t = s; gsub(/^[ \t]+|[ \t]+$/, "", t)
        if (indent(s) > ind) { out = out " " t; continue }
        if (leadin && listitem(s) && !slotlabel(s)) { inlist = 1; out = out " " t; continue }
        if (slotstop(s)) break
        out = out " " t
      }
      gsub(/[ \t]+/, " ", out); sub(/^ /, "", out); sub(/ $/, "", out); print out
    }'
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

# say: one object, read by the user's screen (systemMessage) and by Claude (additionalContext). stderr
# alone would not do: Claude Code sends a hook's stderr to its debug log when the hook exits 0.
say() {
  printf 'plan-handoff: %s\n' "$1" >&2
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg c "plan-handoff: $1" '{systemMessage:$c, hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
  else
    printf '%s\n' '{"systemMessage":"plan-handoff: the walk-away handoff was armed, but jq is not installed, so no fresh session was opened.","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"plan-handoff: the walk-away handoff was armed, but jq is not installed, so no fresh session was opened. Tell the user in one line and carry on in this window."}}'
  fi
  exit 0
}

rec_id=''; recorded=''
read -r rec_id recorded < "$rec" 2>/dev/null
rec_id=${rec_id//$'\r'/}; recorded=${recorded//$'\r'/}
rm -f "$rec" 2>/dev/null
command -v jq >/dev/null 2>&1 || say "jq is not installed"
tu=$(printf '%s' "$input" | jq -r '.tool_use_id // empty' 2>/dev/null | tr -d '\r')
[ -n "$tu" ] && [ "$rec_id" = "$tu" ] \
  || say "The walk-away handoff was armed by an earlier plan exit, not the one just approved, so no fresh session was opened. Tell the user in one line and carry on in this window."

plan_path=$(printf '%s' "$input" | jq -r '(.tool_response | objects | .filePath) // .tool_input.planFilePath // empty' 2>/dev/null | tr -d '\r')
[ -n "$plan_path" ] || { [ "$recorded" != "-" ] && plan_path="$recorded"; }
plan=$(printf '%s' "$input" | jq -r '(.tool_response | objects | .plan) // .tool_input.plan // empty' 2>/dev/null)
if [ -z "${plan//[[:space:]]/}" ] && [ -n "$plan_path" ] && { : < "$plan_path"; } 2>/dev/null; then
  plan=$(cat "$plan_path")
fi
[ -n "${plan//[[:space:]]/}" ] || say "The walk-away handoff was armed, but the approved plan could not be read, so no fresh session was opened. Tell the user in one line and carry on in this window."
. "$(dirname "${BASH_SOURCE[0]}")/lib/marker.sh" 2>/dev/null \
  || say "The walk-away handoff was armed, but lib/marker.sh is missing beside this hook, so the approved plan's WATCH or WALK line could not be read and no fresh session was opened. Tell the user in one line and carry on in this window."
has_marker "$plan" WATCH \
  && say "The approved plan says WATCH, a change made in the approval dialog, so no fresh session was opened. Tell the user in one line and carry on in this window."
has_marker "$plan" WALK \
  || say "The approved plan no longer carries its WALK line, so no fresh session was opened. Tell the user in one line and carry on in this window."

shown_path="$plan_path"; [ -n "$shown_path" ] || shown_path="(the plan approved in the previous session)"
goal_for "$plan" "$shown_path"
[ -n "$cond" ] && prompt="/goal $cond"
[ -n "${prompt:-}" ] || prompt="Carry out the approved plan at $shown_path. Read it first; it is sealed, approved and the scope. No /goal was set, because ${goal_note#goal NOT set: }, so tell the user no separate grader is watching this build."

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r'); [ -n "$cwd" ] || cwd="$PWD"
# The approving window's effort level, from this hook's own input. Without it the new session starts
# at the saved default for its model, so a plan made at a raised level is built below it. --effort
# sets that session alone. Only a level `claude --help` lists is passed; anything else is dropped.
effort=$(printf '%s' "$input" | jq -r '.effort.level? // empty' 2>/dev/null | tr -d '\r')
case "$effort" in
  low|medium|high|xhigh|max) eff_flag=" --effort $effort"; goal_note="$goal_note; effort $effort carried" ;;
  *) eff_flag=''; goal_note="$goal_note; effort not carried, so the saved default applies" ;;
esac
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
unix_cmd="cd $(sq "$cwd") && claude --permission-mode auto$eff_flag $(sq "$prompt")"

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
claim="$tmp\\intent-lock-handoff-$sid.claim"
# The launcher enters the plan's folder or stops, because claude started anywhere else builds in the
# wrong place. Then it CLAIMS the launch: this hook claims the same file when its wait runs out, and
# creating it is all-or-nothing, so a window that starts late finds the handoff called off and builds
# nothing. The claim runs only from the real launcher file, so a printed copy run by a test writes none.
body="try { Set-Location -LiteralPath $(psq "$wcwd") -ErrorAction Stop; \$hand = 'STARTED' } catch { \$hand = 'FOLDER-FAILED: ' + \$_.Exception.Message }
if (Test-Path -LiteralPath $(psq "$launcher")) { try { \$f = [IO.File]::Open($(psq "$claim"), 'CreateNew', 'Write'); \$w = [IO.StreamWriter]::new(\$f); \$w.Write(\$hand); \$w.Close() } catch { Write-Host 'intent-lock: this handoff was called off, because the session that asked for it had stopped waiting.'; return } }
if (\$hand -ne 'STARTED') { Write-Host ('intent-lock: ' + \$hand); return }
Remove-Item -LiteralPath $(psq "$launcher") -Force -ErrorAction SilentlyContinue
claude --permission-mode auto$eff_flag $(psq "$prompt")"

shell=pwsh.exe; command -v pwsh.exe >/dev/null 2>&1 || shell=powershell.exe
# No -d for Windows Terminal: the launcher's first line moves into the folder itself, so the folder
# never has to survive wt.exe's own parsing, where a semicolon also separates commands.
# No -WorkingDirectory: Start-Process refuses a folder holding square brackets, and the launcher enters
# the folder itself on its first line.
fallback="Start-Process $shell -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File',$(psqq "$launcher")"

if [ "${INTENT_LOCK_HANDOFF_DRYRUN:-}" = 1 ]; then
  printf 'DRYRUN windows launcher %s:\n%s\n' "$launcher" "$body" >&2
  printf 'DRYRUN windows terminal: wt.exe %s -NoExit -ExecutionPolicy Bypass -File %s\n' "$shell" "$launcher" >&2
  printf 'DRYRUN windows fallback: powershell.exe -NoProfile -Command %s\n' "$fallback" >&2
  say "DRYRUN: the handoff would open a fresh auto-mode session in $wcwd ($goal_note)."
fi

launcher_u=$(cygpath -u "$launcher" 2>/dev/null || printf '%s' "$launcher")
claim_u=$(cygpath -u "$claim" 2>/dev/null || printf '%s' "$claim")
# The names are per session, so a claim left by an earlier handoff in this session is cleared first.
rm -f "$claim_u" 2>/dev/null
printf '%s\n' "$body" > "$launcher_u" 2>/dev/null \
  || say "The walk-away handoff was armed, but its launcher could not be written to $launcher, so no fresh session was opened. Tell the user in one line and carry on in this window."
# PSModulePath is cleared on the way out: started from PowerShell 7, Windows PowerShell inherits 7's
# module folders first and can lose a built-in command (seen 2026-08-22 on the machine this came from).
# INTENT_LOCK_HANDOFF_NOWINDOW=1 (tests only) opens no window, and the wait below runs as usual.
if [ "${INTENT_LOCK_HANDOFF_NOWINDOW:-}" = 1 ]; then
  :
elif command -v wt.exe >/dev/null 2>&1; then
  env -u PSModulePath wt.exe "$shell" -NoExit -ExecutionPolicy Bypass -File "$launcher" >/dev/null 2>&1 &
else
  env -u PSModulePath powershell.exe -NoProfile -Command "$fallback" >/dev/null 2>&1 &
fi
# Starting the terminal proves nothing: a launch that fails is reported inside the new window, where
# this hook cannot see it. The claim says what happened. Until 2026-10-14 the proof was the launcher
# deleting itself, and a delete that failed quietly, or a window slower than the wait, read as "did not
# start" while the window went on to build: two sessions on one plan.
limit="${INTENT_LOCK_HANDOFF_WAIT:-60}"; state=''; waited=0
while [ "$waited" -lt "$limit" ]; do
  if [ -s "$claim_u" ]; then state=$(cat "$claim_u" 2>/dev/null); [ -n "$state" ] && break; fi
  sleep 1; waited=$((waited + 1))
done
if [ -z "$state" ]; then
  if ( set -o noclobber; printf 'CALLED-OFF' > "$claim_u" ) 2>/dev/null; then state=CALLED-OFF
  else sleep 2; state=$(cat "$claim_u" 2>/dev/null); fi
fi
case "$state" in
  STARTED) rm -f "$claim_u" 2>/dev/null ;;
  FOLDER-FAILED*) rm -f "$claim_u" 2>/dev/null
    say "THE PLAN HANDOFF DID NOT START: the new window opened but could not enter $wcwd (${state#FOLDER-FAILED: }), so no fresh session is building this plan. Tell the user in one line. The launcher is kept at $launcher; once the folder is back it opens with: wt.exe $shell -NoExit -ExecutionPolicy Bypass -File \"$launcher\" . Do not start work on this plan here unless they say so." ;;
  CALLED-OFF)
    say "THE PLAN HANDOFF DID NOT START: a new window was asked for, but within $limit seconds nothing ran its launcher, so the handoff was called off and a window that starts later builds nothing. Tell the user in one line; to open it by hand, delete $claim and run: wt.exe $shell -NoExit -ExecutionPolicy Bypass -File \"$launcher\" . Do not start work on this plan here unless they say so." ;;
  *)
    say "THE PLAN HANDOFF MAY NOT HAVE STARTED: its claim at $claim could not be read, so whether a fresh session is building this plan is unknown. Tell the user in one line, and ask them to look for the new window before anything is built here." ;;
esac
say "THE PLAN HANDOFF HAS FIRED: a fresh auto-mode session has started in a new window to build this plan ($goal_note). Do not start work on this plan here, because two sessions building one plan collide. Tell the user the new window has it and this one can be closed, then stop."
