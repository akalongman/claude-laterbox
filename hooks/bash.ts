// Finding Git for Windows' bash (spec R1). Every step reads a variable or asks whether a file exists; none starts a
// process. The hooks module hands in the variables it read and its file check, so nothing here touches the engine.

// The variables the search reads, unset ones absent (1.6).
export type BashVariables = Readonly<
    Partial<
        Record<
            | 'OS'
            | 'SHELL'
            | 'CLAUDE_CODE_GIT_BASH_PATH'
            | 'ProgramFiles'
            | 'ProgramW6432'
            | 'ProgramFiles(x86)'
            | 'LOCALAPPDATA'
            | 'PATH',
            string
        >
    >
>;

// The step of 1.3 that gave the bash found, in search order.
export type BashStep = 'shell' | 'override' | 'program-files' | 'per-user' | 'path';

// What the search came to: the bash to start and the step that gave it, or nothing.
export type BashSearch =
    | { readonly kind: 'found'; readonly path: string; readonly step: BashStep }
    | { readonly kind: 'not_found' };

// The file names a bash may have, lower-cased: Claude Code's own rule for its override (1.3).
const BASH_NAMES: ReadonlySet<string> = new Set(['bash.exe', 'sh.exe', 'bash', 'sh']);

// The Windows folders that hold WSL's bash.exe, a launcher for Linux, lower-cased (1.3).
const WINDOWS_FOLDERS: ReadonlySet<string> = new Set(['system32', 'syswow64', 'windowsapps']);

// Git's bash launcher under a Program Files folder (step 3), under LOCALAPPDATA (step 4), and in the parent of a
// PATH folder that holds git.exe (step 5).
const PROGRAM_FILES_BASH = 'Git\\bin\\bash.exe';
const PER_USER_BASH = 'Programs\\Git\\bin\\bash.exe';
const PARENT_BASH = 'bin\\bash.exe';

// Either slash separates the folders of a Windows path.
const SEPARATOR = /[\\/]/;
const TRAILING_SEPARATORS = /[\\/]+$/;

// Whether the module runs on Windows: Windows sets OS for every process, also when the plugin root is on a network
// share (1.1).
export function isWindowsHost(variables: BashVariables): boolean {
    return variables.OS === 'Windows_NT';
}

// Whether a path may name Git's bash: non-empty, not a bare name (a file name with no folder part is never used), its
// file name bash.exe, sh.exe, bash or sh, and no folder on the way a Windows folder that holds WSL's bash; both
// slashes separate, case is ignored (1.3).
export function isUsableBash(path: string): boolean {
    if (path === '') {
        return false;
    }
    const segments = path.toLowerCase().split(SEPARATOR);
    return (
        segments.length > 1 &&
        BASH_NAMES.has(segments.at(-1) ?? '') &&
        !segments.some((segment) => WINDOWS_FOLDERS.has(segment))
    );
}

// The first candidate of 1.3's five steps, in order, that passes `isUsableBash` and `exists`. An `exists` that rejects
// counts as false, and no path is asked about twice, whatever its case (Windows ignores it).
export async function findBash(
    variables: BashVariables,
    exists: (path: string) => Promise<boolean>,
): Promise<BashSearch> {
    const answers = new Map<string, boolean>();
    const isPresent = async (path: string): Promise<boolean> => {
        const key = path.toLowerCase();
        const known = answers.get(key);
        if (known !== undefined) {
            return known;
        }
        let answer: boolean;
        try {
            answer = await exists(path);
        } catch {
            answer = false;
        }
        answers.set(key, answer);
        return answer;
    };

    const named: ReadonlyArray<{ readonly step: BashStep; readonly path: string | undefined }> = [
        { step: 'shell', path: variables.SHELL },
        { step: 'override', path: variables.CLAUDE_CODE_GIT_BASH_PATH },
        { step: 'program-files', path: under(variables.ProgramFiles, PROGRAM_FILES_BASH) },
        { step: 'program-files', path: under(variables.ProgramW6432, PROGRAM_FILES_BASH) },
        { step: 'program-files', path: under(variables['ProgramFiles(x86)'], PROGRAM_FILES_BASH) },
        { step: 'per-user', path: under(variables.LOCALAPPDATA, PER_USER_BASH) },
    ];
    for (const { step, path } of named) {
        if (path !== undefined && isUsableBash(path) && (await isPresent(path))) {
            return { kind: 'found', path, step };
        }
    }

    for (const folder of pathFolders(variables.PATH)) {
        const git = under(folder, 'git.exe');
        const path = under(parentOf(folder), PARENT_BASH);
        if (git === undefined || path === undefined || !(await isPresent(git))) {
            continue;
        }
        if (isUsableBash(path) && (await isPresent(path))) {
            return { kind: 'found', path, step: 'path' };
        }
    }
    return { kind: 'not_found' };
}

// The engine script under a plugin root, in the forward-slash form bash takes on every platform (1.2).
export function scriptPathOf(root: string): string {
    return `${root.replaceAll('\\', '/').replace(/\/+$/, '')}/scripts/later.sh`;
}

// `suffix` joined to `base` with a backslash once the base's trailing slashes are trimmed; nothing for a base that is
// unset or holds only slashes.
function under(base: string | undefined, suffix: string): string | undefined {
    const trimmed = (base ?? '').replace(TRAILING_SEPARATORS, '');
    return trimmed === '' ? undefined : `${trimmed}\\${suffix}`;
}

// The folders on PATH in order, empty ones dropped.
function pathFolders(path: string | undefined): ReadonlyArray<string> {
    return (path ?? '')
        .split(';')
        .map(unquoted)
        .filter((entry) => entry !== '');
}

// A PATH entry trimmed and stripped of one pair of surrounding double quotes.
function unquoted(entry: string): string {
    const trimmed = entry.trim();
    return trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"') ? trimmed.slice(1, -1) : trimmed;
}

// The folder above `folder` once its trailing slashes are trimmed, cut at its last slash of either kind; nothing for
// a folder without one, such as a drive root.
function parentOf(folder: string): string | undefined {
    const trimmed = folder.replace(TRAILING_SEPARATORS, '');
    const cut = Math.max(trimmed.lastIndexOf('\\'), trimmed.lastIndexOf('/'));
    return cut < 0 ? undefined : trimmed.slice(0, cut);
}
