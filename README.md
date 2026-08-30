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

### From a release, on macOS or Linux

```sh
curl -fsSL https://raw.githubusercontent.com/timovandeput/my-brain/main/tool/install-release.sh | bash
my-brain version
```

That picks the binary for your machine out of the latest GitHub release, checks it against the
release's `SHA256SUMS.txt`, and puts it in `~/.local/bin`. Running the same line again is how you
update — it replaces whatever is installed. Two environment variables steer it:

- `INSTALL_DIR=/usr/local/bin` installs somewhere else.
- `MY_BRAIN_VERSION=v0.1.0` pins a release instead of taking the latest.

The script covers the two platforms it can install onto: Apple silicon Macs and x64 Linux. **On
Windows**, take `my-brain-windows-x64.zip` from the [releases page][releases], unpack it, and put
`my-brain.exe` in a directory on your PATH. An **Intel Mac** has no prebuilt binary at all —
GitHub's Intel macOS runner is on its way out — so build from source as below.

Installing by hand on macOS or Linux works the same way: take the archive, unpack it, move
`my-brain` onto your PATH. A browser download is quarantined by macOS and Gatekeeper will refuse to
run it, so clear the flag first — the install script uses curl, which does not set it:

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
This is the route for any platform the release matrix in `.github/workflows/release.yml` does not
cover, an Intel Mac among them.

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

## Using the vault

Start an agent in the vault root. It reads `AGENTS.md`, which `init` wrote, and that file tells it
where the binary is, which commands exist, and how the notes are organised. Nothing else needs
configuring, and the agent does not need to have seen this vault before. Claude Code reads the same
file through the one-line `CLAUDE.md`.

### Adding information

Type `/brain-capture`, or say "add this to my brain". Capture is manual on purpose. An agent that
files a note every time the conversation brushes a topic fills the vault with noise you then have
to clean up.

What happens next is why capture is a skill rather than a file write. The agent separates what you
said from what it concluded, and writes the second as an inference carrying `confidence:` or not at
all. It splits the input by type: a meeting is rarely one note, it is usually a project, a person, a
decision and an open question, four notes that each answer a different query months later. It
searches the vault before writing so a fifth note about Foo gets merged into the one that already
exists. Then it writes the frontmatter, links the notes up, and re-indexes.

Material too long or too messy to process now goes into `logs/` whole, as `type: log`,
`status: seed`. Raw input parked deliberately is fine. Raw input mistaken for knowledge is not.

If you edit notes yourself, run `my-brain index` afterwards. The index never rebuilds itself.

### Answering questions

Ask the agent a question in plain language. `AGENTS.md` tells it how to answer, and the procedure is
worth knowing because it explains the answers you get:

1. Search first, with two or three differently worded queries. Ranking is lexical, so if you say
   "focus" and the vault says "attention", one query finds nothing and another finds everything.
2. Use filters when the question has a shape. `--filter type=question --filter status=open` is every
   open question. `--filter type=decision --filter project=foo` is why Foo is built the way it is.
   Filters narrow, they do not rank, so they answer what words cannot.
3. Read the top hits, then follow their links one hop. Those links were placed deliberately and
   encode relationships that word matching cannot see.
4. Answer from the notes and cite the paths used. If the vault does not have the answer, say so
   rather than filling the gap from general knowledge, and pass on a note's `confidence: low` rather
   than laundering it into a fact.

Any agent that follows the `AGENTS.md` convention can do this. The vault carries its own manual, so
there is no per-agent setup and no prompt to paste.

### Reading the vault in Obsidian

The vault is a folder of plain markdown with `[[wikilinks]]`, so Obsidian opens it as it stands.
Choose "Open folder as vault" and point it at the vault root. There is nothing to convert and
nothing to sync, and both can have the vault open at once. The only thing my-brain owns is the
`.brain/` directory, which Obsidian hides anyway because it starts with a dot.

Exclude the agent's own files from Obsidian's search. Go to Preferences -> Files and Links ->
Excluded files and add `AGENTS.md` and `CLAUDE.md`. They are the manual, not notes, and because they
spell out the whole vocabulary they otherwise surface near the top of half your searches. Obsidian
de-emphasises excluded files rather than deleting them from the index: they drop out of the quick
switcher, graph view and link suggestions, and fall to the bottom of search results.

If you rename or move a note in Obsidian, Obsidian rewrites the links itself and my-brain's index
goes stale. Run `my-brain index`, or ask the agent to.

## Backups are yours to arrange

my-brain has no undo, no trash and no version history. `rm` deletes the file, `rename` rewrites
every referring note in place, and the agent edits notes directly while it captures. Those are
ordinary filesystem writes and nothing in the tool can take one back. Keeping copies of the vault is
your responsibility, not the tool's.

Git is the option worth reaching for first. Notes are plain markdown, so the history is readable,
a diff shows exactly which sentence an agent changed, and you can revert one note without touching
the rest.

```sh
cd my-vault
git init
my-brain init     # sees the repo and keeps .brain/index.bin out of it
git add . && git commit -m "vault"
git remote add origin git@github.com:you/my-vault.git
git push -u origin main
```

`init` adds the index to `.gitignore` only when the vault is already a git repository, so run
`git init` first, or re-run `my-brain init` afterwards. The index is a rebuildable binary and does
not belong in the history; `my-brain index` regenerates it in seconds on a fresh clone.

Commit and push on whatever rhythm you keep, and make a point of committing before a
`/brain-maintain` pass or a batch of renames, which touch many files at once. `--dry-run` on
`rename` and `rm` shows the plan before anything is written, but a commit is what saves you after
the fact. Use a private repository. A second brain is personal by definition, and a vault pushed to
a public remote stays readable in the history even after you delete the file.

If git is not for you, copy the vault folder to a cloud storage provider on a schedule you will
actually keep, and keep dated copies rather than one live mirror. A continuously synced folder
propagates a deletion as fast as it propagates a note, so it protects you from a dead disk but not
from a bad edit, unless the provider keeps file version history and you know how to get at it.

## Commands of the executable

`my-brain help` lists the subcommands, and `my-brain help <command>` gives one command's arguments
and flags. Both also work as `--help`. That output comes from the code, so it stays right when a
flag changes, which a table in this file would not.

Leave the running to the agent. The binary is built to be driven by one: every command takes
`--json`, the interesting answers are ranked lists that want a follow-up query, and `rename` and
`rm` rewrite links across many files in one go. Ask in plain language instead. The agent knows the
vault, and `AGENTS.md` tells it which command fits the question.

Two are yours to run. `my-brain init` sets a vault up, and `my-brain index` rebuilds the index after
you edit notes by hand or move them around in Obsidian.

## Development

```sh
dart test              # unit and integration tests
dart test -P scale     # the 5,000-note scale suite
dart run tool/gen_templates.dart   # after editing assets/templates/*.md
./tool/build.sh
```

`docs/architecture.md` is the place to start on the code. It walks the four layers, the on-disk
index regions and the invocation flows, with diagrams.

The files `init` writes live in `assets/templates/` as real markdown and are compiled into the
binary as base64 constants — the executable is self-contained, so it cannot read them from disk.
Regenerate after editing them.
