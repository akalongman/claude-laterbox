#!/usr/bin/env bash
#
# later.sh: parking lot for follow-up notes, kept as a per-project backlog.
#
#   add <note>       append a stamped note to the project's queue file
#   list             print the open notes, numbered, with their age
#   rows             a tab-separated listing for programs: "queue\t<label>",
#                    then "note\t<n>\t<age>\t<text>" per open note
#   done <n>...      tick the listed notes to [x]
#   drop <n>...      delete the listed notes
#   done|drop --if <text> <n>
#                    close note <n> only while its text is still exactly
#                    <text>; otherwise refuse and change nothing
#   all              one line per queue with open notes under the scan roots
#   session-start    SessionStart hook entry point: a user-visible count line,
#                    plus the oldest notes once per LATER_DIGEST_DAYS, and
#                    the terminal command kept linked in ~/.local/bin
#
# The queue file is LATER.local.md at the project's root, unless the
# laterbox.file setting names another file (see resolve_queue_name).
#
# The hook owns WHEN (hooks/hooks.json fires this on session start); this
# script owns WHAT. No `set -e`: the hook path must exit 0 whatever happens,
# so a broken reminder can never delay or block a session.

# A CDPATH from the environment would send a cd below to another folder, and
# make it print that folder.
unset CDPATH

DEFAULT_QUEUE_NAME='LATER.local.md'
# The queue file's name for this run, set by resolve_queue_name.
QUEUE_NAME=$DEFAULT_QUEUE_NAME
# Set, possibly to empty, to the unusable laterbox.file value this run saw.
unset QUEUE_NAME_REJECTED
# The stored copy of the setting, for runs Claude Code did not start.
SETTING_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/later/queue-file"
# shellcheck disable=SC2016  # the backticks are literal markdown
NOTE_HEADING='# Parked notes (`/later`)'

DIGEST_DAYS="${LATER_DIGEST_DAYS:-7}"
DIGEST_COUNT="${LATER_DIGEST_COUNT:-5}"
DISPLAY_WIDTH="${LATER_DISPLAY_WIDTH:-100}"   # session-start only
SCAN_DEPTH=6

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/later/v2"
# with_lock's refusal, on both of its paths.
LOCKED_MSG='later: the queue is locked by another writer'

# The terminal link step's notices (session-start only).
NOTICE_ADDED='later: added the terminal command ~/.local/bin/later; set laterbox.terminal to off in /config to remove it.'
NOTICE_REMOVED='later: removed the terminal command ~/.local/bin/later.'
NOTICE_REFUSED='later: ~/.local/bin/later exists and was not made by this plugin, so the terminal command was not added; remove it and start a new session to get it.'
NOTICE_PATH="later: ~/.local/bin is not on PATH in this session, so a terminal may not find later; add it to PATH in your shell's startup file."
# A printf format: the unusable value, then the name used instead.
NOTICE_BAD_NAME='later: laterbox.file is "%s", which is not a plain file name, so %s is used; change it in /config.'

OPEN_RE='^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*(.*)$'
STAMP_RE=' \(([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2})\)$'
STAMP_LEN=19   # length of " (YYYY-MM-DD HH:MM)"
# The carriage return of a CRLF line end, and the UTF-8 byte-order mark,
# EF BB BF, as bytes, so they match under a UTF-8 and a byte locale alike.
CR=$'\r'
BOM=$'\357\273\277'

# The bytes 0x80 to 0xBF, which only ever continue a UTF-8 character. Listed,
# like JSON_CTL below, because a range in a bracket follows the locale.
UTF8_TAIL=$'\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237\240\241\242\243\244\245\246\247\250\251\252\253\254\255\256\257\260\261\262\263\264\265\266\267\270\271\272\273\274\275\276\277'
# One character in UTF-8, two bytes: its length is 1 under a UTF-8 locale.
UTF8_PROBE=$'\303\251'

# LATER_NO_FLOCK=1 makes with_lock take its lock folder on Linux too, for
# tests: the lock of macOS and Git Bash.

# True when <name> is one plain file name: not empty, not . or .., no / or \,
# no glob character (`all` would read every matching file as a queue), no
# control character, at most 255 bytes.
usable_queue_name() {
    local name="$1" bytes
    case "$name" in
        ''|.|..|*/*|*\\*|*\**|*\?*|*\[*|*[[:cntrl:]]*) return 1 ;;
    esac
    # ${#name} counts characters, and a character is at most 6 bytes (the
    # old UTF-8 maximum), so only a name over 42 needs its bytes counted.
    [ "${#name}" -le 42 ] && return 0
    bytes=$(printf '%s' "$name" | wc -c)
    [ "${bytes//[!0123456789]/}" -le 255 ]
}

# Sets QUEUE_NAME from the first of these that gives a usable name:
#   1. CLAUDE_PLUGIN_OPTION_FILE, the laterbox.file setting. Claude Code
#      exports an option to a hook only once the user has set it, so
#      session-start reads its absence as the default;
#   2. the stored copy, for the terminal command and the skill's calls;
#   3. the default.
# A name from 1 replaces the copy when the copy holds anything else. An
# unusable value is never used or stored; the next source decides.
resolve_queue_name() { # subcommand
    local stored='' from_setting=''
    if [ -n "${CLAUDE_PLUGIN_OPTION_FILE+set}" ]; then
        if usable_queue_name "$CLAUDE_PLUGIN_OPTION_FILE"; then
            QUEUE_NAME=$CLAUDE_PLUGIN_OPTION_FILE
            from_setting=1
        else
            QUEUE_NAME_REJECTED=$CLAUDE_PLUGIN_OPTION_FILE
        fi
    elif [ "$1" = session-start ]; then
        QUEUE_NAME=$DEFAULT_QUEUE_NAME
        from_setting=1
    fi
    # The copy less its final newline; empty when missing or unreadable.
    { IFS= read -r -d '' stored; } 2>/dev/null < "$SETTING_FILE"
    stored=${stored%$'\n'}
    if [ -n "$from_setting" ]; then
        [ "$stored" = "$QUEUE_NAME" ] || store_queue_name
    elif usable_queue_name "$stored"; then
        QUEUE_NAME=$stored
    else
        QUEUE_NAME=$DEFAULT_QUEUE_NAME
    fi
}

# Replaces the stored copy with QUEUE_NAME by a rename from its own folder,
# so a reader sees the old copy or the new one, never a part.
store_queue_name() {
    local dir=${SETTING_FILE%/*} tmp
    mkdir -p "$dir" || return 0
    tmp=$(mktemp "$dir/.queue-file.XXXXXX") || return 0
    if ! { printf '%s\n' "$QUEUE_NAME" > "$tmp" && mv -f "$tmp" "$SETTING_FILE"; }; then
        rm -f "$tmp"
    fi
}

# Sets REPLY to <path> with every symbolic link resolved, in its folders too,
# as readlink -f does where it exists (it is missing before macOS 12.3): a
# missing last part stays as named. Each step enters a folder with cd -P and
# reads a link with plain readlink. It fails after 40 links, which ends a
# cycle, and at a folder it cannot enter. It goes back to the working folder
# it started in when it can; when it cannot, because that folder was
# removed, the shell stays elsewhere, so a caller that reads a relative path
# afterwards calls it in a subshell. scripts/later carries a copy, since it
# cannot source this file before it has found it; the suite checks that the
# two stay the same.
real_path() { # path
    local p=$1 here=$PWD hops=0 dir name text
    REPLY=''
    while :; do
        case $p in
            */*) dir=${p%/*}; name=${p##*/}; [ -n "$dir" ] || dir=/ ;;
            *) dir=.; name=$p ;;
        esac
        # A path that ends in a folder: that folder, entered whole.
        case $name in ''|.|..) dir=$p; name='' ;; esac
        # An empty path names nothing; cd reads a leading dash as an option,
        # and - alone as $OLDPWD.
        case $dir in
            '') break ;;
            -*) dir=./$dir ;;
        esac
        cd -P "$dir" 2>/dev/null || break
        if [ -n "$name" ] && [ -L "./$name" ]; then
            hops=$((hops + 1))
            [ "$hops" -le 40 ] || break
            text=$(readlink "./$name") || break
            case $text in
                /*) p=$text ;;
                *) p=${PWD%/}/$text ;;
            esac
            continue
        fi
        if [ -n "$name" ]; then REPLY=${PWD%/}/$name; else REPLY=$PWD; fi
        break
    done
    # Back to the starting folder; when it was removed, the result stands.
    cd "$here" 2>/dev/null || :
    [ -n "$REPLY" ]
}

# Sets REPLY to the root of the main checkout containing <dir>, or to nothing
# outside a work tree. A linked worktree resolves to the main checkout
# through the common git dir. One git call prints the top level, the git dir
# and the common dir, a line each; a path holding a newline reads as no work
# tree. The root is spelled as cd -P and $PWD spell it, as the shell spells
# every other folder here, which git does not do everywhere (spec R5.4: git
# under Git Bash prints C:/Users/x, the shell /c/Users/x); a root that cd
# cannot enter stays as git printed it. It leaves the shell in the root:
# queue_file, its one caller, runs in a command substitution.
project_root() { # dir
    local out top gitdir common nl=$'\n'
    REPLY=''
    out=$(git -C "$1" rev-parse --path-format=absolute --show-toplevel --git-dir --git-common-dir 2>/dev/null) || return 0
    top=${out%%"$nl"*}; out=${out#*"$nl"}
    gitdir=${out%%"$nl"*}; common=${out#*"$nl"}
    case $common in *"$nl"*) return 0 ;; esac
    if [ "$gitdir" != "$common" ]; then
        top=${common%/*}
        [ -n "$top" ] || top=/
    fi
    if cd -P "$top" 2>/dev/null; then REPLY=$PWD; else REPLY=$top; fi
}

# Queue file for <dir>. $HOME is itself a git repository on a dotfiles setup,
# so a root equal to $HOME is discarded unless <dir> is $HOME; otherwise every
# directory under it without a repository of its own would share one queue.
# The three are compared as cd -P spells them (spec R5.4). Every caller runs
# it in a command substitution, so the folders it and project_root enter
# never reach the caller's shell.
queue_file() {
    local dir home='' root
    cd -P "$1" 2>/dev/null || return 1
    dir=$PWD
    cd -P "$HOME" 2>/dev/null && home=$PWD
    project_root "$dir"; root=$REPLY
    if [ -n "$root" ] && [ "$root" = "$home" ] && [ "$dir" != "$home" ]; then
        root=''
    fi
    printf '%s/%s\n' "${root:-$dir}" "$QUEUE_NAME"
}

queue_label() { basename "$(dirname "$1")"; }

# Sets REPLY to the lock and state key of a queue path: its SHA-1 in hex. By
# sha1sum, or by shasum -a 1 where sha1sum is missing (stock macOS), which
# gives the same digest, so a queue keeps its key across the two.
state_key() { # path
    local sum
    if command -v sha1sum >/dev/null 2>&1; then
        sum=$(printf '%s' "$1" | sha1sum)
    else
        sum=$(printf '%s' "$1" | shasum -a 1)
    fi
    REPLY=${sum%% *}
}

# --- the clock ---------------------------------------------------------
# A stamp is the local wall clock, YYYY-MM-DD HH:MM. Ages and the "new" test
# compare civil minutes (days since 1970-01-01 times 1440, plus the time of
# day) in shell arithmetic, so a run calls date once, whatever the number of
# notes (spec R5.6).

# Sets NOW_EPOCH (seconds), NOW_MIN (the civil minutes of the local wall
# clock) and NOW_STAMP (YYYY-MM-DD HH:MM, local) from one date call.
# LATER_NOW, epoch seconds, replaces the clock for tests: GNU date reads it
# with -d, BSD date with -r. A clock that cannot be read leaves 0, 0 and an
# empty stamp, and fails. Quiet, because it runs before session-start's
# silent subshell and BSD date rejects -d loudly; and nothing date prints
# reaches arithmetic before clock_from has checked it, because an arithmetic
# error here would end the whole run.
load_clock() {
    local fmt='+%s %Y %m %d %H %M' out
    case ${LATER_NOW:-} in
        ''|*[!0123456789]*)
            out=$(date "$fmt" 2>/dev/null) ;;
        *)
            out=$(date -d "@$LATER_NOW" "$fmt" 2>/dev/null) # gnu-date-probe
            clock_from "$out" && return 0
            out=$(date -r "$LATER_NOW" "$fmt" 2>/dev/null) ;;
    esac
    clock_from "$out"
}

# Sets the clock from date's "<epoch> <Y> <m> <d> <H> <M>"; fails on anything
# else, leaving 0, 0 and an empty stamp.
clock_from() { # date output
    local e y mo d h mi extra
    NOW_EPOCH=0 NOW_MIN=0 NOW_STAMP=''
    read -r e y mo d h mi extra <<< "$1"
    case $e in ''|*[!0123456789]*) return 1 ;; esac
    [ "${#e}" -le 15 ] && [ -z "$extra" ] && stamp_minutes "$y-$mo-$d $h:$mi" || return 1
    NOW_EPOCH=$((10#$e)) NOW_MIN=$REPLY NOW_STAMP="$y-$mo-$d $h:$mi"
}

# Sets REPLY to the days from 1970-01-01 to <year>-<month>-<day> of the
# proleptic Gregorian calendar, by H. Hinnant's days_from_civil. Its years
# start in March, so January and February count in the year before: -1 for
# year 0000, which the era step rounds down by hand, because $(( / ))
# truncates toward zero. Base 10 forced: "08" is eight, not bad octal.
civil_days() { # year month day
    local y=$((10#$1)) m=$((10#$2)) d=$((10#$3)) era yoe doy
    [ "$m" -le 2 ] && y=$((y - 1))
    era=$(( (y >= 0 ? y : y - 399) / 400 ))
    yoe=$(( y - era * 400 ))
    doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 ))
    REPLY=$(( era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468 ))
}

# Sets REPLY to the civil minutes of <stamp>, "YYYY-MM-DD HH:MM", or to 0,
# failing, when it is not a real date and time: month 1 to 12, a day the
# month has (February 29 in leap years only), hour 0 to 23, minute 0 to 59.
# The shape is checked before any field reaches arithmetic.
stamp_minutes() { # stamp
    local s=$1 y mo d h mi last
    REPLY=0
    [ "${#s}" -eq 16 ] && [ "${s//[0123456789]/}" = '-- :' ] && [ "${s:4:1}${s:7:1}${s:10:1}${s:13:1}" = '-- :' ] || return 1
    y=$((10#${s:0:4})) mo=$((10#${s:5:2})) d=$((10#${s:8:2})) h=$((10#${s:11:2})) mi=$((10#${s:14:2}))
    case $mo in
        1|3|5|7|8|10|12) last=31 ;;
        4|6|9|11) last=30 ;;
        2) if (( y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) )); then last=29; else last=28; fi ;;
        *) return 1 ;;
    esac
    [ "$d" -ge 1 ] && [ "$d" -le "$last" ] && [ "$h" -le 23 ] && [ "$mi" -le 59 ] || return 1
    civil_days "$y" "$mo" "$d"
    REPLY=$(( REPLY * 1440 + h * 60 + mi ))
}

# One row per open note: "<position>\t<file line>\t<stamp minutes>\t<text>".
# The minutes are 0 for an undated note; the stamp is stripped from the text.
# A queue saved with CRLF line ends, or starting with a UTF-8 byte-order
# mark, reads as an LF file (spec R5.3): one carriage return is dropped from
# the end of each line, and the mark from the first line, before the match.
# A carriage return inside a note's text stays. The read builtin reads the
# file itself: no process, whatever the number of lines (spec R5.6).
open_notes() {
    local file="$1" i=0 n=0 line text mins
    [ -f "$file" ] || return 0
    # The test after read keeps a last line that has no newline.
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%"$CR"}
        [ "$n" -eq 1 ] && line=${line#"$BOM"}
        [[ $line =~ $OPEN_RE ]] || continue
        text=${BASH_REMATCH[1]}
        mins=0
        if [[ $text =~ $STAMP_RE ]]; then
            stamp_minutes "${BASH_REMATCH[1]}"; mins=$REPLY
            [ "$mins" != 0 ] && text=${text:0:${#text}-STAMP_LEN}
        fi
        i=$((i + 1))
        printf '%s\t%s\t%s\t%s\n' "$i" "$n" "$mins" "$text"
    done < "$file"
}

row_count() { [ -n "$1" ] && printf '%s\n' "$1" | grep -c . || printf '0\n'; }

# Text of note <n> in <rows>, whole: everything after the third tab, inner
# tabs kept. Fails when <rows> has no note <n>.
row_text() {
    local i text
    while IFS=$'\t' read -r i _ _ text; do
        [ "$i" = "$2" ] && { printf '%s' "$text"; return 0; }
    done <<< "$1"
    return 1
}

# Sets REPLY to the age of a note stamped at <minutes>: undated for 0, else
# the whole days of 24 hours back from the local clock, today for none.
age_label() { # minutes
    local days
    if [ "$1" = 0 ]; then
        REPLY=undated
        return 0
    fi
    days=$(( (NOW_MIN - $1) / 1440 ))
    if [ "$days" -le 0 ]; then REPLY=today; else REPLY="${days}d"; fi
}

# Sets REPLY to <text> clipped to <width> characters, the cut marked with
# "...". Under a byte locale (C, POSIX) a character is a byte, and a cut that
# lands inside a UTF-8 character steps back to its first byte, at most three
# bytes, so the display never ends in a broken character.
clip() { # text width
    local text=$1 width=$2 cut steps=0
    if [ "${#text}" -le "$width" ]; then
        REPLY=$text
        return 0
    fi
    cut=$((width - 3))
    if [ "${#UTF8_PROBE}" -ne 1 ]; then
        while [ "$steps" -lt 3 ] && [ "$cut" -gt 0 ]; do
            case ${text:cut:1} in
                ["$UTF8_TAIL"]) cut=$((cut - 1)); steps=$((steps + 1)) ;;
                *) break ;;
            esac
        done
    fi
    REPLY="${text:0:cut}..."
}

# Rows on stdin -> " N. text (age)", N being the note's position in the queue.
# With a width, each text is clipped to it.
numbered() {
    local width="${1:-}" i n mins text
    while IFS=$'\t' read -r i n mins text; do
        if [ -n "$width" ]; then
            clip "$text" "$width"; text=$REPLY
        fi
        age_label "$mins"
        printf '%2d. %s (%s)\n' "$i" "$text" "$REPLY"
    done
}

# Run a command holding the queue's lock, and return its status. Every
# writer of a queue on one machine must take the same lock, and the PATH can
# differ between its entry points (Homebrew's flock on macOS reaches a
# terminal, not an app started from the desktop), so the platform chooses
# the lock, not the PATH: flock on Linux when it is found, the lock folder of
# with_lock_dir everywhere else (macOS, Git Bash). Left open: on Linux, an
# entry point whose PATH lacks flock takes the folder while the others take
# flock, and those two do not exclude each other. Without a state folder
# there is nowhere to lock, and the command runs unlocked.
with_lock() {
    local file="$1" key; shift
    mkdir -p "$STATE_DIR" 2>/dev/null
    [ -d "$STATE_DIR" ] || { "$@"; return; }
    state_key "$file"; key=$REPLY
    if [ "${LATER_NO_FLOCK:-}" != 1 ] && [[ ${OSTYPE:-} == linux* ]] && command -v flock >/dev/null 2>&1; then
        (
            flock -w 5 9 || { echo "$LOCKED_MSG" >&2; exit 1; }
            "$@"
        ) 9>"$STATE_DIR/$key.lock"
    else
        with_lock_dir "$STATE_DIR/$key.lock.d" "$@"
    fi
}

# The lock off Linux, and on Linux without flock: the folder <lock>, which
# mkdir makes or refuses in one step on every platform. The holder writes its
# process id into it, runs the command and removes it, whatever the
# command's status; a killed holder leaves it behind under a dead id. A
# waiter tries every 0.1 seconds for at most 5 seconds, then refuses. It
# breaks the folder at once when the id names no live process, and when the
# folder is over 60 seconds old, which no writer holds it for (the id was
# reused by another process, or never written). A missing or empty id proves
# nothing: the holder writes it just after its mkdir. The age costs a
# process, so it is read once per second of the wait.
#
# Two waiters can judge the same folder stale. When the first has removed it
# and a writer has made a new one, the second's rm removes that one. A
# breaker therefore sleeps before its next mkdir like any waiter, so that a
# second breaker's rm, one process start behind its look, lands before the
# breaker's own mkdir. That narrows the window; it does not close it. A
# writer that is not breaking can make its folder between the two removals
# and lose it, and so can a breaker whose sleep is shorter than the other's
# process start.
with_lock_dir() { # lock command...
    local lock="$1" start=$SECONDS tries=0 seen='' aged_at='' pid status
    shift
    while ! mkdir "$lock" 2>/dev/null; do
        if [ -d "$lock" ]; then
            seen=1
            pid=''
            { read -r pid < "$lock/pid"; } 2>/dev/null
            case $pid in
                ''|0*|*[!0123456789]*) ;;   # no usable id: the age decides
                *) kill -0 "$pid" 2>/dev/null || { rm -rf "$lock"; pid=broken; } ;;
            esac
            if [ "$pid" != broken ] && [ "$aged_at" != "$SECONDS" ]; then
                aged_at=$SECONDS
                find "$lock" -prune -mmin +1 -exec rm -rf {} \; 2>/dev/null
            fi
        elif [ ! -w "${lock%/*}" ]; then
            # No folder, yet mkdir failed: released just now, or the state
            # folder cannot take one (no write permission, read-only, gone).
            # The second is no other writer: unlocked, as without a state
            # folder.
            "$@"; return
        fi
        # SECONDS ends the wait; the count ends it too if the clock steps back.
        tries=$((tries + 1))
        if [ "$tries" -ge 50 ] || [ $((SECONDS - start)) -ge 5 ]; then
            # A folder never seen in the whole wait was no other writer, but
            # a mkdir that failed for another reason (a file in its place, a
            # full disk): unlocked, rather than blame a writer.
            [ -n "$seen" ] || { "$@"; return; }
            echo "$LOCKED_MSG" >&2
            return 1
        fi
        sleep 0.1
    done
    { printf '%s\n' "$$" > "$lock/pid"; } 2>/dev/null
    "$@"
    status=$?
    # Removed while it holds this writer's id, or none (the write failed, a
    # full disk). A folder naming another id was broken while the command
    # ran (held past 60 seconds, a suspended machine) and is another
    # writer's now; a new holder that has not written its id yet still looks
    # like none.
    pid=''
    { read -r pid < "$lock/pid"; } 2>/dev/null
    case $pid in ''|"$$") rm -rf "$lock" ;; esac
    return "$status"
}

append_note() {
    local file="$1" line="$2"
    [ -f "$file" ] || printf '%s\n\n' "$NOTE_HEADING" > "$file"
    # A hand-edited file may lack its final newline; do not glue two notes.
    [ -n "$(tail -c1 "$file")" ] && printf '\n' >> "$file"
    printf -- '- [ ] %s\n' "$line" >> "$file"
}

cmd_add() {
    local note file
    note=$(printf '%s' "$*" | tr '\n\r\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
    if [ -z "$note" ]; then
        echo 'later: nothing to park (empty note)'
        return 0
    fi
    file=$(queue_file "$PWD") || { echo 'later: cannot resolve the queue here' >&2; return 1; }
    # Without a readable clock the note is parked undated rather than lost.
    with_lock "$file" append_note "$file" "$note${NOW_STAMP:+ ($NOW_STAMP)}" || return 1
    echo "later: parked -> $note"
}

cmd_list() {
    local file rows
    file=$(queue_file "$PWD") || { echo 'later: no parked notes'; return 0; }
    rows=$(open_notes "$file")
    if [ -z "$rows" ]; then
        echo 'later: no parked notes'
        return 0
    fi
    printf '%s: %s parked\n' "$(queue_label "$file")" "$(row_count "$rows")"
    printf '%s\n' "$rows" | numbered
}

# The open notes for programs: "queue\t<label>", then one
# "note\t<position>\t<age>\t<text>" per open note. The text runs to the end
# of the line and may hold tabs. No queue file: the queue line alone.
cmd_rows() {
    local file i n mins text
    file=$(queue_file "$PWD") || { echo 'later: cannot resolve the queue here' >&2; return 1; }
    printf 'queue\t%s\n' "$(queue_label "$file")"
    while IFS=$'\t' read -r i n mins text; do
        age_label "$mins"
        printf 'note\t%s\t%s\t%s\n' "$i" "$REPLY" "$text"
    done < <(open_notes "$file")
}

# close_notes <mode> <file> [--if <text>] <n>...
# With --if, note <n> must still be exactly <text> under the lock; a note
# that changed or vanished since a program listed it is refused before any
# temporary file exists. The rewrite changes only the lines it closes: done
# turns the first [ ] into [x] and keeps the rest, a carriage return or a
# byte-order mark included; drop removes the whole line. Every other line is
# copied with the bytes it was read with. A queue saved without a final line
# end keeps none: awk holds each line back until it has read the next, and
# writes the file's last line without a newline when the file had none and
# that line is kept. A line that a dropped last line followed keeps its own
# line end. The last byte costs one process, whatever the queue's size.
# cp -p gives the temporary file the queue's mode before the new content
# goes into it (chmod --reference, which did that after, is GNU only), so a
# queue its owner cannot write is refused here, as append_note refuses it.
close_notes() {
    local mode="$1" file="$2"; shift 2
    local guarded='' expect='' rows count n lines tmp verb target dir text ended
    if [ "${1:-}" = '--if' ]; then
        guarded=1; expect="${2-}"; shift 2
    fi
    # Rewrite beside the real file, so a symlinked queue stays a symlink.
    # real_path may run in this shell (the folder lock), and it goes back to
    # this folder; nothing below or after this function reads a relative
    # path, since the queue path from queue_file is absolute.
    target=$file
    real_path "$file" && target=$REPLY
    # The temporary file takes a short name of its own: the queue's name plus
    # a suffix would pass the 255-byte limit of a name for a queue name of
    # 249 bytes or more, which usable_queue_name accepts. A target without a
    # folder part is in the current folder.
    case $target in
        */*) dir=${target%/*} ;;
        *) dir=. ;;
    esac
    rows=$(open_notes "$file")
    count=$(row_count "$rows")
    for n in "$@"; do
        case "$n" in
            ''|*[!0123456789]*|??????????*) echo "later: not a note number: $n" >&2; return 1 ;;
        esac
        if [ -n "$guarded" ] && { ! text=$(row_text "$rows" "$((10#$n))") || [ "$text" != "$expect" ]; }; then
            echo "later: note $n changed since it was listed; nothing changed" >&2
            return 1
        fi
        if [ "$n" -lt 1 ] || [ "$n" -gt "$count" ]; then
            echo "later: no note $n (the queue has $count open)" >&2
            return 1
        fi
    done
    lines=$(for n in "$@"; do
        printf '%s\n' "$rows" | awk -F'\t' -v i="$n" '$1 == i + 0 { print $2 }'
    done | sort -un | tr '\n' ' ')
    tmp=$(mktemp "$dir/.later-queue.XXXXXX") || { echo 'later: cannot write beside the queue' >&2; return 1; }
    # 1 when the file ends in a newline; the substitution drops that newline.
    ended=1
    [ -n "$(tail -c1 "$target")" ] && ended=0
    if cp -p "$target" "$tmp" && awk -v lines="$lines" -v mode="$mode" -v ended="$ended" '
            BEGIN { split(lines, a, " "); for (k in a) pick[a[k]] = 1 }
            (NR in pick) { if (mode == "drop") next; sub(/\[[[:space:]]\]/, "[x]") }
            { if (held) print kept; kept = $0; kept_nr = NR; held = 1 }
            END { if (held) printf "%s%s", kept, ((ended == 1 || kept_nr < NR) ? "\n" : "") }
        ' "$target" > "$tmp" && mv "$tmp" "$target"; then
        verb='done'; [ "$mode" = drop ] && verb='dropped'
        for n in "$@"; do
            printf 'later: %s -> %s\n' "$verb" "$(row_text "$rows" "$((10#$n))")"
        done
    else
        rm -f "$tmp"
        echo 'later: could not rewrite the queue, nothing changed' >&2
        return 1
    fi
}

cmd_close() {
    local mode="$1" file; shift
    [ $# -gt 0 ] || { echo "later: $mode needs at least one note number" >&2; return 1; }
    if [ "$1" = '--if' ] && [ $# -ne 3 ]; then
        echo 'later: --if takes exactly one note number' >&2
        return 1
    fi
    file=$(queue_file "$PWD") || { echo 'later: cannot resolve the queue here' >&2; return 1; }
    [ -f "$file" ] || { echo 'later: no parked notes' >&2; return 1; }
    with_lock "$file" close_notes "$mode" "$file" "$@"
}

# Every path under the scan roots named like the queue that is a file or a
# symbolic link. Which links are queues is the reader's test, [ -f ], which
# follows them: a link to a regular file is one, a dangling link or a link
# to a folder is none. (find -xtype f made that test, in GNU find only.)
find_queues() {
    local roots="${LATER_ROOTS:-$HOME}" root
    local IFS=':'
    for root in $roots; do
        [ -d "$root" ] || continue
        find "$root" -maxdepth "$SCAN_DEPTH" \
            \( -name node_modules -o -name vendor -o -name .git -o -name .worktrees \) -prune \
            -o \( -type f -o -type l \) -name "$QUEUE_NAME" -print 2>/dev/null
    done | sort -u
}

cmd_all() {
    local file rows count oldest label path out='' total=0 queues=0
    while IFS= read -r file; do
        [ -f "$file" ] || continue
        rows=$(open_notes "$file")
        [ -n "$rows" ] || continue
        count=$(row_count "$rows")
        oldest=$(printf '%s\n' "$rows" | cut -f3 | sort -n | head -n1)
        age_label "$oldest"; label=$REPLY
        path=$(dirname "$file")
        case "$path" in "$HOME"*) path="~${path#"$HOME"}" ;; esac
        out+=$(printf '%s\t%s\t%s' "$count" "$label" "$path")$'\n'
        total=$((total + count)); queues=$((queues + 1))
    done < <(find_queues)
    if [ "$queues" -eq 0 ]; then
        echo 'later: no parked notes'
        return 0
    fi
    printf '%s' "$out" | sort -t$'\t' -k1,1nr -k3,3 | while IFS=$'\t' read -r count label path; do
        printf '%3d open, oldest %-8s  %s\n' "$count" "$label" "$path"
    done
    printf '%3d open in %d queues\n' "$total" "$queues"
}

# --- JSON, without jq --------------------------------------------------
# The hook reads its input and writes its output in plain bash: no process
# per character, and the same bytes out under a UTF-8 or a C locale. Every
# delimiter the code looks for is ASCII, which never occurs inside a UTF-8
# multibyte character, and a ${s:n} offset only ever skips ASCII text.
# Replacements sit in quoted variables in an unquoted assignment, which
# bash 3.2, 4 and 5.2 (patsub_replacement) all read literally.

JSON_WS=$' \t\n\r'
# The bytes 0x01 to 0x1f, which a string literal holds only escaped. Listed,
# like the next two, because a class or a range in a bracket follows the
# locale ([[:cntrl:]] also holds DEL, and U+0080 to U+009F under UTF-8).
JSON_CTL=$'\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037'
JSON_HEX='0123456789ABCDEFabcdef'
JSON_BARE='0123456789.eE+trufalsn-'   # every character of a number or literal
JSON_BARE_RE='^(true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?)$'

# Sets REPLY to <text> as a JSON string literal, quotes included: " and \
# escaped, \b \f \n \r \t for those controls, \u00XX for the other bytes
# below 0x20, every other byte unchanged.
json_string() { # text
    local s=$1 bs=\\ q='"' i=1 c e
    s=${s//"$bs"/"$bs$bs"}
    s=${s//"$q"/"$bs$q"}
    case $s in *["$JSON_CTL"]*)
        while [ "$i" -le 31 ]; do
            c=${JSON_CTL:i-1:1}
            case $s in *"$c"*)
                case $i in
                    8) e='\b' ;; 9) e='\t' ;; 10) e='\n' ;; 12) e='\f' ;; 13) e='\r' ;;
                    *) printf -v e '\\u%04x' "$i" ;;
                esac
                s=${s//"$c"/"$e"} ;;
            esac
            i=$((i + 1))
        done
    esac
    REPLY=$q$s$q
}

# Consumes the string literal at the start of the caller's $s, which begins
# with its opening quote, and sets REPLY to its decoded value. \uXXXX is
# written as UTF-8, a surrogate pair as one character, a lone surrogate as
# U+FFFD; \u0000 is dropped, as $(jq -r ...) dropped it in 0.1.0. Fails on
# an unterminated literal, an unknown escape or a raw control character.
json_take_string() {
    local out='' chunk e hex cp lo
    s=${s:1}
    while :; do
        # The text up to the next quote or backslash; none: unterminated.
        chunk=${s%%[\"\\]*}
        [ "$chunk" != "$s" ] || return 1
        case $chunk in *["$JSON_CTL"]*) return 1 ;; esac
        out+=$chunk
        s=${s#"$chunk"}
        if [ "${s:0:1}" = '"' ]; then
            s=${s:1}
            break
        fi
        e=${s:1:1}
        case $e in
            \"|\\|/) out+=$e ;;
            b) out+=$'\b' ;;
            f) out+=$'\f' ;;
            n) out+=$'\n' ;;
            r) out+=$'\r' ;;
            t) out+=$'\t' ;;
            u) ;;
            *) return 1 ;;
        esac
        if [ "$e" != u ]; then
            s=${s:2}
            continue
        fi
        hex=${s:2:4}
        case $hex in [$JSON_HEX][$JSON_HEX][$JSON_HEX][$JSON_HEX]) ;; *) return 1 ;; esac
        cp=$((16#$hex)); s=${s:6}
        if [ "$cp" -ge 55296 ] && [ "$cp" -le 57343 ]; then
            # A high surrogate (D800 to DBFF) followed by a low one (DC00 to
            # DFFF) is one character above U+FFFF.
            hex=${s:2:4}
            case ${s:0:2}$hex in
                '\u'[dD][cdefCDEF][$JSON_HEX][$JSON_HEX]) lo=$((16#$hex)) ;;
                *) lo=0 ;;
            esac
            if [ "$cp" -le 56319 ] && [ "$lo" -ne 0 ]; then
                cp=$(( 65536 + ((cp - 55296) << 10) + (lo - 56320) )); s=${s:6}
            else
                cp=65533
            fi
        fi
        if [ "$cp" -eq 0 ]; then
            continue
        elif [ "$cp" -lt 128 ]; then
            printf -v e '\\%03o' "$cp"
        elif [ "$cp" -lt 2048 ]; then
            printf -v e '\\%03o\\%03o' $(( 192 | (cp >> 6) )) $(( 128 | (cp & 63) ))
        elif [ "$cp" -lt 65536 ]; then
            printf -v e '\\%03o\\%03o\\%03o' $(( 224 | (cp >> 12) )) $(( 128 | ((cp >> 6) & 63) )) $(( 128 | (cp & 63) ))
        else
            printf -v e '\\%03o\\%03o\\%03o\\%03o' $(( 240 | (cp >> 18) )) $(( 128 | ((cp >> 12) & 63) )) \
                $(( 128 | ((cp >> 6) & 63) )) $(( 128 | (cp & 63) ))
        fi
        # shellcheck disable=SC2059  # the format is the octal escapes
        printf -v e "$e"
        out+=$e
    done
    REPLY=$out
}

# Sets REPLY to the decoded value of the top-level string member <key> of
# <json>; empty when <key> is absent or its value is not a string, or when
# <json> is not one well-formed JSON object. Members of nested objects and
# arrays are skipped, never matched. A key given twice takes its last value,
# as jq did in 0.1.0. Fails whenever REPLY is empty for one of those reasons.
json_field() { # json key
    local s=$1 key=$2 stack='' want=value name='' hit='' found='' closed='' w t
    # stack holds the closer of each open object (}) or array (]); want is
    # the token the grammar allows next. Any token it does not allow ends the
    # scan with closed unset.
    w=${s%%[!"$JSON_WS"]*}; s=${s#"$w"}
    [ "${s:0:1}" = '{' ] || s=''
    while [ -n "$s" ]; do
        t=${s:0:1}
        case $want:$t in
            value:'{'|value:'['|first_value:'{'|first_value:'[')
                [ "$stack" = '}' ] && [ "$name" = "$key" ] && hit=''
                if [ "$t" = '{' ]; then stack+='}'; want=first_key; else stack+=']'; want=first_value; fi
                s=${s:1} ;;
            first_key:'}'|first_value:']'|after_value:'}'|after_value:']')
                [ "${stack#"${stack%?}"}" = "$t" ] || break
                stack=${stack%?}; s=${s:1}; want=after_value
                if [ -z "$stack" ]; then
                    # The top-level object is closed: only whitespace may follow.
                    w=${s%%[!"$JSON_WS"]*}; s=${s#"$w"}
                    [ -z "$s" ] && closed=1
                    break
                fi ;;
            after_key:':')
                s=${s:1}; want=value ;;
            after_value:',')
                s=${s:1}
                if [ "${stack#"${stack%?}"}" = '}' ]; then want=key; else want=value; fi ;;
            first_key:'"'|key:'"')
                json_take_string || break
                name=$REPLY; want=after_key ;;
            value:'"'|first_value:'"')
                json_take_string || break
                if [ "$stack" = '}' ] && [ "$name" = "$key" ]; then hit=1; found=$REPLY; fi
                want=after_value ;;
            value:*|first_value:*)
                t=${s%%[!"$JSON_BARE"]*}
                [[ $t =~ $JSON_BARE_RE ]] || break
                [ "$stack" = '}' ] && [ "$name" = "$key" ] && hit=''
                s=${s#"$t"}; want=after_value ;;
            *)
                break ;;
        esac
        w=${s%%[!"$JSON_WS"]*}; s=${s#"$w"}
    done
    if [ -n "$closed" ] && [ -n "$hit" ]; then
        REPLY=$found
        return 0
    fi
    REPLY=''
    return 1
}

# How the display reaches the user. Kept in one place: it is the only line
# that changes if the message has to go into model context instead.
emit() { json_string "$1"; printf '{"systemMessage":%s}\n' "$REPLY"; }

# Sets REPLY to <text> as a number, base 10 forced (a hand-edited "08" is not
# octal, and "010" is ten), or to 0, failing, when <text> is not all digits.
num_or_zero() { case "$1" in ''|*[!0123456789]*) REPLY=0; return 1 ;; *) REPLY=$((10#$1)) ;; esac; }

# True when <link> is a symbolic link whose text names `later` in the folder
# <bin>. Folders are compared with -ef, so a text reaching <bin> through
# another path counts; a relative text is read against the link's folder.
is_own_link() { # link bin
    local link="$1" bin="$2" text dir
    [ -L "$link" ] || return 1
    text=$(readlink "$link") || return 1
    [ "$(basename "$text")" = later ] || return 1
    dir=$(dirname "$text")
    case "$dir" in /*) ;; *) dir="$(dirname "$link")/$dir" ;; esac
    [ "$dir" -ef "$bin" ]
}

# The terminal link step: keeps ~/.local/bin/later -> <data>/bin/later ->
# <plugin root>/scripts/later, and prints zero or more notice lines. Any
# failed command ends it silently; it always returns 0.
#   link condition   own, refused or off
#   PATH condition   missing when the link is own and ~/.local/bin is not
#                    on PATH, else ok
# <data>/terminal-state holds the two conditions last seen, so the refused
# and PATH notices print when their condition starts, not while it lasts.
terminal_link() {
    [ -n "${CLAUDE_PLUGIN_DATA:-}" ] || return 0
    case "$(uname -s)" in Linux|Darwin) ;; *) return 0 ;; esac
    local root data user tmp link path_state state seen_link='' seen_path=''
    # The script's own resolved location, never CLAUDE_PLUGIN_ROOT, which a
    # hook of another plugin can inherit. Its folder is physical, so the
    # folder above it is the plugin root. This step runs in a command
    # substitution, so the folders real_path enters are left with it.
    real_path "${BASH_SOURCE[0]}" || return 0
    root=${REPLY%/*}; root=${root%/*}
    # Spec R5.7: no link to a front-end that is missing or cannot run.
    [ -f "$root/scripts/later" ] && [ -x "$root/scripts/later" ] || return 0
    data=$CLAUDE_PLUGIN_DATA
    user="$HOME/.local/bin/later"

    # The data link, replaced by a rename so it is never missing or
    # half-written, also when two sessions start at once. mv without -T
    # (GNU only) moves into a folder when the destination is one or links to
    # one: a link to a folder there is removed first, and a folder ends the
    # step. A folder that appears between that check and the rename catches
    # the temporary link, which is then taken out of it. The front-end above
    # is a file, so the link this makes is never a link to a folder.
    if [ "$(readlink "$data/bin/later")" != "$root/scripts/later" ]; then
        mkdir -p "$data/bin" || return 0
        if [ -d "$data/bin/later" ]; then
            [ -L "$data/bin/later" ] || return 0
            rm -f "$data/bin/later" || return 0
        fi
        tmp="$data/bin/.later.tmp.$$.$NOW_EPOCH"
        ln -s "$root/scripts/later" "$tmp" || return 0
        mv -f "$tmp" "$data/bin/later" || { rm -f "$tmp"; return 0; }
        if [ -d "$data/bin/later" ]; then
            rm -f "$data/bin/later/${tmp##*/}"
            return 0
        fi
    fi

    if [ "${CLAUDE_PLUGIN_OPTION_TERMINAL:-}" = off ]; then
        link=off
        # No -f: of two sessions removing the link at once, one announces it.
        if is_own_link "$user" "$data/bin"; then
            rm "$user" || return 0
            printf '%s\n' "$NOTICE_REMOVED"
        fi
    elif is_own_link "$user" "$data/bin"; then
        link=own
    elif [ ! -e "$user" ] && [ ! -L "$user" ]; then
        mkdir -p "$HOME/.local/bin" || return 0
        # No -f: when another session made the link first, ln fails and the
        # link is read again.
        if ln -s "$data/bin/later" "$user"; then
            printf '%s\n' "$NOTICE_ADDED"
            link=own
        elif is_own_link "$user" "$data/bin"; then
            link=own
        else
            link=refused
        fi
    else
        link=refused
    fi

    path_state=ok
    if [ "$link" = own ]; then
        case ":$PATH:" in
            *":$HOME/.local/bin:"*|*":$HOME/.local/bin/:"*) ;;
            *) path_state=missing ;;
        esac
    fi

    state="$data/terminal-state"
    { IFS= read -r seen_link; IFS= read -r seen_path; } 2>/dev/null < "$state"
    if [ "$link" = refused ] && [ "$seen_link" != refused ]; then
        printf '%s\n' "$NOTICE_REFUSED"
    fi
    if [ "$path_state" = missing ] && [ "$seen_path" != missing ]; then
        printf '%s\n' "$NOTICE_PATH"
    fi
    if [ "$link" != "$seen_link" ] || [ "$path_state" != "$seen_path" ]; then
        { printf '%s\n%s\n' "$link" "$path_state" > "$state"; } 2>/dev/null
    fi
    return 0
}

cmd_session_start() {
    local input='' cwd src agent file rows='' count sf='' l1='' l2='' l3='' shown digest floor msg='' notices bad
    # The whole input, by the read builtin: no process. read fails at the end
    # of the input, which is where it stops.
    IFS= read -r -d '' input
    json_field "$input" cwd; cwd=$REPLY
    json_field "$input" source; src=$REPLY
    json_field "$input" agent_id; agent=$REPLY
    [ -n "$cwd" ] && [ "$src" = 'startup' ] && [ -z "$agent" ] || return 0
    [ "${CLAUDE_CODE_ENTRYPOINT:-}" = 'cli' ] || return 0

    # The count line: empty for a missing directory, no queue file or no
    # open notes.
    file=$(queue_file "$cwd") && rows=$(open_notes "$file")
    if [ -n "$rows" ]; then
        count=$(row_count "$rows")

        mkdir -p "$STATE_DIR" 2>/dev/null
        state_key "$file"; sf="$STATE_DIR/$REPLY"
        # The state: the epoch of the last display, the epoch of the last
        # list of oldest notes, and the local minute of the last display,
        # which a 0.1.0 state lacks. Missing or unreadable: never shown.
        { IFS= read -r l1; IFS= read -r l2; IFS= read -r l3; } 2>/dev/null < "$sf"
        num_or_zero "$l1"; shown=$REPLY
        num_or_zero "$l2"; digest=$REPLY

        # New = stamped at or after the MINUTE of the last display. Stamps
        # have minute precision, so comparing against the exact second would
        # skip a note parked later in the same minute as a display. Without
        # the third line, that minute is the one the display's epoch fell in,
        # counted back from the clock in whole minutes.
        if num_or_zero "$l3"; then
            floor=$REPLY
        else
            floor=$(( NOW_MIN - (NOW_EPOCH / 60 - shown / 60) ))
        fi
        local new new_count
        new=$(printf '%s\n' "$rows" | awk -F'\t' -v f="$floor" '$3 != 0 && $3 >= f')
        new_count=$(row_count "$new")

        msg="later: $count parked in $(queue_label "$file")"
        if [ "$new_count" -gt 0 ]; then
            local names='' text
            while IFS=$'\t' read -r _ _ _ text; do
                clip "$text" "$DISPLAY_WIDTH"
                names+="${names:+; }$REPLY"
            done < <(printf '%s\n' "$new" | head -n3)
            msg+=", $new_count new: $names"
            [ "$new_count" -gt 3 ] && msg+=", +$((new_count - 3)) more"
        fi

        if [ $(( NOW_EPOCH - digest )) -ge $(( DIGEST_DAYS * 86400 )) ]; then
            msg+=$'\n'"Oldest notes:"$'\n'
            msg+=$(printf '%s\n' "$rows" | sort -s -t$'\t' -k3,3n | head -n "$DIGEST_COUNT" | numbered "$DISPLAY_WIDTH")
            digest=$NOW_EPOCH
        fi
    fi

    # The notices follow the count line, one per line, in the same message.
    # An unusable laterbox.file comes last, at every start while it is set;
    # a control character in it shows as ?, keeping the notice one line.
    notices=$(terminal_link)
    if [ -n "${QUEUE_NAME_REJECTED+set}" ]; then
        # shellcheck disable=SC2059  # NOTICE_BAD_NAME is the format
        printf -v bad "$NOTICE_BAD_NAME" "${QUEUE_NAME_REJECTED//[[:cntrl:]]/?}" "$QUEUE_NAME"
        notices+="${notices:+$'\n'}$bad"
    fi
    [ -n "$msg" ] && [ -n "$notices" ] && msg+=$'\n'
    msg+=$notices
    [ -n "$msg" ] || return 0

    emit "$msg"
    # The count state, only when a count line was shown, and only with a
    # clock: a display recorded at minute 0 would make every note new again.
    [ -n "$sf" ] && [ -n "$NOW_STAMP" ] && { printf '%s\n%s\n%s\n' "$NOW_EPOCH" "$digest" "$NOW_MIN" > "$sf"; } 2>/dev/null
    return 0
}

usage() {
    echo 'usage: later.sh {add <note> | list | rows | done [--if <text>] <n>... | drop [--if <text>] <n>... | all | session-start}'
}

# Before the dispatch, so session-start stores the setting before any of its
# early exits. Silent: the session-start path writes nothing to stderr.
resolve_queue_name "${1:-}" 2>/dev/null
load_clock 2>/dev/null

case "${1:-}" in
    add)           shift; cmd_add "$@" ;;
    list)          cmd_list ;;
    rows)          cmd_rows ;;
    done|drop)     cmd_close "$@" ;;
    all)           cmd_all ;;
    # A subshell: an expansion error discards the whole top-level command,
    # which would skip the exit 0; inside a subshell it ends only the
    # subshell. The handler writes stdout only through emit, once the
    # message is complete, so a failure leaves no display or the whole one.
    session-start) ( cmd_session_start ) 2>/dev/null; exit 0 ;;
    *)             usage >&2; exit 1 ;;
esac
