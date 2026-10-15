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

# LATER_NOW (epoch seconds) replaces the clock, for tests.
now() { printf '%s' "${LATER_NOW:-$(date +%s)}"; }
# LATER_NO_FLOCK=1 makes with_lock take its lock folder where flock exists,
# for tests: the lock of machines without flock (macOS, Git Bash).

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
    [ "${bytes//[!0-9]/}" -le 255 ]
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

# Root of the main checkout containing <dir>, or nothing outside a work tree.
# A linked worktree resolves to the main checkout through the common git dir.
project_root() {
    local dir="$1" top gitdir common
    top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
    gitdir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 0
    common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
    if [ "$gitdir" != "$common" ]; then
        dirname "$common"
    else
        printf '%s\n' "$top"
    fi
}

# Queue file for <dir>. $HOME is itself a git repository on a dotfiles setup,
# so a root equal to $HOME is discarded unless <dir> is $HOME; otherwise every
# directory under it without a repository of its own would share one queue.
queue_file() {
    local dir home root
    dir=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    home=$(cd "$HOME" 2>/dev/null && pwd -P)
    root=$(project_root "$dir")
    if [ -n "$root" ] && [ "$root" = "$home" ] && [ "$dir" != "$home" ]; then
        root=''
    fi
    printf '%s/%s\n' "${root:-$dir}" "$QUEUE_NAME"
}

queue_label() { basename "$(dirname "$1")"; }

state_key() { printf '%s' "$1" | sha1sum | cut -d' ' -f1; }

# One row per open note: "<position>\t<file line>\t<stamp epoch>\t<text>".
# The epoch is 0 for an undated note; the stamp is stripped from the text.
open_notes() {
    local file="$1" i=0 raw n text epoch
    [ -f "$file" ] || return 0
    while IFS= read -r raw; do
        n=${raw%%:*}
        [[ ${raw#*:} =~ $OPEN_RE ]] || continue
        text=${BASH_REMATCH[1]}
        epoch=0
        if [[ $text =~ $STAMP_RE ]]; then
            epoch=$(date -d "${BASH_REMATCH[1]}" +%s 2>/dev/null) || epoch=0
            [ "$epoch" != 0 ] && text=${text:0:${#text}-STAMP_LEN}
        fi
        i=$((i + 1))
        printf '%s\t%s\t%s\t%s\n' "$i" "$n" "$epoch" "$text"
    done < <(grep -nE "$OPEN_RE" "$file")
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

age_label() {
    local epoch="$1" days
    [ "$epoch" = 0 ] && { printf 'undated'; return; }
    days=$(( ($(now) - epoch) / 86400 ))
    if [ "$days" -le 0 ]; then printf 'today'; else printf '%sd' "$days"; fi
}

# Clip <text> to <width> characters, marking the cut with "...".
clip() {
    local text="$1" width="$2"
    if [ "${#text}" -gt "$width" ]; then
        printf '%s...' "${text:0:width-3}"
    else
        printf '%s' "$text"
    fi
}

# Rows on stdin -> " N. text (age)", N being the note's position in the queue.
# With a width, each text is clipped to it.
numbered() {
    local width="${1:-}" i n epoch text
    while IFS=$'\t' read -r i n epoch text; do
        [ -n "$width" ] && text=$(clip "$text" "$width")
        printf '%2d. %s (%s)\n' "$i" "$text" "$(age_label "$epoch")"
    done
}

# Run a command holding the queue's lock, and return its status: by flock
# where it exists, else by the lock folder of with_lock_dir. Without a state
# folder there is nowhere to lock, and the command runs unlocked.
with_lock() {
    local file="$1"; shift
    mkdir -p "$STATE_DIR" 2>/dev/null
    [ -d "$STATE_DIR" ] || { "$@"; return; }
    if [ "${LATER_NO_FLOCK:-}" != 1 ] && command -v flock >/dev/null 2>&1; then
        (
            flock -w 5 9 || { echo "$LOCKED_MSG" >&2; exit 1; }
            "$@"
        ) 9>"$STATE_DIR/$(state_key "$file").lock"
    else
        with_lock_dir "$STATE_DIR/$(state_key "$file").lock.d" "$@"
    fi
}

# The lock where flock is missing: the folder <lock>, which mkdir makes or
# refuses in one step on every platform. The holder writes its process id
# into it, runs the command and removes it, whatever the command's status; a
# killed holder leaves it behind under a dead id. A waiter tries every 0.1
# seconds for at most 5 seconds, then refuses. It breaks the folder at once
# when the id names no live process, and when the folder is over 60 seconds
# old, which no writer holds it for (the id was reused by another process,
# or never written). A missing or empty id proves nothing: the holder writes
# it just after its mkdir. The age costs a process, so it is read once per
# second of the wait.
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
                ''|0*|*[!0-9]*) ;;   # no usable id: the age decides
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
    local note file stamp
    note=$(printf '%s' "$*" | tr '\n\r\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
    if [ -z "$note" ]; then
        echo 'later: nothing to park (empty note)'
        return 0
    fi
    file=$(queue_file "$PWD") || { echo 'later: cannot resolve the queue here' >&2; return 1; }
    stamp=$(date -d "@$(now)" '+%Y-%m-%d %H:%M')
    with_lock "$file" append_note "$file" "$note ($stamp)" || return 1
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
    local file i n epoch text
    file=$(queue_file "$PWD") || { echo 'later: cannot resolve the queue here' >&2; return 1; }
    printf 'queue\t%s\n' "$(queue_label "$file")"
    while IFS=$'\t' read -r i n epoch text; do
        printf 'note\t%s\t%s\t%s\n' "$i" "$(age_label "$epoch")" "$text"
    done < <(open_notes "$file")
}

# close_notes <mode> <file> [--if <text>] <n>...
# With --if, note <n> must still be exactly <text> under the lock; a note
# that changed or vanished since a program listed it is refused before any
# temporary file exists.
close_notes() {
    local mode="$1" file="$2"; shift 2
    local guarded='' expect='' rows count n lines tmp verb target text
    if [ "${1:-}" = '--if' ]; then
        guarded=1; expect="${2-}"; shift 2
    fi
    # Rewrite beside the real file, so a symlinked queue stays a symlink.
    target=$(readlink -f "$file" 2>/dev/null) || target=$file
    rows=$(open_notes "$file")
    count=$(row_count "$rows")
    for n in "$@"; do
        case "$n" in
            ''|*[!0-9]*|??????????*) echo "later: not a note number: $n" >&2; return 1 ;;
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
    tmp=$(mktemp "$target.XXXXXX") || { echo 'later: cannot write beside the queue' >&2; return 1; }
    if awk -v lines="$lines" -v mode="$mode" '
            BEGIN { split(lines, a, " "); for (k in a) pick[a[k]] = 1 }
            (NR in pick) { if (mode == "drop") next; sub(/\[[[:space:]]\]/, "[x]") }
            { print }
        ' "$target" > "$tmp" && chmod --reference="$target" "$tmp" && mv "$tmp" "$target"; then
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

find_queues() {
    local roots="${LATER_ROOTS:-$HOME}" root
    local IFS=':'
    for root in $roots; do
        [ -d "$root" ] || continue
        find "$root" -maxdepth "$SCAN_DEPTH" \
            \( -name node_modules -o -name vendor -o -name .git -o -name .worktrees \) -prune \
            -o -xtype f -name "$QUEUE_NAME" -print 2>/dev/null
    done | sort -u
}

cmd_all() {
    local file rows count oldest label path out='' total=0 queues=0
    while IFS= read -r file; do
        rows=$(open_notes "$file")
        [ -n "$rows" ] || continue
        count=$(row_count "$rows")
        oldest=$(printf '%s\n' "$rows" | cut -f3 | sort -n | head -n1)
        label=$(age_label "$oldest")
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

# Base 10 forced: a hand-edited "08" is not octal, and "010" is ten.
num_or_zero() { case "$1" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$((10#$1))" ;; esac; }

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
    # hook of another plugin can inherit.
    root=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P) || return 0
    data=$CLAUDE_PLUGIN_DATA
    user="$HOME/.local/bin/later"

    # The data link, replaced by a rename so it is never missing or
    # half-written, also when two sessions start at once.
    if [ "$(readlink "$data/bin/later")" != "$root/scripts/later" ]; then
        mkdir -p "$data/bin" || return 0
        tmp="$data/bin/.later.tmp.$$.$(now)"
        ln -s "$root/scripts/later" "$tmp" || return 0
        mv -fT "$tmp" "$data/bin/later" || { rm -f "$tmp"; return 0; }
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
    local input='' cwd src agent file rows='' count sf='' shown=0 digest=0 t floor msg='' notices bad
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
        sf="$STATE_DIR/$(state_key "$file")"
        if [ -r "$sf" ]; then
            shown=$(num_or_zero "$(sed -n 1p "$sf")")
            digest=$(num_or_zero "$(sed -n 2p "$sf")")
        fi
        t=$(now)

        # New = stamped at or after the MINUTE of the last display. Stamps
        # have minute precision, so comparing against the exact second would
        # skip a note parked later in the same minute as a display.
        floor=$(( shown - shown % 60 ))
        local new new_count
        new=$(printf '%s\n' "$rows" | awk -F'\t' -v f="$floor" '$3 != 0 && $3 >= f')
        new_count=$(row_count "$new")

        msg="later: $count parked in $(queue_label "$file")"
        if [ "$new_count" -gt 0 ]; then
            local names='' text
            while IFS=$'\t' read -r _ _ _ text; do
                names+="${names:+; }$(clip "$text" "$DISPLAY_WIDTH")"
            done < <(printf '%s\n' "$new" | head -n3)
            msg+=", $new_count new: $names"
            [ "$new_count" -gt 3 ] && msg+=", +$((new_count - 3)) more"
        fi

        if [ $(( t - digest )) -ge $(( DIGEST_DAYS * 86400 )) ]; then
            msg+=$'\n'"Oldest notes:"$'\n'
            msg+=$(printf '%s\n' "$rows" | sort -s -t$'\t' -k3,3n | head -n "$DIGEST_COUNT" | numbered "$DISPLAY_WIDTH")
            digest=$t
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
    # The count state, only when a count line was shown.
    [ -n "$sf" ] && { printf '%s\n%s\n' "$t" "$digest" > "$sf"; } 2>/dev/null
    return 0
}

usage() {
    echo 'usage: later.sh {add <note> | list | rows | done [--if <text>] <n>... | drop [--if <text>] <n>... | all | session-start}'
}

# Before the dispatch, so session-start stores the setting before any of its
# early exits. Silent: the session-start path writes nothing to stderr.
resolve_queue_name "${1:-}" 2>/dev/null

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
