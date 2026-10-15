#!/usr/bin/env bash
# Plain-bash test helpers for the engine tests, no bats dependency. A copy of
# the subset this plugin's tests use, so the suite depends on nothing outside
# the plugin folder. Source it; do not run it.

TESTS_RUN=0
TESTS_FAILED=0
TMPDIRS=()
# Parent of every mk_repo directory. Callers write "$(mk_repo)", a subshell,
# so mk_repo cannot add its directory to TMPDIRS; finish removes this root.
TMPROOT="$(mktemp -d)"

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); }
_fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf 'FAIL: %s\n' "$1" >&2; }

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

# A throwaway git repository with one commit, under TMPROOT.
mk_repo() {
    local dir; dir="$(mktemp -d -p "$TMPROOT")"
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
    printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED" >&2
    for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done
    rm -rf "$TMPROOT"
    [ "$TESTS_FAILED" -eq 0 ]
}
