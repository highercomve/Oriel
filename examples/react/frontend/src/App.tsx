import { useEffect, useState, type FormEvent } from "react";
import { Routes, Route, NavLink, Navigate } from "react-router-dom";
// Generated from the Zig `Commands` struct (zig build types / zig build dev).
import { invoke, listen, openExternal, orielWindow, deepLink, type Commands } from "./oriel";

type Note = Commands["list_notes"]["result"][number];
type AppInfo = Commands["app_info"]["result"];

function NotesPage() {
  const [info, setInfo] = useState<AppInfo | null>(null);
  const [notes, setNotes] = useState<Note[]>([]);
  const [draft, setDraft] = useState("");
  const [name, setName] = useState("Sergio");
  const [greeting, setGreeting] = useState("");
  const [error, setError] = useState("");
  const [dnd, setDnd] = useState(false);
  const [exported, setExported] = useState("");
  const [exporting, setExporting] = useState(false);
  const [openedLink, setOpenedLink] = useState<string | null>(null);

  useEffect(() => {
    invoke("app_info").then(setInfo);
    invoke("list_notes").then(setNotes);
    invoke("do_not_disturb").then(setDnd);
    deepLink?.current().then((url) => {
      if (url) {
        setOpenedLink(url);
        invoke("log_js_deep_link", { url, source: "current" }).catch(() => {});
      }
    });
    // Pushed from Zig, e.g. by the tray menu or deep links.
    const unlisten = [
      listen("notes_changed", setNotes),
      listen("do_not_disturb", setDnd),
      listen("deep-link", (e) => {
        setOpenedLink(e.url);
        invoke("log_js_deep_link", { url: e.url, source: "event" }).catch(() => {});
      }),
    ];
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
    <div>
      <header>
        <h1>Notes</h1>
        {dnd && <span className="badge dnd">do not disturb</span>}
        {info && (
          <span className={`badge ${info.dev ? "dev" : "prod"}`}>
            {info.dev ? "dev · hot reload" : "production · embedded"} · Zig {info.zig} · {info.mode}
          </span>
        )}
      </header>
      {openedLink && <p className="opened-link">Opened via link: {openedLink}</p>}

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
        <a
          href="https://ziglang.org"
          onClick={(e) => {
            e.preventDefault();
            openExternal("https://ziglang.org");
          }}
        >
          ziglang.org
        </a>{" "}
        open in your browser.
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
    </div>
  );
}

function SettingsPage() {
  const [info, setInfo] = useState<AppInfo | null>(null);

  useEffect(() => {
    invoke("app_info").then(setInfo);
  }, []);

  return (
    <div className="settings-page">
      <header>
        <h1>Settings</h1>
      </header>
      <div className="settings-section">
        <p>Manage application preferences and system integration.</p>
        {info && (
          <div className="settings-card">
            <h3>Environment</h3>
            <p>Mode: <strong>{info.mode}</strong> ({info.dev ? "Development with Vite" : "Production embedded assets"})</p>
            <p>Zig version: <strong>{info.zig}</strong></p>
          </div>
        )}
        <div className="settings-card">
          <h3>External Links</h3>
          <p>
            System browser integration via <code>oriel.openExternal()</code>:
          </p>
          <button
            type="button"
            onClick={() => openExternal("https://ziglang.org")}
          >
            Visit ziglang.org
          </button>
        </div>
      </div>
    </div>
  );
}

/** Open the Settings route in its own window (or focus it if already open). */
function openSettingsWindow() {
  orielWindow
    .open({ label: "settings", url: "/settings", title: "Settings", width: 520, height: 560 })
    .catch((err) => console.error("open settings window:", err));
}

export function App() {
  // The Settings window shows just its page, without the main navigation.
  if (orielWindow?.current().label === "settings") {
    return (
      <main>
        <SettingsPage />
      </main>
    );
  }
  return (
    <main>
      <nav className="nav-bar">
        <NavLink to="/" end className={({ isActive }) => (isActive ? "active" : "")}>
          Notes
        </NavLink>
        <NavLink to="/settings" className={({ isActive }) => (isActive ? "active" : "")}>
          Settings
        </NavLink>
        <button className="nav-window" onClick={openSettingsWindow} title="Open Settings in a new window">
          ⧉ Settings window
        </button>
      </nav>
      <Routes>
        <Route path="/" element={<NotesPage />} />
        <Route path="/index.html" element={<Navigate to="/" replace />} />
        <Route path="/settings" element={<SettingsPage />} />
      </Routes>
    </main>
  );
}
