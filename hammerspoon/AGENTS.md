# AGENTS.md

## Communicating with Hammerspoon

Use interaction with the running Hammerspoon instance sparingly, only when information essential to the task cannot be obtained through source inspection, static checks, or direct inspection of the target application. Do not open Hammerspoon or Console, bootstrap IPC, or check reload completion as a routine step for configuration or hotkey changes. For example, extending Alt+D to recognize Pages' “Revert Changes” button requires inspecting Pages and editing the existing button matching logic, not communicating with Hammerspoon. Editing Lua files alone does not justify runtime interaction.

The Console and CLI procedures below apply only after establishing a concrete need for Hammerspoon's internal runtime information. Inspect a target application's accessibility hierarchy directly in that application whenever possible. File moves, path updates, static checks, and Git operations alone do not require these procedures. Honor an explicit user instruction not to open Hammerspoon.

### Console

1. Start with Console to execute Lua directly; follow the CLI steps when command-line access is needed. If Lua configuration files were edited, wait for the latest `-- Done.` message before executing a required runtime query.
2. Call `let app = await cua.getApp("org.hammerspoon.Hammerspoon")` and locate the editable `text field` in the returned accessibility state.
3. Use `app.setValue(fieldIndex, luaCode)` to enter Lua, then `app.pressKey("Return")` to execute it. For a direct query, use:
   ```lua
   print('CONSOLE_RESULT', hs.configdir, hs.processInfo.processID)
   ```
4. Call `app.getAXState()` and read the output following the submitted command. Confirm the result marker and returned values.
5. For a longer query, write the Lua code to a task-specific file under `/tmp`, then execute `dofile("/tmp/<task>.lua")` through the same Console input. Read printed results from Console; for asynchronous results, write them with Lua `io.open` to a task-specific result file and read that file after its completion marker appears.
6. Refresh the accessibility state before selecting the input field again and use the field index from that state.

### CLI

1. Finish Lua configuration edits and wait for the latest `-- Done.` message in Console.
2. Execute the following through the Console steps above:
   ```lua
   require('hs.ipc'); print('IPC_BOOTSTRAP', hs.ipc.__default, hs.processInfo.processID)
   ```
3. Read the Console output and confirm `IPC_BOOTSTRAP`, `hs.ipc: Hammerspoon, local`, and the process PID.
4. Use `exec_command` outside the sandbox with `sandbox_permissions="require_escalated"`, reusing existing authorization, to run:
   ```sh
   timeout -k 1s 8s hs -c 'print("IPC_READY", hs.configdir, hs.processInfo.processID)'
   ```
5. Confirm exit code 0 and output containing `IPC_READY`, `/Users/xuyiwen/.hammerspoon`, and the PID from step 3.
6. Run an actual runtime query through the same outside-sandbox execution:
   ```sh
   timeout -k 1s 8s hs -c 'print("RUNTIME_OK", #hs.hotkey.getHotkeys(), hs.screen.mainScreen():name())'
   ```
7. Confirm the returned hotkey count and screen name, then run the required Lua queries one at a time with `timeout -k 1s 8s`. Do not substitute `hs -t` or the tool's `yield_time_ms` for the external process deadline.
8. After another configuration reload, wait for the new `-- Done.` message and repeat steps 2–7.

### Connection Failures and Cleanup

1. If a sandboxed CLI call reports `Connection Invalid` or `com.apple.hiservices-xpcservice`, rerun it outside the sandbox through the CLI execution step above, following the tool's approval requirements.
2. If the CLI reports `can't access Hammerspoon message port`, check Console for a reload after the last IPC bootstrap. Execute `print(package.loaded['hs.ipc'])` in Console to check module loading without loading it implicitly. If it is absent, repeat the Console IPC bootstrap and outside-sandbox probe.
3. Keep the same `hs` command and default port while resolving module loading and sandbox access. Do not cycle through executable paths or retry with `-m Hammerspoon`, `-n`, or `-q` to fix a connection failure.
4. If the outside-sandbox CLI remains unavailable after bootstrap, execute the query directly in Console. For longer or asynchronous queries, execute a task-specific `/tmp` Lua file through Console and write the results with `io.open`; check the current task's completion marker before reading the result file.
5. After a timeout or interrupted call, inspect `ps -axo pid,ppid,etime,command` and confirm that this task's CLI client has exited. Match any remaining client by its command and task ownership, terminate only that PID, and verify its exit before starting another client. Do not use `killall hs` or terminate clients belonging to other tasks.
6. After diagnosis, remove only this task's temporary `dofile` or IPC-loading entries from configuration files. Check both `~/.hammerspoon` and the configured Git repository for synchronized copies and remove the same temporary entries there. Wait for the resulting reload to finish; repeat the CLI bootstrap if further CLI queries are needed.

## Implementation Preference

- Prefer implementing logic in Lua and avoid adding external scripts where practical.
- Use external commands when appropriate; this preference does not require reimplementing their capabilities in Lua.
- Keep application hotkey implementations consistent with the existing project style and reuse existing helpers.
- Add a nearby test-version comment for an application-specific feature only after actual runtime testing, recording the exact application and macOS versions tested (for example, `-- Tested on: AppName 1.2.3; macOS 27.0.1.`). Static inspection and syntax checks do not count as runtime testing. If runtime testing has not been completed, omit the test-version comment; do not add `untested` or equivalent annotations.
- When UI changes require a different implementation and the version introducing the change is known, branch on that version and preserve the existing implementation for older versions. This applies to both macOS versions and application versions; use the existing OS_VERSION/OS and applicationVersion helpers as appropriate.
- Verify the version boundary rather than assuming the currently installed version introduced the change. If the exact boundary is unknown, state that uncertainty and document any provisional boundary based on verified behavior instead of presenting it as confirmed.
- When locating UI elements by strings, prefer the existing localization helpers (such as `T` and `TC`) and verify the relevant localization resources where possible. Do not hardcode translated labels or add hardcoded translations as fallbacks merely because localization lookup has not yet been verified.
- Before implementing UI button hotkeys, inspect the actual application's accessibility hierarchy in the relevant UI state. Hardcode verified paths using the existing `getc(...)` style; do not substitute recursive traversal or generic searches for verified paths.
- Prefer a localizable label (`AXAttributedDescription`) or `AXTitle` over `AXIdentifier` when available; prefer a meaningful `AXIdentifier` over numeric indices only when no suitable label or title is available, especially for leaf controls such as `AXButton` and `AXTextField`. Use strings that remain generally applicable, not opaque internal markers such as `_NS:10`. An icon name such as `play.fill` is acceptable as an identifier when it unambiguously distinguishes the control. Use numeric indices only when no suitable specific attribute is available.
- If accessibility inspection is unavailable, report the blocker instead of guessing paths or adding a generic search fallback.

## Minimal Fix Policy

- This policy applies only to bug fixes. New features are not subject to the 10-line limit; use normal formatting and as many lines as the implementation requires.
- Fixes for uncommitted problems that Codex itself has just introduced are exempt from the changed-line limit and do not require approval to exceed 10 lines.
- Every fix must be the smallest possible fix and must reuse the existing implementation.
- Modify only the location causing the problem, with no more than 10 changed lines.
- If more than 10 changed lines are unavoidable, stop before making those changes, report the reason in detail, explain the proposed implementation and how it works, and wait for explicit approval.
- In particular, when the prompt says the behavior worked before and only recently became buggy, treat it as a regression: preserve the previously working implementation and fix only the specific regression point.

## Commit Message Style

- Use `type(scope): summary` for every commit, including `fix`, `feat`, `perf`, `docs`, `refactor`, and `chore`.
- Use the specific affected module or component as the scope, such as `browser-tabs`, `window-switcher`, `menubar`, `clipboard`, `localization`, or `keybindings`. Do not use `hammerspoon` as a generic scope: it is already the default context.
- For changes outside Hammerspoon, name the actual component being changed, such as `pac`, `proxy`, or `gitignore`.
- Write concise English summaries in the imperative that describe the concrete behavior changed and, when useful, the trigger or outcome. Avoid vague summaries such as "fix bugs" or "improve behavior".
- Add a body when needed to explain the problem, resulting behavior, or meaningful validation. Keep existing useful detail when rewording commits.
- Use consistent messages for corresponding commits across branches when synchronizing history.
