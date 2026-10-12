# Build-shape question packs

Read on demand, when the shape of the build is recognisable. Use the matching pack instead of the
generic six slots. If no pack fits, fall back to the slots and consider adding a pack.

Each pack is a candidate set, not a form. Skip what context already settled; the job is an empty
ledger, not a completed checklist.

**Every question below is written as working notes and must not reach the user as written.** Before
any of it becomes a question box, rewrite it in the user's words: say what changes depending on the
answer, what happens on each option, and the mechanism the choice turns on (`rules/questions.md`).

---

## Internal business tool

A dashboard, triage console, data-extraction workflow or spreadsheet tool for a team.

- Who runs it: you alone, your team, or someone who gets no walkthrough?
- Is it ever shown upward to leadership? That decides the styling and whether it needs a summary
  view a reader can take in at a glance.
- Which data extract feeds it, and is that extract a one-off pull or regenerated on a schedule? A
  tool built on a one-off pull dies the first time the data refreshes.
- Does it need to know an as-of date, or the difference between pending and applied changes? Tools
  that ignore state give subtly wrong answers.
- What does it export, and where does that export travel?
- Could someone else run it next quarter without you in the room?

---

## Public or portfolio work

A demo, a featured post, a business site.

- Is any real employer data, terminology or internal detail reachable in the output, including in
  commit history, fixtures and screenshots?
- Is a fictional re-domain the target, or is this a neutral build with no internal origin?
- Which channel promotes it, and does that change the shape? A featured card is not a live site.
- Who is the reader: a recruiter skimming for twenty seconds, a peer, or a client evaluating?
- Does the repo need to be public, and has it ever held anything that must not go public?

---

## Skill

- Where must it run, and what does each extra surface cost to keep in step?
- Does it shape how the model responds, or does it do a thing? Does it fire on a command or on the
  work appearing?
- What must it never do? A skill with no stated anti-scope drifts into its neighbours.
- Which existing skill does it overlap? Two near-identical descriptions compete and neither wins.
- Is the output objectively checkable? If yes, capture a few verified input and output pairs now,
  while a correct run is in front of you.

---

## Hook or plumbing

- Which event, and why that one? A prompt hook fires every turn; a tool hook fires per tool call,
  concurrently across a parallel batch; a session hook fires once.
- Does it observe, or can it block? A blocking hook must say which way it fails when it cannot read
  its own state. Fail open, and say so out loud: a check that swallows its own error reads exactly
  like one that found nothing.
- What does it cost per turn? Hook output is read on the turn it is written and every turn after.
- If it runs once per session, is that flag keyed by session id and made atomically? A read-then-
  write flag loses to concurrent fires, and a global flag is shared across sessions.
- What happens when its input file is renamed or deleted: silence, or a claim that something is
  active when it is not?

---

## Frontend or site

- Whose brand: neutral public, a client's, or an employer's?
- Which pages are in scope, and which are explicitly not?
- Is this a new look, polish on something that works, or identity assets? They are different jobs.
- Is the local dev port pinned before first run, so the address never drifts?
- What does it look like on a phone, and is any wide element scrolling the page sideways?

---

## Remote server

- Which machine, and are you at the keyboard or is the session running `ssh` itself? That changes
  how fine-grained each step must be.
- Does it touch a service that must survive a reboot?
- Is there a deploy copy in the repo that must be edited rather than the server directly?
- What is the rollback, and can you run it alone?

---

## Analysis or decision document

- Who reads it, and how long do they give it? One minute and a full read are different documents.
- What decision does it feed, and is that decision already made?
- Must the reader be able to disagree with the method, or only the conclusion?
- What is the one number or sentence they will carry away?
- Is one recommendation wanted, or a balanced set of options?

---

## New project

- Its own folder and repository, and a first push?
- Does it need seed documents (`CLAUDE.md`, `README.md`) or is it small enough to be one file?
- Local port pinned before first run?
- Does it need its own API key and spending cap? Caps are per key, so a shared key means a shared
  cap.
