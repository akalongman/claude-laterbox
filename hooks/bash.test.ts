import { expect, test } from 'claude-code/testing';
import type { BashSearch, BashStep } from './bash';
import { findBash, isUsableBash, isWindowsHost, scriptPathOf } from './bash';

const GIT_BASH = 'C:\\Program Files\\Git\\bin\\bash.exe';
const X86_BASH = 'C:\\Program Files (x86)\\Git\\bin\\bash.exe';
const USR_BASH = 'D:\\Git\\usr\\bin\\bash.exe';
const NOT_FOUND: BashSearch = { kind: 'not_found' };

function found(path: string, step: BashStep): BashSearch {
    return { kind: 'found', path, step };
}

// A disk that holds only the given paths; `asked` logs every path it is asked about, in order.
type Disk = { readonly asked: ReadonlyArray<string>; readonly exists: (path: string) => Promise<boolean> };

function disk(present: ReadonlyArray<string>): Disk {
    const asked: string[] = [];
    return {
        asked,
        exists: async (path: string): Promise<boolean> => {
            asked.push(path);
            return present.includes(path);
        },
    };
}

test('a SHELL naming an existing Git bash is found first and nothing else is checked', async () => {
    const files = disk([GIT_BASH, USR_BASH]);
    const variables = {
        SHELL: GIT_BASH,
        CLAUDE_CODE_GIT_BASH_PATH: USR_BASH,
        ProgramFiles: 'C:\\Program Files',
        LOCALAPPDATA: 'C:\\Users\\u\\AppData\\Local',
        PATH: 'C:\\Program Files\\Git\\cmd',
    };
    expect(await findBash(variables, files.exists)).toEqual(found(GIT_BASH, 'shell'));
    expect(files.asked).toEqual([GIT_BASH]);
});

test("WSL's bash under System32 is skipped, whatever its case and slashes", async () => {
    for (const shell of ['C:\\Windows\\System32\\bash.exe', 'C:\\WINDOWS\\system32/bash.exe']) {
        const files = disk([shell, GIT_BASH]);
        expect(await findBash({ SHELL: shell, ProgramFiles: 'C:\\Program Files' }, files.exists)).toEqual(
            found(GIT_BASH, 'program-files'),
        );
        expect(files.asked).toEqual([GIT_BASH]);
    }
});

test('an override is skipped by its file name and used when it names bash', async () => {
    const named = disk(['C:\\tools\\git-bash.exe']);
    expect(await findBash({ CLAUDE_CODE_GIT_BASH_PATH: 'C:\\tools\\git-bash.exe' }, named.exists)).toEqual(NOT_FOUND);
    expect(named.asked).toEqual([]);

    const files = disk([USR_BASH]);
    const variables = { SHELL: 'C:\\missing\\bash.exe', CLAUDE_CODE_GIT_BASH_PATH: USR_BASH };
    expect(await findBash(variables, files.exists)).toEqual(found(USR_BASH, 'override'));
    expect(files.asked).toEqual(['C:\\missing\\bash.exe', USR_BASH]);
});

test('the Program Files folders are checked in order, a folder named twice once', async () => {
    const files = disk([X86_BASH]);
    const variables = {
        ProgramFiles: 'C:\\Program Files',
        ProgramW6432: 'C:\\Program Files',
        'ProgramFiles(x86)': 'C:\\Program Files (x86)',
    };
    expect(await findBash(variables, files.exists)).toEqual(found(X86_BASH, 'program-files'));
    expect(files.asked).toEqual([GIT_BASH, X86_BASH]);
});

test('the per-user install under LOCALAPPDATA is found, its trailing backslash trimmed', async () => {
    const perUser = 'C:\\Users\\Nino Beridze\\AppData\\Local\\Programs\\Git\\bin\\bash.exe';
    const files = disk([perUser]);
    expect(await findBash({ LOCALAPPDATA: 'C:\\Users\\Nino Beridze\\AppData\\Local\\' }, files.exists)).toEqual(
        found(perUser, 'per-user'),
    );
    expect(files.asked).toEqual([perUser]);
});

test('a quoted PATH entry holding git.exe leads to bin\\bash.exe in its parent', async () => {
    const files = disk(['C:\\Program Files\\Git\\cmd\\git.exe', GIT_BASH]);
    expect(await findBash({ PATH: ';"C:\\Program Files\\Git\\cmd";;C:\\x\\' }, files.exists)).toEqual(
        found(GIT_BASH, 'path'),
    );
    expect(files.asked).toEqual(['C:\\Program Files\\Git\\cmd\\git.exe', GIT_BASH]);
});

test('PATH is scanned in order past a git.exe without bash, blanks skipped, trailing backslashes trimmed', async () => {
    const portable = 'D:\\PortableGit\\bin\\bash.exe';
    const files = disk(['C:\\Tools\\cmd\\git.exe', 'D:\\PortableGit\\cmd\\git.exe', portable]);
    expect(await findBash({ PATH: ' C:\\Tools\\cmd\\ ;; ;D:\\PortableGit\\cmd\;' }, files.exists)).toEqual(
        found(portable, 'path'),
    );
    expect(files.asked).toEqual([
        'C:\\Tools\\cmd\\git.exe',
        'C:\\Tools\\bin\\bash.exe',
        'D:\\PortableGit\\cmd\\git.exe',
        portable,
    ]);
});

test('a path already checked is not checked again, whatever its case or trailing backslash', async () => {
    const files = disk([]);
    const variables = { SHELL: GIT_BASH, ProgramFiles: 'c:\\program files\\', PATH: 'C:\\Git\\cmd;c:\\git\\cmd\\' };
    expect(await findBash(variables, files.exists)).toEqual(NOT_FOUND);
    expect(files.asked).toEqual([GIT_BASH, 'C:\\Git\\cmd\\git.exe']);
});

test('an empty folder variable or a PATH entry at a drive root gives no candidate', async () => {
    const files = disk(['\\Git\\bin\\bash.exe', '\\Programs\\Git\\bin\\bash.exe', 'C:\\git.exe', 'C:\\bin\\bash.exe']);
    const variables = { ProgramFiles: '', ProgramW6432: '\\', LOCALAPPDATA: '/', PATH: 'C:\\' };
    expect(await findBash(variables, files.exists)).toEqual(NOT_FOUND);
    expect(files.asked).toEqual([]);
});

test('an exists that rejects counts as absent at every step', async () => {
    const asked: string[] = [];
    const rejecting = async (path: string): Promise<boolean> => {
        asked.push(path);
        throw new Error('a network location');
    };
    const variables = {
        SHELL: GIT_BASH,
        CLAUDE_CODE_GIT_BASH_PATH: USR_BASH,
        ProgramFiles: 'C:\\Program Files',
        ProgramW6432: 'C:\\Program Files',
        'ProgramFiles(x86)': 'C:\\Program Files (x86)',
        LOCALAPPDATA: 'C:\\Users\\u\\AppData\\Local',
        PATH: 'C:\\Program Files\\Git\\cmd',
    };
    expect(await findBash(variables, rejecting)).toEqual(NOT_FOUND);
    expect(asked).toEqual([
        GIT_BASH,
        USR_BASH,
        X86_BASH,
        'C:\\Users\\u\\AppData\\Local\\Programs\\Git\\bin\\bash.exe',
        'C:\\Program Files\\Git\\cmd\\git.exe',
    ]);
});

test('nothing set gives not found without a check', async () => {
    const files = disk([]);
    expect(await findBash({}, files.exists)).toEqual(NOT_FOUND);
    expect(files.asked).toEqual([]);
});

test('a bare bash name in SHELL or the override is never asked about or used', async () => {
    const asked: string[] = [];
    const everything = async (path: string): Promise<boolean> => {
        asked.push(path);
        return true;
    };
    expect(await findBash({ SHELL: 'bash', CLAUDE_CODE_GIT_BASH_PATH: 'sh.exe' }, everything)).toEqual(NOT_FOUND);
    expect(asked).toEqual([]);
});

test('a usable bash is named bash or sh and lies outside the Windows system folders', async () => {
    expect(isUsableBash(GIT_BASH)).toBe(true);
    expect(isUsableBash('D:/Git/usr/bin/SH.EXE')).toBe(true);
    expect(isUsableBash('/usr/bin/bash')).toBe(true);
    expect(isUsableBash('/bash')).toBe(true);
    expect(isUsableBash('')).toBe(false);
    expect(isUsableBash('bash')).toBe(false);
    expect(isUsableBash('SH.EXE')).toBe(false);
    expect(isUsableBash('C:\\tools\\git-bash.exe')).toBe(false);
    expect(isUsableBash('C:\\Program Files\\Git\\bin\\')).toBe(false);
    expect(isUsableBash('C:\\Windows\\SysWOW64\\bash.exe')).toBe(false);
    expect(isUsableBash('C:\\Users\\u\\AppData\\Local\\Microsoft\\WindowsApps\\bash.exe')).toBe(false);
});

test('the host is Windows only when OS is Windows_NT', async () => {
    expect(isWindowsHost({ OS: 'Windows_NT' })).toBe(true);
    expect(isWindowsHost({})).toBe(false);
});

test('the script path is the root in forward slashes, non-ASCII letters kept', async () => {
    expect(scriptPathOf('C:\\Users\\ნინო\\.claude\\plugins\\cache\\akalongman\\laterbox\\0.3.0\\')).toBe(
        'C:/Users/ნინო/.claude/plugins/cache/akalongman/laterbox/0.3.0/scripts/later.sh',
    );
    expect(scriptPathOf('/home/u/p')).toBe('/home/u/p/scripts/later.sh');
});
