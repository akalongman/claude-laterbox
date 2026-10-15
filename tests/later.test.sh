#!/usr/bin/env bash
# shellcheck disable=SC1010,SC2016,SC2088
# SC1010: `done` is passed as a subcommand argument throughout.
# SC2016, SC2088: literal backticks and a literal tilde are asserted on.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The helpers build and read the hook's JSON with jq, by this absolute path,
# captured before any engine run; no engine run gets it. Without it the
# session-start cases cannot tell a pass from a fail, so none of the suite runs.
JQ="$(type -P jq)" || { echo 'later.test.sh: the test helpers need jq on PATH; nothing was run' >&2; exit 2; }
# shellcheck source=/dev/null
source "$HERE/assert.sh"
# A run from a hook's environment must not link into a real data folder.
unset CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_OPTION_TERMINAL
ENGINE="$HERE/../scripts/later.sh"
# The PATH of every engine run, front-end runs included. CI narrows it to the
# system folders, so the engine cannot lean on a tool the user installed.
ENGINE_PATH="${LATER_TEST_ENGINE_PATH:-$PATH}"

# Why Git Bash skips every case that makes a symbolic link.
NO_LINKS="Git Bash's ln -s makes a copy, not a symbolic link"

# Every engine call runs with a throwaway HOME and cache, UTC, and a fixed
# clock: 2026-10-04 14:05:00 UTC.
T_HOME="$(mktemp -d)";  TMPDIRS+=("$T_HOME")
T_CACHE="$(mktemp -d)"; TMPDIRS+=("$T_CACHE")
NOW=1791122700
DAY=86400

lt() { # dir args...
    local dir="$1"; shift
    ( cd "$dir" && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" TZ=UTC LATER_NOW="$NOW" PATH="$ENGINE_PATH" bash "$ENGINE" "$@" )
}

# --- resolution, add, list -------------------------------------------

repo="$(mk_repo)"
mkdir -p "$repo/app/Http"
out="$(lt "$repo/app/Http" add check the S3 retry path)"
assert_eq "$out" "later: parked -> check the S3 retry path" "add confirms"
assert_file "$repo/NOTES.local.md" "subdirectory parks at the git toplevel"
assert_nofile "$repo/app/Http/NOTES.local.md" "no queue in the subdirectory"
assert_eq "$(sed -n 3p "$repo/NOTES.local.md")" "- [ ] check the S3 retry path (2026-10-04 14:05)" "note is stamped"
assert_eq "$(sed -n 1p "$repo/NOTES.local.md")" '# Parked notes (`/later`)' "new queue gets the heading"

git -C "$repo" worktree add -q -b feat/x "$repo/.worktrees/feat-x" >/dev/null 2>&1
mkdir -p "$repo/.worktrees/feat-x/sub"
lt "$repo/.worktrees/feat-x/sub" add from the worktree >/dev/null
assert_nofile "$repo/.worktrees/feat-x/NOTES.local.md" "worktree does not get its own queue"
assert_contains "$(cat "$repo/NOTES.local.md")" "from the worktree" "worktree parks in the main checkout"

plain="$(mktemp -d)"; TMPDIRS+=("$plain")
lt "$plain" add outside any repo >/dev/null
assert_file "$plain/NOTES.local.md" "no repository: queue in the directory itself"

# HOME is itself a repository (dotfiles): a directory under it with no
# repository of its own must not fall through to the HOME queue.
git -C "$T_HOME" init -q
mkdir -p "$T_HOME/Downloads/foo"
lt "$T_HOME/Downloads/foo" add under home >/dev/null
assert_file "$T_HOME/Downloads/foo/NOTES.local.md" "home-as-repo: queue stays in the directory"
assert_nofile "$T_HOME/NOTES.local.md" "home-as-repo: HOME queue untouched"
lt "$T_HOME" add in home itself >/dev/null
assert_file "$T_HOME/NOTES.local.md" "HOME itself uses the HOME queue"

q="$(mk_repo)"
out="$(lt "$q" add "$(printf 'line one\nline   two\t end ')")"
assert_eq "$(tail -n1 "$q/NOTES.local.md")" "- [ ] line one line two end (2026-10-04 14:05)" "whitespace and newlines collapse"
out="$(lt "$q" add '   ')"
assert_eq "$out" "later: nothing to park (empty note)" "empty note refused"
assert_eq "$(grep -c '^- \[ \]' "$q/NOTES.local.md")" "1" "empty note not written"

# Legacy and hand-edited lines, a closed line, and a file without a final newline.
l="$(mk_repo)"
printf '%s\n' '# Parked notes (`/later`)' '' \
    '- [ ] Move upload disk config to env' \
    '- [x] already done' \
    '  -  [ ]   hand edited spacing' \
    '- [ ] Recheck group lecturer policy (2026-09-22 09:00)' > "$l/NOTES.local.md"
printf '%s' '- [ ] no final newline' >> "$l/NOTES.local.md"
before="$(file_digest "$l/NOTES.local.md")"
out="$(lt "$l" list)"
assert_eq "$(file_digest "$l/NOTES.local.md")" "$before" "list never rewrites the file"
assert_contains "$out" "$(basename "$l"): 4 parked" "list header counts open notes only"
assert_contains "$out" " 1. Move upload disk config to env (undated)" "legacy note is undated"
assert_contains "$out" " 2. hand edited spacing (undated)" "hand-edited spacing parses"
assert_contains "$out" " 3. Recheck group lecturer policy (12d)" "age in days"
assert_contains "$out" " 4. no final newline (undated)" "last line without newline is read"
lt "$l" add appended after a missing newline >/dev/null
assert_eq "$(grep -c 'no final newline$' "$l/NOTES.local.md")" "1" "append does not glue onto the last line"
assert_contains "$(lt "$l" list)" " 5. appended after a missing newline (today)" "fresh note is today"

e="$(mk_repo)"
assert_eq "$(lt "$e" list)" "later: no parked notes" "list with no queue file"

# A stamp-shaped tail that is not a real date stays part of the text.
b="$(mk_repo)"
printf '%s\n' '- [ ] call back (2026-13-45 99:99)' > "$b/NOTES.local.md"
assert_contains "$(lt "$b" list)" " 1. call back (2026-13-45 99:99) (undated)" "invalid stamp is text"

# --- done, drop -------------------------------------------------------

d="$(mk_repo)"
printf '%s\n' '# Parked notes (`/later`)' '' '- [ ] one' '- [x] closed' '- [ ] two (2026-10-01 10:00)' '- [ ] three' > "$d/NOTES.local.md"
out="$(lt "$d" done 2)"
assert_eq "$out" "later: done -> two" "done prints the closed note"
assert_eq "$(sed -n 5p "$d/NOTES.local.md")" "- [x] two (2026-10-01 10:00)" "done ticks the box and keeps the line"
assert_contains "$(lt "$d" list)" " 2. three (undated)" "positions renumber after a close"

before="$(file_digest "$d/NOTES.local.md")"
assert_fail "out of range exits non-zero" lt "$d" done 1 9
assert_eq "$(file_digest "$d/NOTES.local.md")" "$before" "out of range leaves the file byte-identical"
assert_fail "zero is out of range" lt "$d" done 0
assert_fail "non-number refused" lt "$d" done 1x
assert_fail "no numbers refused" lt "$d" done
assert_fail "absurdly large number refused" lt "$d" done 99999999999999999999
assert_eq "$(file_digest "$d/NOTES.local.md")" "$before" "refused numbers leave the file byte-identical"

out="$(lt "$d" drop 1 2)"
assert_contains "$out" "later: dropped -> one" "drop prints the first note"
assert_contains "$out" "later: dropped -> three" "drop prints the second note"
assert_eq "$(grep -c -e 'one' -e 'three' "$d/NOTES.local.md")" "0" "drop removes the lines"
assert_eq "$(grep -c '^- \[x\]' "$d/NOTES.local.md")" "2" "closed notes survive a drop"
assert_eq "$(lt "$d" list)" "later: no parked notes" "queue is empty after closing everything"
assert_eq "$(find "$d" -maxdepth 1 -name 'NOTES.local.md.*' | count_lines)" "0" "no temp file left behind"

if [ "$PLATFORM" = gitbash ]; then
    skip "rewrite keeps the file mode: Git Bash's chmod cannot set mode 640"
else
    chmod 640 "$d/NOTES.local.md"; lt "$d" add perm check >/dev/null; lt "$d" done 1 >/dev/null
    assert_eq "$(file_mode "$d/NOTES.local.md")" "rw-r-----" "rewrite keeps the file mode"
fi

# Characters that shells, printf and awk like to interpret.
sp="$(mk_repo)"
weird='50% of C:\new\table & *.php "quoted" $HOME `tick`'
lt "$sp" add "$weird" >/dev/null
assert_contains "$(lt "$sp" list)" " 1. $weird (today)" "special characters survive add and list"
assert_eq "$(lt "$sp" done 1)" "later: done -> $weird" "special characters survive done"

# A queue that is a symlink (for example into a synced folder) stays one.
if [ "$PLATFORM" = gitbash ]; then
    skip "a symlinked queue stays a symlink through a rewrite: $NO_LINKS"
else
    lk="$(mk_repo)"; store="$(mktemp -d)"; TMPDIRS+=("$store")
    printf '%s\n' '- [ ] linked one' '- [ ] linked two' > "$store/notes.md"
    ln -s "$store/notes.md" "$lk/NOTES.local.md"
    lt "$lk" done 1 >/dev/null
    assert_ok "symlinked queue stays a symlink" test -L "$lk/NOTES.local.md"
    assert_eq "$(sed -n 1p "$store/notes.md")" "- [x] linked one" "rewrite lands in the link target"
fi

nq="$(mk_repo)"
assert_fail "done with no queue file fails" lt "$nq" done 1
assert_nofile "$nq/NOTES.local.md" "done does not create a queue"

# Parallel writers: a rewrite racing appends must not lose a note.
r="$(mk_repo)"
for i in 1 2 3 4 5 6 7 8; do lt "$r" add "seed $i" >/dev/null; done
for i in 1 2 3 4 5 6 7 8; do lt "$r" add "racer $i" >/dev/null & lt "$r" done 1 >/dev/null & done
wait
assert_eq "$(grep -c 'racer' "$r/NOTES.local.md")" "8" "no append lost during rewrites"
assert_eq "$(grep -c '^- \[x\]' "$r/NOTES.local.md")" "8" "every done landed"

# --- rows, --if -------------------------------------------------------

T=$'\t'
rw="$(mk_repo)"
printf '%s\n' '# Parked notes (`/later`)' '' \
    '- [ ] Check the S3 retry path (2026-10-01 10:00)' \
    '- [x] closed one' \
    '- [ ] undated one' > "$rw/NOTES.local.md"
printf -- '- [ ] split\there\n' >> "$rw/NOTES.local.md"
out="$(lt "$rw" rows)"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "queue${T}$(basename "$rw")" "rows starts with the queue line"
assert_eq "$(printf '%s\n' "$out" | sed -n 2p)" "note${T}1${T}3d${T}Check the S3 retry path" "rows: position, age, text without the stamp"
assert_eq "$(printf '%s\n' "$out" | sed -n 3p)" "note${T}2${T}undated${T}undated one" "rows leaves closed notes out"
assert_eq "$(printf '%s\n' "$out" | sed -n 4p)" "note${T}3${T}undated${T}split${T}here" "rows keeps a tab inside a note's text"
assert_eq "$(printf '%s\n' "$out" | count_lines)" "4" "rows prints nothing else"
assert_eq "$(lt "$e" rows)" "queue${T}$(basename "$e")" "rows without a queue file prints the queue line alone"
gone="$(mktemp -d)"
out="$( cd "$gone" && rmdir "$gone" && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" PATH="$ENGINE_PATH" bash "$ENGINE" rows 2>&1; echo "exit $?" )"
assert_contains "$out" "later: cannot resolve the queue here" "rows names an unresolvable queue"
assert_contains "$out" "exit 1" "rows exits 1 when the queue cannot be resolved"

gq="$(mk_repo)"
printf '%s\n' '- [ ] alpha' '- [ ] beta' '- [ ] gamma' > "$gq/NOTES.local.md"
assert_eq "$(lt "$gq" done --if beta 2)" "later: done -> beta" "done --if closes a note whose text matches"
before="$(file_digest "$gq/NOTES.local.md")"
out="$(lt "$gq" drop --if beta 2 2>&1; echo "exit $?")"
assert_eq "$out" "later: note 2 changed since it was listed; nothing changed"$'\n'"exit 1" "drop --if refuses a note whose text differs"
assert_eq "$(file_digest "$gq/NOTES.local.md")" "$before" "a refused --if leaves the file byte-identical"
assert_eq "$(lt "$gq" drop --if gamma 2)" "later: dropped -> gamma" "drop --if drops a note whose text matches"
assert_eq "$(lt "$gq" done --if alpha 5 2>&1)" "later: note 5 changed since it was listed; nothing changed" "--if past the end reports a change"
assert_eq "$(lt "$gq" done --if alpha 1 2 2>&1)" "later: --if takes exactly one note number" "--if with two numbers is refused"
assert_fail "--if with no number is refused" lt "$gq" done --if alpha
assert_contains "$(lt "$gq" list)" "$(basename "$gq"): 1 parked" "refused --if forms change nothing"
assert_eq "$(lt "$rw" done --if 'Check the S3 retry path' 1)" "later: done -> Check the S3 retry path" "--if compares the text without its stamp"
assert_eq "$(lt "$rw" drop --if "split${T}here" 2)" "later: dropped -> split${T}here" "--if matches a text holding a tab"
assert_contains "$(PATH="$ENGINE_PATH" bash "$ENGINE" 2>&1)" "done [--if <text>] <n>..." "usage names the --if form"

# --- all --------------------------------------------------------------

roots="$(mktemp -d)"; TMPDIRS+=("$roots")
mkdir -p "$roots/a" "$roots/b" "$roots/c" "$roots/a/node_modules/pkg" "$roots/a/.worktrees/w" "$roots/a/vendor/x"
printf '%s\n' '- [ ] a1 (2026-09-13 14:05)' '- [ ] a2 (2026-10-04 10:00)' > "$roots/a/NOTES.local.md"
printf '%s\n' '- [ ] b1' '- [ ] b2' '- [ ] b3 (2026-10-01 10:00)' > "$roots/b/NOTES.local.md"
printf '%s\n' '- [x] all closed' > "$roots/c/NOTES.local.md"
printf '%s\n' '- [ ] hidden' | tee "$roots/a/node_modules/pkg/NOTES.local.md" "$roots/a/.worktrees/w/NOTES.local.md" > "$roots/a/vendor/x/NOTES.local.md"
all() { ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" TZ=UTC LATER_NOW="$NOW" LATER_ROOTS="$1" PATH="$ENGINE_PATH" bash "$ENGINE" all ); }
out="$(all "$roots")"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "  3 open, oldest undated   $roots/b" "largest queue first, undated is oldest"
assert_eq "$(printf '%s\n' "$out" | sed -n 2p)" "  2 open, oldest 21d       $roots/a" "oldest age of a dated queue"
assert_eq "$(printf '%s\n' "$out" | sed -n 3p)" "  5 open in 2 queues" "total line; closed-only and pruned queues omitted"
assert_eq "$(printf '%s\n' "$out" | count_lines)" "3" "nothing else printed"
assert_contains "$(all "$roots/a:$roots/b:/nonexistent")" "  5 open in 2 queues" "several roots, missing root ignored"
assert_eq "$(all "$roots/c")" "later: no parked notes" "no open notes anywhere"
mkdir -p "$T_HOME/proj"; printf '%s\n' '- [ ] h1' > "$T_HOME/proj/NOTES.local.md"
out="$( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" TZ=UTC LATER_NOW="$NOW" PATH="$ENGINE_PATH" bash "$ENGINE" all )"
assert_contains "$out" "~/proj" "default root is HOME, shown with a tilde"

# A queue that is a symlink to a regular file is counted, once. The link
# target lives outside the scanned root, so it cannot count as a second queue.
if [ "$PLATFORM" = gitbash ]; then
    skip "all counts a symlinked queue once: $NO_LINKS"
else
    lroot="$(mktemp -d)"; ltarget="$(mktemp -d)"; TMPDIRS+=("$lroot" "$ltarget")
    mkdir -p "$lroot/p"; printf '%s\n' '- [ ] via link' > "$ltarget/notes.md"
    ln -s "$ltarget/notes.md" "$lroot/p/NOTES.local.md"
    assert_eq "$(all "$lroot")" "  1 open, oldest undated   $lroot/p"$'\n'"  1 open in 1 queues" "all counts a symlinked queue"
fi

# --- session-start ----------------------------------------------------

hook_in() { "$JQ" -n --arg cwd "$1" --arg src "${2:-startup}" '{cwd: $cwd, source: $src, hook_event_name: "SessionStart"}'; }
ss() { # stdin: hook input; prints the user-visible message
    ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" PATH="$ENGINE_PATH" bash "$ENGINE" session-start ) | "$JQ" -r '.systemMessage // empty'
}

s="$(mk_repo)"; mkdir -p "$s/deep/er"
printf '%s\n' '- [ ] old undated' '- [ ] old dated (2026-09-01 08:00)' '- [ ] n3' '- [ ] n4' '- [ ] n5' '- [ ] n6' > "$s/NOTES.local.md"

# First display ever: stamped notes are new, the list is due.
out="$(hook_in "$s/deep/er" | ss)"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "later: 6 parked in $(basename "$s"), 1 new: old dated" "count line, from a subdirectory"
assert_eq "$(printf '%s\n' "$out" | sed -n 2p)" "Oldest notes:" "list shown when never shown"
assert_eq "$(printf '%s\n' "$out" | sed -n 3p)" " 1. old undated (undated)" "undated first, in file order"
assert_eq "$(printf '%s\n' "$out" | sed -n 7p)" " 6. n6 (undated)" "list capped at five, dated note sorts after undated"
assert_eq "$(printf '%s\n' "$out" | count_lines)" "7" "five list rows"

# Next display two minutes later: nothing new, list not due.
NOW=$((NOW + 120))
assert_eq "$(hook_in "$s" | ss)" "later: 6 parked in $(basename "$s")" "quiet queue shows the count only"

# A note parked now is announced once.
lt "$s" add fresh one >/dev/null
NOW=$((NOW + 3600))
assert_eq "$(hook_in "$s" | ss)" "later: 7 parked in $(basename "$s"), 1 new: fresh one" "new note announced"
NOW=$((NOW + 3600))
assert_eq "$(hook_in "$s" | ss)" "later: 7 parked in $(basename "$s")" "and only once"

# Parked in the same minute as a display, after it: still announced next time.
NOW=$((NOW + 20)); hook_in "$s" | ss >/dev/null
NOW=$((NOW + 20)); lt "$s" add same minute >/dev/null
NOW=$((NOW + 600))
assert_contains "$(hook_in "$s" | ss)" "1 new: same minute" "same-minute note is not skipped"

# More than three new notes.
for i in 1 2 3 4 5; do lt "$s" add "burst $i" >/dev/null; done
NOW=$((NOW + 600))
assert_contains "$(hook_in "$s" | ss)" "5 new: burst 1; burst 2; burst 3, +2 more" "first three named, rest counted"

# The list returns after seven days, and LATER_DIGEST_COUNT caps it.
NOW=$((NOW + 7 * DAY))
out="$(hook_in "$s" | ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" LATER_DIGEST_COUNT=2 PATH="$ENGINE_PATH" bash "$ENGINE" session-start ) | "$JQ" -r .systemMessage)"
assert_eq "$(printf '%s\n' "$out" | count_lines)" "4" "weekly list due again, capped by LATER_DIGEST_COUNT"

# Long notes are clipped in the display, never in the file or in `list`.
lg="$(mk_repo)"
long="$(printf 'x%.0s' $(seq 1 300))"
lt "$lg" add "$long" >/dev/null
NOW=$((NOW + 600))
out="$(hook_in "$lg" | ss)"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p | count_bytes)" "$(( $(printf 'later: 1 parked in %s, 1 new: ' "$(basename "$lg")" | count_bytes) + 100 + 1 ))" "new note clipped to 100 characters"
assert_contains "$(printf '%s\n' "$out" | sed -n 1p)" "xxx..." "clip is marked"
assert_eq "$(printf '%s\n' "$out" | sed -n 3p | count_bytes)" "$(( 4 + 100 + 8 + 1 ))" "list row clipped to 100 characters"
assert_contains "$(lt "$lg" list)" "$long" "list prints the note in full"

# Silent paths: every one exits 0 and prints nothing.
assert_eq "$(hook_in "$s" resume | ss)" "" "resume is ignored"
assert_eq "$(hook_in "$s" compact | ss)" "" "compact is ignored"
assert_eq "$("$JQ" -n --arg cwd "$s" '{cwd: $cwd, source: "startup", agent_id: "a1"}' | ss)" "" "subagent is ignored"
assert_eq "$(printf 'not json' | ss)" "" "malformed input is ignored"
assert_eq "$(printf '' | ss)" "" "empty input is ignored"
assert_eq "$(hook_in "$e" | ss)" "" "no queue file: nothing"
assert_eq "$(hook_in "$d" | ss)" "" "no open notes: nothing"
assert_eq "$(hook_in /nonexistent/dir | ss)" "" "missing directory: nothing"
assert_eq "$(hook_in "$s" | ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" CLAUDE_CODE_ENTRYPOINT=sdk-cli PATH="$ENGINE_PATH" bash "$ENGINE" session-start ))" "" "headless session is ignored"
assert_ok "malformed input exits 0" bash -c "printf 'not json' | HOME='$T_HOME' XDG_CACHE_HOME='$T_CACHE' CLAUDE_CODE_ENTRYPOINT=cli PATH='$ENGINE_PATH' bash '$ENGINE' session-start"

# An unreadable queue: nothing on stdout or stderr, and exit 0.
if [ "$PLATFORM" = gitbash ]; then
    skip "an unreadable queue prints nothing: Git Bash's chmod 000 leaves the file readable"
else
    ur="$(mktemp -d)"; TMPDIRS+=("$ur"); printf '%s\n' '- [ ] unreadable' > "$ur/NOTES.local.md"; chmod 000 "$ur/NOTES.local.md"
    out="$(hook_in "$ur" | ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" PATH="$ENGINE_PATH" bash "$ENGINE" session-start 2>&1; echo "exit $?" ))"
    assert_eq "$out" "exit 0" "unreadable queue prints nothing on either stream and exits 0"
fi

# Unwritable state: still displays.
if [ "$PLATFORM" = gitbash ]; then
    skip "display works when state cannot be written: Git Bash's chmod 500 leaves the folder writable"
else
    ro="$(mktemp -d)"; TMPDIRS+=("$ro"); chmod 500 "$ro"
    out="$(hook_in "$s" | ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$ro" CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" PATH="$ENGINE_PATH" bash "$ENGINE" session-start ) | "$JQ" -r '.systemMessage // empty')"
    assert_contains "$out" "later: 13 parked" "display works when state cannot be written"
    chmod 700 "$ro"
fi

# Corrupt state file is treated as never shown. The engine keys its state by
# the queue's physical path, and on macOS mktemp's folder sits behind a link.
key="$(sha1_of "$(cd "$s" && pwd -P)/NOTES.local.md")"
printf 'garbage\n\n' > "$T_CACHE/later/v2/$key"
assert_contains "$(hook_in "$s" | ss)" "Oldest notes:" "corrupt state means never shown"

# Leading-zero state reads as decimal: "08" is not valid octal and must not
# abort the hook, and a digest written as 0<now> is recent, so no list.
# pipefail carries the engine's exit status out of ss.
printf '08\n0%s\n' "$NOW" > "$T_CACHE/later/v2/$key"
out="$(hook_in "$s" | ss; echo "exit $?")"
assert_eq "$(printf '%s\n' "$out" | sed 's/,.*//')" "later: 13 parked in $(basename "$s")"$'\n'"exit 0" "leading-zero state still displays and exits 0"

# --- terminal link ----------------------------------------------------
# Every case has its own HOME, with the data folder inside it.

if [ "$PLATFORM" = gitbash ]; then
    skip "terminal link section (the engine links the terminal command with ln -s): $NO_LINKS"
else
    ROOT="$(cd "$HERE/.." && pwd -P)"
    ADDED='later: added the terminal command ~/.local/bin/later; set laterbox.terminal to off in /config to remove it.'
    REMOVED='later: removed the terminal command ~/.local/bin/later.'
    REFUSED='later: ~/.local/bin/later exists and was not made by this plugin, so the terminal command was not added; remove it and start a new session to get it.'
    NOPATH="later: ~/.local/bin is not on PATH in this session, so a terminal may not find later; add it to PATH in your shell's startup file."

    mk_home() { local h; h="$(mk_tmpdir)"; mkdir -p "$h/data"; printf '%s' "$h"; }

    # One startup of a terminal session in <home>, from the queue-less repo $e,
    # with ~/.local/bin on PATH and the option unset; VAR=value words override.
    sl() { # home [VAR=value...]
        local h="$1"; shift
        hook_in "$e" | ( cd / && env HOME="$h" XDG_CACHE_HOME="$T_CACHE" CLAUDE_PLUGIN_DATA="$h/data" \
            CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" PATH="$h/.local/bin:$ENGINE_PATH" "$@" \
            bash "$ENGINE" session-start ) | "$JQ" -r '.systemMessage // empty'
    }

    # Nothing under <home> but its empty data folder.
    untouched() { [ -z "$(find "$1" -mindepth 1 ! -path "$1/data")" ] && [ -z "$(ls -A "$1/data")" ]; }

    h="$(mk_home)"
    assert_eq "$(sl "$h")" "$ADDED" "an empty ~/.local/bin/later: both links made, announced"
    assert_eq "$(readlink "$h/.local/bin/later")" "$h/data/bin/later" "the user link names the data link"
    assert_eq "$(readlink "$h/data/bin/later")" "$ROOT/scripts/later" "the data link names the plugin's front-end"
    ino="$(file_inode "$h/.local/bin/later")"
    assert_eq "$(sl "$h")" "" "an own link: the next start is silent"
    assert_eq "$(file_inode "$h/.local/bin/later")" "$ino" "an own link is left as it is"
    assert_eq "$(tr '\n' ' ' < "$h/data/terminal-state")" "own ok " "the state file holds the conditions"

    h="$(mk_home)"; ln -s "$h/data" "$h/alias"; mkdir -p "$h/.local/bin"; ln -s "$h/alias/bin/later" "$h/.local/bin/later"
    assert_eq "$(sl "$h")" "" "a link reaching the data folder through another path is own"
    h="$(mk_home)"; mkdir -p "$h/.local/bin"; ln -s ../../data/bin/later "$h/.local/bin/later"
    assert_eq "$(sl "$h")" "" "a relative link to the data folder is own"

    h="$(mk_home)"; mkdir -p "$h/.local/bin"; printf 'mine\n' > "$h/.local/bin/later"
    assert_eq "$(sl "$h")" "$REFUSED" "a regular file: refused, announced"
    assert_eq "$(cat "$h/.local/bin/later")" "mine" "a regular file is left alone"
    assert_eq "$(sl "$h")" "" "a refusal is announced once"

    h="$(mk_home)"; mkdir -p "$h/.local/bin"; ln -s /usr/bin/true "$h/.local/bin/later"
    assert_eq "$(sl "$h")" "$REFUSED" "a foreign link: refused, announced"
    assert_eq "$(readlink "$h/.local/bin/later")" "/usr/bin/true" "a foreign link is left alone"

    h="$(mk_home)"; mkdir -p "$h/.local/bin"; ln -s "$h/gone/later" "$h/.local/bin/later"
    assert_eq "$(sl "$h")" "$REFUSED" "a dangling foreign link: refused, announced"
    assert_eq "$(readlink "$h/.local/bin/later")" "$h/gone/later" "a dangling foreign link is left alone"

    h="$(mk_home)"; mkdir -p "$h/data/bin"; ln -s /old/root/scripts/later "$h/data/bin/later"
    sl "$h" >/dev/null
    assert_eq "$(readlink "$h/data/bin/later")" "$ROOT/scripts/later" "a data link to another root is repointed"
    assert_eq "$(find "$h/data/bin" -name '.later.tmp.*' | count_lines)" "0" "no temporary link is left"

    h="$(mk_home)"; sl "$h" >/dev/null
    assert_eq "$(sl "$h" CLAUDE_PLUGIN_OPTION_TERMINAL=off)" "$REMOVED" "off removes an own link, announced"
    assert_fail "off: the own link is gone" test -L "$h/.local/bin/later"
    assert_eq "$(sl "$h" CLAUDE_PLUGIN_OPTION_TERMINAL=off)" "" "off: the next start is silent"
    assert_eq "$(sl "$h" CLAUDE_PLUGIN_OPTION_TERMINAL=link)" "$ADDED" "back to link: added again"

    h="$(mk_home)"; mkdir -p "$h/.local/bin"; ln -s /usr/bin/true "$h/.local/bin/later"
    assert_eq "$(sl "$h" CLAUDE_PLUGIN_OPTION_TERMINAL=off)" "" "off leaves a foreign link, silently"
    assert_eq "$(readlink "$h/.local/bin/later")" "/usr/bin/true" "off: the foreign link is untouched"

    h="$(mk_home)"
    assert_eq "$(sl "$h" CLAUDE_PLUGIN_OPTION_TERMINAL=)" "$ADDED" "an empty option means link"

    h="$(mk_home)"
    assert_eq "$(sl "$h" PATH="$ENGINE_PATH")" "$ADDED"$'\n'"$NOPATH" "a PATH without ~/.local/bin is announced with the link"
    assert_eq "$(sl "$h" PATH="$ENGINE_PATH")" "" "the PATH notice shows once"
    h="$(mk_home)"
    assert_eq "$(sl "$h" PATH="$h/.local/bin/:$ENGINE_PATH")" "$ADDED" "a PATH entry with a trailing slash counts"

    h="$(mk_home)"
    out="$(hook_in "$s" | ( cd / && env HOME="$h" XDG_CACHE_HOME="$T_CACHE" CLAUDE_PLUGIN_DATA="$h/data" \
        CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" PATH="$h/.local/bin:$ENGINE_PATH" bash "$ENGINE" session-start ))"
    assert_eq "$(printf '%s' "$out" | "$JQ" -s length)" "1" "the count line and a notice arrive in one JSON object"
    assert_contains "$(printf '%s' "$out" | "$JQ" -r .systemMessage | sed -n 1p)" "parked in $(basename "$s")" "the count line comes first"
    assert_eq "$(printf '%s' "$out" | "$JQ" -r .systemMessage | tail -n1)" "$ADDED" "the notice follows it"

    h="$(mk_home)"
    "$JQ" -n --arg cwd "$e" '{cwd: $cwd, source: "resume"}' | ( cd / && HOME="$h" XDG_CACHE_HOME="$T_CACHE" CLAUDE_PLUGIN_DATA="$h/data" CLAUDE_CODE_ENTRYPOINT=cli PATH="$ENGINE_PATH" bash "$ENGINE" session-start ) >/dev/null
    assert_ok "a resumed session links nothing" untouched "$h"
    h="$(mk_home)"
    "$JQ" -n --arg cwd "$e" '{cwd: $cwd, source: "startup", agent_id: "a1"}' | ( cd / && HOME="$h" XDG_CACHE_HOME="$T_CACHE" CLAUDE_PLUGIN_DATA="$h/data" CLAUDE_CODE_ENTRYPOINT=cli PATH="$ENGINE_PATH" bash "$ENGINE" session-start ) >/dev/null
    assert_ok "a subagent links nothing" untouched "$h"
    h="$(mk_home)"
    hook_in "$e" | ( cd / && HOME="$h" XDG_CACHE_HOME="$T_CACHE" CLAUDE_PLUGIN_DATA="$h/data" CLAUDE_CODE_ENTRYPOINT=sdk-cli PATH="$ENGINE_PATH" bash "$ENGINE" session-start ) >/dev/null
    assert_ok "a headless session links nothing" untouched "$h"
    h="$(mk_home)"
    hook_in "$e" | ( cd / && HOME="$h" XDG_CACHE_HOME="$T_CACHE" CLAUDE_CODE_ENTRYPOINT=cli PATH="$ENGINE_PATH" bash "$ENGINE" session-start ) >/dev/null
    assert_ok "no data folder in the environment links nothing" untouched "$h"

    h="$(mk_home)"
    for i in 1 2 3 4; do sl "$h" > "$h/out.$i" & done
    wait
    assert_eq "$(cat "$h"/out.* | grep -c 'added the terminal command')" "1" "four sessions starting at once announce the link once"
    assert_eq "$(readlink "$h/.local/bin/later")" "$h/data/bin/later" "and leave one own link"
    assert_eq "$(find "$h/data/bin" -name '.later.tmp.*' | count_lines)" "0" "and no temporary link"
fi

# --- terminal front-end -----------------------------------------------
# scripts/later as a terminal reaches it: ~/.local/bin/later, a link to the
# data folder's bin/later, a link to the plugin's file.

if [ "$PLATFORM" = gitbash ]; then
    skip "terminal front-end section (the cases reach the front-end through two links): $NO_LINKS"
else
    FRONT="$(cd "$HERE/.." && pwd -P)/scripts/later"
    fe="$(mktemp -d)"; TMPDIRS+=("$fe")
    mkdir -p "$fe/data/bin" "$fe/home/.local/bin"
    ln -s "$FRONT" "$fe/data/bin/later"
    ln -s "$fe/data/bin/later" "$fe/home/.local/bin/later"
    w="$(mk_repo)"
    wr() { ( cd "$w" && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" TZ=UTC LATER_NOW="$NOW" PATH="$ENGINE_PATH" "$fe/home/.local/bin/later" "$@" ); }
    assert_eq "$( cd "$w" && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" PATH="$ENGINE_PATH" "$FRONT" )" "later: no parked notes" "by its own path, bare later lists"
    assert_eq "$(wr)" "later: no parked notes" "bare later lists"
    wr first note >/dev/null
    assert_eq "$(wr done with the migration, check logs)" "later: parked -> done with the migration, check logs" "done plus words is a note"
    assert_eq "$(wr all hands meeting notes)" "later: parked -> all hands meeting notes" "all plus words is a note"
    assert_eq "$(wr -- all)" "later: parked -> all" "double dash parks a subcommand word"
    assert_eq "$(wr drop)" "later: parked -> drop" "drop with no numbers is a note"
    assert_eq "$(wr done 1)" "later: done -> first note" "done with a number closes"
    assert_eq "$(wr drop 1 2)" "$(printf 'later: dropped -> done with the migration, check logs\nlater: dropped -> all hands meeting notes')" "drop with numbers deletes"
    assert_contains "$(LATER_ROOTS="$w" wr all)" "open in 1 queues" "all alone scans"
    assert_contains "$(wr --help)" "later done <n>" "help lists the subcommands"
    cp "$FRONT" "$fe/later"
    assert_fail "a front-end without its engine exits non-zero" env HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" PATH="$ENGINE_PATH" "$fe/later"
    assert_contains "$(HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" PATH="$ENGINE_PATH" "$fe/later" 2>&1)" "later: engine not found or not executable at $(cd "$fe" && pwd -P)/later.sh" "a front-end without its engine names the path it tried"
fi

finish
