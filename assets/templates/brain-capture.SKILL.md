---
name: brain-capture
description: Capture a thought, conclusion, or piece of information into the second brain — classify it, file it in the right note, link it up, and reconcile it against what is already there. Invoke ONLY when the user explicitly asks, by typing /brain-capture or by saying something like "add this to my brain" or "remember this". NEVER trigger this automatically, and never run it just because the conversation touched on a topic in the vault.
---

# Capturing into the second brain

The user has given you something to remember. Filing it is the easy part; the work is making sure
the vault is still coherent afterwards.

`{{BINARY}}` is the `my-brain` executable. Use `--json` for anything you act on.

## 1. Pin down what you are capturing

Restate the thought in one or two sentences and check it back with the user only if it is genuinely
ambiguous. Do not paraphrase away specifics — numbers, names, dates and caveats are usually the part
worth keeping.

If the user handed you several unrelated thoughts at once, treat each as a separate capture and work
through them one at a time. Merging unrelated facts into one note makes both unretrievable.

## 2. Find what the vault already knows

Run `status` first. If the index is stale, run `index`.

Then search — **two to four differently worded queries**, not one:

- the user's own words
- the term the vault would most likely use for this (its canonical name)
- an adjacent or parent concept
- if a person, project or source is named, that name on its own

```
my-brain search "<query>" --json -n 8
```

Union the results. Read the top few notes in full. Then run `my-brain links --from <note>` on the
most relevant ones and follow one hop — the neighbours of a relevant note are usually relevant, and
word matching will not have found them.

You are answering three questions: *Does a note about this already exist? What would this new fact
connect to? Does anything here contradict it?*

## 3. Handle contradictions before you write anything

If the new information conflicts with what a note already says, **stop and ask the user.** Do not
pick a side, do not "update" the note, and do not write both versions and hope.

Show them:

- the existing statement, and which note it is in
- the new statement
- **your recommendation, with the reasoning** — usually one of: the new information is more recent;
  one statement is specific and the other was a generalisation; one has a named source and the other
  does not; other notes in the vault corroborate one of them; the two are not actually in conflict
  and are describing different cases.

Then do what they decide. If they confirm the new version, edit the old statement rather than
appending a second one, and note the change if the reason matters.

A conflict you resolve silently propagates into every answer that note ever supports. This is the
one step in this procedure that is never optional.

## 4. Decide where it goes

**Extend an existing note** when the thought is another fact about a subject the vault already
covers. This is the common case and should be your default — a vault of hundreds of one-line notes
retrieves badly.

**Create a new note** when the thought is about a subject that does not have a home yet, or when it
is substantial enough that someone would go looking for it by name.

Put new notes wherever the vault's existing structure suggests. If the vault has no structure yet,
start a flat layout and let folders emerge when a subject clearly earns one. Do not build an
elaborate hierarchy in an empty vault; the index does the finding, and folders that exist for their
own sake become a filing chore forever after.

## 5. Write it

- Give the note frontmatter: `title`, `tags`, `type`, `status`, `created`, `updated`. Add
  `project:`, `topic:`, `source:` or similar when the note belongs to something specific — those
  become search filters immediately.
- **Reuse the vault's existing tags.** Every `--json` search hit carries its own `tags`, so the
  results from step 2 already show you the vocabulary in use. Invent a new tag only when nothing
  existing fits: `attention` and `focus` as two tags for one idea means a `--filter` finds half the
  notes and the split is invisible until someone goes looking.
- Write in the vault's existing voice and format. Match what is already there.
- Link it: `[[Related Note]]` for every note you found in step 2 that is genuinely related.
- **Add the links back.** Open each note you linked to and add a link to the new note where it fits
  in the prose. A note nothing points at is a note nobody will find.
- Set `updated:` on every note you touched.

## 6. Reconcile duplicates

```
my-brain index
my-brain similar "<the note you just wrote>" --json -n 5
```

A near-duplicate means the vault already had this subject under a different name — often a spelling
variant, a synonym, or a note created before the canonical one existed.

Merge them: pick the note that is better established (more backlinks, better title, more content),
move the unique content from the other into it, then

```
my-brain rm "<the redundant note>"
```

which rewrites every reference before deleting. **Never delete a note with the filesystem.** If the
two notes should keep separate identities but one is the better name, use `my-brain rename` instead
— it moves the file and fixes every link to it in one pass.

## 7. Only now, check size

Order matters here. Splitting a note you are about to merge wastes the work and multiplies the
errors, so duplicates and contradictions get resolved first.

```
my-brain doctor --json
```

For each note flagged as oversized: a long note is a retrieval problem, because search returns whole
notes and a note covering six subjects will surface for all six and answer none of them well.

Split along the seams that already exist — the note's own `##` headings. Each new child note gets a
real title, frontmatter, and a link back to the parent. The parent keeps a short summary of each
section it gave away, plus the link to the child. Then check `links --to` on the parent to see
whether any inbound links were really aimed at a section that has now moved, and repoint them.

Do not split a note that is long because it is genuinely one dense subject. Length is a signal, not
a rule.

## 8. Finish

```
my-brain index
my-brain doctor
```

Then tell the user, briefly and concretely, what changed: notes created, notes updated, anything
merged or split, and any contradiction you raised and how it was settled. Give paths, so they can
open them.
