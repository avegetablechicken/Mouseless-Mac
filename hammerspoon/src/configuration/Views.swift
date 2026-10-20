// Window layout: a System Settings style sidebar, grouped forms, and native sheets.
import AppKit
import SwiftUI

struct ConfigurationView: View {
  @Environment(Store.self) private var store

  var body: some View {
    @Bindable var store = store
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 320)
    } detail: {
      DetailView()
    }
    .modifier(StoreModals(active: store.sheet == nil && store.panel == nil))
    .sheet(item: $store.sheet, onDismiss: { store.sheetPath = [] }) { DetailSheet(root: $0) }
    .background {
      Color.clear.sheet(item: Binding(get: { store.sheet == nil ? store.panel : nil }, set: { store.panel = $0 })) { PanelSheet(panel: $0) }
    }
  }
}

// MARK: - Sidebar

struct SidebarView: View {
  @Environment(Store.self) private var store

  var body: some View {
    @Bindable var store = store
    List(selection: $store.selection) {
      Section {
        BrandHeader()
          .selectionDisabled()
      }
      ForEach(groups.indices, id: \.self) { g in
        Section(groups[g].name) {
          // Unique row identities; bare indices collide with the section indices and leave sections empty.
          ForEach(groups[g].tabs.indices.map { TabID(group: g, tab: $0) }, id: \.self) { id in
            let tab = groups[g].tabs[id.tab]
            HStack(spacing: 9) {
              IconTile(symbol: tab.symbol, tint: tab.tint, size: 22)
              Text(tab.title).lineLimit(1)
              Spacer(minLength: 4)
              if store.changed(tab.file) {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).help("\(tab.file).json has unsaved changes")
              }
            }
            .padding(.vertical, 1)
            .tag(id)
          }
        }
      }
    }
    .listStyle(.sidebar)
  }
}

struct BrandHeader: View {
  private static let icon: NSImage? = {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.hammerspoon.Hammerspoon").map { NSWorkspace.shared.icon(forFile: $0.path) }
  }()
  var body: some View {
    HStack(spacing: 10) {
      if let icon = BrandHeader.icon {
        Image(nsImage: icon).resizable().frame(width: 34, height: 34)
      } else {
        IconTile(symbol: "hammer.fill", tint: .orange, size: 32)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text("Hammerspoon").font(.headline)
        Text("Make your Mac your own").font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 6)
  }
}

// MARK: - Detail

struct DetailView: View {
  @Environment(Store.self) private var store

  var body: some View {
    @Bindable var store = store
    let tab = store.tab
    NavigationStack(path: $store.route) {
      Form {
        HeroHeader()
        if store.drafts[tab.file] == nil {
          Section {
            VStack(spacing: 10) {
              Image(systemName: store.loaded ? "exclamationmark.triangle.fill" : "hourglass")
                .font(.system(size: 28)).foregroundStyle(store.loaded ? .orange : .secondary)
              Text(store.loaded ? "Configuration unavailable" : "Loading configuration…").font(.headline)
              if let error = store.files[tab.file]?.error { Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center) }
              if store.loaded { Button("Refresh Files") { store.readAgain() } }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 18)
          }
        } else {
          TabContent(sections: store.sections(tab))
        }
      }
      .formStyle(.grouped)
      .id(store.tabID)
      .navigationTitle(tab.title)
      .navigationSubtitle(tab.file + ".json" + (store.changed(tab.file) ? " — Edited" : ""))
      .toolbar { DetailToolbar() }
      .navigationDestination(for: NodeRoute.self) { NodePage(route: $0) }
    }
    .onChange(of: store.tabID) { store.route = []; store.closeSheet(); store.panel = nil }
    .overlay(alignment: .bottom) { StatusPill() }
  }
}

/// Tabs keyed by application list their apps; each app opens its own page.
struct TabContent: View {
  @Environment(Store.self) private var store
  let sections: [SectionSpec]

  private var appList: Bool {
    let tab = store.tab
    return tab.keys.contains("@apps") || (tab.keys.contains("@other") && ["localization", "application"].contains(tab.file))
  }

  var body: some View {
    switch (store.tabID.group, store.tabID.tab) {
    case (0, 0): GeneralPage()
    case (0, 1): ClipboardPage()
    case (1, 0): ModifiersPage()
    case (1, 1): GlobalActionsPage()
    case (1, 2): AppLauncherPage()
    case (1, 3): MenusPage()
    case (2, 0): WindowBehaviorPage()
    case (2, 1): LifecyclePage()
    case (2, 2): InputDevicesPage()
    case (3, 0): ProxyClientsPage(file: "proxy")
    case (3, 1): AutoSwitchingPage()
    case (3, 2): ProxyClientsPage(file: "proxy-local")
    case (4, 0): FileMappingsPage()
    case (4, 1): PathVariablesPage()
    case (5, 0): ResourcesPage()
    default: generic
    }
  }

  @ViewBuilder private var generic: some View {
    if appList {
      let browsers = sections.filter { $0.path.last?.key == "browsers" }
      ForEach(browsers) { spec in
        Section { AppRouteRow(spec: spec) } footer: { Text("Shared by Safari, Chrome, Edge, and Edge Dev.") }
      }
      Section {
        ForEach(AppIdentity.shared.installedFirst(sections.filter { $0.path.last?.key != "browsers" }) { $0.path.last?.key.flatMap { AppIdentity.shared.isApplication($0) ? $0 : nil } }) { AppRouteRow(spec: $0) }
        if sections.isEmpty { EmptyRow(text: "No apps configured") }
      } header: {
        Text("Apps")
      }
    } else {
      ForEach(sections) { SectionView(spec: $0) }
      if sections.isEmpty {
        Section {
          VStack(spacing: 6) {
            Text("No configuration yet").font(.headline)
            Text("Use Add Entry or Edit File JSON in the toolbar to add configuration.").foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity).padding(.vertical, 16)
        }
      }
    }
  }
}

struct AppRouteRow: View {
  @Environment(Store.self) private var store
  let spec: SectionSpec

  var body: some View {
    let key = spec.path.last?.description ?? ""
    let title = key == "browsers" ? "Browsers" : store.displayTitle(spec.file, spec.path, spec.value, key)
    let count = spec.value?.childCount ?? 0
    let noun = spec.file == "keybindings" ? (count == 1 ? "shortcut" : "shortcuts") : (count == 1 ? "setting" : "settings")
    DrillRow(route: NodeRoute(file: spec.file, path: spec.path, title: title), summary: "\(count) \(noun)",
             actions: key == "browsers" ? [] : [.delete("Delete \(title)") { store.deleteEntry(spec.file, spec.path) }]) {
      HStack(spacing: 10) {
        if key == "browsers" { IconTile(symbol: "safari.fill", tint: .blue, size: 24) } else { AppIcon(id: key, size: 24) }
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
          if AppIdentity.shared.isApplication(key) && title != key { Text(key).font(.caption).foregroundStyle(.secondary) }
        }
      }
    }
  }
}

/// A pushed page for one nested entry.
/// Editors and confirmations, presented by whichever layer is frontmost.
struct StoreModals: ViewModifier {
  @Environment(Store.self) private var store
  let active: Bool
  func body(content: Content) -> some View {
    content
      .alert(store.confirm?.title ?? "", isPresented: Binding(get: { active && store.confirm != nil }, set: { if !$0 { store.confirm = nil } }),
             presenting: store.confirm) { request in
        Button(request.actionTitle, role: .destructive) { request.action() }
        Button("Cancel", role: .cancel) {}
      } message: { request in
        Text(request.message)
      }
      .sheet(item: Binding(get: { active ? store.jsonEditor : nil }, set: { store.jsonEditor = $0 })) { JSONEditorSheet(request: $0) }
      .background {
        Color.clear.sheet(item: Binding(get: { active ? store.property : nil }, set: { store.property = $0 })) { PropertySheet(request: $0) }
          .background {
            Color.clear.sheet(item: Binding(get: { active ? store.prompt : nil }, set: { store.prompt = $0 })) { PromptSheet(request: $0) }
          }
      }
  }
}

/// A page pushed from a tab; details opened from it appear in a sheet.
struct NodePage: View {
  @Environment(Store.self) private var store
  let route: NodeRoute

  var body: some View {
    NodeForm(route: route)
      .environment(\.navigationContext, .page)
      .navigationTitle(route.title)
      .navigationSubtitle(route.file + ".json" + (store.changed(route.file) ? " — Edited" : ""))
      .navigationBarBackButtonHidden(true)
      .toolbar {
        ToolbarItem(placement: .navigation) {
          Button { if !store.route.isEmpty { store.route.removeLast() } } label: { Label("Back", systemImage: "chevron.backward") }
            .keyboardShortcut("[", modifiers: .command)
            .help("Back (⌘[)")
        }
        DetailToolbar()
      }
  }
}

/// Details in a sheet, as System Settings does; deeper levels push inside the sheet.
struct DetailSheet: View {
  @Environment(Store.self) private var store
  let root: NodeRoute

  var body: some View {
    let current = store.sheetPath.last ?? root
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        if !store.sheetPath.isEmpty {
          Button { store.sheetPath.removeLast() } label: { Image(systemName: "chevron.backward") }
            .buttonStyle(.borderless)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back (⌘[)")
        }
        Text(current.title).font(.headline).lineLimit(1)
        Spacer()
      }
      .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
      NodeForm(route: current)
        .id(current)
        .environment(\.navigationContext, .sheet)
        .overlay(alignment: .bottom) { StatusPill() }
      Divider()
      HStack {
        Spacer()
        Button("Done") { store.closeSheet() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
      .padding(16)
    }
    .frame(minWidth: 620, idealWidth: 700, minHeight: 440, idealHeight: 600)
    .modifier(StoreModals(active: store.panel == nil))
    .background {
      Color.clear.sheet(item: Binding(get: { store.panel }, set: { store.panel = $0 })) { PanelSheet(panel: $0) }
    }
  }
}

struct NodeForm: View {
  @Environment(Store.self) private var store
  let route: NodeRoute

  var body: some View {
    let file = route.file, path = route.path
    let value = store.value(file, path)
    let key = path.last?.description ?? ""
    Form {
      if let value {
        if AppIdentity.shared.isApplication(key) {
          Section {
            HStack(spacing: 12) {
              AppIcon(id: key, size: 40)
              VStack(alignment: .leading, spacing: 2) {
                Text(route.title).font(.title3.weight(.semibold))
                Text(key).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
              }
            }
            .padding(.vertical, 4)
          }
        }
        content(file, path, value, key)
        if store.isRemovable(file, path) {
          Section {
            let name = route.title.components(separatedBy: " · ").last ?? route.title
            HStack {
              Spacer()
              Button("Delete \(name)…", role: .destructive) {
                store.confirmAction("Delete \(name)?", "The entry is removed from your draft. Save to write the change.", action: "Delete") {
                  store.deleteEntry(file, path)
                }
              }
              .foregroundStyle(.red)
            }
          }
        }
      } else {
        Section { EmptyRow(text: "This entry is no longer available.") }
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder private func content(_ file: String, _ path: Path, _ value: JSON, _ key: String) -> some View {
    if store.isShortcutValue(file, path, value), let object = value.object {
      ShortcutPage(file: file, path: path, object: object, title: route.title)
    } else if path.at(-2)?.key == "candidates", let object = value.object {
      CandidatePage(file: file, path: path, object: object)
    } else if path.last?.key == "condition" {
      ProxyConditionView(file: file, path: path, value: value, asSection: true)
    } else if file == "localization" && path.count == 1 {
      TranslationsPage(app: key)
    } else if file == "application" && path == [.k("io.mountainduck")] {
      MountainDuckPage()
    } else if let items = value.array, store.isRecordList(file, path, value) {
      RecordSections(file: file, path: path, items: items, title: route.title)
    } else if value.isRecord && !store.isWindowBehaviorMapping(file, path, value) {
      ObjectPage(file: file, path: path, value: value, title: route.title)
    } else {
      Section { NodeView(file: file, path: path, value: value, key: key) }
    }
  }
}

/// Plain values share one group; nested lists and objects each get a titled section.
/// One section of a flattened page. Pages are built as a flat list so the form never
/// receives sections nested inside other sections' builders.
struct SectionModel: Identifiable {
  struct Row: Identifiable {
    let path: Path, value: JSON?, key: String
    var depth = 1
    var onRemove: (() -> Void)? = nil
    var removeHelp = "Delete"
    /// A subheading inside a section instead of a value row.
    var caption: String? = nil
    var id: String { path.joined + (caption == nil ? "" : "#caption") }
  }
  let id: String
  var header: String? = nil
  var menu: [NodeAction] = []
  var rows: [Row] = []
  var empty: String? = nil
  var actions: [NodeAction] = []
}

struct FlatSections: View {
  let file: String
  let sections: [SectionModel]

  var body: some View {
    ForEach(sections) { section in
      Section {
        ForEach(section.rows) { row in
          if let caption = row.caption {
            Text(caption).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
          } else {
            NodeView(file: file, path: row.path, value: row.value, key: row.key, depth: row.depth,
                     onRemove: row.onRemove, removeHelp: row.removeHelp)
          }
        }
        if let empty = section.empty { EmptyRow(text: empty) }
        if !section.actions.isEmpty { ActionButtons(actions: section.actions) }
      } header: {
        if section.header != nil || !section.menu.isEmpty {
          HStack {
            Text(section.header ?? "")
            Spacer()
            ActionsMenu(actions: section.menu)
          }
        }
      }
    }
  }
}

/// Plain values share one section; nested lists and objects each get titled sections.
struct ObjectPage: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, value: JSON, title: String
  var excluded: Set<String> = []
  var extra: [String] = []
  var showsActions = true
  /// Title for the first section when the object is embedded in a tab.
  var header: String? = nil

  var body: some View {
    FlatSections(file: file, sections: store.objectSections(file, path, value, title: title, header: header,
                                                            excluded: excluded, extra: extra, showsActions: showsActions))
  }
}

/// Each object in a list as its own section, so its fields are edited in place.
struct RecordSections: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, items: [JSON], title: String

  var body: some View {
    FlatSections(file: file, sections: store.recordSections(file, path, items, title: title))
  }
}

extension Store {
  /// Lists containing objects, edited as one section per object.
  func isRecordList(_ file: String, _ path: Path, _ value: JSON?) -> Bool {
    guard let items = value?.array, items.contains(where: { $0.isRecord }),
          items.allSatisfy({ $0.isRecord || !$0.isContainer }) else { return false }
    if file == "misc" && path.count == 1 && ["proxy", "verificationFilter"].contains(path[0].key ?? "") { return false }
    if path.last?.key == "candidates" { return false }
    return items.indices.allSatisfy {
      !isShortcutValue(file, path.appending($0), items[$0]) && !isWindowBehaviorMapping(file, path.appending($0), items[$0])
    }
  }
  /// Children that get a section of their own instead of a row.
  func ownsSection(_ file: String, _ childPath: Path, _ child: JSON?) -> Bool {
    guard let child, child.isContainer else { return false }
    if childPath.count == 2 && (file == "sync" || (file == "keybindings" && childPath.first?.key == "hyper")) { return false }
    return !isShortcutValue(file, childPath, child) && keyFieldKind(file, childPath) == nil && !isCompactList(child)
      && !(file == "localization" && childPath.count == 1)
  }
  /// Tab sections whose nested lists and objects are laid out as sections on the tab itself.
  func flattensSection(_ file: String, _ path: Path, _ value: JSON?) -> Bool {
    if ["sync", "localization"].contains(file) || proxyFiles.contains(file) { return false }
    if file == "keybindings" && ["hyper", "hotkeys"].contains(path.first?.key ?? "") { return false }
    if file == "misc" && ["proxy", "verificationFilter"].contains(path.first?.key ?? "") { return false }
    if isRecordList(file, path, value) { return true }
    guard let object = value?.object else { return false }
    return object.keys.contains { ownsSection(file, path.appending($0), object[$0]) }
  }

  func objectSections(_ file: String, _ path: Path, _ value: JSON, title: String, header: String? = nil,
                      excluded: Set<String> = [], extra: [String] = [], showsActions: Bool = true) -> [SectionModel] {
    let keys = (displayKeys(file, path, value) + extra.map { PK.k($0) }).filter { !excluded.contains($0.description) }
    let inline = keys.filter { !ownsSection(file, path + [$0], value[$0]) }
    let nested = keys.filter { ownsSection(file, path + [$0], value[$0]) }
    let removable = { (k: PK) in self.supportsShortcutOptions(file, path) || self.isRemovable(file, path + [k]) }
    let actions = containerActions(file, path, value, title: title)
    var result: [SectionModel] = []
    if !inline.isEmpty || nested.isEmpty || header != nil {
      result.append(SectionModel(
        id: file + "/" + path.joined + "#values", header: header,
        rows: inline.map { k in
          SectionModel.Row(path: path + [k], value: value[k], key: k.description,
                           onRemove: removable(k) ? { [unowned self] in deleteEntry(file, path + [k]) } : nil, removeHelp: "Delete " + k.description)
        },
        empty: inline.isEmpty && nested.isEmpty ? "No settings" : nil,
        actions: showsActions && (!inline.isEmpty || nested.isEmpty) ? actions : []))
    }
    for k in nested {
      let childPath = path + [k]
      let childTitle = displayTitle(file, childPath, value[k], k.description)
      if let items = value[k]?.array, isRecordList(file, childPath, value[k]) {
        result += recordSections(file, childPath, items, title: childTitle)
      } else {
        result.append(SectionModel(
          id: file + "/" + childPath.joined, header: childTitle,
          menu: removable(k) ? [.delete("Delete \(childTitle)") { [unowned self] in deleteEntry(file, childPath) }] : [],
          rows: [SectionModel.Row(path: childPath, value: value[k], key: k.description, depth: 0)]))
      }
    }
    // With no plain values, the object's own actions follow its sections.
    if showsActions && inline.isEmpty && !nested.isEmpty {
      result.append(SectionModel(id: file + "/" + path.joined + "#actions", actions: actions.map { action in
        if case .item(let label, let run) = action, label == "Edit as JSON…" { return .item("Edit \(title) as JSON…", run) }
        if case .add(_, let application, let proxy, let run) = action { return .add("Add Setting", application: application, proxy: proxy, run: run) }
        return action
      }))
    }
    return result
  }

  func recordSections(_ file: String, _ path: Path, _ items: [JSON], title: String) -> [SectionModel] {
    var result: [SectionModel] = []
    // A list that belongs to an app keeps the app's name for its only item; otherwise items are numbered.
    let named = items.count == 1 && AppIdentity.shared.isApplication(path.last?.key ?? "")
    for (i, item) in items.enumerated() {
      let itemPath = path.appending(i)
      let header = named ? title : "\(singular(title)) \(i + 1)"
      guard let record = item.object else {
        result.append(SectionModel(id: file + "/" + itemPath.joined, header: header,
          menu: [.delete("Delete \(header)") { [unowned self] in deleteEntry(file, itemPath) }],
          rows: [SectionModel.Row(path: itemPath, value: item, key: String(i + 1))]))
        continue
      }
      let value = JSON.object(record)
      let keys = displayKeys(file, itemPath, value)
      let inline = keys.filter { !ownsSection(file, itemPath + [$0], value[$0]) }
      let nested = keys.filter { ownsSection(file, itemPath + [$0], value[$0]) }
      var rows = inline.map { SectionModel.Row(path: itemPath + [$0], value: value[$0], key: $0.description) }
      for k in nested {
        rows.append(SectionModel.Row(path: itemPath + [k], value: nil, key: k.description,
                                     caption: displayTitle(file, itemPath + [k], value[k], k.description)))
        rows.append(SectionModel.Row(path: itemPath + [k], value: value[k], key: k.description, depth: 0))
      }
      result.append(SectionModel(
        id: file + "/" + itemPath.joined, header: header,
        menu: objectAddActions(file, itemPath, value, title: header) + [
          .item("Edit as JSON…") { [unowned self] in editValue(file, itemPath, title: header) },
          .delete("Delete \(header)") { [unowned self] in deleteEntry(file, itemPath) },
        ],
        rows: rows, empty: rows.isEmpty ? "No settings" : nil))
    }
    result.append(SectionModel(id: file + "/" + path.joined + "#list", actions: [
      .item("Edit All as JSON…") { [unowned self] in editValue(file, path, title: title) },
      .add("Add " + singular(title), application: isApplicationList(file, path)) { [unowned self] id, _ in openArrayEntry(file, path, applicationID: id) },
    ]))
    return result
  }

  /// "Snippets · Rules" → "Rule": the name of one item in a list.
  private func singular(_ title: String) -> String {
    let last = title.components(separatedBy: " · ").last ?? title
    if last.hasSuffix("ies") { return String(last.dropLast(3)) + "y" }
    if last.hasSuffix("s") && !last.hasSuffix("ss") { return String(last.dropLast()) }
    return last
  }


}

/// A shortcut's details: its key combination, then any other settings.
struct ShortcutPage: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, object: JObject, title: String

  private var appLauncher: Bool { path.at(1)?.key == "appkeys" && path.count == 3 }

  var body: some View {
    Section {
      FormRow {
        ShortcutButton(file: file, title: title, modsPath: path.appending("mods"), keyPath: path.appending("key"))
      } label: { Text("Shortcut") }
      ActionButtons(actions: [.item("Edit as JSON…") { store.editValue(file, path, title: title) }]
        + (store.supportsShortcutOptions(file, path) ? [.add("Add Property") { _, _ in store.openPropertyEditor(file, path, title: title) }] : []))
    } footer: {
      if store.supportsShortcutOptions(file, path) {
        Text("Properties such as persist, repeatable, or window filters change when the shortcut is active.")
      }
    }
    ObjectPage(file: file, path: path, value: .object(object), title: title, excluded: ["mods", "key"],
               extra: appLauncher && !object.has("bundleID") ? ["bundleID"] : [], showsActions: false)
  }
}

struct HeroHeader: View {
  @Environment(Store.self) private var store
  var body: some View {
    let tab = store.tab
    Section {
      VStack(spacing: 8) {
        IconTile(symbol: tab.symbol, tint: tab.tint, size: 58)
          .padding(.bottom, 2)
        Text(tab.title).font(.title2.weight(.semibold))
        Text(store.group.description).foregroundStyle(.secondary).multilineTextAlignment(.center)
        HStack(spacing: 6) {
          Label(tab.file + ".json", systemImage: "doc.text")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          if store.changed(tab.file) {
            Text("Modified")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 7).padding(.vertical, 2)
              .background(Capsule().fill(Color.accentColor.opacity(0.15)))
              .foregroundStyle(Color.accentColor)
          }
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
    }
  }
}

struct DetailToolbar: ToolbarContent {
  @Environment(Store.self) private var store

  var body: some ToolbarContent {
    let tab = store.tab
    ToolbarItemGroup(placement: .primaryAction) {
      if let dynamic = tab.keys.first(where: { $0.hasPrefix("@") }), store.drafts[tab.file] != nil {
        let path: Path = dynamic == "@apps" ? [.k("hotkeys")] : []
        let need = store.entryNeedsApplication(tab.file, path)
        if need.needed {
          Menu {
            Button("Enter Manually…") { store.openEntryEditor(tab.file, path, title: tab.title, applicationID: "") }
            Button(need.proxy ? "Browse Applications…" : "Browse…") {
              store.browseApplication { id, proxyName in
                store.openEntryEditor(tab.file, path, title: tab.title, applicationID: need.proxy ? (proxyName ?? id) : id)
              }
            }
          } label: { Label("Add Entry", systemImage: "plus") }
          .help("Add entry")
        } else {
          Button { store.openEntryEditor(tab.file, path, title: tab.title, applicationID: "") } label: { Label("Add Entry", systemImage: "plus") }
            .help("Add entry")
        }
      }
      Menu {
        Button("Edit File JSON…") {
          let name = tab.file
          guard let draft = store.drafts[name] else { return }
          store.editJSON("Edit \(name).json", draft) { v in
            guard v.isRecord else { throw ConfigError("The root value must be a JSON object") }
            try store.assign(name, [], v); store.mark()
          }
        }
        .disabled(store.drafts[tab.file] == nil)
        Button("Refresh Files") { store.readAgain() }
        if let directory = store.configDirectory {
          Divider()
          Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory + "/config/" + tab.file + ".json")])
          }
        }
      } label: { Label("More", systemImage: "ellipsis") }
      .help("More actions")
    }
    ToolbarItemGroup(placement: .primaryAction) {
      Button { store.discard() } label: { Label("Discard Changes", systemImage: "arrow.uturn.backward") }
        .disabled(!store.canDiscard)
        .help("Discard changes to \(tab.file).json")
      Button { store.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
        .disabled(store.pending != nil || store.reloading)
        .help("Reload Hammerspoon to apply saved configuration")
    }
    ToolbarItem(placement: .primaryAction) {
      Button { store.save() } label: { Text("Save") }
        .buttonStyle(.borderedProminent)
        .tint(store.canSave ? .accentColor : .gray)
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!store.canSave)
        .help("Save \(tab.file).json (⌘S)")
    }
  }
}

struct StatusPill: View {
  @Environment(Store.self) private var store
  var body: some View {
    if let status = store.status {
      let pill = HStack(spacing: 8) {
        Image(systemName: store.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
          .foregroundStyle(store.statusIsError ? .red : .green)
        Text(status).lineLimit(2)
        if store.statusIsError {
          Button { store.setStatus(nil) } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
      }
      .font(.callout)
      .padding(.horizontal, 14).padding(.vertical, 9)
      Group {
        if #available(macOS 26.0, *) {
          pill.glassEffect(.regular, in: .capsule)
        } else {
          pill.background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
      }
      .padding(.bottom, 16)
      .padding(.horizontal, 24)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .animation(.snappy, value: status)
    }
  }
}

// MARK: - Sections

struct SectionTitle: View {
  let title: String
  var appID: String?
  var body: some View {
    HStack(spacing: 7) {
      if let appID, AppIdentity.shared.isApplication(appID) { AppIcon(id: appID, size: 18) }
      Text(title)
    }
  }
}

struct SectionView: View {
  @Environment(Store.self) private var store
  let spec: SectionSpec

  private var key: String { spec.path.last?.description ?? "" }
  private var title: String { store.displayTitle(spec.file, spec.path, spec.value, key) }
  private var expansionKey: String { spec.id }

  var body: some View {
    let file = spec.file, path = spec.path
    if spec.missing {
      Section {
        HStack {
          Text("Not configured").foregroundStyle(.secondary)
          Spacer()
          if let initial = emptyConfiguration[file]?[path.strings.joined(separator: ".")], initial.isContainer {
            AddEntryButton(needsApplication: initial.isArray ? store.isApplicationList(file, path) : store.entryNeedsApplication(file, path).needed) { id, _ in
              if initial.isArray { store.openArrayEntry(file, path, applicationID: id) }
              else { store.openEntryEditor(file, path, title: title, applicationID: id) }
            }
          }
          Button("Configure…") { store.configureMissingSection(spec) }
            .buttonStyle(.bordered).controlSize(.small)
        }
      } header: { Text(title) }
    } else if store.tab.keys.contains("@apps") {
      Section {
        DisclosureGroup(isExpanded: Binding(get: { store.expandedApps.contains(expansionKey) }, set: { open in
          if open { store.expandedApps.insert(expansionKey) } else { store.expandedApps.remove(expansionKey) }
        })) {
          NodeView(file: file, path: path, value: spec.value, key: key)
        } label: {
          HStack(spacing: 9) {
            if key == "browsers" {
              IconTile(symbol: "safari.fill", tint: .blue, size: 22)
              VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                  Text("Browsers").fontWeight(.semibold)
                  Text("Shared").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15))).foregroundStyle(Color.accentColor)
                }
                Text("Applies to Safari, Chrome, Edge, and Edge Dev.").font(.caption).foregroundStyle(.secondary)
              }
            } else {
              AppIcon(id: key, size: 22)
              Text(title).fontWeight(.semibold)
              Text("\(spec.value?.childCount ?? 0)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if key != "browsers" {
              ActionsMenu(actions: [.delete("Delete \(title) Shortcuts") { store.expandedApps.remove(expansionKey); store.deleteEntry(file, path) }])
            }
          }
        }
      }
    } else if proxyFiles.contains(file) && path.count == 1 {
      let open = !store.collapsed.contains(expansionKey)
      Section {
        if open, let value = spec.value { ProxyClientView(file: file, path: path, value: value, key: key) }
      } header: {
        HStack(spacing: 6) {
          Button {
            withAnimation(.snappy) {
              if open { store.collapsed.insert(expansionKey) } else { store.collapsed.remove(expansionKey) }
            }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "chevron.right").font(.caption.weight(.bold)).rotationEffect(.degrees(open ? 90 : 0))
              Text(title)
              if store.proxyApps[key] == false { Text("Not installed").font(.caption).foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .opacity(store.proxyApps[key] == false ? 0.6 : 1)
          Spacer()
          ActionsMenu(actions: [.delete("Delete \(title)") { store.collapsed.remove(expansionKey); store.deleteEntry(file, path) }])
        }
      }
    } else if file == "misc" && path.count == 1 && path[0].key == "proxy", let rules = spec.value?.array {
      AutoSwitchingSections(file: file, path: path, rules: rules)
    } else if let value = spec.value, store.flattensSection(file, path, value) {
      if let items = value.array {
        RecordSections(file: file, path: path, items: items, title: title)
      } else {
        ObjectPage(file: file, path: path, value: value, title: title, header: hidesHeader ? nil : title)
      }
    } else {
      Section {
        if file == "localization" && path.count == 1 && path[0].key == "resources", let value = spec.value {
          LocalizationResourcesView(file: file, path: path, value: value)
        } else {
          NodeView(file: file, path: path, value: spec.value, key: key)
        }
      } header: {
        if path.count == 1 && ((file == "localization" && path[0].key != "resources") || (file == "application" && store.tab.keys.contains("@other"))) {
          HStack {
            SectionTitle(title: title, appID: key)
            Spacer()
            ActionsMenu(actions: [.delete("Delete " + applicationTitle(key)) { store.deleteEntry(file, path) }])
          }
        } else if !hidesHeader {
          SectionTitle(title: title, appID: path.count == 1 ? nil : key)
        }
      }
    }
  }

  /// Sections whose tab title already names them.
  private var hidesHeader: Bool {
    let file = spec.file, path = spec.path
    return (file == "localization" && path.count == 1 && path[0].key == "resources")
      || (file == "sync" && path.count == 1 && ["file", "variable"].contains(path[0].key ?? ""))
      || (file == "misc" && path.count == 1 && ["pollingInterval", "menuBarOverflowCollapseDelay"].contains(path[0].key ?? ""))
      || (file == "keybindings" && ((path.count == 1 && path[0].key == "hyper")
          || (path.count == 2 && path[0].key == "hotkeys" && ["appkeys", "global", "shared"].contains(path[1].key ?? ""))))
  }
}

struct AutoSwitchingSections: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, rules: [JSON]

  var body: some View {
    ScopedRows(scope: "\(file)/\(path)", indices: Array(rules.indices)) { index in
      let rulePath = path.appending(index)
      let rule = rules[index]
      Section {
        if let object = rule.object {
          ForEach(object.keys, id: \.self) { key in
            if key == "candidates", let candidates = object[key]?.array {
              ProxyCandidatesView(file: file, path: rulePath.appending(key), candidates: candidates)
            } else if key == "condition" {
              EmptyView()
            } else {
              NodeView(file: file, path: rulePath.appending(key), value: object[key], key: key, depth: 1)
            }
          }
        } else {
          NodeView(file: file, path: rulePath, value: rule, key: String(index + 1), depth: 1)
        }
      } header: {
        HStack {
          Text(rules.count > 1 ? "Switching rule \(index + 1)" : "Switching rule")
          Spacer()
          ActionsMenu(actions: (rule.object?.has("condition") == false ? [
            NodeAction.item("Add Rule Condition") { store.set(file, rulePath.appending("condition"), .object(JObject())) },
          ] : []) + [
            .item("Edit as JSON…") { store.editValue(file, rulePath, title: "Switching rule") },
            .delete("Delete Switching Rule") { store.deleteEntry(file, rulePath) },
          ])
        }
      }
      if let condition = rule.object?["condition"] {
        ProxyConditionView(file: file, path: rulePath.appending("condition"), value: condition, asSection: true)
      }
    }
    Section {
      if rules.isEmpty { EmptyRow(text: "No switching rules") }
      ActionButtons(actions: [
        .item("Edit All Rules as JSON…") { store.editValue(file, path, title: "Automatic switching rules") },
        .add("Add Switching Rule") { _, _ in store.openArrayEntry(file, path) },
      ])
    }
  }
}

// MARK: - Sheets

struct SheetHeader: View {
  let title: String
  let message: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.title3.weight(.semibold)).lineLimit(2)
      Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct ErrorText: View {
  let text: String?
  var body: some View {
    if let text {
      Label(text, systemImage: "exclamationmark.triangle.fill")
        .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct JSONEditorSheet: View {
  @Environment(Store.self) private var store
  let request: JSONEditorRequest
  @State private var text = ""
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SheetHeader(title: request.title, message: request.help)
      CodeEditor(text: $text).frame(minHeight: 280)
      ErrorText(text: error)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { store.jsonEditor = nil }.keyboardShortcut(.cancelAction)
        Button("Apply") { apply() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
      }
    }
    .padding(22)
    .frame(width: 600)
    .frame(minHeight: 420)
    .onAppear { text = request.text }
  }

  private func apply() {
    do {
      try request.apply(try JSONParser.parse(text))
      store.jsonEditor = nil
    } catch { self.error = "Not applied: " + error.localizedDescription }
  }
}

struct PropertySheet: View {
  @Environment(Store.self) private var store
  let request: PropertyRequest
  @State private var draft: PropertyRequest?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SheetHeader(title: request.title, message: "Choose a property or enter a custom name. Changes are saved with Save changes.")
      VStack(alignment: .leading, spacing: 6) {
        Text(request.nameLabel).font(.callout.weight(.medium))
        HStack(spacing: 6) {
          TextField("", text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0 }), prompt: Text(request.nameLabel))
            .labelsHidden().textFieldStyle(.roundedBorder)
            .onSubmit { if var d = draft { store.propertyNameChanged(&d); draft = d } }
          if !request.suggestions.isEmpty {
            Menu {
              ForEach(request.suggestions, id: \.self) { name in
                Button(name) { if var d = draft { d.name = name; store.propertyNameChanged(&d); draft = d } }
              }
            } label: { Image(systemName: "chevron.up.chevron.down") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          }
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("Value (JSON)").font(.callout.weight(.medium))
        CodeEditor(text: Binding(get: { draft?.valueText ?? "" }, set: { draft?.valueText = $0 })).frame(height: 170)
      }
      ErrorText(text: error)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { store.property = nil }.keyboardShortcut(.cancelAction)
        Button(request.actionTitle) { commit() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
      }
    }
    .padding(22)
    .frame(width: 520)
    .onAppear { draft = request }
  }

  private func commit() {
    guard let draft else { return }
    do { try store.commitProperty(draft); store.property = nil }
    catch { self.error = error.localizedDescription }
  }
}
