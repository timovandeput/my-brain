# This vault is a second brain

You are operating a personal knowledge vault: markdown notes linked with `[[wikilinks]]`, readable in
Obsidian. Your job is to answer from it accurately and to keep it worth reading.

Treat it as a small database that happens to store its rows as markdown, not as a folder of
documents that happen to have some YAML on top. The frontmatter is the schema, the wikilinks are the
foreign keys, and both only work if you keep them consistent.

There may be thousands of notes here. You cannot find things by listing directories or grepping, and
you should not try. You will miss notes whose filenames say nothing about their contents, and you
will burn context on files you did not need. Use the index.

## The tool

```
{{BINARY}}
```

That binary is `my-brain` {{VERSION}}. Add `--json` to any command for structured output; that is the
form to use when you are going to act on the result.

| Command | Use it for |
| --- | --- |
| `search <words>` | Ranked lookup. **This is how you find anything.** |
| `similar <note>` | Notes covering the same ground, for duplicate detection. |
| `attrs` | The frontmatter keys and values the vault actually uses, counted. |
| `links --to <note>` | Backlinks: everything that points at a note. |
| `links --from <note>` | A note's outgoing links, with broken ones marked. |
| `doctor` | Vault health: links, sizes, duplicate titles, orphans, unreadable frontmatter. |
| `status` | Whether the index still matches the files on disk. |
| `index` | Rebuild the index. |
| `rename <old> <new>` | Move a note **and rewrite every link to it**. |
| `rm <note>` | Delete a note **after unlinking every reference**. |

Useful `search` flags: `-n 20` for more hits, `--tag x`, `--filter key=value` (repeat for OR on one
key, AND across keys), `--not key=value`, `--path-prefix dir/`.

`similar`, `attrs` and `doctor` take `--path-prefix dir/` as well, for working through one directory
at a time. On `doctor` it narrows what is reported, not what is resolved: a note linked to only from
outside the subtree is still not an orphan.

## Answering a question

1. **Search first, always.** Run two or three differently worded queries, not one. Ranking is
   lexical: it matches the words that are actually in the notes, so if the user says "focus" and the
   vault says "attention", one query finds nothing and the other finds everything. Query the user's
   words, the likely canonical term, and an adjacent concept.
2. **Use the structure when the question has one.** Filters narrow, they do not rank, so they answer
   questions that words cannot. `--filter type=question --filter status=open` is every open
   question. `--filter type=decision --filter project=foo` is why Foo is built the way it is.
3. **Read the top hits.** Scores are comparable within one query only. A large gap between hit 1 and
   hit 2 means the first is probably the answer; a flat spread means the topic is spread across
   notes and you should read several.
4. **Follow the links.** The notes you read will link to others. Those links were placed
   deliberately and encode relationships that word matching cannot see. Follow them one hop before
   concluding, and use `links --to` when you need to know what else depends on a fact.
5. **Answer from the notes, and cite the paths you used.** If the vault does not contain the answer,
   say so plainly rather than filling the gap from general knowledge. If you do add outside
   knowledge, mark it as outside knowledge. If the note you are quoting carries `confidence: low` or
   marks its claim as an inference, pass that on: say what it rests on, do not launder it into a
   fact.

If `search` warns that the index is stale, the vault has changed since it was last indexed. Run
`my-brain index` and search again.

## What one note is

One note is one independently citable thing: an idea, a decision, a person, a project, a source. It
carries enough context to stand on its own, because search returns whole notes and whoever reads it
later will not have the conversation that produced it.

Both ways of getting this wrong hurt retrieval:

- **One note per subject area.** An `AI.md` holding six loosely related ideas comes back for all six
  queries and answers none of them well. `doctor` flags these once they pass the word threshold.
- **One note per sentence.** Fifty files each asserting one thing lose the context that made the
  thing worth keeping. If a note makes no sense without opening its neighbour, it should have stayed
  in the neighbour.

## Where files go

```
notes/         every note you write
logs/          dated raw capture: meetings, transcripts, journal entries
attachments/   images, PDFs, anything that is not markdown
```

The vault root holds AGENTS.md, CLAUDE.md and the tool's own dot-directories, and nothing else. Notes
written into the root bury the instructions you are reading, so new notes go under `notes/` and dated
dumps under `logs/`.

The path carries that one distinction. The frontmatter carries everything else, so do not build
folders for `type`, `status`, `project` or subject. `--filter type=decision --filter project=foo`
already answers those, and a folder tree that repeats them is a second copy of the schema that goes
wrong the first time an open question is answered or a seed grows into a note. Subfolders under
`notes/` are for a subject that has genuinely outgrown one directory; let them emerge from notes that
already exist rather than laying out an empty hierarchy first.

Use `my-brain rename` to move a note between directories, never `mv`. A bare `[[Deep Work]]` link
resolves by filename, so moving its target rewrites nothing, but a link written as a path does need
rewriting and only `rename` will do it.

## Frontmatter: the retrieval model

Every scalar and list-of-scalars key becomes a `--filter`, so the frontmatter is what turns a pile of
prose into something queryable.

```yaml
---
title: Use Postgres for Foo
type: decision
status: stable
tags: [databases, postgres]
project: foo
confidence: high
created: 2026-01-15
updated: 2026-08-29
---
```

| Key | The question it answers | Values |
| --- | --- | --- |
| `title` | what is this called | the note's own name; keep it in step with the filename |
| `type` | what kind of thing is it | one of the seven below, nothing else |
| `status` | where is it in its life | one of the six below, nothing else |
| `tags` | what is it about | subject terms only, lowercase, `/` for hierarchy |
| `project` | which project owns it | the project note's filename stem, no brackets |
| `confidence` | how sure are we | `high`, `medium`, `low`, on inferred claims only |
| `created`, `updated` | when | `YYYY-MM-DD` |

`type` is one of:

| Value | For |
| --- | --- |
| `note` | an idea, concept or claim. The default, and most of the vault. |
| `source` | something read, watched or heard. One note per source. |
| `person` | someone who comes up more than once. |
| `project` | a body of work with a beginning and an end. |
| `decision` | a choice that was made, and the reasoning behind it. |
| `question` | something open, or since answered. |
| `log` | a meeting, a call, a journal entry: dated, about what happened. |

`status` is one of: `seed` (a fragment, not yet worth citing), `developing`, `stable`, `superseded`
(replaced by a newer note, kept and linked forward), `archived` (no longer true or relevant, kept for
history), and, on questions only, `open` and `answered`.

Five rules hold this together:

- **Never invent a value.** Use the closest listed one. A note filed as `type: initiative` is
  invisible to every `--filter type=project` and nothing will ever tell you. If the vocabulary
  genuinely does not fit what you are filing, ask the user to extend it rather than extending it
  yourself.
- **Never invent a key** unless you can name the query it answers and no existing key or link
  answers it. `importance: 8`, `interesting: true` and `category: useful` filter nothing anybody will
  ever ask for, and each one is another thing to keep consistent forever.
- **Keep `tags` to the subject axis.** Type, status, project, year, priority and "read later" have
  properties of their own, or do not belong in the vault at all. Tags that mix axes turn every
  `--tag` query into a half-answer.
- **Reuse the vocabulary already in use.** `my-brain attrs` lists every key and value in the vault
  with its note count, so you can see what this vault calls things before you add `focus` next to
  `attention`. `attrs --key tags` expands one key. Search hits also carry their own `tags`.
- **Never put `[[wikilinks]]` in frontmatter.** The index reads links from the body only. A link in
  frontmatter creates no backlink, is not checked against the vault, and `rename` does not rewrite
  it, so it rots the first time anything moves. `doctor` lists these under "links in frontmatter".
  Frontmatter holds values. The body holds links.

## Relations live in the body

Links are `[[Note Title]]`, or `[[Note Title|what you want it to read as]]`. A link inside a sentence
carries the reason for the connection, so prefer that. When a relation is structural rather than
prose, give it a labelled line of its own:

```md
**Supersedes:** [[Decision - Use MongoDB]]
**Based on:** [[Benchmark - Foo databases]]
**Source:** [[Book - Designing Data-Intensive Applications]], p. 142
```

Those are ordinary links, so `links --to`, `doctor` and `rename` all see them, and the label words
are indexed with the rest of the body. That is why provenance belongs here and not in a `sources:`
key.

Link generously: a fact is only retrievable if something points at it. When you link A to B, consider
whether B should point back. A one-way link is half a connection.

Filenames are the note's identity. Keep them human-readable and stable.

## Say what you inferred

Anything you worked out rather than were told is an inference, and it has to read like one. "The
migration probably caused the slowdown: both happened on the 14th and no other change is recorded"
is worth keeping. "The migration caused the slowdown" is a fact the vault never had, and it will be
quoted back as one. Set `confidence:` on any note whose central claim you inferred, and say in the
body what the inference rests on. Where you do not know something, write that down under an
`## Open questions` heading. An honest gap is more useful than a confident guess, and much easier to
fix later.

## A note is finished when

1. `type` and `status` are set, from the lists above, and `doctor` does not report the note under
   "unreadable frontmatter" (a YAML error costs the note every filter it thought it had).
2. The title names the one thing the note is about, well enough to pick it out of a result list.
3. It stands on its own for a reader who has no other context.
4. Its claims are distinguishable from its inferences and the user's opinions.
5. Every person, project or source it names that has a note is linked to that note.
6. Where the information came from is on the page.
7. Its tags reuse vocabulary the vault already has.
8. `similar` says nothing else already covers it.

## Editing rules

- **Never `mv` or `rm` a note.** Use `my-brain rename` and `my-brain rm`, which rewrite every
  referring link. A note moved by hand leaves broken links scattered across the vault, and you will
  not find them all.
- **Re-index after writing.** `my-brain index` after a batch of edits, not after every file.
- **Raw input is not knowledge yet.** A transcript, a paste or a meeting dump goes in whole as
  `type: log`, `status: seed`. It turns into knowledge when its entities, decisions and questions
  become notes of their own with real titles. Answer from those, and treat anything still
  unprocessed as raw material rather than as settled fact.
- **Never resolve a contradiction on your own.** If new information conflicts with what a note
  already says, stop and ask the user which is right, with your reasoning for the more likely
  answer. Overwriting a note with the wrong version quietly corrupts everything downstream of it.

## Manual commands: do not run these on your own

These procedures run **only** when the user explicitly asks for them. Do not trigger them because a
conversation looked related.

| The user says | You follow |
| --- | --- |
| `/brain-capture`, or "add this to my brain", "remember this" | `.agents/skills/brain-capture/SKILL.md` |
| `/brain-maintain`, or "tidy up the vault", "clean up my notes" | `.agents/skills/brain-maintain/SKILL.md` |

Answering questions from the vault is not one of these. Do that freely, using the loop above.
