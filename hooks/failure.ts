// What an engine run that failed means to the user (spec 4.2): the kind of failure, told by how the run failed and
// how it was started, and the plain reason each kind gives. The hooks module hands in what the run came to, so
// nothing here touches the engine.

// How an engine run failed: it was rejected (it could not start, or it ran out of time), or the engine exited with
// a code other than 0.
export type RunFailure =
    | { readonly kind: 'rejected'; readonly message: string }
    | { readonly kind: 'exited'; readonly exitCode: number; readonly stderr: string };

// The kinds of 4.2, and `engine`: the engine ran and named what went wrong itself.
export type FailureKind = 'bash_gone' | 'script_missing' | 'refused' | 'timeout' | 'other' | 'engine';

// A rejection that says the system refused the start: an access error, or Windows' own words for one.
const REFUSED = /\b(EACCES|EPERM)\b|access is denied/i;

// A rejection that says the run ran out of time.
const TIMED_OUT = /timed? ?out|ETIMEDOUT/i;

// The exit code bash gives when it cannot find the script it was given.
const NOT_FOUND_EXIT_CODE = 127;

// The kind of a failed run, checked in this order: a refused start, a run out of time, then a start that failed
// otherwise, which under Git's bash means the bash found at session start is gone and, started directly, means the
// script is missing; an exit of 127 means bash started and the script did not, and any other exit is the engine's.
export function failureKindOf(failure: RunFailure, launcher: 'direct' | 'bash'): FailureKind {
    if (failure.kind === 'rejected') {
        if (REFUSED.test(failure.message)) {
            return 'refused';
        }
        if (TIMED_OUT.test(failure.message)) {
            return 'timeout';
        }
        return launcher === 'bash' ? 'bash_gone' : 'script_missing';
    }
    return failure.exitCode === NOT_FOUND_EXIT_CODE ? 'script_missing' : 'engine';
}

// The plain reason a kind gives, with what to do; `started` is the program the run started, and `engineReason` is
// the engine's own reason, which passes through unchanged. The failure templates put `later: ` before the reason.
export function failureReason(
    kind: FailureKind,
    detail: { readonly started: string; readonly engineReason: string },
): string {
    switch (kind) {
        case 'bash_gone':
            return `the bash at ${detail.started} is gone; restart Claude Code to search again`;
        case 'script_missing':
            return "laterbox's files are incomplete; reinstall the plugin";
        case 'refused':
            return `the system refused to start ${detail.started}; check its permissions or your security software`;
        case 'timeout':
            return 'the queue did not answer within 10 seconds; try again';
        case 'other':
            return 'the queue engine could not run; start Claude Code with --debug for details';
        case 'engine':
            return detail.engineReason;
        default: {
            const exhaustive: never = kind;
            return exhaustive;
        }
    }
}
