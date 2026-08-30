---
name: brain-capture
description: Capture a thought, conclusion, or piece of information into the second brain — classify it, file it in the right note, link it up, and reconcile it against what is already there. Invoke ONLY when the user explicitly asks, by typing /brain-capture or by saying something like "add this to my brain" or "remember this". NEVER trigger this automatically, and never run it just because the conversation touched on a topic in the vault.
---

# Capturing into the second brain

The user has given you something to remember. Writing it down is the easy part. The work is deciding
what kind of thing it is, splitting it into the pieces the vault can retrieve separately, and making
sure the vault is still coherent afterwards.

`{{BINARY}}` is the `my-brain` executable. Use `--json` for anything you act on. AGENTS.md carries
the note model: the `type` and `status` vocabularies, what belongs in `tags`, and why relations go in
the body. Follow it exactly. Every value you invent here is one the next search will miss.

## 1. Pin down what you were given

Restate it in one or two sentences, and check back with the user only if it is genuinely ambiguous.
Do not paraphrase away specifics. Numbers, names, dates and caveats are usually the part worth
keeping.

Separate what the user told you from what you concluded. The first is what the vault records; the
second gets written as an inference, with `confidence:` set and its basis stated, or not written at
all.

## 2. Classify before you write

Do not go straight from a paragraph of input to a file. Work out what is in it first:

- **What type is each piece?** `note`, `source`, `person`, `project`, `decision`, `question`, `log`.
- **Which entities does it name?** People, projects, sources, systems. Each one that recurs deserves
  a note, and everything else links to it.
- **What does it actually claim?** A decision made, a fact recorded, an opinion held, a question
  still open. These are different types and they retrieve differently.

A meeting note about Foo is not one capture. It is a project, a person, a decision, and an open
question, four notes that each answer a different query:

```
Transcript
  ├── project: Foo
  ├── person: Alice
  ├── decision: use Postgres
  └── question: should Foo shard?
```

If the raw material is long or messy and you cannot process it now, file it whole as `type: log`,
`status: seed`, and say so. Raw input parked deliberately is fine. Raw input mistaken for knowledge
is not.

Several unrelated thoughts in one message are several captures. Work them one at a time.

## 3. Find what the vault already knows

Run `status` first. If the index is stale, run `index`.

Then search, **two to four differently worded queries**, not one:

- the user's own words
- the term the vault would most likely use for this (its canonical name)
- an adjacent or parent concept
- every person, project and source you named in step 2, each on its own

```
my-brain search "<query>" --json -n 8
```

Union the results. Read the top few notes in full. Then run `my-brain links --from <note>` on the
most relevant ones and follow one hop. The neighbours of a relevant note are usually relevant, and
word matching will not have found them.

You are answering three questions: *Does a note about this already exist? What would this new fact
connect to? Does anything here contradict it?*

## 4. Handle contradictions before you write anything

If the new information conflicts with what a note already says, **stop and ask the user.** Do not
pick a side, do not "update" the note, and do not write both versions and hope.

Show them:

- the existing statement, and which note it is in
- the new statement
- **your recommendation, with the reasoning.** Usually one of: the new information is more recent;
  one statement is specific and the other was a generalisation; one has a named source and the other
  does not; other notes in the vault corroborate one of them; the two are not actually in conflict
  and are describing different cases.

Then do what they decide. If they confirm the new version, edit the old statement rather than
appending a second one, and note the change if the reason matters. When the old statement was a
decision that a new decision replaces, keep it: set the old note to `status: superseded` and add
`**Superseded by:** [[The New Decision]]`. Knowing what we used to think, and why we stopped, is
worth as much as the current answer.

A conflict you resolve silently propagates into every answer that note ever supports. This is the one
step in this procedure that is never optional.

## 5. Pick the operation for each piece

You have a short list of things to file and a picture of what the vault holds. Each piece gets one
operation, decided before you touch a file:

| Situation | Operation |
| --- | --- |
| The subject has a note and this is another fact about it | **update** that note |
| The subject has no note, and someone would look for it by name | **create** a note |
| The subject has two notes under different names | **merge**, then update the survivor |
| One note in the way already covers two subjects | **split** it, then file into the right half |
| The fact belongs to an existing note but names something new | **update**, and **create** the entity note it links to |

Updating an existing note is the common case and should be your default. A vault of hundreds of
one-line notes retrieves badly.

Put new notes wherever the vault's existing structure suggests. If the vault has no structure yet,
start flat and let folders emerge when a subject clearly earns one. Do not build an elaborate
hierarchy in an empty vault; the index does the finding, and folders that exist for their own sake
become a filing chore forever after.

## 6. Write it

- **Frontmatter from the model in AGENTS.md**: `title`, `type`, `status`, `tags`, `created`,
  `updated`, plus `project:` when it belongs to one and `confidence:` when its central claim is
  something you inferred. Use the listed `type` and `status` values and no others.
- **Tags are subjects, not filing labels.** Reuse what the vault already uses. `my-brain attrs`
  gives you the whole vocabulary with counts, and `attrs --key tags` expands it; the search hits
  from step 3 carry their own tags too. Invent a tag only when nothing existing fits: `attention`
  and `focus` as two tags for one idea means a `--tag` query finds half the notes, and the split
  stays invisible until someone goes looking.
- **No wikilinks in frontmatter.** `project: foo` is a filter value, a plain stem with no brackets.
  The link to `[[Project Foo]]` goes in the body, where the link graph can see it.
- **Link the entities.** Every person, project and source you identified in step 2 gets a
  `[[link]]` in the prose, and a note of its own if it does not have one. Structural relations get a
  labelled line: `**Supersedes:**`, `**Based on:**`, `**Source:**`.
- **Record where it came from.** A URL, a book with a page, a conversation with a date. A fact whose
  origin is lost cannot be re-checked when it is challenged, and it will be challenged.
- **Say what is inferred and what is unknown.** Write inferences as inferences, with what they rest
  on. Put genuine gaps under `## Open questions` rather than filling them in.
- **Add the links back.** Open each note you linked to and add a link to the new note where it fits
  in the prose. A note nothing points at is a note nobody will find.
- Write in the vault's existing voice and format, and set `updated:` on every note you touched.

## 7. Reconcile duplicates

```
my-brain index
my-brain similar "<the note you just wrote>" --json -n 5
```

A near-duplicate means the vault already had this subject under a different name, often a spelling
variant, a synonym, or a note created before the canonical one existed.

Merge them: pick the note that is better established (more backlinks, better title, more content),
move the unique content from the other into it, then

```
my-brain rm "<the redundant note>"
```

which rewrites every reference before deleting. **Never delete a note with the filesystem.** If the
two notes should keep separate identities but one is the better name, use `my-brain rename` instead.
It moves the file and fixes every link to it in one pass.

## 8. Only now, check size

Order matters here. Splitting a note you are about to merge wastes the work and multiplies the
errors, so duplicates and contradictions get resolved first.

```
my-brain doctor --json
```

For each note flagged as oversized: a long note is a retrieval problem, because search returns whole
notes and a note covering six subjects will surface for all six and answer none of them well.

Split along the seams that already exist, the note's own `##` headings. Each new child note gets a
real title, its own frontmatter, and a link back to the parent. The parent keeps a short summary of
each section it gave away, plus the link to the child. Then check `links --to` on the parent to see
whether any inbound links were really aimed at a section that has now moved, and repoint them.

Do not split a note that is long because it is genuinely one dense subject. Length is a signal, not a
rule.

## 9. Validate before you finish

Deterministic checks, on every note you created or edited. Do not skip these because the writing
looked fine; the failures here are exactly the ones that are invisible until a search comes back
empty six months from now.

```
my-brain index
my-brain doctor
my-brain links --from "<each note you wrote>"
```

- `doctor` reports zero new broken links, and none of your notes is an orphan.
- `doctor` lists none of your notes under "unreadable frontmatter" (its YAML broke, so it has no
  attributes at all) or "links in frontmatter" (that link is not in the graph).
- `my-brain attrs --key type` and `--key status` show your values folded into the existing counts,
  not sitting alone at the bottom of the list as a new one.
- Each note passes the finished-note checklist in AGENTS.md.

Fix what fails, re-index, and check again.

## 10. Finish

Tell the user, briefly and concretely, what changed: notes created, notes updated, anything merged or
split, and any contradiction you raised and how it was settled. Give paths, so they can open them.
Say separately what you deliberately left unprocessed, such as raw material parked as `status: seed`,
and anything you recorded as an inference rather than a fact.
