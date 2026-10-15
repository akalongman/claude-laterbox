#!/usr/bin/env bash
# Plain-bash test helpers for the engine tests, no bats dependency. A copy of
# the subset this plugin's tests use, so the suite depends on nothing outside
# the plugin folder. Source it; do not run it.

TESTS_RUN=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TMPDIRS=()

# linux, macos or gitbash (Git for Windows and its MSYS2 and Cygwin kin);
# LATER_TEST_PLATFORM overrides the detection.
if [ -n "${LATER_TEST_PLATFORM:-}" ]; then
    PLATFORM="$LATER_TEST_PLATFORM"
else
    case "$(uname -s)" in
        Darwin) PLATFORM=macos ;;
        MINGW*|MSYS*|CYGWIN*) PLATFORM=gitbash ;;
        *) PLATFORM=linux ;;
    esac
fi
case "$PLATFORM" in
    linux|macos|gitbash) ;;
    *) printf 'assert.sh: LATER_TEST_PLATFORM is "%s", not linux, macos or gitbash\n' "$PLATFORM" >&2; exit 2 ;;
esac

# Parent of every mk_repo and mk_tmpdir directory. Callers write "$(mk_repo)",
# a subshell, so mk_repo cannot add its directory to TMPDIRS; finish removes
# this root.
TMPROOT="$(mktemp -d)"

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); }
_fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# A case this platform cannot run: counted apart, never as run or passed.
skip() { # reason
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    printf 'SKIP: %s\n' "$1" >&2
}

assert_eq() { # actual expected msg
    if [ "$1" = "$2" ]; then _pass; else _fail "$3 (expected '$2', got '$1')"; fi
}

assert_contains() { # haystack needle msg
    case "$1" in
        *"$2"*) _pass ;;
        *) _fail "$3 (missing '$2')" ;;
    esac
}

assert_ok() { # msg cmd...
    local msg="$1"; shift
    if "$@" >/dev/null 2>&1; then _pass; else _fail "$msg (command failed: $*)"; fi
}

assert_fail() { # msg cmd...
    local msg="$1"; shift
    if "$@" >/dev/null 2>&1; then _fail "$msg (command unexpectedly succeeded: $*)"; else _pass; fi
}

assert_file() { # path msg
    if [ -e "$1" ]; then _pass; else _fail "$2 (no such path: $1)"; fi
}

assert_nofile() { # path msg
    if [ -e "$1" ]; then _fail "$2 (path exists: $1)"; else _pass; fi
}

# Portable stand-ins for GNU-only commands and output (md5sum, stat -c,
# mktemp -p, unpadded wc), so the suite runs the same on Linux, macOS and
# Git Bash.

file_digest() { # path: cksum's checksum and byte count of its content
    local sum size
    read -r sum size _ <<< "$(cksum < "$1")"
    printf '%s %s\n' "$sum" "$size"
}

file_mode() { # path: its permission string, for example rw-r-----
    local line; line="$(ls -lnd -- "$1")" || return 1
    printf '%s\n' "${line:1:9}"
}

file_inode() { # path: the inode of the path itself, a link's own and not its target's
    local inode
    read -r inode _ <<< "$(ls -di -- "$1")"
    printf '%s\n' "$inode"
}

count_lines() { # stdin: the number of lines, digits only (BSD wc pads it)
    local n; n="$(wc -l)"
    printf '%s\n' "${n//[!0-9]/}"
}

count_bytes() { # stdin: the number of bytes, digits only
    local n; n="$(wc -c)"
    printf '%s\n' "${n//[!0-9]/}"
}

sha1_of() { # text: its SHA-1 in hex, by sha1sum or, where that is missing, shasum
    local sum
    if command -v sha1sum >/dev/null 2>&1; then
        sum="$(printf '%s' "$1" | sha1sum)"
    else
        sum="$(printf '%s' "$1" | shasum -a 1)"
    fi
    printf '%s\n' "${sum%% *}"
}

mk_tmpdir() { # a new directory under TMPROOT
    mktemp -d "$TMPROOT/d.XXXXXX"
}

# A throwaway git repository with one commit, under TMPROOT.
mk_repo() {
    local dir; dir="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@t.t
    git -C "$dir" config user.name t
    git -C "$dir" config commit.gpgsign false   # a global gpgsign=true would hang or fail in tests
    printf 'root\n' > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -qm init
    printf '%s' "$dir"
}

finish() {
    printf '\n%d run, %d failed, %d skipped\n' "$TESTS_RUN" "$TESTS_FAILED" "$TESTS_SKIPPED" >&2
    for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done
    rm -rf "$TMPROOT"
    [ "$TESTS_FAILED" -eq 0 ]
}
