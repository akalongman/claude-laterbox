import { expect, test } from 'claude-code/testing';
import type { FileLook, GateMemo } from './gate';
import { needsRead, SAFETY_READ_MS } from './gate';

const APP = '/home/u/projects/org/app';
const BILLING = '/home/u/projects/org/billing';
const ABSENT: FileLook = { kind: 'absent' };
const UNSEEABLE: FileLook = { kind: 'unseeable' };

function present(mtimeMs: number, size: number): FileLook {
    return { kind: 'present', mtimeMs, size };
}

// The file as a read's look saw it.
const SEEN = present(1_000, 120);

// The memo of a read in APP at 5 seconds, whose look before it saw `file`.
function memoOf(file: FileLook | undefined): GateMemo {
    return { cwd: APP, path: `${APP}/LATER.local.md`, file, readAtMs: 5_000 };
}

// One row per clause: the memo, the folder and the file the tick saw, the tick's time, and whether it reads.
const CASES: ReadonlyArray<readonly [string, GateMemo | undefined, string, FileLook | undefined, number, boolean]> = [
    ['no memo', undefined, APP, SEEN, 10_000, true],
    ['another folder', memoOf(SEEN), BILLING, SEEN, 10_000, true],
    ['a memo without a look', memoOf(undefined), APP, SEEN, 10_000, true],
    ['a tick without a look', memoOf(SEEN), APP, undefined, 10_000, true],
    ['a memo that could not see the file', memoOf(UNSEEABLE), APP, SEEN, 10_000, true],
    ['a file the tick cannot see', memoOf(SEEN), APP, UNSEEABLE, 10_000, true],
    ['a file unseen both times', memoOf(UNSEEABLE), APP, UNSEEABLE, 10_000, true],
    ['a file that disappeared', memoOf(SEEN), APP, ABSENT, 10_000, true],
    ['a file that appeared', memoOf(ABSENT), APP, SEEN, 10_000, true],
    ['another modification time', memoOf(SEEN), APP, present(2_000, 120), 10_000, true],
    ['another size', memoOf(SEEN), APP, present(1_000, 121), 10_000, true],
    ['an unchanged file 59 999 ms after the read', memoOf(SEEN), APP, SEEN, 64_999, false],
    ['an unchanged file 60 000 ms after the read', memoOf(SEEN), APP, SEEN, 65_000, true],
    ['a file still absent 59 999 ms after the read', memoOf(ABSENT), APP, ABSENT, 64_999, false],
    ['a file still absent 60 000 ms after the read', memoOf(ABSENT), APP, ABSENT, 65_000, true],
];
for (const [name, memo, cwd, file, nowMs, isRead] of CASES) {
    test(`${name} ${isRead ? 'is read' : 'is not read'}`, async () => {
        expect(needsRead(memo, cwd, file, nowMs)).toBe(isRead);
    });
}

test('the safety read comes once a minute', async () => {
    expect(SAFETY_READ_MS).toBe(60_000);
});
