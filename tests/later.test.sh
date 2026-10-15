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
# A run from a hook's environment must not link into a real data folder, take
# the queue name from a real setting or touch the real stored copy of it.
unset CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_OPTION_TERMINAL CLAUDE_PLUGIN_OPTION_FILE XDG_STATE_HOME
# The lock cases choose the lock themselves.
unset LATER_NO_FLOCK
ENGINE="$HERE/../scripts/later.sh"
# The PATH of every engine run, front-end runs included. CI narrows it to the
# system folders, so the engine cannot lean on a tool the user installed.
ENGINE_PATH="${LATER_TEST_ENGINE_PATH:-$PATH}"

# The engine needs no jq (spec R5.1). Every engine run finds this one first:
# it records the call and fails, and the last case asserts it was never called.
JQ_TRAP="$(mk_tmpdir)"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> "${0%/*}/calls"' 'exit 127' > "$JQ_TRAP/jq"
chmod +x "$JQ_TRAP/jq"
ENGINE_PATH="$JQ_TRAP:$ENGINE_PATH"

# Why Git Bash skips every case that makes a symbolic link.
NO_LINKS="Git Bash's ln -s makes a copy, not a symbolic link"

# Every engine call runs with a throwaway HOME, cache and state folder, the
# zone ZONE (UTC unless a case sets another for its own runs), and a fixed
# clock, NOW: 2026-10-04 14:05:00 UTC at first, moved forward by later cases.
T_HOME="$(mktemp -d)";  TMPDIRS+=("$T_HOME")
T_CACHE="$(mktemp -d)"; TMPDIRS+=("$T_CACHE")
T_STATE="$(mktemp -d)"; TMPDIRS+=("$T_STATE")
NOW0=1791122700
NOW=$NOW0
DAY=86400
ZONE=UTC

# The default queue file name.
Q=LATER.local.md

# strace, for the process budget case; empty where it is missing.
STRACE="$(type -P strace)" || STRACE=''

# The engine's bash, for every helper below. With TRACE_LOG set, strace
# records in that file the processes the engine starts; nothing else is traced.
run_engine() { # args...
    if [ -n "${TRACE_LOG:-}" ]; then
        "$STRACE" -f -e trace=clone,clone3,fork,vfork -o "$TRACE_LOG" bash "$ENGINE" "$@"
    else
        bash "$ENGINE" "$@"
    fi
}

lt() { # dir args...
    local dir="$1"; shift
    ( cd "$dir" && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" TZ="$ZONE" LATER_NOW="$NOW" PATH="$ENGINE_PATH" run_engine "$@" )
}

# The engine keys its state and its lock by the queue's physical path, and on
# macOS mktemp's folder sits behind a link.
state_key_of() { sha1_of "$(cd "$1" && pwd -P)/$Q"; } # dir
# The folder that locks the queue in <dir> where flock is missing.
lock_of() { printf '%s/later/v2/%s.lock.d\n' "$T_CACHE" "$(state_key_of "$1")"; } # dir

# --- resolution, add, list -------------------------------------------

repo="$(mk_repo)"
mkdir -p "$repo/app/Http"
out="$(lt "$repo/app/Http" add check the S3 retry path)"
assert_eq "$out" "later: parked -> check the S3 retry path" "add confirms"
assert_file "$repo/$Q" "subdirectory parks at the git toplevel"
assert_nofile "$repo/NOTES.local.md" "no queue under the 0.1.0 name"
assert_nofile "$repo/app/Http/$Q" "no queue in the subdirectory"
assert_eq "$(sed -n 3p "$repo/$Q")" "- [ ] check the S3 retry path (2026-10-04 14:05)" "note is stamped"
assert_eq "$(sed -n 1p "$repo/$Q")" '# Parked notes (`/later`)' "new queue gets the heading"

git -C "$repo" worktree add -q -b feat/x "$repo/.worktrees/feat-x" >/dev/null 2>&1
mkdir -p "$repo/.worktrees/feat-x/sub"
lt "$repo/.worktrees/feat-x/sub" add from the worktree >/dev/null
assert_nofile "$repo/.worktrees/feat-x/$Q" "worktree does not get its own queue"
assert_contains "$(cat "$repo/$Q")" "from the worktree" "worktree parks in the main checkout"

plain="$(mktemp -d)"; TMPDIRS+=("$plain")
lt "$plain" add outside any repo >/dev/null
assert_file "$plain/$Q" "no repository: queue in the directory itself"

# HOME is itself a repository (dotfiles): a directory under it with no
# repository of its own must not fall through to the HOME queue.
git -C "$T_HOME" init -q
mkdir -p "$T_HOME/Downloads/foo"
lt "$T_HOME/Downloads/foo" add under home >/dev/null
assert_file "$T_HOME/Downloads/foo/$Q" "home-as-repo: queue stays in the directory"
assert_nofile "$T_HOME/$Q" "home-as-repo: HOME queue untouched"
lt "$T_HOME" add in home itself >/dev/null
assert_file "$T_HOME/$Q" "HOME itself uses the HOME queue"

q="$(mk_repo)"
out="$(lt "$q" add "$(printf 'line one\nline   two\t end ')")"
assert_eq "$(tail -n1 "$q/$Q")" "- [ ] line one line two end (2026-10-04 14:05)" "whitespace and newlines collapse"
out="$(lt "$q" add '   ')"
assert_eq "$out" "later: nothing to park (empty note)" "empty note refused"
assert_eq "$(grep -c '^- \[ \]' "$q/$Q")" "1" "empty note not written"

# Legacy and hand-edited lines, a closed line, and a file without a final newline.
l="$(mk_repo)"
printf '%s\n' '# Parked notes (`/later`)' '' \
    '- [ ] Move upload disk config to env' \
    '- [x] already done' \
    '  -  [ ]   hand edited spacing' \
    '- [ ] Recheck group lecturer policy (2026-09-22 09:00)' > "$l/$Q"
printf '%s' '- [ ] no final newline' >> "$l/$Q"
before="$(file_digest "$l/$Q")"
out="$(lt "$l" list)"
assert_eq "$(file_digest "$l/$Q")" "$before" "list never rewrites the file"
assert_contains "$out" "$(basename "$l"): 4 parked" "list header counts open notes only"
assert_contains "$out" " 1. Move upload disk config to env (undated)" "legacy note is undated"
assert_contains "$out" " 2. hand edited spacing (undated)" "hand-edited spacing parses"
assert_contains "$out" " 3. Recheck group lecturer policy (12d)" "age in days"
assert_contains "$out" " 4. no final newline (undated)" "last line without newline is read"
lt "$l" add appended after a missing newline >/dev/null
assert_eq "$(grep -c 'no final newline$' "$l/$Q")" "1" "append does not glue onto the last line"
assert_contains "$(lt "$l" list)" " 5. appended after a missing newline (today)" "fresh note is today"

e="$(mk_repo)"
assert_eq "$(lt "$e" list)" "later: no parked notes" "list with no queue file"

# A stamp-shaped tail that is not a real date stays part of the text.
b="$(mk_repo)"
printf '%s\n' '- [ ] call back (2026-13-45 99:99)' > "$b/$Q"
assert_contains "$(lt "$b" list)" " 1. call back (2026-13-45 99:99) (undated)" "invalid stamp is text"

# --- done, drop -------------------------------------------------------

d="$(mk_repo)"
printf '%s\n' '# Parked notes (`/later`)' '' '- [ ] one' '- [x] closed' '- [ ] two (2026-10-01 10:00)' '- [ ] three' > "$d/$Q"
out="$(lt "$d" done 2)"
assert_eq "$out" "later: done -> two" "done prints the closed note"
assert_eq "$(sed -n 5p "$d/$Q")" "- [x] two (2026-10-01 10:00)" "done ticks the box and keeps the line"
assert_contains "$(lt "$d" list)" " 2. three (undated)" "positions renumber after a close"

before="$(file_digest "$d/$Q")"
assert_fail "out of range exits non-zero" lt "$d" done 1 9
assert_eq "$(file_digest "$d/$Q")" "$before" "out of range leaves the file byte-identical"
assert_fail "zero is out of range" lt "$d" done 0
assert_fail "non-number refused" lt "$d" done 1x
assert_fail "no numbers refused" lt "$d" done
assert_fail "absurdly large number refused" lt "$d" done 99999999999999999999
assert_eq "$(file_digest "$d/$Q")" "$before" "refused numbers leave the file byte-identical"

out="$(lt "$d" drop 1 2)"
assert_contains "$out" "later: dropped -> one" "drop prints the first note"
assert_contains "$out" "later: dropped -> three" "drop prints the second note"
assert_eq "$(grep -c -e 'one' -e 'three' "$d/$Q")" "0" "drop removes the lines"
assert_eq "$(grep -c '^- \[x\]' "$d/$Q")" "2" "closed notes survive a drop"
assert_eq "$(lt "$d" list)" "later: no parked notes" "queue is empty after closing everything"
assert_eq "$(find "$d" -maxdepth 1 -name "$Q.*" | count_lines)" "0" "no temp file left behind"

if [ "$PLATFORM" = gitbash ]; then
    skip "rewrite keeps the file mode: Git Bash's chmod cannot set mode 640"
else
    chmod 640 "$d/$Q"; lt "$d" add perm check >/dev/null; lt "$d" done 1 >/dev/null
    assert_eq "$(file_mode "$d/$Q")" "rw-r-----" "rewrite keeps the file mode"
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
    ln -s "$store/notes.md" "$lk/$Q"
    lt "$lk" done 1 >/dev/null
    assert_ok "symlinked queue stays a symlink" test -L "$lk/$Q"
    assert_eq "$(sed -n 1p "$store/notes.md")" "- [x] linked one" "rewrite lands in the link target"
fi

nq="$(mk_repo)"
assert_fail "done with no queue file fails" lt "$nq" done 1
assert_nofile "$nq/$Q" "done does not create a queue"

# Parallel writers: a rewrite racing appends must not lose a note.
r="$(mk_repo)"
for i in 1 2 3 4 5 6 7 8; do lt "$r" add "seed $i" >/dev/null; done
for i in 1 2 3 4 5 6 7 8; do lt "$r" add "racer $i" >/dev/null & lt "$r" done 1 >/dev/null & done
wait
assert_eq "$(grep -c 'racer' "$r/$Q")" "8" "no append lost during rewrites"
assert_eq "$(grep -c '^- \[x\]' "$r/$Q")" "8" "every done landed"

# The same race on the lock folder of macOS and Git Bash (spec R5.2):
# LATER_NO_FLOCK=1 makes the engine take it on Linux too.
r="$(mk_repo)"
for i in 1 2 3 4 5 6 7 8; do lt "$r" add "seed $i" >/dev/null; done
for i in 1 2 3 4 5 6 7 8; do LATER_NO_FLOCK=1 lt "$r" add "racer $i" >/dev/null & LATER_NO_FLOCK=1 lt "$r" done 1 >/dev/null & done
wait
assert_eq "$(grep -c 'racer' "$r/$Q")" "8" "no flock: no append lost during rewrites"
assert_eq "$(grep -c '^- \[x\]' "$r/$Q")" "8" "no flock: every done landed"
assert_nofile "$(lock_of "$r")" "no flock: the last writer removes the lock folder"

# --- the lock folder ----------------------------------------------------
# The lock of macOS and Git Bash. A case reaches it with LATER_NO_FLOCK=1 or
# with an OSTYPE that is not Linux's, and removes the lock folders it made.

LOCKED='later: the queue is locked by another writer'
# "<status> <seconds>" on the first line, then the output of add. The
# caller's prefix assignments (LATER_NO_FLOCK, OSTYPE) reach the engine.
timed_add() { # dir note
    local t0=$SECONDS out status
    out="$(lt "$1" add "$2" 2>&1)"; status=$?
    printf '%s %s\n%s\n' "$status" "$((SECONDS - t0))" "$out"
}
between() { [ "$3" -ge "$1" ] && [ "$3" -le "$2" ]; } # low high n

# A live holder's folder, and a folder whose holder has not written its id
# yet: the writer waits, then refuses, and removes neither. A file in the
# folder's place is no other writer: after the wait, the write runs unlocked.
# Off Linux the folder is the lock also with flock on the PATH, because the
# platform chooses the lock, not the PATH: under OSTYPE=darwin23 a held
# folder refuses the writer. The four run at once, so the suite waits once.
held="$(mk_repo)"; lt "$held" add before the holder >/dev/null
mkdir -p "$(lock_of "$held")"; printf '%s\n' "$$" > "$(lock_of "$held")/pid"
young="$(mk_repo)"; lt "$young" add before the holder >/dev/null
mkdir -p "$(lock_of "$young")"
occupied="$(mk_repo)"; : > "$(lock_of "$occupied")"
mac="$(mk_repo)"; lt "$mac" add before the holder >/dev/null
mkdir -p "$(lock_of "$mac")"; printf '%s\n' "$$" > "$(lock_of "$mac")/pid"
held_before="$(file_digest "$held/$Q")"; young_before="$(file_digest "$young/$Q")"; mac_before="$(file_digest "$mac/$Q")"
res="$(mk_tmpdir)"
LATER_NO_FLOCK=1 timed_add "$held" refused > "$res/held" &
LATER_NO_FLOCK=1 timed_add "$young" refused > "$res/young" &
LATER_NO_FLOCK=1 timed_add "$occupied" "past a file" > "$res/occupied" &
OSTYPE=darwin23 timed_add "$mac" refused > "$res/mac" &
wait
read -r status secs < "$res/held"
assert_eq "$(sed 1d "$res/held")" "$LOCKED" "no flock: a live holder's lock refuses the writer"
assert_eq "$status" "1" "no flock: the refused writer exits 1"
# At least 3: the writer waited instead of refusing at once.
assert_ok "no flock: the refusal comes after a wait of at most 7 seconds (took $secs)" between 3 7 "$secs"
assert_eq "$(file_digest "$held/$Q")" "$held_before" "no flock: a refused writer leaves the queue byte-identical"
assert_eq "$(cat "$(lock_of "$held")/pid" 2>/dev/null)" "$$" "no flock: a refused writer leaves the holder's folder and id in place"
read -r status secs < "$res/young"
assert_eq "$(sed 1d "$res/young")$status" "${LOCKED}1" "no flock: a folder without an id yet is not broken, and refuses the writer"
assert_eq "$(file_digest "$young/$Q")" "$young_before" "no flock: a folder without an id leaves the queue byte-identical"
assert_ok "no flock: a refused writer leaves a folder without an id in place" test -d "$(lock_of "$young")"
assert_nofile "$(lock_of "$young")/pid" "no flock: a refused writer writes no id into a folder it does not hold"
read -r status secs < "$res/occupied"
assert_eq "$(sed 1d "$res/occupied")$status" "later: parked -> past a file0" "no flock: a file in the lock folder's place is no other writer"
assert_ok "no flock: the file in the folder's place is left alone" test -f "$(lock_of "$occupied")"
read -r status secs < "$res/mac"
assert_eq "$(sed 1d "$res/mac")$status" "${LOCKED}1" "off Linux: a held folder refuses the writer, also with flock on the PATH"
assert_eq "$(file_digest "$mac/$Q")" "$mac_before" "off Linux: the refused writer leaves the queue byte-identical"
assert_eq "$(cat "$(lock_of "$mac")/pid" 2>/dev/null)" "$$" "off Linux: the refused writer leaves the holder's folder and id in place"
rm -rf "$(lock_of "$held")" "$(lock_of "$young")" "$(lock_of "$occupied")" "$(lock_of "$mac")"

# The counterpart: on Linux with flock on the PATH, flock is the lock, and a
# held folder does not stop the writer.
if ( PATH="$ENGINE_PATH"; command -v flock >/dev/null 2>&1 ); then
    lx="$(mk_repo)"; mkdir -p "$(lock_of "$lx")"; printf '%s\n' "$$" > "$(lock_of "$lx")/pid"
    out="$(OSTYPE=linux-gnu timed_add "$lx" "past a folder")"
    read -r status secs <<< "$out"
    assert_eq "$(printf '%s\n' "$out" | sed 1d)$status" "later: parked -> past a folder0" "on Linux with flock: a held folder does not stop the writer"
    assert_eq "$(cat "$(lock_of "$lx")/pid" 2>/dev/null)" "$$" "on Linux with flock: the folder is left as it was"
    rm -rf "$(lock_of "$lx")"
else
    skip "on Linux with flock, a held lock folder does not stop add: no flock on the engine's PATH"
fi

# A folder whose id names no live process (a killed holder) is broken at once.
: & dead=$!; wait "$dead"
dl="$(mk_repo)"; mkdir -p "$(lock_of "$dl")"; printf '%s\n' "$dead" > "$(lock_of "$dl")/pid"
out="$(LATER_NO_FLOCK=1 timed_add "$dl" "after a killed writer")"
read -r status secs <<< "$out"
assert_eq "$(printf '%s\n' "$out" | sed 1d)$status" "later: parked -> after a killed writer0" "no flock: a dead holder's lock is broken"
assert_ok "no flock: a dead holder's lock is broken within 2 seconds (took $secs)" between 0 2 "$secs"
assert_nofile "$(lock_of "$dl")" "no flock: the writer that broke the lock removes its own folder"
rm -rf "$(lock_of "$dl")"

# A folder over 60 seconds old is broken, also without an id. TZ=UTC+0:10 is
# a zone ten minutes behind UTC, and touch reads the stamp as UTC.
ag="$(mk_repo)"; mkdir -p "$(lock_of "$ag")"
TZ=UTC0 touch -t "$(TZ=UTC+0:10 date +%Y%m%d%H%M.%S)" "$(lock_of "$ag")"
out="$(LATER_NO_FLOCK=1 timed_add "$ag" "past an old lock")"
read -r status secs <<< "$out"
assert_eq "$(printf '%s\n' "$out" | sed 1d)$status" "later: parked -> past an old lock0" "no flock: a lock folder ten minutes old is broken"
assert_ok "no flock: an old lock folder is broken within 2 seconds (took $secs)" between 0 2 "$secs"
assert_nofile "$(lock_of "$ag")" "no flock: the writer that broke an old lock removes its own folder"
rm -rf "$(lock_of "$ag")"

# A state folder that cannot take the lock folder is no other writer: the
# write runs at once, unlocked, as on the flock path without a state folder.
if [ "$PLATFORM" = gitbash ]; then
    skip "no flock: a state folder without write permission: Git Bash's chmod u-w leaves the folder writable"
else
    uw="$(mk_repo)"; chmod u-w "$T_CACHE/later/v2"
    out="$(LATER_NO_FLOCK=1 timed_add "$uw" "with no room for a lock")"
    chmod u+w "$T_CACHE/later/v2"
    read -r status secs <<< "$out"
    assert_eq "$(printf '%s\n' "$out" | sed 1d)$status" "later: parked -> with no room for a lock0" "no flock: a state folder without write permission runs the write unlocked"
    assert_ok "no flock: and at once (took $secs)" between 0 2 "$secs"
fi

# --- rows, --if -------------------------------------------------------

T=$'\t'
rw="$(mk_repo)"
printf '%s\n' '# Parked notes (`/later`)' '' \
    '- [ ] Check the S3 retry path (2026-10-01 10:00)' \
    '- [x] closed one' \
    '- [ ] undated one' > "$rw/$Q"
printf -- '- [ ] split\there\n' >> "$rw/$Q"
out="$(lt "$rw" rows)"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "queue${T}$(basename "$rw")" "rows starts with the queue line"
assert_eq "$(printf '%s\n' "$out" | sed -n 2p)" "note${T}1${T}3d${T}Check the S3 retry path" "rows: position, age, text without the stamp"
assert_eq "$(printf '%s\n' "$out" | sed -n 3p)" "note${T}2${T}undated${T}undated one" "rows leaves closed notes out"
assert_eq "$(printf '%s\n' "$out" | sed -n 4p)" "note${T}3${T}undated${T}split${T}here" "rows keeps a tab inside a note's text"
assert_eq "$(printf '%s\n' "$out" | count_lines)" "4" "rows prints nothing else"
assert_eq "$(lt "$e" rows)" "queue${T}$(basename "$e")" "rows without a queue file prints the queue line alone"
gone="$(mktemp -d)"
out="$( cd "$gone" && rmdir "$gone" && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" PATH="$ENGINE_PATH" bash "$ENGINE" rows 2>&1; echo "exit $?" )"
assert_contains "$out" "later: cannot resolve the queue here" "rows names an unresolvable queue"
assert_contains "$out" "exit 1" "rows exits 1 when the queue cannot be resolved"

gq="$(mk_repo)"
printf '%s\n' '- [ ] alpha' '- [ ] beta' '- [ ] gamma' > "$gq/$Q"
assert_eq "$(lt "$gq" done --if beta 2)" "later: done -> beta" "done --if closes a note whose text matches"
before="$(file_digest "$gq/$Q")"
out="$(lt "$gq" drop --if beta 2 2>&1; echo "exit $?")"
assert_eq "$out" "later: note 2 changed since it was listed; nothing changed"$'\n'"exit 1" "drop --if refuses a note whose text differs"
assert_eq "$(file_digest "$gq/$Q")" "$before" "a refused --if leaves the file byte-identical"
assert_eq "$(lt "$gq" drop --if gamma 2)" "later: dropped -> gamma" "drop --if drops a note whose text matches"
assert_eq "$(lt "$gq" done --if alpha 5 2>&1)" "later: note 5 changed since it was listed; nothing changed" "--if past the end reports a change"
assert_eq "$(lt "$gq" done --if alpha 1 2 2>&1)" "later: --if takes exactly one note number" "--if with two numbers is refused"
assert_fail "--if with no number is refused" lt "$gq" done --if alpha
assert_contains "$(lt "$gq" list)" "$(basename "$gq"): 1 parked" "refused --if forms change nothing"
assert_eq "$(lt "$rw" done --if 'Check the S3 retry path' 1)" "later: done -> Check the S3 retry path" "--if compares the text without its stamp"
assert_eq "$(lt "$rw" drop --if "split${T}here" 2)" "later: dropped -> split${T}here" "--if matches a text holding a tab"
assert_contains "$(XDG_STATE_HOME="$T_STATE" PATH="$ENGINE_PATH" bash "$ENGINE" 2>&1)" "done [--if <text>] <n>..." "usage names the --if form"

# --- all --------------------------------------------------------------

roots="$(mktemp -d)"; TMPDIRS+=("$roots")
mkdir -p "$roots/a" "$roots/b" "$roots/c" "$roots/a/node_modules/pkg" "$roots/a/.worktrees/w" "$roots/a/vendor/x"
printf '%s\n' '- [ ] a1 (2026-09-13 14:05)' '- [ ] a2 (2026-10-04 10:00)' > "$roots/a/$Q"
printf '%s\n' '- [ ] b1' '- [ ] b2' '- [ ] b3 (2026-10-01 10:00)' > "$roots/b/$Q"
printf '%s\n' '- [x] all closed' > "$roots/c/$Q"
printf '%s\n' '- [ ] hidden' | tee "$roots/a/node_modules/pkg/$Q" "$roots/a/.worktrees/w/$Q" > "$roots/a/vendor/x/$Q"
all() { ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" TZ="$ZONE" LATER_NOW="$NOW" LATER_ROOTS="$1" PATH="$ENGINE_PATH" run_engine all ); }
out="$(all "$roots")"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "  3 open, oldest undated   $roots/b" "largest queue first, undated is oldest"
assert_eq "$(printf '%s\n' "$out" | sed -n 2p)" "  2 open, oldest 21d       $roots/a" "oldest age of a dated queue"
assert_eq "$(printf '%s\n' "$out" | sed -n 3p)" "  5 open in 2 queues" "total line; closed-only and pruned queues omitted"
assert_eq "$(printf '%s\n' "$out" | count_lines)" "3" "nothing else printed"
assert_contains "$(all "$roots/a:$roots/b:/nonexistent")" "  5 open in 2 queues" "several roots, missing root ignored"
assert_eq "$(all "$roots/c")" "later: no parked notes" "no open notes anywhere"
mkdir -p "$T_HOME/proj"; printf '%s\n' '- [ ] h1' > "$T_HOME/proj/$Q"
out="$( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" TZ=UTC LATER_NOW="$NOW" PATH="$ENGINE_PATH" bash "$ENGINE" all )"
assert_contains "$out" "~/proj" "default root is HOME, shown with a tilde"

# A queue that is a symlink to a regular file is counted, once. The link
# target lives outside the scanned root, so it cannot count as a second queue.
if [ "$PLATFORM" = gitbash ]; then
    skip "all counts a symlinked queue once: $NO_LINKS"
else
    lroot="$(mktemp -d)"; ltarget="$(mktemp -d)"; TMPDIRS+=("$lroot" "$ltarget")
    mkdir -p "$lroot/p"; printf '%s\n' '- [ ] via link' > "$ltarget/notes.md"
    ln -s "$ltarget/notes.md" "$lroot/p/$Q"
    assert_eq "$(all "$lroot")" "  1 open, oldest undated   $lroot/p"$'\n'"  1 open in 1 queues" "all counts a symlinked queue"
fi

# --- session-start ----------------------------------------------------

hook_in() { "$JQ" -n --arg cwd "$1" --arg src "${2:-startup}" '{cwd: $cwd, source: $src, hook_event_name: "SessionStart"}'; }
ss_json() { # stdin: hook input; prints the hook's output as it wrote it
    ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" CLAUDE_CODE_ENTRYPOINT=cli TZ="$ZONE" LATER_NOW="$NOW" PATH="$ENGINE_PATH" run_engine session-start )
}
ss() { # stdin: hook input; prints the user-visible message
    ss_json | "$JQ" -r '.systemMessage // empty'
}
# <text> as the inside of a JSON string literal, for input written by hand.
json_inner() { printf '%s' "$1" | sed 's/[\\"]/\\&/g'; }
is_json() { printf '%s' "$1" | "$JQ" -e . >/dev/null; }

s="$(mk_repo)"; mkdir -p "$s/deep/er"
printf '%s\n' '- [ ] old undated' '- [ ] old dated (2026-09-01 08:00)' '- [ ] n3' '- [ ] n4' '- [ ] n5' '- [ ] n6' > "$s/$Q"

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
out="$(hook_in "$s" | ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" LATER_DIGEST_COUNT=2 PATH="$ENGINE_PATH" bash "$ENGINE" session-start ) | "$JQ" -r .systemMessage)"
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

# Under a byte locale (C) a character is a byte, and a cut that lands inside
# a UTF-8 character steps back to its first byte, so the display ends on a
# whole character: one byte back for the first note, two for the second and
# three for the third. Clipped at 97 bytes plus the marker, these keep 32
# Georgian letters (96 bytes), xx and 31 letters (95), xx and 23 emoji (94).
geo50="$(printf 'ა%.0s' $(seq 1 50))"
emoji30="$(printf '🎉%.0s' $(seq 1 30))"
cb="$(mk_repo)"
printf -- '- [ ] %s (2026-10-04 14:00)\n' "$geo50" "xx$geo50" "xx$emoji30" > "$cb/$Q"
out="$(hook_in "$cb" | LC_ALL=C ss)"
geo32="$(printf 'ა%.0s' $(seq 1 32))"; geo31="$(printf 'ა%.0s' $(seq 1 31))"; emoji23="$(printf '🎉%.0s' $(seq 1 23))"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "later: 3 parked in $(basename "$cb"), 3 new: $geo32...; xx$geo31...; xx$emoji23..." "under LC_ALL=C the clip ends on a whole UTF-8 character"
assert_contains "$out" $'\n'" 3. xx$emoji23... (" "under LC_ALL=C the list rows are clipped on a whole character too"

# Spec R5.1: the output is valid JSON whatever the notes hold. The queue is
# written directly, because add collapses tabs and carriage returns.
rt="$(mk_repo)"
rt1='say "hi" to C:\temp, \"quoted\" and \\ twice'
rt2="a tab${T}and a control byte "$'\001'" inside"
rt3='Georgian შენიშვნა and an emoji 🎉'
rt4="a carriage"$'\r'"return mid note"
printf -- '- [ ] %s (2026-10-04 14:00)\n' "$rt1" "$rt2" "$rt3" "$rt4" > "$rt/$Q"
out="$(hook_in "$rt" | ss_json)"
assert_ok "the output parses for notes holding quotes, backslashes, controls and non-ASCII text" is_json "$out"
msg="$(printf '%s' "$out" | "$JQ" -r '.systemMessage // empty')"
assert_eq "$(printf '%s\n' "$msg" | sed -n 1p)" "later: 4 parked in $(basename "$rt"), 4 new: $rt1; $rt2; $rt3, +1 more" "the count line holds the note texts exactly"
i=0
for n in "$rt1" "$rt2" "$rt3" "$rt4"; do
    i=$((i + 1))
    assert_contains "$msg" $'\n'" $i. $n (" "the list holds note $i exactly"
done

# Review Focus 5: the top-level cwd is used, decoded, also after a nested
# object that holds a cwd of its own.
if [ "$PLATFORM" = gitbash ]; then
    skip "a cwd holding a backslash and a double quote: Windows folder names cannot hold either"
else
    wq="$(mk_tmpdir)/back\\slash \"quoted\""
    mv "$(mk_repo)" "$wq"
    printf '%s\n' '- [ ] in an odd folder' > "$wq/$Q"
    out="$(printf '{"model":{"cwd":"/wrong"},"source":"startup","cwd":"%s","hook_event_name":"SessionStart"}' "$(json_inner "$wq")" | ss)"
    assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "later: 1 parked in back\\slash \"quoted\"" "a nested cwd is skipped, the top-level one decoded"
fi
# \u escapes: one ASCII, one above U+007F and a surrogate pair. The nested
# cwd after the top-level one is skipped too.
uq="$(mk_tmpdir)/esc-Aა😀"
mv "$(mk_repo)" "$uq"
printf '%s\n' '- [ ] spelled with escapes' > "$uq/$Q"
out="$(printf '{"source":"startup","cwd":"%s/esc-\\u0041\\u10D0\\ud83d\\ude00","extra":[{"cwd":"/wrong"}]}' "$(json_inner "${uq%/*}")" | ss)"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "later: 1 parked in esc-Aა😀" "\\u escapes in the cwd decode, a surrogate pair included"
# A key given twice takes its last value, as jq did in 0.1.0.
out="$(printf '{"cwd":"/nonexistent","source":"startup","cwd":"%s"}' "$(json_inner "$uq")" | ss)"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "later: 1 parked in esc-Aა😀" "a cwd given twice takes its last value"

# Silent paths: every one exits 0 and prints nothing.
assert_eq "$(hook_in "$s" resume | ss)" "" "resume is ignored"
assert_eq "$(hook_in "$s" compact | ss)" "" "compact is ignored"
assert_eq "$("$JQ" -n --arg cwd "$s" '{cwd: $cwd, source: "startup", agent_id: "a1"}' | ss)" "" "subagent is ignored"
assert_eq "$(printf 'not json' | ss)" "" "malformed input is ignored"
assert_eq "$(printf '' | ss)" "" "empty input is ignored"
sj="$(json_inner "$s")"
assert_eq "$(printf '{"cwd":"%s","source":"startup"' "$sj" | ss)" "" "an unclosed object is ignored"
assert_eq "$(printf '[{"cwd":"%s","source":"startup"}]' "$sj" | ss)" "" "a top-level array is ignored"
assert_eq "$(printf '{"cwd":"%s","source":"startup"} {}' "$sj" | ss)" "" "text after the object is ignored"
assert_eq "$(printf '{"cwd":"%s","source":"startup","cwd":7}' "$sj" | ss)" "" "a cwd whose last value is not a string is ignored"
assert_eq "$(hook_in "$e" | ss)" "" "no queue file: nothing"
assert_eq "$(hook_in "$d" | ss)" "" "no open notes: nothing"
assert_eq "$(hook_in /nonexistent/dir | ss)" "" "missing directory: nothing"
assert_eq "$(hook_in "$s" | ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" CLAUDE_CODE_ENTRYPOINT=sdk-cli PATH="$ENGINE_PATH" bash "$ENGINE" session-start ))" "" "headless session is ignored"
assert_ok "malformed input exits 0" bash -c "printf 'not json' | HOME='$T_HOME' XDG_CACHE_HOME='$T_CACHE' XDG_STATE_HOME='$T_STATE' CLAUDE_CODE_ENTRYPOINT=cli PATH='$ENGINE_PATH' bash '$ENGINE' session-start"

# An unreadable queue: nothing on stdout or stderr, and exit 0.
if [ "$PLATFORM" = gitbash ]; then
    skip "an unreadable queue prints nothing: Git Bash's chmod 000 leaves the file readable"
else
    ur="$(mktemp -d)"; TMPDIRS+=("$ur"); printf '%s\n' '- [ ] unreadable' > "$ur/$Q"; chmod 000 "$ur/$Q"
    out="$(hook_in "$ur" | ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" PATH="$ENGINE_PATH" bash "$ENGINE" session-start 2>&1; echo "exit $?" ))"
    assert_eq "$out" "exit 0" "unreadable queue prints nothing on either stream and exits 0"
fi

# Unwritable state: still displays.
if [ "$PLATFORM" = gitbash ]; then
    skip "display works when state cannot be written: Git Bash's chmod 500 leaves the folder writable"
else
    ro="$(mktemp -d)"; TMPDIRS+=("$ro"); chmod 500 "$ro"
    out="$(hook_in "$s" | ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$ro" XDG_STATE_HOME="$T_STATE" CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" PATH="$ENGINE_PATH" bash "$ENGINE" session-start ) | "$JQ" -r '.systemMessage // empty')"
    assert_contains "$out" "later: 13 parked" "display works when state cannot be written"
    chmod 700 "$ro"
fi

# Corrupt state file is treated as never shown.
key="$(state_key_of "$s")"
printf 'garbage\n\n' > "$T_CACHE/later/v2/$key"
assert_contains "$(hook_in "$s" | ss)" "Oldest notes:" "corrupt state means never shown"

# Leading-zero state reads as decimal: "08" is not valid octal and must not
# abort the hook, and a digest written as 0<now> is recent, so no list.
# pipefail carries the engine's exit status out of ss.
printf '08\n0%s\n' "$NOW" > "$T_CACHE/later/v2/$key"
out="$(hook_in "$s" | ss; echo "exit $?")"
assert_eq "$(printf '%s\n' "$out" | sed 's/,.*//')" "later: 13 parked in $(basename "$s")"$'\n'"exit 0" "leading-zero state still displays and exits 0"

# A third line, the local minute of the last display, decides what is new
# over the first, and reads as decimal too. Under UTC that minute is NOW / 60.
printf '0\n%s\n0%s\n' "$NOW" "$((NOW / 60))" > "$T_CACHE/later/v2/$key"
assert_eq "$(hook_in "$s" | ss)" "later: 13 parked in $(basename "$s")" "the third state line, with a leading zero, outranks a never-shown first line"

# --- the clock ----------------------------------------------------------
# Stamps are local wall-clock minutes, compared in shell arithmetic (spec
# R5.6). '<+04>-4' (the offset of the spec's Asia/Tbilisi) and '<-05>5' are
# the POSIX spellings of UTC+4 and UTC-5, which need no zone database.
PLUS4='<+04>-4'
MINUS5='<-05>5'

# Ages are whole days of 24 hours back from the local clock, which reads
# 2026-10-04 14:05 in UTC+4 four hours before NOW0.
ages="$(mk_repo)"
printf -- '- [ ] %s\n' 'late yesterday (2026-10-03 23:30)' 'a day and an hour ago (2026-10-03 13:00)' 'twelve days ago (2026-09-22 09:00)' > "$ages/$Q"
out="$(ZONE=$PLUS4 NOW=$((NOW0 - 4 * 3600)) lt "$ages" list)"
assert_contains "$out" " 1. late yesterday (today)" "ages: 14 hours 35 minutes back reads today"
assert_contains "$out" " 2. a day and an hour ago (1d)" "ages: 25 hours back reads 1d, counted on the local clock"
assert_contains "$out" " 3. twelve days ago (12d)" "ages: twelve days and five hours back reads 12d"

# Real dates only: February 29 in leap years (every fourth year, a century
# only every fourth century), and year 0000, whose January and February count
# in the year before it for the day count. The rest stay undated, stamp and
# all.
dt="$(mk_repo)"
printf -- '- [ ] %s\n' 'future leap day (2028-02-29 10:00)' 'past leap day (2024-02-29 10:00)' 'leap century (2000-02-29 10:00)' \
    'year zero (0000-02-29 12:00)' 'not leap (2027-02-29 10:00)' 'not leap century (2100-02-29 10:00)' 'no such date (2026-13-45 99:99)' > "$dt/$Q"
out="$(NOW=$NOW0 lt "$dt" rows)"
assert_eq "$(printf '%s\n' "$out" | sed 1d)" "$(printf 'note\t%s\n' "1${T}today${T}future leap day" "2${T}948d${T}past leap day" "3${T}9714d${T}leap century" \
    "4${T}740199d${T}year zero" "5${T}undated${T}not leap (2027-02-29 10:00)" "6${T}undated${T}not leap century (2100-02-29 10:00)" \
    "7${T}undated${T}no such date (2026-13-45 99:99)")" "dates: leap years count, impossible dates stay text"

# A 0.1.0 state file holds two epochs and no minutes; its display converts to
# the local minute it fell in. Here the display was an hour ago, at 17:05 in
# UTC+4, and the clock reads 18:05.
o1="$(mk_repo)"
printf -- '- [ ] %s\n' 'half an hour ago (2026-10-04 17:35)' 'two hours ago (2026-10-04 16:05)' > "$o1/$Q"
mkdir -p "$T_CACHE/later/v2"
printf '%s\n%s\n' "$((NOW0 - 3600))" "$NOW0" > "$T_CACHE/later/v2/$(state_key_of "$o1")"
assert_eq "$(hook_in "$o1" | ZONE=$PLUS4 NOW=$NOW0 ss)" "later: 2 parked in $(basename "$o1"), 1 new: half an hour ago" "0.1.0 state: a note from after the display is new, one from before it is not"

# The 0.1.0 display fell at second 50 of 17:05, and the clock reads second 30
# of 18:05: a note stamped 17:05 is new, as 0.1.0 counted it, and one stamped
# 17:04 is not.
o2="$(mk_repo)"
printf -- '- [ ] %s\n' 'in the minute of the display (2026-10-04 17:05)' 'the minute before it (2026-10-04 17:04)' > "$o2/$Q"
o2_state="$T_CACHE/later/v2/$(state_key_of "$o2")"
printf '%s\n%s\n' "$((NOW0 - 3600 + 50))" "$NOW0" > "$o2_state"
assert_eq "$(hook_in "$o2" | ZONE=$PLUS4 NOW=$((NOW0 + 30)) ss)" "later: 2 parked in $(basename "$o2"), 1 new: in the minute of the display" "0.1.0 state: the display's minute counts whatever its second"
# The state keeps its two epochs and gains the local minute of the display.
assert_eq "$(tr '\n' ' ' < "$o2_state")" "$((NOW0 + 30)) $NOW0 $(( (NOW0 + 30 + 4 * 3600) / 60 )) " "the state holds the display's epoch, the digest's epoch and the display's local minute"

# A note added at the test clock is announced at the next session start and
# not at the one after, in a zone ahead of UTC and in one behind it (spec
# R8.2). The display before the add gives the second start a minute to
# compare with.
for zs in "$PLUS4 18:05" "$MINUS5 09:05"; do
    zone=${zs% *}
    zn="$(mk_repo)"
    printf -- '- [ ] %s\n' 'parked before' > "$zn/$Q"
    hook_in "$zn" | ZONE=$zone NOW=$NOW0 ss >/dev/null
    ZONE=$zone NOW=$NOW0 lt "$zn" add parked at the test clock >/dev/null
    assert_eq "$(tail -n1 "$zn/$Q")" "- [ ] parked at the test clock (2026-10-04 ${zs#* })" "$zone: add stamps the local time"
    assert_eq "$(hook_in "$zn" | ZONE=$zone NOW=$((NOW0 + 3600)) ss)" "later: 2 parked in $(basename "$zn"), 1 new: parked at the test clock" "$zone: the note is announced at the next start"
    assert_eq "$(hook_in "$zn" | ZONE=$zone NOW=$((NOW0 + 7200)) ss)" "later: 2 parked in $(basename "$zn")" "$zone: and not at the one after"
done

# One date call per run, not one per note (spec R5.6). This folder's date
# records each call and runs the real one; only this case puts it first on
# the engine's PATH.
DATE_TRAP="$(mk_tmpdir)"
type -P date > "$DATE_TRAP/real"
printf '%s\n' '#!/bin/sh' 'd=${0%/*}' 'printf "%s\n" "$*" >> "$d/calls"' 'read -r real < "$d/real"' 'exec "$real" "$@"' > "$DATE_TRAP/date"
chmod +x "$DATE_TRAP/date"
dq="$(mk_repo)"
for i in $(seq 1 20); do printf -- '- [ ] dated %s (2026-10-01 10:00)\n' "$i"; done > "$dq/$Q"
out="$(ENGINE_PATH="$DATE_TRAP:$ENGINE_PATH" lt "$dq" list)"
assert_contains "$out" "20. dated 20 (" "the date trap: list runs"
calls=0; [ -f "$DATE_TRAP/calls" ] && calls="$(count_lines < "$DATE_TRAP/calls")"
assert_ok "the date trap: list on 20 dated notes runs date once or twice (ran it $calls times)" between 1 2 "$calls"

# The process budget (spec R5.6): a command starts as many processes on 100
# notes as on 5. strace wraps the engine's bash alone and logs every clone,
# clone3, fork and vfork of the run.
if [ "$PLATFORM" != linux ]; then
    skip "the process budget: strace is Linux only"
elif [ -z "$STRACE" ] || ! "$STRACE" -f -o /dev/null true >/dev/null 2>&1; then
    skip "the process budget: strace is missing or cannot trace here"
else
    pb5="$(mk_repo)"; pb100="$(mk_repo)"
    for i in $(seq 1 5); do printf -- '- [ ] note %s (2026-10-01 10:00)\n' "$i"; done > "$pb5/$Q"
    for i in $(seq 1 100); do printf -- '- [ ] note %s (2026-10-01 10:00)\n' "$i"; done > "$pb100/$Q"
    forks_of() { # dir command...: the processes one engine run starts there
        local dir="$1" log; shift
        log="$(mk_tmpdir)/trace"
        if [ "$1" = session-start ]; then
            hook_in "$dir" | TRACE_LOG="$log" ss_json >/dev/null
        else
            TRACE_LOG="$log" lt "$dir" "$@" >/dev/null 2>&1
        fi
        grep -cE '^[0-9]+ +(clone3?|v?fork)\(' "$log"
    }
    # A session start stores the queue name's copy when the copy differs, at
    # three processes: stored here first, so neither traced run pays for it.
    hook_in "$e" | ss_json >/dev/null
    # In this order: the first session start of both queues, and add before
    # done and drop, so the two runs of a pair see the same state.
    for cmd in rows list session-start 'add one more' 'done 1' 'drop 1'; do
        read -r -a words <<< "$cmd"
        few="$(forks_of "$pb5" "${words[@]}")"; many="$(forks_of "$pb100" "${words[@]}")"
        assert_eq "$many" "$few" "the process budget: $cmd starts as many processes on 100 notes as on 5"
        assert_ok "the process budget: strace saw $cmd start processes ($few)" test "$few" -gt 0
    done
fi

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
        hook_in "$e" | ( cd / && env HOME="$h" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" CLAUDE_PLUGIN_DATA="$h/data" \
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
    out="$(hook_in "$s" | ( cd / && env HOME="$h" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" CLAUDE_PLUGIN_DATA="$h/data" \
        CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" PATH="$h/.local/bin:$ENGINE_PATH" bash "$ENGINE" session-start ))"
    assert_eq "$(printf '%s' "$out" | "$JQ" -s length)" "1" "the count line and a notice arrive in one JSON object"
    assert_contains "$(printf '%s' "$out" | "$JQ" -r .systemMessage | sed -n 1p)" "parked in $(basename "$s")" "the count line comes first"
    assert_eq "$(printf '%s' "$out" | "$JQ" -r .systemMessage | tail -n1)" "$ADDED" "the notice follows it"

    h="$(mk_home)"
    "$JQ" -n --arg cwd "$e" '{cwd: $cwd, source: "resume"}' | ( cd / && HOME="$h" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" CLAUDE_PLUGIN_DATA="$h/data" CLAUDE_CODE_ENTRYPOINT=cli PATH="$ENGINE_PATH" bash "$ENGINE" session-start ) >/dev/null
    assert_ok "a resumed session links nothing" untouched "$h"
    h="$(mk_home)"
    "$JQ" -n --arg cwd "$e" '{cwd: $cwd, source: "startup", agent_id: "a1"}' | ( cd / && HOME="$h" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" CLAUDE_PLUGIN_DATA="$h/data" CLAUDE_CODE_ENTRYPOINT=cli PATH="$ENGINE_PATH" bash "$ENGINE" session-start ) >/dev/null
    assert_ok "a subagent links nothing" untouched "$h"
    h="$(mk_home)"
    hook_in "$e" | ( cd / && HOME="$h" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" CLAUDE_PLUGIN_DATA="$h/data" CLAUDE_CODE_ENTRYPOINT=sdk-cli PATH="$ENGINE_PATH" bash "$ENGINE" session-start ) >/dev/null
    assert_ok "a headless session links nothing" untouched "$h"
    h="$(mk_home)"
    hook_in "$e" | ( cd / && HOME="$h" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" CLAUDE_CODE_ENTRYPOINT=cli PATH="$ENGINE_PATH" bash "$ENGINE" session-start ) >/dev/null
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
    wr() { ( cd "$w" && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" TZ=UTC LATER_NOW="$NOW" PATH="$ENGINE_PATH" "$fe/home/.local/bin/later" "$@" ); }
    assert_eq "$( cd "$w" && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" PATH="$ENGINE_PATH" "$FRONT" )" "later: no parked notes" "by its own path, bare later lists"
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
    assert_fail "a front-end without its engine exits non-zero" env HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" PATH="$ENGINE_PATH" "$fe/later"
    assert_contains "$(HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" PATH="$ENGINE_PATH" "$fe/later" 2>&1)" "later: engine not found or not executable at $(cd "$fe" && pwd -P)/later.sh" "a front-end without its engine names the path it tried"
fi

# --- the queue file name ----------------------------------------------
# The last section: every case starts from a state folder of its own, so no
# case, here or above, inherits another's stored copy.

fresh_state() { T_STATE="$(mk_tmpdir)"; }
store_copy() { mkdir -p "$T_STATE/later" && printf '%s\n' "$1" > "$T_STATE/later/queue-file"; }
stored_copy() { cat "$T_STATE/later/queue-file" 2>/dev/null; }

# The setting names the queue file and is stored; a run without it follows
# the stored copy.
fresh_state
fs="$(mk_repo)"
assert_eq "$(CLAUDE_PLUGIN_OPTION_FILE=LATER.md lt "$fs" add set by the setting 2>&1)" "later: parked -> set by the setting" "the setting: add parks and prints nothing else"
assert_file "$fs/LATER.md" "the setting names the queue file"
assert_nofile "$fs/$Q" "the setting: no queue under the default name"
assert_eq "$(stored_copy)" "LATER.md" "the setting is stored"
assert_eq "$(find "$T_STATE/later" -name '.queue-file.*' | count_lines)" "0" "storing leaves no temporary file"
ino="$(file_inode "$T_STATE/later/queue-file")"
CLAUDE_PLUGIN_OPTION_FILE=LATER.md lt "$fs" list >/dev/null
assert_eq "$(file_inode "$T_STATE/later/queue-file")" "$ino" "a copy that already holds the setting is not rewritten"
lt "$fs" add without the setting >/dev/null
assert_contains "$(cat "$fs/LATER.md")" "without the setting" "a run without the setting follows the stored copy"
assert_nofile "$fs/$Q" "the stored copy: no queue under the default name"

# An unusable value is never used or stored: the stored copy decides, else
# the default. The limit is 255 bytes: 86 Georgian letters are 86 characters
# but 258 bytes.
long256="$(printf 'x%.0s' $(seq 1 253)).md"
geo258="$(printf 'ა%.0s' $(seq 1 86))"
for bad in '' . .. a/b 'a\b' '*.md' 'x?' '[x]' "a${T}b.md" "$long256" "$geo258"; do
    label="'${bad:0:12}'"; label="${label//$T/<tab>}"
    fresh_state; ub="$(mk_repo)"
    assert_eq "$(CLAUDE_PLUGIN_OPTION_FILE="$bad" lt "$ub" add with no copy 2>&1)" "later: parked -> with no copy" "unusable $label, no copy: add parks and prints nothing else"
    assert_contains "$(cat "$ub/$Q" 2>/dev/null)" "with no copy" "unusable $label, no copy: the default is used"
    assert_eq "$(find "$ub" -mindepth 1 -maxdepth 1 | count_lines)" "3" "unusable $label: nothing else is written in the project"
    assert_nofile "$T_STATE/later/queue-file" "unusable $label: the value is not stored"
    store_copy LATER.md; before="$(file_digest "$T_STATE/later/queue-file")"
    assert_eq "$(CLAUDE_PLUGIN_OPTION_FILE="$bad" lt "$ub" add with a copy 2>&1)" "later: parked -> with a copy" "unusable $label, a copy: add parks and prints nothing else"
    assert_contains "$(cat "$ub/LATER.md" 2>/dev/null)" "with a copy" "unusable $label, a copy: the stored name is used"
    assert_eq "$(file_digest "$T_STATE/later/queue-file")" "$before" "unusable $label: the copy is unchanged"
done

# 255 bytes is usable, ASCII or not: 85 Georgian letters are 255 bytes.
for good in "$(printf 'x%.0s' $(seq 1 252)).md" "$(printf 'ა%.0s' $(seq 1 85))"; do
    fresh_state; ug="$(mk_repo)"
    CLAUDE_PLUGIN_OPTION_FILE="$good" lt "$ug" add at the limit >/dev/null
    assert_file "$ug/$good" "a name of 255 bytes in ${#good} characters is used"
    assert_eq "$(stored_copy)" "$good" "a name of 255 bytes in ${#good} characters is stored"
done

# session-start stores the setting, or its absence as the default, before
# any early exit, and counts the queue under that name.
sq="$(mk_repo)"
printf '%s\n' '- [ ] under the default' > "$sq/$Q"
printf '%s\n' '- [ ] one under LATER.md' '- [ ] two under LATER.md' > "$sq/LATER.md"
fresh_state; store_copy LATER.md
assert_contains "$(hook_in "$sq" | ss)" "later: 1 parked in $(basename "$sq")" "session-start without the setting counts the default queue"
assert_eq "$(stored_copy)" "$Q" "session-start without the setting stores the default"
fresh_state
assert_contains "$(hook_in "$sq" | CLAUDE_PLUGIN_OPTION_FILE=LATER.md ss)" "later: 2 parked in $(basename "$sq")" "session-start counts the setting's queue"
assert_eq "$(stored_copy)" "LATER.md" "session-start stores the setting"
fresh_state
assert_eq "$(hook_in "$sq" resume | CLAUDE_PLUGIN_OPTION_FILE=LATER.md ss)" "" "a resumed session prints nothing"
assert_eq "$(stored_copy)" "LATER.md" "a resumed session still stores the setting"
fresh_state
out="$(hook_in "$sq" | ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" CLAUDE_PLUGIN_OPTION_FILE=LATER.md CLAUDE_CODE_ENTRYPOINT=sdk-cli PATH="$ENGINE_PATH" bash "$ENGINE" session-start ))"
assert_eq "$out" "" "a headless session prints nothing"
assert_eq "$(stored_copy)" "LATER.md" "a headless session still stores the setting"

# An unusable setting: the message's last line says so at every session
# start while it is set, also when it is the whole message.
BAD='later: laterbox.file is "a/b", which is not a plain file name, so LATER.local.md is used; change it in /config.'
bn="$(mk_repo)"
fresh_state
assert_eq "$(hook_in "$bn" | CLAUDE_PLUGIN_OPTION_FILE=a/b ss)" "$BAD" "an unusable setting is announced, alone when nothing else shows"
assert_eq "$(hook_in "$bn" | CLAUDE_PLUGIN_OPTION_FILE=a/b ss)" "$BAD" "and at every session start while it is set"
assert_nofile "$T_STATE/later/queue-file" "session-start does not store an unusable setting"
printf '%s\n' '- [ ] parked here' > "$bn/$Q"
out="$(hook_in "$bn" | CLAUDE_PLUGIN_OPTION_FILE=a/b ss)"
assert_contains "$(printf '%s\n' "$out" | sed -n 1p)" "later: 1 parked in $(basename "$bn")" "an unusable setting: the count line still comes first"
assert_eq "$(printf '%s\n' "$out" | tail -n1)" "$BAD" "an unusable setting: the notice is the last line"
fresh_state; store_copy LATER.md
assert_eq "$(hook_in "$bn" | CLAUDE_PLUGIN_OPTION_FILE=a/b ss)" 'later: laterbox.file is "a/b", which is not a plain file name, so LATER.md is used; change it in /config.' "the notice names the stored name it fell back to"
assert_eq "$(stored_copy)" "LATER.md" "an unusable setting leaves the copy as it was"
fresh_state
assert_eq "$(hook_in "$bn" | CLAUDE_PLUGIN_OPTION_FILE='' ss | tail -n1)" 'later: laterbox.file is "", which is not a plain file name, so LATER.local.md is used; change it in /config.' "an empty setting is announced"
fresh_state
assert_eq "$(hook_in "$bn" | CLAUDE_PLUGIN_OPTION_FILE=$'a\nb' ss | tail -n1)" 'later: laterbox.file is "a?b", which is not a plain file name, so LATER.local.md is used; change it in /config.' "a control character in the setting shows as ? and keeps the notice one line"

# A copy that cannot be written breaks nothing.
if [ "$PLATFORM" = gitbash ]; then
    skip "a copy that cannot be written breaks nothing: Git Bash's chmod 500 leaves the folder writable"
else
    fresh_state; mkdir -p "$T_STATE/later"; chmod 500 "$T_STATE/later"
    nw="$(mk_repo)"
    out="$(hook_in "$nw" | ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" XDG_STATE_HOME="$T_STATE" CLAUDE_PLUGIN_OPTION_FILE=LATER.md CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" PATH="$ENGINE_PATH" bash "$ENGINE" session-start 2>&1 >/dev/null; echo "exit $?" ))"
    assert_eq "$out" "exit 0" "session-start with a copy that cannot be written: nothing on stderr, exit 0"
    assert_eq "$(CLAUDE_PLUGIN_OPTION_FILE=LATER.md lt "$nw" add unstored 2>&1)" "later: parked -> unstored" "add with a copy that cannot be written parks and prints nothing else"
    assert_file "$nw/LATER.md" "add with a copy that cannot be written still uses the setting"
    chmod 700 "$T_STATE/later"
fi

# all lists only the queues under the name in force.
ar="$(mk_tmpdir)"; mkdir -p "$ar/p1" "$ar/p2"
printf '%s\n' '- [ ] under LATER.md' > "$ar/p1/LATER.md"
printf '%s\n' '- [ ] under the default' > "$ar/p2/$Q"
fresh_state; store_copy LATER.md
assert_eq "$(all "$ar")" "  1 open, oldest undated   $ar/p1"$'\n'"  1 open in 1 queues" "all with a stored LATER.md lists only LATER.md queues"
fresh_state
assert_eq "$(all "$ar")" "  1 open, oldest undated   $ar/p2"$'\n'"  1 open in 1 queues" "all with no copy lists only the default's queues"

# Names with a space, a leading dash or non-ASCII letters work end to end.
for name in 'Later notes.md' '-notes.md' 'შენიშვნები.md'; do
    fresh_state; nr="$(mk_repo)"
    assert_eq "$(CLAUDE_PLUGIN_OPTION_FILE="$name" lt "$nr" add first under "$name" 2>&1)" "later: parked -> first under $name" "$name: add with the setting"
    assert_file "$nr/$name" "$name: the queue file has that name"
    assert_eq "$(stored_copy)" "$name" "$name: the stored copy holds it"
    lt "$nr" add second >/dev/null
    assert_eq "$(lt "$nr" list 2>&1)" "$(basename "$nr"): 2 parked"$'\n'" 1. first under $name (today)"$'\n'" 2. second (today)" "$name: list through the stored copy"
    assert_eq "$(lt "$nr" done 1 2>&1)" "later: done -> first under $name" "$name: done 1"
    assert_eq "$(all "$nr")" "  1 open, oldest today     $nr"$'\n'"  1 open in 1 queues" "$name: all"
done

# A stored copy that is empty, holds an unusable value or cannot be read:
# the default.
fresh_state; mkdir -p "$T_STATE/later"; : > "$T_STATE/later/queue-file"; rc="$(mk_repo)"
assert_eq "$(lt "$rc" add despite an empty copy 2>&1)" "later: parked -> despite an empty copy" "an empty copy: add parks and prints nothing else"
assert_file "$rc/$Q" "an empty copy: the default is used"
fresh_state; store_copy a/b; rc="$(mk_repo)"
assert_eq "$(lt "$rc" add despite a bad copy 2>&1)" "later: parked -> despite a bad copy" "a copy holding a/b: add parks and prints nothing else"
assert_file "$rc/$Q" "a copy holding a/b: the default is used"
if [ "$PLATFORM" = gitbash ]; then
    skip "an unreadable copy: Git Bash's chmod 000 leaves the file readable"
else
    fresh_state; store_copy LATER.md; chmod 000 "$T_STATE/later/queue-file"; rc="$(mk_repo)"
    assert_eq "$(lt "$rc" add despite an unreadable copy 2>&1)" "later: parked -> despite an unreadable copy" "an unreadable copy: add parks and prints nothing else"
    assert_file "$rc/$Q" "an unreadable copy: the default is used"
    chmod 600 "$T_STATE/later/queue-file"
fi

# Spec R4: the engine writes no git ignore rule or configuration.
fresh_state; gr="$(mk_repo)"
exclude_before="$(file_digest "$gr/.git/info/exclude" 2>/dev/null)"
config_before="$(file_digest "$gr/.git/config")"
lt "$gr" add the first note here >/dev/null
assert_file "$gr/$Q" "R4: the first add makes the queue"
assert_eq "$(file_digest "$gr/.git/info/exclude" 2>/dev/null)" "$exclude_before" "R4: .git/info/exclude is byte-identical"
assert_nofile "$gr/.gitignore" "R4: no .gitignore is made"
assert_eq "$(file_digest "$gr/.git/config")" "$config_before" "R4: the repository's git configuration is untouched"

# Spec R8.2: no engine run in the whole suite reached for jq.
assert_nofile "$JQ_TRAP/calls" "no engine run called jq"

finish
