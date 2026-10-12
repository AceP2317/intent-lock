# Question rules

Paste into a project's `CLAUDE.md`, or import it there with a line reading
`@~/.claude/intent-lock/rules/questions.md`. The kit's `question-guard.sh` refuses the mechanical
breaches; the judgement half is yours.

- **Every decision goes through the question box** (`AskUserQuestion`), never as a question written
  in reply prose. A set of named options is answered with one pick; a question in prose waits for the
  user to compose a reply.
- **Fill the set to the box's capacity** where real alternatives exist, up to four options. Batch
  independent questions into one box; ask one alone when its answer changes the next question.
- **Mark exactly one option `(Recommended)`**, at the end of its label. A full set still carries a
  position, not a balanced menu.
- **Each option description gives four beats, one sentence each, in this order:** what this is; how
  it differs from the other choices; what you will see once it is picked; what you give up. A set
  where nothing costs anything is a menu, not a decision.
- **Teach the mechanism** a consequence rests on, and define any term the user may not know in its
  own short sentence. "One commit unpushed" means nothing to someone not told how committing differs
  from pushing.
- **The question sentence says what changes depending on the answer.**
- **No file names, flags or code identifiers in a header or option label.** Name what the thing
  does instead.
- **No `preview` field.** A preview swaps the dialog for a side-by-side layout that draws labels
  only, so every option's explanation is dropped. Draw a comparison grid in the reply instead.
- **Never point at reply text.** No "the restatement above", "listed above" or "in my reply". Text
  written before a question box can be out of view while the box is open, so put what the question
  is about inside the question itself.
