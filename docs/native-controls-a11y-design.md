# Native buttons/checkboxes/radios and an accessibility tree for `-Dnative_ui`

Branch release-0.9.1, 2026-10-04. Rule: **native look, web layout**. CSS decides every box. A real
platform control fills the box when the page leaves the control's look alone. Oriel never draws
its own copy of a native control when the platform has a real one.

## 0. What the code does today (facts the design relies on)

- `tree.zig`: `Kind = { view, text, input, textarea, select, icon, image, canvas }`. An unknown kind
  string becomes `.view`. The `"p"` op **replaces** a node's `Props` and also resets `measured_text_size`,
  `baseline`, Yoga style and `on_props` (Android re-mirrors the JSON). `emit()` in render.js
  diffs props by their encoded string, so any prop change costs a re-layout of that node.
- Checkbox and radio: `render.js` makes `kind:"view"` with `ctl`, `on` (from the `checked` *attribute*:
  main.js makes `.checked` reflect it) and `acc`, plus `blb` on macOS. `paintControl` in gtk.zig,
  win32.zig and apple_draw.zig draws it.
- `<button>` becomes a drawn box (a `view` with a text child, or `text`). On macOS, `pushButton()`
  uses the `PUSH_MARK` background set by `UA_CSS_MAC` to tell when the page left the button alone.
  This sentinel idea is reused below.
- **Bug:** `<input type=button|submit|reset>` goes down the text-field path, so it becomes an editable `input`.
- Click: the backend sends `event(id,"click",flags)`, then `activate()` runs. A checkbox or radio is
  toggled before dispatch and undone if the page cancels it. Radio exclusivity is done in JS by
  `check()`. `<label>` forwards the click to its control. A `<button type=submit>` calls `submit(form)`.
  **No form reset exists, and no keyboard activation exists:** Space/Enter on a focused drawn
  button or link does nothing (`scrollKey` only skips Space).
- Focus: Tab goes `keyEvent` → `tabFocus()` → `el.focus()` → `host.focus(id)` → `Backend.focus`.
  Native fields send `"focus"`/`"blur"` events.
- Fields: each backend has `syncFields`/`makeField` (gtk.zig:1038/1090, win32.zig:1126/1362,
  appkit.zig:664/707, uikit.zig:588/640) and Kotlin has `NuiView.syncFields`/`makeField`. The page
  draws the field's box. The widget sits at the content box. Clipping per backend:
  - AppKit/UIKit: a clipping holder view.
  - Win32: a `clip` child window.
  - Android: `clipBounds`.
  - **GTK: none.** Overlay children are hidden unless fully visible (`coveredLater`).
- No accessibility code exists anywhere. `scripts/headless.sh` forces `GTK_A11Y=none`.
- `al`/`ro` (the macOS session's label/readonly props) are **not on release-0.9.1**. The contract below defines `al`.

## 1. Shared contract

### 1.1 Capability gate
Each backend's platform JSON gets `controls: ["check","button"]` (a subset). render.js asks for a
native kind only when it is listed. Otherwise today's drawn path runs unchanged. This allows
per-backend rollout with no fallback code in the tree. iOS lists `["button"]` only (see 3.5).
An app opt-out (`native_controls=false` window option → `controls: []`) gives every app a way back.

### 1.2 Tree additions (tree.zig)
```zig
pub const Kind = enum { view, text, input, textarea, select, icon, image, canvas, button, check };
// Props additions
mix: bool = false,            // <input type=checkbox> .indeterminate (drawn and native)
al: ?[]const u8 = null,       // accessible name of a native-control node (input/textarea/select/button/check)
ro: bool = false,             // readonly field
// reused: ctl ("checkbox"|"radio") on .check, on, dis, acc, dk (color-scheme dark), runs (button label), fz/fwt/ff/col
```
- `create()`: `.button` gets `measureFn` and `baselineFn`. `.check` gets `baselineFn` only when it has `blb` (as `.view` today).
- `measure(.button)` is the backend's text measure of `props.runs`, the label alone. Padding and border
  come from CSS as for any box. `measureFn` passes the width through, so a wrapped label reports its wrapped height.
- `baselineFn(.button)`: the label is centered in the content box, as browsers center button content:
  `top + (inner - textH)/2 + n.baseline`, where `textH` is the measured label height and `n.baseline`
  is the text's first baseline. Without a baseline from the backend, use the field estimate.
- Painting: backends draw **nothing** for `.button`/`.check`: no bg, border, ring or `paintControl`.
  The bw/pad values stay in Props only as layout room.

### 1.3 render.js output
- **check** (checkbox/radio, `appearance` not `none`, capability present):
  `kind:"check"` with `{ctl, on, mix, dis, acc, dk, al, blb?, w, h, m}`. The size comes from CSS
  (the UA sheets keep the WebView sizes). No `pad/bw/bg/br`. No `ol`: the native control draws its own focus ring.
- **button** (when the rule in 1.4 says native): `kind:"button"`, `kids: []`, with
  `{pad, bw (room only), w/h/min/max…, runs:[one run: label], fz, fwt, ff, col, dis, dk, al, click:true}`.
  `label` is the whitespace-collapsed text content. For `<input>` it is the `value` attribute, or
  "Submit"/"Reset"/"" by default.
- `al` comes from the same `accName(el)` (a11y.js, 2.2) that fills `ax.n`, so the two names never
  diverge. It is sent for every native-control kind, always: it is not gated on AT. Names depend
  on other elements (`<label for>`, `aria-labelledby`), and `element()` reuses unchanged subtrees,
  so a11y.js keeps a `source el → Set(control el)` map. A mutation inside a source marks its controls.

### 1.4 The exact native/drawn rule for buttons
Applies to `<button>` and `<input type=button|submit|reset>`. The control is native iff **all** of these hold:
1. The capability `button` is present and the element is not `display: contents|none`.
2. Computed `appearance` and `-webkit-appearance` are both not `none`.
3. **Background untouched:** `background-color` equals the platform UA sheet's sentinel
   (generalize `PUSH_MARK`: each platform's UA button rule sets an off-by-0.0001-alpha mark) and
   `background-image` is `none`.
4. **Border untouched:** all four `border-*-style` equal the UA `outset` and `border-*-color` equal
   the UA sentinel color. Widths do not count: they are layout room. `border-*-radius` equals the UA value.
5. **No state rule touches them:** css.js tags at parse time any rule whose selector had
   `:hover|:active|:focus|:focus-visible` and whose decls set `background*`, `border*` or `appearance`
   (`rule.stateBox = selector with those attributes stripped`). If any tagged rule's stripped selector
   matches `el`, the button is drawn in every state. Without this, the first hover would swap a
   native button for a drawn one.
6. **Plain content:** the children are text nodes, or inline elements that make no box (computed
   `display:inline`, no background/border/padding/margin, not `img|svg|canvas|input|select|textarea|button`),
   recursively. There is no `::before`/`::after` with content on the button or any descendant,
   and the label is not empty (an empty native button has no use).
7. Not a direct row of a `stampList`/`stampRow` plan (stamped rows are JSON-free; see risk R6).

Ignored without losing the native control: `color` (applied where the platform can, else dropped),
`font-*` (size and weight applied), `padding`, `width/height`, `box-shadow` (not drawn), `outline`
(the platform ring is used), `cursor`. These follow Chromium: author color and padding keep the
native appearance; author background, border or radius drops it.

Checkbox/radio rule: native iff the capability is present and `appearance` is not `none`. This is
today's rule. Browsers ignore background and border on a checkbox unless `appearance: none` is set.

### 1.5 State ownership and events (JS is the single source of truth)
- A native check is **non-auto**:
  - Win32: `BS_CHECKBOX`, `BS_3STATE` or `BS_RADIOBUTTON`, never the `AUTO` styles.
  - Elsewhere the control may flip itself on click, so the backend re-asserts state from props.
  Radios are never grouped natively: each sits in its own holder or parent. On GTK each radio
  gets a private hidden group anchor, needed only for the radio look. Exclusivity stays in `check()`.
- Mouse click on a native control → `event(id,"click",flags)`, the existing path through
  `activate()`. Toggle and undo, label, submit/reset all work unchanged.
- After sending a click from a `.check`, the backend marks the control stale and calls
  `request_frame`. The next `laid_out` sets the state from `props.on/mix` **unconditionally**.
  This also covers a cancelled click, and a React-controlled box that ends where it began and so sends no `"p"` op.
- Keyboard: keys on a focused native button or check go to the page first (`"key"`/`"keyup"`
  events, as Win32 fields already do). The backend **suppresses the control's own Space/Enter
  activation**. main.js `keyEvent` gains the browsers' default action for all elements, drawn or native:
  - Enter keydown activates `button`, `input[type=button|submit|reset]`, `a[href]` and `summary`.
  - Space keyup activates `button`, the `input` button types, checkbox and radio. Space keydown preventDefault blocks it.
  One code path means preventDefault behaves as in a browser.
- Focus: as fields do. `Backend.focus(node)` focuses the native control. The control's focus and
  blur become `"focus"`/`"blur"` events. On macOS without Full Keyboard Access, NSButton refuses
  first responder; this matches main.js `tabRule="mac"`. On Win32, a focus that came by keyboard
  sends `WM_CHANGEUISTATE(UIS_CLEAR, UISF_HIDEFOCUS)` so the focus rectangle shows.
- Form reset: main.js `activate()` handles `type=reset` → `reset(form)`, which restores `value =
  defaultValue` for fields, `selected` for options, and checkedness (see open question Q3).

## 2. Accessibility contract

### 2.1 On demand, not a prop
a11y data is **not** in Props, because:
- (a) a props change re-lays out the node;
- (b) names depend on other elements, which `element()`'s subtree reuse would leave stale;
- (c) the cost must be zero when no assistive technology is running.

How it turns on: the backend detects AT and calls `Engine.setA11y(on)` → `event(0,"a11y",1|0)`.
Detection per backend:
- macOS/iOS: the first `accessibilityChildren`/`accessibilityElements` query, or `UIAccessibilityIsVoiceOverRunning()`.
- Win32: `WM_GETOBJECT` with `UiaRootObjectId`, or `UiaClientsAreListening()`.
- Android: `AccessibilityManager.isEnabled` and its listener.
- GTK: the first `get_first_accessible_child`.

On `1`, a11y.js sends the whole tree once, then only changes after each `emit`.
On `0`, it sends `["a",-2]` (clear) and stops.

### 2.2 Ops and payload
New op letters. `apply()` switches on the first char; `c p k d r x` are taken.
```
["a", id, ax|null]   set or clear a node's a11y data (id may be an inline element with no node: link run's k)
["f", id]            a11y focus moved to a drawn element (document.__active without a native widget); -1 none
["n", id, text, 1|2] announce (live region text changed; 1 polite, 2 assertive)        [phase 3]
ax = { r: role, n?: name, d?: description, s?: state bits, l?: heading level,
       v?: value text, rv?: [min,max,now], live?: 1|2, h?: 1 (aria-hidden: prune subtree) }
s bits: 1 disabled, 2 checked, 4 mixed, 8 expanded, 16 collapsed, 32 selected, 64 pressed,
        128 required, 256 invalid, 512 readonly, 1024 focusable, 2048 multiline
roles: button link checkbox radio switch textbox searchbox combobox listbox option slider
       progressbar heading img list listitem separator dialog alertdialog alert status
       navigation main banner contentinfo region form table row cell columnheader tab tablist
       tabpanel menu menuitem menubar toolbar tooltip tree treeitem group generic text
```
- tree.zig keeps `Tree.ax: AutoHashMapUnmanaged(i64, Ax)` in its own arena, apart from `nodes`. `Ax.role` is an enum, and an unknown role becomes `.generic`.
- `"d"` drops the entry. A new `on_ax(ctx, id)` hook tells backends.
- Nothing about layout is touched.

Who gets an `ax` entry:
- elements with an explicit `role`, `aria-label`, `aria-labelledby` or `aria-describedby`;
- `aria-live`, `aria-hidden`;
- focusable or `click` elements;
- `h1–h6`, `a[href]`, `img/svg` with alt or title (alt="" → `h:1`), `ul/ol/li/dl`, `hr`;
- landmarks (`nav main header footer aside form section[aria-label]`);
- `dialog`, `table/tr/td/th` (phase 3), `progress/meter`, `details/summary`;
- every native-control node.

**Text nodes get no entry.** A `.text` node is an implicit `role:text` whose name the backend reads
from `props.runs`. Each link run inside it (`run.k`) is a child element whose rects come from
`Backend.run_rects`, with `Tree.ax[k]` as its role and name. This is the Android scoping's proposal, which is correct.

Name (`accName`, WAI accname 1.2 order: **`aria-labelledby` before `aria-label`**, which corrects the
Android scoping's order):
1. `aria-labelledby` (text of the referenced elements);
2. `aria-label`;
3. native: `<label for>` or wrapping `<label>`, `alt`, `<caption>`/`<legend>`/`<figcaption>`, an input button's value;
4. subtree text, for roles that take their name from content (button, link, heading, checkbox, radio, option, tab, menuitem, cell, listitem, tooltip, treeitem);
5. `title`; if a name already came from 1–4, `title` becomes `d`.

Names are trimmed to 256 chars. `d` comes from `aria-describedby`, else `title`.

States come from DOM and ARIA:
- `disabled` attribute or `aria-disabled`;
- `.checked` / `aria-checked` (mixed: `.indeterminate` or `aria-checked=mixed`);
- `aria-expanded`, or `details[open]`;
- `aria-selected`, `option.selected`, `aria-pressed`;
- `required` / `aria-required`, `aria-invalid`, `readonly` / `aria-readonly`;
- focusable when tabindex ≥ 0 or naturally focusable.

`role=presentation|none` on a non-focusable element → no entry, and its children belong to the next ancestor.

**Tree shape:** an `ax` node's a11y parent is the nearest node ancestor with an `ax` entry, else the
root. Children follow node-tree order, which is DOM order except for fixed boxes (re-rooted) and
flex `order`. Nodes with `vis:false`, a zero frame or `h:1` are pruned. Platform objects are built
**lazily** (on query) and hold only `(surface, id)`. When a query finds the id gone, they report
"element not available".

**Native controls merge** at their node's place in the order:
- AppKit and UIKit return the NSControl/UIControl itself, with its `accessibilityParent` set to our parent element.
- Win32 returns `UiaHostProviderFromHwnd(child)` as that fragment's host provider.
- GTK links the real GtkWidget into the custom accessible chain.
- Android calls `AccessibilityNodeInfo.addChild(View)`.

The native role and state are kept. Our `al` is applied as its label:
- `setAccessibilityLabel:` on Apple platforms;
- `gtk_accessible_update_property(GTK_ACCESSIBLE_PROPERTY_LABEL)` on GTK;
- `IAccPropServices::SetHwndPropStr(UIA_NamePropertyId)` on Win32;
- an `AccessibilityDelegate` setting the name or hint on Android.

### 2.3 Actions back (engine events, all existing except two)
| AT action | engine | handled by |
|---|---|---|
| press, activate, invoke, ACTION_CLICK, toggle, expand/collapse, select | `"click"` | `activate()` |
| set focus | `"focus"` | `document.__active = el` (shows ring as keyboard focus: set `keyboardFocus=true`) |
| show menu | `"contextmenu"` [cx,cy] | existing |
| scroll into view | Zig only: `Tree.scrollIntoView(n,"nearest")`, then the usual scroll notice | no JS needed |
| scroll a scroller (Android SCROLL_FORWARD, UIA ScrollPattern) | existing `scrollBy`/`scroll` paths | existing |
| increment/decrement on a *drawn* slider-role element | new `"axstep"` data ±1 → dispatch ArrowUp/ArrowDown keydown on el | main.js |

Hit testing for touch exploration and Narrator uses `Tree.hit()`. The first node up the chain with `ax`, or a text node, wins.

## 3. Per-backend work

Every backend gains:
- (a) `syncControls(s)` next to `syncFields`, or a shared loop for kinds `.button/.check` with the
  same visibility and clipping rules as that backend's fields;
- (b) `measure` for `.button`, which delegates to its text measure of `props.runs`;
- (c) a paint switch where `.button/.check` draw nothing;
- (d) `focus()` that also looks the node up in the controls map;
- (e) a11y providers (2.x).

### 3.1 GTK (gtk.zig)
- **Prerequisite (fixes fields too):** a per-control holder (a `GtkFixed` with
  `gtk_widget_set_overflow(GTK_OVERFLOW_HIDDEN)`), placed at the visible part, with the control
  offset inside. This is the AppKit holder model. Without it a half-scrolled button vanishes.
- `makeControl`: `gtk_button_new_with_label`, or `gtk_check_button_new` for checks. A radio gets
  `gtk_check_button_set_group(btn, anchor)` with a private, never-shown anchor per radio, used only
  for the radio indicator.
- Per-node CSS through the existing `updateCss`:
  - `.nui-f{id}` for buttons: `min-height:0; min-width:0; padding:0` (the control fills the CSS border
    box; Adwaita's look stays), plus the label's color and size.
  - Indicator size for checks: `check, radio { min-width/height: Npx; margin:0 }`.
- Signals: `clicked` (button), and `toggled` (check, ignored when `s.updating`) → `"click"`.
- Keys: a key controller in capture phase sends `"key"`, then returns TRUE for space, Return and
  KP_Enter, so JS owns activation.
- a11y needs GTK ≥ 4.10. An `OrielAxNode` GObject implements `GtkAccessible`:
  - vfuncs: `get_at_context` (`gtk_at_context_create(role, self, display)`), `get_accessible_parent`,
    `get_first_accessible_child`, `get_next_accessible_sibling`, `get_bounds`, `get_platform_state`.
  - The drawing area becomes a GType subclass (`OrielArea`) that re-implements `GtkAccessible`'s
    child and sibling vfuncs, chaining to our nodes and to the field holders.
  - Changes go through `gtk_accessible_update_state/property/relation`; announcements need 4.14's `gtk_accessible_announce`.
  - **Needs a PoC first** (risk R3).

### 3.2 Win32 (win32.zig)
- `makeControl`: `CreateWindowExW("BUTTON")` with `BS_PUSHBUTTON | BS_MULTILINE`, `BS_CHECKBOX`,
  `BS_3STATE` or `BS_RADIOBUTTON` (all non-auto), plus `WS_TABSTOP`, in a `makeClip` window, as fields are.
  - State: `BM_SETCHECK`, with `BST_INDETERMINATE` for `mix`. Font: `WM_SETFONT` from the run's font.
  - `subclass(hwnd, &controlProc)` sends keys to the page first and eats `VK_SPACE`/`VK_RETURN`.
  - `BN_CLICKED` arrives as `WM_COMMAND` at the clip window's proc → `"click"`.
  - `WM_CTLCOLORBTN`/`WM_CTLCOLORSTATIC` return a brush of the background behind the node (the
    nearest ancestor with a solid `bg`), because themed rounded corners show the parent (risk R4).
  - Dark: `SetWindowTheme(hwnd, "DarkMode_Explorer")` when `dk` (not documented: Q5).
- a11y: in the canvas wndproc, `WM_GETOBJECT` with `lParam == UiaRootObjectId` returns
  `UiaReturnRawElementProvider` of an `IRawElementProviderFragmentRoot`. Each `ax` node is an
  `IRawElementProviderSimple + Fragment` COM object (hand-written vtables, like the existing
  IDropTarget) with:
  - `RuntimeId [UiaAppendRuntimeId, id]`, `BoundingRectangle` (frame × scale + ClientToScreen), `Navigate`, `SetFocus`;
  - `GetPatternProvider`: Invoke, Toggle, SelectionItem, ExpandCollapse, ScrollItem, RangeValue (drawn);
  - events: `UiaRaiseAutomationEvent`, `…PropertyChangedEvent`, `…StructureChangedEvent`; `UiaRaiseNotificationEvent` for "n".

### 3.3 AppKit (appkit.zig, apple_draw.zig)
- `makeControl`: an `NSButton` in a clipping holder (as `makeField`).
  - Type: push (`NSBezelStyleRounded`; `NSBezelStyleFlexiblePush` when the box height differs from
    the control size's natural bezel height), `NSButtonTypeSwitch`, or `NSButtonTypeRadio`.
  - `allowsMixedState` for `mix`. `controlSize` is mini/small/regular, picked by the box height.
  - `appearance` is darkAqua when `dk`. `attributedTitle` carries the font and color.
  - target/action → `"click"`, then mark stale.
  - Keys: a runtime subclass `OrielButton` overrides `keyDown:`/`keyUp:` and forwards to the surface's key path.
- The UA_CSS_MAC push-button imitation (`pushButton()`, `PUSH_MARK`) becomes the fallback mark
  only. Keep `mac-buttons.test.mjs` for `controls: []`.
- a11y: the surface view overrides `accessibilityChildren` and `accessibilityHitTest:`.
  - Elements are `NSAccessibilityElement` instances (`accessibilityElementWithRole:frame:label:parent:`),
    or a small runtime subclass for `accessibilityPerformPress`/`ShowMenu`, `setAccessibilityFocused:` and
    `accessibilityFrameInParentSpace`, which keeps them right while scrolling.
  - Notifications: `NSAccessibilityPostNotification` (LayoutChanged, ValueChanged,
    FocusedUIElementChanged, AnnouncementRequested).

### 3.4 Android (android.zig + OrielNative.kt)
- Kotlin `makeControl`:
  - framework `Button`: `isAllCaps=false`, `minHeight/minWidth=0`, `stateListAnimator=null`, `setPadding(0)`, and the
    `InsetDrawable` unwrapped from its background so the bezel fills the box (PoC). Ripple is native.
  - `CheckBox`/`RadioButton` as `NuiCheck` subclasses that scale `buttonDrawable` into the CSS box in `onDraw`.
  - `setOnClickListener` → `tapNode(window,id)`, then mark stale. An `OnKeyListener` sends keys first and consumes Space/Enter.
  - The props mirror already carries `ctl/on/dis`. `mix` and `al` are added.
- android.zig: forward `on_ax` as JSON through a new JNI call `ax(window, id, json)`. Kotlin keeps `axById`.
- a11y (agree with the Android scoping):
  - a framework `AccessibilityNodeProvider` on `NuiView`, not androidx;
  - virtual id = node id, and `HOST_VIEW_ID` for the root;
  - bounds from `frames` × density;
  - real field views via `addChild(View)`;
  - built only while enabled;
  - `TYPE_WINDOW_CONTENT_CHANGED` throttled to Choreographer frames;
  - actions: CLICK → `tapNode`, SCROLL → `scrollBy`, ACCESSIBILITY_FOCUS handled locally, FOCUS → `event("focus")`.

### 3.5 iOS (uikit.zig)
Decision:
- `<button>` → `UIButton` with `UIButtonConfiguration.grayButtonConfiguration` (iOS 15+). This is
  iOS Safari's own look: gray fill with tinted text.
- **Checkbox and radio stay drawn.** UIKit has no checkbox. `UISwitch` has other semantics and a
  fixed 51×31 size that breaks web layout. The checkbox that WKWebView itself draws is the
  platform's web look. They are made accessible: trait button plus `UIAccessibilityTraitToggleButton`
  (iOS 17), with value "checked"/"unchecked"/"mixed".
- a11y: the surface view's `accessibilityElements` is a **flat array in reading order** (VoiceOver
  navigates linearly; the rotor uses traits).
  - `UIAccessibilityElement` with `accessibilityFrameInContainerSpace`; native controls are inserted as-is.
  - Traits: header, link, button, image, selected, notEnabled, adjustable.
  - `accessibilityActivate` → click, `accessibilityScroll:`, `accessibilityIncrement/Decrement`.
  - `UIAccessibilityPostNotification(layoutChanged|screenChanged|announcement)`.

### 3.6 JS files
- `render.js`:
  - `nativeButton(el, cs)` implements rule 1.4;
  - the check branch picks `kind:"check"`;
  - the `<input>` button types get a button path (drawn or native), which fixes the text-field bug;
  - no `ol` for native kinds;
  - the UA sheets get per-platform sentinels.
- `css.js`: `rule.stateBox` tagging (rule 1.4.5).
- `main.js`:
  - keyboard activation in `keyEvent`;
  - `reset(form)`;
  - `.indeterminate` property → re-render;
  - `"a11y"` and `"axstep"` events;
  - `document.__active` setter → `a11y.focus(el)`.
- New `a11y.js`: `roleOf`, `accName`, `statesOf`, the dependency map, and `A11y.emit(ops)`. It runs
  inside `Renderer.emit` after node ops (so nodes exist) and diffs per id by encoded string. The
  scope per frame is the rebuilt elements plus marked dependents, with a full pass on enable.
  It is bundled into `runtime*.js` like the other modules.

## 4. Phases (smallest useful first)

**Feature 1**
- **1.0 (JS only, all platforms, no new kinds):**
  - keyboard activation (Enter/Space);
  - `<input type=button|submit|reset>` as buttons;
  - `reset(form)`;
  - `mix` drawn by `paintControl`;
  - Win32 and Android also get focus visibility for drawn buttons.
  This fixes real bugs on every platform today.
- **1.1 Native checks** (`.check`) on GTK, Win32, AppKit and Android:
  - only two widget types and no content rule;
  - the existing CSS size and the existing `appearance:none` rule;
  - non-auto state with re-assert;
  - the GTK holder prerequisite.
- **1.2 Native text-only buttons** (`.button`) with rule 1.4 on GTK, Win32, AppKit, Android and iOS, plus the css.js `stateBox`.
- **1.3 Icon + text:** a single leading `<img>`/`<svg>`/icon child gets the native image slot:
  NSButton `image`, `BCM_SETIMAGELIST`, a GtkButton child box with a GtkPicture, an Android compound
  drawable, UIButtonConfiguration `image`. All other rich content stays drawn.
- **1.4 Z-order and pointer fidelity:**
  - a control covered by a later-painted box is hidden and replaced, in paint order, by its snapshot
    (`GtkWidgetPaintable`, `WM_PRINTCLIENT`, `cacheDisplayInRect`, `View.draw` to bitmap);
  - pointerdown/up/mousedown forwarded from native controls.

**Feature 2**
- **2.0 Labels on native widgets (all backends):** `al`/`ro` on input, textarea, select, button and check.
  Existing fields get their `<label>` names. This is one setter per backend and aligns with the macOS session.
- **2.1 Contract plus two backends:**
  - a11y.js, the `"a"` op, `Tree.ax`, on/off, `ORIEL_NUI_AXDUMP` (Zig logs the merged tree);
  - roles, names and states for interactive elements, headings, images and text nodes;
  - activate, focus and scroll-into-view actions;
  - **AppKit and Android**, the simplest lazy APIs.
- **2.2 Win32 UIA, iOS, GTK** (the GTK PoC must pass first).
- **2.3** Link runs as elements, the `"f"` focus op, lists and landmarks, tables, live regions (`"n"`), `aria-describedby`, `"axstep"`.
- **2.4** Text navigation (UIA TextPattern, `GtkAccessibleText` 4.14, NSAccessibility text ranges)
  and per-character reading in long text. Defer until there is demand.

## 5. Testing
- **node tests** (`src/native_ui/js/test`, harness as in `mac-buttons.test.mjs`, platform JSON with `controls`):
  - `native-controls.test.mjs`: the rule 1.4 table:
    - native: plain, padded, colored;
    - drawn: `appearance:none`, background, border color, radius, `:hover{background}`, `<svg>` child, `::before`, `<b>` child (native, label text), empty label;
    - also: `kind:"check"` props, `controls:[]` gives today's output, input button types.
  - `key-activation.test.mjs`: Enter/Space on button, checkbox, radio, link; preventDefault on keydown blocks.
  - `form-reset.test.mjs`.
  - `a11y.test.mjs`: no `"a"` ops before `event(0,"a11y",1)`; full then incremental; accname order
    table (labelledby > label > for > alt > content > title→d); `aria-hidden` prune; presentation;
    `<label>` text edit re-sends `al` and `ax.n`; `"a"` null on removal.
- **Zig** (`tree.zig` tests): `"a"` op parse and drop on `"d"`; `.button` measure and baseline with
  the stub measure; `.check` keeps `blb`.
- **Headless GTK**: `SHOT=… scripts/headless.sh` on a controls demo page for screenshots
  (scrolled half out, under a modal, disabled, dark).
  - For a11y, add `A11Y=1` to headless.sh: it keeps `GTK_A11Y` unset and starts
    `at-spi-bus-launcher` in the private D-Bus session.
  - `scripts/atspi-dump.py` (pyatspi) asserts roles and names. `ORIEL_NUI_AXDUMP` diffs the same tree backend-independently.
- **Manual**, each platform:
  - Tab order, Space/Enter, focus ring, a React-controlled checkbox, preventDefault on click, radio groups;
  - macOS VoiceOver plus Accessibility Inspector;
  - iOS VoiceOver on the simulator plus Accessibility Inspector;
  - Windows Narrator plus Accessibility Insights / inspect.exe (patterns, runtime ids);
  - Orca plus Accerciser;
  - TalkBack plus `adb shell uiautomator dump`, which lists virtual nodes and can be scripted.

## 6. Risks
- **R1 Z-order:** native widgets sit above the canvas, so drawn menus and modals under or over them
  conflict. Today fields are hidden or trimmed when covered, and with many buttons this shows more.
  Phase 1.4 fixes it with snapshots. Until then, buttons under a modal backdrop vanish instead of dimming.
- **R2 Layout drift:** in the chosen model the CSS box sizes the control, so layouts match the
  WebView build. Some bezels look odd at sizes they were not made for (NSButton push → flexiblePush,
  Android insets). Wrapped labels need multiline (BS_MULTILINE, GtkLabel wrap); NSButton truncates.
- **R3 GTK a11y on a drawing area:** whether a subclass can re-implement `GtkAccessible` child
  enumeration under GObject's interface override rules, and the behavior across 4.10–4.22.
  Fallback: one hidden accessible GtkWidget per `ax` node (heavy).
- **R4 Win32 themed corners and dark mode:** the solid-brush approximation of the background behind a
  control; no official dark BUTTON theme.
- **R5 Many native widgets:** a 500-row list with a button per row means 500 HWNDs or NSViews.
  Cap by visibility: create on first visible and destroy after leaving the viewport plus a margin,
  using the same visibility test as fields.
- **R6 Stamped rows** (`host.stamp`/`stampList`) bypass JSON. A native button in a stamped row
  needs `Backend.leaf`/`on_create` to create widgets, so rule 1.4.7 keeps them drawn in v1.
- **R7 a11y object lifetime:** UIA/NS/GTK hold references to elements after nodes die. Elements
  hold only the id, and every query re-resolves it.
- **R8 Reading order** follows the node tree, not DOM order, for fixed boxes and flex `order`. Accept for now; a11y.js could send `o` (order hint) later.

## 7. Open questions
- Q1 Should button and check sizes keep the WebView-measured UA metrics (recommended, no layout
  change), or switch to the platform controls' intrinsic sizes (e.g. GtkButton 34px tall)?
- Q2 iOS: confirm checkbox/radio stay drawn, and confirm the iOS 15 minimum for UIButtonConfiguration. The minimum macOS version also needs checking.
- Q3 Checkedness: `.checked` reflects the attribute (main.js), so `defaultChecked` is lost and reset
  cannot restore it. Should the browser's "dirty checkedness" model be adopted? That means `:checked`
  in css.js matching a property-driven mark, not `[checked]`.
- Q4 The `al`/`ro` names and semantics from the macOS session: confirm `al` = `accName()` (labelledby first), so both land as one prop.
- Q5 Is undocumented `DarkMode_Explorer` on Win32 BUTTON acceptable, or should dark pages fall back to drawn buttons on Windows?
- Q6 GTK minimum 4.10 (4.14 for announce and text): acceptable for target distros?
- Q7 Opt-out granularity: one window option, or a CSS hook (`appearance: none` is already standard)?
