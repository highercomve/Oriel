import { useEffect, useState, type FormEvent } from "react";
// Generated from the Zig `Commands` struct (zig build types / zig build dev).
import { invoke, listen, type Commands } from "./oriel";

type Note = Commands["list_notes"]["result"][number];
type AppInfo = Commands["app_info"]["result"];

export function App() {
  const [info, setInfo] = useState<AppInfo | null>(null);
  const [notes, setNotes] = useState<Note[]>([]);
  const [draft, setDraft] = useState("");
  const [name, setName] = useState("Sergio");
  const [greeting, setGreeting] = useState("");
  const [error, setError] = useState("");
  const [dnd, setDnd] = useState(false);
  const [exported, setExported] = useState("");
  const [exporting, setExporting] = useState(false);

  useEffect(() => {
    invoke("app_info").then(setInfo);
    invoke("list_notes").then(setNotes);
    invoke("do_not_disturb").then(setDnd);
    // Pushed from Zig, e.g. by the tray menu.
    const unlisten = [listen("notes_changed", setNotes), listen("do_not_disturb", setDnd)];
    return () => unlisten.forEach((off) => off());
  }, []);

  const exportNotes = () => {
    setExporting(true);
    run(async () => {
      const res = await invoke("export_notes");
      setExported(res);
      setExporting(false);
    });
  };

  const run = async (action: () => Promise<void>) => {
    setError("");
    try {
      await action();
    } catch (e) {
      setError(String(e));
    }
  };

  const addNote = (e: FormEvent) => {
    e.preventDefault();
    run(async () => {
      setNotes(await invoke("add_note", { text: draft }));
      setDraft("");
    });
  };

  return (
    <main>
      <header>
        <h1>Notes</h1>
        {dnd && <span className="badge dnd">do not disturb</span>}
        {info && (
          <span className={`badge ${info.dev ? "dev" : "prod"}`}>
            {info.dev ? "dev · hot reload" : "production · embedded"} · Zig {info.zig} · {info.mode}
          </span>
        )}
      </header>

      <form onSubmit={addNote} className="row">
        <input value={draft} onChange={(e) => setDraft(e.target.value)} placeholder="Write a note…" autoFocus />
        <button type="submit">Add</button>
      </form>
      {error && <p className="error">{error}</p>}

      <ul className="notes">
        {notes.map((note) => (
          <li key={note.id}>
            <span>{note.text}</span>
            <time>{note.created_at}</time>
            <button className="ghost" onClick={() => run(async () => setNotes(await invoke("delete_note", { id: note.id })))} aria-label="Delete note">
              ✕
            </button>
          </li>
        ))}
        {notes.length === 0 && <li className="empty">No notes yet: stored in SQLite, on the Zig side.</li>}
      </ul>

      <p className="hint">
        Close the window to keep notes in the tray. External links such as{" "}
        <a href="https://ziglang.org">ziglang.org</a> open in your browser.
      </p>

      <section className="row greet">
        <input value={name} onChange={(e) => setName(e.target.value)} />
        <button onClick={() => run(async () => setGreeting(await invoke("greet", { name })))}>Greet</button>
        <span>{greeting}</span>
      </section>

      <section className="row export">
        <button onClick={exportNotes} disabled={exporting}>
          {exporting ? "Exporting (async)…" : "Export notes (async)"}
        </button>
        {exported && <pre className="exported-preview">{exported}</pre>}
      </section>
    </main>
  );
}
