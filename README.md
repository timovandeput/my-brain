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

### From a release

```sh
curl -fsSL https://raw.githubusercontent.com/timovandeput/my-brain/main/tool/install-release.sh | bash
my-brain version
```

That picks the binary for your machine out of the latest GitHub release, checks it against the
release's `SHA256SUMS.txt`, and puts it in `~/.local/bin`. Running the same line again is how you
update — it replaces whatever is installed. Two environment variables steer it:

- `INSTALL_DIR=/usr/local/bin` installs somewhere else.
- `MY_BRAIN_VERSION=v0.1.0` pins a release instead of taking the latest.

To do it by hand, take an archive from the [releases page][releases]:
`my-brain-macos-arm64.tar.gz` for Apple silicon, `my-brain-macos-x64.tar.gz` for Intel Macs, plus
`my-brain-linux-x64.tar.gz` and `my-brain-windows-x64.zip`. Unpack it and move `my-brain` onto your
PATH. A browser download is quarantined by macOS and Gatekeeper will refuse to run it, so clear the
flag first — the install script uses curl, which does not set it:

```sh
tar -xzf my-brain-macos-arm64.tar.gz
xattr -d com.apple.quarantine ./my-brain 2>/dev/null || true
chmod +x ./my-brain && mv ./my-brain ~/.local/bin/
```

[releases]: https://github.com/timovandeput/my-brain/releases/latest

### From source

```sh
./tool/install.sh          # builds and links into ~/.local/bin
```

Dart cannot cross-compile, so `dart compile exe` produces a binary for the machine that runs it.
Binaries for macOS, Linux and Windows come from the CI matrix in
`.github/workflows/release.yml`, which is also what a tag publishes.

## Set up a vault

```sh
mkdir my-vault && cd my-vault
my-brain init
```

`init` shows a diff of every file before writing it and asks first. It creates:

```
AGENTS.md                                the agent's operating manual
CLAUDE.md                                one line: @AGENTS.md
notes/                                   every note
logs/                                    dated raw capture
attachments/                             anything that is not markdown
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
| `similar <note>` | Notes covering the same ground — duplicate detection. `-n`, `--path-prefix`. |
| `attrs` | Frontmatter keys and values in use, with counts. `--key k`, `-n`, `--path-prefix`. |
| `links --to/--from <note>` | Backlinks, or outgoing links with broken ones marked. |
| `doctor` | Broken links, oversized notes, duplicate titles, ambiguous links, orphans, unreadable frontmatter, links in frontmatter. `--path-prefix`. |
| `rename <old> <new>` | Move a note and rewrite every link to it. A `dir/` destination moves it in there. |
| `rm <note>` | Delete a note after unlinking every reference. |

`--path-prefix` scopes a command to one directory. On `doctor` it narrows what is reported and not
what is resolved, so a note linked to only from outside the subtree still counts as linked.

Filters are OR within one key and AND across keys. Every scalar and list-of-scalars frontmatter key
becomes filterable, so `project: alpha` in a note means `--filter project=alpha` works immediately.

The index never rebuilds itself. `search` warns on stderr when it is stale and answers anyway; the
agent decides when to re-index, because it knows whether it just finished writing.

## The note model

The instructions `init` installs define a small schema and hold the agent to it, because a
vocabulary that drifts is a filter that silently returns half an answer.

- `type` is one of note, source, person, project, decision, question, log. `status` is one of seed,
  developing, stable, superseded, archived, plus open and answered on questions. The agent is told
  to ask before extending either list rather than inventing a value.
- `tags` carries the subject axis and nothing else. Type, status, project and priority are
  properties of their own, so `--filter type=decision --filter project=foo` answers "why is Foo
  built this way" and `--filter type=question --filter status=open` answers "what is still open".
- Notes live in `notes/`, dated raw capture in `logs/`, non-markdown in `attachments/`, and the root
  stays the manual and the tool's own directories. The path carries that one distinction; the
  frontmatter carries the rest. Folders per `type` or per project would be a second copy of the
  schema, and it goes wrong the first time an open question is answered.
- Relations live in the body, either in prose or as labelled lines like `**Supersedes:** [[...]]`.
  The parser reads links from the body only, so a wikilink in frontmatter creates no backlink and is
  not rewritten by `rename`; `doctor` now reports it rather than leaving it to rot silently.
- Inferences are written as inferences and carry `confidence:`. Raw input goes in as `type: log`,
  `status: seed`, and becomes knowledge only once it is split into typed, titled, linked notes.

The binary holds none of this. It ships no vocabulary, requires no key, and rejects nothing, because
the ontology is the vault's to choose and lives in AGENTS.md where you can edit it. What the tool
contributes is the two halves that need to be mechanical:

- **`attrs`** reports the vocabulary the vault actually uses, counted, and has no opinion about what
  it should be. Drift is visible as a long tail (`project` 40, `projects` 1) and what to do about it
  stays a judgement for the agent and the user. It also answers the question that made "reuse the
  existing tags" hard to follow before: an agent can now ask the vault what it calls things instead
  of guessing from search hits.
- **`doctor`** reports only facts about what this tool can do with a note. Two of them are about
  frontmatter: a `---` block whose YAML did not parse (the note indexes and searches normally but
  has no attributes, so every `--filter` silently skips it) and a `[[wikilink]]` written into a
  property (not an edge, no backlink, and `rename` will not rewrite it). Neither says anything about
  which keys a note ought to carry.

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
