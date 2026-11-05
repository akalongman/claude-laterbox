import type {
    CommandSpec,
    ModelCompleteInput,
    ModelCompleteResult,
    ModelForkResult,
    ModelUsage,
    On,
    PaneOpenArgs,
    ProcessRunInit,
    PromptFillResult,
    SessionMessage,
    UiFocusResult,
    UiPane,
} from 'claude-code';
import type { Engine, MockClock, Mounted, Plugin } from 'claude-code/testing';
import { describe, expect, mock, test } from 'claude-code/testing';

const SESSION = { cwd: '/home/u/projects/org/app', surface: 'terminal', isInteractive: true } as const;
const CLEAN = 'Check the S3 retry path in UploadJob';
const USAGE: ModelUsage = {
    input_tokens: 0,
    output_tokens: 0,
    cache_read_input_tokens: 0,
    cache_creation_input_tokens: 0,
};

function answered(text: string): ModelCompleteResult {
    return { isAnswered: true, text, usage: USAGE };
}

type EngineReply = { readonly exitCode: number; readonly stdout: string; readonly stderr: string };

// What the world beneath the plugin answers; every field has a default (see stage).
type World = {
    readonly register?: 'deny';
    readonly engine?: EngineReply | 'deny' | { readonly deny: string }; // answers every run; 'deny' is spawn ENOENT
    readonly rows?: () => string; // stdout of `later.sh rows`
    readonly closeNote?: (args: ReadonlyArray<string>, text: string) => EngineReply; // answers `done` and `drop`
    readonly add?: (note: string) => EngineReply; // answers `add`
    readonly messages?: ReadonlyArray<SessionMessage> | 'deny';
    readonly completion?: ModelCompleteResult;
    readonly fork?: ModelForkResult | 'deny' | 'slow';
    readonly open?: 'placed' | 'unplaced' | 'deny';
    readonly panes?: ReadonlyArray<UiPane>;
    readonly draft?: string;
    readonly draftRead?: 'deny'; // refuses `$.prompt.read`
    readonly fill?: PromptFillResult;
    readonly env?: Readonly<Record<string, string>>; // the variables `$.env.get` reads
    readonly isEnvRefused?: (name: string) => boolean; // which `$.env.get` reads are refused
    readonly files?: ReadonlyArray<string>; // the paths `$.fs.exists` finds
    readonly exists?: (path: string) => Promise<boolean | 'deny'>; // answers `$.fs.exists` in place of files
    readonly stat?: (path: string) => FileTimes | 'deny'; // answers `$.fs.stat`; 'deny' refuses it
    readonly cwd?: () => string; // the folder `$.session.cwd()` answers
};

// What `$.fs.stat` answers for a file, beside its kind.
type FileTimes = { readonly mtimeMs: number; readonly size: number };

type Stage = {
    readonly clock: MockClock;
    readonly registered: CommandSpec[];
    readonly toasts: string[];
    readonly runs: string[][];
    readonly inits: (ProcessRunInit | undefined)[];
    readonly completions: ModelCompleteInput[];
    readonly forks: string[];
    readonly opens: PaneOpenArgs[];
    readonly closes: string[];
    readonly focuses: string[];
    readonly fills: { readonly text: string; readonly mode: string }[];
    readonly fileChecks: string[];
    readonly debugLines: string[];
    readonly sequence: string[]; // every `$.session.cwd`, `$.fs.exists`, `$.fs.stat` and `$.process.run`, in order
};

const PANE_ID = 'later-notes';
const CHECK = 'Check the S3 retry path in UploadJob';
const ASK = 'Ask the payments team about the invoice export';
const RAISE = 'Raise the queue timeout on staging';
const RERUN = 'Rerun the flaky test';
const LISTING = 'app: 2 parked\n 1. Move the upload config to env (3d)\n 2. Recheck the retry path (today)\n';
const HEADLESS = { ...SESSION, isInteractive: false } as const;

// `later.sh rows` for a queue labelled `label`, one [age, text] pair per open note. With `path` the queue line ends
// in it, as the engine prints it; without, the queue line has no path field.
function rowsOf(label: string, notes: ReadonlyArray<readonly [string, string]>, path?: string): string {
    const head = path === undefined ? `queue\t${label}` : `queue\t${label}\t${path}`;
    return [head, ...notes.map(([age, text], index) => `note\t${index + 1}\t${age}\t${text}`)].join('\n') + '\n';
}

// The queue file `rows` names for the session's folder.
const QUEUE_PATH = '/home/u/projects/org/app/LATER.local.md';
const ROWS_NOTES: ReadonlyArray<readonly [string, string]> = [['3d', CHECK], ['today', ASK], ['12d', RAISE]];
const ROWS = rowsOf('shop', ROWS_NOTES, QUEUE_PATH);

function key(text: string, occurrence = 1): string {
    return `note:${occurrence}:${text}`;
}

// The engine as the tests need it: rows from the world, `done` and `drop` from closeNote, `add` from add. The note of
// an `add` and the guard text of a `done` or `drop` arrive on standard input, as `stdin`.
function engineReply(world: World, args: ReadonlyArray<string>, stdin: string): EngineReply {
    const ok = (stdout: string): EngineReply => ({ exitCode: 0, stdout, stderr: '' });
    switch (args[0]) {
        case 'rows':
            return ok((world.rows ?? (() => ROWS))());
        case 'list':
            return ok(LISTING);
        case 'done':
        case 'drop':
            return (
                world.closeNote?.(args, stdin) ?? ok(`later: ${args[0] === 'done' ? 'done' : 'dropped'} -> ${stdin}\n`)
            );
        default:
            return world.add?.(stdin) ?? ok(`later: parked -> ${stdin}\n`);
    }
}

function engineCalls(world: Stage): string[][] {
    return world.runs.map((run) => run.slice(1));
}

// One engine run as the world recorded it: the arguments after the script, and the standard input when it was given.
type EngineRun = { readonly args: ReadonlyArray<string>; readonly stdin?: string };

function engineRuns(world: Stage): EngineRun[] {
    return world.runs.map((run, index): EngineRun => {
        const stdin = world.inits[index]?.stdin;
        return stdin === undefined ? { args: run.slice(1) } : { args: run.slice(1), stdin };
    });
}

// The path the plugin asked `$.fs.exists` about, taken from the path the hook is handed. The kit resolves a path
// against the working directory, and where a drive path is not absolute (Linux, macOS) it puts the directory before
// it, so a drive path is taken back from the end; any other path is kept.
function drivePathOf(path: string): string {
    return /[A-Za-z]:[\\/].*$/s.exec(path)?.[0] ?? path;
}

// The world beneath the plugin: every call it makes is recorded and answered from `world`, and every event the
// tests raise has a bottom. Defaults: the registration succeeds, the engine answers as engineReply does (ROWS for
// `rows`, LISTING for `list`, and it parks or closes by whatever text arrives on standard input), the transcript is
// empty, the completion answers CLEAN, the fork has nothing to fork, the pane is placed, no pane is open, the draft
// is empty, a fill succeeds, no variable is set, no file exists (a stat is refused) and the session runs in
// SESSION.cwd.
function stage(on: On, world: World = {}): Stage {
    const clock = mock.clock(on);
    const recorded: Stage = {
        clock,
        registered: [],
        toasts: [],
        runs: [],
        inits: [],
        completions: [],
        forks: [],
        opens: [],
        closes: [],
        focuses: [],
        fills: [],
        fileChecks: [],
        debugLines: [],
        sequence: [],
    };
    const { env = {}, isEnvRefused } = world;
    if (isEnvRefused === undefined) {
        mock.env(on, env);
    } else {
        on('env.get', (_$, e) => (isEnvRefused(e.name) ? { deny: 'refused by the test' } : { value: env[e.name] }));
    }
    on('session.start', (_$, e) => ({ cwd: e.cwd }));
    on('command.register', (_$, e) => {
        if (world.register === 'deny') {
            return { deny: `"/${e.name}" refused: it is the user's /${e.name}` };
        }
        recorded.registered.push(e);
        return { value: { command: e.name } };
    });
    on('ui.toast', (_$, e) => {
        recorded.toasts.push(e.text);
        return { value: undefined };
    });
    on('ui.log', (_$, e) => {
        if (e.to === 'debug') {
            recorded.debugLines.push(e.text);
        }
        return { value: undefined };
    });
    on('process.run', (_$, e) => {
        recorded.sequence.push(`process.run ${e.argv.slice(1).join(' ')}`);
        recorded.runs.push([...e.argv]);
        recorded.inits.push(e.init);
        const { engine } = world;
        if (engine === 'deny') {
            return { deny: 'spawn ENOENT' };
        }
        if (engine !== undefined && 'deny' in engine) {
            return { deny: engine.deny };
        }
        const reply = engine ?? engineReply(world, e.argv.slice(1), e.init?.stdin ?? '');
        return { value: { ...reply, isStdoutTruncated: false, isStderrTruncated: false } };
    });
    on('session.messages', () =>
        world.messages === 'deny' ? { deny: 'no transcript' } : { value: [...(world.messages ?? [])] },
    );
    on('model.complete', (_$, e) => {
        recorded.completions.push(e);
        return { value: world.completion ?? answered(CLEAN) };
    });
    on('model.fork', async (_$, e) => {
        recorded.forks.push(e.prompt);
        if (world.fork === 'deny') {
            return { deny: 'fork refused by the test' };
        }
        if (world.fork === 'slow') {
            await clock.sleep(41_000);
            return { value: answered('a late answer') };
        }
        return { value: world.fork ?? { isAnswered: false, reason: 'nothing-to-fork' } };
    });
    on('ui.open', (_$, e) => {
        recorded.opens.push(e);
        if (world.open === 'deny') {
            return { deny: 'refused by the test' };
        }
        return {
            value: world.open === 'unplaced' ? { isPlaced: false, reason: 'no surface places panes' } : { isPlaced: true },
        };
    });
    on('ui.close', (_$, e) => {
        recorded.closes.push(e.id);
        return { value: undefined };
    });
    on('ui.panes', () => ({ value: [...(world.panes ?? [])] }));
    on('ui.focus', (_$, e) => {
        if (e.origin.kind === 'plugin' && e.element !== undefined) {
            recorded.focuses.push(e.element);
        }
        return {};
    });
    on('prompt.read', () =>
        world.draftRead === 'deny'
            ? { deny: 'no prompt box in this test' }
            : { value: { text: world.draft ?? '', cursor: (world.draft ?? '').length } },
    );
    on('prompt.fill', (_$, e) => {
        recorded.fills.push({ text: e.text, mode: e.mode });
        return world.fill ?? { isFilled: true };
    });
    on('fs.exists', async (_$, e) => {
        const path = drivePathOf(e.path);
        recorded.sequence.push('fs.exists');
        recorded.fileChecks.push(path);
        const found = world.exists === undefined ? (world.files ?? []).includes(path) : await world.exists(path);
        return found === 'deny' ? { deny: 'a network location' } : { value: found };
    });
    on('fs.stat', (_$, e) => {
        recorded.sequence.push('fs.stat');
        const times = world.stat?.(drivePathOf(e.path)) ?? 'deny';
        return times === 'deny'
            ? { deny: 'refused by the test' }
            : { value: { kind: 'file', size: times.size, mtimeMs: times.mtimeMs, isLink: false } };
    });
    on('session.cwd', () => {
        recorded.sequence.push('session.cwd');
        return { value: world.cwd?.() ?? SESSION.cwd };
    });
    return recorded;
}

test('session start registers /later as an immediate command', async ($, on) => {
    const world = stage(on);
    const result = await $.session.start(SESSION);
    expect(result).toEqual({ cwd: SESSION.cwd });
    expect(world.registered).toEqual([
        {
            name: 'later',
            description: 'Park a note for a later session, even while Claude is working; alone, open the parked notes.',
            argumentHint: '[note text; omit to open the parked notes]',
            immediate: true,
        },
    ]);
    expect(world.toasts).toEqual([]);
});

test('a refused registration shows a toast and the session still starts', async ($, on) => {
    const world = stage(on, { register: 'deny' });
    const result = await $.session.start(SESSION);
    expect(result).toEqual({ cwd: SESSION.cwd });
    expect(world.registered).toEqual([]);
    expect(world.toasts).toHaveLength(1);
    expect(world.toasts[0]).toStartWith('later: could not register /later: ');
    expect(world.toasts[0]).toContain("it is the user's /later");
});

const OFF = { options: { rewrite: 'off' } };
const TYPED = 'chek the S3 retry path';

// What the engine stamps on a run typed at the prompt; the kit's `$` takes the event's input whole.
const AT_PROMPT = { origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 80 } } as const;

test('a bare run in a session that is not interactive lists the queue', OFF, async ($, on) => {
    const world = stage(on);
    await $.session.start(HEADLESS);
    const result = await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    expect(world.runs).toHaveLength(1);
    expect(world.runs[0]?.[0]).toEndWith('/scripts/later.sh');
    expect(world.runs[0]?.slice(1)).toEqual(['list']);
    expect(world.inits).toEqual([{ timeoutMs: 10_000, env: { CLAUDE_PLUGIN_OPTION_FILE: 'LATER.local.md' } }]);
    expect(world.opens).toEqual([]);
    expect(result.text).toBe(LISTING.trimEnd());
    expect(result.context).toHaveLength(1);
    expect(result.context?.[0]).toContain('listed the parked notes with /later');
    expect(result.context?.[0]).toContain('not tasks for now');
});

test('whitespace alone counts as a bare run', OFF, async ($, on) => {
    const world = stage(on, { engine: { exitCode: 0, stdout: 'later: no parked notes\n', stderr: '' } });
    await $.session.start(HEADLESS);
    const result = await $.command.run({ command: 'later', args: ' \n\t ', ...AT_PROMPT });
    expect(world.runs[0]?.slice(1)).toEqual(['list']);
    expect(result.text).toBe('later: no parked notes');
});

test('in off mode a note is collapsed to one line and parked without a model call', OFF, async ($, on) => {
    const world = stage(on);
    await $.session.start(SESSION);
    const result = await $.command.run({
        command: 'later',
        args: '  chek the\n   S3 retry \t path ',
        ...AT_PROMPT,
    });
    expect(world.runs).toHaveLength(1);
    expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: TYPED });
    expect(world.completions).toEqual([]);
    expect(world.forks).toEqual([]);
    expect(result.text).toBe(`later: parked -> ${TYPED}`);
    expect(result.context).toEqual([
        `The user parked a follow-up note for a later session with /later: "${TYPED}". ` +
            'It is a reminder, not a task for now; do not act on it unless the user asks.',
    ]);
});

test('shell-special characters reach the engine verbatim', OFF, async ($, on) => {
    const world = stage(on);
    await $.session.start(SESSION);
    const weird = '50% of C:\\new\\table & *.php "quoted" \'single\' $HOME `tick`; rm -rf /';
    await $.command.run({ command: 'later', args: weird, ...AT_PROMPT });
    expect(world.runs[0]?.slice(1)).toEqual(['add']);
    expect(world.inits[0]?.stdin).toBe(weird);
});

test('an engine exit code names the reason and keeps the typed text on screen', OFF, async ($, on) => {
    const world = stage(on, {
        engine: { exitCode: 1, stdout: '', stderr: 'later: the queue is locked by another writer\n' },
    });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(result).toEqual({
        text: `later: could not park the note (the queue is locked by another writer); typed: ${TYPED}`,
    });
    expect(world.debugLines).toEqual([
        'later: engine run failed: exit code 1: later: the queue is locked by another writer',
    ]);
});

test('an engine exit code without stderr names the code', OFF, async ($, on) => {
    const world = stage(on, { engine: { exitCode: 2, stdout: '', stderr: '' } });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(result).toEqual({ text: `later: could not park the note (exit code 2); typed: ${TYPED}` });
    expect(world.debugLines).toEqual(['later: engine run failed: exit code 2']);
});

// The kit's runs start the script directly, so a start the system cannot make means the script is not there.
test('an engine that cannot start names the files as incomplete', OFF, async ($, on) => {
    const world = stage(on, { engine: 'deny' });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: 'x', ...AT_PROMPT });
    expect(result).toEqual({
        text: "later: could not park the note (laterbox's files are incomplete; reinstall the plugin); typed: x",
    });
    expect(world.debugLines).toHaveLength(1);
    expect(world.debugLines[0]).toMatch(/^later: engine run failed: .*\bspawn ENOENT$/);
});

test('a refused start names the program', OFF, async ($, on) => {
    const world = stage(on, { engine: { deny: 'spawn EACCES' } });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: 'x', ...AT_PROMPT });
    const [started = ''] = world.runs[0] ?? [];
    expect(started).toEndWith('/scripts/later.sh');
    expect(result).toEqual({
        text:
            `later: could not park the note (the system refused to start ${started}; check its permissions or your ` +
            'security software); typed: x',
    });
    expect(world.debugLines).toHaveLength(1);
    expect(world.debugLines[0]).toMatch(/^later: engine run failed: .*\bspawn EACCES$/);
});

test("a listing that fails prints the engine's reason alone", OFF, async ($, on) => {
    stage(on, { engine: { exitCode: 1, stdout: '', stderr: 'later: cannot resolve the queue here\n' } });
    await $.session.start(HEADLESS);
    const result = await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    expect(result).toEqual({ text: 'later: cannot resolve the queue here' });
});

test('a bare run opens the notes pane and prints nothing', async ($, on) => {
    const writes: (readonly [string, unknown])[] = [];
    on('state.set', (_$, e, next) => {
        writes.push([e.key, e.value]);
        return next(e);
    });
    const world = stage(on);
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    expect(engineCalls(world)).toEqual([['rows']]);
    expect(world.opens).toEqual([{ id: PANE_ID, title: 'Parked notes', focus: true, closeOnEscape: true, rows: 6 }]);
    expect(result).toEqual({});
    expect(writes).toContainEqual(['selected', { kind: 'note', key: key(CHECK) }]);
});

test('an empty queue asks for three rows', async ($, on) => {
    const world = stage(on, { rows: () => rowsOf('shop', []) });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    expect(world.opens[0]?.rows).toBe(3);
});

test('a pane that is not placed is closed again and the list is printed', async ($, on) => {
    const world = stage(on, { open: 'unplaced' });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    expect(world.closes).toEqual([PANE_ID]);
    expect(engineCalls(world)).toEqual([['rows'], ['list']]);
    expect(result.text).toBe(LISTING.trimEnd());
    expect(result.context?.[0]).toContain('listed the parked notes with /later');
});

test('a refused open prints the list', async ($, on) => {
    const world = stage(on, { open: 'deny' });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    expect(world.closes).toEqual([]);
    expect(engineCalls(world)).toEqual([['rows'], ['list']]);
    expect(result.text).toBe(LISTING.trimEnd());
});

function said(role: 'user' | 'assistant', text: string): SessionMessage {
    return { role, text, toolUses: [] };
}

// Thirteen entries carry text; the excerpt keeps the newest twelve. Two entries carry none (tool rows) and drop out.
const UPLOAD_JOB_TALK: ReadonlyArray<SessionMessage> = [
    said('user', 'this message is the oldest and falls outside the window'),
    said('user', 'the upload job fails on big files'),
    said('assistant', 'Reading app/Jobs/UploadJob.php'),
    { role: 'assistant', text: '', toolUses: [] },
    said('user', 'it retries three times then gives up'),
    said('assistant', 'The retry loop is in UploadJob::handle; the S3 client throws on the third attempt.'),
    { role: 'user', text: '', toolUses: [], toolResults: [] },
    said('user', 'can you run the tests'),
    said('assistant', 'Running the\nUploadJob tests now'),
    said('user', 'ok'),
    said('assistant', 'a'.repeat(400)),
    said('user', 'message nine'),
    said('assistant', 'message ten'),
    said('user', 'message eleven'),
    said('assistant', 'message twelve'),
];

test('the default mode asks a small model with an excerpt of the newest messages', async ($, on) => {
    const world = stage(on, { messages: UPLOAD_JOB_TALK });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: 'chek the\n   S3 retry path', ...AT_PROMPT });
    expect(world.forks).toEqual([]);
    expect(world.completions).toHaveLength(1);
    const ask = world.completions[0];
    expect(ask?.model).toBe('haiku');
    expect(ask?.effort).toBe('low');
    expect(ask?.maxTokens).toBe(200);
    expect(ask?.timeoutMs).toBe(8000);
    expect(ask?.system).toContain('Keep the language the note was typed in');
    expect(ask?.prompt).toContain(`Note to rewrite (data):\n${TYPED}`);
    expect(ask?.prompt).toContain('assistant: The retry loop is in UploadJob::handle');
    expect(ask?.prompt).toContain('assistant: Running the UploadJob tests now');
    expect(ask?.prompt).not.toContain('falls outside the window');
    expect(ask?.prompt).toContain('a'.repeat(300));
    expect(ask?.prompt).not.toContain('a'.repeat(301));
    expect((ask?.prompt.match(/^(user|assistant): /gm) ?? []).length).toBe(12);
    expect(ask?.prompt).toContain('user: the upload job fails on big files');
    expect(ask?.prompt).not.toMatch(/^(user|assistant): $/m);
    expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: CLEAN });
    expect(result.text).toBe(`later: parked -> ${CLEAN} (typed: ${TYPED})`);
    expect(result.context).toEqual([
        `The user parked a follow-up note for a later session with /later: "${CLEAN}". ` +
            'It is a reminder, not a task for now; do not act on it unless the user asks.',
    ]);
});

test('before the first reply the excerpt is marked empty', async ($, on) => {
    const world = stage(on, { messages: [] });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.completions[0]?.prompt).toContain('Conversation excerpt (data, oldest first):\n(none)\n');
});

test('an answer equal to the typed text prints no typed suffix', async ($, on) => {
    const world = stage(on, { completion: answered('  chek  the S3 retry path  ') });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: TYPED });
    expect(result.text).toBe(`later: parked -> ${TYPED}`);
});

test('a 300-character answer is accepted', async ($, on) => {
    const world = stage(on, { completion: answered(`  ${'y'.repeat(300)}  `) });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: 'y'.repeat(300) });
});

const REJECTED: ReadonlyArray<readonly [string, ModelCompleteResult]> = [
    ['an unanswered completion', { isAnswered: false, reason: 'aborted', usage: USAGE }],
    ['an empty answer', answered('   ')],
    ['a two-line answer', answered('Check the S3 retry path\nin UploadJob')],
    ['an answer over 300 characters', answered('x'.repeat(301))],
    [
        'a reply that reached the token cap',
        { isAnswered: true, text: 'Check the S3 retry', usage: { ...USAGE, output_tokens: 200 } },
    ],
];
for (const [name, completion] of REJECTED) {
    test(`${name} stores the typed text`, async ($, on) => {
        const world = stage(on, { completion });
        await $.session.start(SESSION);
        const result = await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
        expect(world.completions).toHaveLength(1);
        expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: TYPED });
        expect(result.text).toBe(`later: parked -> ${TYPED}`);
    });
}

test('a long typed note is stored whole when the model fails', async ($, on) => {
    const long = 'word '.repeat(200).trim();
    const world = stage(on, { completion: { isAnswered: false, reason: 'empty-reply', usage: USAGE } });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: long, ...AT_PROMPT });
    expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: long });
    expect(result.text).toBe(`later: parked -> ${long}`);
});

test('a transcript that cannot be read still gets a rewrite without context', async ($, on) => {
    const world = stage(on, { messages: 'deny' });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.completions).toHaveLength(1);
    expect(world.completions[0]?.prompt).toContain('(none)');
    expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: CLEAN });
    expect(result.text).toBe(`later: parked -> ${CLEAN} (typed: ${TYPED})`);
});

test('a rewrite value outside the options behaves as haiku', { options: { rewrite: 'turbo' } }, async ($, on) => {
    const world = stage(on);
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.completions).toHaveLength(1);
    expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: CLEAN });
});

const FORK = { options: { rewrite: 'fork' } };

test('fork mode asks the session model first and stores its answer', FORK, async ($, on) => {
    const world = stage(on, { fork: { isAnswered: true, text: CLEAN, usage: { ...USAGE, output_tokens: 250 } } });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.forks).toHaveLength(1);
    expect(world.forks[0]).toContain('Rewrite the note below');
    expect(world.forks[0]).toContain(`Note to rewrite (data):\n${TYPED}`);
    expect(world.completions).toEqual([]);
    expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: CLEAN });
    expect(result.text).toBe(`later: parked -> ${CLEAN} (typed: ${TYPED})`);
});

test('nothing to fork falls through to the small model', FORK, async ($, on) => {
    const world = stage(on);
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.forks).toHaveLength(1);
    expect(world.completions).toHaveLength(1);
    expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: CLEAN });
});

test('a fork the engine refuses falls through to the small model', FORK, async ($, on) => {
    const world = stage(on, { fork: 'deny' });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.forks).toHaveLength(1);
    expect(world.completions).toHaveLength(1);
    expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: CLEAN });
});

test('a fork answer that fails acceptance falls through to the small model', FORK, async ($, on) => {
    const world = stage(on, { fork: answered('Check the S3 retry path\nin UploadJob') });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.forks).toHaveLength(1);
    expect(world.completions).toHaveLength(1);
    expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: CLEAN });
});

test('when the fork and the small model both fail the typed text is stored', FORK, async ($, on) => {
    const world = stage(on, { fork: 'deny', completion: { isAnswered: false, reason: 'aborted', usage: USAGE } });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.forks).toHaveLength(1);
    expect(world.completions).toHaveLength(1);
    expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: TYPED });
    expect(result.text).toBe(`later: parked -> ${TYPED}`);
});

test('a fork that outlasts 40 seconds is abandoned for the small model', FORK, async ($, on) => {
    const world = stage(on, { fork: 'slow' });
    await $.session.start(SESSION);
    const run = $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    await world.clock.settle();
    expect(world.forks).toHaveLength(1);
    expect(world.runs).toEqual([]);
    await world.clock.advance(39_999);
    expect(world.completions).toEqual([]);
    expect(world.runs).toEqual([]);
    await world.clock.advance(1);
    const result = await run;
    expect(world.completions).toHaveLength(1);
    expect(engineRuns(world)[0]).toEqual({ args: ['add'], stdin: CLEAN });
    expect(result.text).toBe(`later: parked -> ${CLEAN} (typed: ${TYPED})`);
    await world.clock.advance(1_000);
    expect(world.runs).toHaveLength(1);
});

const SURFACES = ['terminal', 'desktop'] as const;
type PaneUi = Mounted<(typeof SURFACES)[number], 'Pane'>;
const PANE_PROPS = {
    title: 'Parked notes',
    isFocused: true,
    bodyColumns: 100,
    placement: 'inline',
    scroll: { offset: 0, bodyRows: 20 },
    view: {},
} as const;

// Starts the session, runs bare /later and mounts the pane it opened.
async function openPane($: Engine, surface: (typeof SURFACES)[number]): Promise<PaneUi> {
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    return $.ui.mount({ plugin: 'laterbox', surface, component: 'Pane', requestId: PANE_ID, props: PANE_PROPS });
}

// The person moving the pane's ring, as Tab or an arrow does.
function personFocus($: Engine, element: string): Promise<UiFocusResult> {
    return $.ui.focus({
        component: 'Pane',
        requestId: PANE_ID,
        plugin: 'laterbox',
        element,
        origin: { kind: 'person' },
    });
}

async function shows(ui: PaneUi, text: string): Promise<boolean> {
    return (await ui.find({ type: 'Text', text })) !== undefined;
}

async function buttonKeys(ui: PaneUi): Promise<string[]> {
    return (await ui.findAll({ type: 'Button' })).map((button) => button.key ?? '');
}

// A queue the stubbed engine reads, closes notes in (checking --if as later.sh does) and parks notes into. Its file is
// at QUEUE_PATH, and every change gives it a new modification time, as a write does.
function liveQueue(initial: ReadonlyArray<string>): {
    readonly world: World;
    readonly set: (texts: ReadonlyArray<string>) => void;
} {
    let texts = [...initial];
    let writes = 0;
    const ok = (stdout: string): EngineReply => ({ exitCode: 0, stdout, stderr: '' });
    const write = (next: ReadonlyArray<string>): void => {
        texts = [...next];
        writes += 1;
    };
    return {
        set: write,
        world: {
            rows: () => rowsOf('shop', texts.map((text) => ['today', text] as const), QUEUE_PATH),
            exists: async (path) => path === QUEUE_PATH,
            stat: (path) => (path === QUEUE_PATH ? { mtimeMs: 1_000 + writes, size: texts.join('\n').length } : 'deny'),
            closeNote: ([mode, , n], text) => {
                const index = Number(n) - 1;
                if (texts[index] !== text) {
                    return {
                        exitCode: 1,
                        stdout: '',
                        stderr: `later: note ${n} changed since it was listed; nothing changed\n`,
                    };
                }
                write(texts.filter((_, at) => at !== index));
                return ok(`later: ${mode === 'done' ? 'done' : 'dropped'} -> ${text}\n`);
            },
            add: (note) => {
                write([...texts, note]);
                return ok(`later: parked -> ${note}\n`);
            },
        },
    };
}

for (const surface of SURFACES) {
    describe(surface, () => {
        test('the pane draws the header, one row per note and the action line', async ($, on) => {
            stage(on);
            const ui = await openPane($, surface);
            expect(await shows(ui, 'shop: 3 parked')).toBe(true);
            expect((await ui.find({ key: key(CHECK) }))?.text).toStartWith(`> 1. ${CHECK}`);
            expect((await ui.find({ key: key(ASK) }))?.text).toStartWith(`  2. ${ASK}`);
            expect(await shows(ui, '(12d)')).toBe(true);
            expect(await buttonKeys(ui)).toEqual([
                key(CHECK),
                key(ASK),
                key(RAISE),
                'work',
                'done',
                'drop',
                'add',
                'next',
                'previous',
            ]);
            expect(await shows(ui, 'esc: close')).toBe(true);
            expect(await ui.findAll({ type: 'Text', text: /^later: / })).toEqual([]);
        });

        test('an empty queue draws only a', async ($, on) => {
            stage(on, { rows: () => rowsOf('shop', []) });
            const ui = await openPane($, surface);
            expect(await shows(ui, 'shop: no parked notes')).toBe(true);
            expect(await buttonKeys(ui)).toEqual(['add']);
        });

        test('a queue that cannot be read opens the pane with the reason', async ($, on) => {
            stage(on, { engine: { exitCode: 1, stdout: '', stderr: 'later: cannot resolve the queue here\n' } });
            const ui = await openPane($, surface);
            expect(await shows(ui, 'later: cannot resolve the queue here')).toBe(true);
            expect(await buttonKeys(ui)).toEqual(['add']);
        });

        test('d closes the note the ring was moved to and selects the row now at its place', async ($, on) => {
            const world = stage(on, liveQueue([CHECK, ASK, RAISE]).world);
            const ui = await openPane($, surface);
            await personFocus($, key(ASK));
            await ui.press({ key: 'done' });
            expect(engineRuns(world)).toContainEqual({ args: ['done', '--if', '2'], stdin: ASK });
            expect(await shows(ui, `later: done -> ${ASK}`)).toBe(true);
            expect(await shows(ui, 'shop: 2 parked')).toBe(true);
            expect((await ui.find({ key: key(RAISE) }))?.text).toStartWith('> 2. ');
            expect(engineCalls(world).filter(([verb]) => verb === 'rows')).toHaveLength(2);
        });

        test('x drops the selected note', async ($, on) => {
            const world = stage(on, liveQueue([CHECK, ASK, RAISE]).world);
            const ui = await openPane($, surface);
            await ui.press({ key: 'drop' });
            expect(engineRuns(world)).toContainEqual({ args: ['drop', '--if', '1'], stdin: CHECK });
            expect(await shows(ui, `later: dropped -> ${CHECK}`)).toBe(true);
        });

        test('a refused d re-reads and keeps the selected note', async ($, on) => {
            const queue = liveQueue([CHECK, ASK, RAISE]);
            const world = stage(on, queue.world);
            const ui = await openPane($, surface);
            await personFocus($, key(RAISE));
            queue.set([ASK, RAISE]);
            await ui.press({ key: 'done' });
            expect(engineRuns(world)).toContainEqual({ args: ['done', '--if', '3'], stdin: RAISE });
            expect(await shows(ui, 'later: note 3 changed since it was listed; nothing changed')).toBe(true);
            expect((await ui.find({ key: key(RAISE) }))?.text).toStartWith('> 2. ');
            await ui.press({ key: 'done' });
            expect(engineRuns(world)).toContainEqual({ args: ['done', '--if', '2'], stdin: RAISE });
            expect(await shows(ui, `later: done -> ${RAISE}`)).toBe(true);
        });

        for (const [draft, appended] of [['', CHECK], ['and then', ` ${CHECK}`], ['fix ', CHECK]] as const) {
            test(`w after the draft "${draft}" appends the note and closes the pane`, async ($, on) => {
                const world = stage(on, { draft });
                const ui = await openPane($, surface);
                await ui.press({ key: 'work' });
                expect(world.fills).toEqual([{ text: appended, mode: 'append' }]);
                expect(world.closes).toEqual([PANE_ID]);
            });
        }

        test('Enter on a row works on that row', async ($, on) => {
            const world = stage(on);
            const ui = await openPane($, surface);
            await ui.press({ key: key(RAISE) });
            expect(world.fills).toEqual([{ text: RAISE, mode: 'append' }]);
        });

        for (const [name, answers, reason] of [
            ['rejected', { draftRead: 'deny' }, 'laterbox: $.prompt.read: no prompt box in this test'],
            ['refused', { fill: { isFilled: false } }, 'refused'],
        ] as const) {
            test(`a fill refused (${name}) keeps the pane open and says why`, async ($, on) => {
                const world = stage(on, answers);
                const ui = await openPane($, surface);
                await ui.press({ key: 'work' });
                expect(world.closes).toEqual([]);
                expect(await shows(ui, `later: could not fill the prompt (${reason})`)).toBe(true);
            });
        }

        test('j and k move one note, stop at the ends, and d follows them', async ($, on) => {
            const world = stage(on);
            const ui = await openPane($, surface);
            await ui.press({ key: 'previous' });
            expect((await ui.find({ key: key(CHECK) }))?.text).toStartWith('> 1. ');
            await ui.press({ key: 'next' });
            expect((await ui.find({ key: key(ASK) }))?.text).toStartWith('> 2. ');
            await ui.press({ key: 'next' });
            expect((await ui.find({ key: key(RAISE) }))?.text).toStartWith('> 3. ');
            await ui.press({ key: 'next' });
            expect((await ui.find({ key: key(RAISE) }))?.text).toStartWith('> 3. ');
            await ui.press({ key: 'done' });
            expect(engineRuns(world)).toContainEqual({ args: ['done', '--if', '3'], stdin: RAISE });
        });

        test('duplicate notes get distinct rows, and d acts on the one selected', async ($, on) => {
            const world = stage(on, { rows: () => rowsOf('shop', [['today', RERUN], ['today', RERUN]]) });
            const ui = await openPane($, surface);
            expect(await buttonKeys(ui)).toEqual(expect.arrayContaining([key(RERUN, 1), key(RERUN, 2)]));
            await personFocus($, key(RERUN, 2));
            await ui.press({ key: 'done' });
            expect(engineRuns(world)).toContainEqual({ args: ['done', '--if', '2'], stdin: RERUN });
        });

        test('a second d pressed while the first runs is ignored', async ($, on) => {
            const world = stage(on, liveQueue([RERUN, RERUN, RAISE]).world);
            const ui = await openPane($, surface);
            await Promise.all([ui.press({ key: 'done' }), ui.press({ key: 'done' })]);
            const closes = engineRuns(world).filter(({ args }) => args[0] === 'done');
            expect(closes).toEqual([{ args: ['done', '--if', '1'], stdin: RERUN }]);
            expect(await shows(ui, 'shop: 2 parked')).toBe(true);
            expect((await ui.find({ key: key(RERUN) }))?.text).toStartWith(`> 1. ${RERUN}`);
        });

        test('a twin closed elsewhere leaves the marker on the selected text', async ($, on) => {
            const queue = liveQueue([RERUN, RERUN, RAISE]);
            const world = stage(on, queue.world);
            const ui = await openPane($, surface);
            await personFocus($, key(RERUN, 2));
            queue.set([RERUN, RAISE]);
            await world.clock.advance(5_000);
            expect((await ui.find({ key: key(RERUN) }))?.text).toStartWith(`> 1. ${RERUN}`);
            expect((await ui.find({ key: key(RAISE) }))?.text).toStartWith('  2. ');
            await ui.press({ key: 'done' });
            expect(engineRuns(world)).toContainEqual({ args: ['done', '--if', '1'], stdin: RERUN });
        });

        test('d on the first of two twins selects the row now at its place', async ($, on) => {
            const world = stage(on, liveQueue([RERUN, RAISE, RERUN]).world);
            const ui = await openPane($, surface);
            await ui.press({ key: 'done' });
            expect(engineRuns(world)).toContainEqual({ args: ['done', '--if', '1'], stdin: RERUN });
            expect((await ui.find({ key: key(RAISE) }))?.text).toStartWith('> 1. ');
        });

        test('d on the last of two twins selects the row now at its place', async ($, on) => {
            const world = stage(on, liveQueue([RERUN, RAISE, RERUN]).world);
            const ui = await openPane($, surface);
            await personFocus($, key(RERUN, 2));
            await ui.press({ key: 'done' });
            expect(engineRuns(world)).toContainEqual({ args: ['done', '--if', '3'], stdin: RERUN });
            expect((await ui.find({ key: key(RAISE) }))?.text).toStartWith('> 2. ');
        });

        test('a note ending in a space is closed with the space', async ($, on) => {
            const world = stage(on, { rows: () => rowsOf('shop', [['today', 'text ']]) });
            const ui = await openPane($, surface);
            await ui.press({ key: 'done' });
            expect(engineRuns(world)).toContainEqual({ args: ['done', '--if', '1'], stdin: 'text ' });
        });

        test('a note holding a tab is drawn whole and sent whole', async ($, on) => {
            const split = 'split\there';
            const world = stage(on, { rows: () => rowsOf('shop', [['undated', split]]) });
            const ui = await openPane($, surface);
            expect((await ui.find({ key: key(split) }))?.text).toContain(split);
            await ui.press({ key: 'done' });
            expect(engineRuns(world)).toContainEqual({ args: ['done', '--if', '1'], stdin: split });
        });
    });
}

function rowsReads(world: Stage): number {
    return engineCalls(world).filter(([verb]) => verb === 'rows').length;
}

for (const surface of SURFACES) {
    describe(`${surface}, adding`, () => {
        test('a shows an input, and a submitted note is rewritten and parked', async ($, on) => {
            const world = stage(on);
            const ui = await openPane($, surface);
            await ui.press({ key: 'add' });
            expect(await ui.find({ type: 'Input', key: 'new-note' })).toBeDefined();
            expect(await buttonKeys(ui)).toEqual([key(CHECK), key(ASK), key(RAISE)]);
            await ui.input({ key: 'new-note', text: TYPED });
            expect(engineRuns(world)).toContainEqual({ args: ['add'], stdin: CLEAN });
            expect(await shows(ui, `later: parked -> ${CLEAN} (typed: ${TYPED})`)).toBe(true);
            expect(await ui.find({ type: 'Input' })).toBeUndefined();
            expect(await buttonKeys(ui)).toContain('add');
            expect(rowsReads(world)).toBe(2);
        });

        test('an empty submit returns to the action line', OFF, async ($, on) => {
            const world = stage(on);
            const ui = await openPane($, surface);
            await ui.press({ key: 'add' });
            await ui.input({ key: 'new-note', text: '   ' });
            expect(engineCalls(world).filter(([verb]) => verb === 'add')).toEqual([]);
            expect(await buttonKeys(ui)).toContain('add');
            expect((await ui.find({ key: key(CHECK) }))?.text).toStartWith(`> 1. ${CHECK}`);
        });

        test("a failed park shows the command's failure line", OFF, async ($, on) => {
            stage(on, {
                add: () => ({ exitCode: 1, stdout: '', stderr: 'later: the queue is locked by another writer\n' }),
            });
            const ui = await openPane($, surface);
            await ui.press({ key: 'add' });
            await ui.input({ key: 'new-note', text: TYPED });
            const failure = `later: could not park the note (the queue is locked by another writer); typed: ${TYPED}`;
            expect(await shows(ui, failure)).toBe(true);
        });

        test('the first note added to an empty queue becomes the selected row', OFF, async ($, on) => {
            stage(on, liveQueue([]).world);
            const ui = await openPane($, surface);
            expect(await buttonKeys(ui)).toEqual(['add']);
            await ui.press({ key: 'add' });
            await ui.input({ key: 'new-note', text: 'first one' });
            expect((await ui.find({ key: key('first one') }))?.text).toStartWith('> 1. first one');
        });
    });
}

// The first tick reads once more, since the open's read had no file to look at; the second reads the changed queue.
test('the open pane looks every five seconds and shows a changed queue', async ($, on) => {
    const queue = liveQueue([CHECK]);
    const world = stage(on, queue.world);
    const ui = await openPane($, 'terminal');
    expect(rowsReads(world)).toBe(1);
    await world.clock.advance(4_999);
    expect(rowsReads(world)).toBe(1);
    await world.clock.advance(1);
    expect(rowsReads(world)).toBe(2);
    queue.set([CHECK, ASK]);
    await world.clock.advance(5_000);
    expect(await shows(ui, 'shop: 2 parked')).toBe(true);
});

// A plugin beside this one that closes the notes pane. The kit has no person's close, and the module's own close
// never reaches its own `ui.close` hook, so another plugin's close is the one that reaches it.
const CLOSER: Plugin = {
    name: 'closer',
    register(on) {
        on('session.start', async ($, e, next) => {
            await $.command.register({ name: 'close-notes', description: 'Close the notes pane', immediate: true });
            return next(e);
        });
        on('command.run', { command: 'close-notes' }, async ($) => {
            await $.ui.close({ id: 'later-notes' });
            return {};
        });
    },
};

test('a pane closed from outside the module reads nothing more', { plugins: [CLOSER] }, async ($, on) => {
    const world = stage(on);
    await openPane($, 'terminal');
    await $.command.run({ command: 'close-notes', args: '', ...AT_PROMPT });
    await world.clock.advance(10_000);
    expect(rowsReads(world)).toBe(1);
});

test('after w the pane reads nothing more', async ($, on) => {
    const world = stage(on);
    const ui = await openPane($, 'terminal');
    await ui.press({ key: 'work' });
    await world.clock.advance(10_000);
    expect(rowsReads(world)).toBe(1);
});

test('a reload with the pane open keeps reading', async ($, on) => {
    const world = stage(on, {
        panes: [{ id: PANE_ID, title: 'Parked notes', isShown: true, isFocused: false, isPlaced: true }],
    });
    await $.session.start(SESSION);
    await world.clock.advance(5_000);
    expect(rowsReads(world)).toBe(1);
});

test('a session that is not interactive reads nothing on the clock', async ($, on) => {
    const world = stage(on, {
        panes: [{ id: PANE_ID, title: 'Parked notes', isShown: true, isFocused: false, isPlaced: true }],
    });
    await $.session.start(HEADLESS);
    await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    await world.clock.advance(10_000);
    expect(rowsReads(world)).toBe(0);
});

// The modification time and size of a queue file that does not change.
const STEADY: FileTimes = { mtimeMs: 1_000, size: 160 };

// A queue file at QUEUE_PATH that the look finds, standing as `times` says at each look.
function queueFile(times: () => FileTimes): Pick<World, 'exists' | 'stat'> {
    return {
        exists: async (path) => path === QUEUE_PATH,
        stat: (path) => (path === QUEUE_PATH ? times() : 'deny'),
    };
}

// The open's read had no file to look at, so the first tick, at 5 seconds, reads once more and takes the look; the
// ticks after it read nothing until a minute after that read.
test('an open pane on an unchanged queue reads only at the minute', async ($, on) => {
    const world = stage(on, queueFile(() => STEADY));
    await openPane($, 'terminal');
    expect(rowsReads(world)).toBe(1);
    await world.clock.set(5_000);
    expect(rowsReads(world)).toBe(2);
    for (let at = 10_000; at <= 60_000; at += 5_000) {
        await world.clock.set(at);
        expect(rowsReads(world)).toBe(2);
    }
    await world.clock.set(65_000);
    expect(rowsReads(world)).toBe(3);
});

test('a changed modification time is read on the next tick', async ($, on) => {
    let mtimeMs = STEADY.mtimeMs;
    const world = stage(on, queueFile(() => ({ ...STEADY, mtimeMs })));
    await openPane($, 'terminal');
    await world.clock.set(10_000);
    expect(rowsReads(world)).toBe(2);
    mtimeMs += 1;
    await world.clock.set(15_000);
    expect(rowsReads(world)).toBe(3);
});

// The engine lists a queue whose file is gone as an empty one, its path still on the queue line.
test('a deleted queue file is read on the next tick and shows an empty queue', async ($, on) => {
    let isThere = true;
    const world = stage(on, {
        rows: () => rowsOf('shop', isThere ? ROWS_NOTES : [], QUEUE_PATH),
        exists: async (path) => isThere && path === QUEUE_PATH,
        stat: (path) => (isThere && path === QUEUE_PATH ? STEADY : 'deny'),
    });
    const ui = await openPane($, 'terminal');
    await world.clock.set(10_000);
    expect(rowsReads(world)).toBe(2);
    isThere = false;
    await world.clock.set(15_000);
    expect(rowsReads(world)).toBe(3);
    expect(await shows(ui, 'shop: no parked notes')).toBe(true);
    expect(await ui.findAll({ type: 'Text', text: /^later: / })).toEqual([]);
    await world.clock.set(20_000);
    expect(rowsReads(world)).toBe(3);
});

const BILLING = '/home/u/projects/org/billing';

// The file in the other folder looks the same as the first: the folder alone sends the tick to the engine. That read
// names another file than the one looked at, so the tick after it reads once more to take a look at the new one.
test('a session that moved to another folder is read on the next tick', async ($, on) => {
    let cwd: string = SESSION.cwd;
    const world = stage(on, {
        cwd: () => cwd,
        rows: () => (cwd === BILLING ? rowsOf('billing', [['today', RERUN]], `${BILLING}/LATER.local.md`) : ROWS),
        exists: async () => true,
        stat: () => STEADY,
    });
    const ui = await openPane($, 'terminal');
    await world.clock.set(10_000);
    expect(rowsReads(world)).toBe(2);
    cwd = BILLING;
    await world.clock.set(15_000);
    expect(rowsReads(world)).toBe(3);
    expect(await shows(ui, 'billing: 1 parked')).toBe(true);
    await world.clock.set(20_000);
    expect(rowsReads(world)).toBe(4);
    await world.clock.set(25_000);
    expect(rowsReads(world)).toBe(4);
});

// A network location, whose `exists` the module's file layer rejects, and a file whose stat is refused (spec 2.3).
const UNSEEN: ReadonlyArray<readonly [string, Pick<World, 'exists' | 'stat'>]> = [
    ['fs.exists', { exists: async () => 'deny' }],
    ['fs.stat', { exists: async () => true, stat: () => 'deny' }],
];
for (const [refused, files] of UNSEEN) {
    test(`a queue that cannot be seen is read on every tick (${refused} refused)`, async ($, on) => {
        const world = stage(on, files);
        await openPane($, 'terminal');
        for (const [at, reads] of [[5_000, 2], [10_000, 3], [15_000, 4]] as const) {
            await world.clock.set(at);
            expect(rowsReads(world)).toBe(reads);
        }
    });
}

// A file system that stops answering, such as a network mount on Linux or macOS, which the file layer does touch. The
// tick's look gives up after 2 seconds and the pane reads through the engine and shows its answer. While that look
// has not settled, a `d` reads without looking and no tick starts another look; once it settles the ticks look again.
test('a queue file that does not answer is looked at once, then read through the engine', async ($, on) => {
    const answer = held<boolean>();
    let isHung = false;
    const world = stage(on, {
        rows: () => rowsOf('shop', isHung ? [...ROWS_NOTES, ['today', RERUN]] : ROWS_NOTES, QUEUE_PATH),
        exists: async (path) => (isHung ? answer.promise : path === QUEUE_PATH),
        stat: () => STEADY,
    });
    const ui = await openPane($, 'terminal');
    await world.clock.set(5_000);
    expect(rowsReads(world)).toBe(2);
    const looks = world.fileChecks.length;
    isHung = true;
    await world.clock.set(11_999);
    expect(world.fileChecks).toHaveLength(looks + 1);
    expect(rowsReads(world)).toBe(2);
    await world.clock.set(12_000);
    expect(rowsReads(world)).toBe(3);
    expect(await shows(ui, 'shop: 4 parked')).toBe(true);
    const pressed = ui.press({ key: 'done' });
    await world.clock.settle();
    expect(world.fileChecks).toHaveLength(looks + 1);
    expect(rowsReads(world)).toBe(4);
    await pressed;
    await world.clock.set(20_000);
    expect(world.fileChecks).toHaveLength(looks + 1);
    expect(rowsReads(world)).toBe(4);
    answer.release(true);
    await world.clock.set(25_000);
    expect(world.fileChecks).toHaveLength(looks + 2);
    expect(rowsReads(world)).toBe(5);
});

// The read after a `d` waits for the look no longer than a tick does, so the press settles; the tick after it starts no
// second look while the first has not settled.
test('d while the queue file does not answer closes and reads after the timeout', async ($, on) => {
    const answer = held<boolean>();
    const world = stage(on, { exists: () => answer.promise, stat: () => STEADY });
    const ui = await openPane($, 'terminal');
    const pressed = ui.press({ key: 'done' });
    await world.clock.settle();
    expect(engineCalls(world)).toEqual([['rows'], ['done', '--if', '1']]);
    await world.clock.set(2_000);
    expect(engineCalls(world)).toEqual([['rows'], ['done', '--if', '1'], ['rows']]);
    await pressed;
    expect(await shows(ui, `later: done -> ${CHECK}`)).toBe(true);
    await world.clock.set(5_000);
    expect(world.fileChecks).toEqual([QUEUE_PATH]);
    answer.release(true);
});

// The open has no file to look at yet; the first tick and the read after a `d` take the folder and look at the file
// before they run `rows`, and the `d` compares the folder before it runs `done`.
test('the look comes before the read', async ($, on) => {
    const world = stage(on, queueFile(() => STEADY));
    const ui = await openPane($, 'terminal');
    expect(world.sequence).toEqual(['session.cwd', 'process.run rows']);
    await world.clock.set(5_000);
    expect(world.sequence.slice(2)).toEqual(['session.cwd', 'fs.exists', 'fs.stat', 'process.run rows']);
    await ui.press({ key: 'done' });
    expect(world.sequence.slice(6)).toEqual([
        'session.cwd',
        'process.run done --if 1',
        'session.cwd',
        'fs.exists',
        'fs.stat',
        'process.run rows',
    ]);
});

const MOVED = 'later: the session moved to another folder; the list was read again';

// The first `d` reads the list of the folder the session is in now and closes nothing; the second acts on that list.
test('d after the session moved reads again and closes nothing', async ($, on) => {
    let cwd: string = SESSION.cwd;
    const world = stage(on, {
        cwd: () => cwd,
        rows: () => (cwd === BILLING ? rowsOf('billing', [['today', RERUN]], `${BILLING}/LATER.local.md`) : ROWS),
    });
    const ui = await openPane($, 'terminal');
    cwd = BILLING;
    await ui.press({ key: 'done' });
    expect(engineCalls(world)).toEqual([['rows'], ['rows']]);
    expect(await shows(ui, MOVED)).toBe(true);
    expect(await shows(ui, 'billing: 1 parked')).toBe(true);
    await ui.press({ key: 'done' });
    expect(engineRuns(world).slice(2)).toEqual([{ args: ['done', '--if', '1'], stdin: RERUN }, { args: ['rows'] }]);
});

test('w after the session moved reads again and fills nothing', async ($, on) => {
    let cwd: string = SESSION.cwd;
    const world = stage(on, { cwd: () => cwd });
    const ui = await openPane($, 'terminal');
    cwd = BILLING;
    await ui.press({ key: 'work' });
    expect(world.fills).toEqual([]);
    expect(world.closes).toEqual([]);
    expect(engineCalls(world)).toEqual([['rows'], ['rows']]);
    expect(await shows(ui, MOVED)).toBe(true);
});

// The queue file set to `LATER.md` in `/config`.
const SET_FILE = { options: { rewrite: 'off', file: 'LATER.md' } };

// A bare run where the session is not interactive lists, an add parks, and after an interactive start a bare run
// opens the pane and a `d` closes a note and reads again: each run is given the setting.
test('every engine run carries the queue file setting', SET_FILE, async ($, on) => {
    const world = stage(on);
    await $.session.start(HEADLESS);
    await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    const ui = await openPane($, 'terminal');
    await ui.press({ key: 'done' });
    expect(engineCalls(world).map(([verb]) => verb)).toEqual(['list', 'add', 'rows', 'done', 'rows']);
    const files = world.inits.map((init) => init?.env?.['CLAUDE_PLUGIN_OPTION_FILE']);
    expect(files).toEqual(['LATER.md', 'LATER.md', 'LATER.md', 'LATER.md', 'LATER.md']);
});

// The queue file setting of every engine run the world recorded.
function settingOfRuns(world: Stage): (string | undefined)[] {
    return world.inits.map((init) => init?.env?.['CLAUDE_PLUGIN_OPTION_FILE']);
}

test("the pane's a parks with the queue file setting", SET_FILE, async ($, on) => {
    const world = stage(on);
    const ui = await openPane($, 'terminal');
    await ui.press({ key: 'add' });
    await ui.input({ key: 'new-note', text: TYPED });
    expect(engineRuns(world)).toContainEqual({ args: ['add'], stdin: TYPED });
    expect(settingOfRuns(world)).toEqual(engineCalls(world).map(() => 'LATER.md'));
});

test('a pane that is not placed lists with the queue file setting', SET_FILE, async ($, on) => {
    const world = stage(on, { open: 'unplaced' });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    expect(engineCalls(world)).toEqual([['rows'], ['list']]);
    expect(settingOfRuns(world)).toEqual(['LATER.md', 'LATER.md']);
});

test('a refused open lists with the queue file setting', SET_FILE, async ($, on) => {
    const world = stage(on, { open: 'deny' });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    expect(engineCalls(world)).toEqual([['rows'], ['list']]);
    expect(settingOfRuns(world)).toEqual(['LATER.md', 'LATER.md']);
});

// The texts of spec 1.8's worked examples. Passed as arguments, Git for Windows' runtime would replace `@README.md`
// with that file's contents and glob `*.md` and `(the)`.
const AT_FILE = '@README.md *.md';
const PARENS = 'fix (the) export';

// `/later` parks AT_FILE, the pane's `a` parks PARENS, `d` closes AT_FILE and `x` drops PARENS.
test('user text never travels in the argument vector', OFF, async ($, on) => {
    const world = stage(on, liveQueue([]).world);
    const ui = await openPane($, 'terminal');
    await $.command.run({ command: 'later', args: AT_FILE, ...AT_PROMPT });
    await ui.press({ key: 'add' });
    await ui.input({ key: 'new-note', text: PARENS });
    await ui.press({ key: 'done' });
    await ui.press({ key: 'drop' });
    const sent = world.runs.flatMap((argv, index) => (argv[1] === 'rows' ? [] : [{ argv, init: world.inits[index] }]));
    const args = sent.map(({ argv }) => argv.slice(1));
    expect(args).toEqual([['add'], ['add'], ['done', '--if', '1'], ['drop', '--if', '1']]);
    const texts = [AT_FILE, PARENS, AT_FILE, PARENS];
    for (const [index, { argv, init }] of sent.entries()) {
        const text = texts[index] ?? '';
        expect(argv.filter((arg) => arg.includes(text))).toEqual([]);
        expect(init?.stdin).toBe(text);
        expect(init?.env?.['LATER_INPUT']).toBe('stdin');
    }
});

test('a close sends the note text exactly', async ($, on) => {
    const world = stage(on, { rows: () => rowsOf('shop', [['today', 'ends here  ']], QUEUE_PATH) });
    const ui = await openPane($, 'terminal');
    await ui.press({ key: 'done' });
    const index = world.runs.findIndex((argv) => argv[1] === 'done');
    expect(world.runs[index]?.slice(1)).toEqual(['done', '--if', '1']);
    expect(world.inits[index]?.stdin).toBe('ends here  ');
});

// A bare run whose pane is not placed reads `rows` and then lists.
test('runs without user text carry no standard input', async ($, on) => {
    const world = stage(on, { open: 'unplaced' });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    expect(engineCalls(world)).toEqual([['rows'], ['list']]);
    expect(world.inits.map((init) => init !== undefined && 'stdin' in init)).toEqual([false, false]);
    expect(world.inits.map((init) => init?.env !== undefined && 'LATER_INPUT' in init.env)).toEqual([false, false]);
});

// Every queue the module stores, in the order it stores them.
function storedQueues(on: On): unknown[] {
    const queues: unknown[] = [];
    on('state.set', (_$, e, next) => {
        if (e.key === 'queue') {
            queues.push(e.value);
        }
        return next(e);
    });
    return queues;
}

// Two bare runs, the first over a queue line that names the queue file, the second over one that does not.
test('the rows header path is read', async ($, on) => {
    const queues = storedQueues(on);
    let rows = rowsOf('shop', ROWS_NOTES, '/home/u/shop/LATER.local.md');
    stage(on, { rows: () => rows });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    rows = rowsOf('shop', ROWS_NOTES);
    await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    expect(queues).toEqual([
        expect.objectContaining({ kind: 'read', label: 'shop', path: '/home/u/shop/LATER.local.md' }),
        expect.objectContaining({ kind: 'read', label: 'shop', path: '' }),
    ]);
});

// The engine turns a tab in the label into a space, but a folder's tab stays in the path.
test('a tab in the queue path stays in the path', async ($, on) => {
    const queues = storedQueues(on);
    stage(on, { rows: () => rowsOf('tab name', ROWS_NOTES, '/home/u/tab\tname/LATER.local.md') });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    expect(queues).toEqual([
        expect.objectContaining({ kind: 'read', label: 'tab name', path: '/home/u/tab\tname/LATER.local.md' }),
    ]);
});

// Git for Windows' bash launcher where its installer puts it, the bash Claude Code chose for the session as `SHELL`.
const GIT_BASH = 'C:\\Program Files\\Git\\bin\\bash.exe';
const WINDOWS = { OS: 'Windows_NT', SHELL: GIT_BASH };

// The reason every engine run gives when no bash was found, and the line spec 4.1 shows once per session.
const NO_BASH_REASON =
    "Git for Windows' bash was not found. Install Git for Windows (https://git-scm.com/download/win) and restart " +
    'Claude Code.';
const NO_BASH_LINE = `laterbox: ${NO_BASH_REASON}`;

test('on Windows the engine runs through the bash Claude Code chose', OFF, async ($, on) => {
    const world = stage(on, { env: WINDOWS, files: [GIT_BASH] });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: 'x', ...AT_PROMPT });
    expect(world.runs).toHaveLength(1);
    const [bash, script, ...args] = world.runs[0] ?? [];
    expect(bash).toBe(GIT_BASH);
    expect(script).toEndWith('/scripts/later.sh');
    expect(script).not.toContain('\\');
    expect(args).toEqual(['add']);
    expect(world.toasts).toEqual([]);
});

// The bash the search found at session start no longer starts: the reason names it and asks for a restart.
test('a bash that is gone asks for a restart', OFF, async ($, on) => {
    const world = stage(on, { env: WINDOWS, files: [GIT_BASH], engine: 'deny' });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: 'x', ...AT_PROMPT });
    expect(world.runs[0]?.[0]).toBe(GIT_BASH);
    expect(result).toEqual({
        text:
            `later: could not park the note (the bash at ${GIT_BASH} is gone; restart Claude Code to search ` +
            'again); typed: x',
    });
    expect(world.debugLines).toHaveLength(1);
    expect(world.debugLines[0]).toMatch(/^later: engine run failed: .*\bspawn ENOENT$/);
});

// The SHELL a Windows session would start, but without `OS=Windows_NT` nothing is searched.
test('without OS=Windows_NT the engine runs directly', OFF, async ($, on) => {
    const world = stage(on, { env: { SHELL: GIT_BASH }, files: [GIT_BASH] });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: 'x', ...AT_PROMPT });
    expect(world.runs).toHaveLength(1);
    expect(world.runs[0]?.[0]).toEndWith('/scripts/later.sh');
    expect(world.runs[0]?.slice(1)).toEqual(['add']);
    expect(world.fileChecks).toEqual([]);
});

// A session that is not interactive parks and lists; an interactive one opens the pane. Each start searches once
// (spec 1.4) and shows the line once; the runs in between show none.
test('no bash: one toast and a plain reason everywhere', OFF, async ($, on) => {
    const world = stage(on, { env: { OS: 'Windows_NT' } });
    await $.session.start(HEADLESS);
    const parked = await $.command.run({ command: 'later', args: 'x', ...AT_PROMPT });
    expect(parked).toEqual({ text: `later: could not park the note (${NO_BASH_REASON}); typed: x` });
    const listed = await $.command.run({ command: 'later', args: '', ...AT_PROMPT });
    expect(listed).toEqual({ text: `later: ${NO_BASH_REASON}` });
    await world.clock.settle();
    expect(world.toasts).toEqual([NO_BASH_LINE]);
    const ui = await openPane($, 'terminal');
    expect(await shows(ui, `later: ${NO_BASH_REASON}`)).toBe(true);
    expect(await buttonKeys(ui)).toEqual(['add']);
    await world.clock.settle();
    expect(world.toasts).toEqual([NO_BASH_LINE, NO_BASH_LINE]);
    expect(world.runs).toEqual([]);
});

// Every read refused, `OS` among them: the host is not taken as Windows, so the engine runs as before (spec 1.1, R6).
test('refused variable reads leave the engine running directly', OFF, async ($, on) => {
    const world = stage(on, { isEnvRefused: () => true });
    await $.session.start(HEADLESS);
    const parked = await $.command.run({ command: 'later', args: 'x', ...AT_PROMPT });
    expect(parked.text).toBe('later: parked -> x');
    expect(world.runs).toHaveLength(1);
    expect(world.runs[0]?.[0]).toEndWith('/scripts/later.sh');
    await world.clock.settle();
    expect(world.toasts).toEqual([]);
});

// On Windows a refused read skips only its own step: without PATH the search still takes SHELL.
test('on Windows a refused PATH read still finds the bash in SHELL', OFF, async ($, on) => {
    const world = stage(on, { env: WINDOWS, files: [GIT_BASH], isEnvRefused: (name) => name === 'PATH' });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: 'x', ...AT_PROMPT });
    expect(world.runs).toHaveLength(1);
    expect(world.runs[0]?.[0]).toBe(GIT_BASH);
    await world.clock.settle();
    expect(world.toasts).toEqual([]);
});

// An answer the test holds until it releases it.
function held<T>(): { readonly promise: Promise<T>; readonly release: (value: T) => void } {
    let release: (value: T) => void = () => undefined;
    const promise = new Promise<T>((settle) => {
        release = settle;
    });
    return { promise, release };
}

// The search's file check is held: the start resolves meanwhile, and a `/later` that arrives before the search
// finished waits for it, then runs through the bash it found.
test('session start does not wait for the search', OFF, async ($, on) => {
    const answer = held<boolean>();
    const world = stage(on, { env: WINDOWS, exists: () => answer.promise });
    let isStarted = false;
    const started = $.session.start(SESSION).then(() => {
        isStarted = true;
    });
    await world.clock.settle();
    expect(isStarted).toBe(true);
    expect(world.fileChecks).toEqual([GIT_BASH]);
    const run = $.command.run({ command: 'later', args: 'x', ...AT_PROMPT });
    await world.clock.settle();
    expect(world.runs).toEqual([]);
    answer.release(true);
    await Promise.all([started, run]);
    expect(world.runs[0]?.[0]).toBe(GIT_BASH);
});
