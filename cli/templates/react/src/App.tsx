import { useEffect, useRef, useState, type FormEvent } from "react";
// Generated from the Zig `Commands` and `Events` (zig build types).
import { invoke, listen, deepLink, type Commands } from "./oriel";

type AppInfo = Commands["app_info"]["result"];

export function App() {
  const [name, setName] = useState("Oriel");
  const [greeting, setGreeting] = useState("");
  const [count, setCount] = useState(0);
  const [info, setInfo] = useState<AppInfo | null>(null);
  const [error, setError] = useState("");
  const [openedLink, setOpenedLink] = useState<string | null>(null);
  const greetedRef = useRef(false);

  const greet = (who: string) =>
    invoke("greet", { name: who })
      .then((text) => {
        setGreeting(text);
        setError("");
      })
      .catch((err) => setError(String(err)));

  useEffect(() => {
    // Pushed from Zig by `events.emit(.greeted, ...)`.
    const off = listen("greeted", (e) => setCount(e.count));
    const offLink = listen("deep-link", (e) => setOpenedLink(e.url));
    deepLink?.current().then((url) => { if (url) setOpenedLink(url); });
    invoke("app_info").then(setInfo);
    if (!greetedRef.current) {
      greetedRef.current = true;
      greet(name);
    }
    return () => {
      off();
      offLink();
    };
  }, []);

  const submit = (e: FormEvent) => {
    e.preventDefault();
    greet(name);
  };

  return (
    <main>
      <h1>@@title@@</h1>
      <p className="tagline">React + Vite, with Zig on the other side of invoke().</p>
      <form onSubmit={submit}>
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Your name" />
        <button type="submit">Greet</button>
      </form>
      <p className={error ? "greeting error" : "greeting"}>{error || greeting}</p>
      <p className="count">Greeted {count} {count === 1 ? "time" : "times"} (event from Zig)</p>
      {openedLink && <p className="opened-link">Opened via link: {openedLink}</p>}
      {info && (
        <footer>
          Zig {info.zig} · {info.mode}
          {info.dev ? " · dev server" : ""}
        </footer>
      )}
    </main>
  );
}
