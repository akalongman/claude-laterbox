# claude-plugins

A Claude Code plugin marketplace named `akalongman`. Every plugin here is
project-agnostic: it discovers the project layout at runtime and carries no
machine-specific or organization-specific facts.

## Plugins

| Plugin | Contents |
|---|---|
| `later` | A parking lot for follow-up notes. `/later <note>` parks a note at once, even while a turn is running, after a small model has cleaned its text; `/later` alone opens a pane to work through the queue; a terminal command, `later`, reaches the same queue; the skill `later:notes` lists, parks, closes and drops notes on request; a session-start line shows the count. |

## Requirements

`later` needs Claude Code 2.1.296 or later. Its engine, which reads and
writes the queue, needs bash, git 2.31 or later, jq, GNU coreutils and GNU
findutils. `flock` is optional: with it, concurrent writes to a queue are
serialized; without it they run unlocked.

| System | Setup |
|---|---|
| Debian, Ubuntu | `sudo apt install git jq` (bash, coreutils, findutils and `flock` come with the system) |
| Fedora | `sudo dnf install git jq` (the rest comes with the system) |
| Alpine and other BusyBox-based systems | Install bash, git, jq and the GNU coreutils and findutils packages; the BusyBox tools are not enough |
| macOS | `brew install git jq coreutils findutils flock`, then put the plain GNU names first on `PATH` in the shell's startup file: `export PATH="$(brew --prefix)/opt/coreutils/libexec/gnubin:$(brew --prefix)/opt/findutils/libexec/gnubin:$PATH"` |
| Windows | Not supported yet. Inside WSL the Linux rows apply. |

The plugin is developed and tested on Linux; macOS and WSL are untested.

## Install

From a terminal:

```bash
claude plugin marketplace add akalongman/claude-plugins
claude plugin install later@akalongman
```

or inside a session:

```
/plugin marketplace add akalongman/claude-plugins
/plugin install later@akalongman
```

For a team, run the terminal commands with `--scope project` inside the
repository once and commit the `.claude/settings.json` they write.

## later and the parking lot

`NOTES.local.md` at a project's root (the main checkout for a worktree, the
directory itself outside a repository) is a checkbox queue of follow-up notes.
`/later <note>` parks one: the command runs the moment it is typed, also
while a turn is in flight, and prints one line, `later: parked -> <note>`.
Before the note is stored a model cleans its text (spelling, grammar, a vague
reference expanded from the last few messages); when the stored text differs
from the typed one the line ends with `(typed: <text>)`. When every rewrite
path fails, the typed text is stored.

`/later` alone opens a pane of the parked notes, above the prompt (beside
the transcript in fullscreen), and gives it the keys:

| Key | Action |
|---|---|
| Up, Down, Tab | Move between the notes and the action buttons; once the list is taller than the pane the arrows scroll instead |
| `j`, `k` | Next and previous note, at any length |
| `w`, Enter on a row | Put the note's text at the end of the prompt draft and close the pane; nothing is sent |
| `d` | Mark the note done |
| `x` | Drop the note |
| `a` | Type a new note; it is cleaned and parked as `/later <note>` would |
| Esc | Close the pane |

`d` and `x` act only on a note that still reads as it was listed: when
another writer changed or moved it, the pane says so and reads the queue
again. While open, the pane reads the queue every five seconds. A session
that shows no panes, such as `claude -p "/later"`, prints the list instead.

The `/config` row `later.rewrite` picks the rewrite:

- `haiku` (default): a small model, given the newest messages of the
  conversation as an excerpt; a few thousand tokens and one to three seconds
  per note.
- `fork`: the session's own model over the whole conversation; the rewrite
  sees everything, at roughly the conversation's size in cache-read tokens
  (about 200,000 on a long session) and 4 to 20 seconds per note, bounded at
  40 seconds, after which `haiku` is tried.
- `off`: the typed text is stored unchanged, no model call.

The output row reaches the model with the next user message, together with a
hidden note that the parked text is a reminder for a later session, not a task
for now. Spoken requests ("what is parked", "tick off note 2", "park this for
later") are handled by the skill `later:notes`, which lists, parks, closes and
drops notes through the same engine. At the start of a terminal session a
hook prints the count of parked notes and the new ones, and once a week the
oldest five.

### The terminal command

At the start of a terminal session the plugin keeps a command `later` in
`~/.local/bin`: `~/.local/bin/later` is a symbolic link to `bin/later` in the
plugin's data folder (`~/.claude/plugins/data/later-akalongman`), which links
to `scripts/later` of the installed version. The command appears at the first
session start after the install, not at the install, and an update reaches it
at the next session start. The hook never replaces a file it did not make:
when `~/.local/bin/later` exists and is not its link, the session-start
message says so once and leaves that file as it is.

From any terminal, in a project: `later` lists the queue, `later <note>`
parks a note as typed, `later done <n>...` and `later drop <n>...` close
notes by their list number, `later all` counts the open notes of every
queue under your home folder (up to six levels deep), `later -- <note>`
parks text that looks like a subcommand, and `later --help` lists these
forms.

`~/.local/bin` must be on `PATH`. macOS never adds it; Ubuntu and Debian add
it at login when the folder exists; elsewhere add
`export PATH="$HOME/.local/bin:$PATH"` to the shell's startup file. The
session-start message says once when the session's `PATH` lacks it. On
Windows the plugin adds no terminal command.

The `/config` row `later.terminal` is `link` (the default) or `off`: `off`
removes the link the plugin made at the next session start and adds none.
Uninstalling deletes the plugin's data folder and leaves
`~/.local/bin/later` dangling: shells skip it ("command not found"), and
`rm ~/.local/bin/later` removes it. To leave nothing behind, set
`later.terminal` to `off` and start a session before uninstalling.

## Develop

Test the working copy in one session without installing it:

```bash
claude --plugin-dir ./plugins/later
```

Check before pushing:

```bash
claude plugin validate . --strict
claude plugin validate ./plugins/later --strict
claude plugin test ./plugins/later
bash plugins/later/tests/later.test.sh
shellcheck plugins/later/scripts/later plugins/later/scripts/later.sh plugins/later/tests/*.sh
```

Once a session has loaded the plugin from this folder, which writes the
declarations it needs to `plugins/later/.claude-plugin/types/`, the command
`npx -y -p typescript@5.9.3 tsc -p plugins/later --noEmit` type-checks the mod.

A change reaches installed copies only when `version` in
`plugins/later/.claude-plugin/plugin.json` changes, so a release bumps it.

## License

MIT; see `LICENSE`.
