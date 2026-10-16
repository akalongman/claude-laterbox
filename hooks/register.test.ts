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
    readonly engine?: EngineReply | 'deny'; // answers every engine run
    readonly rows?: () => string; // stdout of `later.sh rows`
    readonly closeNote?: (args: ReadonlyArray<string>) => EngineReply; // answers `done` and `drop`
    readonly add?: (note: string) => EngineReply; // answers `add`
    readonly messages?: ReadonlyArray<SessionMessage> | 'deny';
    readonly completion?: ModelCompleteResult;
    readonly fork?: ModelForkResult | 'deny' | 'slow';
    readonly open?: 'placed' | 'unplaced' | 'deny';
    readonly panes?: ReadonlyArray<UiPane>;
    readonly draft?: string;
    readonly draftRead?: 'deny'; // refuses `$.prompt.read`
    readonly fill?: PromptFillResult;
};

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
};

const PANE_ID = 'later-notes';
const CHECK = 'Check the S3 retry path in UploadJob';
const ASK = 'Ask the payments team about the invoice export';
const RAISE = 'Raise the queue timeout on staging';
const RERUN = 'Rerun the flaky test';
const LISTING = 'app: 2 parked\n 1. Move the upload config to env (3d)\n 2. Recheck the retry path (today)\n';
const HEADLESS = { ...SESSION, isInteractive: false } as const;

// `later.sh rows` for a queue labelled `label`, one [age, text] pair per open note.
function rowsOf(label: string, notes: ReadonlyArray<readonly [string, string]>): string {
    return (
        [`queue\t${label}`, ...notes.map(([age, text], index) => `note\t${index + 1}\t${age}\t${text}`)].join('\n') +
        '\n'
    );
}
const ROWS = rowsOf('shop', [['3d', CHECK], ['today', ASK], ['12d', RAISE]]);

function key(text: string, occurrence = 1): string {
    return `note:${occurrence}:${text}`;
}

// The engine as the tests need it: rows from the world, `done` and `drop` from closeNote, `add` from add.
function engineReply(world: World, args: ReadonlyArray<string>): EngineReply {
    const ok = (stdout: string): EngineReply => ({ exitCode: 0, stdout, stderr: '' });
    switch (args[0]) {
        case 'rows':
            return ok((world.rows ?? (() => ROWS))());
        case 'list':
            return ok(LISTING);
        case 'done':
        case 'drop':
            return (
                world.closeNote?.(args) ??
                ok(`later: ${args[0] === 'done' ? 'done' : 'dropped'} -> ${args[2] ?? ''}\n`)
            );
        default:
            return world.add?.(args[1] ?? '') ?? ok(`later: parked -> ${args[1] ?? ''}\n`);
    }
}

function engineCalls(world: Stage): string[][] {
    return world.runs.map((run) => run.slice(1));
}

// The world beneath the plugin: every call it makes is recorded and answered from `world`, and every event the
// tests raise has a bottom. Defaults: the registration succeeds, the engine answers as engineReply does (ROWS for
// `rows`, LISTING for `list`, and it parks or closes whatever it is given), the transcript is empty, the completion
// answers CLEAN, the fork has nothing to fork, the pane is placed, no pane is open, the draft is empty and a fill
// succeeds.
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
    };
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
    on('process.run', (_$, e) => {
        recorded.runs.push([...e.argv]);
        recorded.inits.push(e.init);
        if (world.engine === 'deny') {
            return { deny: 'spawn ENOENT' };
        }
        const reply = world.engine ?? engineReply(world, e.argv.slice(1));
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
    expect(world.runs[0]?.slice(1)).toEqual(['add', TYPED]);
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
    expect(world.runs[0]?.slice(1)).toEqual(['add', weird]);
});

test('an engine exit code names the reason and keeps the typed text on screen', OFF, async ($, on) => {
    stage(on, { engine: { exitCode: 1, stdout: '', stderr: 'later: the queue is locked by another writer\n' } });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(result).toEqual({
        text: `later: could not park the note (the queue is locked by another writer); typed: ${TYPED}`,
    });
});

test('an engine exit code without stderr names the code', OFF, async ($, on) => {
    stage(on, { engine: { exitCode: 2, stdout: '', stderr: '' } });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(result).toEqual({ text: `later: could not park the note (exit code 2); typed: ${TYPED}` });
});

test('an engine that cannot start reports the rejection', OFF, async ($, on) => {
    stage(on, { engine: 'deny' });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(result.context).toBeUndefined();
    expect(result.text).toStartWith('later: could not park the note (');
    expect(result.text).toContain('spawn ENOENT');
    expect(result.text).toEndWith(`; typed: ${TYPED}`);
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
    expect(world.runs[0]?.slice(1)).toEqual(['add', CLEAN]);
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
    expect(world.runs[0]?.slice(1)).toEqual(['add', TYPED]);
    expect(result.text).toBe(`later: parked -> ${TYPED}`);
});

test('a 300-character answer is accepted', async ($, on) => {
    const world = stage(on, { completion: answered(`  ${'y'.repeat(300)}  `) });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.runs[0]?.slice(1)).toEqual(['add', 'y'.repeat(300)]);
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
        expect(world.runs[0]?.slice(1)).toEqual(['add', TYPED]);
        expect(result.text).toBe(`later: parked -> ${TYPED}`);
    });
}

test('a long typed note is stored whole when the model fails', async ($, on) => {
    const long = 'word '.repeat(200).trim();
    const world = stage(on, { completion: { isAnswered: false, reason: 'empty-reply', usage: USAGE } });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: long, ...AT_PROMPT });
    expect(world.runs[0]?.slice(1)).toEqual(['add', long]);
    expect(result.text).toBe(`later: parked -> ${long}`);
});

test('a transcript that cannot be read still gets a rewrite without context', async ($, on) => {
    const world = stage(on, { messages: 'deny' });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.completions).toHaveLength(1);
    expect(world.completions[0]?.prompt).toContain('(none)');
    expect(world.runs[0]?.slice(1)).toEqual(['add', CLEAN]);
    expect(result.text).toBe(`later: parked -> ${CLEAN} (typed: ${TYPED})`);
});

test('a rewrite value outside the options behaves as haiku', { options: { rewrite: 'turbo' } }, async ($, on) => {
    const world = stage(on);
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.completions).toHaveLength(1);
    expect(world.runs[0]?.slice(1)).toEqual(['add', CLEAN]);
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
    expect(world.runs[0]?.slice(1)).toEqual(['add', CLEAN]);
    expect(result.text).toBe(`later: parked -> ${CLEAN} (typed: ${TYPED})`);
});

test('nothing to fork falls through to the small model', FORK, async ($, on) => {
    const world = stage(on);
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.forks).toHaveLength(1);
    expect(world.completions).toHaveLength(1);
    expect(world.runs[0]?.slice(1)).toEqual(['add', CLEAN]);
});

test('a fork the engine refuses falls through to the small model', FORK, async ($, on) => {
    const world = stage(on, { fork: 'deny' });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.forks).toHaveLength(1);
    expect(world.completions).toHaveLength(1);
    expect(world.runs[0]?.slice(1)).toEqual(['add', CLEAN]);
});

test('a fork answer that fails acceptance falls through to the small model', FORK, async ($, on) => {
    const world = stage(on, { fork: answered('Check the S3 retry path\nin UploadJob') });
    await $.session.start(SESSION);
    await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.forks).toHaveLength(1);
    expect(world.completions).toHaveLength(1);
    expect(world.runs[0]?.slice(1)).toEqual(['add', CLEAN]);
});

test('when the fork and the small model both fail the typed text is stored', FORK, async ($, on) => {
    const world = stage(on, { fork: 'deny', completion: { isAnswered: false, reason: 'aborted', usage: USAGE } });
    await $.session.start(SESSION);
    const result = await $.command.run({ command: 'later', args: TYPED, ...AT_PROMPT });
    expect(world.forks).toHaveLength(1);
    expect(world.completions).toHaveLength(1);
    expect(world.runs[0]?.slice(1)).toEqual(['add', TYPED]);
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
    expect(world.runs[0]?.slice(1)).toEqual(['add', CLEAN]);
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

// A queue the stubbed engine reads, closes notes in (checking --if as later.sh does) and parks notes into.
function liveQueue(initial: ReadonlyArray<string>): {
    readonly world: World;
    readonly set: (texts: ReadonlyArray<string>) => void;
} {
    let texts = [...initial];
    const ok = (stdout: string): EngineReply => ({ exitCode: 0, stdout, stderr: '' });
    return {
        set: (next) => {
            texts = [...next];
        },
        world: {
            rows: () => rowsOf('shop', texts.map((text) => ['today', text] as const)),
            closeNote: ([mode, , text, n]) => {
                const index = Number(n) - 1;
                if (texts[index] !== text) {
                    return {
                        exitCode: 1,
                        stdout: '',
                        stderr: `later: note ${n} changed since it was listed; nothing changed\n`,
                    };
                }
                texts = texts.filter((_, at) => at !== index);
                return ok(`later: ${mode === 'done' ? 'done' : 'dropped'} -> ${text}\n`);
            },
            add: (note) => {
                texts = [...texts, note];
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
            expect(engineCalls(world)).toContainEqual(['done', '--if', ASK, '2']);
            expect(await shows(ui, `later: done -> ${ASK}`)).toBe(true);
            expect(await shows(ui, 'shop: 2 parked')).toBe(true);
            expect((await ui.find({ key: key(RAISE) }))?.text).toStartWith('> 2. ');
            expect(engineCalls(world).filter(([verb]) => verb === 'rows')).toHaveLength(2);
        });

        test('x drops the selected note', async ($, on) => {
            const world = stage(on, liveQueue([CHECK, ASK, RAISE]).world);
            const ui = await openPane($, surface);
            await ui.press({ key: 'drop' });
            expect(engineCalls(world)).toContainEqual(['drop', '--if', CHECK, '1']);
            expect(await shows(ui, `later: dropped -> ${CHECK}`)).toBe(true);
        });

        test('a refused d re-reads and keeps the selected note', async ($, on) => {
            const queue = liveQueue([CHECK, ASK, RAISE]);
            const world = stage(on, queue.world);
            const ui = await openPane($, surface);
            await personFocus($, key(RAISE));
            queue.set([ASK, RAISE]);
            await ui.press({ key: 'done' });
            expect(engineCalls(world)).toContainEqual(['done', '--if', RAISE, '3']);
            expect(await shows(ui, 'later: note 3 changed since it was listed; nothing changed')).toBe(true);
            expect((await ui.find({ key: key(RAISE) }))?.text).toStartWith('> 2. ');
            await ui.press({ key: 'done' });
            expect(engineCalls(world)).toContainEqual(['done', '--if', RAISE, '2']);
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
            expect(engineCalls(world)).toContainEqual(['done', '--if', RAISE, '3']);
        });

        test('duplicate notes get distinct rows, and d acts on the one selected', async ($, on) => {
            const world = stage(on, { rows: () => rowsOf('shop', [['today', RERUN], ['today', RERUN]]) });
            const ui = await openPane($, surface);
            expect(await buttonKeys(ui)).toEqual(expect.arrayContaining([key(RERUN, 1), key(RERUN, 2)]));
            await personFocus($, key(RERUN, 2));
            await ui.press({ key: 'done' });
            expect(engineCalls(world)).toContainEqual(['done', '--if', RERUN, '2']);
        });

        test('a second d pressed while the first runs is ignored', async ($, on) => {
            const world = stage(on, liveQueue([RERUN, RERUN, RAISE]).world);
            const ui = await openPane($, surface);
            await Promise.all([ui.press({ key: 'done' }), ui.press({ key: 'done' })]);
            expect(engineCalls(world).filter(([verb]) => verb === 'done')).toEqual([['done', '--if', RERUN, '1']]);
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
            expect(engineCalls(world)).toContainEqual(['done', '--if', RERUN, '1']);
        });

        test('d on the first of two twins selects the row now at its place', async ($, on) => {
            const world = stage(on, liveQueue([RERUN, RAISE, RERUN]).world);
            const ui = await openPane($, surface);
            await ui.press({ key: 'done' });
            expect(engineCalls(world)).toContainEqual(['done', '--if', RERUN, '1']);
            expect((await ui.find({ key: key(RAISE) }))?.text).toStartWith('> 1. ');
        });

        test('d on the last of two twins selects the row now at its place', async ($, on) => {
            const world = stage(on, liveQueue([RERUN, RAISE, RERUN]).world);
            const ui = await openPane($, surface);
            await personFocus($, key(RERUN, 2));
            await ui.press({ key: 'done' });
            expect(engineCalls(world)).toContainEqual(['done', '--if', RERUN, '3']);
            expect((await ui.find({ key: key(RAISE) }))?.text).toStartWith('> 2. ');
        });

        test('a note ending in a space is closed with the space', async ($, on) => {
            const world = stage(on, { rows: () => rowsOf('shop', [['today', 'text ']]) });
            const ui = await openPane($, surface);
            await ui.press({ key: 'done' });
            expect(engineCalls(world)).toContainEqual(['done', '--if', 'text ', '1']);
        });

        test('a note holding a tab is drawn whole and sent whole', async ($, on) => {
            const split = 'split\there';
            const world = stage(on, { rows: () => rowsOf('shop', [['undated', split]]) });
            const ui = await openPane($, surface);
            expect((await ui.find({ key: key(split) }))?.text).toContain(split);
            await ui.press({ key: 'done' });
            expect(engineCalls(world)).toContainEqual(['done', '--if', split, '1']);
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
            expect(engineCalls(world)).toContainEqual(['add', CLEAN]);
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

test('the open pane reads the queue every five seconds', async ($, on) => {
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
    expect(engineCalls(world)).toContainEqual(['add', TYPED]);
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
