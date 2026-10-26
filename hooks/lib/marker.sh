# marker.sh -- part of the intent-lock kit (MIT, Ian Provencher). Sourced by intent-guard.sh, which
# checks the plan at exit, and by plan-handoff.sh, which reads the plan as approved, so the two can
# never disagree about what a plan says.
#
# has_marker <plan text> <NAME>: the text carries <!-- INTENT-LOCK:NAME --> on a line of its own,
# outside ``` and ~~~ fences and indented code blocks, so a plan that quotes a marker while explaining
# it is not taken at its word.
has_marker() {
  printf '%s\n' "$1" | awk -v want="$2" '
    { sub(/\r$/, "") }
    fence != "" { if ($0 ~ ("^[ \t]*" fence)) fence = ""; next }
    /^[ \t]*```/ { fence = "```"; next }
    /^[ \t]*~~~/ { fence = "~~~"; next }
    /^(    |\t)/ { next }
    $0 ~ ("^[ \t]*<!-- INTENT-LOCK:" want " -->[ \t]*$") { found = 1; exit }
    END { exit(found ? 0 : 1) }'
}
