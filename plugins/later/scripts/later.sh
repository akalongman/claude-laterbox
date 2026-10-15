#!/usr/bin/env bash
#
# later.sh: parking lot for follow-up notes, kept as a per-project backlog.
#
#   add <note>       append a stamped note to the project's NOTES.local.md
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
# The hook owns WHEN (hooks/hooks.json fires this on session start); this
# script owns WHAT. No `set -e`: the hook path must exit 0 whatever happens,
# so a broken reminder can never delay or block a session.

NOTES_FILE_NAME='NOTES.local.md'
# shellcheck disable=SC2016  # the backticks are literal markdown
NOTE_HEADING='# Parked notes (`/later`)'

DIGEST_DAYS="${LATER_DIGEST_DAYS:-7}"
DIGEST_COUNT="${LATER_DIGEST_COUNT:-5}"
DISPLAY_WIDTH="${LATER_DISPLAY_WIDTH:-100}"   # session-start only
SCAN_DEPTH=6

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/later/v2"

# The terminal link step's notices (session-start only).
NOTICE_ADDED='later: added the terminal command ~/.local/bin/later; set later.terminal to off in /config to remove it.'
NOTICE_REMOVED='later: removed the terminal command ~/.local/bin/later.'
NOTICE_REFUSED='later: ~/.local/bin/later exists and was not made by this plugin, so the terminal command was not added; remove it and start a new session to get it.'
NOTICE_PATH="later: ~/.local/bin is not on PATH in this session, so a terminal may not find later; add it to PATH in your shell's startup file."

OPEN_RE='^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*(.*)$'
STAMP_RE=' \(([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2})\)$'
STAMP_LEN=19   # length of " (YYYY-MM-DD HH:MM)"

# LATER_NOW (epoch seconds) replaces the clock, for tests.
now() { printf '%s' "${LATER_NOW:-$(date +%s)}"; }

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
    printf '%s/%s\n' "${root:-$dir}" "$NOTES_FILE_NAME"
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

# Run a command holding the queue's lock. Without flock, run it unlocked.
with_lock() {
    local file="$1"; shift
    mkdir -p "$STATE_DIR" 2>/dev/null
    if command -v flock >/dev/null 2>&1 && [ -d "$STATE_DIR" ]; then
        (
            flock -w 5 9 || { echo 'later: the queue is locked by another writer' >&2; exit 1; }
            "$@"
        ) 9>"$STATE_DIR/$(state_key "$file").lock"
    else
        "$@"
    fi
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
            -o -xtype f -name "$NOTES_FILE_NAME" -print 2>/dev/null
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

# How the display reaches the user. Kept in one place: it is the only line
# that changes if the message has to go into model context instead.
emit() { jq -n --arg m "$1" '{systemMessage: $m}'; }

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
    command -v jq >/dev/null 2>&1 || return 0
    local input cwd src agent file rows='' count sf='' shown=0 digest=0 t floor msg='' notices
    input=$(cat)
    cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
    src=$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null)
    agent=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)
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
    notices=$(terminal_link)
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
