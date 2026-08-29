# my-brain

A compiled Dart CLI that indexes and searches a vault of Obsidian-compatible markdown notes, so an
AI agent can use that vault as a second brain at a scale where grep and directory listings stop
working.

The split of responsibilities is deliberate:

- **`my-brain` owns the mechanical work** — BM25 indexing, ranked retrieval, frontmatter filtering,
  link-graph queries, and link-safe renames and deletes.
- **The agent owns the judgement** — classifying new information, writing and merging notes,
  resolving contradictions with the user, and deciding when a note has grown too large to retrieve
  well.

`my-brain init` writes the agent's own operating instructions into the vault (`AGENTS.md` plus
skills under `.agents/skills/`), so the vault carries its manual and stays in step with whatever the
binary can currently do.

## Status

Under construction.
