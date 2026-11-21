import { expect, test } from 'claude-code/testing';
import type { ToolRequest } from './tool';
import { parseToolInput, TOOL_DESCRIPTION, TOOL_INPUT_SCHEMA } from './tool';

const ACTION_REASON = 'action must be list, show, add, done or drop';
const ADD_REASON = 'add needs a note that is not empty';
const IDS_REASON =
    'show, done and drop need ids from a listing: the 8 characters in square brackets on a line, without the ' +
    'brackets; list first';

// The keys every call carries beside the tool's own arguments.
const RESERVED = { tool: 'mcp__laterbox__queue', tool_use_id: 'toolu_01', consent: 'The user asked for it' } as const;

// Review focus 2: 100 words of 19 characters, each pair apart by 6 spaces and a newline. 2,593 characters as given,
// 1,999 once every run of whitespace is one space.
const SPACED_NOTE = Array.from({ length: 100 }, () => 'abcdefghijklmnopqrs').join('      \n');

// U+1F600, a character outside the basic plane: one code point and two UTF-16 units. Spec 5.1 counts code points.
const ASTRAL = '\u{1F600}';

// One row per refused input: what it is, the input, and the reason.
const REFUSED: ReadonlyArray<readonly [string, unknown, string]> = [
    ['no action', {}, ACTION_REASON],
    ['an unknown action', { action: 'peek' }, ACTION_REASON],
    ['an action that is not a string', { action: 1 }, ACTION_REASON],
    ['an input that is not an object', 'list', ACTION_REASON],
    ['no input', undefined, ACTION_REASON],
    ['null', null, ACTION_REASON],
    ['add without a note', { action: 'add' }, ADD_REASON],
    ['add with a note of spaces', { action: 'add', note: '  ' }, ADD_REASON],
    ['add with an empty note', { action: 'add', note: '' }, ADD_REASON],
    ['add with a note that is not a string', { action: 'add', note: 5 }, ADD_REASON],
    [
        'add with a note of 2001 characters',
        { action: 'add', note: 'x'.repeat(2_001) },
        'the note is 2001 characters and the limit is 2000; shorten it and park it again',
    ],
    [
        'add with a note of 2001 characters outside the basic plane',
        { action: 'add', note: ASTRAL.repeat(2_001) },
        'the note is 2001 characters and the limit is 2000; shorten it and park it again',
    ],
    ['show without ids', { action: 'show' }, IDS_REASON],
    ['done without ids', { action: 'done' }, IDS_REASON],
    ['drop without ids', { action: 'drop' }, IDS_REASON],
    ['done with no id in ids', { action: 'done', ids: [] }, IDS_REASON],
    ['drop with ids that is not an array', { action: 'drop', ids: 'ea2c489f' }, IDS_REASON],
    ['show with an id that is not a string', { action: 'show', ids: ['ea2c489f', 7] }, IDS_REASON],
    ['done with an id of 6 characters', { action: 'done', ids: ['ea2c48'] }, IDS_REASON],
    ['drop with an id in its square brackets', { action: 'drop', ids: ['[ea2c489f]'] }, IDS_REASON],
    ['done with an id in upper case', { action: 'done', ids: ['EA2C489F'] }, IDS_REASON],
    ['done in the old form of a number and a text', { action: 'done', number: 1, text: 'a' }, IDS_REASON],
];
for (const [name, input, reason] of REFUSED) {
    test(`${name} is refused`, async () => {
        expect(parseToolInput(input)).toEqual({ ok: false, reason });
    });
}

// One row per accepted input: what it is, the input, and the request it gives. A note is kept exactly as given, and
// ids each once in the order first given; keys of another form and the reserved keys are ignored.
const ACCEPTED: ReadonlyArray<readonly [string, unknown, ToolRequest]> = [
    ['list', { action: 'list' }, { action: 'list' }],
    ['add', { action: 'add', note: 'Rerun the flaky test' }, { action: 'add', note: 'Rerun the flaky test' }],
    ['add keeps the note as given', { action: 'add', note: ' a\n b ' }, { action: 'add', note: ' a\n b ' }],
    [
        'add with a note of 2000 characters',
        { action: 'add', note: 'x'.repeat(2_000) },
        { action: 'add', note: 'x'.repeat(2_000) },
    ],
    [
        'add with a note of 2000 characters outside the basic plane',
        { action: 'add', note: ASTRAL.repeat(2_000) },
        { action: 'add', note: ASTRAL.repeat(2_000) },
    ],
    [
        'add with a note of 2593 characters that collapse to 1999',
        { action: 'add', note: SPACED_NOTE },
        { action: 'add', note: SPACED_NOTE },
    ],
    ['show', { action: 'show', ids: ['ea2c489f'] }, { action: 'show', ids: ['ea2c489f'] }],
    ['done', { action: 'done', ids: ['ea2c489f'] }, { action: 'done', ids: ['ea2c489f'] }],
    [
        'drop with an id given twice',
        { action: 'drop', ids: ['46f2440c', 'ea2c489f', '46f2440c'] },
        { action: 'drop', ids: ['46f2440c', 'ea2c489f'] },
    ],
    ['the reserved keys', { ...RESERVED, action: 'list' }, { action: 'list' }],
    [
        'keys of the other forms on a list',
        { action: 'list', note: 'x', ids: [], number: 0, text: '' },
        { action: 'list' },
    ],
    [
        'keys of the other forms on an add',
        { action: 'add', note: 'x', ids: 'none', number: 'two', text: 5 },
        { action: 'add', note: 'x' },
    ],
    [
        'keys of the other forms on a close',
        { action: 'drop', ids: ['46f2440c'], note: '', number: 2, text: 'b' },
        { action: 'drop', ids: ['46f2440c'] },
    ],
    ['a note on a show', { action: 'show', ids: ['46f2440c'], note: 5 }, { action: 'show', ids: ['46f2440c'] }],
];
for (const [name, input, request] of ACCEPTED) {
    test(`${name} is accepted`, async () => {
        expect(parseToolInput(input)).toStrictEqual({ ok: true, request });
    });
}

test('the note built of spaced words is 2593 characters as given', async () => {
    expect(SPACED_NOTE.length).toBe(2_593);
    expect(SPACED_NOTE.replace(/\s+/g, ' ').trim().length).toBe(1_999);
});

test('the input schema names the five actions and their fields', async () => {
    expect(TOOL_INPUT_SCHEMA).toEqual({
        type: 'object',
        properties: {
            action: { type: 'string', enum: ['list', 'show', 'add', 'done', 'drop'] },
            note: { type: 'string' },
            ids: { type: 'array', items: { type: 'string', pattern: '^[0-9a-f]{8}$' }, minItems: 1 },
        },
        required: ['action'],
    });
});

test('the description names the five actions, the cut, the limit, the id and what a refusal means', async () => {
    expect(TOOL_DESCRIPTION.length).toBeLessThanOrEqual(862);
    for (const words of ['list', 'show', 'add', 'done', 'drop', 'ids', '"..."', '2000', 'the id is "07be33aa"']) {
        expect(TOOL_DESCRIPTION).toContain(words);
    }
    expect(TOOL_DESCRIPTION).toContain('no open note');
    expect(TOOL_DESCRIPTION).not.toMatch(/[\u2013\u2014]/);
});
