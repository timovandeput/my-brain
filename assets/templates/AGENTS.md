# This vault is a second brain

You are operating a personal knowledge vault: markdown notes linked with `[[wikilinks]]`, readable in
Obsidian. Your job is to answer from it accurately and to keep it worth reading.

There may be thousands of notes here. You cannot find things by listing directories or grepping, and
you should not try — you will miss notes whose filenames say nothing about their contents, and you
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
| `similar <note>` | Notes covering the same ground — duplicate detection. |
| `links --to <note>` | Backlinks: everything that points at a note. |
| `links --from <note>` | A note's outgoing links, with broken ones marked. |
| `doctor` | Vault health: broken links, oversized notes, duplicate titles, orphans. |
| `status` | Whether the index still matches the files on disk. |
| `index` | Rebuild the index. |
| `rename <old> <new>` | Move a note **and rewrite every link to it**. |
| `rm <note>` | Delete a note **after unlinking every reference**. |

Useful `search` flags: `-n 20` for more hits, `--tag x`, `--filter key=value` (repeat for OR on one
key, AND across keys), `--not key=value`, `--path-prefix dir/`.

## Answering a question

1. **Search first, always.** Run two or three differently worded queries, not one. Ranking is
   lexical: it matches the words that are actually in the notes, so if the user says "focus" and the
   vault says "attention", one query finds nothing and the other finds everything. Query the user's
   words, the likely canonical term, and an adjacent concept.
2. **Read the top hits.** Scores are comparable within one query only. A large gap between hit 1 and
   hit 2 means the first is probably the answer; a flat spread means the topic is spread across
   notes and you should read several.
3. **Follow the links.** The notes you read will link to others. Those links were placed
   deliberately and encode relationships that word matching cannot see. Follow them one hop before
   concluding, and use `links --to` when you need to know what else depends on a fact.
4. **Answer from the notes, and cite the paths you used.** If the vault does not contain the answer,
   say so plainly rather than filling the gap from general knowledge. If you do add outside
   knowledge, mark it as outside knowledge.

If `search` warns that the index is stale, the vault has changed since it was last indexed. Run
`my-brain index` and search again.

## Note conventions

Frontmatter is optional but makes notes filterable. When you write or edit a note, use these keys:

```yaml
---
title: Deep Work
aliases: [Focused Work]
tags: [productivity, attention]
type: note
status: developing
created: 2026-01-15
updated: 2026-08-29
---
```

- `type` — `note`, `source`, `person`, `project`, `decision`, `question`, `log`
- `status` — `seed` (a fragment), `developing` (being built out), `stable` (settled)
- `tags` — lowercase, hierarchical with `/` when useful (`project/alpha`)
- Add any other key you find useful; every scalar and list-of-scalars key becomes filterable, so
  `project: alpha` in frontmatter means `--filter project=alpha` works immediately.

Links are `[[Note Title]]`, or `[[Note Title|what you want it to read as]]`. Link generously: a fact
is only retrievable if something points at it. When you link A to B, consider whether B should point
back — a one-way link is half a connection.

Filenames are the note's identity. Keep them human-readable and stable.

## Editing rules

- **Never `mv` or `rm` a note.** Use `my-brain rename` and `my-brain rm`, which rewrite every
  referring link. A note moved by hand leaves broken links scattered across the vault, and you will
  not find them all.
- **Re-index after writing.** `my-brain index` after a batch of edits, not after every file.
- **Never resolve a contradiction on your own.** If new information conflicts with what a note
  already says, stop and ask the user which is right, with your reasoning for the more likely
  answer. Overwriting a note with the wrong version quietly corrupts everything downstream of it.

## Manual commands — do not run these on your own

These procedures run **only** when the user explicitly asks for them. Do not trigger them because a
conversation looked related.

| The user says | You follow |
| --- | --- |
| `/brain-capture`, or "add this to my brain", "remember this" | `.agents/skills/brain-capture/SKILL.md` |
| `/brain-maintain`, or "tidy up the vault", "clean up my notes" | `.agents/skills/brain-maintain/SKILL.md` |

Answering questions from the vault is not one of these. Do that freely, using the loop above.
