import { expect, test } from 'claude-code/testing';
import type { ListedNote, Unresolved } from './notes';
import {
    CLIP_CHARS,
    clipText,
    closedOf,
    closeRecords,
    listedNotes,
    listingOf,
    noteId,
    parkedOf,
    resolveIds,
    shownOf,
    unresolvedReason,
} from './notes';

const CERT = 'renew the certificate';

// A note of 150 characters, past the cut.
const SENTENCE = 'Recheck the export totals for March against the ledger, the run of 2026-11-02 showed a difference. ';
const LONG = SENTENCE.repeat(2).slice(0, 150);

// Three open notes as `rows` gives them: two with the same text around a long one.
const rows = [
    { position: 1, age: '3d', text: 'A' },
    { position: 2, age: 'today', text: LONG },
    { position: 3, age: 'undated', text: 'A' },
];
const notes = listedNotes(rows);

// The note at an index of a list the test built to hold it.
function noteAt(list: ReadonlyArray<ListedNote>, index: number): ListedNote {
    const note = list[index];
    if (note === undefined) {
        throw new Error(`the list has no note at ${index}`);
    }
    return note;
}

test('an id is 8 hex characters fixed by the text and the occurrence', async () => {
    expect(noteId(CERT, 1)).toBe('ea2c489f');
    expect(noteId(CERT, 2)).toBe('46f2440c');
    expect(noteId('renew the certificatE', 1)).toBe('ffe5dbd1');
    expect(noteId('შეამოწმე ექსპორტი', 1)).toBe('c22439f4');
    expect(noteId('a\tb  ', 1)).toBe('9d0e9861');
    expect(noteId('😀 done', 1)).toBe('2e9f36a3');
});

test('2000 generated notes have 2000 ids', async () => {
    const ids = new Set<string>();
    for (let index = 0; index < 2000; index += 1) {
        const text =
            `Note ${index}: recheck the export totals for batch ${index * 7919} ` +
            'against the ledger and write the difference down';
        ids.add(noteId(text, 1));
    }
    expect(ids.size).toBe(2000);
    for (const id of ids) {
        expect(id).toMatch(/^[0-9a-f]{8}$/);
    }
});

test('a text is cut to 97 characters and three dots past 100', async () => {
    expect(CLIP_CHARS).toBe(100);
    expect(clipText('a'.repeat(100))).toBe('a'.repeat(100));
    expect(clipText('a'.repeat(101))).toBe(`${'a'.repeat(97)}...`);
    expect(clipText('ა'.repeat(101))).toBe(`${'ა'.repeat(97)}...`);
    expect(clipText(`${'a'.repeat(96)}😀${'b'.repeat(10)}`)).toBe(`${'a'.repeat(96)}😀...`);
    expect(clipText(`${'a'.repeat(97)}😀${'b'.repeat(10)}`)).toBe(`${'a'.repeat(97)}...`);
    expect(clipText('ends in dots...')).toBe('ends in dots...');
});

test('each row gets the id of its text and its occurrence among the rows with that text', async () => {
    expect(notes).toStrictEqual([
        { position: 1, age: '3d', text: 'A', id: noteId('A', 1) },
        { position: 2, age: 'today', text: LONG, id: noteId(LONG, 1) },
        { position: 3, age: 'undated', text: 'A', id: noteId('A', 2) },
    ]);
    expect(noteAt(notes, 0).id).not.toBe(noteAt(notes, 2).id);
});

test("of two notes with the same text, the second takes the first's id once the first closes", async () => {
    const remaining = listedNotes(rows.slice(1));
    expect(noteAt(remaining, 0).id).toBe(noteAt(notes, 1).id);
    expect(noteAt(remaining, 1).id).toBe(noteId('A', 1));
    expect(resolveIds(remaining, [noteId('A', 2)])).toStrictEqual({
        ok: false,
        unknown: [noteId('A', 2)],
        ambiguous: [],
    });
});

test('the listing is the label and count, then one cut line per note with its id and age', async () => {
    expect(Array.from(LONG)).toHaveLength(150);
    expect(listingOf('shop', notes).split('\n')).toStrictEqual([
        'shop: 3 parked',
        ` 1. [${noteId('A', 1)}] A (3d)`,
        ` 2. [${noteId(LONG, 1)}] ${LONG.slice(0, 97)}... (today)`,
        ` 3. [${noteId('A', 2)}] A (undated)`,
    ]);
});

test('a listing of no note says there is none', async () => {
    expect(listingOf('shop', [])).toBe('later: no parked notes');
});

// Three rows with the text given as note 2.
function rowsAround(
    text: string,
): ReadonlyArray<{ readonly position: number; readonly age: string; readonly text: string }> {
    return [
        { position: 1, age: '3d', text: 'A' },
        { position: 2, age: '3d', text },
        { position: 3, age: 'today', text: 'B' },
    ];
}

test('a text that starts with an id is listed after its own id and changes no other line', async () => {
    const forged = `[07be33aa] ${CERT}`;
    const listed = listedNotes(rowsAround(forged));
    const lines = listingOf('shop', listed).split('\n');
    const plain = listingOf('shop', listedNotes(rowsAround(CERT))).split('\n');
    expect(lines[2]).toBe(` 2. [${noteId(forged, 1)}] ${forged} (3d)`);
    expect(noteId(forged, 1)).not.toBe('07be33aa');
    expect([lines[0], lines[1], lines[3]]).toStrictEqual([plain[0], plain[1], plain[3]]);
    expect(resolveIds(listed, ['07be33aa'])).toStrictEqual({ ok: false, unknown: ['07be33aa'], ambiguous: [] });
});

test('the line of note 100 starts with its number and its id resolves', async () => {
    const hundred = listedNotes(
        Array.from({ length: 100 }, (_, index) => ({ position: index + 1, age: 'today', text: `note ${index + 1}` })),
    );
    const lines = listingOf('shop', hundred).split('\n');
    const last = noteAt(hundred, 99);
    expect(lines).toHaveLength(101);
    expect(lines[0]).toBe('shop: 100 parked');
    expect(lines[9]).toStartWith(' 9. [');
    expect(lines[10]).toStartWith('10. [');
    expect(lines[100]).toStartWith('100. [');
    expect(lines[100]).toBe(`100. [${last.id}] note 100 (today)`);
    expect(resolveIds(hundred, [last.id])).toStrictEqual({ ok: true, notes: [last] });
});

test('a note shown is its listing line with the text whole and no header', async () => {
    expect(shownOf([noteAt(notes, 1)])).toBe(` 2. [${noteId(LONG, 1)}] ${LONG} (today)`);
});

test('ids name their notes in queue order, each once, whatever their order and repeats', async () => {
    const first = noteAt(notes, 0);
    const third = noteAt(notes, 2);
    expect(resolveIds(notes, [third.id, first.id, third.id])).toStrictEqual({ ok: true, notes: [first, third] });
});

test('ids that name no open note are refused, each once in the order given', async () => {
    expect(resolveIds(notes, ['00000000', noteAt(notes, 0).id, '11111111', '00000000'])).toStrictEqual({
        ok: false,
        unknown: ['00000000', '11111111'],
        ambiguous: [],
    });
});

test('an id two open notes have is refused as ambiguous', async () => {
    const shared: ReadonlyArray<ListedNote> = [
        { position: 1, age: '3d', text: 'x', id: 'aaaaaaaa' },
        { position: 2, age: 'today', text: 'y', id: 'aaaaaaaa' },
    ];
    expect(resolveIds(shared, ['aaaaaaaa'])).toStrictEqual({ ok: false, unknown: [], ambiguous: ['aaaaaaaa'] });
});

// One row per refusal: what it is, the ids refused, the action, and the reason without the hook's `later: `.
const REASONS: ReadonlyArray<readonly [string, Unresolved, 'show' | 'done' | 'drop', string]> = [
    [
        'unknown ids on a show',
        { unknown: ['00000000', '11111111'], ambiguous: [] },
        'show',
        'no open note [00000000] [11111111]; list again',
    ],
    [
        'an ambiguous id on a show',
        { unknown: [], ambiguous: ['aaaaaaaa'] },
        'show',
        'more than one open note has the id [aaaaaaaa]; read it in the pane (/later)',
    ],
    [
        'unknown ids on a done',
        { unknown: ['00000000', '11111111'], ambiguous: [] },
        'done',
        'no open note [00000000] [11111111]; nothing changed, list again',
    ],
    [
        'unknown ids on a drop',
        { unknown: ['00000000', '11111111'], ambiguous: [] },
        'drop',
        'no open note [00000000] [11111111]; nothing changed, list again',
    ],
    [
        'an ambiguous id on a done',
        { unknown: [], ambiguous: ['aaaaaaaa'] },
        'done',
        'more than one open note has the id [aaaaaaaa]; nothing changed, close it from the pane (/later)',
    ],
    [
        'an ambiguous id on a drop',
        { unknown: [], ambiguous: ['aaaaaaaa'] },
        'drop',
        'more than one open note has the id [aaaaaaaa]; nothing changed, close it from the pane (/later)',
    ],
    [
        'an unknown and an ambiguous id on a show',
        { unknown: ['00000000'], ambiguous: ['aaaaaaaa'] },
        'show',
        'no open note [00000000]; more than one open note has the id [aaaaaaaa]; list again',
    ],
    [
        'an unknown and an ambiguous id on a drop',
        { unknown: ['00000000'], ambiguous: ['aaaaaaaa'] },
        'drop',
        'no open note [00000000]; more than one open note has the id [aaaaaaaa]; nothing changed, list again',
    ],
    [
        'two ambiguous ids on a done',
        { unknown: [], ambiguous: ['aaaaaaaa', 'bbbbbbbb'] },
        'done',
        'more than one open note has the id [aaaaaaaa] [bbbbbbbb]; nothing changed, close it from the pane (/later)',
    ],
];
for (const [name, unresolved, action, reason] of REASONS) {
    test(`${name} gives its reason`, async () => {
        expect(unresolvedReason(unresolved, action)).toBe(reason);
    });
}

test('the close records are each note number and its text byte for byte, one per line', async () => {
    expect(
        closeRecords([
            { position: 2, age: 'today', text: 'ends here  ', id: 'x' },
            { position: 10, age: '3d', text: 'split\there', id: 'y' },
        ]),
    ).toBe('2\tends here  \n10\tsplit\there\n');
});

test('a close answers one line per note with its id and its cut text', async () => {
    expect(closedOf('done', [noteAt(notes, 1)])).toBe(`later: done -> [${noteId(LONG, 1)}] ${LONG.slice(0, 97)}...`);
    expect(closedOf('drop', [noteAt(notes, 0), noteAt(notes, 2)]).split('\n')).toStrictEqual([
        `later: dropped -> [${noteId('A', 1)}] A`,
        `later: dropped -> [${noteId('A', 2)}] A`,
    ]);
});

test('a park answer is cut and any other engine line is kept', async () => {
    expect(parkedOf(`later: parked -> ${LONG}`)).toBe(`later: parked -> ${LONG.slice(0, 97)}...`);
    expect(parkedOf(`later: parked -> ${CERT}`)).toBe(`later: parked -> ${CERT}`);
    expect(parkedOf('later: nothing to park (empty note)')).toBe('later: nothing to park (empty note)');
});
