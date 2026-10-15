// Pages laid out around what each setting does, rather than the JSON shape.
import AppKit
import SwiftUI

/// Selectable list row with the System Settings selection highlight.
struct SelectableRow<Content: View>: View {
  let selected: Bool
  let select: () -> Void
  @ViewBuilder let content: Content
  var body: some View {
    content
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
      .contentShape(Rectangle())
      // Simultaneous, so rows whose content is a button are selected as well.
      .simultaneousGesture(TapGesture().onEnded(select))
  }
}

/// A row that opens an editor sheet.
struct PanelRow<Label: View>: View {
  @Environment(Store.self) private var store
  let panel: Panel
  var summary = ""
  @ViewBuilder let label: Label
  var body: some View {
    Button { store.panel = panel } label: {
      HStack(spacing: 10) {
        label
        Spacer(minLength: 12)
        Text(summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct StepperRow: View {
  let title: String
  var help: String? = nil
  let value: Binding<Double>
  var range: ClosedRange<Double>
  var step: Double
  var unit: String
  var body: some View {
    FormRow {
      HStack(spacing: 8) {
        Text("\(JSON.formatNumber(value.wrappedValue)) \(unit)").monospacedDigit().foregroundStyle(.secondary)
        Stepper("", value: value, in: range, step: step).labelsHidden()
      }
    } label: { TitleLabel(title: title, helpText: help) }
  }
}

// MARK: - General

struct GeneralPage: View {
  @Environment(Store.self) private var store
  var body: some View {
    Section {
      StepperRow(title: "Polling interval", help: "How often background checks run, such as detecting apps that quit silently",
                 value: store.numberBinding("misc", [.k("pollingInterval")], default: 1), range: 0.25...60, step: 0.25, unit: "s")
    }
    SnippetsSections()
    let known: Set<String> = ["pollingInterval", "snippets", "pasteboardFilter", "verificationFilter", "proxy"]
    ForEach((store.drafts["misc"]?.object?.keys ?? []).filter { !known.contains($0) }, id: \.self) { key in
      SectionView(spec: SectionSpec(file: "misc", path: [.k(key)], value: store.value("misc", [.k(key)])))
    }
  }
}

struct SnippetsSections: View {
  @Environment(Store.self) private var store
  @State private var rule = 0
  @State private var selection: String?
  private let base: Path = [.k("snippets")]

  var body: some View {
    if store.value("misc", base) == nil {
      Section {
        ActionButtons(actions: [.item("Set Up Text Replacement") {
          store.set("misc", base, .object(JObject([("sound", .string("Pop")), ("rules", .array([]))])))
        }])
      } header: { Text("Text Replacement") }
    } else {
      Section {
        Toggle(isOn: store.flagBinding("misc", base.appending("enabled"), default: true)) {
          TitleLabel(title: "Text replacement", helpText: "Type a prefix and an abbreviation to insert text")
        }
        .toggleStyle(.switch)
        FormRow {
          Picker("", selection: Binding(get: { store.value("misc", base.appending("sound"))?.string ?? (store.value("misc", base.appending("sound")) == .bool(false) ? "" : "Pop") },
                                        set: { name in
                                          store.set("misc", base.appending("sound"), name.isEmpty ? .bool(false) : .string(name))
                                          if !name.isEmpty { NSSound(named: name)?.play() }
                                        })) {
            Text("None").tag("")
            Divider()
            ForEach(SystemSounds.names, id: \.self) { Text($0).tag($0) }
          }
          .labelsHidden().fixedSize()
        } label: { TitleLabel(title: "Sound", helpText: "Played after a replacement") }
      } header: { Text("Text Replacement") }
      replacements
    }
  }

  @ViewBuilder private var replacements: some View {
    let rules = store.value("misc", base.appending("rules"))?.array ?? []
    let current = min(rule, max(rules.count - 1, 0))
    let rulePath = base.appending("rules").appending(current)
    let prefix = rules.indices.contains(current) ? rules[current]["prefix"]?.string ?? "" : ""
    let entries = rules.indices.contains(current) ? rules[current]["entries"]?.object ?? JObject() : JObject()
    Section {
      if rules.isEmpty {
        EmptyRow(text: "Add a prefix to start, such as !!")
      } else {
        FormRow {
          Picker("", selection: Binding(get: { current }, set: { rule = $0; selection = nil })) {
            ForEach(Array(rules.indices), id: \.self) { Text(rules[$0]["prefix"]?.string ?? "—").tag($0) }
          }
          .labelsHidden().fixedSize()
        } label: { TitleLabel(title: "Prefix", helpText: "Typed before each abbreviation") }
        Toggle(isOn: store.flagBinding("misc", rulePath.appending("enabled"), default: true)) { TitleLabel(title: "Use this prefix") }
          .toggleStyle(.switch)
        HStack {
          Text("Abbreviation").frame(width: 170, alignment: .leading)
          Text("Replace with")
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(entries.keys, id: \.self) { name in
          SelectableRow(selected: selection == name, select: { selection = name }) {
            SnippetEntryRow(rulePath: rulePath, prefix: prefix, name: name, value: entries[name])
          }
        }
        if entries.isEmpty { EmptyRow(text: "No abbreviations") }
        ListControls(add: { _ in
          store.ask(PromptRequest(title: "Add Abbreviation", message: "Typing \(prefix) followed by the abbreviation inserts its text.",
                                  label: "Abbreviation", placeholder: "sig", monospaced: true,
                                  validate: { snippetError($0, prefix: prefix, excluding: nil) },
                                  commit: { store.set("misc", rulePath.appending("entries").appending($0), .string("")) }))
        }, remove: selection.map { name in { store.deleteEntry("misc", rulePath.appending("entries").appending(name)); selection = nil } },
           applications: false)
      }
    } header: {
      HStack {
        Text("Abbreviations")
        Spacer()
        ActionsMenu(actions: [
          .add("Add Prefix") { _, _ in
            store.ask(PromptRequest(title: "Add Prefix", message: "A prefix starts every abbreviation in its group, such as !! or ;;.",
                                    label: "Prefix", placeholder: ";;", monospaced: true,
                                    validate: { text in
                                      if text.range(of: #"^[!-~]+$"#, options: .regularExpression) == nil { return "Use printable characters without spaces." }
                                      return rules.contains { $0["prefix"]?.string == text } ? "This prefix already exists." : nil
                                    },
                                    commit: { text in
                                      store.set("misc", base.appending("rules"), .array(rules + [.object(JObject([("prefix", .string(text)), ("entries", .object(JObject()))]))]))
                                      rule = rules.count
                                    }))
          },
        ] + (rules.isEmpty ? [] : [
          .item("Edit Prefix as JSON…") { store.editValue("misc", rulePath, title: "Prefix \(prefix)") },
          .delete("Delete Prefix \(prefix)") { store.deleteEntry("misc", rulePath); rule = 0 },
        ]))
      }
    } footer: {
      Text(rules.isEmpty ? "" : "Type \(prefix) and an abbreviation anywhere to insert its text. Abbreviations use printable characters without spaces.")
    }
  }

  /// Abbreviations must be printable and unique across all prefixes.
  private func snippetError(_ name: String, prefix: String, excluding: String?) -> String? {
    if name.range(of: #"^[!-~]+$"#, options: .regularExpression) == nil { return "Use printable characters without spaces." }
    let rules = store.value("misc", base.appending("rules"))?.array ?? []
    let triggers = rules.flatMap { rule in (rule["entries"]?.object?.keys ?? []).map { (rule["prefix"]?.string ?? "") + $0 } }
    return triggers.contains(prefix + name) && prefix + name != (excluding.map { prefix + $0 } ?? "") ? "\(prefix)\(name) is already used." : nil
  }
}

struct SnippetEntryRow: View {
  @Environment(Store.self) private var store
  let rulePath: Path, prefix: String, name: String, value: JSON?
  @State private var text = ""

  var body: some View {
    let path = rulePath.appending("entries").appending(name)
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      HStack(spacing: 0) {
        Text(prefix).foregroundStyle(.tertiary)
        PlainField(text: $text, prompt: "abbreviation", monospaced: true, alignment: .leading,
                   onFocusChange: { if !$0 { commit() } }, onSubmit: commit)
      }
      .font(.system(.body, design: .monospaced))
      .frame(width: 170, alignment: .leading)
      if value == .bool(false) {
        Text("Turned off").foregroundStyle(.tertiary)
        Spacer()
      } else {
        TextField("", text: store.stringBinding("misc", path), prompt: Text("Text"), axis: .vertical)
          .labelsHidden().lineLimit(1...4)
      }
    }
    .onAppear { text = name }
    .onChange(of: name) { text = name }
  }

  private func commit() {
    do { try store.renameKey("misc", rulePath.appending("entries"), from: name, to: text) }
    catch { store.setStatus(error.localizedDescription, error: true); text = name }
  }
}

// MARK: - Clipboard

struct ClipboardPage: View {
  @Environment(Store.self) private var store
  var body: some View {
    let filters = store.value("misc", [.k("pasteboardFilter")])?.array ?? []
    Section {
      Toggle(isOn: Binding(get: { filters.contains(.string("@claude-code")) }, set: { on in
        let rest = filters.filter { $0 != .string("@claude-code") }
        store.set("misc", [.k("pasteboardFilter")], .array(on ? [.string("@claude-code")] + rest : rest))
      })) { TitleLabel(title: "Clean up Claude Code output", helpText: "Removes the terminal's gutter and wrapping from copied output") }
      .toggleStyle(.switch)
      ScopedRows(scope: "pasteboardFilter", indices: filters.indices.filter { filters[$0] != .string("@claude-code") }) { index in
        HStack {
          PlainField(text: Binding(get: { store.value("misc", [.k("pasteboardFilter"), .i(index)])?.string ?? "" },
                                   set: { store.set("misc", [.k("pasteboardFilter"), .i(index)], .string($0)) }),
                     prompt: "Pattern", monospaced: true, alignment: .leading, multiline: true)
          RemoveButton(help: "Delete pattern") { store.deleteEntry("misc", [.k("pasteboardFilter"), .i(index)]) }
        }
        .hoverRow()
        .contextMenu {
          Button("Move Up") { store.move("misc", [.k("pasteboardFilter")], from: index, to: index - 1) }.disabled(index == 0)
          Button("Move Down") { store.move("misc", [.k("pasteboardFilter")], from: index, to: index + 1) }.disabled(index == filters.count - 1)
        }
      }
      ActionButtons(actions: [.add("Add Pattern") { _, _ in
        store.ask(PromptRequest(title: "Add Cleanup Pattern", message: "A Lua pattern for text to clean up. Its first capture becomes the clipboard text.",
                                label: "Pattern", placeholder: "(.*)\n\nSource: .*", monospaced: true, multiline: true,
                                commit: { store.set("misc", [.k("pasteboardFilter")], .array(filters + [.string($0)])) }))
      }])
    } header: {
      Text("Clipboard Cleanup")
    } footer: {
      Text("Copied text is checked against each pattern in order; the first match replaces it with its capture. Press Option-Return for a line break.")
    }
    let rules = store.value("misc", [.k("verificationFilter")])?.array ?? []
    Section {
      ScopedRows(scope: "verificationFilter", indices: Array(rules.indices)) { i in
        PanelRow(panel: .verification(i)) {
          VStack(alignment: .leading, spacing: 2) {
            Text(store.stringList("misc", [.k("verificationFilter"), .i(i), .k("filter")]).joined(separator: " + ")).lineLimit(1)
            Text(rules[i]["extract"]?.string ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
          }
        }
      }
      if rules.isEmpty { EmptyRow(text: "No rules") }
      ActionButtons(actions: [.add("Add Rule") { _, _ in
        store.set("misc", [.k("verificationFilter")], .array(rules + [.object(JObject([("filter", .array([])), ("extract", .string("%d%d%d%d+"))]))]))
        store.panel = .verification(rules.count)
      }])
    } header: {
      Text("Verification Codes")
    } footer: {
      Text("Codes in new messages are copied automatically. Without a matching rule, messages that mention a verification code use their first run of four or more digits.")
    }
  }
}

// MARK: - Shortcuts

struct ModifiersPage: View {
  @Environment(Store.self) private var store
  @State private var selection: String?

  var body: some View {
    let hyperName = store.hyperKeyName
    Section {
      FormRow {
        ShortcutButton(file: "keybindings", title: "Hyper key", keyPath: [.k("hyper"), .k(hyperName)])
      } label: { TitleLabel(title: "Hyper key ✧", helpText: "Hold it as an extra modifier; press it twice for double-tap shortcuts") }
    }
    let presets = (store.value("keybindings", [.k("hyper")])?.object?.keys ?? []).filter { $0 != hyperName }
    Section {
      ForEach(presets, id: \.self) { name in
        NamedMappingRow(file: "keybindings", path: [.k("hyper"), .k(name)], value: store.value("keybindings", [.k("hyper"), .k(name)]))
          .contextMenu { Button("Delete Preset", role: .destructive) { store.deleteEntry("keybindings", [.k("hyper"), .k(name)]) } }
      }
      ActionButtons(actions: [.add("Add Preset") { _, _ in
        store.ask(PromptRequest(title: "Add Modifier Preset", message: "Shortcuts can use a preset instead of their own modifiers.",
                                label: "Name", placeholder: "window",
                                validate: { name in
                                  if name.range(of: "[.{}]", options: .regularExpression) != nil { return "Names can't contain dots or braces." }
                                  return store.value("keybindings", [.k("hyper"), .k(name)]) != nil ? "This preset already exists." : nil
                                },
                                commit: { store.set("keybindings", [.k("hyper"), .k($0)], .array([])) }))
      }])
    } header: {
      Text("Modifier Presets")
    } footer: {
      Text("Apply a preset to a shortcut from the shortcut's context menu. Changing a preset changes every shortcut that uses it; renaming it updates them too.")
    }
    Section {
      StepperRow(title: "Move step", help: "Distance a window moves per step",
                 value: store.numberBinding("keybindings", [.k("parameters"), .k("windowMoveStep")], default: 20), range: 1...500, step: 5, unit: "px")
      StepperRow(title: "Resize step", help: "Change in size per step",
                 value: store.numberBinding("keybindings", [.k("parameters"), .k("windowResizeStep")], default: 100), range: 5...1000, step: 10, unit: "px")
      FormRow {
        let corner = store.numberBinding("keybindings", [.k("parameters"), .k("trackpadCornerSize")], default: 0.25)
        HStack(spacing: 10) {
          Slider(value: corner, in: 0.1...0.4, step: 0.05).frame(width: 200)
          Text("\(Int((corner.wrappedValue * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
      } label: { TitleLabel(title: "Trackpad corner size", helpText: "Share of the trackpad treated as a corner") }
    } header: { Text("Windows and Trackpad") }
    let remote = store.value("keybindings", [.k("remoteDesktopModifiers")])?.object ?? JObject()
    Section {
      ForEach(AppIdentity.shared.installedFirst(remote.keys) { $0 }, id: \.self) { app in
        SelectableRow(selected: selection == app, select: { selection = app }) {
          PanelRow(panel: .remoteDesktop(app), summary: remoteSummary(remote[app])) { AppLabel(id: app) }
        }
      }
      if remote.isEmpty { EmptyRow(text: "No remote desktop apps") }
      ListControls(add: { app in
        if remote[app] == nil {
          store.set("keybindings", [.k("remoteDesktopModifiers"), .k(app)],
                    .array([.object(JObject([("map", .object(JObject([("command", .string("control")), ("control", .string("command"))])))]))]))
        }
        store.panel = .remoteDesktop(app)
      }, remove: selection.map { app in { store.deleteEntry("keybindings", [.k("remoteDesktopModifiers"), .k(app)]); selection = nil } })
    } header: {
      Text("Remote Desktop Modifiers")
    } footer: {
      Text("Swaps modifier keys, such as ⌘ and ⌃, while you use these apps.")
    }
  }

  private func remoteSummary(_ value: JSON?) -> String {
    (value?.array ?? []).compactMap { rule -> String? in
      let pairs = (rule["map"]?.object?.entries ?? []).map { keyDisplay(.string($0.0)) + "→" + keyDisplay($0.1) }.joined(separator: " ")
      return rule["type"]?.string == "restore" ? pairs + " in other windows" : pairs
    }.joined(separator: " · ")
  }
}

struct GlobalActionsPage: View {
  @Environment(Store.self) private var store
  private static let groups: [(String, (String) -> Bool)] = [
    ("Hammerspoon", { ["reloadHammerspoon", "toggleHotkeys", "toggleConsole", "showHotkeys", "searchHotkeys", "showCurrentWindowInfo"].contains($0) }),
    ("Menu Bar", { ["searchMenuBar", "moveFocusToStatusMenus", "showHiddenStatusItems", "showProxyMenu"].contains($0) }),
    ("Window Switching", { $0.hasPrefix("switch") || $0 == "searchWindow" || $0 == "searchTab" }),
    ("Window Position", { $0 == "fill" || $0.hasPrefix("moveTowards") || ($0.hasPrefix("moveTo") && !$0.contains("Space") && !$0.contains("Screen")) }),
    ("Window Size", { $0.hasPrefix("zoomTo") || $0.hasSuffix("Expand") || $0.hasSuffix("Shrink") }),
    ("Spaces", { $0.contains("Space") }),
    ("Displays", { $0.contains("Screen") }),
    ("Stage Manager", { $0.hasPrefix("focusStageManager") }),
    ("Copy and Paste with PC", { $0.hasSuffix("PC") }),
  ]

  var body: some View {
    let base: Path = [.k("hotkeys"), .k("global")]
    let actions = store.value("keybindings", base)?.object ?? JObject()
    var remaining = actions.keys
    let grouped = GlobalActionsPage.groups.map { name, test in
      let ids = remaining.filter(test)
      remaining.removeAll { ids.contains($0) }
      return (name, ids)
    }.filter { !$0.1.isEmpty } + (remaining.isEmpty ? [] : [("Other", remaining)])
    ForEach(grouped, id: \.0) { name, ids in
      Section {
        ForEach(ids, id: \.self) { id in
          ShortcutRow(file: "keybindings", path: base.appending(id), value: actions[id] ?? .object(JObject()),
                      title: store.displayTitle("keybindings", base.appending(id), actions[id], id))
        }
      } header: { Text(name) }
    }
    Section {
      ActionButtons(actions: store.containerActions("keybindings", base, .object(actions), title: "Global shortcuts"))
    } footer: {
      Text("Click a shortcut and type a new one. Esc cancels; Delete clears.")
    }
  }
}

struct AppLauncherPage: View {
  @Environment(Store.self) private var store
  var body: some View {
    let base: Path = [.k("hotkeys"), .k("appkeys")]
    let entries = store.value("keybindings", base)?.array ?? []
    Section {
      ScopedRows(scope: "appkeys", indices: AppIdentity.shared.installedFirst(Array(entries.indices)) { i in
        let ids = entries[i]["bundleID"].map { $0.string.map { [$0] } ?? $0.array?.compactMap(\.string) ?? [] }
        return ids.flatMap { AppIdentity.shared.installedFirst($0) { $0 }.first }
      }) { i in
        ShortcutRow(file: "keybindings", path: base.appending(i), value: entries[i],
                    title: store.displayTitle("keybindings", base.appending(i), entries[i], String(i + 1)))
      }
      if entries.isEmpty { EmptyRow(text: "No app shortcuts") }
      ListControls(add: { app in
        store.set("keybindings", base, .array(entries + [.object(JObject([("mods", .array([])), ("key", .string("")), ("bundleID", .string(app))]))]))
        store.panel = .appLauncher(entries.count)
      }, addTitle: "Add App Shortcut", remove: nil)
    } footer: {
      Text("A shortcut opens its app, or hides it when it's already in front. Click an app to change what it opens.")
    }
  }
}

struct MenusPage: View {
  @Environment(Store.self) private var store
  private static let sharedGroups: [(String, (String) -> Bool)] = [
    ("Windows", { $0.hasPrefix("zoom") }),
    ("Tabs and Documents", { ["remapPreviousTab", "openRecent", "confirmDelete"].contains($0) }),
    ("Open and Save Panels", { $0.hasSuffix("SidebarItemOnOpenSavePanel") }),
    ("Settings Windows", { $0.hasSuffix("ToolbarItemOnSettingsWindow") }),
  ]

  var body: some View {
    MenuModeSection(mode: "index", title: "Open Menus by Number",
                    footer: "The modifiers plus 1–9 or 0 open the front app's menus, counting from the first menu after the app menu.")
    MenuModeSection(mode: "letter", title: "Open Menus by Letter",
                    footer: "The modifiers plus a letter open the menu whose title it marks, like F for File.")
    let base: Path = [.k("hotkeys"), .k("shared")]
    let actions = store.value("keybindings", base)?.object ?? JObject()
    var remaining = actions.keys
    let grouped = MenusPage.sharedGroups.map { name, test in
      let ids = remaining.filter(test)
      remaining.removeAll { ids.contains($0) }
      return (name, ids)
    }.filter { !$0.1.isEmpty } + (remaining.isEmpty ? [] : [("Other Shared Actions", remaining)])
    ForEach(grouped, id: \.0) { name, ids in
      Section {
        ForEach(ids, id: \.self) { id in
          ShortcutRow(file: "keybindings", path: base.appending(id), value: actions[id] ?? .object(JObject()),
                      title: store.displayTitle("keybindings", base.appending(id), actions[id], id))
        }
      } header: { Text(name) } footer: {
        if name == grouped.last?.0 { Text("Shared actions work in any app that has the matching menu item or control. An app's own shortcut for the same action takes precedence.") }
      }
    }
  }
}

struct MenuModeSection: View {
  @Environment(Store.self) private var store
  let mode: String, title: String, footer: String
  @State private var lastMods: JSON = .string("option")

  var body: some View {
    let path: Path = [.k("hotkeys"), .k("menubar"), .k(mode)]
    let mods = store.value("keybindings", path.appending("mods"))
    let enabled = !(mods == nil || mods == .bool(false) || mods == .string("") || mods == .array([]))
    Section {
      Toggle(isOn: Binding(get: { enabled }, set: { on in
        if on { store.set("keybindings", path.appending("mods"), lastMods) }
        else { if let mods { lastMods = mods }; store.set("keybindings", path.appending("mods"), .bool(false)) }
      })) { TitleLabel(title: title) }
      .toggleStyle(.switch)
      if enabled {
        FormRow {
          ShortcutButton(file: "keybindings", title: "Modifiers", modsPath: path.appending("mods"))
        } label: { Text("Modifiers") }
        if store.value("keybindings", path.appending("appMenu")) != nil {
          FormRow {
            ShortcutButton(file: "keybindings", title: "Open app menu", modsPath: path.appending("appMenu").appending("mods"),
                           keyPath: path.appending("appMenu").appending("key"))
          } label: { Text("Open app menu") }
        }
        Text("Excluded apps").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
        AppListEditor(file: "keybindings", path: path.appending("exclude"), empty: "Works in every app")
      }
    } footer: { Text(footer) }
  }
}

// MARK: - Apps

struct WindowBehaviorPage: View {
  @Environment(Store.self) private var store
  @State private var list = "hideWithoutWindow"
  @State private var selection: String?

  private struct Entry: Hashable { let index: Int, app: String, custom: Bool }

  var body: some View {
    let items = store.value("application", [.k(list)])?.array ?? []
    let entries = AppIdentity.shared.installedFirst(items.enumerated().flatMap { index, item -> [Entry] in
      if let id = item.string { return [Entry(index: index, app: id, custom: false)] }
      return (item.object?.keys ?? []).map { Entry(index: index, app: $0, custom: true) }
    }) { $0.app }
    let switcher = list == "windowSwitcherIgnore"
    Section {
      Picker("", selection: Binding(get: { list }, set: { list = $0; selection = nil })) {
        Text("Hide").tag("hideWithoutWindow")
        Text("Quit").tag("quitWithoutWindow")
        Text("Window Switcher").tag("windowSwitcherIgnore")
      }
      .pickerStyle(.segmented).labelsHidden()
    } footer: {
      Text(switcher ? "These apps are left out of the window switcher. Customized apps show only matching windows."
           : "When the last window of these apps closes, the app is \(list == "quitWithoutWindow" ? "quit" : "hidden"). Customized apps decide which windows count.")
    }
    Section {
      ForEach(entries, id: \.self) { entry in
        let key = "\(entry.index)/\(entry.app)"
        SelectableRow(selected: selection == key, select: { selection = key }) {
          HStack(spacing: 10) {
            AppLabel(id: entry.app)
            Spacer(minLength: 12)
            if entry.custom {
              Button { store.panel = .windowRule(list: list, index: entry.index, app: entry.app) } label: {
                HStack(spacing: 4) {
                  Text(switcher ? "Matching windows" : "Custom windows")
                  Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
            } else {
              Text(entry.app).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
            }
          }
        }
        .contextMenu {
          if entry.custom {
            Button(switcher ? "Hide All Windows" : "Count All Windows") { uncustomize(entry, items) }
          } else {
            Button(switcher ? "Show Matching Windows…" : "Choose Which Windows Count…") { customize(entry, items) }
          }
          Divider()
          Button("Remove", role: .destructive) { remove(entry) }
        }
      }
      if entries.isEmpty { EmptyRow(text: "No apps") }
      ListControls(add: { app in
        if !entries.contains(where: { $0.app == app }) { store.set("application", [.k(list)], .array(items + [.string(app)])) }
      }, remove: selection.flatMap { key in entries.first { "\($0.index)/\($0.app)" == key } }.map { entry in { remove(entry); selection = nil } })
    }
  }

  private func remove(_ entry: Entry) {
    if entry.custom { store.removeWindowRule(list, entry.index, entry.app) } else { store.deleteEntry("application", [.k(list), .i(entry.index)]) }
  }
  /// A customized app moves into the list's rule object; only the first object is read for the switcher.
  private func customize(_ entry: Entry, _ items: [JSON]) {
    var list = items
    list.remove(at: entry.index)
    let target = list.firstIndex { $0.isRecord } ?? list.count
    if target == list.count { list.append(.object(JObject())) }
    var object = list[target].object ?? JObject()
    object[entry.app] = .object(JObject())
    list[target] = .object(object)
    store.set("application", [.k(self.list)], .array(list))
    store.panel = .windowRule(list: self.list, index: target, app: entry.app)
  }
  private func uncustomize(_ entry: Entry, _ items: [JSON]) {
    store.removeWindowRule(list, entry.index, entry.app)
    let updated = store.value("application", [.k(list)])?.array ?? []
    store.set("application", [.k(list)], .array(updated + [.string(entry.app)]))
  }
}

struct LifecyclePage: View {
  @Environment(Store.self) private var store
  var body: some View {
    Section {
      AppListEditor(file: "application", path: [.k("forbidden")], empty: "No blocked apps")
    } header: {
      Text("Blocked Apps")
    } footer: {
      Text("\(Image(systemName: "exclamationmark.triangle.fill")) Blocked apps are force-quit and deleted (sudo rm -rf) when they launch or are installed.")
        .foregroundStyle(.red)
    }
    Section {
      AppListEditor(file: "application", path: [.k("terminateSilently")])
    } header: { Text("Apps That Quit Without Notice") } footer: {
      Text("Hammerspoon checks these apps by polling, so it notices when they quit.")
    }
    Section {
      AppListEditor(file: "application", path: [.k("suspendHotkeysInRemoteDesktop")])
    } header: { Text("Pause Shortcuts in Remote Desktop") } footer: {
      Text("While a remote session window of these apps is focused, Hammerspoon's shortcuts pass through to the remote computer.")
    }
    let menuBar: Path = [.k("menuBarItems")]
    Section {
      Text("Check continuously").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      AppListEditor(file: "application", path: menuBar.appending("changing"))
      Text("Check when the focused window changes").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
      AppListEditor(file: "application", path: menuBar.appending("focusedWindowChanged"), removeWhenEmpty: true)
      Text("Check when the window title changes").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
      AppListEditor(file: "application", path: menuBar.appending("titleChanged"), removeWhenEmpty: true)
      let unread = store.stringList("application", menuBar.appending("changeOnWindow"))
      if store.value("application", menuBar.appending("changeOnWindow")) != nil {
        HStack {
          Label(unread.isEmpty ? "“changeOnWindow” is not read by Hammerspoon." : "\(unread.count) apps are under “changeOnWindow”, which Hammerspoon doesn't read.",
                systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          Spacer()
          Button(unread.isEmpty ? "Remove" : "Move to Window Changes") {
            let current = store.stringList("application", menuBar.appending("focusedWindowChanged"))
            if !unread.isEmpty {
              store.set("application", menuBar.appending("focusedWindowChanged"), .array((current + unread.filter { !current.contains($0) }).map { .string($0) }))
            }
            store.deleteEntry("application", menuBar.appending("changeOnWindow"))
          }
          .controlSize(.small)
        }
      }
    } header: { Text("Menu Bar Updates") } footer: {
      Text("Menu shortcuts are refreshed for apps whose menu bar changes. Continuous checks run every 0.25 seconds while the app is in front.")
    }
  }
}

struct InputDevicesPage: View {
  @Environment(Store.self) private var store
  @State private var selection: String?
  @State private var device: Int?

  var body: some View {
    let sources = store.value("application", [.k("inputSource")])?.object ?? JObject()
    Section {
      ForEach(AppIdentity.shared.installedFirst(sources.keys) { $0 }, id: \.self) { app in
        let path: Path = [.k("inputSource"), .k(app)]
        let list = store.stringList("application", path)
        SelectableRow(selected: selection == app, select: { selection = app }) {
          HStack(spacing: 10) {
            AppLabel(id: app)
            Spacer(minLength: 12)
            if list.count > 1 {
              PanelRow(panel: .inputSources(app), summary: list.map(InputSources.name).joined(separator: ", then ")) { EmptyView() }
            } else {
              InputSourcePicker(selection: Binding(get: { list.first ?? "" }, set: { store.set("application", path, .string($0)) }))
            }
          }
        }
        .contextMenu {
          Button("Add a Fallback Source…") { store.panel = .inputSources(app) }
          Button("Remove", role: .destructive) { store.deleteEntry("application", path) }
        }
      }
      if sources.isEmpty { EmptyRow(text: "No apps") }
      ListControls(add: { app in
        if sources[app] == nil { store.set("application", [.k("inputSource"), .k(app)], .string(InputSources.all.first?.id ?? "com.apple.keylayout.ABC")) }
      }, remove: selection.map { app in { store.deleteEntry("application", [.k("inputSource"), .k(app)]); selection = nil } })
    } header: {
      Text("Input Sources")
    } footer: {
      Text("Switches the keyboard input source when an app becomes active.")
    }
    Section {
      AppListEditor(file: "application", path: [.k("defaultMusicAppForControlCenter")], ordered: true)
    } header: { Text("Default Music App") } footer: {
      Text("Opened when you press play in Control Center and nothing is playing. The first installed app is used.")
    }
    androidSections
  }

  @ViewBuilder private var androidSections: some View {
    let devices = store.value("application", [.k("androidDevices")])?.array ?? []
    let legacy = devices.contains { $0.isRecord }
    Section {
      AppListEditor(file: "application", path: [.k("manageAndroidDevices")], ordered: true, empty: "No phone manager")
    } header: { Text("Android Phone Manager") } footer: {
      Text("Opened in the background when a phone below is connected, and quit when it's unplugged.")
    }
    Section {
      if legacy {
        HStack {
          Label("Some phones are saved as {product, vendor} objects, but Hammerspoon only reads [product, vendor] lists, so connecting them does nothing.",
                systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          Spacer()
          Button("Convert") {
            store.set("application", [.k("androidDevices")], .array(devices.map { item in
              guard let object = item.object else { return item }
              return .array([object["product"] ?? .string(""), object["vendor"] ?? .string("")])
            }))
          }
          .controlSize(.small)
        }
      }
      HStack {
        Text("Product").frame(maxWidth: .infinity, alignment: .leading)
        Text("Vendor").frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      ScopedRows(scope: "androidDevices", indices: Array(devices.indices)) { i in
        SelectableRow(selected: device == i, select: { device = i }) {
          HStack {
            deviceField(i, devices[i], 0, "product")
            deviceField(i, devices[i], 1, "vendor")
          }
        }
      }
      if devices.isEmpty { EmptyRow(text: "No phones") }
      ListControls(add: { _ in store.set("application", [.k("androidDevices")], .array(devices + [.array([.string(""), .string("")])])) },
                   remove: device.map { i in { store.deleteEntry("application", [.k("androidDevices"), .i(i)]); device = nil } },
                   applications: false)
    } header: { Text("Android Phones") } footer: {
      Text("USB device names as reported by the system.")
    }
  }

  private func deviceField(_ index: Int, _ item: JSON, _ position: Int, _ key: String) -> some View {
    let path: Path = item.isRecord ? [.k("androidDevices"), .i(index), .k(key)] : [.k("androidDevices"), .i(index), .i(position)]
    return PlainField(text: store.stringBinding("application", path), prompt: key == "product" ? "Product" : "Vendor", alignment: .leading)
      .frame(maxWidth: .infinity)
  }
}

struct MountainDuckPage: View {
  @Environment(Store.self) private var store
  var body: some View {
    let path: Path = [.k("io.mountainduck"), .k("connections")]
    let rules = store.value("application", path)?.array ?? []
    Section {
      ScopedRows(scope: "connections", indices: Array(rules.indices)) { i in
        if let name = rules[i].string {
          HStack {
            Image(systemName: "link").foregroundStyle(.secondary)
            Text("Always connect")
            Spacer()
            PlainField(text: store.stringBinding("application", path.appending(i)), prompt: "Bookmark").frame(maxWidth: 260)
            RemoveButton(help: "Delete \(name)") { store.deleteEntry("application", path.appending(i)) }
          }
          .hoverRow()
        } else {
          let locations = store.stringList("application", path.appending(i).appending("locations"))
          let connect = locations.first.map { store.stringList("application", path.appending(i).appending($0)) } ?? []
          PanelRow(panel: .mountainDuck(i), summary: conditionSummary(rules[i]["condition"])) {
            Label(connect.isEmpty ? "Conditional" : connect.joined(separator: ", "), systemImage: "arrow.triangle.branch")
          }
        }
      }
      if rules.isEmpty { EmptyRow(text: "No automatic connections") }
      ActionButtons(actions: [
        .add("Always Connect") { _, _ in
          store.ask(PromptRequest(title: "Always Connect", message: "The bookmark is connected whenever Mountain Duck is running.",
                                  label: "Bookmark name", placeholder: "OneDrive",
                                  commit: { store.set("application", path, .array(rules + [.string($0)])) }))
        },
        .add("Connect by Condition") { _, _ in
          store.set("application", path, .array(rules + [.object(JObject([
            ("condition", .object(JObject())), ("locations", .array([.string("inlab"), .string("outoflab")])),
            ("inlab", .array([])), ("outoflab", .array([])),
          ]))]))
          store.panel = .mountainDuck(rules.count)
        },
      ])
    } header: { Text("Automatic Connections") } footer: {
      Text("Applied whenever Mountain Duck is running. Names are bookmark titles in Mountain Duck's menu.")
    }
  }
}

// MARK: - Network proxy

struct ProxyClientsPage: View {
  @Environment(Store.self) private var store
  let file: String
  var body: some View {
    let clients = store.value(file, [])?.object ?? JObject()
    Section {
      ForEach(clients.keys.filter { store.proxyApps[$0] != false } + clients.keys.filter { store.proxyApps[$0] == false }, id: \.self) { name in
        let client = clients[name]?.object ?? JObject()
        let modes = [client.has("pac") ? "PAC" : nil, client.has("global") || name == "v2rayN" ? "Global" : nil].compactMap { $0 }
        PanelRow(panel: .proxyClient(file: file, name: name),
                 summary: store.proxyApps[name] == false ? "Not installed" : client.has("condition") ? modes.joined(separator: " · ") + " · Conditional" : modes.joined(separator: " · ")) {
          HStack(spacing: 10) {
            if let app = proxyAppIDs[name] { AppIcon(id: app, size: 24) } else { IconTile(symbol: "network", tint: .blue, size: 24) }
            Text(name)
          }
          .opacity(store.proxyApps[name] == false ? 0.55 : 1)
        }
        .contextMenu { Button("Delete \(name)", role: .destructive) { store.deleteEntry(file, [.k(name)]) } }
      }
      if clients.isEmpty { EmptyRow(text: "No clients") }
      ActionButtons(actions: [.add("Add Client") { _, _ in
        store.ask(PromptRequest(title: "Add Proxy Client",
                                message: "Use a proxy app's name (V2RayX, V2rayU, v2rayN, Clash Verge Rev, MonoCloud) to control that app, or any other name for a plain system proxy.",
                                label: "Name", placeholder: "Office Proxy",
                                validate: { clients.has($0) ? "This client already exists." : nil },
                                commit: { name in
                                  store.set(file, [.k(name)], .object(JObject([("pac", .string(""))])))
                                  store.panel = .proxyClient(file: file, name: name)
                                }))
      }])
    } footer: {
      Text(file == "proxy-local" ? "Private clients replace shared clients with the same name and aren't synced."
           : "App clients switch the app's own mode; other clients set the system proxy directly.")
    }
  }
}

struct AutoSwitchingPage: View {
  @Environment(Store.self) private var store
  var body: some View {
    let path: Path = [.k("proxy")]
    let rules = store.value("misc", path)?.array ?? []
    let clients = (store.drafts["proxy"]?.object?.keys ?? []) + (store.drafts["proxy-local"]?.object?.keys ?? []).filter {
      store.drafts["proxy"]?.object?.has($0) != true
    }
    ScopedRows(scope: "rules", indices: Array(rules.indices)) { i in
      let rulePath = path.appending(i)
      let candidates = rules[i]["candidates"]?.array ?? []
      Section {
        conditionRow(rulePath, rules[i]["condition"], title: "Rule condition")
        ScopedRows(scope: "\(rulePath)", indices: Array(candidates.indices)) { j in
          CandidateRow(path: rulePath.appending("candidates").appending(j), index: j, count: candidates.count, clients: clients)
        }
        if candidates.isEmpty { EmptyRow(text: "No candidates") }
        ActionButtons(actions: [.add("Add Candidate") { _, _ in
          store.set("misc", rulePath.appending("candidates"),
                    .array(candidates + [.object(JObject([("name", .string(clients.first ?? "System")), ("mode", .string("pac"))]))]))
        }])
      } header: {
        HStack {
          Text(rules.count > 1 ? "Rule \(i + 1)" : "Switching Rule")
          Spacer()
          ActionsMenu(actions: [
            .item("Edit as JSON…") { store.editValue("misc", rulePath, title: "Switching rule") },
            .delete("Delete Rule") { store.deleteEntry("misc", rulePath) },
          ])
        }
      } footer: {
        Text("Candidates are tried from the top; the first whose client is available is turned on.")
      }
    }
    Section {
      if rules.isEmpty { EmptyRow(text: "No switching rules") }
      ActionButtons(actions: [.add("Add Rule") { _, _ in
        store.set("misc", path, .array(rules + [.object(JObject([("candidates", .array([]))]))]))
      }])
    } footer: {
      Text("Runs when the Mac connects to a network. Rules are checked in order; if none applies, the system proxy is turned off.")
    }
  }

  @ViewBuilder private func conditionRow(_ path: Path, _ condition: JSON?, title: String) -> some View {
    if condition != nil {
      PanelRow(panel: .condition(file: "misc", path: path.appending("condition"), title: title), summary: conditionSummary(condition)) {
        Label("When", systemImage: "line.3.horizontal.decrease.circle")
      }
    } else {
      HStack {
        Label("Always", systemImage: "line.3.horizontal.decrease.circle")
        Spacer()
        Button("Add Condition…") {
          store.set("misc", path.appending("condition"), .object(JObject()))
          store.panel = .condition(file: "misc", path: path.appending("condition"), title: title)
        }
        .controlSize(.small)
      }
    }
  }
}

struct CandidateRow: View {
  @Environment(Store.self) private var store
  let path: Path, index: Int, count: Int, clients: [String]
  var body: some View {
    let candidate = store.value("misc", path)?.object ?? JObject()
    let name = candidate["name"]?.string ?? ""
    HStack(spacing: 10) {
      Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 14)
      Picker("", selection: Binding(get: { name }, set: { store.set("misc", path.appending("name"), .string($0)) })) {
        ForEach(clients + (clients.contains(name) ? [] : [name]), id: \.self) { Text($0).tag($0) }
      }
      .labelsHidden().fixedSize()
      Spacer()
      Picker("", selection: Binding(get: { candidate["mode"]?.string ?? "pac" }, set: { store.set("misc", path.appending("mode"), .string($0)) })) {
        Text("PAC").tag("pac")
        Text("Global").tag("global")
      }
      .labelsHidden().pickerStyle(.segmented).fixedSize()
      Button {
        if candidate["condition"] == nil { store.set("misc", path.appending("condition"), .object(JObject())) }
        store.panel = .condition(file: "misc", path: path.appending("condition"), title: "\(name) condition")
      } label: {
        Image(systemName: candidate.has("condition") ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
      }
      .buttonStyle(.borderless)
      .help(candidate.has("condition") ? conditionSummary(candidate["condition"]) : "Add a condition")
      RemoveButton(help: "Delete candidate") { store.deleteEntry("misc", path) }
    }
    .hoverRow()
    .contextMenu {
      Button("Move Up") { store.move("misc", path.parent, from: index, to: index - 1) }.disabled(index == 0)
      Button("Move Down") { store.move("misc", path.parent, from: index, to: index + 1) }.disabled(index == count - 1)
    }
  }
}

// MARK: - File sync and localization

struct ResourcesPage: View {
  @Environment(Store.self) private var store
  @State private var selection: String?
  var body: some View {
    let resources = store.value("localization", [.k("resources")])?.object ?? JObject()
    Section {
      ForEach(AppIdentity.shared.installedFirst(resources.keys) { $0 }, id: \.self) { app in
        SelectableRow(selected: selection == app, select: { selection = app }) {
          PanelRow(panel: .resource(app), summary: resourceSummary(resources[app])) { AppLabel(id: app) }
        }
      }
      if resources.isEmpty { EmptyRow(text: "No apps") }
      ListControls(add: { app in
        if resources[app] == nil { store.set("localization", [.k("resources"), .k(app)], .string("")) }
        store.panel = .resource(app)
      }, remove: selection.map { app in { store.deleteEntry("localization", [.k("resources"), .k(app)]); selection = nil } })
    } footer: {
      Text("Where each app keeps its translations, used to match English menu and button names in the app's language.")
    }
  }

  private func resourceSummary(_ value: JSON?) -> String {
    (value?.array ?? (value.map { [$0] } ?? [])).map { item in
      if let s = item.string { return s }
      guard let (key, value) = item.object?.entries.first else { return "" }
      let kind = ["electron": "Electron", "java": "Java", "qt": "Qt", "rust_i18n": "Rust i18n"][key] ?? key
      return key == "rust_i18n" ? kind : "\(kind): \(scalarText(value))"
    }.joined(separator: ", ")
  }
}

/// Menu translations for one app: menu titles and strings are separate views of one page.
struct TranslationsPage: View {
  @Environment(Store.self) private var store
  let app: String
  @State private var direction = "reverse"
  @State private var selection: String?

  var body: some View {
    let path: Path = [.k(app)]
    let blocks = store.translationBlocks(store.value("localization", path))
    let block = blocks[direction == "forward" ? 1 : 0]
    Section {
      Picker("", selection: Binding(get: { direction }, set: { direction = $0; selection = nil })) {
        Text("Menu Titles").tag("reverse")
        Text("Strings").tag("forward")
      }
      .pickerStyle(.segmented).labelsHidden()
    } footer: {
      Text(direction == "reverse" ? "Translates the app's menu titles to English, so menu shortcuts find them. Also used for strings in reverse."
           : "English text and its translation in the app, for buttons and items the automatic lookup misses.")
    }
    Section {
      HStack {
        Text(direction == "reverse" ? "In the app" : "English").frame(maxWidth: .infinity, alignment: .leading)
        Text(direction == "reverse" ? "English" : "In the app").frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      ForEach(block.keys, id: \.self) { key in
        SelectableRow(selected: selection == key, select: { selection = key }) {
          HStack(alignment: .firstTextBaseline) {
            Text(key).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if let list = block[key]?.array {
              TokenField(tokens: Binding(get: { list.compactMap { $0.string } }, set: { write(block, key, .array($0.map { .string($0) })) }))
                .frame(maxWidth: .infinity)
            } else {
              PlainField(text: Binding(get: { block[key]?.string ?? "" }, set: { write(block, key, .string($0)) }), alignment: .leading)
                .frame(maxWidth: .infinity)
            }
          }
        }
      }
      if block.isEmpty { EmptyRow(text: "No translations") }
      ListControls(add: { _ in
        store.ask(PromptRequest(title: "Add Translation", label: direction == "reverse" ? "Title in the app" : "English text",
                                validate: { block.has($0) ? "This text already has a translation." : nil },
                                commit: { write(block, $0, .string("")) }))
      }, remove: selection.map { key in { var updated = block; updated[key] = nil; save(updated); selection = nil } },
         applications: false)
    }
  }

  private func write(_ block: JObject, _ key: String, _ value: JSON) { var updated = block; updated[key] = value; save(updated) }
  private func save(_ block: JObject) {
    do { try store.writeTranslationBlock("localization", [.k(app)], direction, block); store.mark() }
    catch { store.setStatus(error.localizedDescription, error: true) }
  }
}
