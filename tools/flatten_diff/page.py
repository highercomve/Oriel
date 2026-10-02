# The test page for run.sh: rows the native renderer flattens (stamped
# rows, rows that must take the general path) and, after each forced render,
# a change. `page.py N` prints the page with the first N changes; `page.py
# --steps` how many there are. Add a step for anything a flattener change
# could get wrong.
import sys
head='''<!doctype html>
<html><head><meta charset="utf-8"><style>
body { margin: 0; font-size: 14px; }
.row { display: flex; gap: 8px; align-items: center; padding: 3px 8px; }
.row .n { width: 48px; color: #777; }
.row .dot { width: 8px; height: 8px; border-radius: 50%; background: #6d8bff; }
.row .up { text-transform: uppercase; font-weight: 700; }
.row .first { order: -1; }
.row .ws { white-space: pre; }
.hot .row .n { width: 70px; }
[data-x] .row .dot { width: 20px; }
#wrap.big .n { width: 100px; }
.sel .dot { height: 14px; }
</style></head><body><div id="wrap"><div id="list"></div></div><script>
const list = document.getElementById("list"), wrap = document.getElementById("wrap");
const add = (html) => { const r = document.createElement("div"); r.className = "row"; r.innerHTML = html; list.append(r); return r; };
const rows = [];
for (let i = 0; i < 6; i++) rows.push(add(`<span class="n">${i}</span><span class="dot"></span><span>Row ${i}:  the quick\\u00a0 brown fox </span>`));
const up = add(`<span class="n">u</span><span class="up">  mixed Case  </span><span class="first">first</span>`);
const empty = add(`<span class="n"></span><span class="dot"></span><span></span>`);
const nested = add(`<span class="n">x</span><span><b>bold</b> tail</span>`);
const pre = add(`<span class="n">p</span><span class="ws">a   b</span>`);
const click = add(`<span class="n">c</span><span>click me</span>`);
click.lastElementChild.addEventListener("click", () => {});
'''
steps=[
 'rows[0].lastElementChild.textContent = "Row 0: updated"; rows[1].lastElementChild.textContent = ""; empty.lastElementChild.textContent = "filled"; rows[2].remove();',
 'list.classList.add("hot");',
 'wrap.setAttribute("data-x", "");',
 'add(`<span class="n">new</span><span class="dot"></span><span>Row new</span>`); rows[3].lastElementChild.textContent = "Row 3: updated  twice";',
 'wrap.classList.add("big");',
 'rows[4].classList.add("sel"); rows[5].setAttribute("title", "t");',
 'wrap.removeAttribute("data-x"); list.classList.remove("hot");',
 'rows[4].classList.remove("sel"); rows[5].removeAttribute("title"); up.children[1].textContent = "  now   upper ";',
]
if sys.argv[1] == '--steps':
    print(len(steps))
    sys.exit()
n=int(sys.argv[1])
body=''.join('void list.offsetHeight;\n'+s+'\n' for s in steps[:n])
print(head+body+'</script></body></html>')
