---
name: brain-maintain
description: Run a maintenance pass over the second brain — repair schema drift and broken links, merge duplicate notes, split notes that have grown too large to retrieve well, and add missing cross-references. Invoke ONLY when the user explicitly asks, by typing /brain-maintain or by saying something like "tidy up the vault" or "clean up my notes". NEVER trigger this automatically or as a follow-on to other work.
---

# Maintaining the second brain

This is the same hygiene work that `/brain-capture` does for one thought, applied across the vault.
It edits the user's notes, so it runs only when they ask for it.

`{{BINARY}}` is the `my-brain` executable. AGENTS.md carries the note model this pass enforces: the
`type` and `status` vocabularies, what belongs in `tags`, and why relations live in the body.

## Scope it first

Ask the user what to cover if they have not said: the whole vault, or a subtree, or one topic
(`--tag x`). `doctor`, `attrs`, `search` and `similar` all take `--path-prefix notes/projects/`, so a
subtree pass is the same procedure with that flag on every command. On a large vault, a full pass
produces more changes than anyone wants to review at once. Offer to work through the report in
batches and stop when they have had enough.

## Get the report

```
my-brain index
my-brain doctor --json
```

That gives you seven lists: broken links, oversized notes, duplicate or colliding titles, ambiguous
link targets, orphans, notes whose frontmatter did not parse, and notes with a wikilink written into
frontmatter. `doctor` reports only what the tool can establish as fact; whether the vault's own
vocabulary is being kept is pass 2's job. Work the passes in order, since each one changes the input
to the next.

## 1. Notes in the wrong place

The vault root is for AGENTS.md, CLAUDE.md and the tool's own dot-directories. Notes go under
`notes/`, dated raw capture under `logs/`. Notes written into the root bury the instructions, and a
vault set up before this layout existed has all of them there.

```
find . -maxdepth 1 -name '*.md' ! -name AGENTS.md ! -name CLAUDE.md
```

Show the user the list and offer to move it. Each file moves with `my-brain rename`, never `mv`:

```
my-brain rename "<file>" "notes/<file>"
```

Links written as a bare `[[Name]]` resolve by filename and so survive the move untouched; links
written as a path are rewritten by `rename` as it goes. Re-index afterwards.

Do not go reorganising the vault beyond that. A subject folder someone made deliberately is theirs,
and moving notes between existing directories changes nothing about how they retrieve.

## 2. Schema and vocabulary drift

`doctor` will not judge this for you, and search cannot find it either: a note filed under a value
nobody queries is invisible by definition. `attrs` reports the vocabulary the vault actually uses,
counted, and leaves the judgement to you.

```
my-brain attrs --json
my-brain attrs --key tags
```

Read the counts. A vocabulary in good order is a short list with plausible frequencies. Drift shows
up as a long tail of near-synonyms: `project` 40 times and `projects` once, or `initiative` twice
where every other note says `project`. Fix the outliers to the vocabulary in AGENTS.md. One misfiled
value costs nothing until someone filters on the right one and gets a confident, incomplete answer.

Two other things worth reading out of the same report. A key that appears on three notes and nowhere
else is either a mistake or an idea that never caught on; either way it is not a filter anyone can
rely on. And a key whose values are nearly all distinct, such as a free-text field, filters nothing
useful even though every note carries it.

If the vault's real vocabulary has genuinely outgrown the list in AGENTS.md, say so and let the user
decide whether to extend it. Do not quietly adopt a new value because several notes already use it,
and do not rewrite forty notes to a new vocabulary without asking first.

Now the two frontmatter findings from the `doctor` report:

- **unreadable frontmatter.** The note opened a `---` block whose YAML did not parse, so it carries
  no attributes at all and every `--filter` passes it by while the note goes on looking fine in
  search results. Usually an unquoted colon or bracket in a value. Fix the YAML and re-index.
- **links in frontmatter.** A `[[wikilink]]` written into a property. It is not an edge: no
  backlink, nothing in `links --from`, and `rename` will not rewrite it when its target moves. Move
  the link into the body, as prose or as a labelled relation line, and leave a plain value in the
  frontmatter if it was serving as a filter.

Notes with no frontmatter at all are a different matter, and neither command reports them, because
having no properties is a choice rather than a defect. If the user wants every note typed, find them
with `grep -rL --include='*.md' --exclude-dir='.*' '^type:' .` and work through the list with them.
Do not go stamping `type:` onto notes nobody asked you to touch.

## 3. Broken links

Each broken link is a target that nothing in the vault answers. Search for what it was probably
aiming at:

```
my-brain search "<the broken target>" --json -n 5
```

Three outcomes, and you need to tell them apart:

- **A misspelling or a renamed note.** The target exists under a slightly different name. Fix the
  link to point at the real note. If the *note's* name is the wrong one, fix that instead with
  `my-brain rename`. One command repoints every reference.
- **A note that was intended but never written.** Leave it. An unresolved link is a deliberate
  to-do in a wiki, and deleting it destroys the intent. Collect these and show the user the list at
  the end; they may want some of them written.
- **A note that was deleted by hand**, leaving references behind. Either restore the link to a
  successor note, or replace the link with its display text so the prose still reads.

## 4. Duplicate and colliding titles

For each pair, read both. Then:

- **Genuine duplicates**, the same subject under two names. Merge into the better-established note
  (more backlinks, better title), then `my-brain rm` the other so its references are rewritten
  rather than orphaned.
- **Distinct subjects that happen to share a title.** Rename one to something unambiguous with
  `my-brain rename`, and add a link between them if a reader could confuse the two.

Run `my-brain similar <note>` on the vault's most central notes even when `doctor` did not flag
them; near-duplicates with different titles do not show up as title collisions.

**If merging surfaces a contradiction between the two notes, stop and ask the user.** Show both
statements, where each came from, and your recommendation with the reasoning. Do not pick the
version from the note you happened to keep. Where one note supersedes the other rather than
duplicating it, keep both: mark the old one `status: superseded` and link it forward.

## 5. Raw material that never became knowledge

```
my-brain attrs --key status
my-brain search "<a word from the vault's subject area>" --filter status=seed --json -n 20
```

Seeds and `type: log` dumps are raw input that was parked deliberately. They are fine as a record and
poor as an answer, because nothing in them is titled, typed or linked, so they surface for queries
they cannot answer.

Show the user the list and let them pick. For each one they choose, follow `/brain-capture` from its
classify step: pull out the entities, decisions and questions, write them as their own notes, link
them back to the raw note, and leave the original in place as the source. Do not process the whole
backlog unasked; this is the most expensive work in the pass.

## 6. Missing cross-references

For notes that came up repeatedly in the searches above, check `my-brain links --from` and
`links --to`. Where two notes are clearly about related things and neither points at the other, add
the link, in the prose, where it belongs. Do not append a "Related" dump at the bottom of every
note; a link inside a sentence carries the reason for the connection, and a bare list does not.

Orphans from the `doctor` report are the acute case: a note nothing links to and which links nowhere
is effectively invisible. Find its neighbours by search and connect it, or ask the user whether it
should still exist.

## 7. Oversized notes, last

Splitting is last because merging and relinking change which notes are oversized, and splitting
first would multiply the work.

For each flagged note, decide whether length is actually the problem. A note is too long when it
covers several subjects, so search returns it for all of them and answers none well. A note that is
long because one subject is genuinely dense should be left alone.

To split: use the note's own `##` headings as the seams. Each child gets a real title, frontmatter
carried over from the parent where it applies, and a link back. The parent keeps a one-or-two
sentence summary of each section it gave away plus the link to the child, so it still works as an
entry point. Then run `my-brain links --to <parent>` and repoint any inbound link that was really
aimed at a section which has now moved.

Splitting is also the moment to check the other extreme. A note of one sentence that is not an entity
stub, has no links, and repeats what its neighbour says is a fragment: fold it back into the note it
belongs to and `my-brain rm` it.

## Finish

```
my-brain index
my-brain doctor
```

Report what you changed: schema values corrected, links repaired, notes merged, notes split,
references added, with paths. List separately the things you deliberately did not change:
intentional unwritten links, notes you judged fine at their current length, raw material left
unprocessed, and anything you were not confident enough to touch. Those are the user's decisions to
make, not yours.
