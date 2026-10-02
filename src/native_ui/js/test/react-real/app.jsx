// A React page with controlled fields: test/react-real.test.mjs types into
// them through the runtime, as a native field would.
import React, { useState } from "react";
import { createRoot } from "react-dom/client";

function App() {
  const [text, setText] = useState("old");
  const [range, setRange] = useState(0.2);
  const [checked, setChecked] = useState(false);
  const [pick, setPick] = useState("b");
  globalThis.__state = { text, range, checked, pick };
  return (
    <div>
      <input id="text" value={text} onChange={(e) => setText(e.target.value)} />
      <input id="range" type="range" min={0} max={1} step={0.05} value={range} onChange={(e) => setRange(parseFloat(e.target.value))} />
      <input id="box" type="checkbox" checked={checked} onChange={(e) => setChecked(e.target.checked)} />
      <select id="pick" value={pick} onChange={(e) => setPick(e.target.value)}>
        <option value="a">Alpha</option>
        <option value="b">Beta</option>
        <option value="c">Gamma</option>
      </select>
    </div>
  );
}
createRoot(document.getElementById("root")).render(<App />);
