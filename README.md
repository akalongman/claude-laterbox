# Laterbox

Laterbox is a Claude Code plugin that parks follow-up notes for a later
session. A note goes into a checkbox queue, `LATER.local.md`, at the root of
the project you are in, and stays there until you close or drop it:

```markdown
# Parked notes (`/later`)

- [ ] Rerun the flaky checkout test before the release (2026-10-15 14:05)
- [x] Ask Sam about the deploy window (2026-10-14 09:30)
```

The project root is the repository's root, the main checkout's root for a
worktree, and the folder itself outside a repository. A home folder kept in
git (a dotfiles setup) is the root for itself only: a folder below it without
a repository of its own keeps its own queue. The queue file's name is a
setting, `laterbox.file` (see [Settings](#settings)).

What you type:

| Where | Command | What it does |
|---|---|---|
| A session | `/later <note>` | Parks the note at once, even while a turn is running, after a model has cleaned its text |
| A session | `/later` | Opens a pane to work through the parked notes |
| A session | "what is parked", "tick off note 2", "park this for later" | The skill `laterbox:notes` lists, parks, closes and drops notes |
| A terminal | `later`, `later <note>`, `later done <n>`, `later drop <n>`, `later all` | The same queue from any shell |

At the start of a terminal session a line shows the count of parked notes.

## Using it

### `/later <note>`

The command runs the moment it is typed, also while a turn is in flight, and
prints one line, `later: parked -> <note>`. Before the note is stored a model
cleans its text (spelling, grammar, a vague reference expanded from the last
few messages); when the stored text differs from the typed one the line ends
with `(typed: <text>)`. When every rewrite path fails, the typed text is
stored. The setting `laterbox.rewrite` chooses the model or turns the rewrite
off; [What it sends](#what-it-sends) says what each choice sends.

The output row reaches the model with the next user message, together with a
hidden note that the parked text is a reminder for a later session, not a
task for now.

### The pane: `/later` alone

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

### Asking in words: the skill

Spoken requests ("what is parked", "do the second parked note", "tick that
note off", "drop note 3", "park this for later") are handled by the skill
`laterbox:notes`, which lists, parks, closes and drops notes through the same
engine. It asks before it starts work on a parked note.

### The session-start line

At the start of a terminal session a hook prints the count of parked notes,
names up to three notes parked since the count was last shown, and once a
week lists the oldest five. The line is shown to you only; the model does not
see it.

### The terminal command

From any terminal, in a project:

| Command | What it does |
|---|---|
| `later` | List the queue |
| `later <note>` | Park a note as typed (no rewrite) |
| `later done <n>...` | Mark notes done by their list number |
| `later drop <n>...` | Drop notes by their list number |
| `later all` | Count the open notes of every queue under your home folder, up to six levels deep |
| `later -- <note>` | Park text that looks like a subcommand |
| `later --help` | List these forms |

The whole argument string is the note unless it has the exact shape of a
subcommand, so `later done with the migration` parks a note.

On Linux and macOS the session-start hook keeps the command as a link,
`~/.local/bin/later` (see [What it writes](#what-it-writes)). It appears at
the first terminal session start after the install, not at the install, and
an update reaches it at the next session start. When `~/.local/bin/later`
already exists and the plugin did not make it, the session-start message
says so once and leaves that file as it is.

`~/.local/bin` must be on `PATH`. macOS never adds it; Ubuntu and Debian add
it at login when the folder exists; elsewhere add
`export PATH="$HOME/.local/bin:$PATH"` to the shell's startup file. The
session-start message says once when the session's `PATH` lacks it.

## Install

From a terminal:

```bash
claude plugin marketplace add akalongman/claude-laterbox
claude plugin install laterbox@akalongman
```

or inside a session:

```
/plugin marketplace add akalongman/claude-laterbox
/plugin install laterbox@akalongman
```

For a team, run the two terminal commands with `--scope project` inside the
repository once and commit the `.claude/settings.json` they write.

## Requirements

### Platforms

The engine, `scripts/later.sh`, reads and writes the queue for every entry
point. It needs bash and git 2.31 or later (`git --version` prints it). Every
other program it calls ships with Linux, stock macOS and Git for Windows
alike, so nothing else needs installing. For its lock it uses `flock` on
Linux when that `flock` takes a wait timeout (util-linux's does, BusyBox's
does not) and a lock folder made with `mkdir` everywhere else.

| Platform | Setup |
|---|---|
| Linux: Debian, Ubuntu | `sudo apt install git` (bash comes with the system) |
| Linux: Fedora | `sudo dnf install git` (bash comes with the system) |
| Linux: Alpine and other BusyBox-based systems | Install bash and git (`apk add bash git` on Alpine). Untested: CI runs no BusyBox target. |
| macOS | git from the Xcode command line tools (`xcode-select --install`); the system's bash 3.2 is enough. Nothing from Homebrew. |
| Windows (native, PowerShell) | Not supported yet, planned for a later release. Use WSL. |
| WSL | The Linux rows apply. Use one environment per project, keep the project inside the WSL file system, and never park notes into one queue from WSL and from native Windows: their locks do not see each other. |

CI runs the engine's test suite on Linux, on macOS with the engine limited to
the system folders (`/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`), and on Windows
under Git Bash ahead of native support. BusyBox systems and WSL are untested.

### Claude Code

Laterbox needs Claude Code 2.1.296 or later. `/later` and its pane run in
the terminal CLI: the plugin's hooks module starts the engine through process
calls that Claude Code's module API marks as CLI only. The desktop app is
untested. The session-start line appears in terminal sessions only; headless
runs, the desktop app, IDE extensions and SDK hosts skip it.

## What it runs, sends and writes

### What it runs

- A `SessionStart` hook for new sessions:
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/later.sh" session-start`, with a
  10-second timeout. It prints the session-start line, keeps the terminal
  link and stores the queue file setting.
- A hooks module, `hooks/register.tsx`, that Claude Code loads. It registers
  `/later`, draws the pane, runs `scripts/later.sh` as a process (no shell,
  10-second timeout) and makes the rewrite's model calls.
- The skill `laterbox:notes`, which runs `scripts/later.sh` with `list`,
  `add`, `done` or `drop` as shell commands; its declaration allows exactly
  these four.
- The terminal command, `scripts/later`, which runs `scripts/later.sh`.

What the hooks module does, call by call:

- **Hooks.** `session.start` registers `/later` and, while the pane is open,
  re-reads the queue every five seconds. `command.run` answers `/later`
  only: it parks a note or opens the pane. `ui.render`, `ui.focus` and
  `ui.close` draw and drive its own pane only.
- **The one program it starts** (`process.run`): the plugin's own engine,
  `scripts/later.sh` in the plugin's install folder, whose path is built
  from that folder when it runs. The arguments are one subcommand (`add`,
  `list`, `rows`, `done` or `drop`) and, for `add`, `done` and `drop`, the
  note text or number. The environment variable `CLAUDE_PLUGIN_OPTION_FILE`
  carries the queue file setting. Nothing else is run.
- **What it reads.** The conversation's newest messages
  (`session.messages`), only to build the rewrite's excerpt for the model
  call below; and its own pane state (the queue as listed, the selected
  note), only to draw the pane. Neither reaches the engine, which gets the
  note text alone, and neither leaves the machine except through the
  rewrite's model call described under [What it sends](#what-it-sends).
- **The prompt draft.** `w` (or Enter on a row) puts the note's text at the
  end of the prompt draft; nothing is sent.

The engine runs git only to find the project root (`git rev-parse`), and
otherwise standard tools such as `date`, `awk`, `sed`, `sort` and `find`.
`later all` reads every file named like the queue under your home folder, up
to six levels deep, skipping `node_modules`, `vendor`, `.git` and
`.worktrees`.

### What it sends

The rewrite is the only model call the plugin makes itself. Only
`/later <note>` and the pane's `a` start it, as the setting
`laterbox.rewrite` says:

- `haiku` (default): the typed note and an excerpt of the conversation go to
  a small model. The excerpt is the newest messages that carry text, at most
  12, each cut to 300 characters, at most 4,000 characters in all. It costs a
  few thousand tokens and one to three seconds per note.
- `fork`: the session's own model reads the whole conversation and the typed
  note. The rewrite sees everything, at roughly the conversation's size in
  cache-read tokens (about 200,000 on a long session) and 4 to 20 seconds per
  note, bounded at 40 seconds, after which `haiku` is tried.
- `off`: nothing is sent; the typed text is stored unchanged.

Both model calls go through Claude Code's own model access. Beyond them,
what the plugin adds to the conversation goes to the model with the rest of
the session: the output row of `/later` with its hidden note, and the output
of the skill's commands. The plugin opens no network connection of its own;
the engine and the terminal command make no network access.

### What it writes

- **The queue file**, `LATER.local.md` or the name `laterbox.file` gives, at
  the project root (the main checkout for a worktree). The first note creates
  it with the heading `` # Parked notes (`/later`) ``. Closing a note rewrites
  it through a temporary file beside it, `.later-queue.XXXXXX`, renamed over
  it; every line the rewrite does not change stays byte for byte as it was.
- **The data folder**, `~/.claude/plugins/data/laterbox-<marketplace>` (its
  base follows `CLAUDE_CONFIG_DIR` when set; an install from another
  marketplace gets a folder named after that marketplace). It holds
  `bin/later`, a link to `scripts/later` of the installed version, and
  `terminal-state`, the last link and `PATH` conditions the hook saw. The
  plugin writes there on Linux and macOS only.
- **The link `~/.local/bin/later`**, to `bin/later` in the data folder, made
  at a terminal session start on Linux and macOS, creating `~/.local/bin`
  when it is missing. It lives outside the plugin folder. The hook never replaces a file it did not make, and setting
  `laterbox.terminal` to `off` removes the link at the next session start.
- **The state folder `~/.cache/later/`** (`$XDG_CACHE_HOME/later/` when that
  is set). Per queue, under a SHA-1 of the queue's path: when the
  session-start line last showed it and last listed the oldest notes, and the
  lock its writers take turns through.
- **The stored setting `~/.local/state/later/queue-file`**
  (`$XDG_STATE_HOME/later/` when that is set): a copy of `laterbox.file`, for
  the terminal command and the skill, which cannot read Claude Code's
  settings.

The plugin writes no git ignore file, git configuration, shell startup file
or `PATH`.

## Git and the queue file

A new queue file is untracked, and the plugin never adds it to an ignore
file. Choose one of these per project (with another `laterbox.file` name, use
that name):

- Keep it out of the repository for everyone: add `LATER.local.md` to the
  repository's `.gitignore`.
- Keep it out for you alone, with no change to the repository's files: add
  it to the clone's `.git/info/exclude`, or once for every repository to a
  global excludes file (`~/.config/git/ignore` unless `core.excludesFile`
  names another).
- Share it: commit it. Two people who park notes on separate branches then
  get a merge conflict at the end of the file, because each branch appends
  its notes there; resolve it by keeping both sets of lines.

## Settings

The settings appear in `/config` as `laterbox.<key>`.

| Setting | Values | Default | What it does |
|---|---|---|---|
| `laterbox.rewrite` | `haiku`, `fork`, `off` | `haiku` | How `/later` and the pane clean a note before storing it; see [What it sends](#what-it-sends) |
| `laterbox.terminal` | `link`, `off` | `link` | `link` keeps `~/.local/bin/later` at each terminal session start; `off` removes the link the plugin made at the next session start and adds none |
| `laterbox.file` | a file name | `LATER.local.md` | The queue file's name at every project's root |

Pick a `laterbox.file` name that no other tool or person uses: the engine
appends to and rewrites whatever file has that name, and reads any checkbox
in it as a parked note. The name must be one plain file name: not empty, not
`.` or `..`, with no `/`, `\`, `*`, `?`, `[` or control character, at most
255 bytes. An unusable value is never used or stored: the last usable value
(the stored copy, below) or the default is used instead, and the
session-start message says so at every session start until it is fixed.

The setting is one value for every project, and one value per person. The
terminal command and the skill read the stored copy, which every session
start and every run from `/later` or the pane refresh. If you use more than
one Claude Code configuration folder, give every one the same value: the
terminal follows whichever ran last. Clearing the setting returns every entry
point to `LATER.local.md` at the next session start.

Changing the name moves nothing. Queues under the old name stay where they
are, and no entry point lists them any more, `later all` included. To carry a
queue over, rename it by hand at each project root, old name first; for
example, when the old name was the one below and the new one is the default:

```bash
mv NOTES.local.md LATER.local.md
```

`mv` replaces a file that already has the new name, so merge the two by hand
where both exist. A renamed queue counts as new to the session-start line:
its first session start shows its notes as new, once.

## Uninstall

```bash
claude plugin uninstall laterbox@akalongman
```

A team install comes out the way it went in: run
`claude plugin uninstall laterbox@akalongman --scope project` inside the
repository and commit the `.claude/settings.json` it changes.

Uninstalling deletes the plugin's data folder. What stays behind:

- `~/.local/bin/later`, now a dangling link that shells skip ("command not
  found"); `rm ~/.local/bin/later` removes it. To leave no link, set
  `laterbox.terminal` to `off` and start a terminal session before
  uninstalling.
- The state folders:
  `rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/later" "${XDG_STATE_HOME:-$HOME/.local/state}/later"`
  removes them.
- The queue files in your projects, which are yours to keep or delete.

## Develop

Test the working copy in one session without installing it:

```bash
claude --plugin-dir .
```

Check before pushing:

```bash
claude plugin validate . --strict
claude plugin test .
bash tests/later.test.sh
shellcheck scripts/later scripts/later.sh tests/*.sh
```

The suite's helpers build and read the hook's JSON with `jq`, so the suite
needs `jq` on `PATH` (the engine itself does not, and the suite proves it).
The suite says which helper program it lacks before it stops, and prints a
reason for every case it skips on the platform it runs on. To run it with the
engine limited to the system folders, as CI does on macOS:

```bash
LATER_TEST_ENGINE_PATH=/usr/bin:/bin:/usr/sbin:/sbin bash tests/later.test.sh
```

Once a session has loaded the plugin from this folder, which writes the
declarations it needs to `.claude-plugin/types/`, the command
`npx -y -p typescript@5.9.3 tsc -p . --noEmit` type-checks the module.

CI (`.github/workflows/test.yml`) runs on every push and pull request to
`main`. On Linux it installs Claude Code 2.1.296 and runs validate, the
module tests, the engine suite and shellcheck; on macOS and on Windows under
Git Bash it runs the engine suite.

A change reaches installed copies only when `version` in
`.claude-plugin/plugin.json` changes, so a release bumps it.

## License

MIT; see `LICENSE`.
