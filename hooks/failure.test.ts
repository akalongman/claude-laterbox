import { expect, test } from 'claude-code/testing';
import type { FailureKind, RunFailure } from './failure';
import { failureKindOf, failureReason } from './failure';

const GIT_BASH = 'C:\\Program Files\\Git\\bin\\bash.exe';

// What Git's bash prints when the script it was given is not there.
const NO_SCRIPT = 'bash: /c/laterbox/scripts/later.sh: No such file or directory\n';

function rejected(message: string): RunFailure {
    return { kind: 'rejected', message };
}

function exited(exitCode: number, stderr: string): RunFailure {
    return { kind: 'exited', exitCode, stderr };
}

// One row per failure: what the run came to, how it was started, and the kind it is.
const KINDS: ReadonlyArray<readonly [string, RunFailure, 'direct' | 'bash', FailureKind]> = [
    ['spawn EACCES under direct', rejected('spawn EACCES'), 'direct', 'refused'],
    ['spawn EACCES under bash', rejected('spawn EACCES'), 'bash', 'refused'],
    ['spawn EPERM under bash', rejected('spawn EPERM'), 'bash', 'refused'],
    ["Windows' access is denied", rejected('Access is denied.'), 'bash', 'refused'],
    ['a run that timed out under bash', rejected('process timed out after 10000 ms'), 'bash', 'timeout'],
    ['a run that timed out under direct', rejected('process timed out after 10000 ms'), 'direct', 'timeout'],
    ['spawn ENOENT under bash', rejected('spawn ENOENT'), 'bash', 'bash_gone'],
    ['spawn ENOENT under direct', rejected('spawn ENOENT'), 'direct', 'script_missing'],
    ['exit 127', exited(127, NO_SCRIPT), 'bash', 'script_missing'],
    ['exit 1', exited(1, 'later: the queue is locked by another writer\n'), 'bash', 'engine'],
];
for (const [name, failure, launcher, kind] of KINDS) {
    test(`${name} is ${kind}`, async () => {
        expect(failureKindOf(failure, launcher)).toBe(kind);
    });
}

// One row per kind: the reason it gives for a run of Git's bash whose engine named a locked queue.
const REASONS: ReadonlyArray<readonly [FailureKind, string]> = [
    ['bash_gone', `the bash at ${GIT_BASH} is gone; restart Claude Code to search again`],
    ['script_missing', "laterbox's files are incomplete; reinstall the plugin"],
    ['refused', `the system refused to start ${GIT_BASH}; check its permissions or your security software`],
    ['timeout', 'the queue did not answer within 10 seconds; try again'],
    ['other', 'the queue engine could not run; start Claude Code with --debug for details'],
    ['engine', 'the queue is locked by another writer'],
];
for (const [kind, reason] of REASONS) {
    test(`the ${kind} reason`, async () => {
        const detail = { started: GIT_BASH, engineReason: 'the queue is locked by another writer' };
        expect(failureReason(kind, detail)).toBe(reason);
    });
}
