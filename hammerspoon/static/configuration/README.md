# Configuration GUI

The configuration loads `src/configuration.lua` at startup. Open
`hammerspoon://configuration` or run `Configuration.show()` in the Hammerspoon
console to display the Configuration window.

Press **⌥⌘,** when the active application, focused window, or open menu belongs to
Hammerspoon. The shortcut uses the existing context hotkey manager and respects
the project's shortcut suspension setting. No additional menu bar icon is created,
and Hammerspoon's native Preferences remain available.

- The sidebar provides primary categories, tabs provide secondary categories,
  and section headings organize configuration within each tab.
- Strings, numbers, and booleans are directly editable. Nested configurations
  can be expanded, and lists support adding and removing entries.
- JSON editors include syntax highlighting. **Add entry** is available for lists,
  named objects, and page-level collections such as apps, rules, and proxies.
- File mapping source paths, path variable names, and modifier macro names are
  editable. Duplicate names are rejected. Renaming a variable or macro updates
  its references within the same configuration file.
- Macro names retain their exact JSON spelling. The reserved `hyper` name is read-only;
  its value remains editable. The optional `hyperKeyName` field remains supported
  for existing configurations that use a different primary macro name.
- Menu translations have separate forward and reverse localization blocks. Empty
  blocks are omitted and replaced with an **Add Forward localization** or
  **Add Reverse localization** button. Existing JSON storage remains unchanged:
  a compact object is a reverse map, and a pair is ordered `[reverse, forward]`.
- Shortcut modifiers and keys share the title row and use key symbols. Macro
  references remain literal text in a distinct background color.
- Per-app shortcuts start collapsed. Expansion state is retained while editing.
  **⋯ Options** opens their additional properties; Control Center is an exception.
- App launcher rows show app names and shortcuts. Click an app name to edit its
  configuration. Candidates not currently bound to that appkey appear gray.
- **Save changes** writes only the current tab's JSON file. Drafts in other files
  are retained. Saving does not reload Hammerspoon automatically.
- **Reload** applies saved configuration and automatically reopens the Configuration
  window after reloading. Unsaved drafts must be saved or discarded first. Reloading
  from other entry points does not automatically reopen the window.
- Closing the window retains drafts. Quitting or reloading Hammerspoon clears them.
- **Refresh files** reads all configuration files again and asks for confirmation
  before discarding unsaved changes.

All configuration I/O is local, with no server, remote resources, or additional
runtime dependencies. File names are restricted to a fixed allowlist. Saving
checks for external changes, backs up an existing file as `.json.bak`, and replaces
it atomically using a temporary file.

JSON data types, including empty arrays and `null`, are preserved. Saving formats
the current file with two-space indentation. Validation checks the JSON object
structure and a positive polling interval; it does not replace runtime validation
of individual automation rules.

Missing optional files are shown as empty configurations and created only when
saved. Missing sections offer **Configure** or **Add entry**, and omitted shortcut
fields show **Not set**. Browsing alone never inserts default values. Read errors
and malformed JSON are reported rather than treated as empty files.

## Validation

Run from the project directory:

```sh
node tests/configuration_spec.js
lua tests/configuration_spec.lua
lua tests/configuration_macros_spec.lua
luac -p src/configuration.lua init.lua
```

Frontend tests use a lightweight DOM simulation to exercise tab rendering,
drafts, editing, and serialization. Backend tests use isolated temporary files to
check saving, backups, conflicts, and rejected inputs. Macro tests exercise the
startup loader with renamed primary Hyper macros. Actual WebKit appearance and
interaction require verification inside Hammerspoon.
