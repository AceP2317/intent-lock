---
name: intent-lock
description: "Interrogates you until the build intent is provably known, before a plan commits to a direction. Trigger phrases - `/intent-lock`, 'lock the intent', 'interrogate me', 'make sure you know what I want', 'scope this'. Also fires automatically on the first plan-mode turn of a session through the kit's intent-inject hook. Six slots (who, what, what-not, why, how, done) are a coverage floor, never a script. A visible ledger of assumptions and tensions must empty, and you confirm a restatement, before the plan is sealed. Do NOT use for stress-testing a plan that already exists, or for deciding whether to build at all."
---

# Intent Lock

The interrogation that runs before a build commits to a direction. The cheapest mistake to make is
also the most expensive one to find late: planning proceeds on assumed intent, because two questions
felt like enough and inference filled the rest.

Its exit condition is **checkable, not felt**. It stops when a named list of open items is empty and
the user has confirmed a restatement. It never stops because the questions slowed down.

Part of the intent-lock kit by Ian Provencher. The kit's hooks enforce what this text asks for:
`intent-guard.sh` refuses to leave plan mode until the plan is sealed, and `question-guard.sh`
refuses a question box that breaks the rules in `rules/questions.md`.

## When to engage

- The user invokes `/intent-lock` or asks to be interrogated before a build.
- Automatically, on the first plan-mode turn of a session, injected by `intent-inject.sh`. On that
  path the decision to engage is already made; go straight to calibration.
- A build request arrives carrying three or more open unknowns.

## When NOT to engage

- The ask is small and unambiguous. See Calibration: state the short branch and move on.
- A plan already exists and the user wants it attacked.
- The decision is whether to build at all. This skill runs after "yes, we are doing this."

## Persistence

Sticky within a build. Follow-ups deepen the interrogation rather than resetting it. It drops when
the plan is sealed, or when the user says "just build it" or "stop asking".

<!-- INTENT-INJECT:START -->
## Calibration first

State which branch you took, so a wrong call costs one word to correct.

- **Fewer than three open unknowns:** one sentence naming what you assume, then proceed. No
  interrogation. A skill that interrogates a typo fix gets switched off.
- **Three or more:** full rounds until the ledger is empty.

The short branch skips the interrogation, never the question box: a real decision still goes
through `AskUserQuestion`.

## Six slots: a floor, not a script

Check yourself against these. Never put them to the user as a form, never walk them in order, and
never ask about one only because it is unfilled. Where context already settled a slot, say so in a
few words and move on.

- **WHO** uses the output, and who else sees it.
- **WHAT** it is, in one sentence, in its own noun.
- **NOT** what it is not, and what it must never do.
- **WHY** what happens today without it. This is where "I need X" gets tested for whether X is
  load-bearing, so never let it pass on a restatement of WHAT.
- **HOW** where it runs, what data it eats, what it reuses.
- **DONE** the check that settles it, phrased so the build prints its own evidence: a command whose
  output lands in the conversation. Could a reader who was not here decide from the transcript
  alone? DONE also names the giving-up point: a turn count, a time box, or the condition under which
  work stops unfinished.

## Follow the thread

This outranks slot coverage every time.

- Ask the question whose answer would most change what gets built, not the next empty slot. Where a
  slot's answer would change nothing, assume it out loud. A stated assumption is cheaper than a
  question.
- Follow the surprise. An answer that is unexpected, arrives with more feeling than the question
  warranted, or sits badly against something said earlier is the next question.
- Listen for load-bearing throwaways: "just", "obviously", "for now", "like the last one". Ask what
  is inside the word.
- Rounds may widen. If every round is narrower than the last, nothing is being found.
- Reopen settled ground when a later answer undermines it, and say what changed.
- Spend one probe on what no slot asks: what would make you abandon this halfway? What version would
  you be embarrassed to ship?

## The ledger

Show a numbered list of what is still open, with its count, every round. Two kinds of entry:

- **Assumptions:** what is being taken on faith.
- **Tensions:** an answer that sits badly against another answer, the goal, or the code. A tension
  outranks an assumption, so chase it first.

**Two rounds are the floor on the long branch.** One box carries up to four questions, so four
questions at once is still one round. A second round reacts to what the first opened. Sealing
after a single round is allowed only when that round emptied the ledger and opened nothing new, and
you say which.

A question only the user can answer, and they cannot answer yet, moves to the ledger as an accepted
risk. A technical discrepancy is never parked that way: if a test run could settle it, run it.

## The restatement lives inside the question

Before sealing, restate the intent in the user's own words and ask them to break it. **Put the
restatement in the question box's `question` field itself.** Reply text written before a question
box can scroll out of view behind it, so "does the restatement above hold?" can ask someone to
confirm text they never saw. The kit's question guard refuses a question that points at reply text.

## Sequencing

A starting order, not a script:

1. Ask what the code cannot answer: WHO, WHY, NOT.
2. Explore the codebase to settle WHAT and HOW. Never ask what a search would answer.
3. Return to what exploration could not settle, and to anything it found that contradicts step 1.

## Sealing the plan

When the ledger is empty and the restatement is confirmed, write an `## Intent` section at the top
of the plan file covering the six slots and any accepted risks, then the line:

    <!-- INTENT-LOCK:CONFIRMED -->

The user can skip the gate for one plan with `<!-- INTENT-LOCK:WAIVED -->` instead.

Then ask one last question in the box: **"Will you watch this build in this window, or walk away
from it?"** Write the answer into the plan as its own line:

    <!-- INTENT-LOCK:WATCH -->   approval continues in this window, as normal
    <!-- INTENT-LOCK:WALK -->    approval opens a fresh auto-mode session that builds the plan
                                 under a /goal check made from the DONE slot

`intent-guard.sh` refuses to leave plan mode until both lines are there.

## Build shapes

When the build's shape is recognisable, read `references/build-shapes.md` for its question pack:
internal business tool, public or portfolio work, skill, hook or plumbing, frontend or site, remote
server, analysis document, new project.
<!-- INTENT-INJECT:END -->
