# my-brain

A compiled Dart CLI that indexes and searches a vault of Obsidian-compatible markdown notes, so an
AI agent can use that vault as a second brain at a scale where grep and directory listings stop
working.

The split of responsibilities is deliberate:

- **`my-brain` owns the mechanical work** — BM25 indexing, ranked retrieval, frontmatter filtering,
  link-graph queries, and renames and deletes that rewrite every referring link.
- **The agent owns the judgement** — classifying new information, writing and merging notes,
  resolving contradictions with the user, and deciding when a note has grown too large to retrieve
  well.

`my-brain init` writes the agent's own operating instructions into the vault, so the vault carries
its manual and stays in step with whatever the binary can currently do.

## Install

```sh
./tool/install.sh          # builds and links into ~/.local/bin
```

Dart cannot cross-compile, so `dart compile exe` produces a binary for the machine that runs it.
Binaries for macOS, Linux and Windows come from the CI matrix in
`.github/workflows/release.yml`.

## Set up a vault

```sh
mkdir my-vault && cd my-vault
my-brain init
```

`init` shows a diff of every file before writing it and asks first. It creates:

```
AGENTS.md                                the agent's operating manual
CLAUDE.md                                one line: @AGENTS.md
.agents/skills/brain-capture/SKILL.md    manual-only: add information
.agents/skills/brain-maintain/SKILL.md   manual-only: vault hygiene pass
.claude/skills -> ../.agents/skills      so Claude Code finds the same files
.brain/config.yaml                       tuning; written once, never overwritten
```

Skills live under `.agents/skills/` and are symlinked into `.claude/skills`, so an agent following
the AGENTS.md convention and Claude Code read the same files rather than two copies that drift
apart. Where symlinks are unavailable the files are copied and re-synced on each `init`.

Re-running `init` refreshes the instructions when my-brain gains commands. AGENTS.md is
marker-managed: anything you add outside the `<!-- my-brain:begin -->` block survives.
`init --check` reports drift without changing anything.

Then start an agent in the vault and talk to it. `/brain-capture` files a thought; asking a question
retrieves from the notes.

## Commands

Every command takes `--json`, which is the form the agent uses.

| Command | |
| --- | --- |
| `index [--stats]` | Rebuild the index. |
| `status` | Doc count, index size, and whether it still matches the files on disk. |
| `search <words>` | Ranked lookup. `-n`, `--tag`, `--filter k=v`, `--not k=v`, `--path-prefix`. |
| `similar <note>` | Notes covering the same ground — duplicate detection. |
| `links --to/--from <note>` | Backlinks, or outgoing links with broken ones marked. |
| `doctor` | Broken links, oversized notes, duplicate titles, ambiguous links, orphans. |
| `rename <old> <new>` | Move a note and rewrite every link to it. |
| `rm <note>` | Delete a note after unlinking every reference. |

Filters are OR within one key and AND across keys. Every scalar and list-of-scalars frontmatter key
becomes filterable, so `project: alpha` in a note means `--filter project=alpha` works immediately.

The index never rebuilds itself. `search` warns on stderr when it is stale and answers anyway; the
agent decides when to re-index, because it knows whether it just finished writing.

## Design

The index is a single region-based binary file, seek-addressable rather than loaded whole. A query
reads the header, three small fixed tables, and then only the postings of its own terms and the
records of the handful of documents that make the result list. `lib/src/index/format.dart` carries
the normative layout.

Field weights (title and aliases ×3, headings and tags ×2, body ×1) are folded into term frequency
at build time, so scoring is a single pass. Document length for BM25 normalisation stays the raw
term count, so weighting cannot distort it.

Indexing is a full rebuild rather than an incremental merge: rebuilding a few thousand notes costs
seconds and is triggered explicitly, whereas incremental merging into a seek-optimised file is a
large amount of machinery whose failure mode is a silently wrong index.

Measured on 5,001 notes: 2.5s to build the index, ~130ms for a cold search including process start,
130ms for a whole-vault `doctor` pass.

## Development

```sh
dart test              # unit and integration tests
dart test -P scale     # the 5,000-note scale suite
dart run tool/gen_templates.dart   # after editing assets/templates/*.md
./tool/build.sh
```

The files `init` writes live in `assets/templates/` as real markdown and are compiled into the
binary as base64 constants — the executable is self-contained, so it cannot read them from disk.
Regenerate after editing them.
