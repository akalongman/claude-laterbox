// The queue tool the skill reaches the engine through (spec R3): what the model may ask of it, how a call's arguments
// are checked, and the engine run each request makes. The hooks module registers the tool and runs the engine, so
// nothing here touches the engine.

// One request of the tool: list the open notes, park one note, or close one note named by its number and its text
// in the listing the model took (3.1).
export type ToolRequest =
    | { readonly action: 'list' }
    | { readonly action: 'add'; readonly note: string }
    | { readonly action: 'done' | 'drop'; readonly number: number; readonly text: string };

// The three reasons a call is refused, one per form; the hooks module puts `later: ` before them.
const ACTION_REASON = 'action must be list, add, done or drop';
const ADD_REASON = 'add needs a note that is not empty';
const CLOSE_REASON = "done and drop need a whole note number of 1 or more and the note's text";

// What the model reads about the tool: the four actions, the guard of a close, and what its refusal means.
export const TOOL_DESCRIPTION = [
    "Lists, adds, closes and drops the project's parked notes: follow-ups the user saved for a later session,",
    'reminders rather than tasks for now.',
    'action "list" lists the open notes, numbered.',
    'action "add" parks the text given as note.',
    'action "done" closes a note as finished and action "drop" drops one no longer needed: each acts on one note,',
    'named by its number and its exact text from a fresh listing.',
    'A done or drop refused because the note "changed since it was listed" means the queue changed after that',
    'listing and nothing was closed: list again.',
].join(' ');

// The input the model gives: an action, and the fields its form takes.
export const TOOL_INPUT_SCHEMA = {
    type: 'object',
    properties: {
        action: { type: 'string', enum: ['list', 'add', 'done', 'drop'] },
        note: { type: 'string' },
        number: { type: 'integer', minimum: 1 },
        text: { type: 'string' },
    },
    required: ['action'],
} as const;

// A call's arguments as a request, or the reason it is refused. Only the keys of the action's own form are read:
// the call's reserved keys (`tool`, `tool_use_id`, `consent`) and the keys of another form are ignored. A note and
// a text are kept exactly as given; a note is refused when it is empty once trimmed, a text only when it is empty,
// since a close compares it with the note byte for byte.
export function parseToolInput(
    input: unknown,
): { readonly ok: true; readonly request: ToolRequest } | { readonly ok: false; readonly reason: string } {
    if (typeof input !== 'object' || input === null) {
        return { ok: false, reason: ACTION_REASON };
    }
    const action = 'action' in input ? input.action : undefined;
    if (action === 'list') {
        return { ok: true, request: { action } };
    }
    if (action === 'add') {
        const note = 'note' in input ? input.note : undefined;
        return typeof note === 'string' && note.trim() !== ''
            ? { ok: true, request: { action, note } }
            : { ok: false, reason: ADD_REASON };
    }
    if (action === 'done' || action === 'drop') {
        const number = 'number' in input ? input.number : undefined;
        const text = 'text' in input ? input.text : undefined;
        const isWholeNumber = typeof number === 'number' && Number.isInteger(number) && number >= 1;
        return isWholeNumber && typeof text === 'string' && text !== ''
            ? { ok: true, request: { action, number, text } }
            : { ok: false, reason: CLOSE_REASON };
    }
    return { ok: false, reason: ACTION_REASON };
}

// The engine run of a request (3.2): `list`; `add` with the note as input; `done` or `drop` guarded by `--if` and the
// note's number, with its text as input. The hooks module sends the input on standard input.
export function engineCallOf(request: ToolRequest): { readonly args: ReadonlyArray<string>; readonly input?: string } {
    switch (request.action) {
        case 'list':
            return { args: ['list'] };
        case 'add':
            return { args: ['add'], input: request.note };
        case 'done':
        case 'drop':
            return { args: [request.action, '--if', String(request.number)], input: request.text };
        default: {
            const exhaustive: never = request;
            return exhaustive;
        }
    }
}
