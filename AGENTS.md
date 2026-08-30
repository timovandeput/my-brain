# AGENTS.md

This file provides guidance to coding agents (Claude Code and any other agent that reads
AGENTS.md) when working with code in this repository.

## What this is

`my-brain` is a compiled Dart CLI that indexes and searches a vault of Obsidian-compatible markdown
notes with BM25, so an agent can use the vault as a second brain past the point where grep works.
It ships as a single self-contained executable and is invoked by an agent, usually with `--json`.

Read `README.md` first — it carries the product rationale and the note model. This file covers the
mechanics of working in the code.

## Commands

```sh
dart test                                     # everything except the scale suite
dart test test/index/bm25_test.dart           # one file
dart test test/index/bm25_test.dart -n "idf"  # one test by name substring
dart test test/vault                          # one directory
dart test -P scale                            # adds the 5,000-note scale suite (tens of seconds)
dart format .                                 # what CI gates on, alongside analyze
dart analyze --fatal-infos                    # what CI gates on
dart run tool/gen_templates.dart              # regenerate templates.g.dart from assets/templates/
./tool/build.sh                               # gen templates + analyze + compile to build/my-brain
./tool/install.sh                             # build, then symlink build/my-brain into ~/.local/bin
./tool/install-release.sh                     # install/update from a published release, no toolchain
```

`dart compile exe` cannot cross-compile, so every platform needs its own runner. Two workflows:

- `.github/workflows/ci.yml` runs on pull requests and pushes to `main`. `lint` regenerates
  `templates.g.dart` and fails if that changes a tracked file, then checks `dart format` and
  `analyze --fatal-infos`; `test` runs `dart test` and `dart test -P scale`; `build` compiles and
  smoke-tests the binary on all four release targets, so a change that breaks the release build
  fails on the pull request.
  `gen_templates.dart` formats the file it writes, because the first two of those gates contradict
  each other otherwise: one wants formatted source, the other wants the generator's exact output.
  The formatter follows the package's language version (`environment.sdk` in `pubspec.yaml`), not
  the SDK on the runner, so its output does not move under CI when a new Dart ships.
- `.github/workflows/release.yml` runs on a `v*` tag. It first checks the tag matches
  `myBrainVersion` in `lib/src/cli/runner_version.dart` — bump that in the same commit as the tag —
  then repeats the full test suite, builds macos-arm64, macos-x64, linux-x64 and windows-x64, and
  publishes the archives plus a `SHA256SUMS.txt` that `tool/install-release.sh` verifies against.

## Architecture

Four layers, each depending only on the ones above it, with `lib/src/model.dart` as the shared
contract between them (`ScannedFile`, `DocRecord`, `SearchQuery`, `SearchHit`, `Posting`, …). Treat
those types as stable; changing one ripples through every layer.

**`vault/`** — reads the filesystem. `scanner.dart` walks the root honouring config excludes and
produces a `VaultManifest` whose sha256 over `path/size/mtime` triples is the index's identity.
`markdown.dart` + `frontmatter.dart` turn one file into a `ParsedNote` (title, aliases, headings,
wikilinks and note-pointing markdown links with source offsets, inline tags, word count).
`linkgraph.dart`'s `LinkResolver` maps a link target to a document by path → path+`.md` → filename
stem → title → alias, all case-insensitive, ties broken lexicographically so results are
deterministic.

**`text/`** — `Analyzer` in `tokenizer.dart` (splitting, stopwords, Porter stemmer). The same
analyzer configuration must run at index time and query time or terms will never match; there is
one `const Analyzer()` used on both paths for that reason.

**`index/`** — `format.dart` is the normative on-disk layout of `.brain/index.bin` and its header
doc comment is the spec; keep it in sync with any layout change and bump `indexFormatVersion`,
which is the only thing gating compatibility (`indexMagic` never moves). `builder.dart` writes it via the
`IndexableDoc` seam, which is the only thing `IndexWriter` sees, so the writer never depends on the
markdown parser. `reader.dart` is region-based and seek-addressed: a query reads the header, the
small fixed tables, then only its own terms' postings and the records of the hits. Do not introduce
a full-file deserialisation on the search path — the scale suite exists to catch exactly that.
`bm25.dart` scores; filters are resolved to a docId set *before* scoring.

**`cli/` + `commands/`** — one `Command<int>` subclass per subcommand, registered in
`cli/runner.dart`. `cli/vault_context.dart` resolves the vault root (via `--vault`, else searching
upward for `.brain/`), loads config, lazily opens the index, computes staleness, and resolves note
arguments; it throws `CliError` which commands catch and translate to an exit code.

### Invariants worth knowing

- **Field weights are folded into term frequency at build time** (title/alias ×3, heading/tag ×2,
  body ×1), so scoring is one pass. Document length stays the *raw* token count, so weighting
  cannot distort BM25 normalisation.
- **Indexing is always a full rebuild**, never incremental, and the index never rebuilds itself.
  Read commands warn on stderr when stale and answer anyway; `rename` and `rm` mutate files and so
  *refuse* on a stale index unless `--force`.
- **`doctor` always exits 0** — it is a report, not a gate.
- **Links are read from the body only.** A wikilink in frontmatter is not an edge: no backlink, and
  `rename` will not rewrite it. `doctor` reports it (`docFlagFrontmatterLinks`) instead.
- **The binary ships no vocabulary.** It defines no frontmatter keys, requires none, and rejects
  nothing; `attrs` reports what the vault actually uses and has no opinion. The note schema (`type`,
  `status`, tag discipline) lives in `assets/templates/AGENTS.md`, so changing it is a template edit,
  not a Dart change. The same goes for the vault layout: `init` creates `notes/`, `logs/` and
  `attachments/`, but no command cares where a note sits, so where things go is taught by the
  templates rather than enforced by the code.

### Output and exit codes

`avoid_print` is a lint error: commands never touch `stdout`/`stderr` directly, they go through
`cli/output.dart`'s `Output`. That guarantees `--json` mode's contract — stdout carries exactly one
JSON document, while progress, warnings and errors go to stderr. `Output.emit` takes both the JSON
body and a human renderer; only one runs. Tests inject a `StringBuffer` for both streams.

Exit codes: `0` success, `1` note not found / ambiguous / refused, `2` usage error, `3` no vault or
no readable index. A corrupt index must always surface as a clean exit 3 — `VaultContext.openIndex`
catches `Error` as well as `Exception` so a malformed file can never dump a stack trace.

### Templates

`assets/templates/*.md` are the files `init` writes into a vault. A compiled executable cannot read
them from disk, so `tool/gen_templates.dart` embeds them into `lib/src/setup/templates.g.dart` as
base64 constants. **Edit the markdown under `assets/`, then regenerate** — never hand-edit the
generated file. `setup/installer.dart` writes them marker-managed: only the region between
`<!-- my-brain:begin -->` and `<!-- my-brain:end -->` is owned by `init`, and `.brain/config.yaml`
is written once and never overwritten (`ChangeKind.keep`).

## Conventions

- `test/` mirrors `lib/src/`, so the tests for a file live at the same relative path
  (`lib/src/vault/markdown.dart` -> `test/vault/markdown_test.dart`). `test/scale_test.dart` stays
  at the top level because it exercises the whole scan-index-search path, not one unit.
- Tests import internals directly (`package:my_brain/src/...`), not just the `lib/my_brain.dart`
  export surface. Integration-flavoured tests build a real vault under `Directory.systemTemp`.
- A slow test is tagged `@Tags(['scale'])` and skipped by default via `dart_test.yaml`.
- `strict-casts` and `strict-raw-types` are on, plus `prefer_final_locals`.
- Comments in this codebase explain *why* a choice was made, particularly where a simpler
  alternative was rejected. Match that when adding code; do not add narration of what the line does.
