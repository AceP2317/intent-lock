#!/usr/bin/env bash
# question-guard.sh -- PreToolUse hook on AskUserQuestion, part of the intent-lock kit (MIT, Ian Provencher).
#
# Refuses a question box the user cannot answer well. It counts and matches; it never judges or
# rewrites the writing. The refusals, each named with its question number:
#   - an option description with fewer than four sentences (what it is, how it differs, what you
#     will see, what you give up)
#   - a question whose options carry no "(Recommended)" label, or more than one
#   - a file name, snake_case identifier or --flag in a header or option label
#   - any option carrying a `preview`, which swaps the dialog for a layout that drops every
#     option's explanation
#   - a question or description pointing at reply text ("the restatement above", "listed above",
#     "in my reply"), because text written before a question box can be out of view behind it
#
# Fails open, loudly: no jq, no awk, or a payload it cannot parse lets the question through with a
# warning on stderr, so an unchecked question never reads as a checked one.
#
# Switch off for good:  touch ~/.claude/.question-off
set -u

input=$(cat 2>/dev/null) || input=''
warn() { printf 'question-guard: %s\n' "$1" >&2; }

[ -f "$HOME/.claude/.question-off" ] && exit 0
if ! command -v jq >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1; then
  warn "jq or awk is missing, so this question was NOT checked"
  exit 0
fi
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null | tr -d '\r')
[ "$tool" = "AskUserQuestion" ] || exit 0

# One row per field: kind <TAB> question number <TAB> text.
#   Q question  H header  L label  D description  P preview  R count of (Recommended) labels
fields=$(printf '%s' "$input" | jq -r '
  def one: gsub("[\t\r\n]+"; " ");
  (.tool_input.questions // []) | to_entries[] | (.key + 1 | tostring) as $i | .value as $q
  | ("Q\t" + $i + "\t" + (($q.question // "") | one)),
    ("H\t" + $i + "\t" + (($q.header // "") | one)),
    ("R\t" + $i + "\t" + ([($q.options // [])[] | select((.label // "") | test("\\(recommended\\)"; "i"))] | length | tostring)),
    (($q.options // [])[] |
      ("L\t" + $i + "\t" + ((.label // "") | one)),
      ("D\t" + $i + "\t" + ((.description // "") | one)),
      ("P\t" + $i + "\t" + ((.preview // "") | gsub("\\s"; ""))))
' 2>/dev/null)
if [ -z "$fields" ]; then
  warn "could not read any questions from the input, so this question was NOT checked"
  exit 0
fi

viol=$(printf '%s\n' "$fields" | awk -F'\t' '
  function unseen_ptr(low,   s, at, rest, hit) {
    if (match(low, /(^|[^a-z])(see|as|in|listed|shown|stated|written|described|restated|outlined|summarised|summarized|explained|mentioned|noted|drawn|given|quoted|laid out|set out) above([^a-z]|$)/))
      return substr(low, RSTART, RLENGTH)
    if (match(low, /(^|[^a-z])(above|earlier) in (my|this|the) (reply|message|answer|response)/))
      return substr(low, RSTART, RLENGTH)
    if (match(low, /(^|[^a-z])(in|from) my (reply|message|answer|response)([^a-z]|$)/))
      return substr(low, RSTART, RLENGTH)
    s = low
    while (match(s, /(^|[^a-z])(the|this|that|these|those|my) ([a-z-]+ )?([a-z-]+ )?([a-z-]+ )?above([^a-z]|$)/)) {
      hit = substr(s, RSTART, RLENGTH)
      at = RSTART + RLENGTH - 1
      rest = substr(s, at)
      if (rest !~ /^ (the|a|an|it|them|its|their|which|all|every|average|[0-9$])/ &&
          hit !~ /(option|options|choice|choices|question|questions|route|routes|one|two|three|four) above/ &&
          hit !~ /(^|[^a-z])the above/) return hit
      s = substr(s, at)
    }
    return ""
  }
  function flag(qi, what) { if (n < 10) printf "  - question %s: %s\n", qi, what; n++ }
  {
    kind = $1; qi = $2; text = $0; sub(/^[^\t]*\t[^\t]*\t/, "", text); low = tolower(text)
    if (kind == "R") {
      if (text + 0 == 0) flag(qi, "no option is marked (Recommended) -- mark exactly one, so the set carries a position")
      else if (text + 0 > 1) flag(qi, text " options are marked (Recommended) -- mark exactly one")
    }
    if (kind == "P" && text != "")
      flag(qi, "an option carries a preview, which swaps the dialog for a layout that draws labels only and drops every explanation -- draw any comparison grid in the reply instead")
    if (kind == "H" || kind == "L") {
      where = (kind == "H" ? "header" : "option label")
      if (low ~ /\.(sh|md|json|py|js|mjs|ts|tsx|jsx|ps1|txt|ya?ml|toml)([^a-z0-9]|$)/) flag(qi, "a file name appears in a " where " -- name what the thing does instead")
      if (low ~ /[a-z]_[a-z]/) flag(qi, "a code identifier appears in a " where " -- name what the thing does instead")
      if (low ~ /(^|[^a-z0-9])--[a-z]/) flag(qi, "a command-line flag appears in a " where " -- name what the thing does instead")
    }
    if (kind == "Q" || kind == "D") {
      ptr = unseen_ptr(low); gsub(/^[^a-z]+|[^a-z]+$/, "", ptr)
      if (ptr != "") flag(qi, "the " (kind == "Q" ? "question" : "option description") " points at reply text with \"" ptr "\" -- text written before a question box can be out of view behind it, so put what it points at inside the question itself")
    }
    if (kind == "D") {
      t = text; ns = gsub(/[.!?]"? /, " ", t); if (text ~ /[.!?]"?$/) ns++
      if (ns < 4) flag(qi, "an option description has " ns " sentence(s) -- give four: what this is, how it differs from the others, what you will see, and what you give up")
    }
  }') || { warn "awk failed, so this question was NOT checked"; exit 0; }

[ -z "$viol" ] && exit 0

reason="question-guard: this question box breaks the kit's question rules, so the user cannot tell what they are choosing.
$viol
Fix those and ask again. The rules are in rules/questions.md. To switch this guard off: touch ~/.claude/.question-off"
jq -cn --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
