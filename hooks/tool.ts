// The queue tool the skill reaches the engine through (spec R6): what the model may ask of it and how a call's
// arguments are checked. The hooks module registers the tool, runs the engine and writes the answers, so nothing here
// touches the engine.

// One request of the tool: list the open notes, show some whole, park one note, or close some, the notes named by
// the ids of a listing (6.1).
export type ToolRequest =
    | { readonly action: 'list' }
    | { readonly action: 'show'; readonly ids: ReadonlyArray<string> }
    | { readonly action: 'add'; readonly note: string }
    | { readonly action: 'done' | 'drop'; readonly ids: ReadonlyArray<string> };

// The most characters a note parked through the tool may have, counted as the queue stores it (5.1).
export const ADD_MAX_CHARS = 2_000;

// An id as a listing writes it, without its square brackets (1.2).
const ID_PATTERN = /^[0-9a-f]{8}$/;

// The reasons a call is refused; the hooks module puts `later: ` before them.
const ACTION_REASON = 'action must be list, show, add, done or drop';
const ADD_REASON = 'add needs a note that is not empty';
const IDS_REASON =
    'show, done and drop need ids from a listing: the 8 characters in square brackets on a line, without the ' +
    'brackets; list first';

// The reason of a note over the limit, with its length and what to do (5.1).
function limitReason(length: number): string {
    return `the note is ${length} characters and the limit is ${ADD_MAX_CHARS}; shorten it and park it again`;
}

// What the model reads about the tool (6.3): the five actions, the cut of a listing, the limit of a note, the ids a
// show or a close takes, and what its refusal means. No longer than the 862 characters of 0.3.2.
export const TOOL_DESCRIPTION = [
    "Lists, reads, adds, closes and drops the project's parked notes: follow-ups the user saved for a later session,",
    'reminders rather than tasks for now.',
    'action "list" lists the open notes, a line each: number, id in square brackets, text, age.',
    'A text over 100 characters is cut there and ends in "...".',
    'action "show" returns the notes named in ids whole.',
    'action "add" parks the text given as note, at most 2000 characters.',
    'action "done" closes notes as finished and action "drop" drops notes no longer needed: both take ids, one or',
    'more, each as a listing shows it, without the brackets.',
    'For the line " 2. [07be33aa] renew the certificate (3d)" the id is "07be33aa".',
    'An id names its note until the note changes, so a close needs no new listing.',
    'A call refused with "no open note" or "changed since it was listed" changed nothing: list again.',
].join(' ');

// The input the model gives (6.1): an action, and the fields its form takes.
export const TOOL_INPUT_SCHEMA = {
    type: 'object',
    properties: {
        action: { type: 'string', enum: ['list', 'show', 'add', 'done', 'drop'] },
        note: { type: 'string' },
        ids: { type: 'array', items: { type: 'string', pattern: '^[0-9a-f]{8}$' }, minItems: 1 },
    },
    required: ['action'],
} as const;

// A note's length as the queue stores it (5.1): code points, once every run of whitespace is one space and the ends
// are trimmed.
function storedLength(note: string): number {
    return Array.from(note.replace(/\s+/g, ' ').trim()).length;
}

// Whether a call's `ids` is one or more ids, each a string of 8 lowercase hexadecimal characters.
function isIdList(ids: unknown): ids is ReadonlyArray<string> {
    return (
        Array.isArray(ids) &&
        ids.length > 0 &&
        ids.every((id: unknown) => typeof id === 'string' && ID_PATTERN.test(id))
    );
}

// A call's arguments as a request, or the reason it is refused (6.2). Only the keys of the action's own form are
// read: the call's reserved keys (`tool`, `tool_use_id`, `consent`) and the keys of another form are ignored. A note is
// kept exactly as given and refused when it is empty once trimmed or longer than ADD_MAX_CHARS as stored. A show or a
// close without valid ids, the old form of a number and a text among them, is refused before anything reads the
// queue, so a request always names at least one id; it keeps each id once, in the order first given.
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
        if (typeof note !== 'string' || note.trim() === '') {
            return { ok: false, reason: ADD_REASON };
        }
        const length = storedLength(note);
        return length > ADD_MAX_CHARS
            ? { ok: false, reason: limitReason(length) }
            : { ok: true, request: { action, note } };
    }
    if (action === 'show' || action === 'done' || action === 'drop') {
        const ids = 'ids' in input ? input.ids : undefined;
        return isIdList(ids)
            ? { ok: true, request: { action, ids: [...new Set(ids)] } }
            : { ok: false, reason: IDS_REASON };
    }
    return { ok: false, reason: ACTION_REASON };
}
