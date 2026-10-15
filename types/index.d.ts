// The state contract of the later plugin: the values its notes pane is drawn from, kept under `$.state`.

// One open note as `later.sh rows` listed it. The key names the note by its text and its occurrence among open
// notes with the same text, so it does not change with the note's number or age.
export type NoteRow = { readonly key: string; readonly position: number; readonly age: string; readonly text: string };

// The queue as the last `rows` read it, or why it could not be read.
export type Queue =
    | { readonly kind: 'read'; readonly label: string; readonly rows: ReadonlyArray<NoteRow> }
    | { readonly kind: 'failed'; readonly reason: string };

// The note the pane's keys act on, by its key, or none.
export type Selection = { readonly kind: 'none' } | { readonly kind: 'note'; readonly key: string };

declare module 'claude-code' {
    interface PluginState {
        laterbox: { queue: Queue; selected: Selection; isAdding: boolean; status: string };
    }
}
