# Fast window switcher development branch

This replaces `hs.window.switcher` for the existing window navigation shortcuts.
Window search and browser-tab search remain on `hs.chooser`.

## Behavior

- Alt+Tab starts a visible-window session. While Alt remains down, Shift+Tab
  reverses this session; Alt+` also reverses it.
- Shift+Alt+Tab starts a session that also includes minimized windows. Repeating
  that chord advances; Shift+Alt+` reverses it.
- Ctrl+Alt+Tab and Ctrl+Alt+Shift+Tab navigate browser windows forward/backward.
- Esc cancels without restoring, focusing or activating any window. Releasing a
  required base modifier commits the selected window once, even if Shift remains down.
- Existing application exclusion rules are applied to the persistent filter.
  Hidden applications remain excluded. Closing/hiding windows removes them during
  a session; newly discovered windows appear in the next session.
- The list keeps a stable order while cycling. Separate presses wrap; holding a
  key repeats up to the current endpoint, matching the previous implementation.
- The normal shortcuts are disabled while the external AltTab application runs.

## Performance design

`src/window/switcher.lua` owns a subscribed window filter, cached window metadata,
application icons, strongly held thumbnail images, and one reusable canvas.
Window events update metadata and the three lists outside the summon path. Canvas
slots are created at initialization and rebuilt only if the screen capacity changes.
Long lists page through a fixed number of visible slots instead of shrinking every
thumbnail to fit the screen.

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
resized to at most 768×480 before Lua decodes them. Lua drains at most four results
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

The development branch is isolated from the live `~/.hammerspoon` configuration.
The runtime test above is not a deployment. To try normal shortcuts, deploy this
branch's `src/window.lua` and the complete `src/window/` directory together using
the usual configuration workflow; the capture library compiles once into the
system temporary directory. Reverting to the previous `src/window.lua` restores
the previous switcher. No compiled binary is tracked in Git.
