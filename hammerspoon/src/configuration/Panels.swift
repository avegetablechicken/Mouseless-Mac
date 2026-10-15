// Editor sheets opened from rows on the purpose-built pages.
import AppKit
import SwiftUI

enum Panel: Hashable, Identifiable {
  case verification(Int)
  case appLauncher(Int)
  case shortcut(file: String, path: Path, title: String)
  case remoteDesktop(String)
  case windowRule(list: String, index: Int, app: String)
  case mountainDuck(Int)
  case proxyClient(file: String, name: String)
  case condition(file: String, path: Path, title: String)
  case inputSources(String)
  case resource(String)
  case syncFile(String)
  case syncVariable(String)
  var id: Self { self }
}

let proxyAppIDs = ["V2RayX": "cenmrev.V2RayX", "V2rayU": "net.yanue.V2rayU", "v2rayN": "2dust.v2rayN",
                   "MonoCloud": "com.MonoCloud.MonoProxyMac", "Clash Verge Rev": "io.github.clash-verge-rev.clash-verge-rev"]
let windowListTitles = ["hideWithoutWindow": "Hide when the last window closes", "quitWithoutWindow": "Quit when the last window closes",
                        "windowSwitcherIgnore": "Hide from the window switcher"]

struct PanelSheet: View {
  @Environment(Store.self) private var store
  let panel: Panel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        if let app = appID {
          AppIcon(id: app, size: 36)
        } else if case .syncFile(let source) = panel {
          SyncFileIcon(path: source, size: 36)
        } else if case .syncVariable(let name) = panel {
          IconTile(symbol: "folder.fill", tint: store.variableTint(name), size: 36)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.title3.weight(.semibold)).lineLimit(1)
          if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
        }
        Spacer()
      }
      .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 6)
      Form { content }
        .formStyle(.grouped)
        .overlay(alignment: .bottom) { StatusPill() }
      Divider()
      HStack {
        if let delete = deleteAction {
          Button("Delete…", role: .destructive) {
            store.confirmAction("Delete \(title)?", "The entry is removed from your draft. Save to write the change.", action: "Delete") {
              store.panel = nil
              delete()
            }
          }
          .foregroundStyle(.red)
        }
        Spacer()
        Button("Done") { store.panel = nil }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
      }
      .padding(16)
    }
    .frame(width: 660, height: 600)
    .modifier(StoreModals(active: true))
  }

  @ViewBuilder private var content: some View {
    switch panel {
    case .verification(let i): VerificationPanel(index: i)
    case .appLauncher(let i): AppLauncherPanel(index: i)
    case .shortcut(let file, let path, let title): ShortcutPanel(file: file, path: path, title: title)
    case .remoteDesktop(let app): RemoteDesktopPanel(app: app)
    case .windowRule(let list, let index, let app): WindowRulePanel(list: list, index: index, app: app)
    case .mountainDuck(let i): MountainDuckPanel(index: i)
    case .proxyClient(let file, let name): ProxyClientPanel(file: file, name: name)
    case .condition(let file, let path, _):
      Section {
        ConditionEditor(file: file, path: path)
      } footer: {
        Text("Matches when any listed condition is true. Names and addresses are Lua patterns.")
      }
    case .inputSources(let app): InputSourcesPanel(app: app)
    case .resource(let app): ResourcePanel(app: app)
    case .syncFile(let source): SyncFilePanel(source: source)
    case .syncVariable(let name): SyncVariablePanel(name: name)
    }
  }

  private var title: String {
    switch panel {
    case .verification: return "Verification Code Rule"
    case .appLauncher(let i):
      let ids = store.stringList("keybindings", [.k("hotkeys"), .k("appkeys"), .i(i), .k("bundleID")])
      return ids.first.map { AppIdentity.shared.name($0) ?? $0 } ?? store.value("keybindings", [.k("hotkeys"), .k("appkeys"), .i(i), .k("name")])?.string ?? "App Shortcut"
    case .shortcut(_, _, let title): return title
    case .remoteDesktop(let app), .inputSources(let app), .resource(let app): return AppIdentity.shared.name(app) ?? app
    case .windowRule(_, _, let app): return AppIdentity.shared.name(app) ?? app
    case .mountainDuck: return "Connection Rule"
    case .proxyClient(_, let name): return name
    case .condition(_, _, let title): return title
    case .syncFile(let source):
      let trimmed = source.hasSuffix("/") ? String(source.dropLast()) : source
      return trimmed.split(separator: "/").last.map(String.init) ?? source
    case .syncVariable(let name): return name
    }
  }
  private var subtitle: String? {
    switch panel {
    case .appLauncher: return "App launcher"
    case .remoteDesktop: return "Remote desktop modifiers"
    case .windowRule(let list, _, _): return windowListTitles[list]
    case .inputSources: return "Input sources"
    case .resource: return "Localization resources"
    case .mountainDuck: return "Mountain Duck"
    case .proxyClient(let file, _): return file + ".json"
    case .syncFile: return "Synced file"
    case .syncVariable: return "Path variable"
    default: return nil
    }
  }
  private var appID: String? {
    switch panel {
    case .appLauncher(let i): return store.stringList("keybindings", [.k("hotkeys"), .k("appkeys"), .i(i), .k("bundleID")]).first
    case .remoteDesktop(let app), .inputSources(let app), .resource(let app), .windowRule(_, _, let app): return app
    case .mountainDuck: return "io.mountainduck"
    case .proxyClient(_, let name): return proxyAppIDs[name]
    default: return nil
    }
  }
  private var deleteAction: (() -> Void)? {
    switch panel {
    case .verification(let i): return { store.deleteEntry("misc", [.k("verificationFilter"), .i(i)]) }
    case .appLauncher(let i): return { store.deleteEntry("keybindings", [.k("hotkeys"), .k("appkeys"), .i(i)]) }
    case .shortcut(let file, let path, _): return { store.deleteEntry(file, path) }
    case .remoteDesktop(let app): return { store.deleteEntry("keybindings", [.k("remoteDesktopModifiers"), .k(app)]) }
    case .windowRule(let list, let index, let app): return { store.removeWindowRule(list, index, app) }
    case .mountainDuck(let i): return { store.deleteEntry("application", [.k("io.mountainduck"), .k("connections"), .i(i)]) }
    case .proxyClient(let file, let name): return { store.deleteEntry(file, [.k(name)]) }
    case .condition(let file, let path, _): return { store.deleteEntry(file, path) }
    case .inputSources(let app): return { store.deleteEntry("application", [.k("inputSource"), .k(app)]) }
    case .resource(let app): return { store.deleteEntry("localization", [.k("resources"), .k(app)]) }
    case .syncFile(let source): return { store.deleteEntry("sync", [.k("file"), .k(source)]) }
    case .syncVariable(let name):
      return store.pathVariableReferenced(name) ? nil : { store.deleteEntry("sync", [.k("variable"), .k(name)]) }
    }
  }
}

extension Store {
  /// Removes one app's custom window rule; an emptied rule object leaves the list.
  func removeWindowRule(_ list: String, _ index: Int, _ app: String) {
    let path: Path = [.k(list), .i(index)]
    deleteEntry("application", path.appending(app))
    if value("application", path)?.object?.isEmpty == true { deleteEntry("application", path) }
  }
}

// MARK: - Clipboard

struct VerificationPanel: View {
  @Environment(Store.self) private var store
  let index: Int
  var body: some View {
    let path: Path = [.k("verificationFilter"), .i(index)]
    Section {
      TokenRow(title: "Message contains", help: "Every text must appear (Lua patterns)",
               tokens: store.listBinding("misc", path.appending("filter"), removeWhenEmpty: false))
      FormRow {
        PlainField(text: store.stringBinding("misc", path.appending("extract")), prompt: "%d%d%d%d+", monospaced: true).frame(maxWidth: 300)
      } label: { TitleLabel(title: "Code pattern", helpText: "Lua pattern that captures the code") }
    } footer: {
      Text("When a new message matches, the code is copied to the clipboard and shown in a notification. The first matching rule wins.")
    }
  }
}

// MARK: - Shortcuts

struct AppLauncherPanel: View {
  @Environment(Store.self) private var store
  let index: Int

  enum Target: String, CaseIterable { case app = "App", path = "Path", vm = "Parallels VM" }

  var body: some View {
    let path: Path = [.k("hotkeys"), .k("appkeys"), .i(index)]
    let object = store.value("keybindings", path)?.object ?? JObject()
    let target: Target = object.has("bundleID") ? .app : object.has("vm") ? .vm : object.has("path") ? .path : .app
    Section {
      FormRow {
        ShortcutButton(file: "keybindings", title: "Shortcut", modsPath: path.appending("mods"), keyPath: path.appending("key"))
      } label: { Text("Shortcut") }
    } footer: {
      Text("Opens the app, or hides it when it is already in front.")
    }
    Section {
      Picker("Opens", selection: Binding(get: { target }, set: { switchTarget(path, to: $0) })) {
        ForEach(Target.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      switch target {
      case .app:
        AppListEditor(file: "keybindings", path: path.appending("bundleID"), ordered: true)
      case .path:
        PathListEditor(file: "keybindings", path: path.appending("path"))
      case .vm:
        FormRow {
          PlainField(text: store.stringBinding("keybindings", path.appending("name")), prompt: "Windows 11").frame(maxWidth: 300)
        } label: { TitleLabel(title: "Virtual machine", helpText: "Name of the Parallels VM's operating system") }
      }
    } footer: {
      switch target {
      case .app: Text("With several apps, the first one installed on this Mac is opened.")
      case .path: Text("With several paths, the first one that exists is opened.")
      case .vm: Text("Opens the VM's app from ~/Parallels/<name>*.pvm.")
      }
    }
  }

  private func switchTarget(_ path: Path, to target: Target) {
    for key in ["bundleID", "path", "vm", "name"] where store.value("keybindings", path.appending(key)) != nil {
      store.deleteEntry("keybindings", path.appending(key))
    }
    switch target {
    case .app: store.set("keybindings", path.appending("bundleID"), .array([]))
    case .path: store.set("keybindings", path.appending("path"), .array([]))
    case .vm:
      store.set("keybindings", path.appending("vm"), .string("com.parallels.desktop.console"))
      store.set("keybindings", path.appending("name"), .string(""))
    }
  }
}

struct PathListEditor: View {
  @Environment(Store.self) private var store
  let file: String, path: Path
  var directory = false
  @State private var selection: Int?

  var body: some View {
    let paths = store.stringList(file, path)
    ScopedRows(scope: "\(file)/\(path)", indices: Array(paths.indices)) { index in
      let item = paths[index]
      HStack(spacing: 8) {
        Image(systemName: directory ? "folder" : "doc").foregroundStyle(.tertiary)
        PlainField(text: Binding(get: { item }, set: { text in
          var list = store.stringList(file, path)
          if list.indices.contains(index) { list[index] = text; store.setStringList(file, path, list) }
        }), prompt: "Path", alignment: .leading)
      }
      .padding(.horizontal, 6).padding(.vertical, 1)
      .background(RoundedRectangle(cornerRadius: 6).fill(selection == index ? Color.accentColor.opacity(0.18) : .clear))
      .contentShape(Rectangle())
      .onTapGesture { selection = index }
    }
    if paths.isEmpty { EmptyRow(text: "No paths") }
    ListControls(add: { _ in
      store.browsePath(current: "", context: PathContext(requiredType: directory ? "directory" : nil), key: file + "/" + path.joined) { chosen, _ in
        store.setStringList(file, path, store.stringList(file, path) + [chosen])
      }
    }, remove: selection.map { index in {
      var list = store.stringList(file, path)
      if list.indices.contains(index) { list.remove(at: index); store.setStringList(file, path, list) }
      selection = nil
    } }, applications: false)
  }
}

struct ShortcutPanel: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, title: String

  private enum WindowScope: String, CaseIterable { case none = "Any Time", any = "Any Window", matching = "Matching Windows" }
  private enum MenuScope: String, CaseIterable { case off = "Off", any = "Any Menu", positions = "By Position", names = "By Name" }

  var body: some View {
    let object = store.value(file, path)?.object ?? JObject()
    let perApp = store.supportsShortcutOptions(file, path)
    let shared = path.at(1)?.key == "shared"
    Section {
      FormRow {
        ShortcutButton(file: file, title: title, modsPath: path.appending("mods"), keyPath: path.appending("key"))
      } label: { Text("Shortcut") }
    }
    if perApp {
      Section {
        Toggle(isOn: store.flagBinding(file, path.appending("background"))) {
          TitleLabel(title: "Works while the app is in the background", helpText: "For menu bar and background apps")
        }
        Toggle(isOn: store.flagBinding(file, path.appending("persist"))) {
          TitleLabel(title: "Works when the app isn't running", helpText: "Opens the app in the background, then runs the action")
        }
        Toggle(isOn: store.flagBinding(file, path.appending("repeatable"))) { TitleLabel(title: "Repeats while held") }
      } header: { Text("Availability") }
      .toggleStyle(.switch)
      windowSection(object)
      menuSection(object)
    }
    if shared {
      Section {
        AppListEditor(file: file, path: path.appending("excluded"), empty: "Available in every app", removeWhenEmpty: true)
      } header: { Text("Excluded Apps") } footer: { Text("The shortcut does nothing in these apps.") }
    }
    let known: Set<String> = ["mods", "key", "background", "persist", "repeatable", "windowFilter", "nonFrontmost", "menubarFilter", "excluded"]
    let others = object.keys.filter { !known.contains($0) }
    if !others.isEmpty {
      Section {
        ForEach(others, id: \.self) { key in
          NodeView(file: file, path: path.appending(key), value: object[key], key: key, depth: 1,
                   onRemove: { store.deleteEntry(file, path.appending(key)) })
        }
      } header: { Text("Other Settings") }
    }
  }

  @ViewBuilder private func windowSection(_ object: JObject) -> some View {
    let filter = object["windowFilter"]
    let scope: WindowScope = filter == nil ? .none : filter == .bool(true) ? .any : .matching
    Section {
      Picker("Active", selection: Binding(get: { scope }, set: { next in
        switch next {
        case .none: store.deleteEntry(file, path.appending("windowFilter"))
        case .any: store.set(file, path.appending("windowFilter"), .bool(true))
        case .matching: if filter?.isRecord != true { store.set(file, path.appending("windowFilter"), .object(JObject())) }
        }
      })) { ForEach(WindowScope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
      .pickerStyle(.segmented)
      if scope == .matching {
        WindowFilterFields(file: file, path: path.appending("windowFilter"), showsURLs: true)
      }
      if scope != .none && object["background"] == .bool(true) {
        Toggle(isOn: store.flagBinding(file, path.appending("nonFrontmost"))) {
          TitleLabel(title: "Also when another window is focused", helpText: "Unless a newer window, sheet, or popover is in front")
        }
        .toggleStyle(.switch)
      }
    } header: {
      Text("Windows")
    } footer: {
      Text(scope == .none ? "Works whenever the app is in front." : scope == .any ? "Works only while one of the app's windows is focused."
           : "Works only while a focused window matches. Titles and URLs are Lua patterns.")
    }
  }

  @ViewBuilder private func menuSection(_ object: JObject) -> some View {
    let filter = object["menubarFilter"]
    let scope: MenuScope = filter == nil ? .off : filter == .bool(true) ? .any : filter?["allowIndices"] != nil ? .positions : .names
    Section {
      Picker("Menu bar", selection: Binding(get: { scope }, set: { next in
        let target = path.appending("menubarFilter")
        switch next {
        case .off: store.deleteEntry(file, target)
        case .any: store.set(file, target, .bool(true))
        case .positions: store.set(file, target, .object(JObject([("allowIndices", .number(1))])))
        case .names: store.set(file, target, .object(JObject([("allowTitles", .array([]))])))
        }
      })) { ForEach(MenuScope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
      .pickerStyle(.segmented)
      if scope == .positions {
        TokenRow(title: "Positions", help: "Status items counted from the left, starting at 1", tokens: Binding(
          get: { (filter?["allowIndices"]?.array ?? filter?["allowIndices"].map { [$0] } ?? []).map { scalarText($0) } },
          set: { tokens in
            let numbers = tokens.compactMap { Double($0) }.map { JSON.number($0) }
            store.set(file, path.appending("menubarFilter").appending("allowIndices"), numbers.count == 1 ? numbers[0] : .array(numbers))
          }))
      }
      if scope == .names {
        TokenRow(title: "Status item names", help: "Autosave names of the app's status items",
                 tokens: store.listBinding(file, path.appending("menubarFilter").appending("allowTitles"), removeWhenEmpty: false))
      }
    } header: {
      Text("Status Menu")
    } footer: {
      Text(scope == .off ? "Not tied to the app's status menu." : "Works only while one of these status menus is open.")
    }
  }
}

struct RemoteDesktopPanel: View {
  @Environment(Store.self) private var store
  let app: String

  private enum Scope: String, CaseIterable { case remote = "Remote Sessions", local = "Other Windows", matching = "Matching Windows" }

  var body: some View {
    let base: Path = [.k("remoteDesktopModifiers"), .k(app)]
    let rules = store.value("keybindings", base)?.array ?? []
    ScopedRows(scope: "remote", indices: Array(rules.indices)) { i in
      let rulePath = base.appending(i)
      let rule = rules[i].object ?? JObject()
      let scope: Scope = rule["type"]?.string == "restore" ? .local : rule["condition"] != nil ? .matching : .remote
      Section {
        Picker("Applies to", selection: Binding(get: { scope }, set: { next in setScope(rulePath, rule, next) })) {
          ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        if scope == .matching {
          WindowFilterFields(file: "keybindings", path: rulePath.appending("condition").appending("windowFilter"))
        }
        let map = rule["map"]?.object ?? JObject()
        ForEach(map.keys, id: \.self) { key in
          ModifierMappingRow(file: "keybindings", path: rulePath.appending("map").appending(key), value: map[key],
                             onRemove: { store.deleteEntry("keybindings", rulePath.appending("map").appending(key)) })
        }
        if map.isEmpty { EmptyRow(text: "No modifier changes") }
        ActionButtons(actions: [.add("Add Mapping") { _, _ in
          let unused = ["command", "control", "option", "shift", "fn"].first { !map.has($0) } ?? "command"
          store.set("keybindings", rulePath.appending("map").appending(unused), .string(unused == "command" ? "control" : "command"))
        }])
      } header: {
        HStack {
          Text(rules.count > 1 ? "Rule \(i + 1)" : "Modifiers")
          Spacer()
          ActionsMenu(actions: [.delete("Delete Rule") { store.deleteEntry("keybindings", rulePath) }])
        }
      } footer: {
        switch scope {
        case .remote: Text("Swaps modifiers while a remote session window is focused.")
        case .local: Text("Swaps modifiers back in this app's other windows, for apps whose keys are remapped elsewhere.")
        case .matching: Text("Swaps modifiers while a matching window is focused.")
        }
      }
    }
    Section {
      ActionButtons(actions: [.add("Add Rule") { _, _ in
        store.set("keybindings", base, .array(rules + [.object(JObject([("map", .object(JObject([("command", .string("control"))])))]))]))
      }])
    } footer: {
      Text("Rules are checked in order; the first that applies is used. Only VNC Viewer and Microsoft Remote Desktop can tell remote sessions apart; in other apps every window counts as remote.")
    }
  }

  private func setScope(_ path: Path, _ rule: JObject, _ scope: Scope) {
    if rule.has("type") { store.deleteEntry("keybindings", path.appending("type")) }
    if scope != .matching && rule.has("condition") { store.deleteEntry("keybindings", path.appending("condition")) }
    switch scope {
    case .remote: break
    case .local: store.set("keybindings", path.appending("type"), .string("restore"))
    case .matching:
      if !rule.has("condition") {
        store.set("keybindings", path.appending("condition"), .object(JObject([("windowFilter", .object(JObject()))])))
      }
    }
  }
}

// MARK: - Apps

struct WindowRulePanel: View {
  @Environment(Store.self) private var store
  let list: String, index: Int, app: String

  var body: some View {
    let path: Path = [.k(list), .i(index), .k(app)]
    let switcher = list == "windowSwitcherIgnore"
    Section {
      WindowFilterFields(file: "application", path: path, showsSheets: !switcher)
      if !switcher {
        FormRow {
          HStack(spacing: 6) {
            NumberField(file: "application", path: path.appending("delay"), number: store.value("application", path.appending("delay"))?.number ?? 0)
            Text("s").foregroundStyle(.secondary)
          }
        } label: { TitleLabel(title: "Delay", helpText: "Wait before checking for remaining windows") }
      }
    } header: {
      Text(switcher ? "Windows Shown in the Switcher" : "Windows That Count")
    } footer: {
      Text(switcher ? "Only the app's windows matching these conditions appear in the window switcher."
           : "Only matching windows count as the app's windows. When the last one closes, the app is \(list == "quitWithoutWindow" ? "quit" : "hidden").")
    }
  }
}

struct MountainDuckPanel: View {
  @Environment(Store.self) private var store
  let index: Int

  var body: some View {
    let path: Path = [.k("io.mountainduck"), .k("connections"), .i(index)]
    let locations = store.stringList("application", path.appending("locations"))
    let met = locations.first ?? "inlab", unmet = locations.count > 1 ? locations[1] : "outoflab"
    Section {
      ConditionEditor(file: "application", path: path.appending("condition"),
                      exitCodeNote: "Exit 0: met · exit 1: not met · otherwise: no change")
    } header: { Text("Condition") }
    Section {
      TokenRow(title: "Connect", help: "Bookmark names in Mountain Duck's menu", tokens: store.listBinding("application", path.appending(met), removeWhenEmpty: false))
      TokenRow(title: "Disconnect", tokens: store.listBinding("application", path.appending(unmet), removeWhenEmpty: false))
    } header: {
      Text("When the Condition Is Met")
    } footer: {
      Text("When it isn't met, the first list disconnects and the second connects.")
    }
  }
}

struct InputSourcesPanel: View {
  @Environment(Store.self) private var store
  let app: String
  @State private var selection: Int?

  var body: some View {
    let path: Path = [.k("inputSource"), .k(app)]
    let sources = store.stringList("application", path)
    Section {
      ScopedRows(scope: "inputSource", indices: Array(sources.indices)) { index in
        let id = sources[index]
        HStack {
          Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 14)
          InputSourcePicker(selection: Binding(get: { id }, set: { next in
            var list = store.stringList("application", path); list[index] = next; store.setStringList("application", path, list)
          }))
          Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 6).fill(selection == index ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { selection = index }
      }
      ListControls(add: { _ in
        store.setStringList("application", path, sources + [InputSources.all.first?.id ?? "com.apple.keylayout.ABC"])
      }, remove: selection.map { i in { var list = sources; list.remove(at: i); store.setStringList("application", path, list); selection = nil } },
         moveUp: selection.flatMap { i in i > 0 ? { store.move("application", path, from: i, to: i - 1); selection = i - 1 } : nil },
         moveDown: selection.flatMap { i in i < sources.count - 1 ? { store.move("application", path, from: i, to: i + 1); selection = i + 1 } : nil },
         applications: false)
    } footer: {
      Text("When the app becomes active and the current input source isn't listed, the first available source is selected.")
    }
  }
}

// MARK: - Network proxy

struct ProxyClientPanel: View {
  @Environment(Store.self) private var store
  let file: String, name: String
  @State private var mode = "pac"
  @State private var location = 0

  var body: some View {
    let base: Path = [.k(name)]
    let client = store.value(file, base)?.object ?? JObject()
    let locations = client.has("condition") ? store.stringList(file, base.appending("locations")) : []
    let target = locations.isEmpty ? base : base.appending(locations[min(location, locations.count - 1)])
    let v2ray = name == "v2rayN"
    Section {
      if !locations.isEmpty {
        Picker("Location", selection: $location) {
          ForEach(Array(locations.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
        }
        .pickerStyle(.segmented)
      }
      Picker("Mode", selection: $mode) {
        Text("PAC").tag("pac")
        Text("Global").tag("global")
      }
      .pickerStyle(.segmented)
      if mode == "pac" {
        if v2ray {
          FormRow {
            PlainField(text: store.stringBinding(file, target.appending("pac").appending("routing")), prompt: "Required",
                       invalid: (store.value(file, target.appending("pac"))?["routing"]?.string ?? "").isEmpty).frame(maxWidth: 340)
          } label: { TitleLabel(title: "Routing profile", helpText: "v2rayN routing used for PAC mode") }
        } else {
          FormRow {
            HStack(spacing: 2) {
              PlainField(text: store.stringBinding(file, target.appending("pac"), removeWhenEmpty: true), prompt: "Not set")
              BrowseButton(current: store.value(file, target.appending("pac"))?.string ?? "", context: PathContext(fileURL: true),
                           key: file + "/" + target.joined + "/pac") { store.set(file, target.appending("pac"), .string($0)) }
            }
            .frame(maxWidth: 380)
          } label: { TitleLabel(title: "Configuration URL", helpText: "Automatic proxy configuration (PAC) file") }
        }
      } else {
        if v2ray {
          FormRow {
            PlainField(text: store.stringBinding(file, target.appending("global").appending("routing"), removeWhenEmpty: true), prompt: "Global").frame(maxWidth: 340)
          } label: { TitleLabel(title: "Routing profile") }
        }
        ForEach(["http", "https", "socks5"], id: \.self) { proto in
          FormRow {
            PlainField(text: store.stringBinding(file, target.appending("global").appending(proto), removeWhenEmpty: true), prompt: "Off")
              .frame(maxWidth: 260)
          } label: { Text(proto == "socks5" ? "SOCKS5" : proto.uppercased()) }
        }
      }
    } footer: {
      if mode == "pac" {
        Text(v2ray ? "v2rayN's PAC mode selects this routing profile and uses the Global addresses."
             : "Turns off the manual proxies and uses this configuration file.")
      } else {
        Text("Each address is host:port. Protocols without an address are turned off.")
      }
    }
    Section {
      if client.has("condition") {
        ConditionEditor(file: file, path: base.appending("condition"),
                        exitCodeNote: locations.isEmpty ? nil : "The exit code picks the location: 0 for the first, 1 for the second")
      } else {
        ActionButtons(actions: [.item("Offer Only Under Conditions…") { store.set(file, base.appending("condition"), .object(JObject())) }])
      }
    } header: {
      Text("Availability")
    } footer: {
      Text(client.has("condition") ? "The client is offered in the menu and for automatic switching only when a condition matches."
           : "Offered whenever its app is installed.")
    }
    .onAppear { if client["pac"] == nil && client["global"] != nil { mode = "global" } }
  }
}

// MARK: - Localization

struct ResourcePanel: View {
  @Environment(Store.self) private var store
  let app: String

  enum Kind: String, CaseIterable { case path = "Folder", electron = "Electron", java = "Java", qt = "Qt", rust = "Rust i18n" }

  var body: some View {
    let path: Path = [.k("resources"), .k(app)]
    let items = locations(store.value("localization", path))
    ScopedRows(scope: "resource", indices: Array(items.indices)) { index in
      let item = items[index]
      let kind = kind(item)
      Section {
        Picker("Type", selection: Binding(get: { kind }, set: { update(items, index, empty($0)) })) {
          ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        if kind != .rust {
          FormRow {
            PlainField(text: Binding(get: { text(item) }, set: { update(items, index, value(kind, $0)) }), prompt: placeholder(kind), monospaced: true)
              .frame(maxWidth: 360)
          } label: { TitleLabel(title: label(kind)) }
        }
      } header: {
        HStack {
          Text(items.count > 1 ? "Location \(index + 1)" : "Location")
          Spacer()
          ActionsMenu(actions: [.delete("Delete Location") { var list = items; list.remove(at: index); write(list) }])
        }
      }
    }
    Section {
      ActionButtons(actions: [.add("Add Location") { _, _ in write(items + [.string("")]) }])
    } footer: {
      Text("Folders are looked up as an absolute path, then inside the app's Resources and frameworks, then in system frameworks. All listed locations are used.")
    }
  }

  private func locations(_ value: JSON?) -> [JSON] { value?.array ?? (value.map { [$0] } ?? []) }
  private func write(_ items: [JSON]) {
    store.set("localization", [.k("resources"), .k(app)], items.count == 1 ? items[0] : .array(items))
  }
  private func update(_ items: [JSON], _ index: Int, _ item: JSON) { var list = items; list[index] = item; write(list) }
  private func kind(_ item: JSON) -> Kind {
    guard let object = item.object else { return .path }
    return object.has("electron") ? .electron : object.has("java") ? .java : object.has("qt") ? .qt : object.has("rust_i18n") ? .rust : .path
  }
  private func key(_ kind: Kind) -> String { ["Electron": "electron", "Java": "java", "Qt": "qt", "Rust i18n": "rust_i18n"][kind.rawValue] ?? "" }
  private func empty(_ kind: Kind) -> JSON {
    kind == .path ? .string("") : kind == .rust ? .object(JObject([("rust_i18n", .bool(true))])) : .object(JObject([(key(kind), .string(""))]))
  }
  private func value(_ kind: Kind, _ text: String) -> JSON { kind == .path ? .string(text) : .object(JObject([(key(kind), .string(text))])) }
  private func text(_ item: JSON) -> String { item.string ?? item.object?.entries.first.map { scalarText($0.1) } ?? "" }
  private func label(_ kind: Kind) -> String {
    switch kind {
    case .path: return "Folder or framework"
    case .electron: return "Locale folder in app.asar"
    case .java: return "Module path"
    case .qt: return "Translation file prefix"
    case .rust: return ""
    }
  }
  private func placeholder(_ kind: Kind) -> String {
    switch kind {
    case .path: return "Example.framework"
    case .electron: return "locales"
    case .java: return "org.example/l10n"
    case .qt: return "app"
    case .rust: return ""
    }
  }
}
