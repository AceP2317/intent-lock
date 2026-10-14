#!/usr/bin/env bash
# test/run.sh -- runs every kit hook against fixtures, in both directions.
#
#   bash test/run.sh
#
# Every refusal is paired with a twin that must pass, and every hook's first check is a negative
# control: an input the hook must leave alone. A hook that refuses everything, or nothing, fails here.
# Hermetic: each hook runs with a scratch HOME and state folder, so nothing on your machine is read
# or written. Needs bash, jq and awk, the same as the hooks.
set -u
LC_ALL=C
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$HERE/.." && pwd)
H="$KIT/hooks"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is not installed, so nothing was tested"; exit 2; }

pass=0; fail=0; group_fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); group_fail=$((group_fail+1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:0:400}"; }
group() { [ -n "${G:-}" ] && summary; G=$1; group_fail=0; printf '\n== %s ==\n' "$1"; }
summary() { if [ "$group_fail" = 0 ]; then printf 'PASS %s\n' "$G"; else printf 'FAIL %s (%s failed)\n' "$G" "$group_fail"; fi; }

OUT=''; ERR=''
fresh() { rm -rf "$T/home" "$T/state"; mkdir -p "$T/home/.claude" "$T/state"; }
run() {  # run <hook> <json>  -> OUT (stdout), ERR (stderr)
  OUT=$(printf '%s' "$2" | HOME="$T/home" INTENT_LOCK_STATE="$T/state" INTENT_LOCK_KIT="${KITDIR:-$KIT}" \
        INTENT_LOCK_HANDOFF_DRYRUN=1 INTENT_LOCK_PLATFORM="${PLATFORM:-}" bash "$H/$1" 2>"$T/err")
  ERR=$(cat "$T/err")
}
denied() { [[ $OUT == *'"permissionDecision":"deny"'* ]]; }
expect_deny()  { if denied; then ok "$1"; else bad "$1" "expected DENY, got: $OUT $ERR"; fi; }
expect_allow() { if denied; then bad "$1" "expected ALLOW, got: $OUT"; else ok "$1"; fi; }

# --- intent-inject -------------------------------------------------------------------------------
group "intent-inject: loads the method in plan mode, once per session"
fresh
run intent-inject.sh '{"session_id":"s1","permission_mode":"default","prompt":"hi"}'
[ -z "$OUT" ] && ok "negative control: silent outside plan mode" || bad "negative control: silent outside plan mode" "$OUT"
run intent-inject.sh '{"session_id":"s1","permission_mode":"plan","prompt":"build x"}'
[[ $OUT == *"apply intent-lock"* && $OUT == *"## Six slots"* && $OUT == *"## Question rules"* ]] \
  && ok "first plan-mode prompt gets the method and the question rules" || bad "first plan-mode prompt gets the method and the question rules" "$OUT"
[ "${#OUT}" -lt 10000 ] && ok "the method fits the 10,000-character hook output cap (${#OUT})" || bad "the method fits the 10,000-character hook output cap" "${#OUT} characters"
[[ $OUT != *"INTENT-INJECT"* ]] && ok "the marker lines themselves are not sent" || bad "the marker lines themselves are not sent" "$OUT"
run intent-inject.sh '{"session_id":"s1","permission_mode":"plan","prompt":"more"}'
[[ $OUT == *"loaded earlier this session"* && ${#OUT} -lt 500 ]] && ok "second prompt in the same session gets the short reminder" || bad "second prompt in the same session gets the short reminder" "$OUT"
run intent-inject.sh '{"session_id":"s2","permission_mode":"plan","prompt":"other"}'
[[ $OUT == *"## Six slots"* ]] && ok "a different session gets the full method again" || bad "a different session gets the full method again" "$OUT"
fresh; mkdir -p "$T/emptykit"
KITDIR="$T/emptykit" run intent-inject.sh '{"session_id":"s3","permission_mode":"plan","prompt":"x"}'
[[ $OUT == *"NOT LOADED"* && $ERR == *"NOT LOADED"* ]] && ok "a missing skill is announced, never silent" || bad "a missing skill is announced, never silent" "$OUT / $ERR"
fresh; touch "$T/home/.claude/.intent-off"
run intent-inject.sh '{"session_id":"s4","permission_mode":"plan","prompt":"x"}'
[[ -z $OUT && $ERR == *"switched off"* ]] && ok "the off switch silences the method and says so on stderr" || bad "the off switch silences the method and says so on stderr" "$OUT / $ERR"

# --- intent-guard --------------------------------------------------------------------------------
group "intent-guard: no exit from plan mode until the plan is sealed"
INTENT='## Intent

- **WHO** - the warehouse planners who run the weekly shortage review, and their manager.
- **WHAT** - a one-page shortage list ranked by days of cover, built from the MRP export.
- **NOT** - no write-back to the planning system and no email sending.
- **WHY** - today the list is built by hand every Monday and misses late purchase orders.
- **HOW** - reads the Monday export file, runs locally, reuses the existing export parser.
- **DONE** - `npm test` prints PASS for the ranking fixtures, or stop after two sessions.'
plan() { { printf '%s\n\n' "$INTENT"; printf '%s\n' "$@"; } > "$T/plan.md"; }
exitp() { jq -nc --arg p "$T/plan.md" '{session_id:"g1",tool_name:"ExitPlanMode",tool_input:{planFilePath:$p}}'; }
fresh
run intent-guard.sh "$(jq -nc '{session_id:"g1",tool_name:"Write",tool_input:{file_path:"x"}}')"
[ -z "$OUT" ] && ok "negative control: another tool is left alone" || bad "negative control: another tool is left alone" "$OUT"
printf '# Plan\n\n1. build it\n' > "$T/plan.md"; run intent-guard.sh "$(exitp)"; expect_deny "an unsealed plan is refused"
[[ $OUT == *"no confirmed intent"* ]] && ok "the refusal says what to write" || bad "the refusal says what to write" "$OUT"
printf '## Intent\n\nshort\n\n<!-- INTENT-LOCK:CONFIRMED -->\n<!-- INTENT-LOCK:WATCH -->\n' > "$T/plan.md"; run intent-guard.sh "$(exitp)"; expect_deny "a seal over a hollow Intent section is refused"
plan '<!-- INTENT-LOCK:CONFIRMED -->'; run intent-guard.sh "$(exitp)"; expect_deny "a sealed plan with no watch-or-walk answer is refused"
plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WATCH -->' '<!-- INTENT-LOCK:WALK -->'; run intent-guard.sh "$(exitp)"; expect_deny "a plan answering both watch and walk is refused"
plan '```' '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WATCH -->' '```'; run intent-guard.sh "$(exitp)"; expect_deny "markers inside a code block do not seal the plan"
plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WATCH -->'; run intent-guard.sh "$(exitp)"; expect_allow "a sealed WATCH plan is allowed"
[[ $ERR == *"ALLOW confirmed watch"* ]] && grep -q 'ALLOW confirmed watch' "$T/state/guard.log" && ok "the allow is logged and printed" || bad "the allow is logged and printed" "$ERR"
[ ! -f "$T/state/handoff/g1" ] && ok "a WATCH plan arms no handoff" || bad "a WATCH plan arms no handoff" "record exists"
plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'; run intent-guard.sh "$(exitp)"; expect_allow "a sealed WALK plan is allowed"
[ -f "$T/state/handoff/g1" ] && ok "a WALK plan arms the handoff for its session" || bad "a WALK plan arms the handoff for its session" "no record"
PROSE="${INTENT/- \*\*DONE\*\* -/- Done when}"
{ printf '%s\n\n' "$PROSE"; printf '%s\n' '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'; } > "$T/plan.md"; rm -f "$T/state/handoff/g1"
run intent-guard.sh "$(exitp)"; expect_deny "a WALK plan whose DONE the handoff cannot read is refused"
[[ $OUT == *"no grader"* && $OUT == *"- **DONE:**"* ]] && ok "the refusal says how to write the DONE line" || bad "the refusal says how to write the DONE line" "$OUT"
[ ! -f "$T/state/handoff/g1" ] && ok "a refused WALK arms no handoff" || bad "a refused WALK arms no handoff" "record exists"
{ printf '%s\n\n' "${INTENT/- \*\*DONE\*\* -/- DONE:}"; printf '%s\n' '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'; } > "$T/plan.md"
run intent-guard.sh "$(exitp)"; expect_allow "its twin with a plain '- DONE:' label is allowed"
{ printf '%s\n\n' "$PROSE"; printf '%s\n' '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WATCH -->'; } > "$T/plan.md"
run intent-guard.sh "$(exitp)"; expect_allow "an unreadable DONE does not block a WATCH plan"
mkdir -p "$T/stand/hooks"; cp "$H/intent-guard.sh" "$T/stand/hooks/"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T/stand/hooks/plan-handoff.sh"
{ printf '%s\n\n' "$INTENT"; printf '%s\n' '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'; } > "$T/plan.md"
H="$T/stand/hooks" run intent-guard.sh "$(exitp)"; expect_deny "a stand-in handoff that exits 0 without checking does not pass a WALK"
printf '# Plan\n<!-- INTENT-LOCK:WAIVED -->\n<!-- INTENT-LOCK:WATCH -->\n' > "$T/plan.md"; run intent-guard.sh "$(exitp)"; expect_allow "a waived plan is allowed"
run intent-guard.sh "$(jq -nc --arg p "$INTENT

<!-- INTENT-LOCK:CONFIRMED -->
<!-- INTENT-LOCK:WATCH -->" '{session_id:"g2",tool_name:"ExitPlanMode",tool_input:{plan:$p}}')"
expect_allow "plan text given inline with no file path is read"
run intent-guard.sh '{"session_id":"g3","tool_name":"ExitPlanMode","tool_input":{}}'
[[ -z $OUT && $ERR == *"NOT checked"* ]] && ok "no readable plan fails open, and says so" || bad "no readable plan fails open, and says so" "$OUT / $ERR"

# --- question-guard ------------------------------------------------------------------------------
group "question-guard: refuses a box the user cannot answer well"
D4='This keeps the current layout. It differs from the other choice by changing nothing. You will see the same page tomorrow. You give up the faster search.'
box() {  # box <question> <label1> <desc1> [extra jq to apply to the option list]
  jq -nc --arg q "$1" --arg l "$2" --arg d "$3" --arg d4 "$D4" \
    '{session_id:"q",tool_name:"AskUserQuestion",tool_input:{questions:[{question:$q,header:"Layout",
      options:[{label:$l,description:$d},{label:"Change it",description:$d4}]}]}}'; }
fresh
run question-guard.sh "$(jq -nc '{tool_name:"Bash",tool_input:{command:"ls"}}')"
[ -z "$OUT" ] && ok "negative control: another tool is left alone" || bad "negative control: another tool is left alone" "$OUT"
run question-guard.sh "$(box "Which layout should the report use?" "Keep it (Recommended)" "$D4")"; expect_allow "a well-formed box is allowed"
run question-guard.sh "$(box "Which layout should the report use?" "Keep it" "$D4")"; expect_deny "a box with no recommended option is refused"
run question-guard.sh "$(box "Which layout should the report use?" "Keep it (Recommended)" "$D4" | jq -c '.tool_input.questions[0].options[1].label="Change it (Recommended)"')"; expect_deny "a box with two recommended options is refused"
run question-guard.sh "$(box "Which layout should the report use?" "Keep it (Recommended)" "This keeps the layout. It changes nothing. You see the same page.")"; expect_deny "a three-sentence description is refused"
run question-guard.sh "$(box "Which layout should the report use?" "Edit report.json (Recommended)" "$D4")"; expect_deny "a file name in a label is refused"
run question-guard.sh "$(box "Which layout should the report use?" "Pass --force (Recommended)" "$D4")"; expect_deny "a flag in a label is refused"
run question-guard.sh "$(box "Which layout should the report use?" "Keep it (Recommended)" "$D4" | jq -c '.tool_input.questions[0].options[0].preview="| a | b |"')"; expect_deny "an option with a preview is refused"
run question-guard.sh "$(box "Does the restatement above hold?" "Yes (Recommended)" "$D4")"; expect_deny "a question pointing at the restatement above is refused"
[[ $OUT == *"points at reply text"* ]] && ok "the refusal names the pointer" || bad "the refusal names the pointer" "$OUT"
run question-guard.sh "$(box "Which layout should the report use?" "Keep it (Recommended)" "This keeps everything listed above. It differs by changing nothing. You see the same page. You give up speed.")"; expect_deny "a description pointing at a list above is refused"
run question-guard.sh "$(box "In one line: a ranked shortage list from the Monday export, no write-back. Does that hold?" "Yes (Recommended)" "$D4")"; expect_allow "a restatement carried inside the question is allowed"
run question-guard.sh "$(box "Should the alert fire when cover stays above 3 days?" "Yes (Recommended)" "$D4")"; expect_allow "above used as a comparison is allowed"

# --- plan-handoff --------------------------------------------------------------------------------
group "plan-handoff: opens a fresh auto-mode session only when armed"
approve() { jq -nc --arg p "$T/plan.md" --arg c "$T" '{session_id:"h1",cwd:$c,tool_name:"ExitPlanMode",tool_input:{planFilePath:$p},tool_response:{filePath:$p}}'; }
fresh; plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'
run plan-handoff.sh "$(approve)"
[ -z "$OUT$ERR" ] && ok "negative control: not armed, so nothing happens" || bad "negative control: not armed, so nothing happens" "$OUT / $ERR"
mkdir -p "$T/state/handoff"; printf '%s\n' "$T/plan.md" > "$T/state/handoff/h1"
PLATFORM=windows run plan-handoff.sh "$(approve)"
[[ $ERR == *"/goal Carry out the approved plan"* && $ERR == *'prints PASS for the ranking fixtures'* && $ERR == *"--permission-mode auto"* ]] \
  && ok "armed on Windows: the launcher runs /goal built from the DONE slot in auto mode" || bad "armed on Windows: the launcher runs /goal built from the DONE slot in auto mode" "$ERR"
[[ $ERR != *"NOT - no write-back"* ]] && ok "the goal stops at the end of the DONE slot" || bad "the goal stops at the end of the DONE slot" "$ERR"
[ ! -f "$T/state/handoff/h1" ] && ok "the arm is consumed" || bad "the arm is consumed" "record still there"
PLATFORM=windows run plan-handoff.sh "$(approve)"
[ -z "$OUT$ERR" ] && ok "a consumed arm does not fire again" || bad "a consumed arm does not fire again" "$OUT / $ERR"
printf '%s\n' "$T/plan.md" > "$T/state/handoff/h1"
PLATFORM=unix run plan-handoff.sh "$(approve)"
[[ $OUT == *"claude --permission-mode auto '/goal Carry out"* && $OUT == *"Do not start work on this plan here"* ]] \
  && ok "armed on Mac or Linux: the exact command is handed to Claude to show" || bad "armed on Mac or Linux: the exact command is handed to Claude to show" "$OUT"
# The approving window's effort level rides along; the run just above carried none, which is the control.
[[ $OUT != *"--effort"* ]] && ok "control: an approval with no effort level passes no --effort" || bad "control: an approval with no effort level passes no --effort" "$OUT"
approve_at() { approve | jq -c --arg e "$1" '. + {effort:{level:$e}}'; }
printf '%s\n' "$T/plan.md" > "$T/state/handoff/h1"
PLATFORM=windows run plan-handoff.sh "$(approve_at xhigh)"
[[ $ERR == *"claude --permission-mode auto --effort xhigh '/goal Carry out"* ]] \
  && ok "armed at xhigh: the new window starts at xhigh" || bad "armed at xhigh: the new window starts at xhigh" "$ERR"
printf '%s\n' "$T/plan.md" > "$T/state/handoff/h1"
PLATFORM=unix run plan-handoff.sh "$(approve_at "max'; rm -rf ~; '")"
[[ $OUT == *"claude --permission-mode auto '/goal Carry out"* && $OUT != *"rm -rf"* ]] \
  && ok "a level the CLI does not take is dropped, never pasted into the command" || bad "a level the CLI does not take is dropped, never pasted into the command" "$OUT"
printf '# Plan\n<!-- INTENT-LOCK:WAIVED -->\n<!-- INTENT-LOCK:WALK -->\n' > "$T/plan.md"; printf '%s\n' "$T/plan.md" > "$T/state/handoff/h1"
PLATFORM=windows run plan-handoff.sh "$(approve)"
[[ $OUT == *"goal NOT set"* && $ERR != *"/goal Carry"* ]] && ok "a plan with no DONE slot opens without a goal, and says so" || bad "a plan with no DONE slot opens without a goal, and says so" "$OUT / $ERR"
# A path holding a space: Start-Process joins its argument list with plain spaces, so an unquoted path
# arrives in two pieces. The temp folder carries the space here, as it does for a Windows user whose
# name has one. The control runs the same check against a copy with the quoting taken out.
fresh; plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'
mkdir -p "$T/state/handoff" "$T/te mp" "$T/old/hooks"; printf '%s\n' "$T/plan.md" > "$T/state/handoff/h1"
TEMP="$T/te mp" PLATFORM=windows run plan-handoff.sh "$(approve)"
[[ $ERR == *"DRYRUN windows fallback:"*"'-File','\""*"te mp"*".ps1\"'"* ]] \
  && ok "a launcher path holding a space reaches Start-Process inside its own double quotes" || bad "a launcher path holding a space reaches Start-Process inside its own double quotes" "$ERR"
[[ $ERR == *"DRYRUN windows terminal: wt.exe "* && $ERR != *"wt.exe -d"* ]] \
  && ok "Windows Terminal is not handed the folder, so no folder name can split its command line" || bad "Windows Terminal is not handed the folder, so no folder name can split its command line" "$ERR"
sed 's/\$(psqq "\$launcher")/$(psq "$launcher")/' "$H/plan-handoff.sh" > "$T/old/hooks/plan-handoff.sh"
printf '%s\n' "$T/plan.md" > "$T/state/handoff/h1"
TEMP="$T/te mp" PLATFORM=windows H="$T/old/hooks" run plan-handoff.sh "$(approve)"
[[ $ERR == *"DRYRUN windows fallback:"*"te mp"* && $ERR != *"'-File','\""* ]] \
  && ok "control: with the quoting taken out, the same check sees the path go in bare" || bad "control: with the quoting taken out, the same check sees the path go in bare" "$ERR"

group "plan-handoff --check-done: every way a plan writes its DONE line"
check() {  # check <name> <DONE line> <want: set|unset> [text that must be in the goal]
  local said rc
  said=$(printf '%s\n\n%s\n%s\n' "## Intent" "- **WHO** - planners." "$2" | bash "$H/plan-handoff.sh" --check-done /p.md 2>&1); rc=$?
  if [ "$3" = set ]; then
    [[ $rc -eq 0 && $said == *"goal set from DONE"* ]] && ok "$1" || bad "$1" "rc=$rc $said"
  else
    [[ $rc -ne 0 && $said == *"goal NOT set"* ]] && ok "$1" || bad "$1" "rc=$rc $said"
  fi
}
check "bold label with a dash"        '- **DONE** - npm test prints PASS'            set
check "bold label, colon inside"      '- **DONE:** npm test prints PASS'             set
check "bold label ending in a stop"   '**DONE.** npm test prints PASS'               set
check "plain bulleted label"          '- DONE: npm test prints PASS'                 set
check "bare label, no punctuation"    'DONE npm test prints PASS'                    set
check "negative control: prose 'Done when' is not a label" '- Done when npm test prints PASS' unset
check "negative control: a word starting DONE is not a label" '- DONEISH: npm test prints PASS' unset
check "negative control: no DONE line at all" '- **HOW** - runs locally.' unset
said=$(printf '%s\n' '- DONE: npm test prints PASS,' '  or stop after two sessions.' '- NOT: no email.' | bash "$H/plan-handoff.sh" --check-done /p.md 2>&1)
[[ $said == *"goal set from DONE"* ]] && ok "a continued DONE line still builds a goal" || bad "a continued DONE line still builds a goal" "$said"
plan_txt=$(printf '%s\n' '- DONE: npm test prints PASS,' '  or stop after two sessions.' '- NOT: no email.')
fresh; printf '%s\n' "$plan_txt" > "$T/plan.md"; mkdir -p "$T/state/handoff"; printf '%s\n' "$T/plan.md" > "$T/state/handoff/h1"
PLATFORM=windows run plan-handoff.sh "$(approve)"
[[ $ERR == *"prints PASS, or stop after two sessions."* && $ERR != *"no email"* ]] \
  && ok "the goal carries the continuation and stops at the next plain label" || bad "the goal carries the continuation and stops at the next plain label" "$ERR"

summary
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
