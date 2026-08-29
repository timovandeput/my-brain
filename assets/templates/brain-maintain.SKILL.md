---
name: brain-maintain
description: Run a maintenance pass over the second brain — repair broken links, merge duplicate notes, split notes that have grown too large to retrieve well, and add missing cross-references. Invoke ONLY when the user explicitly asks, by typing /brain-maintain or by saying something like "tidy up the vault" or "clean up my notes". NEVER trigger this automatically or as a follow-on to other work.
---

# Maintaining the second brain

This is the same hygiene work that `/brain-capture` does for one thought, applied across the vault.
It edits the user's notes, so it runs only when they ask for it.

`{{BINARY}}` is the `my-brain` executable.

## Scope it first

Ask the user what to cover if they have not said: the whole vault, or a subtree
(`--path-prefix projects/`), or one topic (`--tag x`). On a large vault, a full pass produces more
changes than anyone wants to review at once. Offer to work through the report in batches and stop
when they have had enough.

## Get the report

```
my-brain index
my-brain doctor --json
```

That gives you five lists: broken links, oversized notes, duplicate or colliding titles, ambiguous
link targets, and orphans. Work them in this order — each pass changes the input to the next.

## 1. Broken links

Each broken link is a target that nothing in the vault answers. Search for what it was probably
aiming at:

```
my-brain search "<the broken target>" --json -n 5
```

Three outcomes, and you need to tell them apart:

- **A misspelling or a renamed note.** The target exists under a slightly different name. Fix the
  link to point at the real note. If the *note's* name is the wrong one, fix that instead with
  `my-brain rename` — one command repoints every reference.
- **A note that was intended but never written.** Leave it. An unresolved link is a deliberate
  to-do in a wiki, and deleting it destroys the intent. Collect these and show the user the list at
  the end; they may want some of them written.
- **A note that was deleted by hand**, leaving references behind. Either restore the link to a
  successor note, or replace the link with its display text so the prose still reads.

## 2. Duplicate and colliding titles

For each pair, read both. Then:

- **Genuine duplicates** — same subject under two names. Merge into the better-established note
  (more backlinks, better title), then `my-brain rm` the other so its references are rewritten
  rather than orphaned.
- **Distinct subjects that happen to share a title** — rename one to something unambiguous with
  `my-brain rename`, and add a link between them if a reader could confuse the two.

Run `my-brain similar <note>` on the vault's most central notes even when `doctor` did not flag
them; near-duplicates with different titles do not show up as title collisions.

**If merging surfaces a contradiction between the two notes, stop and ask the user** — show both
statements, where each came from, and your recommendation with the reasoning. Do not pick the
version from the note you happened to keep.

## 3. Missing cross-references

For notes that came up repeatedly in the searches above, check `my-brain links --from` and
`links --to`. Where two notes are clearly about related things and neither points at the other, add
the link, in the prose, where it belongs. Do not append a "Related" dump at the bottom of every
note; a link inside a sentence carries the reason for the connection, and a bare list does not.

Orphans from the `doctor` report are the acute case: a note nothing links to and which links
nowhere is effectively invisible. Find its neighbours by search and connect it, or ask the user
whether it should still exist.

## 4. Oversized notes — last

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

## Finish

```
my-brain index
my-brain doctor
```

Report what you changed: links repaired, notes merged, notes split, references added — with paths.
List separately the things you deliberately did not change: intentional unwritten links, notes you
judged fine at their current length, and anything you were not confident enough to touch. Those are
the user's decisions to make, not yours.
