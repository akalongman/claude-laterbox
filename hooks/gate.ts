// The refresh gate of the open notes pane (spec R2): what the pane saw of the queue file before its last read, and
// whether a tick runs `rows` again. The hooks module hands in the folder and the look it took, so nothing here
// touches the engine.

// What a look at the queue file saw: the file with its modification time and size, no file, or nothing it could
// see (2.3).
export type FileLook =
    | { readonly kind: 'present'; readonly mtimeMs: number; readonly size: number }
    | { readonly kind: 'absent' }
    | { readonly kind: 'unseeable' };

// What the pane's last read was taken against: the session's working directory and the queue file's path, the look
// at that file taken before the read (undefined when none was), and when the read started.
export type GateMemo = {
    readonly cwd: string;
    readonly path: string;
    readonly file: FileLook | undefined;
    readonly readAtMs: number;
};

// How long an unchanged queue goes unread at most: a file system with one-second timestamps can hide a change of
// the same size made within the second of the last read (2.2).
export const SAFETY_READ_MS = 60_000;

// Whether a tick that saw the folder `cwd` and the file `file` at `nowMs` reads the queue (2.2, 2.3): with no memo,
// in another folder, without a look on either side, when either look could not see the file, when the file appeared,
// disappeared, or changed its modification time or size, and in any case a minute after the last read.
export function needsRead(memo: GateMemo | undefined, cwd: string, file: FileLook | undefined, nowMs: number): boolean {
    if (memo === undefined || cwd !== memo.cwd || memo.file === undefined || file === undefined) {
        return true;
    }
    const seen = memo.file;
    if (seen.kind === 'unseeable' || file.kind === 'unseeable' || seen.kind !== file.kind) {
        return true;
    }
    const isChanged =
        seen.kind === 'present' &&
        file.kind === 'present' &&
        (seen.mtimeMs !== file.mtimeMs || seen.size !== file.size);
    return isChanged || nowMs - memo.readAtMs >= SAFETY_READ_MS;
}
