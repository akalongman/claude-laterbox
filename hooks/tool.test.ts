import { expect, test } from 'claude-code/testing';
import type { ToolRequest } from './tool';
import { engineCallOf, parseToolInput, TOOL_DESCRIPTION, TOOL_INPUT_SCHEMA } from './tool';

const ACTION_REASON = 'action must be list, add, done or drop';
const ADD_REASON = 'add needs a note that is not empty';
const CLOSE_REASON = "done and drop need a whole note number of 1 or more and the note's text";

// The keys every call carries beside the tool's own arguments.
const RESERVED = { tool: 'mcp__laterbox__queue', tool_use_id: 'toolu_01', consent: 'The user asked for it' } as const;

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
    ['done with number 0', { action: 'done', number: 0, text: 'a' }, CLOSE_REASON],
    ['done with number -1', { action: 'done', number: -1, text: 'a' }, CLOSE_REASON],
    ['done with number 1.5', { action: 'done', number: 1.5, text: 'a' }, CLOSE_REASON],
    ["done with the string '2'", { action: 'done', number: '2', text: 'a' }, CLOSE_REASON],
    ['done with a number that is not finite', { action: 'done', number: Infinity, text: 'a' }, CLOSE_REASON],
    ['done with NaN', { action: 'done', number: NaN, text: 'a' }, CLOSE_REASON],
    ['drop without text', { action: 'drop', number: 2 }, CLOSE_REASON],
    ['drop with empty text', { action: 'drop', number: 2, text: '' }, CLOSE_REASON],
    ['drop with text that is not a string', { action: 'drop', number: 2, text: 7 }, CLOSE_REASON],
    ['drop without a number', { action: 'drop', text: 'a' }, CLOSE_REASON],
];
for (const [name, input, reason] of REFUSED) {
    test(`${name} is refused`, async () => {
        expect(parseToolInput(input)).toEqual({ ok: false, reason });
    });
}

// One row per accepted input: what it is, the input, and the request it gives. A note and a text are kept exactly
// as given; keys of another form and the reserved keys are ignored.
const ACCEPTED: ReadonlyArray<readonly [string, unknown, ToolRequest]> = [
    ['list', { action: 'list' }, { action: 'list' }],
    ['add', { action: 'add', note: 'Rerun the flaky test' }, { action: 'add', note: 'Rerun the flaky test' }],
    ['add keeps the note as given', { action: 'add', note: ' a\n b ' }, { action: 'add', note: ' a\n b ' }],
    ['done', { action: 'done', number: 1, text: 'a' }, { action: 'done', number: 1, text: 'a' }],
    ['drop', { action: 'drop', number: 12, text: 'ends here  ' }, { action: 'drop', number: 12, text: 'ends here  ' }],
    ['done with text of spaces', { action: 'done', number: 3, text: ' ' }, { action: 'done', number: 3, text: ' ' }],
    ['the reserved keys', { ...RESERVED, action: 'list' }, { action: 'list' }],
    ['keys of the other forms on a list', { action: 'list', note: 'x', number: 0, text: '' }, { action: 'list' }],
    [
        'keys of the close form on an add',
        { action: 'add', note: 'x', number: 'two', text: 5 },
        { action: 'add', note: 'x' },
    ],
    ['a note on a close', { action: 'drop', number: 2, text: 'b', note: '' }, { action: 'drop', number: 2, text: 'b' }],
];
for (const [name, input, request] of ACCEPTED) {
    test(`${name} is accepted`, async () => {
        expect(parseToolInput(input)).toStrictEqual({ ok: true, request });
    });
}

test('list runs list with no input', async () => {
    const call = engineCallOf({ action: 'list' });
    expect(call).toStrictEqual({ args: ['list'] });
    expect('input' in call).toBe(false);
});

test('add runs add with the note as input', async () => {
    expect(engineCallOf({ action: 'add', note: ' @README.md *.md ' })).toStrictEqual({
        args: ['add'],
        input: ' @README.md *.md ',
    });
});

test('done runs a guarded done with the text as input', async () => {
    expect(engineCallOf({ action: 'done', number: 2, text: 'B' })).toStrictEqual({
        args: ['done', '--if', '2'],
        input: 'B',
    });
});

test('drop runs a guarded drop with the text as input', async () => {
    expect(engineCallOf({ action: 'drop', number: 10, text: 'ends here  ' })).toStrictEqual({
        args: ['drop', '--if', '10'],
        input: 'ends here  ',
    });
});

test('the input schema names the four actions and their fields', async () => {
    expect(TOOL_INPUT_SCHEMA).toEqual({
        type: 'object',
        properties: {
            action: { type: 'string', enum: ['list', 'add', 'done', 'drop'] },
            note: { type: 'string' },
            number: { type: 'integer', minimum: 1 },
            text: { type: 'string' },
        },
        required: ['action'],
    });
});

test('the description names the four actions and the guard', async () => {
    for (const word of ['list', 'add', 'done', 'drop', 'number', 'exact text', 'refus']) {
        expect(TOOL_DESCRIPTION).toContain(word);
    }
    expect(TOOL_DESCRIPTION).not.toMatch(/[\u2013\u2014]/);
});
