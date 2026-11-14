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

pass=0; fail=0; skipped=0; group_fail=0; group_skip=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); group_fail=$((group_fail+1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:0:400}"; }
# A check that cannot run here is counted on its own, so a missing tool never reads as a pass.
skip() { skipped=$((skipped+1)); group_skip=$((group_skip+1)); printf '  SKIP  %s\n' "$1"; }
group() { [ -n "${G:-}" ] && summary; G=$1; group_fail=0; group_skip=0; printf '\n== %s ==\n' "$1"; }
summary() {
  local s=''; [ "$group_skip" = 0 ] || s="$group_skip skipped"
  if [ "$group_fail" = 0 ]; then printf 'PASS %s%s\n' "$G" "${s:+ ($s)}"; else printf 'FAIL %s (%s failed%s)\n' "$G" "$group_fail" "${s:+, $s}"; fi
}

OUT=''; ERR=''
fresh() { rm -rf "$T/home" "$T/state"; mkdir -p "$T/home/.claude" "$T/state"; }
# The three settings the hooks read from Claude Code's environment are removed unless an arm sets one
# (WATCH_HERE, GUIDE, ENTRY), so a suite run from inside Claude Code tests them absent, not inherited.
unset_kit_env() { KITENV=(env -u INTENT_LOCK_WATCH_HERE -u INTENT_LOCK_GUIDE_MODEL -u CLAUDE_CODE_ENTRYPOINT)
  [ -n "${WATCH_HERE+x}" ] && KITENV+=(INTENT_LOCK_WATCH_HERE="$WATCH_HERE")
  [ -n "${GUIDE+x}" ] && KITENV+=(INTENT_LOCK_GUIDE_MODEL="$GUIDE")
  [ -n "${ENTRY+x}" ] && KITENV+=(CLAUDE_CODE_ENTRYPOINT="$ENTRY"); }
run() {  # run <hook> <json>  -> OUT (stdout), ERR (stderr)
  unset_kit_env
  OUT=$(printf '%s' "$2" | "${KITENV[@]}" HOME="$T/home" INTENT_LOCK_STATE="$T/state" INTENT_LOCK_KIT="${KITDIR:-$KIT}" \
        INTENT_LOCK_HANDOFF_DRYRUN=1 INTENT_LOCK_PLATFORM="${PLATFORM:-}" bash "$H/$1" 2>"$T/err")
  ERR=$(cat "$T/err")
}
denied() { [[ $OUT == *'"permissionDecision":"deny"'* ]]; }
expect_deny()  { if denied; then ok "$1"; else bad "$1" "expected DENY, got: $OUT $ERR"; fi; }
expect_allow() { if denied; then bad "$1" "expected ALLOW, got: $OUT"; else ok "$1"; fi; }

# --- intent-inject -------------------------------------------------------------------------------
group "intent-inject: loads the method in plan mode, once per session and after a summary"
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
# A summary takes the method away, so the first plan turn after one gets it again, and only that turn.
TR="$T/s7.jsonl"; printf '{"type":"user"}\n' > "$TR"
J='{"session_id":"s7","permission_mode":"plan","prompt":"x","transcript_path":"'"$TR"'"}'
run intent-inject.sh "$J"; printf '{"type":"assistant"}\n' >> "$TR"; run intent-inject.sh "$J"
[[ $OUT == *"loaded earlier this session"* ]] && ok "negative control: with no summary, a later turn gets the reminder" || bad "negative control: with no summary, a later turn gets the reminder" "$OUT"
printf '{"type":"system","subtype":"compact_boundary"}\n' >> "$TR"; run intent-inject.sh "$J"
[[ $OUT == *"## Six slots"* ]] && ok "the first plan turn after a summary gets the full method again" || bad "the first plan turn after a summary gets the full method again" "$OUT"
run intent-inject.sh "$J"
[[ $OUT == *"loaded earlier this session"* ]] && ok "the turn after that is back to the reminder" || bad "the turn after that is back to the reminder" "$OUT"
fresh; mkdir -p "$T/emptykit"
KITDIR="$T/emptykit" run intent-inject.sh '{"session_id":"s3","permission_mode":"plan","prompt":"x"}'
[[ $OUT == *"NOT LOADED"* && $ERR == *"NOT LOADED"* ]] && ok "a missing skill is announced, never silent" || bad "a missing skill is announced, never silent" "$OUT / $ERR"
fresh; touch "$T/home/.claude/.intent-off"
run intent-inject.sh '{"session_id":"s4","permission_mode":"plan","prompt":"x"}'
[[ -z $OUT && $ERR == *"switched off"* ]] && ok "the off switch silences the method and says so on stderr" || bad "the off switch silences the method and says so on stderr" "$OUT / $ERR"
# A warning only stderr carries reaches Claude Code's debug log alone, so these are said where Claude reads.
fresh; mkdir -p "$T/norules/skill/intent-lock"; cp "$KIT/skill/intent-lock/SKILL.md" "$T/norules/skill/intent-lock/"
KITDIR="$T/norules" run intent-inject.sh '{"session_id":"s5","permission_mode":"plan","prompt":"x"}'
[[ $OUT == *"## Six slots"* && $OUT == *"question rules not found"* ]] && ok "missing question rules are told to Claude with the method" || bad "missing question rules are told to Claude with the method" "$OUT"
if PATH=/usr/bin command -v jq >/dev/null 2>&1; then skip "the jq-missing arms: /usr/bin holds a jq here"
else
  OUT=$(printf '%s' '{"session_id":"s6","permission_mode":"plan","prompt":"x"}' | HOME="$T/home" INTENT_LOCK_KIT="$KIT" PATH=/usr/bin "$BASH" "$H/intent-inject.sh" 2>/dev/null)
  [[ $OUT == *'"systemMessage":"intent-lock: jq is not installed'* ]] && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
    && ok "with no jq, plan mode says the method is not running" || bad "with no jq, plan mode says the method is not running" "$OUT"
  OUT=$(printf '%s' '{"session_id":"s6","permission_mode":"default","prompt":"x"}' | HOME="$T/home" INTENT_LOCK_KIT="$KIT" PATH=/usr/bin "$BASH" "$H/intent-inject.sh" 2>/dev/null)
  [ -z "$OUT" ] && ok "negative control: with no jq, a prompt outside plan mode hears nothing" || bad "negative control: with no jq, a prompt outside plan mode hears nothing" "$OUT"
fi

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
exitp() { jq -nc --arg p "$T/plan.md" '{session_id:"g1",tool_use_id:"gx1",tool_name:"ExitPlanMode",tool_input:{planFilePath:$p}}'; }
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
[[ $(cat "$T/state/handoff/g1" 2>/dev/null) == "gx1 "*/plan.md ]] && ok "a WATCH plan arms the handoff too, naming this exit and its plan" \
  || bad "a WATCH plan arms the handoff too, naming this exit and its plan" "record: $(cat "$T/state/handoff/g1" 2>&1)"
rm -f "$T/state/handoff/g1"
WATCH_HERE=1 run intent-guard.sh "$(exitp)"; expect_allow "with INTENT_LOCK_WATCH_HERE=1 a sealed WATCH plan is allowed"
[ ! -f "$T/state/handoff/g1" ] && [[ $ERR == *"ALLOW confirmed watch  "* ]] && ok "with INTENT_LOCK_WATCH_HERE=1 a WATCH plan arms nothing" \
  || bad "with INTENT_LOCK_WATCH_HERE=1 a WATCH plan arms nothing" "record: $(cat "$T/state/handoff/g1" 2>&1) / $ERR"
plan '<!-- INTENT-LOCK:CONFIRMED -->'; WATCH_HERE=1 run intent-guard.sh "$(exitp)"
[[ $OUT == *"carries on in this window, because INTENT_LOCK_WATCH_HERE is set"* ]] && ok "the unanswered-question refusal says where a watched build runs with the switch set" \
  || bad "the unanswered-question refusal says where a watched build runs with the switch set" "$OUT"
run intent-guard.sh "$(exitp)"
[[ $OUT == *"Watching: approval opens a fresh auto-mode session"*"watch stop"* ]] && ok "control: without the switch it says either answer opens a fresh session" \
  || bad "control: without the switch it says either answer opens a fresh session" "$OUT"
mkdir -p "$T/nohand/hooks"; cp "$H/intent-guard.sh" "$T/nohand/hooks/"; cp -r "$H/lib" "$T/nohand/hooks/"
plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WATCH -->'; rm -f "$T/state/handoff/g1"
H="$T/nohand/hooks" run intent-guard.sh "$(exitp)"
! denied && [[ $OUT == *"plan-handoff.sh is missing"*"carry on in this window"* ]] && [ ! -f "$T/state/handoff/g1" ] \
  && ok "a WATCH plan with no handoff beside the gate is allowed, arms nothing, and says so" || bad "a WATCH plan with no handoff beside the gate is allowed, arms nothing, and says so" "$OUT"
plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'; H="$T/nohand/hooks" run intent-guard.sh "$(exitp)"
expect_deny "a WALK plan with no handoff beside the gate is refused"
plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'; run intent-guard.sh "$(exitp)"; expect_allow "a sealed WALK plan is allowed"
[[ $(cat "$T/state/handoff/g1" 2>/dev/null) == "gx1 "*/plan.md ]] && ok "a WALK plan arms the handoff for its session, naming this exit and its plan" \
  || bad "a WALK plan arms the handoff for its session, naming this exit and its plan" "record: $(cat "$T/state/handoff/g1" 2>&1)"
PROSE="${INTENT/- \*\*DONE\*\* -/- Done when}"
{ printf '%s\n\n' "$PROSE"; printf '%s\n' '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'; } > "$T/plan.md"; rm -f "$T/state/handoff/g1"
run intent-guard.sh "$(exitp)"; expect_deny "a WALK plan whose DONE the handoff cannot read is refused"
[[ $OUT == *"no grader"* && $OUT == *"- **DONE:**"* ]] && ok "the refusal says how to write the DONE line" || bad "the refusal says how to write the DONE line" "$OUT"
[ ! -f "$T/state/handoff/g1" ] && ok "a refused WALK arms no handoff" || bad "a refused WALK arms no handoff" "record exists"
{ printf '%s\n\n' "${INTENT/- \*\*DONE\*\* -/- DONE:}"; printf '%s\n' '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'; } > "$T/plan.md"
run intent-guard.sh "$(exitp)"; expect_allow "its twin with a plain '- DONE:' label is allowed"
{ printf '%s\n\n' "$PROSE"; printf '%s\n' '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WATCH -->'; } > "$T/plan.md"
run intent-guard.sh "$(exitp)"; expect_allow "an unreadable DONE does not block a WATCH plan"
mkdir -p "$T/stand/hooks"; cp "$H/intent-guard.sh" "$T/stand/hooks/"; cp -r "$H/lib" "$T/stand/hooks/"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T/stand/hooks/plan-handoff.sh"
{ printf '%s\n\n' "$INTENT"; printf '%s\n' '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'; } > "$T/plan.md"
H="$T/stand/hooks" run intent-guard.sh "$(exitp)"; expect_deny "a stand-in handoff that exits 0 without checking does not pass a WALK"
printf '# Plan\n<!-- INTENT-LOCK:WAIVED -->\n<!-- INTENT-LOCK:WATCH -->\n' > "$T/plan.md"; run intent-guard.sh "$(exitp)"; expect_allow "a waived plan is allowed"
run intent-guard.sh "$(jq -nc --arg p "$INTENT

<!-- INTENT-LOCK:CONFIRMED -->
<!-- INTENT-LOCK:WATCH -->" '{session_id:"g2",tool_name:"ExitPlanMode",tool_input:{plan:$p}}')"
expect_allow "plan text given inline with no file path is read"
# A fail-open exit is told to the user and to Claude in one object: stderr from a hook that exits 0
# reaches only Claude Code's debug log, so a warning written there alone is a silent one.
said() { ! denied && [[ $OUT == *"\"systemMessage\":\"$1"* && $OUT == *"\"additionalContext\":\"$1"* ]]; }
# nojq <hook> <json>: the hook run with only /usr/bin on PATH, where this machine keeps no jq.
nojq() { OUT=$(printf '%s' "$2" | HOME="$T/home" INTENT_LOCK_STATE="$T/state" INTENT_LOCK_KIT="$KIT" PATH=/usr/bin "$BASH" "$H/$1" 2>/dev/null); }
NOJQ=1; PATH=/usr/bin command -v jq >/dev/null 2>&1 && { NOJQ=''; skip "the jq-missing arms: /usr/bin holds a jq here"; }
run intent-guard.sh '{"session_id":"g3","tool_name":"ExitPlanMode","tool_input":{}}'
said "intent-lock: could not read the plan" && [[ $ERR == *"NOT checked"* ]] && ok "no readable plan fails open, and tells the user and Claude" \
  || bad "no readable plan fails open, and tells the user and Claude" "$OUT / $ERR"
fresh; : > "$T/state/handoff"; plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'; run intent-guard.sh "$(exitp)"
said "intent-lock: could not write" && ok "a WALK whose handoff cannot be armed is let through, and the user and Claude are told" \
  || bad "a WALK whose handoff cannot be armed is let through, and the user and Claude are told" "$OUT / $ERR"
if [ -n "$NOJQ" ]; then nojq intent-guard.sh "$(exitp)"
  said "intent-lock: jq is not installed" && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 && ok "with no jq the exit is let through, and the user and Claude are told" \
    || bad "with no jq the exit is let through, and the user and Claude are told" "$OUT"; fi

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
run question-guard.sh '{"tool_name":"AskUserQuestion","tool_input":{}}'
said "question-guard: could not read any questions" && ok "a box it cannot read is let through, and the user and Claude are told" \
  || bad "a box it cannot read is let through, and the user and Claude are told" "$OUT / $ERR"
if [ -n "$NOJQ" ]; then nojq question-guard.sh '{"tool_name":"AskUserQuestion"}'
  said "question-guard: jq or awk is missing" && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 && ok "with no jq a box is let through, and the user and Claude are told" \
    || bad "with no jq a box is let through, and the user and Claude are told" "$OUT"; fi
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
approve() { jq -nc --arg p "$T/plan.md" --arg c "$T" '{session_id:"h1",tool_use_id:"tu1",cwd:$c,tool_name:"ExitPlanMode",tool_input:{planFilePath:$p},tool_response:{filePath:$p}}'; }
# armh [exit id]: the arm intent-guard.sh writes, for the exit approve() names unless another is given.
armh() { mkdir -p "$T/state/handoff"; printf '%s %s\n' "${1:-tu1}" "$T/plan.md" > "$T/state/handoff/h1"; }
fresh; plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'
run plan-handoff.sh "$(approve)"
[ -z "$OUT$ERR" ] && ok "negative control: not armed, so nothing happens" || bad "negative control: not armed, so nothing happens" "$OUT / $ERR"
plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WATCH -->'
PLATFORM=windows run plan-handoff.sh "$(approve)"
[ -z "$OUT$ERR" ] && ok "a WATCH plan with no arm opens nothing" || bad "a WATCH plan with no arm opens nothing" "$OUT / $ERR"
armh; PLATFORM=windows run plan-handoff.sh "$(approve)"
[[ $ERR == *"DRYRUN windows launcher"* && $ERR == *"claude --permission-mode auto 'Carry out the approved plan"* && $ERR == *"stop at each watch stop the plan names"* && $ERR != *"'/goal "* && $OUT == *"fresh watched auto-mode session"* ]] \
  && ok "an armed WATCH plan on Windows opens a watched session with no goal, and says which kind" || bad "an armed WATCH plan on Windows opens a watched session with no goal, and says which kind" "$OUT / $ERR"
[[ $ERR == *"If this session has an advisor, consult it"* ]] && ok "the watched prompt tells the session when to consult a guide" || bad "the watched prompt tells the session when to consult a guide" "$ERR"
armh; PLATFORM=unix run plan-handoff.sh "$(approve)"
[[ $OUT == *"claude --permission-mode auto 'Carry out the approved plan"*"watch stop"* && $OUT != *"/goal Carry"* && $OUT == *"for a watched build"* ]] \
  && ok "an armed WATCH plan on Mac or Linux hands over the command with no goal, and says which kind" || bad "an armed WATCH plan on Mac or Linux hands over the command with no goal, and says which kind" "$OUT"
# A run with nobody present opens nothing, consumes its arm, and logs why; the control is the same arm
# with Claude Code's interactive entrypoint, which opens.
plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'
armh; ENTRY=sdk-cli PLATFORM=windows run plan-handoff.sh "$(approve)"
[ -z "$OUT$ERR" ] && [ ! -f "$T/state/handoff/h1" ] && grep -q 'HANDOFF none: headless run (sdk-cli)' "$T/state/guard.log" \
  && ok "a headless run opens nothing, consumes its arm, and logs why" || bad "a headless run opens nothing, consumes its arm, and logs why" "$OUT / $ERR"
armh; ENTRY=cli PLATFORM=windows run plan-handoff.sh "$(approve)"
[[ $ERR == *"DRYRUN windows launcher"* ]] && ok "control: the same arm in an interactive session opens" || bad "control: the same arm in an interactive session opens" "$OUT / $ERR"
armh
PLATFORM=windows run plan-handoff.sh "$(approve)"
[[ $ERR == *"/goal Carry out the approved plan"* && $ERR == *'prints PASS for the ranking fixtures'* && $ERR == *"--permission-mode auto"* && $OUT == *"fresh walk-away auto-mode session"* ]] \
  && ok "armed on Windows: the launcher runs /goal built from the DONE slot in auto mode, and says which kind" || bad "armed on Windows: the launcher runs /goal built from the DONE slot in auto mode, and says which kind" "$OUT / $ERR"
[[ $ERR == *"If this session has an advisor, consult it"*"Done when"* ]] && ok "the goal tells the session when to consult a guide, ahead of its DONE" || bad "the goal tells the session when to consult a guide, ahead of its DONE" "$ERR"
[[ $ERR != *"--advisor"* && $ERR != *"LASTEXITCODE) {"* ]] && ok "control: with no guide setting, no --advisor and no error line" || bad "control: with no guide setting, no --advisor and no error line" "$ERR"
[[ $ERR != *"NOT - no write-back"* ]] && ok "the goal stops at the end of the DONE slot" || bad "the goal stops at the end of the DONE slot" "$ERR"
[ ! -f "$T/state/handoff/h1" ] && ok "the arm is consumed" || bad "the arm is consumed" "record still there"
PLATFORM=windows run plan-handoff.sh "$(approve)"
[ -z "$OUT$ERR" ] && ok "a consumed arm does not fire again" || bad "a consumed arm does not fire again" "$OUT / $ERR"
armh
PLATFORM=unix run plan-handoff.sh "$(approve)"
[[ $OUT == *"claude --permission-mode auto '/goal Carry out"* && $OUT == *"Do not start work on this plan here"* ]] \
  && ok "armed on Mac or Linux: the exact command is handed to Claude to show" || bad "armed on Mac or Linux: the exact command is handed to Claude to show" "$OUT"
# The approving window's effort level rides along; the run just above carried none, which is the control.
[[ $OUT != *"--effort"* ]] && ok "control: an approval with no effort level passes no --effort" || bad "control: an approval with no effort level passes no --effort" "$OUT"
approve_at() { approve | jq -c --arg e "$1" '. + {effort:{level:$e}}'; }
armh
PLATFORM=windows run plan-handoff.sh "$(approve_at xhigh)"
[[ $ERR == *"claude --permission-mode auto --effort xhigh '/goal Carry out"* ]] \
  && ok "armed at xhigh: the new window starts at xhigh" || bad "armed at xhigh: the new window starts at xhigh" "$ERR"
armh
PLATFORM=unix run plan-handoff.sh "$(approve_at "max'; rm -rf ~; '")"
[[ $OUT == *"claude --permission-mode auto '/goal Carry out"* && $OUT != *"rm -rf"* ]] \
  && ok "a level the CLI does not take is dropped, never pasted into the command" || bad "a level the CLI does not take is dropped, never pasted into the command" "$OUT"
# The guide. The made-up name carries brackets to prove they pass, quoted, on both platforms.
armh; GUIDE='my-guide.2[x]' PLATFORM=windows run plan-handoff.sh "$(approve)"
[[ $ERR == *"claude --permission-mode auto --advisor 'my-guide.2[x]' '/goal Carry out"* && $ERR == *"unset INTENT_LOCK_GUIDE_MODEL"* && $OUT == *"guide my-guide.2[x] passed"* ]] \
  && ok "a guide setting on Windows starts the window with --advisor and an error line" || bad "a guide setting on Windows starts the window with --advisor and an error line" "$OUT / $ERR"
armh; GUIDE='my-guide.2[x]' PLATFORM=unix run plan-handoff.sh "$(approve)"
[[ $OUT == *"claude --permission-mode auto --advisor 'my-guide.2[x]' '/goal Carry out"* ]] \
  && ok "a guide setting on Mac or Linux puts --advisor in the command" || bad "a guide setting on Mac or Linux puts --advisor in the command" "$OUT"
armh; GUIDE="x'; rm -rf ~; '" PLATFORM=windows run plan-handoff.sh "$(approve)"
[[ $ERR != *"--advisor"* && $ERR != *"rm -rf"* && $ERR == *"DRYRUN windows launcher"* && $OUT == *"INTENT_LOCK_GUIDE_MODEL was dropped"* ]] \
  && ok "a guide setting that is not a model name is dropped, the window still opens, and it says so" || bad "a guide setting that is not a model name is dropped, the window still opens, and it says so" "$OUT / $ERR"
armh; GUIDE='' PLATFORM=windows run plan-handoff.sh "$(approve)"
[[ $ERR != *"--advisor"* && $OUT != *"dropped"* && $ERR == *"DRYRUN windows launcher"* ]] \
  && ok "control: a guide setting left empty passes no flag and is not reported" || bad "control: a guide setting left empty passes no flag and is not reported" "$OUT / $ERR"
printf '# Plan\n<!-- INTENT-LOCK:WAIVED -->\n<!-- INTENT-LOCK:WALK -->\n' > "$T/plan.md"; armh
PLATFORM=windows run plan-handoff.sh "$(approve)"
[[ $OUT == *"goal NOT set"* && $ERR != *"/goal Carry"* ]] && ok "a plan with no DONE slot opens without a goal, and says so" || bad "a plan with no DONE slot opens without a goal, and says so" "$OUT / $ERR"
# A path holding a space: Start-Process joins its argument list with plain spaces, so an unquoted path
# arrives in two pieces. The temp folder carries the space here, as it does for a Windows user whose
# name has one. The control runs the same check against a copy with the quoting taken out.
fresh; plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'
mkdir -p "$T/state/handoff" "$T/te mp" "$T/old/hooks"; armh
TEMP="$T/te mp" PLATFORM=windows run plan-handoff.sh "$(approve)"
[[ $ERR == *"DRYRUN windows fallback:"*"'-File','\""*"te mp"*".ps1\"'"* ]] \
  && ok "a launcher path holding a space reaches Start-Process inside its own double quotes" || bad "a launcher path holding a space reaches Start-Process inside its own double quotes" "$ERR"
[[ $ERR == *"DRYRUN windows terminal: wt.exe "* && $ERR != *"wt.exe -d"* ]] \
  && ok "Windows Terminal is not handed the folder, so no folder name can split its command line" || bad "Windows Terminal is not handed the folder, so no folder name can split its command line" "$ERR"
sed 's/\$(psqq "\$launcher")/$(psq "$launcher")/' "$H/plan-handoff.sh" > "$T/old/hooks/plan-handoff.sh"; cp -r "$H/lib" "$T/old/hooks/"
armh
TEMP="$T/te mp" PLATFORM=windows H="$T/old/hooks" run plan-handoff.sh "$(approve)"
[[ $ERR == *"DRYRUN windows fallback:"*"te mp"* && $ERR != *"'-File','\""* ]] \
  && ok "control: with the quoting taken out, the same check sees the path go in bare" || bad "control: with the quoting taken out, the same check sees the path go in bare" "$ERR"
# It fires for the exit that armed it alone, and only while the plan as approved says WALK, because the
# approval dialog can edit the plan. Each drop reaches the screen and Claude; the control is every armed
# run above, which fires.
fresh; plan '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'
armh tu0; PLATFORM=windows run plan-handoff.sh "$(approve)"
said "plan-handoff: The plan handoff was armed by an earlier plan exit" && [[ $ERR != *DRYRUN* ]] \
  && ok "an arm an earlier exit left opens nothing, and the user and Claude are told" || bad "an arm an earlier exit left opens nothing, and the user and Claude are told" "$OUT / $ERR"
as_watch() { approve | jq -c --arg t "$(sed 's/:WALK/:WATCH/' "$T/plan.md")" '.tool_response.plan = $t'; }
armh; PLATFORM=windows run plan-handoff.sh "$(as_watch)"
[[ $ERR == *"DRYRUN windows launcher"* && $ERR == *"watch stop"* && $ERR != *"'/goal "* ]] \
  && ok "a WALK changed to WATCH in the approval dialog opens a watched session instead" || bad "a WALK changed to WATCH in the approval dialog opens a watched session instead" "$OUT / $ERR"
armh; WATCH_HERE=1 PLATFORM=windows run plan-handoff.sh "$(as_watch)"
said "plan-handoff: The approved plan says WATCH" && [[ $ERR != *DRYRUN* && $OUT == *"INTENT_LOCK_WATCH_HERE is set"* ]] \
  && ok "with INTENT_LOCK_WATCH_HERE=1, a WALK changed to WATCH opens nothing" || bad "with INTENT_LOCK_WATCH_HERE=1, a WALK changed to WATCH opens nothing" "$OUT / $ERR"
armh; PLATFORM=windows run plan-handoff.sh "$(approve | jq -c --arg t "$INTENT" '.tool_response.plan = $t')"
said "plan-handoff: The approved plan no longer carries a WATCH or WALK line" && [[ $ERR != *DRYRUN* ]] \
  && ok "a WALK line deleted in the approval dialog opens nothing" || bad "a WALK line deleted in the approval dialog opens nothing" "$OUT / $ERR"
armh; PLATFORM=windows run plan-handoff.sh "$(approve | jq -c --arg t "$(cat "$T/plan.md"; printf '\n<!-- INTENT-LOCK:WATCH -->\n')" '.tool_response.plan = $t')"
said "plan-handoff: The approved plan carries both" && [[ $ERR != *DRYRUN* ]] \
  && ok "a plan given both lines in the approval dialog opens nothing" || bad "a plan given both lines in the approval dialog opens nothing" "$OUT / $ERR"
mkdir -p "$T/bare"; cp "$H/plan-handoff.sh" "$H/intent-guard.sh" "$T/bare/"
armh; PLATFORM=windows H="$T/bare" run plan-handoff.sh "$(approve)"
said "plan-handoff: The plan handoff was armed, but lib/marker.sh is missing" && [[ $ERR != *DRYRUN* ]] \
  && ok "a handoff with no marker reader beside it opens nothing, and says so" || bad "a handoff with no marker reader beside it opens nothing, and says so" "$OUT / $ERR"
H="$T/bare" run intent-guard.sh "$(exitp)"
said "intent-lock: lib/marker.sh is missing" && ok "a gate with no marker reader beside it lets the exit through, and says so" \
  || bad "a gate with no marker reader beside it lets the exit through, and says so" "$OUT / $ERR"

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
fresh; printf '%s\n' "$plan_txt" '<!-- INTENT-LOCK:WALK -->' > "$T/plan.md"; armh
PLATFORM=windows run plan-handoff.sh "$(approve)"
[[ $ERR == *"prints PASS, or stop after two sessions."* && $ERR != *"no email"* ]] \
  && ok "the goal carries the continuation and stops at the next plain label" || bad "the goal carries the continuation and stops at the next plain label" "$ERR"
check "bold label in title case"      '- **Done:** npm test prints PASS'             set
check "plain label in title case before a colon" '- Done: npm test prints PASS'      set
# goal_of <plan lines...>: the Windows dry run for that plan, in $ERR.
goal_of() { fresh; printf '%s\n' "$@" '<!-- INTENT-LOCK:WALK -->' > "$T/plan.md"; armh
            PLATFORM=windows run plan-handoff.sh "$(approve)"; }
goal_of '## Intent' '' '**DONE.** The transcript must show, in order:' '' '- LEADIN_ONE green.' '- LEADIN_TWO matches.' '' '## Context' 'LEAK_LEADIN'
[[ $ERR == *LEADIN_ONE*LEADIN_TWO* && $ERR != *LEAK_LEADIN* ]] \
  && ok "a DONE lead-in keeps the list under it" || bad "a DONE lead-in keeps the list under it" "$ERR"
goal_of '## Intent' '' '- **DONE:** all of these hold:' '  - NEST_ONE passes' '  - CSV: NEST_TWO matches' '  NOT one NEST_THREE slips' '- **WHY:** LEAK_NEST'
[[ $ERR == *NEST_ONE*NEST_TWO*NEST_THREE* && $ERR != *LEAK_NEST* ]] \
  && ok "a line indented under DONE continues it, whatever word it opens with" || bad "a line indented under DONE continues it, whatever word it opens with" "$ERR"
goal_of '```' '- **DONE:** LEAK_FENCE template' '```' '' '## Intent' '' '- **DONE:** FENCE_REAL passes'
[[ $ERR == *FENCE_REAL* && $ERR != *LEAK_FENCE* ]] \
  && ok "a DONE inside a code fence is skipped for the Intent section's" || bad "a DONE inside a code fence is skipped for the Intent section's" "$ERR"
long=$(printf '%4100s' '' | tr ' ' x)
fresh; { printf '%s\n\n' "${INTENT/- \*\*DONE\*\* -/- **DONE** - $long}"; printf '%s\n' '<!-- INTENT-LOCK:CONFIRMED -->' '<!-- INTENT-LOCK:WALK -->'; } > "$T/plan.md"
run intent-guard.sh "$(exitp)"
[[ $OUT == *"4,000"* && $OUT == *"Shorten the DONE slot"* ]] \
  && ok "a DONE refused for its length is told to shorten, not to relabel" || bad "a DONE refused for its length is told to shorten, not to relabel" "$OUT"
# The guide sentence counts toward the 4,000: a DONE that fits only without it is refused, and the same
# DONE 200 characters shorter is the control that passes.
bare="Carry out the approved plan at /p.md; read it first, it is sealed, approved and the scope. Done when all of this is shown by output in this conversation: "
edge() { printf '%s\n' "- DONE: $(printf "%$(( 4000 - ${#bare} - $1 ))s" '' | tr ' ' y)" | bash "$H/plan-handoff.sh" --check-done /p.md 2>&1; }
said=$(edge 10); [[ $said == *"goal NOT set"*"4,000"* ]] && ok "a DONE that fits only without the guide sentence is refused" || bad "a DONE that fits only without the guide sentence is refused" "$said"
said=$(edge 200); [[ $said == *"goal set from DONE"* ]] && ok "control: the same DONE 190 characters shorter fits" || bad "control: the same DONE 190 characters shorter fits" "$said"

group "plan-handoff: the new window claims the launch, and a late one builds nothing"
# The real Windows path with no window opened, in this test's own temp folder; a stand-in claude.
claim_run() {  # claim_run <session> <wait seconds> <folder>; output in $T/<session>.out
  unset_kit_env
  jq -nc --arg p "$T/plan.md" --arg c "$(cygpath -w "$3")" --arg s "$1" \
     '{session_id:$s,tool_use_id:("tu-" + $s),cwd:$c,tool_name:"ExitPlanMode",tool_input:{planFilePath:$p},tool_response:{filePath:$p}}' \
  | "${KITENV[@]}" HOME="$T/home" INTENT_LOCK_STATE="$T/state" INTENT_LOCK_KIT="$KIT" INTENT_LOCK_PLATFORM=windows TEMP="$T/tmp" \
    INTENT_LOCK_HANDOFF_NOWINDOW=1 INTENT_LOCK_HANDOFF_WAIT="$2" bash "$H/plan-handoff.sh" > "$T/$1.out" 2>&1
}
launcher_ready() { local i; for i in $(seq 1 100); do [ -f "$T/tmp/intent-lock-handoff-$1.ps1" ] && return 0; sleep 0.2; done; return 1; }
# The approving session's variables are planted, as the new tab inherits them from this hook's process.
# stand_in <session> [claude body]: the default stand-in reports where it ran and what it inherited.
stand_in() { local body="${2:-'CLAUDE-RAN in ' + (Get-Location).Path + ' IDENTITY=[' + \$env:CLAUDE_CODE_SESSION_ID + \$env:CLAUDECODE + '] PROBE=' + \$env:INTENT_LOCK_PROBE}"
  pwsh.exe -NoProfile -Command "\$env:CLAUDE_CODE_SESSION_ID = 'planted'; \$env:CLAUDECODE = '1'; \$env:INTENT_LOCK_PROBE = 'kept'
  function claude { $body }
  . '$(cygpath -w "$T/tmp/intent-lock-handoff-$1.ps1")'" 2>&1 | tr -d '\r'; }
if command -v pwsh.exe >/dev/null 2>&1; then
  fresh; mkdir -p "$T/tmp" "$T/state/handoff" "$T/w1" "$T/w2" "$T/w3" "$T/w4" "$T/w5"
  printf '%s\n' '## Intent' '' '- DONE: the stand-in reports.' '<!-- INTENT-LOCK:WALK -->' > "$T/plan.md"
  for s in c1 c2 c3 c4 c5; do printf 'tu-%s %s\n' "$s" "$T/plan.md" > "$T/state/handoff/$s"; done
  claim_run c1 30 "$T/w1" & j1=$!
  claim_run c3 30 "$T/w3" & j3=$!
  GUIDE='my-guide.2[x]' claim_run c4 30 "$T/w4" & j4=$!
  GUIDE='my-guide.2[x]' claim_run c5 30 "$T/w5" & j5=$!
  claim_run c2 2 "$T/w2"
  launcher_ready c1 && o1=$(stand_in c1) || o1="no launcher was written"
  launcher_ready c3 && { rm -rf "$T/w3"; o3=$(stand_in c3); } || o3="no launcher was written"
  launcher_ready c4 && o4=$(stand_in c4 "\$global:LASTEXITCODE = 3; 'CLAUDE-FAILED ARGS=' + (\$args -join '|')") || o4="no launcher was written"
  launcher_ready c5 && o5=$(stand_in c5 "'CLAUDE-RAN ARGS=' + (\$args -join '|')") || o5="no launcher was written"
  o2=$(stand_in c2)
  wait "$j1" "$j3" "$j4" "$j5"
  [[ $o1 == *"CLAUDE-RAN in $(cygpath -w "$T/w1")"* && $(cat "$T/c1.out") == *"HAS FIRED"* ]] \
    && ok "a window that claims the launch in time builds in the planning session's folder" || bad "a window that claims the launch in time builds in the planning session's folder" "$o1 / $(cat "$T/c1.out")"
  [[ $o1 == *"IDENTITY=[] PROBE=kept"* ]] \
    && ok "claude starts without the approving session's own variables; control: another variable stays" \
    || bad "claude starts without the approving session's own variables; control: another variable stays" "$o1"
  [[ $(cat "$T/c2.out") == *"called off"* && $o2 == *"called off"* && $o2 != *CLAUDE-RAN* ]] \
    && ok "a window that starts after the wait ran out builds nothing" || bad "a window that starts after the wait ran out builds nothing" "$o2 / $(cat "$T/c2.out")"
  [[ $o3 == *FOLDER-FAILED* && $o3 != *CLAUDE-RAN* && $(cat "$T/c3.out") == *"could not enter"* ]] \
    && ok "a window whose folder is gone stops instead of building elsewhere" || bad "a window whose folder is gone stops instead of building elsewhere" "$o3 / $(cat "$T/c3.out")"
  [[ $o4 == *"CLAUDE-FAILED ARGS=--permission-mode|auto|--advisor|my-guide.2[x]|/goal "* && $o4 == *"intent-lock: claude ended with an error"*"unset INTENT_LOCK_GUIDE_MODEL"* ]] \
    && ok "with a guide set, a claude that ends in an error leaves one line naming the setting to unset" || bad "with a guide set, a claude that ends in an error leaves one line naming the setting to unset" "$o4"
  [[ $o5 == *"CLAUDE-RAN ARGS=--permission-mode|auto|--advisor|my-guide.2[x]|/goal "* && $o5 != *"ended with an error"* ]] \
    && ok "control: with a guide set, a claude that ends cleanly leaves no such line" || bad "control: with a guide set, a claude that ends cleanly leaves no such line" "$o5"
else
  skip "the six window-claim arms: no pwsh.exe here, so the claim cannot be run"
fi

summary
printf '\n%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
