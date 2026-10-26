# intent-lock

A Claude Code kit that turns three of Anthropic's own best practices from advice into rules the
harness enforces: plan before you build, have Claude interview you, and build the spec in a fresh
session.

Anthropic's [best-practices page](https://code.claude.com/docs/en/best-practices) recommends all
three. The same page explains why recommending is not enough:

> Unlike CLAUDE.md instructions which are advisory, hooks are deterministic and guarantee the action
> happens.

So this kit ships the interview as a skill, and the enforcement as four hooks.

## What it enforces

1. **No leaving plan mode on assumed intent.** `intent-guard.sh` refuses `ExitPlanMode` until the
   plan file carries an `## Intent` section (who, what, not, why, how, done) sealed with
   `<!-- INTENT-LOCK:CONFIRMED -->`, and a line saying whether you will watch the build or walk away.
   A walk-away is refused unless the handoff can build a `/goal` from the plan's DONE line, so the
   fresh session never opens with nothing grading it.
2. **Every decision as a real choice.** `question-guard.sh` refuses a question box where an option
   has fewer than four sentences (what it is, how it differs, what you will see, what you give up),
   where no option is marked `(Recommended)`, where a label names a file or flag, or where the
   question points at reply text you may not be able to see.
3. **At least two rounds, then a restatement you confirm.** `intent-inject.sh` loads the method into
   the first plan-mode turn of every session: a coverage floor of six slots, a visible ledger of
   assumptions and tensions, and a restatement put inside the question box for you to break. This
   one is instructed rather than counted: the gate checks the sealed record, not the number of
   rounds.
4. **A fresh session to build.** Answer "walk away" and `plan-handoff.sh` opens a new auto-mode
   session on approval whose first prompt is `/goal`, built from the plan's DONE slot, so a separate
   grader checks the build from its first turn. The DONE line may be bold (`**DONE**`, `**DONE:**`,
   `**DONE.**`), plain (`- DONE: ...`) or bare (`DONE its suite passes`). The new session starts
   at the effort level the planning window had when you approved, not the saved default. On Windows
   it opens the window; on Mac and Linux it prints the exact command to run. It opens only for the
   plan exit you answered, and only while the plan you approve still says walk away: change its line
   to `<!-- INTENT-LOCK:WATCH -->` in the approval dialog and the build stays in this window.

## Install in three steps

You need Claude Code, `bash`, `jq` and `awk`. On Windows, Git Bash provides bash and awk.

1. Clone the kit and copy the skill into place:

       git clone https://github.com/AceP2317/intent-lock ~/.claude/intent-lock
       cp -r ~/.claude/intent-lock/skill/intent-lock ~/.claude/skills/

2. Merge the `hooks` block from `settings.example.json` into `~/.claude/settings.json`. If you
   already have hooks, add these entries beside yours rather than replacing them.

3. Check it works on your machine:

       bash ~/.claude/intent-lock/test/run.sh

   Every group should print `PASS`. Then press `Shift+Tab` until the status bar shows plan mode and
   ask for something to be built: Claude opens by saying which branch of the interview it took.

Optional: add `@~/.claude/intent-lock/rules/questions.md` to a project's `CLAUDE.md` so the question
rules apply outside plan mode too.

## Switching parts off

- `touch ~/.claude/.intent-off` turns off the method and the exit gate.
- `touch ~/.claude/.question-off` turns off the question guard.
- A single plan can skip the gate with `<!-- INTENT-LOCK:WAIVED -->` in place of the seal.

Every hook fails open: when it cannot read its input it lets the action through and prints a
warning, so a check that could not run never looks like one that passed. The exit gate puts that
warning on your screen and in front of Claude, since a hook's stderr alone reaches only the debug log.

## Tests

- `bash test/run.sh` runs every hook against fixtures in both directions. Each refusal has a twin
  that must pass, and each hook starts with an input it must leave alone.
- `bash test/live.sh` proves the exit gate inside two real `claude -p` runs, in a throwaway project
  whose only settings are this kit's hooks: it must refuse an unsealed plan and allow a sealed one.
  It costs two short model turns and needs node for a stand-in approver.

## Limits

- Only Windows has been tested end to end. The handoff on Mac and Linux prints a command rather
  than opening a window.
- The question guard counts sentences and matches words. It cannot tell whether an option actually
  teaches the choice; that half is the method's job, not the hook's.
- A `/goal` keeps re-checking until its grader rules the condition met or impossible. If something
  outside the session breaks the condition, for example another session pushes when the plan said
  not to, the goal can go round many times. Type `/goal clear` to end it.

## Why it pays for itself

Anthropic's page states the constraint plainly: "Claude's context window fills up fast, and
performance degrades as it fills." A build aimed at an assumed intent gets corrected after the work
exists, in the same window. Every round of rework then re-reads the build, the failed attempt and the
correction, and the original instruction becomes a smaller share of a bigger context. That is drift.
The interview moves the corrections to planning size, before anything is built, and the handoff
starts the build without the planning conversation riding along on every request.

Measured on the session that planned the write-up below, with both windows counted: 113.0 million
tokens read with the handoff, against 165.5 million for the same build kept in the planning window.
The build met all six of its checks in one 39-minute unattended pass.

## Read more

The write-up, with a real planning session as the worked example:
[ian-provencher.com/blog/intent-lock](https://ian-provencher.com/blog/intent-lock).

MIT licence. By [Ian Provencher](https://github.com/AceP2317).
