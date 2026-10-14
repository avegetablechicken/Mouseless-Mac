# Fast window switcher development branch

This replaces `hs.window.switcher` for the existing window navigation shortcuts.
Window search and browser-tab search remain on `hs.chooser`.

## Behavior

- Alt+Tab starts a visible-window session. While Alt remains down, Shift+Tab
  reverses this session; Alt+` also reverses it.
- Shift+Alt+Tab is detected by a dedicated eventtap and starts a session including
  minimized windows; no `hs.hotkey` binding is created for this chord. In this mode
  Tab advances and backtick reverses. In the ordinary Alt+Tab session, Shift+Tab
  still reverses. The launch detector ignores repeats, suspension, extra modifiers
  and active sessions, and stops while the external AltTab app is running.
- Ctrl+Alt+Tab and Ctrl+Alt+Shift+Tab navigate browser windows forward/backward.
- Only the three launch chords are registered as hotkeys. Opening and closing a
  session does not enable, disable or re-register them. During a session eventtap
  consumes forward/backward navigation, arrow keys and Escape before normal key
  handling; launch callbacks also ignore input while a session is active.
- Left/right move within the current row; up/down select the closest horizontal
  card in the adjacent row. Arrow keys stop at grid edges.
- Esc cancels without restoring, focusing or activating any window. Releasing a
  required base modifier commits the selected window once, even if Shift remains down.
- Existing application exclusion rules are applied to the persistent filter.
  Hidden applications remain excluded. Closing/hiding windows removes them during
  a session; newly discovered eligible windows are appended immediately. The grid
  reflows while keeping the selected surviving window and existing order stable.
- The list keeps a stable order while cycling. Separate presses wrap; holding a
  key repeats up to the current endpoint, matching the previous implementation.
- The normal shortcuts are disabled while the external AltTab application runs.

## Performance design

`src/window/switcher.lua` owns a subscribed window filter, cached window metadata,
application icons, strongly held thumbnail images, and one reusable canvas.
Window events update metadata and the three lists outside the summon path. Canvas
slots are created at initialization and updated when window count or screen geometry changes.
The panel is a card grid with no separate large preview above it. Each card has
an application icon and title header above a larger thumbnail (300-point default
card width). Grid shape is determined by window count, independently of the screen:
1–4 windows use one row; 5–8 use 2×4; 9–12 use 3×4; 13–15 use 3×5;
16–20 use 4×5; 21–24 use 4×6; 25–30 use 5×6. Above 30, keep six columns
and the same card scale, show five rows at a time, and scroll vertically. The
canvas pool is bounded to 30 cards. Wheel and trackpad input scroll by rows; a
scrollbar indicates position. Keyboard navigation automatically reveals the selected
card. Closing windows clamps the scroll range. Up to 30 windows, adding windows
never decreases either grid dimension. Removing windows reverses the same sequence.
Screen size affects card scale; icons, headers and images scale together. A native NSVisualEffectView panel supplies a
translucent, blurred backdrop beneath the canvas; it shares the canvas geometry
and is shown/hidden with the same session. Text and previews remain opaque.

The shortcut path copies cached window IDs, selects an item, paints cached images,
and shows the existing canvas. It contains no window enumeration, AX metadata
queries, synchronous screenshots, or fixed display-delay timer. A zero-delay task
requests screenshot refreshes **after** the panel is submitted for display.

`src/window/capture_native.m` runs capture, resize and PNG encoding on a serial
native queue. It uses the same dynamically resolved SkyLight window capture API
used by AltTab for minimized/offscreen windows, falling back to the public window
snapshot API when needed. Private APIs may change with macOS; a failed capture
leaves the older image or application icon in place. This branch does not request
additional permissions automatically.

The native queue deduplicates requests, prioritizes visible tiles, bounds pending
and completed queues to 128 each, and limits in-flight capture to one. Images are
cropped to their nontransparent content (including small Stage Manager surfaces)
and resized to at most 768×480 before Lua decodes them. Fully transparent captures
are rejected so they cannot replace a useful thumbnail or application icon. Lua drains at most four results
per timer tick. Results carry generation and window-identity tokens, so reloads,
closed windows and reused IDs cannot receive stale images. No background block
calls Lua. The library remains mapped across configuration reloads while native
work may still be in flight.

Idle refreshes target the most recently focused window and uncached windows;
visible session tiles are refreshed preferentially. Missing images never delay
showing. Failed captures retry with backoff. Screenshot work is skipped while the
screen is locked. The cache is memory-only and released when its windows disappear
or the engine is deleted; ordinary use does not write screenshots to disk.

First show still pays native window-system presentation costs. Startup inventory
and compilation also take time, but are outside shortcut invocation. This does not
replace Hammerspoon's underlying accessibility window discovery, including its
limitations with fullscreen Spaces that have not been visited.

## Checks

Run from `macos/hammerspoon` in this worktree:

```sh
lua tests/window_switcher_spec.lua
luac -p src/window.lua src/window/switcher.lua src/window/capture.lua
clang -shared -fPIC -fobjc-arc -O2 -Wall -Wextra -Werror \
  -Wno-unused-parameter -undefined dynamic_lookup -framework Cocoa \
  src/window/capture_native.m -o /tmp/hammerspoon-window-capture-dev.so
```

The deterministic suite checks inventories, selection, repeat/wrap behavior,
modifier-release commit, Escape, close-during-session, late results, capture failure,
disposal, actual shortcut routing, and zero AX/enumeration/capture calls on summon.

For an explicit live check, execute the absolute path to
`tests/window_switcher_live.lua` through Hammerspoon Console with `dofile(...)`.
It temporarily loads only the new engine, registers no shortcuts, never commits a
selection, and automatically deletes its filter/canvas/timers. It writes a JSON
result and a canvas-only preview PNG under `hs.fs.temporaryDirectory()` with the
prefix `fast-window-switcher-`. Preview images can contain window titles/content;
they are local test artifacts, not repository files.

On the development machine, a live run with 11 visible windows produced 12 cached
images (the window inventory changed during the run), zero capture errors, a first
show call of 91.5 ms and a second show after eight seconds of 16.0 ms. Twenty tight
repeated show/cancel calls were usually 0.7–1.1 ms, with outliers up to 21.7 ms.
These are **call-to-show-submission timings**, not measured key-to-screen latency
or an apples-to-apples benchmark against AltTab. No speedup ratio is claimed.

## Integration status

The development branch is deployed to `~/.hammerspoon`.
The isolated runtime test above does not itself deploy changes. To try normal shortcuts, deploy this
branch's `src/window.lua` and the complete `src/window/` directory together using
the usual configuration workflow; the capture library compiles once into the
system temporary directory. Reverting to the previous `src/window.lua` restores
the previous switcher. No compiled binary is tracked in Git.

The native image regression test covers transparent padding, asymmetric crop
coordinates, unchanged opaque images, and fully transparent capture rejection:

```sh
clang -fobjc-arc -O2 -framework Cocoa tests/window_capture_image_spec.m \
  -L/opt/homebrew/lib -llua -o /tmp/hammerspoon-capture-image-spec
/tmp/hammerspoon-capture-image-spec
```
