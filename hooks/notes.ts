// How the queue tool names and writes the open notes (spec R1 to R5): a note's id, the cut of a long text, the lines of
// a listing, a show and a close, the refusal of ids that name no single note, and the records a guarded close sends
// the engine. The hooks module runs the engine and hands its rows here, so nothing here touches the engine.

// One open note as the tool names it: a row of `later.sh rows` and its id.
export type ListedNote = {
    readonly position: number;
    readonly age: string;
    readonly text: string;
    readonly id: string;
};

// The ids of a call that name no open note, and those more than one open note has.
export type Unresolved = { readonly unknown: ReadonlyArray<string>; readonly ambiguous: ReadonlyArray<string> };

// The notes a call's ids name, or the ids that stopped it.
export type Resolved =
    | { readonly ok: true; readonly notes: ReadonlyArray<ListedNote> }
    | ({ readonly ok: false } & Unresolved);

// The most characters a text keeps in a listing or an answer; a longer one keeps three fewer and `...` (2.2).
export const CLIP_CHARS = 100;

// What the engine's `add` answers before the note it parked.
const PARKED_PREFIX = 'later: parked -> ';

// A note's id (1.1, 1.2): 8 lowercase hexadecimal characters, fixed by the text and its occurrence among the open
// notes with that text, the same in every session and on every platform. FNV-1a over each UTF-16 unit of
// `<occurrence>:<text>`, low byte first, then the finalizer of MurmurHash3.
export function noteId(text: string, occurrence: number): string {
    const key = `${occurrence}:${text}`;
    let hash = 0x811c9dc5;
    for (let index = 0; index < key.length; index += 1) {
        const unit = key.charCodeAt(index);
        hash = Math.imul(hash ^ (unit & 0xff), 0x01000193);
        hash = Math.imul(hash ^ (unit >>> 8), 0x01000193);
    }
    hash ^= hash >>> 16;
    hash = Math.imul(hash, 0x85ebca6b);
    hash ^= hash >>> 13;
    hash = Math.imul(hash, 0xc2b2ae35);
    hash ^= hash >>> 16;
    return (hash >>> 0).toString(16).padStart(8, '0');
}

// A text as a listing writes it (2.2): whole up to 100 code points, else its first 97 and `...`. The cut counts code
// points, so it never splits a character outside the basic plane.
export function clipText(text: string): string {
    const points = Array.from(text);
    return points.length > CLIP_CHARS ? `${points.slice(0, CLIP_CHARS - 3).join('')}...` : text;
}

// Each row with its id, in the rows' order: the occurrence is counted among the rows with exactly that text, from 1.
export function listedNotes(
    rows: ReadonlyArray<{ readonly position: number; readonly age: string; readonly text: string }>,
): ReadonlyArray<ListedNote> {
    const seen = new Map<string, number>();
    return rows.map((row) => {
        const occurrence = (seen.get(row.text) ?? 0) + 1;
        seen.set(row.text, occurrence);
        return { position: row.position, age: row.age, text: row.text, id: noteId(row.text, occurrence) };
    });
}

// One note's line with the text given: its number padded to two places as the engine's `list` writes it, its id in
// square brackets, the text, and its age in parentheses.
function lineOf(note: ListedNote, text: string): string {
    return `${String(note.position).padStart(2, ' ')}. [${note.id}] ${text} (${note.age})`;
}

// The listing (2.1): `later: no parked notes` for no note, else the label and the count, then one line per note with
// its text cut, joined by newlines, no final newline.
export function listingOf(label: string, notes: ReadonlyArray<ListedNote>): string {
    if (notes.length === 0) {
        return 'later: no parked notes';
    }
    return [`${label}: ${notes.length} parked`, ...notes.map((note) => lineOf(note, clipText(note.text)))].join('\n');
}

// The notes shown whole (3.1): each note's listing line with its text uncut, no header.
export function shownOf(notes: ReadonlyArray<ListedNote>): string {
    return notes.map((note) => lineOf(note, note.text)).join('\n');
}

// The notes the ids name, in queue order and each once, whatever the order and repeats of the ids. Refused when an
// id names no note or more than one: each list keeps the order the ids were given in, each id once.
export function resolveIds(notes: ReadonlyArray<ListedNote>, ids: ReadonlyArray<string>): Resolved {
    const holders = new Map<string, number>();
    for (const note of notes) {
        holders.set(note.id, (holders.get(note.id) ?? 0) + 1);
    }
    const unknown: string[] = [];
    const ambiguous: string[] = [];
    const named = new Set<string>();
    for (const id of new Set(ids)) {
        const count = holders.get(id) ?? 0;
        if (count === 0) {
            unknown.push(id);
        } else if (count > 1) {
            ambiguous.push(id);
        } else {
            named.add(id);
        }
    }
    if (unknown.length > 0 || ambiguous.length > 0) {
        return { ok: false, unknown, ambiguous };
    }
    return { ok: true, notes: notes.filter((note) => named.has(note.id)) };
}

// Ids written as a listing writes them, each in square brackets, separated by spaces.
function bracketed(ids: ReadonlyArray<string>): string {
    return ids.map((id) => `[${id}]`).join(' ');
}

// Why a refusal of `resolveIds` stopped the call (3.2, 4.2), without the `later: ` the hooks module puts before it:
// the unknown ids, then the ambiguous ones, the parts present joined by `; `, then what to do next. Any unknown id
// means the listing is stale, so the answer is to list again; ambiguous ids alone mean the listing is right and the
// pane is the way to the note. A close adds that nothing changed.
export function unresolvedReason(unresolved: Unresolved, action: 'show' | 'done' | 'drop'): string {
    const parts: string[] = [];
    if (unresolved.unknown.length > 0) {
        parts.push(`no open note ${bracketed(unresolved.unknown)}`);
    }
    if (unresolved.ambiguous.length > 0) {
        parts.push(`more than one open note has the id ${bracketed(unresolved.ambiguous)}`);
    }
    const reason = parts.join('; ');
    const stale = unresolved.unknown.length > 0;
    if (action === 'show') {
        return `${reason}; ${stale ? 'list again' : 'read it in the pane (/later)'}`;
    }
    return `${reason}; nothing changed, ${stale ? 'list again' : 'close it from the pane (/later)'}`;
}

// The standard input of the engine's `done|drop --if-each` (4.4): `<position>\t<text>\n` per note, the text byte for
// byte as the row gave it.
export function closeRecords(notes: ReadonlyArray<ListedNote>): string {
    return notes.map((note) => `${note.position}\t${note.text}\n`).join('');
}

// A close's answer (4.5): one `later: done -> [<id>] <text>` or `later: dropped -> [<id>] <text>` line per note, the
// text cut, joined by newlines.
export function closedOf(action: 'done' | 'drop', notes: ReadonlyArray<ListedNote>): string {
    const verb = action === 'done' ? 'done' : 'dropped';
    return notes.map((note) => `later: ${verb} -> [${note.id}] ${clipText(note.text)}`).join('\n');
}

// A park's answer (5.2): the engine's `later: parked -> <note>` with the note cut; any other line as the engine
// wrote it.
export function parkedOf(engineLine: string): string {
    return engineLine.startsWith(PARKED_PREFIX)
        ? `${PARKED_PREFIX}${clipText(engineLine.slice(PARKED_PREFIX.length))}`
        : engineLine;
}
