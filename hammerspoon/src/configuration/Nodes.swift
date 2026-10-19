// Recursive configuration editor. Special-purpose editors take precedence over the
// generic tree; every edit goes through Store so validation and saving stay shared.
import AppKit
import SwiftUI

extension Store {
  func objectAddActions(_ file: String, _ path: Path, _ value: JSON, title: String) -> [NodeAction] {
    if globalOnlyProxy(file, path) { return [] }
    if let allowed = proxyEntryNames(file, path, value) {
      if proxyFiles.contains(file) && path.last?.key == "global" && path.first?.key != "v2rayN" { return [] }
      return allowed.filter { value.object?.has($0) != true }.map { key in
        .add("Add " + (proxyEntryLabels[key] ?? key)) { [unowned self] _, _ in openProxyEntry(file, path, key: key) }
      }
    }
    if file == "localization" && path.first?.key == "resources" && path.count == 2 {
      return [.add("Add Resource") { [unowned self] _, _ in addLocalizationResource(file, path) }]
    }
    let need = entryNeedsApplication(file, path)
    return [.add("Add Entry", application: need.needed, proxy: need.proxy) { [unowned self] id, proxyName in
      openEntryEditor(file, path, title: title, applicationID: need.proxy ? (proxyName ?? id) : id)
    }]
  }

  func containerActions(_ file: String, _ path: Path, _ value: JSON, title: String) -> [NodeAction] {
    var actions: [NodeAction]
    if value.isArray {
      actions = [.add("Add Entry", application: isApplicationList(file, path)) { [unowned self] id, _ in
        openArrayEntry(file, path, applicationID: id)
      }]
    } else {
      actions = objectAddActions(file, path, value, title: title)
    }
    actions.append(.item("Edit as JSON…") { [unowned self] in editValue(file, path, title: title, fallback: value) })
    return actions
  }
}

struct NodeView: View {
  @Environment(Store.self) private var store
  let file: String
  let path: Path
  let value: JSON?
  let key: String
  var depth = 0
  var skipNamedMapping = false
  var skipProxyMode = false
  var skipWindowRule = false
  var hideLabel = false
  var onRemove: (() -> Void)? = nil
  var removeHelp = "Delete"

  private var isProxy: Bool { proxyFiles.contains(file) }

  /// v2rayN and global-only clients always show a Global block.
  private var shownValue: JSON? {
    if (store.globalOnlyProxy(file, path) || (isProxy && path.first?.key == "v2rayN")) && path.count == 1,
       var object = value?.object, object["locations"]?.isArray != true, !object.has("global") {
      object["global"] = .object(JObject())
      return .object(object)
    }
    return value
  }

  var body: some View {
    let value = shownValue
    if file == "misc" && path.count == 1 && path[0].key == "verificationFilter", let rules = value?.array {
      VerificationCodesView(file: file, path: path, rules: rules)
    } else if store.isWindowBehaviorMapping(file, path, value) {
      WindowBehaviorMappingView(file: file, path: path, value: value!, depth: depth)
    } else if !skipWindowRule && file == "application" && windowBehaviorKeys.contains(path.first?.key ?? "")
                && path.count == 4 && path[1].index != nil {
      NodeView(file: file, path: path, value: value, key: key, depth: depth, skipWindowRule: true, hideLabel: hideLabel,
               onRemove: { store.deleteEntry(file, path) }, removeHelp: "Delete \(key)")
    } else if !skipProxyMode && isProxy && path.count >= 2 && ["pac", "global"].contains(path.last?.key ?? "") {
      ProxyModeView(file: file, path: path, value: value, key: key, depth: depth, skipNamedMapping: skipNamedMapping)
    } else if file == "localization" && path.count == 1 && path[0].key != "resources" {
      MenuTranslationsView(file: file, path: path, value: value)
    } else if !skipNamedMapping && path.count == 2
                && ((file == "sync" && ["file", "variable"].contains(path[0].key ?? "")) || (file == "keybindings" && path[0].key == "hyper")) {
      NamedMappingRow(file: file, path: path, value: value)
    } else if file == "keybindings" && path.first?.key == "remoteDesktopModifiers" && path.count == 5 && path[3].key == "map" {
      ModifierMappingRow(file: file, path: path, value: value, onRemove: onRemove)
    } else if file == "keybindings" && path.first?.key == "remoteDesktopModifiers" && path.count == 4 && path.last?.key == "type" {
      Toggle(isOn: Binding(get: { value == .string("restore") }, set: { on in
        if on { store.set(file, path, .string("restore")) } else { store.deleteEntry(file, path) }
      })) {
        TitleLabel(title: "Restore modifiers", helpText: "Restore the original modifier mapping when leaving the app")
      }
      .toggleStyle(.switch)
    } else if store.isShortcutValue(file, path, value) {
      ShortcutRow(file: file, path: path, value: value!, title: store.displayTitle(file, path, value, key))
    } else if let kind = store.keyFieldKind(file, path), value?.string != nil || value == .bool(false) || value?.isArray == true {
      bindingRow(kind)
    } else if let value, value.isContainer {
      ContainerView(file: file, path: path, value: value, key: key, depth: depth, title: title, onRemove: onRemove, removeHelp: removeHelp)
    } else {
      ScalarRow(file: file, path: path, value: value, key: key, title: title, hideLabel: hideLabel, onRemove: onRemove, removeHelp: removeHelp)
    }
  }

  private var title: String { store.displayTitle(file, path, shownValue, key) }

  @ViewBuilder private func bindingRow(_ kind: KeyKind) -> some View {
    let button = ShortcutButton(file: file, title: title, modsPath: kind == .modifiers ? path : nil, keyPath: kind == .key ? path : nil)
    if hideLabel {
      button
    } else {
      FormRow {
        HStack(spacing: 8) { button; if let onRemove { RemoveButton(help: removeHelp, action: onRemove) } }
      } label: { TitleLabel(title: title, appID: appKey(key)) }
      .hoverRow()
    }
  }
}

// MARK: - Generic containers

struct ContainerView: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, value: JSON, key: String, depth: Int, title: String
  var onRemove: (() -> Void)?
  var removeHelp = "Delete"

  private var compact: Bool {
    isCompactList(value) && !(file == "application" && path.count == 1 && path[0].key == "defaultMusicAppForControlCenter")
  }
  private var actions: [NodeAction] {
    var actions = store.containerActions(file, path, value, title: title)
    if let onRemove { actions.append(.delete(removeHelp, onRemove)) }
    return actions
  }

  var body: some View {
    if depth > 0 && compact {
      FormRow {
        HStack(spacing: 8) {
          CompactListRow(file: file, path: path, items: value.array ?? [])
          if let onRemove { RemoveButton(help: removeHelp, action: onRemove) }
        }
      } label: { TitleLabel(title: title, helpText: helpText(key), appID: appKey(key)) }
      .hoverRow()
    } else if depth > 0 {
      DrillRow(route: NodeRoute(file: file, path: path, title: title), summary: summary(value), actions: actions) {
        TitleLabel(title: title, helpText: helpText(key), appID: appKey(key))
      }
    } else {
      if compact {
        CompactListRow(file: file, path: path, items: value.array ?? [])
      } else {
        let array = value.isArray
        let keys = store.displayKeys(file, path, value)
        ForEach(keys, id: \.self) { k in
          let childPath = path + [k]
          let child = value[k]
          NodeView(file: file, path: childPath, value: child, key: k.index.map { String($0 + 1) } ?? k.description,
                   depth: depth + 1, onRemove: removeAction(childPath, child, array: array), removeHelp: removeLabel(k))
        }
        if keys.isEmpty { EmptyRow(text: array ? "No entries" : "No settings") }
      }
      ActionButtons(actions: actions.filter { if case .delete = $0 { return false }; return !(compact && $0.isAdd) })
    }
  }

  private func removeAction(_ childPath: Path, _ child: JSON?, array: Bool) -> (() -> Void)? {
    if array && !store.isShortcutValue(file, childPath, child) && !store.isWindowBehaviorMapping(file, childPath, child) {
      return { store.deleteEntry(file, childPath) }
    }
    if file == "application" && path.count == 1 && path[0].key == "inputSource" { return { store.deleteEntry(file, childPath) } }
    return nil
  }
  private func removeLabel(_ k: PK) -> String { k.key.map { "Delete " + applicationTitle($0) } ?? "Delete Entry" }
}

/// One-line summary for a row that opens a nested page.
@MainActor func summary(_ value: JSON?) -> String {
  guard let value else { return "" }
  if let items = value.array {
    let strings = items.compactMap { $0.string }.filter { !$0.isEmpty }
    if strings.count == items.count && !strings.isEmpty {
      let text = strings.prefix(3).map { applicationTitleIfApp($0) }.joined(separator: ", ")
      return strings.count > 3 ? text + " +\(strings.count - 3)" : text
    }
    return items.count == 1 ? "1 item" : "\(items.count) items"
  }
  if let object = value.object {
    if object.entries.allSatisfy({ !$0.1.isContainer }) {
      var seen: [String] = []
      for (_, v) in object.entries where v != .string("") && !seen.contains(scalarText(v)) { seen.append(scalarText(v)) }
      if !seen.isEmpty { return seen.prefix(2).joined(separator: ", ") + (seen.count > 2 ? " +\(seen.count - 2)" : "") }
    }
    return object.count == 1 ? "1 setting" : "\(object.count) settings"
  }
  return scalarText(value)
}

@MainActor func applicationTitleIfApp(_ text: String) -> String {
  AppIdentity.shared.isApplication(text) ? (AppIdentity.shared.name(text) ?? text) : text
}

/// A row that opens a nested page, as System Settings does for details.
struct DrillRow<Label: View>: View {
  @Environment(Store.self) private var store
  @Environment(\.navigationContext) private var context
  let route: NodeRoute
  var summary = ""
  var actions: [NodeAction] = []
  @ViewBuilder let label: Label

  var body: some View {
    Button { store.present(route, from: context) } label: {
      HStack(spacing: 10) {
        label
        Spacer(minLength: 16)
        Text(summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu { if !actions.isEmpty { NodeActionItems(actions: actions) } }
  }
}

/// Short lists of scalars edited in place as a wrapping row of tokens.
struct CompactListRow: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, items: [JSON]

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(store.isApplicationList(file, path) ? AppIdentity.shared.installedFirst(Array(items.indices)) { items[$0].string } : Array(items.indices), id: \.self) { index in
        Chip(help: "Delete entry", remove: { store.deleteEntry(file, path.appending(index)) }) {
          // Application lists read as apps; their IDs stay in the tooltip and JSON.
          if store.isApplicationList(file, path), let id = items[index].string {
            AppLabel(id: id).padding(.leading, 6).padding(.vertical, 3).help(id)
          } else {
            ScalarControl(file: file, path: path.appending(index), value: items[index], alignment: .leading, compact: true)
          }
        }
      }
      AddEntryButton(needsApplication: store.isApplicationList(file, path), compact: true) { id, _ in
        store.openArrayEntry(file, path, applicationID: id)
      }
      .help("Add entry")
    }
    .padding(.vertical, 2)
  }
}

// MARK: - Scalars

struct ScalarRow: View {
  @Environment(Store.self) private var store
  @Environment(\.fieldAlignment) private var fieldAlignment
  let file: String, path: Path, value: JSON?, key: String, title: String
  var hideLabel = false
  var onRemove: (() -> Void)?
  var removeHelp = "Delete"

  private var inList: Bool { store.value(file, path.parent)?.isArray == true }
  private var addsAlternative: Bool {
    guard value?.string != nil else { return false }
    return (file == "keybindings" && path.first?.key == "hotkeys" && path.at(1)?.key == "appkeys" && path.last?.key == "bundleID")
      || (file == "application" && path.first?.key == "inputSource" && path.count == 2)
      || (file == "localization" && path.first?.key == "resources" && path.count == 2)
  }

  var body: some View {
    if value?.bool != nil && !inList && !hideLabel {
      HStack {
        Toggle(isOn: Binding(get: { store.value(file, path)?.bool ?? false }, set: { store.set(file, path, .bool($0)) })) {
          TitleLabel(title: title, helpText: helpText(key), appID: appKey(key))
        }
        .toggleStyle(.switch)
        if let onRemove { RemoveButton(help: removeHelp, action: onRemove) }
      }
      .hoverRow()
    } else if inList && store.isApplicationList(file, path.parent), let id = value?.string {
      HStack(spacing: 10) {
        AppLabel(id: id)
        Spacer(minLength: 12)
        PlainField(text: binding, prompt: "Bundle ID", alignment: .trailing, secondary: true).frame(maxWidth: 300)
        if let onRemove { RemoveButton(help: removeHelp, action: onRemove) }
      }
      .hoverRow()
    } else if inList || hideLabel {
      HStack(spacing: 8) {
        ScalarControl(file: file, path: path, value: value, alignment: fieldAlignment ?? .leading)
        alternative
        if let onRemove { RemoveButton(help: removeHelp, action: onRemove) }
      }
      .hoverRow()
    } else {
      FormRow {
        HStack(spacing: 8) {
          ScalarControl(file: file, path: path, value: value, alignment: .trailing).frame(maxWidth: 340, alignment: .trailing)
          alternative
          if let onRemove { RemoveButton(help: removeHelp, action: onRemove) }
        }
      } label: {
        TitleLabel(title: title, helpText: helpText(key), appID: appKey(key))
      }
      .hoverRow()
    }
  }

  private var binding: Binding<String> {
    Binding(get: { store.value(file, path)?.string ?? "" }, set: { store.set(file, path, .string($0)) })
  }

  private var alternative: some View { alternativeButton.revealOnHover() }

  @ViewBuilder private var alternativeButton: some View {
    if addsAlternative {
      if file == "localization" {
        AddEntryButton(compact: true) { _, _ in store.addLocalizationResource(file, path) }.help("Add another resource")
      } else {
        let application = file == "application"
        AddEntryButton(needsApplication: !application, compact: true) { id, _ in
          store.editJSON(application ? "Add input source" : "Add app identifier", .string(id)) { v in
            guard let s = v.string, !trimmed(s).isEmpty else {
              throw ConfigError(application ? "Enter a non-empty input source identifier." : "Enter a non-empty app identifier.")
            }
            try store.assign(file, path, .array([store.value(file, path) ?? .string(""), v])); store.mark()
          }
        }
        .help(application ? "Add another input source" : "Add another application")
      }
    }
  }
}

/// The input for a single scalar: switch, number, text, or path.
struct ScalarControl: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, value: JSON?
  var alignment: TextAlignment = .trailing
  var compact = false

  var body: some View {
    switch value {
    case .null?:
      Button("Edit…") { store.editValue(file, path, title: path.last?.description ?? "Value") }
        .buttonStyle(.bordered).controlSize(.small)
    case .bool?:
      Toggle("", isOn: Binding(get: { store.value(file, path)?.bool ?? false }, set: { store.set(file, path, .bool($0)) }))
        .labelsHidden().toggleStyle(.switch).controlSize(.small)
    case .number(let n)?:
      NumberField(file: file, path: path, number: n, minimum: path.last?.key == "pollingInterval" ? 0.01 : path.last?.key == "menuBarOverflowCollapseDelay" ? 0 : nil, alignment: alignment)
    default:
      if value == nil || value?.string != nil, let context = store.pathFieldContext(file, path) {
        PathField(file: file, path: path, context: context, alignment: alignment)
      } else {
        let text = Binding(get: { store.value(file, path)?.string ?? "" }, set: { store.set(file, path, .string($0)) })
        let required = proxyFiles.contains(file) && path.first?.key == "v2rayN" && path.at(-2)?.key == "pac" && path.last?.key == "routing"
        PlainField(text: text, prompt: required ? "Required" : "Not set", alignment: alignment,
                   invalid: required && trimmed(text.wrappedValue).isEmpty)
          .frame(width: compact ? textWidth(text.wrappedValue, minimum: 60, maximum: 260) : nil)
          .help(required ? "Required in v2rayN PAC mode" : "")
      }
    }
  }
}

struct NumberField: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, number: Double
  var minimum: Double?
  var alignment: TextAlignment = .trailing
  @State private var text = ""

  private var invalidKey: String { file + "/" + path.joined }

  var body: some View {
    PlainField(text: $text, prompt: "0", alignment: alignment, invalid: store.invalid[invalidKey] != nil)
      .monospacedDigit()
      .frame(width: 90)
      .onAppear { text = JSON.formatNumber(number) }
      .onChange(of: number) { if store.invalid[invalidKey] == nil, Double(trimmed(text)) != number { text = JSON.formatNumber(number) } }
      .onChange(of: text) {
        guard let parsed = Double(trimmed(text)), parsed.isFinite, minimum.map({ parsed >= $0 }) ?? true else {
          store.markInvalid(invalidKey, "Enter a valid number before saving."); return
        }
        if parsed != number { store.update(file, path, .number(parsed), invalidKey: invalidKey) } else { store.clearInvalid(invalidKey) }
      }
  }
}

struct PathField: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, context: PathContext
  var alignment: TextAlignment = .trailing
  var body: some View {
    let text = Binding(get: { store.value(file, path)?.string ?? "" }, set: { store.set(file, path, .string($0)) })
    HStack(spacing: 2) {
      PlainField(text: text, alignment: alignment)
      BrowseButton(current: text.wrappedValue, context: context, key: file + "/" + path.joined) { text.wrappedValue = $0 }
    }
  }
}

struct BrowseButton: View {
  @Environment(Store.self) private var store
  let current: String, context: PathContext, key: String
  let commit: (String) -> Void
  var body: some View {
    Button {
      store.browsePath(current: current, context: context, key: key) { path, kind in
        if let required = context.requiredType, required != kind { store.setStatus("Destination must be a folder.", error: true); return }
        if context.fileURL {
          let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
          commit("file://" + path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }.joined(separator: "/"))
        } else { commit(path) }
      }
    } label: { Image(systemName: "folder").foregroundStyle(.secondary) }
    .buttonStyle(.borderless)
    .revealOnHover()
    .disabled(store.browsing.contains(key))
    .help(context.requiredType == "directory" ? "Choose a folder" : "Choose a file or folder")
  }
}

/// Raw text editor for a modifier or key value; used in the shortcut popover.
struct KeyField: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, value: JSON?, kind: KeyKind, title: String
  var width: CGFloat = 170
  @State private var text = ""
  @FocusState private var focused: Bool

  private var invalidKey: String { file + "/" + path.joined }

  var body: some View {
    TextField("", text: $text, prompt: Text(kind == .modifiers ? "command + option" : "Return"))
      .labelsHidden()
      .textFieldStyle(.roundedBorder)
      .font(.system(.body, design: .monospaced))
      .frame(width: width)
      .focused($focused)
      .overlay { if store.invalid[invalidKey] != nil { RoundedRectangle(cornerRadius: 6).stroke(.red.opacity(0.8), lineWidth: 1.5) } }
      .help(kind == .modifiers ? "Modifier names, symbols, or a ${hyper.…} reference" : "Key name")
      .accessibilityLabel(title)
      .onAppear { text = keyRaw(value) }
      .onChange(of: value) { if !focused { text = keyRaw(value) } }
      .onChange(of: text) {
        guard focused else { return }
        let current = store.value(file, path)
        do {
          let updated = text == keyRaw(current) ? current : try parseKeyField(text, kind: kind, original: value)
          if let updated, updated != current { store.update(file, path, updated, invalidKey: invalidKey) } else { store.clearInvalid(invalidKey) }
        } catch { store.markInvalid(invalidKey, error.localizedDescription) }
      }
  }
}

// MARK: - Shortcuts

struct ShortcutRow: View {
  @Environment(Store.self) private var store
  @Environment(\.navigationContext) private var context
  let file: String, path: Path, value: JSON, title: String

  private var appLauncher: Bool { file == "keybindings" && path.first?.key == "hotkeys" && path.at(1)?.key == "appkeys" && path.count == 3 }
  /// Shortcuts with settings beyond the key combination open a details page.
  private var hasDetails: Bool {
    store.supportsShortcutOptions(file, path) || path.at(1)?.key == "shared"
      || value.childKeys.contains { $0 != .k("mods") && $0 != .k("key") }
  }

  var body: some View {
    HStack(spacing: 10) {
      if appLauncher {
        AppLaunchName(file: file, path: path, value: value, title: title)
      } else {
        Text(title).lineLimit(2)
      }
      Spacer(minLength: 12)
      ShortcutButton(file: file, title: title, modsPath: path.appending("mods"), keyPath: path.appending("key"))
      if hasDetails && !appLauncher {
        Button { store.panel = .shortcut(file: file, path: path, title: title) } label: { Image(systemName: "info.circle") }
          .buttonStyle(.borderless).foregroundStyle(.secondary).help("Details")
      }
      RemoveButton(help: "Delete shortcut: " + title) { store.deleteEntry(file, path) }
    }
    .hoverRow()
  }
}

struct AppLaunchName: View {
  @Environment(Store.self) private var store
  @Environment(\.navigationContext) private var context
  let file: String, path: Path, value: JSON, title: String

  var body: some View {
    let binding = store.appBindings[path[2].description]
    let source = binding?["source"]
    let unchanged = source != nil && ["bundleID", "path", "vm", "name", "mods", "key"].allSatisfy { source?[$0] == value[$0] }
    let ids = AppIdentity.shared.installedFirst(value["bundleID"]?.string.map { [$0] } ?? value["bundleID"]?.array?.compactMap { $0.string } ?? []) { $0 }
    Button { if let index = path.at(2)?.index { store.panel = .appLauncher(index) } } label: {
      HStack(spacing: 8) {
        if ids.isEmpty {
          Image(systemName: "app.dashed").foregroundStyle(.tertiary)
          Text(title).foregroundStyle(binding != nil && unchanged ? .primary : .secondary)
        } else {
          ForEach(Array(ids.enumerated()), id: \.offset) { index, id in
            if index > 0 { Text("or").font(.caption).foregroundStyle(.tertiary) }
            let active = unchanged && binding?["appid"]?.string == id
            HStack(spacing: 6) {
              AppIcon(id: id, size: 20).opacity(active ? 1 : 0.5)
              Text(applicationTitle(id)).foregroundStyle(active ? .primary : .secondary)
            }
            .help(active ? "Bound to this shortcut" : "Not bound to this shortcut")
          }
        }
      }
      .lineLimit(1)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Edit app launch configuration")
  }
}

// MARK: - Mappings

struct NamedMappingRow: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, value: JSON?
  @State private var text = ""

  private var variable: Bool { file == "sync" && path.first?.key == "variable" }
  private var macro: Bool { file == "keybindings" && path.first?.key == "hyper" }
  private var key: String { path.last?.key ?? "" }
  private var locked: Bool { macro && key == "hyper" }
  private var errorKey: String { file + "/" + path.joined + "/@source" }

  var body: some View {
    Group {
      if macro {
        HStack(spacing: 10) {
          if locked {
            Label { Text(key) } icon: { Image(systemName: "lock.fill").foregroundStyle(.tertiary) }
              .help("The Hyper key name is reserved")
          } else {
            nameField(prompt: "Macro name").frame(maxWidth: 220)
          }
          Spacer(minLength: 12)
          target(alignment: .trailing)
        }
      } else if variable {
        HStack(spacing: 10) {
          nameField(prompt: "Variable name", monospaced: true).frame(maxWidth: 240)
          Spacer(minLength: 12)
          target(alignment: .trailing).frame(maxWidth: 380)
          if !store.pathVariableReferenced(key) { RemoveButton(help: "Delete " + key) { store.deleteEntry(file, path) } }
        }
      } else {
        HStack(spacing: 10) {
          Image(systemName: "doc").foregroundStyle(.tertiary)
          VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
              nameField(prompt: "Source path")
              BrowseButton(current: text, context: PathContext(parentDirectory: true), key: errorKey) { text = $0; commit() }
            }
            HStack(spacing: 4) {
              Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
              target(alignment: .leading).foregroundStyle(.secondary)
            }
          }
          RemoveButton(help: "Delete " + key) { store.deleteEntry(file, path) }
        }
      }
    }
    .hoverRow()
    .onAppear { text = key }
    .onChange(of: key) { text = key }
    .onChange(of: text) {
      do { _ = try store.validateMappingName(file, path, text); store.clearInvalid(errorKey) }
      catch { store.markInvalid(errorKey, error.localizedDescription) }
    }
  }

  private func nameField(prompt: String, monospaced: Bool = false) -> some View {
    PlainField(text: $text, prompt: prompt, monospaced: monospaced, alignment: .leading, invalid: store.invalid[errorKey] != nil,
               onFocusChange: { if !$0 { commit() } }, onSubmit: commit)
  }

  private func target(alignment: TextAlignment) -> some View {
    VStack(alignment: alignment == .leading ? .leading : .trailing, spacing: 4) {
      NodeView(file: file, path: path, value: value, key: key, skipNamedMapping: true, hideLabel: true)
    }
    .environment(\.fieldAlignment, alignment)
  }

  private func commit() {
    guard trimmed(text) != key else { return }
    do { try store.renameMapping(file, path, to: text); store.clearInvalid(errorKey) }
    catch { store.markInvalid(errorKey, error.localizedDescription) }
  }
}

private let modifierChoices = ["command", "option", "control", "shift", "fn"]

struct ModifierMappingRow: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, value: JSON?
  var onRemove: (() -> Void)?

  private var sourceKey: String { path.last?.key ?? "" }
  private func canonical(_ s: String) -> String { modifierNames[s.lowercased()] ?? s }

  var body: some View {
    HStack(spacing: 10) {
      picker(Binding(get: { canonical(sourceKey) }, set: { name in
        do { _ = try store.renameModifierSource(file, path.parent, from: sourceKey, to: name); store.mark() }
        catch { store.setStatus(error.localizedDescription, error: true) }
      }), current: canonical(sourceKey))
      Image(systemName: "arrow.right").foregroundStyle(.tertiary)
      picker(Binding(get: { canonical(scalarText(value)) }, set: { store.set(file, path, .string($0)) }), current: canonical(scalarText(value)))
      Spacer()
      if let onRemove { RemoveButton(action: onRemove) }
    }
    .hoverRow()
  }

  private func picker(_ selection: Binding<String>, current: String) -> some View {
    Picker("", selection: selection) {
      ForEach(modifierChoices + (modifierChoices.contains(current) ? [] : [current]), id: \.self) { name in
        Text("\(keyDisplay(.string(name)))  \(name.capitalized)").tag(name)
      }
    }
    .labelsHidden()
    .fixedSize()
  }
}

struct WindowBehaviorMappingView: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, value: JSON, depth: Int

  var body: some View {
    let title = store.displayTitle(file, path, value, path.last?.description ?? "")
    ForEach(value.childKeys, id: \.self) { k in
      NodeView(file: file, path: path + [k], value: value[k], key: k.description, depth: depth + 1,
               onRemove: { store.deleteEntry(file, path + [k]) }, removeHelp: "Delete " + applicationTitle(k.description))
    }
    ActionButtons(actions: [
      .item("Edit Configured Apps as JSON…") { store.editValue(file, path, title: title) },
      .add("Add App", application: true) { id, _ in store.openEntryEditor(file, path, title: title, applicationID: id) },
    ])
  }
}

struct LocalizationResourcesView: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, value: JSON

  var body: some View {
    let title = store.displayTitle(file, path, value, path.last?.description ?? "")
    ForEach(value.childKeys, id: \.self) { k in
      NodeView(file: file, path: path + [k], value: value[k], key: k.description, depth: 1,
               onRemove: { store.deleteEntry(file, path + [k]) }, removeHelp: "Delete " + applicationTitle(k.description))
    }
    if value.childCount == 0 { EmptyRow(text: "No resources") }
    ActionButtons(actions: [
      .item("Edit as JSON…") { store.editValue(file, path, title: title) },
      .add("Add App", application: true) { id, _ in store.openEntryEditor(file, path, title: title, applicationID: id) },
    ])
  }
}

// MARK: - Clipboard

struct VerificationCodesView: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, rules: [JSON]

  var body: some View {
    ScopedRows(scope: "\(file)/\(path)", indices: Array(rules.indices)) { index in
      let rulePath = path.appending(index)
      let rule = rules[index]
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text("Match").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
          FlowLayout(spacing: 6) {
            ForEach(Array((rule["filter"]?.array ?? []).indices), id: \.self) { i in
              Chip(help: "Delete match text", remove: { store.deleteEntry(file, rulePath.appending("filter").appending(i)) }) {
                TextValue(file: file, path: rulePath.appending("filter").appending(i), label: "Match text \(i + 1)")
              }
            }
            AddEntryButton(compact: true) { _, _ in store.openArrayEntry(file, rulePath.appending("filter")) }.help("Add match text")
          }
          Spacer(minLength: 0)
          RemoveButton(help: "Delete verification code rule") { store.deleteEntry(file, rulePath) }
        }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text("Extract").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
          TextValue(file: file, path: rulePath.appending("extract"), label: "Extraction pattern", monospaced: true, fixedWidth: false)
        }
      }
      .padding(.vertical, 3)
      .hoverRow()
    }
    if rules.isEmpty { EmptyRow(text: "No verification code rules") }
    ActionButtons(actions: [
      .item("Edit as JSON…") { store.editValue(file, path, title: "Verification codes") },
      .add("Add Rule") { _, _ in store.openArrayEntry(file, path) },
    ])
  }
}

/// A string field, or a JSON button for values of another type.
struct TextValue: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, label: String
  var monospaced = false
  var fixedWidth = true
  var alignment: TextAlignment = .leading

  var body: some View {
    let current = store.value(file, path)
    if current == nil || current?.string != nil {
      let text = Binding(get: { store.value(file, path)?.string ?? "" }, set: { store.set(file, path, .string($0)) })
      PlainField(text: text, monospaced: monospaced, alignment: alignment)
        .frame(width: fixedWidth ? textWidth(text.wrappedValue, minimum: 70, maximum: 260) : nil)
        .accessibilityLabel(label)
    } else {
      Button("Edit…") { store.editValue(file, path, title: label) }.buttonStyle(.bordered).controlSize(.small)
    }
  }
}

// MARK: - Localization

/// Translation blocks as sections; used as a page's content.
struct MenuTranslationsView: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, value: JSON?

  var body: some View {
    let blocks = store.translationBlocks(value)
    let missing = ["forward", "reverse"].filter { blocks[$0 == "forward" ? 1 : 0].isEmpty }
    if !(value?.isContainer ?? false) { Section { EmptyRow(text: "No valid translation blocks are configured.") } }
    ForEach(["forward", "reverse"], id: \.self) { direction in
      let block = blocks[direction == "forward" ? 1 : 0]
      if !block.isEmpty {
        let title = store.translationBlockName(direction)
        let blockPath = value?.isArray == true ? path.appending(direction == "reverse" ? 0 : 1) : path
        Section {
          ForEach(block.keys, id: \.self) { key in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text(key).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
              Image(systemName: "arrow.right").foregroundStyle(.tertiary)
              HStack(spacing: 4) {
                if direction == "reverse" && block[key]?.string == nil {
                  Text("Must be one string — edit as JSON").font(.caption).foregroundStyle(.red)
                } else {
                  VStack(alignment: .leading, spacing: 2) {
                    NodeView(file: file, path: blockPath.appending(key), value: block[key], key: key, hideLabel: true)
                  }
                  if direction == "forward" && block[key]?.string != nil {
                    AddEntryButton(compact: true) { _, _ in
                      store.addLocalizationResource(file, blockPath.appending(key), title: "Add localized result")
                    }
                    .help("Add another localized result")
                    .revealOnHover()
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .hoverRow()
          }
          ActionButtons(actions: [
            .item("Edit as JSON…") {
              store.editJSON(title, .object(store.translationBlocks(store.value(file, path))[direction == "forward" ? 1 : 0])) { updated in
                guard let object = updated.object else { throw ConfigError("Use a JSON object containing translation mappings.") }
                try store.writeTranslationBlock(file, path, direction, object); store.mark()
              }
            },
            .add("Add Translation") { _, _ in store.openTranslationEntry(file, path, direction: direction) },
          ])
        } header: {
          Text(title)
        } footer: {
          Text(direction == "forward" ? "Source text → localized text." : "Localized text → source text. Also used as default forward translations.")
        }
      }
    }
    if !missing.isEmpty {
      Section {
        ActionButtons(actions: missing.map { direction in
          .add("Add " + store.translationBlockName(direction)) { _, _ in store.openTranslationEntry(file, path, direction: direction) }
        })
      }
    }
  }
}

// MARK: - Proxy

struct ProxyModeView: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, value: JSON?, key: String, depth: Int
  var skipNamedMapping = false

  var body: some View {
    if store.globalOnlyProxy(file, path) || (path.first?.key == "v2rayN" && key == "global") {
      NodeView(file: file, path: path, value: value, key: key, depth: depth, skipNamedMapping: skipNamedMapping, skipProxyMode: true)
    } else {
      NodeView(file: file, path: path, value: value, key: key, depth: depth, skipNamedMapping: skipNamedMapping, skipProxyMode: true,
               onRemove: { store.deleteEntry(file, path) }, removeHelp: key == "pac" ? "Delete PAC" : "Delete Global")
    }
  }
}

struct ProxyClientView: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, value: JSON, key: String

  var body: some View {
    if let object = shown.object {
      let title = store.displayTitle(file, path, shown, key)
      ForEach(object.keys, id: \.self) { child in
        if child == "condition" {
          ProxyConditionView(file: file, path: path.appending(child), value: object[child])
        } else {
          NodeView(file: file, path: path.appending(child), value: object[child], key: child, depth: 1)
        }
      }
      ActionButtons(actions: store.containerActions(file, path, shown, title: title))
    } else {
      NodeView(file: file, path: path, value: value, key: key)
    }
  }

  private var shown: JSON {
    if (store.globalOnlyProxy(file, path) || path.first?.key == "v2rayN"), var object = value.object,
       object["locations"]?.isArray != true, !object.has("global") {
      object["global"] = .object(JObject())
      return .object(object)
    }
    return value
  }
}

/// A proxy condition: a row that opens it, or a section on its own page.
struct ProxyConditionView: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, value: JSON?
  var asSection = false

  private var actions: [NodeAction] {
    (value?.object.map { o in proxyConditionFields.filter { !o.has($0.0) } } ?? []).map { field in
      NodeAction.item("Add " + field.1) { store.set(file, path.appending(field.0), field.2) }
    } + [
      .item("Edit as JSON…") { store.editValue(file, path, title: "Condition") },
      .delete("Delete Condition") { store.deleteEntry(file, path) },
    ]
  }

  var body: some View {
    if asSection {
      Section {
        if let object = value?.object {
          ForEach(object.keys, id: \.self) { key in
            ProxyConditionField(file: file, path: path.appending(key), value: object[key], key: key)
          }
          if object.isEmpty { EmptyRow(text: "Always applies. Add a Wi-Fi, Ethernet, or shell command condition.") }
        } else {
          NodeView(file: file, path: path, value: value, key: "condition")
        }
      } header: {
        HStack { Text("Condition"); Spacer(); ActionsMenu(actions: actions) }
      } footer: {
        Text("Applies when every listed condition matches.")
      }
    } else {
      DrillRow(route: NodeRoute(file: file, path: path, title: "Condition"), summary: conditionSummary, actions: actions) {
        Label("Condition", systemImage: "line.3.horizontal.decrease.circle")
      }
    }
  }

  private var conditionSummary: String {
    guard let object = value?.object, !object.isEmpty else { return "Always" }
    return object.keys.map { key in proxyConditionFields.first { $0.0 == key }?.1 ?? key }.joined(separator: ", ")
  }
}

struct ProxyConditionField: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, value: JSON?, key: String

  var body: some View {
    let title = proxyConditionFields.first { $0.0 == key }?.1 ?? key
    if value?.string != nil {
      FormRow {
        HStack(spacing: 8) {
          TextValue(file: file, path: path, label: title, monospaced: key == "shell_command", fixedWidth: false, alignment: .trailing)
            .frame(maxWidth: 380)
          RemoveButton(help: "Delete " + title) { store.deleteEntry(file, path) }
        }
      } label: { Text(title) }
      .hoverRow()
    } else if let items = value?.array {
      FormRow {
        HStack(spacing: 8) {
          FlowLayout(spacing: 6) {
            ForEach(Array(items.indices), id: \.self) { i in
              Chip(help: "Delete " + title, remove: { store.deleteEntry(file, path.appending(i)) }) {
                TextValue(file: file, path: path.appending(i), label: "\(title) \(i + 1)")
              }
            }
            AddEntryButton(compact: true) { _, _ in store.openArrayEntry(file, path) }.help("Add " + title)
          }
          RemoveButton(help: "Delete " + title) { store.deleteEntry(file, path) }
        }
      } label: { Text(title) }
      .hoverRow()
    } else {
      NodeView(file: file, path: path, value: value, key: key, onRemove: { store.deleteEntry(file, path) })
    }
  }
}

struct ProxyCandidatesView: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, candidates: [JSON]

  var body: some View {
    ScopedRows(scope: "\(file)/\(path)", indices: Array(candidates.indices)) { index in
      let candidatePath = path.appending(index)
      let candidate = candidates[index]
      if let object = candidate.object {
        let name = object["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "Candidate"
        let mode = object["mode"]?.string.map { $0 == "pac" ? "PAC" : $0 == "global" ? "Global" : $0 } ?? ""
        DrillRow(route: NodeRoute(file: file, path: candidatePath, title: name),
                 summary: [mode, object.has("condition") ? "Conditional" : ""].filter { !$0.isEmpty }.joined(separator: " · "),
                 actions: [
                   .item("Edit as JSON…") { store.editValue(file, candidatePath, title: name) },
                   .delete("Delete \(name)") { store.deleteEntry(file, candidatePath) },
                 ]) {
          Label(name, systemImage: "network")
        }
      } else {
        NodeView(file: file, path: candidatePath, value: candidate, key: String(index + 1))
      }
    }
    if candidates.isEmpty { EmptyRow(text: "No candidates") }
    ActionButtons(actions: [
      .item("Edit Candidates as JSON…") { store.editValue(file, path, title: "Candidates") },
      .add("Add Candidate") { _, _ in store.openArrayEntry(file, path) },
    ])
  }
}

/// A candidate's own page: name and mode, other settings, then its condition.
struct CandidatePage: View {
  @Environment(Store.self) private var store
  let file: String, path: Path, object: JObject

  var body: some View {
    let name = object["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "Candidate"
    Section {
      FormRow { TextValue(file: file, path: path.appending("name"), label: "Name", fixedWidth: false, alignment: .trailing).frame(maxWidth: 340) }
        label: { Text("Name") }
      if let mode = object["mode"]?.string, ["pac", "global"].contains(mode) {
        FormRow {
          Picker("", selection: Binding(get: { mode }, set: { store.set(file, path.appending("mode"), .string($0)) })) {
            Text("PAC").tag("pac")
            Text("Global").tag("global")
          }
          .labelsHidden().pickerStyle(.segmented).fixedSize()
        } label: { Text("Mode") }
      } else if object["mode"] != nil {
        NodeView(file: file, path: path.appending("mode"), value: object["mode"], key: "mode")
      }
      ForEach(object.keys.filter { !["name", "mode", "condition"].contains($0) }, id: \.self) { key in
        NodeView(file: file, path: path.appending(key), value: object[key], key: key, depth: 1)
      }
      ActionButtons(actions: (object.has("condition") ? [] : [
        NodeAction.item("Add Condition") { store.set(file, path.appending("condition"), .object(JObject())) },
      ]) + [.item("Edit as JSON…") { store.editValue(file, path, title: name) }])
    }
    if object.has("condition") {
      ProxyConditionView(file: file, path: path.appending("condition"), value: object["condition"], asSection: true)
    }
  }
}

/// Keys that name applications get the app's icon in their row label.
@MainActor func appKey(_ key: String) -> String? { AppIdentity.shared.isApplication(key) ? key : nil }
