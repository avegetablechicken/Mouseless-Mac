# Hotkey icons

106 transparent SVG icons with 192 × 192 intrinsic bounds for the shortcut chooser. Dark rounded
outlines, blue target regions, directional arrows, and numbered displays follow
one geometric style. Only SVG assets are required at runtime.

Current SVGs use near-square subject geometry within the 96 × 96 view box:
windows are 76 × 72, monitor silhouettes approximately 72 × 73, and keyboards
70 × 72. Regions, borders, title bars and controls are laid out within those
shapes; text and arrowheads retain their proportions. There is no enclosing
background tile.

`src/hotkey_icons.lua` matches shortcut descriptions to filenames, ignoring case
and normalizing punctuation. Explicit icons and existing application icons take
priority. Window operations and the five Hammerspoon utility actions use their
operation-specific illustrations instead of category/application placeholders. Missing
icons use a matching illustration, then a category fallback (keyboard, navigation,
application, window, background action, or menu bar).

Only SVG is loaded through `hs.image.imageFromPath`. A missing or unloadable
SVG retains the existing icon or uses the category fallback. Native SVG loading
and transparency were checked on macOS 26.
Toggle Hotkeys, Reload Hammerspoon, Toggle Hammerspoon Console, Show Keybindings,
and Search Hotkey now have dedicated illustrations.

Regenerate SVGs and validate them using the native macOS image renderer:

```sh
mkdir -p /tmp/hammerspoon-operation-icons
lua static/hotkeys/generate.lua static/hotkeys
swift static/hotkeys/render.swift static/hotkeys /tmp/hammerspoon-operation-icons --verify-svg
```

The verification contact sheet is `/tmp/hammerspoon-operation-icons/svg-preview.png`.
Its first row contains native application icons for size and padding comparison.

Window/browser switching, window/tab search, menu-bar search, window information,
and Stage Manager have dedicated illustrations. Localized Stage Manager labels
are matched by hotkey category and trailing window index. Numbered targets cover
1–9; higher indices use a category icon. Assets do not create shortcuts.

All geometry and operation definitions live in `generate.lua`. The native macOS
renderer handles only its SVG subset (rectangles, lines, and text), using Core
Graphics and Core Text. Neither Hammerspoon nor external packages are required
to regenerate the PNGs:

```sh
mkdir -p /tmp/hammerspoon-operation-icons
lua static/hotkeys/generate.lua /tmp/hammerspoon-operation-icons
swift static/hotkeys/render.swift /tmp/hammerspoon-operation-icons static/hotkeys
```

For optional single-page vector PDF exports, shapes and text are paths with no
raster images or embedded fonts. This command preserves existing PNG files:

```sh
lua static/hotkeys/generate.lua /tmp/hammerspoon-operation-icons
swift static/hotkeys/render.swift /tmp/hammerspoon-operation-icons static/hotkeys --pdf
```

PDF mode reopens and renders every exported file for verification, checks AppKit
loading, and saves its contact sheet to the temporary SVG directory as
`pdf-preview.png`. PDF generation does not change runtime references.

Reload Hammerspoon to load the chooser integration. The preview's main-screen,
full-screen, and whole-window border examples are also provided as assets; they
are only used if a matching operation is present.
