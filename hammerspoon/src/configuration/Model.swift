// Configuration state and editing rules. Lua owns file I/O; this side keeps drafts.
import AppKit
import SwiftUI
import Observation

struct TabSpec {
  let title: String, file: String, keys: [String], symbol: String, tint: Color
}
struct GroupSpec {
  let id: String, name: String, description: String, tabs: [TabSpec]
}
struct TabID: Hashable { let group: Int, tab: Int }

let groups: [GroupSpec] = [
  GroupSpec(id: "general", name: "General", description: "Fine-tune everyday actions and automation.", tabs: [
    TabSpec(title: "General", file: "misc", keys: ["pollingInterval", "@other"], symbol: "gearshape.fill", tint: .gray),
    TabSpec(title: "Clipboard", file: "misc", keys: ["pasteboardFilter", "verificationFilter"], symbol: "doc.on.clipboard.fill", tint: .blue),
  ]),
  GroupSpec(id: "keys", name: "Shortcuts", description: "Define shortcuts for global actions and individual apps.", tabs: [
    TabSpec(title: "Modifiers & behavior", file: "keybindings", keys: ["hyper", "parameters", "remoteDesktopModifiers"], symbol: "command", tint: .indigo),
    TabSpec(title: "Global actions", file: "keybindings", keys: ["hotkeys.global"], symbol: "keyboard.fill", tint: .blue),
    TabSpec(title: "App launcher", file: "keybindings", keys: ["hotkeys.appkeys"], symbol: "square.grid.2x2.fill", tint: .orange),
    TabSpec(title: "Menus & shared", file: "keybindings", keys: ["hotkeys.shared", "hotkeys.menubar"], symbol: "menubar.rectangle", tint: .teal),
    TabSpec(title: "Per-app shortcuts", file: "keybindings", keys: ["@apps"], symbol: "app.connected.to.app.below.fill", tint: .purple),
  ]),
  GroupSpec(id: "apps", name: "Apps", description: "Manage window behavior, input sources, and app integrations.", tabs: [
    TabSpec(title: "Window behavior", file: "application", keys: ["hideWithoutWindow", "quitWithoutWindow", "windowSwitcherIgnore"], symbol: "macwindow.on.rectangle", tint: .blue),
    TabSpec(title: "App lifecycle", file: "application", keys: ["forbidden", "terminateSilently", "suspendHotkeysInRemoteDesktop", "menuBarItems"], symbol: "power", tint: .red),
    TabSpec(title: "Input & devices", file: "application", keys: ["inputSource", "defaultMusicAppForControlCenter", "manageAndroidDevices", "androidDevices"], symbol: "character.textbox", tint: .gray),
    TabSpec(title: "App rules", file: "application", keys: ["@other"], symbol: "list.bullet.rectangle.fill", tint: .green),
  ]),
  GroupSpec(id: "proxy", name: "Network proxy", description: "Manage proxy clients and automatic switching rules.", tabs: [
    TabSpec(title: "Clients", file: "proxy", keys: ["@all"], symbol: "network", tint: .blue),
    TabSpec(title: "Auto-switching", file: "misc", keys: ["proxy"], symbol: "arrow.triangle.branch", tint: .green),
    TabSpec(title: "Private configuration", file: "proxy-local", keys: ["@all"], symbol: "lock.fill", tint: .gray),
  ]),
  GroupSpec(id: "sync", name: "File sync", description: "Keep configuration files in sync across your folders.", tabs: [
    TabSpec(title: "File mappings", file: "sync", keys: ["file"], symbol: "folder.fill", tint: .cyan),
    TabSpec(title: "Path variables", file: "sync", keys: ["variable"], symbol: "curlybraces", tint: .orange),
  ]),
  GroupSpec(id: "language", name: "Localization", description: "Configure app resources and menu translation mappings.", tabs: [
    TabSpec(title: "Resources", file: "localization", keys: ["resources"], symbol: "shippingbox.fill", tint: .brown),
    TabSpec(title: "Menu translations", file: "localization", keys: ["@other"], symbol: "character.bubble.fill", tint: .pink),
  ]),
]

let labels: [String: [String]] = [
  "bundleID": ["Applications"], "pollingInterval": ["Polling interval", "Interval between recurring tasks, in seconds"],
  "pasteboardFilter": ["Clipboard cleanup", "Match and remove extra text when copying"],
  "verificationFilter": ["Verification codes", "Message matching conditions and extraction rules"],
  "hyper": ["Modifier combinations", "Reuse modifier combinations with ${hyper.…} references"],
  "parameters": ["Interaction parameters", "Window movement steps and trackpad regions"],
  "remoteDesktopModifiers": ["Remote desktop modifiers", "Map modifiers for each remote desktop app"],
  "windowMoveStep": ["Window movement step", "Pixels"], "windowResizeStep": ["Window resize step", "Pixels"],
  "trackpadCornerSize": ["Trackpad corner region", "Proportion"], "hideWithoutWindow": ["Hide when no windows remain"],
  "quitWithoutWindow": ["Quit when no windows remain"], "windowSwitcherIgnore": ["Window switcher exclusions"],
  "forbidden": ["Blocked apps"], "terminateSilently": ["Apps to terminate silently"],
  "suspendHotkeysInRemoteDesktop": ["Pause shortcuts in remote desktop apps"], "menuBarItems": ["Menu bar refresh rules"],
  "inputSource": ["App input sources"], "defaultMusicAppForControlCenter": ["Default music apps"],
  "manageAndroidDevices": ["Android manager"], "androidDevices": ["Android devices"], "proxy": ["Automatic switching rules"],
  "variable": ["Path variables"], "file": ["File and folder mappings"], "resources": ["App resource locations"],
  "global": ["Global shortcuts"], "appkeys": ["App launch shortcuts"], "menubar": ["Menu bar shortcuts"],
  "shared": ["Shared shortcuts"], "mods": ["Modifiers"], "key": ["Key"], "daemon": ["Daemon"], "moveTo": ["Window placement"],
  "moveTowards": ["Move window"], "moveToSpace": ["Move to Space"], "moveToScreen": ["Move to screen"], "resize": ["Resize window"],
  "filter": ["Match text"], "extract": ["Extraction pattern"], "reloadHammerspoon": ["Reload configuration"],
  "toggleConsole": ["Show console"], "showHotkeys": ["Show shortcut overview"], "searchHotkeys": ["Search shortcuts"],
  "changing": ["Dynamic menu bar items"], "changeOnWindow": ["Menu bar items that change with windows"],
]
func labelText(_ key: String?) -> String? { key.flatMap { labels[$0]?.first } }
func helpText(_ key: String?) -> String? { key.flatMap { labels[$0].flatMap { $0.count > 1 ? $0[1] : nil } } }

let emptyConfiguration: [String: [String: JSON]] = [
  "misc": ["pollingInterval": .number(1), "pasteboardFilter": .array([]), "verificationFilter": .array([]), "proxy": .array([])],
  "keybindings": ["hyper": .object(JObject()), "parameters": .object(JObject()), "remoteDesktopModifiers": .object(JObject()),
                  "hotkeys.global": .object(JObject()), "hotkeys.appkeys": .array([]), "hotkeys.menubar": .object(JObject()),
                  "hotkeys.shared": .object(JObject())],
  "application": ["menuBarItems": .object(JObject()), "hideWithoutWindow": .array([]), "quitWithoutWindow": .array([]),
                  "windowSwitcherIgnore": .array([]), "forbidden": .array([]), "terminateSilently": .array([]),
                  "suspendHotkeysInRemoteDesktop": .array([]), "inputSource": .object(JObject()),
                  "defaultMusicAppForControlCenter": .array([]), "manageAndroidDevices": .string(""), "androidDevices": .array([])],
  "sync": ["variable": .object(JObject()), "file": .object(JObject())], "localization": ["resources": .object(JObject())],
]
let propertyDefaults: [(String, JSON)] = [
  ("persist", .bool(true)), ("background", .bool(true)), ("repeatable", .bool(true)), ("nonFrontmost", .bool(false)),
  ("windowFilter", .object(JObject())), ("menubarFilter", .bool(true)),
]
func propertyDefault(_ key: String) -> JSON? { propertyDefaults.first { $0.0 == key }?.1 }

let modifierNames = ["cmd": "command", "command": "command", "alt": "option", "option": "option", "ctrl": "control",
                     "control": "control", "shift": "shift", "fn": "fn"]
// Ordered so symbol-to-name parsing picks the canonical name first.
let keySymbols: [(String, String)] = [
  ("command", "⌘"), ("option", "⌥"), ("control", "⌃"), ("shift", "⇧"), ("fn", "🌐\u{FE0E}"), ("left", "←"), ("right", "→"),
  ("up", "↑"), ("down", "↓"), ("return", "↩"), ("enter", "⌤"), ("tab", "⇥"), ("escape", "⎋"), ("esc", "⎋"), ("space", "␣"),
  ("delete", "⌫"), ("forwarddelete", "⌦"), ("home", "↖"), ("end", "↘"), ("pageup", "⇞"), ("pagedown", "⇟"), ("capslock", "⇪"),
]
let proxyFiles: Set<String> = ["proxy", "proxy-local"]
let windowBehaviorKeys: Set<String> = ["hideWithoutWindow", "quitWithoutWindow", "windowSwitcherIgnore"]
let proxyConditionFields: [(String, String, JSON)] = [
  ("shell_command", "Shell command", .string("")), ("ssid", "Wi-Fi SSID", .array([])), ("etherNet", "Ethernet IP", .array([])),
]
let proxyEntryLabels = ["global": "Global", "pac": "PAC", "http": "HTTP", "https": "HTTPS", "socks5": "SOCKS5", "routing": "Routing"]

/// Turns identifiers such as "showCurrentWindowInfo" into "Show current window info".
func humanized(_ key: String) -> String {
  guard key.range(of: #"^[a-z0-9][A-Za-z0-9]*$"#, options: .regularExpression) != nil else { return key }
  let spaced = key
    // Numbers after a word start a new word, while key names such as F12 stay whole.
    .replacingOccurrences(of: #"(?<=[A-Za-z][a-z])([0-9])"#, with: " $1", options: .regularExpression)
    .replacingOccurrences(of: #"([0-9](?:st|nd|rd|th))([a-z])"#, with: "$1 $2", options: .regularExpression)
    // A word's single leading lowercase letter stays attached, as in iBar.
    .replacingOccurrences(of: #"(?<=[A-Za-z0-9][a-z0-9])([A-Z])"#, with: " $1", options: .regularExpression)
    // Plural acronyms such as URLs stay whole.
    .replacingOccurrences(of: #"([A-Z]+)([A-Z](?!s(?:[A-Z]|$))[a-z])"#, with: "$1 $2", options: .regularExpression)
  let words = spaced.split(separator: " ").enumerated().map { index, word -> String in
    let w = String(word)
    let core = w.count > 2 && w.hasSuffix("s") ? String(w.dropLast()) : w
    let acronym = core.count > 1 && core == core.uppercased() && core.rangeOfCharacter(from: .letters) != nil
    // Names such as iBar keep their capitals.
    let mixed = w.first?.isLowercase == true && w.contains { $0.isUppercase }
    if index == 0 { return mixed ? w : w.prefix(1).uppercased() + w.dropFirst() }
    return acronym || mixed ? w : w.lowercased()
  }
  return words.joined(separator: " ")
}

func isReference(_ text: String) -> Bool { text.range(of: #"^\$\{[^}]+\}$"#, options: .regularExpression) != nil }
func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

func scalarText(_ value: JSON?) -> String {
  switch value {
  case .string(let s)?: return s
  case .number(let n)?: return JSON.formatNumber(n)
  case .bool(let b)?: return b ? "true" : "false"
  case .null?: return "null"
  case .array(let a)?: return a.map { $0 == .null ? "" : scalarText($0) }.joined(separator: ",")
  case .object?: return "[object Object]"
  case nil: return ""
  }
}
func truthy(_ value: JSON?) -> Bool {
  switch value {
  case nil, .null?: return false
  case .string(let s)?: return !s.isEmpty
  case .number(let n)?: return n != 0 && !n.isNaN
  case .bool(let b)?: return b
  default: return true
  }
}

func keyDisplay(_ value: JSON?) -> String {
  guard let value else { return "" }
  if let a = value.array { return a.isEmpty ? "None" : a.map { keyDisplay($0) }.joined() }
  if value == .bool(false) { return "Disabled" }
  if value == .string("") { return "None" }
  let raw = scalarText(value)
  let canonical = modifierNames[raw.lowercased()] ?? raw.lowercased()
  return keySymbols.first { $0.0 == canonical }?.1 ?? raw
}
func keyRaw(_ value: JSON?) -> String {
  if let a = value?.array { return a.map { scalarText($0) }.joined(separator: " + ") }
  return value == nil ? "" : scalarText(value)
}

enum KeyKind { case key, modifiers }

func parseKeyField(_ text: String, kind: KeyKind, original: JSON?) throws -> JSON {
  let raw = trimmed(text)
  if isReference(raw) { return .string(raw) }
  if kind == .key { return .string(keySymbols.first { $0.1 == raw || $0.1.unicodeScalars.first.map(String.init) == raw }?.0 ?? raw) }
  if raw == "false" || raw.lowercased() == "disabled" { return .bool(false) }
  if raw.isEmpty || raw.lowercased() == "none" { return original?.isArray == true ? .array([]) : .string("") }
  var expanded = raw.replacingOccurrences(of: "\u{FE0E}", with: "").replacingOccurrences(of: "\u{FE0F}", with: "")
  for (symbol, name) in [("⌘", "command"), ("⌥", "option"), ("⌃", "control"), ("⇧", "shift"), ("🌐", "fn")] {
    expanded = expanded.replacingOccurrences(of: symbol, with: " \(name) ")
  }
  let tokens = expanded.components(separatedBy: CharacterSet(charactersIn: "+,").union(.whitespacesAndNewlines)).filter { !$0.isEmpty }
  let values = try tokens.map { token -> String in
    if let name = modifierNames[token.lowercased()] { return name }
    if isReference(token) || token.range(of: #"^[Ff]\d{1,2}$"#, options: .regularExpression) != nil { return token }
    throw ConfigError("Use modifier names, symbols, or a Hyper reference.")
  }
  if Set(values).count != values.count { throw ConfigError("Each modifier can only appear once.") }
  return original?.isArray == true || values.count > 1 ? .array(values.map { .string($0) }) : .string(values[0])
}

func isCompactList(_ value: JSON?) -> Bool {
  guard let a = value?.array, !a.isEmpty, a.count <= 6 else { return false }
  return a.allSatisfy { v in
    switch v { case .string, .number, .bool: return scalarText(v).count <= 28; default: return false }
  } && a.map { scalarText($0) }.joined(separator: " ").count <= 72
}
func configurationRows(_ value: JSON?) -> Int {
  guard let value, value.isContainer, !isCompactList(value) else { return 1 }
  return value.childKeys.reduce(0) { $0 + configurationRows(value[$1]) }
}

// MARK: - Application identity

@MainActor final class AppIdentity {
  static let shared = AppIdentity()
  private var icons: [String: NSImage?] = [:]
  private var names: [String: String?] = [:]
  private var urls: [String: URL?] = [:]
  var configuredNames: [String: String] = [:]

  static func looksLikeBundleID(_ s: String) -> Bool {
    s.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression) != nil
  }
  // Some bundle IDs have no dot, such as JabRef's, so any ID is looked up.
  private func url(_ id: String) -> URL? {
    if let cached = urls[id] { return cached }
    let result = id.isEmpty ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    urls[id] = result
    return result
  }
  /// Whether the text names an application: an installed app's bundle ID, or one shaped like a bundle ID.
  func isApplication(_ id: String) -> Bool { AppIdentity.looksLikeBundleID(id) || url(id) != nil }

  func icon(_ id: String) -> NSImage? {
    if let cached = icons[id] { return cached }
    let image = url(id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    icons[id] = image
    return image
  }
  func name(_ id: String) -> String? {
    if let configured = configuredNames[id] { return configured }
    if let cached = names[id] { return cached }
    var result: String?
    if let url = url(id), let bundle = Bundle(url: url) {
      result = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
        ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
        ?? bundle.infoDictionary?["CFBundleName"] as? String
        ?? url.deletingPathExtension().lastPathComponent
    }
    names[id] = result
    return result
  }
  /// Lists apps that are installed first; entries for missing apps keep their relative order at the end.
  func installedFirst<T>(_ items: [T], _ id: (T) -> String?) -> [T] {
    let missing = items.map { item in
      id(item).map { url($0) == nil } ?? false
    }
    return items.indices.filter { !missing[$0] }.map { items[$0] } + items.indices.filter { missing[$0] }.map { items[$0] }
  }
}

@MainActor func applicationTitle(_ text: String) -> String {
  let regex = try! NSRegularExpression(pattern: #"\b[a-zA-Z][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)+\b"#)
  let ns = text as NSString
  var result = ""
  var offset = 0
  for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
    result += ns.substring(with: NSRange(location: offset, length: match.range.location - offset))
    let id = ns.substring(with: match.range)
    result += AppIdentity.shared.name(id) ?? id
    offset = match.range.location + match.range.length
  }
  return result + ns.substring(from: offset)
}

// MARK: - Sheets

struct JSONEditorRequest: Identifiable {
  let id = UUID()
  var title: String
  var help = "Accepts strings, arrays, and objects. Click Save changes after applying edits."
  var text: String
  var apply: @MainActor (JSON) throws -> Void
}
struct PropertyRequest: Identifiable {
  let id = UUID()
  var title: String, nameLabel: String, name: String, suggestions: [String], valueText: String, actionTitle: String
  var file: String, path: Path, entry: Bool, translation: String?
}
/// A pushed page for a nested object or list.
struct NodeRoute: Hashable, Identifiable {
  let file: String, path: Path, title: String
  var id: String { file + "/" + path.joined }
}
enum NavigationContext { case root, page, sheet }
struct ConfirmRequest: Identifiable {
  let id = UUID()
  var title: String, message: String, actionTitle: String
  var action: @MainActor () -> Void
}
struct PathContext {
  var requiredType: String? = nil, parentDirectory = false, applicationID: String? = nil, fileURL = false
}
struct SectionSpec: Identifiable {
  let file: String, path: Path, value: JSON?
  var missing: Bool { value == nil }
  var id: String { file + "/" + path.joined }
}
struct FileState { var raw: String?, baseline: JSON?, error: String?, missing = false }

// MARK: - Store

@MainActor @Observable final class Store {
  var files: [String: FileState] = [:]
  var drafts: [String: JSON] = [:]
  var invalid: [String: String] = [:]
  var selection: TabID? = TabID(group: 0, tab: 0)
  var pending: String?
  var reloading = false
  var loaded = false
  var status: String?
  var statusIsError = false
  var expandedApps: Set<String> = []
  var collapsed: Set<String> = []
  var disclosure: [String: Bool] = [:]
  var proxyApps: [String: Bool] = [:]
  var appBindings: [String: JSON] = [:]

  var jsonEditor: JSONEditorRequest?
  var property: PropertyRequest?
  var route: [NodeRoute] = []
  /// Details opened from a pushed page: the sheet's root page and the pages pushed inside it.
  var sheet: NodeRoute?
  var sheetPath: [NodeRoute] = []
  /// A purpose-built editor sheet, such as a verification rule or a proxy client.
  var panel: Panel?
  var prompt: PromptRequest?
  var confirm: ConfirmRequest?

  @ObservationIgnored var send: ([String: Any]) -> Void = { _ in }
  @ObservationIgnored private var nextRequest = 0
  @ObservationIgnored private var browseCallbacks: [String: (String, String) -> Void] = [:]
  @ObservationIgnored private var appCallbacks: [String: (String, String?) -> Void] = [:]
  @ObservationIgnored private var statusTimer: Timer?
  var browsing: Set<String> = []
  var configDirectory: String?
  @ObservationIgnored private var browseKeys: [String: String] = [:]

  var tabID: TabID { selection ?? TabID(group: 0, tab: 0) }
  var group: GroupSpec { groups[tabID.group] }
  var tab: TabSpec { group.tabs[tabID.tab] }
  var file: String { tab.file }

  // MARK: State

  func changed(_ name: String) -> Bool {
    guard let draft = drafts[name] else { return false }
    return draft != files[name]?.baseline
  }
  var dirtyNames: [String] { drafts.keys.filter(changed).sorted() }
  func hasInvalid(_ name: String) -> Bool { invalid.keys.contains { $0.hasPrefix(name + "/") } }
  var canSave: Bool { changed(file) && pending == nil && !hasInvalid(file) }
  var canDiscard: Bool { changed(file) && pending == nil }

  func value(_ name: String, _ path: Path) -> JSON? { drafts[name]?.at(path) }

  func setStatus(_ message: String?, error: Bool = false) {
    status = message; statusIsError = error
    statusTimer?.invalidate()
    // Informational messages fade; errors stay until the next action.
    if message != nil && !error {
      statusTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { if self?.statusIsError == false { withAnimation { self?.status = nil } } }
      }
    }
  }

  func mark() {
    if statusIsError { setStatus(nil) }
  }

  func assign(_ name: String, _ path: Path, _ value: JSON) throws {
    if name == "localization" { try validateTranslationValue(path, value) }
    guard var root = drafts[name] else { throw ConfigError("This configuration is no longer available.") }
    try root.assign(path, value)
    drafts[name] = root
  }
  func set(_ name: String, _ path: Path, _ value: JSON) {
    do { try assign(name, path, value); mark() } catch { setStatus(error.localizedDescription, error: true) }
  }
  func update(_ name: String, _ path: Path, _ value: JSON, invalidKey: String? = nil) {
    if let invalidKey { invalid[invalidKey] = nil }
    set(name, path, value)
  }
  func markInvalid(_ key: String, _ message: String) {
    invalid[key] = message
    setStatus(message, error: true)
  }
  func clearInvalid(_ key: String) { invalid[key] = nil }

  // MARK: Sections

  func sections(_ tab: TabSpec) -> [SectionSpec] {
    let name = tab.file
    guard let root = drafts[name], let object = root.object else { return [] }
    var result: [SectionSpec] = []
    for key in tab.keys {
      var paths: [Path]
      switch key {
      case "@all":
        var keys = object.keys
        if proxyFiles.contains(name) {
          keys = keys.enumerated().sorted { a, b in
            let x = proxyApps[a.element] == false ? 1 : 0, y = proxyApps[b.element] == false ? 1 : 0
            return x != y ? x < y : a.offset < b.offset
          }.map { $0.element }
        }
        paths = keys.map { [.k($0)] }
      case "@apps":
        let keys = (object["hotkeys"]?.object?.keys ?? []).filter { !["global", "appkeys", "menubar", "shared"].contains($0) }
        paths = (keys.filter { $0 == "browsers" } + keys.filter { $0 != "browsers" }).map { [.k("hotkeys"), .k($0)] }
      case "@other":
        var known = group.tabs.flatMap { $0.keys }.filter { !$0.hasPrefix("@") }
        if name == "misc" { known.append("proxy") }
        paths = object.keys.filter { !known.contains($0) }.map { [.k($0)] }
      default:
        paths = [key.split(separator: ".").map { .k(String($0)) }]
      }
      for path in paths { result.append(SectionSpec(file: name, path: path, value: root.at(path))) }
    }
    return result
  }

  // MARK: Titles

  func displayTitle(_ name: String, _ path: Path, _ value: JSON?, _ key: String) -> String {
    let isProxy = proxyFiles.contains(name)
    if name == "keybindings" && path.first(is: "hyper") && path.count == 2 { return path[1].description }
    if name == "keybindings" && path.first(is: "remoteDesktopModifiers") && path.at(-2)?.key == "map" { return keyDisplay(.string(key)) }
    if isProxy && key == "global" { return "Global" }
    if isProxy && key == "pac" { return "PAC" }
    if isProxy && ["http", "https", "socks5", "routing"].contains(key) { return key == "routing" ? "Routing" : key.uppercased() }
    if key.range(of: #"^\d+$"#, options: .regularExpression) == nil {
      if let text = labelText(key) { return text }
      let title = applicationTitle(key)
      // Keys under "entries" are user data (snippet triggers), not setting names.
      return title == key && !isProxy && path.dropLast().last?.key != "entries" ? humanized(key) : title
    }
    let parent = path.dropLast().compactMap { $0.key }.last
    let contexts = ["candidates": "Proxy candidate", "connections": "Connection rules", "bundleID": "App identifier",
                    "locations": "Location", "allowRoles": "Allowed window roles", "rejectTitles": "Excluded window titles",
                    "allowTitles": "Matching window titles", "allowURLs": "Matching URLs", "resources": "Resource location"]
    let context = labelText(parent) ?? parent.flatMap { contexts[$0] } ?? (name == "localization" ? "Translation mapping" : "Configuration entry")
    var details: [String]?
    var detail: String?
    func take(_ v: JSON?) -> Bool {
      guard truthy(v), let v else { return false }
      if let a = v.array { details = a.map { $0 == .null ? "" : scalarText($0) } } else { detail = scalarText(v) }
      return true
    }
    if let object = value?.object {
      let product: JSON? = truthy(object["product"])
        ? .string([object["vendor"], object["product"]].filter { truthy($0) }.map { scalarText($0) }.joined(separator: " ")) : nil
      _ = take(object["name"]) || take(object["title"]) || take(object["message"]) || take(object["bundleID"])
        || take(product) || take(object["filter"]) || take(object["locations"])
      if detail == nil && details == nil, let candidates = object["candidates"]?.array {
        details = candidates.compactMap { $0["name"] }.filter { truthy($0) }.map { scalarText($0) }
      }
      if detail == nil && details == nil, let map = object["map"]?.object {
        let remote = name == "keybindings" && path.first(is: "remoteDesktopModifiers")
        details = map.entries.map { remote ? keyDisplay(.string($0.0)) + " → " + keyDisplay($0.1) : $0.0 + " → " + scalarText($0.1) }
      }
      if detail == nil && details == nil { details = object.keys.map { labelText($0) ?? $0 } }
    } else if let a = value?.array {
      details = a.compactMap { $0.string }
    } else if let value, value != .null, value != .string("") {
      detail = scalarText(value)
    }
    if let details { detail = details.joined(separator: " / ") }
    guard let text = detail, !trimmed(text).isEmpty else { return context }
    var clean = trimmed(applicationTitle(text).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
    if clean.count > 90 { clean = String(clean.prefix(90)) + "…" }
    let launcher = name == "keybindings" && path.first(is: "hotkeys") && path.at(1)?.key == "appkeys" && path.count == 3
    return (launcher ? "" : context + " · ") + clean
  }

  // MARK: Field classification

  func keyFieldKind(_ name: String, _ path: Path) -> KeyKind? {
    guard name == "keybindings" else { return nil }
    if path.first(is: "remoteDesktopModifiers") && path.at(-2)?.key == "map" { return .key }
    if path.first(is: "hyper") && path.count == 2 {
      let hyperName = drafts["keybindings"]?["hyperKeyName"].flatMap { truthy($0) ? scalarText($0) : nil } ?? "hyper"
      return path[1].key == hyperName ? .key : .modifiers
    }
    if path.first(is: "hotkeys"), let last = path.last?.key, last == "mods" || last == "key" { return last == "mods" ? .modifiers : .key }
    return nil
  }
  func isShortcutValue(_ name: String, _ path: Path, _ value: JSON?) -> Bool {
    guard name == "keybindings", path.first(is: "hotkeys"), let object = value?.object else { return false }
    if object.has("mods") || object.has("key") { return true }
    return path.count == 3 && path[1].key != "menubar"
  }
  func supportsShortcutOptions(_ name: String, _ path: Path) -> Bool {
    name == "keybindings" && path.first(is: "hotkeys")
      && !["global", "appkeys", "menubar", "shared", "com.apple.controlcenter"].contains(path.at(1)?.key ?? "")
  }
  func isWindowBehaviorMapping(_ name: String, _ path: Path, _ value: JSON?) -> Bool {
    name == "application" && path.count == 2 && path[1].index != nil && windowBehaviorKeys.contains(path[0].key ?? "") && value?.isRecord == true
  }
  /// Keys a container shows, including placeholders for fields that are commonly missing.
  func displayKeys(_ name: String, _ path: Path, _ value: JSON) -> [PK] {
    var keys = value.childKeys
    if let object = value.object {
      if proxyFiles.contains(name) && path.last?.key == "global" && path.first?.key != "v2rayN" {
        for p in ["http", "https", "socks5"] where !object.has(p) { keys.append(.k(p)) }
      }
      if name == "keybindings" && path.first(is: "remoteDesktopModifiers") && path.count == 3 && !object.has("type") {
        keys.insert(.k("type"), at: 0)
      }
    }
    return keys
  }
  /// Whether a pushed page may offer to delete its entry.
  func isRemovable(_ name: String, _ path: Path) -> Bool {
    guard let parent = value(name, path.parent) else { return false }
    if parent.isArray { return true }
    let first = path.first?.key ?? ""
    if path.count == 1 { return proxyFiles.contains(name) || name == "localization" && first != "resources" || name == "application" }
    if name == "keybindings" && first == "hotkeys" { return path.count == 3 || (path.count == 2 && path[1].key != "browsers") }
    if name == "keybindings" && first == "remoteDesktopModifiers" { return path.count == 2 }
    if proxyFiles.contains(name) { return ["pac", "global", "condition"].contains(path.last?.key ?? "") }
    return path.last?.key == "condition" || (name == "application" && first == "inputSource")
      || (name == "localization" && first == "resources" && path.count == 2)
  }
  func open(_ name: String, _ path: Path, title: String) {
    route.append(NodeRoute(file: name, path: path, title: title))
  }
  /// The tab pushes a page; a pushed page opens details in a sheet; a sheet pushes within itself.
  func present(_ target: NodeRoute, from context: NavigationContext) {
    switch context {
    case .root: route.append(target)
    case .page: sheetPath = []; sheet = target
    case .sheet: sheetPath.append(target)
    }
  }
  func closeSheet() { sheet = nil; sheetPath = [] }
  func globalOnlyProxy(_ name: String, _ path: Path) -> Bool {
    proxyFiles.contains(name) && ["Clash Verge Rev", "MonoCloud"].contains(path.first?.key ?? "")
  }
  func isApplicationList(_ name: String, _ path: Path) -> Bool {
    let lists = ["hideWithoutWindow", "quitWithoutWindow", "windowSwitcherIgnore", "forbidden", "terminateSilently",
                 "suspendHotkeysInRemoteDesktop", "defaultMusicAppForControlCenter"]
    if name == "application" {
      if path.count == 1 && lists.contains(path[0].key ?? "") { return true }
      if path.count == 2 && path[0].key == "menuBarItems" && ["changing", "changeOnWindow"].contains(path[1].key ?? "") { return true }
    }
    return name == "keybindings" && path.first(is: "hotkeys") && path.at(1)?.key == "appkeys" && (path.count == 2 || path.last?.key == "bundleID")
  }
  func pathFieldContext(_ name: String, _ path: Path) -> PathContext? {
    if name == "sync" && path.first(is: "variable") && path.count == 2 { return PathContext() }
    if name == "sync" && path.first(is: "file") && (path.count == 2 || (path.count == 3 && path[2] == .i(0))) {
      return PathContext(requiredType: "directory", parentDirectory: true)
    }
    if name == "localization" && path.first(is: "resources") && (path.count == 2 || (path.count == 3 && path[2].index != nil)) {
      return PathContext(applicationID: path[1].key)
    }
    if name == "keybindings" && path.first(is: "hotkeys") && path.at(1)?.key == "appkeys"
        && (path.last?.key == "path" || (path.last?.index != nil && path.at(-2)?.key == "path")) { return PathContext() }
    if proxyFiles.contains(name) && path.last?.key == "pac" { return PathContext(fileURL: true) }
    return nil
  }
  func entryDescription(_ name: String, _ path: Path) -> String {
    if name == "keybindings" && path.count == 1 && path[0].key == "hyper" { return "Macro name" }
    if name == "application" && (path.isEmpty || path.first(is: "inputSource") || isWindowBehaviorMapping(name, path, .object(JObject()))) { return "Application bundle ID" }
    if name == "keybindings" && path.first(is: "hotkeys") { return path.count == 1 ? "Application bundle ID" : "Shortcut action ID" }
    if name == "keybindings" && path.first(is: "remoteDesktopModifiers") && path.count == 1 { return "Application bundle ID" }
    if name == "localization" && (path.isEmpty || path.first(is: "resources")) { return "Application bundle ID" }
    if name == "sync" && path.first(is: "file") { return "Source path" }
    if name == "sync" && path.first(is: "variable") { return "Variable name" }
    if proxyFiles.contains(name) && path.isEmpty { return "Proxy name" }
    return "Entry name"
  }
  func entryInitialValue(_ name: String, _ path: Path, _ key: String?) -> JSON {
    if name == "keybindings" && path.count == 1 && path[0].key == "hyper" { return .array([]) }
    if name == "application" && path.first(is: "inputSource") && path.count == 1 { return .array([]) }
    if name == "keybindings" && path.first(is: "remoteDesktopModifiers") { return path.last?.key == "map" ? .string("command") : .array([]) }
    if name == "sync" || (name == "localization" && path.first(is: "resources")) { return .string("") }
    if name == "keybindings" && path.first(is: "hotkeys") { return .object(JObject()) }
    if let key, key.hasPrefix("allow") || key.hasPrefix("reject") { return .array([]) }
    if let key, let value = propertyDefault(key) { return value }
    return .object(JObject())
  }
  /// Entry flows that start by choosing an application; proxy entries map to their proxy name.
  func entryNeedsApplication(_ name: String, _ path: Path) -> (needed: Bool, proxy: Bool) {
    let proxy = proxyFiles.contains(name) && path.isEmpty
    return (proxy || entryDescription(name, path) == "Application bundle ID", proxy)
  }

  // MARK: Editors

  func editJSON(_ title: String, _ value: JSON?, apply: @escaping @MainActor (JSON) throws -> Void) {
    jsonEditor = JSONEditorRequest(title: title, text: (value ?? .null).stringify(), apply: apply)
  }
  func editValue(_ name: String, _ path: Path, title: String, fallback: JSON? = nil) {
    editJSON(title, value(name, path) ?? fallback) { [unowned self] v in try assign(name, path, v); mark() }
  }
  func confirmAction(_ title: String, _ message: String, action: String, _ fn: @escaping @MainActor () -> Void) {
    confirm = ConfirmRequest(title: title, message: message, actionTitle: action, action: fn)
  }
  func configureMissingSection(_ s: SectionSpec) {
    let proposed = emptyConfiguration[s.file]?[s.path.strings.joined(separator: ".")] ?? .object(JObject())
    editJSON(displayTitle(s.file, s.path, proposed, s.path.last?.description ?? ""), proposed) { [unowned self] v in
      try assign(s.file, s.path, v); mark()
    }
  }

  func openEntryEditor(_ name: String, _ path: Path, title: String, applicationID: String) {
    if let current = value(name, path), !current.isRecord { setStatus("Entries can only be added to an object.", error: true); return }
    property = PropertyRequest(title: "Add entry · " + title, nameLabel: entryDescription(name, path), name: applicationID,
                               suggestions: [], valueText: entryInitialValue(name, path, nil).stringify(), actionTitle: "Add entry",
                               file: name, path: path, entry: true, translation: nil)
  }
  func openPropertyEditor(_ name: String, _ path: Path, title: String) {
    if name == "keybindings" && path.first(is: "hotkeys") && path.at(1)?.key == "com.apple.controlcenter" { return }
    guard let current = value(name, path)?.object else {
      setStatus("This shortcut is no longer available. Close the editor and refresh the page.", error: true); return
    }
    let available = propertyDefaults.map { $0.0 }.filter { !current.has($0) }
    property = PropertyRequest(title: "Add property · " + title, nameLabel: "Property name", name: available.first ?? "",
                               suggestions: available, valueText: (available.first.flatMap(propertyDefault) ?? .string("")).stringify(),
                               actionTitle: "Add property", file: name, path: path, entry: false, translation: nil)
  }
  func openTranslationEntry(_ name: String, _ path: Path, direction: String) {
    property = PropertyRequest(title: "Add " + translationBlockName(direction), nameLabel: direction == "forward" ? "Source text" : "Localized text",
                               name: "", suggestions: [], valueText: "\"\"", actionTitle: "Add entry",
                               file: name, path: path, entry: true, translation: direction)
  }
  func propertyNameChanged(_ request: inout PropertyRequest) {
    guard request.translation == nil else { return }
    let key = trimmed(request.name)
    if request.entry { request.valueText = entryInitialValue(request.file, request.path, key).stringify() }
    else if let value = propertyDefault(key) { request.valueText = value.stringify() }
  }
  func commitProperty(_ request: PropertyRequest) throws {
    let key = trimmed(request.name)
    if let direction = request.translation {
      if key.isEmpty { throw ConfigError("Enter the text to translate.") }
      var block = translationBlocks(value(request.file, request.path))[direction == "forward" ? 1 : 0]
      if block.has(key) { throw ConfigError("This translation already exists. Edit its existing value.") }
      block[key] = try JSONParser.parse(request.valueText)
      try writeTranslationBlock(request.file, request.path, direction, block)
      mark(); return
    }
    let current = value(request.file, request.path)
    if !(current?.isRecord ?? false) && !(request.entry && current == nil) { throw ConfigError("This configuration is no longer available.") }
    if key.isEmpty { throw ConfigError("Enter a property name.") }
    if current?.object?.has(key) == true { throw ConfigError("This entry already exists. Edit the existing value instead.") }
    let parsed = try JSONParser.parse(request.valueText)
    if !request.entry, propertyDefault(key)?.bool != nil, parsed.bool == nil { throw ConfigError("This property requires true or false.") }
    try assign(request.file, request.path.appending(key), parsed)
    mark()
  }

  func addLocalizationResource(_ name: String, _ path: Path, title: String = "Add resource") {
    editJSON(title, .string("")) { [unowned self] v in
      guard (v.string.map { !trimmed($0).isEmpty } ?? false) || v.isRecord else {
        throw ConfigError("Enter a resource path or resource definition object.")
      }
      let current = value(name, path)
      let next: JSON = current?.array.map { .array($0 + [v]) } ?? (current == nil ? .array([v]) : .array([current!, v]))
      try assign(name, path, next); mark()
    }
  }

  func openArrayEntry(_ name: String, _ path: Path, applicationID: String? = nil) {
    var initial: JSON = .string("")
    let isAppKeys = name == "keybindings" && path.first(is: "hotkeys") && path.at(1)?.key == "appkeys"
    if isAppKeys { initial = .object(JObject([("mods", .array([])), ("key", .string("")), ("bundleID", .string(""))])) }
    else if name == "keybindings" && path.first(is: "remoteDesktopModifiers") { initial = .object(JObject([("map", .object(JObject()))])) }
    else if name == "misc" && path.first(is: "verificationFilter") { initial = .object(JObject([("filter", .array([])), ("extract", .string(""))])) }
    else if name == "misc" && path.last?.key == "proxy" { initial = .object(JObject([("candidates", .array([]))])) }
    else if path.last?.key == "candidates" { initial = .object(JObject([("name", .string("")), ("mode", .string("pac"))])) }
    // Hammerspoon reads phones as [product, vendor].
    else if name == "application" && path.first(is: "androidDevices") { initial = .array([.string(""), .string("")]) }
    else if let first = value(name, path)?[0] {
      switch first {
      case .object: initial = .object(JObject())
      case .array: initial = .array([])
      case .number: initial = .number(0)
      case .bool: initial = .bool(false)
      default: break
      }
    }
    if let id = applicationID, !id.isEmpty {
      if var object = initial.object, object.has("bundleID") { object["bundleID"] = .string(id); initial = .object(object) } else { initial = .string(id) }
    }
    editJSON("Add entry", initial) { [unowned self] v in
      if name == "localization" && !path.first(is: "resources") && path.at(1) == .i(1) && path.count == 3 && v.string == nil {
        throw ConfigError("Each localized result must be a string.")
      }
      if name == "application" && path.first(is: "inputSource") && trimmed(v.string ?? "").isEmpty {
        throw ConfigError("Enter a non-empty input source identifier.")
      }
      if name == "localization" && path.first(is: "resources") && path.count == 2 && !(!trimmed(v.string ?? "").isEmpty || v.isRecord) {
        throw ConfigError("Enter a resource path or resource definition object.")
      }
      if isAppKeys {
        let o = v.object
        if o == nil || trimmed(o?["key"]?.string ?? "").isEmpty || (o?["mods"]?.isArray != true && o?["mods"]?.string == nil) {
          throw ConfigError("Set a key and modifiers for the app launcher entry.")
        }
      }
      let current = value(name, path)
      if current != nil && current?.isArray != true { throw ConfigError("This list is no longer available.") }
      try assign(name, path, .array((current?.array ?? []) + [v])); mark()
    }
  }

  func openProxyEntry(_ name: String, _ path: Path, key: String) {
    let mode = key == "global", v2PAC = key == "pac" && path.first?.key == "v2rayN"
    let initial: JSON = v2PAC ? .object(JObject([("routing", .string(""))]))
      : mode ? .object(JObject([("http", .string("")), ("https", .string("")), ("socks5", .string(""))])) : .string("")
    editJSON("Add " + (proxyEntryLabels[key] ?? key), initial) { [unowned self] v in
      guard let current = value(name, path)?.object else { throw ConfigError("This proxy configuration is no longer available.") }
      if current.has(key) { throw ConfigError("This entry already exists.") }
      if mode && !(["http", "https", "socks5"].allSatisfy { !trimmed(v[$0]?.string ?? "").isEmpty }) {
        throw ConfigError("Set http, https, and socks5 addresses.")
      }
      if !mode && !v2PAC && v.string == nil { throw ConfigError("Enter a string value.") }
      if path.first?.key == "v2rayN" && ((key == "pac" && trimmed(v["routing"]?.string ?? "").isEmpty)
          || (path.last?.key == "pac" && key == "routing" && trimmed(v.string ?? "").isEmpty)) {
        throw ConfigError("Routing is required in v2rayN PAC mode.")
      }
      try assign(name, path.appending(key), v); mark()
    }
  }
  func proxyEntryNames(_ name: String, _ path: Path, _ value: JSON) -> [String]? {
    guard proxyFiles.contains(name) else { return nil }
    if ["global", "pac"].contains(path.last?.key ?? "") && path.count >= 2 {
      return ["http", "https", "socks5"] + (path.first?.key == "v2rayN" ? ["routing"] : [])
    }
    let client = self.value(name, [path[0]])
    let locations = client?["locations"]?.array
    if (path.count == 1 && value["locations"]?.isArray != true)
        || (path.count == 2 && locations?.contains(.string(path[1].key ?? "")) == true) {
      return path.first?.key == "v2rayN" ? ["pac"] : ["pac", "global"]
    }
    return nil
  }

  func openShortcutOptions(_ name: String, _ path: Path, title: String) {
    open(name, path, title: title)
  }
  func openAppLaunchConfiguration(_ name: String, _ path: Path, title: String) {
    open(name, path, title: title)
  }

  func deleteEntry(_ name: String, _ path: Path) {
    guard let key = path.last, var root = drafts[name], let parent = root.at(path.parent), parent[key] != nil else { return }
    let prefix = name + "/" + path.parent.joined + (path.count > 1 ? "/" : "")
    if let index = key.index, parent.isArray {
      var updated: [String: String] = [:]
      for (entry, message) in invalid {
        guard entry.hasPrefix(prefix) else { updated[entry] = message; continue }
        var parts = entry.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let i = Int(parts[0]) else { updated[entry] = message; continue }
        if i == index { continue }
        if i > index { parts[0] = String(i - 1) }
        updated[prefix + parts.joined(separator: "/")] = message
      }
      invalid = updated
    } else {
      let removed = name + "/" + path.joined
      invalid = invalid.filter { $0.key != removed && !$0.key.hasPrefix(removed + "/") }
    }
    root.remove(path)
    drafts[name] = root
    // Leave pages whose entry no longer exists.
    if let gone = route.firstIndex(where: { $0.file == name && value(name, $0.path) == nil }) { route.removeSubrange(gone...) }
    if let sheet, sheet.file == name, value(name, sheet.path) == nil { closeSheet() }
    if let gone = sheetPath.firstIndex(where: { $0.file == name && value(name, $0.path) == nil }) { sheetPath.removeSubrange(gone...) }
    mark()
  }

  // MARK: Named mappings

  func renameReferences(_ config: JSON, _ old: String, _ new: String, namespace: String = "") throws -> JSON {
    let oldRef = "${" + namespace + old + "}", newRef = "${" + namespace + new + "}"
    func rewrite(_ value: JSON) throws -> JSON {
      switch value {
      case .string(let s): return .string(s.replacingOccurrences(of: oldRef, with: newRef))
      case .array(let a): return .array(try a.map(rewrite))
      case .object(let o):
        var result = JObject()
        for (key, child) in o.entries {
          let renamed = key.replacingOccurrences(of: oldRef, with: newRef)
          if result.has(renamed) { throw ConfigError("Renaming would create duplicate configuration entries.") }
          result[renamed] = try rewrite(child)
        }
        return .object(result)
      default: return value
      }
    }
    return try rewrite(config)
  }
  func pathVariableReferenced(_ key: String) -> Bool {
    let reference = "${" + key + "}"
    guard var sync = drafts["sync"]?.object else { return false }
    var variables = sync["variable"]?.object ?? JObject()
    variables[key] = nil
    sync["variable"] = .object(variables)
    func scan(_ value: JSON) -> Bool {
      switch value {
      case .string(let s): return s.contains(reference)
      case .array(let a): return a.contains(where: scan)
      case .object(let o): return o.entries.contains { $0.0.contains(reference) || scan($0.1) }
      default: return false
      }
    }
    return scan(.object(sync))
  }
  func validateMappingName(_ name: String, _ path: Path, _ text: String) throws -> String {
    let variable = name == "sync" && path.first(is: "variable"), macro = name == "keybindings" && path.first(is: "hyper")
    let key = trimmed(text), old = path.last?.key ?? ""
    if key.isEmpty { throw ConfigError(macro ? "Enter a macro name." : variable ? "Enter a variable name." : "Enter a source path.") }
    if macro && old == "hyper" && key != old { throw ConfigError("The hyper macro cannot be renamed.") }
    if macro && key.range(of: "[.{}]", options: .regularExpression) != nil { throw ConfigError("Macro names cannot contain dots or braces.") }
    guard let parent = value(name, path.parent)?.object, parent.has(old) else { throw ConfigError("This mapping is no longer available.") }
    if key != old && parent.has(key) {
      throw ConfigError(macro ? "This macro name already exists." : variable ? "This variable name already exists." : "This source path already has a mapping.")
    }
    return key
  }
  func renameMapping(_ name: String, _ path: Path, to text: String) throws {
    let key = try validateMappingName(name, path, text), old = path.last?.key ?? ""
    guard key != old, var parent = value(name, path.parent)?.object, var root = drafts[name]?.object else { return }
    parent.rename(old, to: key)
    if name == "keybindings" && path.first(is: "hyper") {
      root["hyper"] = .object(parent)
      guard var updated = try renameReferences(.object(root), old, key, namespace: "hyper.").object else { return }
      let primary = drafts[name]?["hyperKeyName"].flatMap { truthy($0) ? scalarText($0) : nil } ?? "hyper"
      if old == primary { updated["hyperKeyName"] = key == "hyper" ? nil : .string(key) }
      drafts[name] = .object(updated)
    } else if name == "sync" && path.first(is: "variable") {
      root["variable"] = .object(parent)
      drafts[name] = try renameReferences(.object(root), old, key)
    } else {
      try assign(name, path.parent, .object(parent))
    }
    mark()
  }

  // MARK: Modifier mappings

  func remoteModifier(_ text: String) throws -> String {
    let key = try parseKeyField(text, kind: .key, original: .string(text)).string ?? text
    guard let canonical = modifierNames[key.lowercased()] else { throw ConfigError("Enter one modifier: command, option, control, shift, or fn.") }
    return canonical
  }
  func renameModifierSource(_ name: String, _ mapPath: Path, from source: String, to text: String) throws -> String {
    guard let map = value(name, mapPath)?.object, map.has(source) else { throw ConfigError("This modifier mapping is no longer available.") }
    let next = text == source ? source : try remoteModifier(text)
    guard next != source else { return source }
    let duplicate = map.keys.contains { key in
      key != source && (modifierNames[((try? parseKeyField(key, kind: .key, original: .string(key)))?.string ?? key).lowercased()] ?? key) == next
    }
    if duplicate { throw ConfigError("This source modifier already has a mapping.") }
    var replacement = map
    replacement.rename(source, to: next)
    try assign(name, mapPath, .object(replacement))
    return next
  }

  // MARK: Translations

  func translationBlockName(_ direction: String) -> String { direction == "forward" ? "Forward localization" : "Reverse localization" }
  /// [reverse, forward]; a compact object is a reverse map.
  func translationBlocks(_ value: JSON?) -> [JObject] {
    let reverse = value?.object ?? value?[0]?.object ?? JObject()
    let forward = value?.isArray == true ? (value?[1]?.object ?? JObject()) : JObject()
    return [reverse, forward]
  }
  func validateTranslationBlock(_ value: JSON, _ direction: String) throws {
    guard let object = value.object else { throw ConfigError("Use a JSON object containing translation mappings.") }
    for (_, translated) in object.entries {
      if translated.string != nil { continue }
      if direction == "forward", let a = translated.array, a.allSatisfy({ $0.string != nil }) { continue }
      throw ConfigError(direction == "forward" ? "Translations must be strings or lists of strings." : "Reverse translations must be strings.")
    }
  }
  func validateTranslationValue(_ path: Path, _ value: JSON) throws {
    guard let first = path.first, first.key != "resources" else { return }
    let app = drafts["localization"]?[first]
    let paired = app?.isArray == true
    if (paired && path.count == 3) || (app?.isRecord == true && path.count == 2) {
      try validateTranslationBlock(.object(JObject([(path.last!.description, value)])), paired && path[1] == .i(1) ? "forward" : "reverse")
    }
  }
  func writeTranslationBlock(_ name: String, _ path: Path, _ direction: String, _ block: JObject) throws {
    try validateTranslationBlock(.object(block), direction)
    let current = value(name, path)
    if direction == "reverse" && current?.isArray != true { try assign(name, path, .object(block)); return }
    let blocks = translationBlocks(current)
    var updated = current?.array ?? [.object(blocks[0]), .object(blocks[1])]
    while updated.count < 2 { updated.append(.object(JObject())) }
    if !updated[0].isRecord { updated[0] = .object(JObject()) }
    if !updated[1].isRecord { updated[1] = .object(JObject()) }
    updated[direction == "reverse" ? 0 : 1] = .object(block)
    try assign(name, path, .array(updated))
  }

  // MARK: Hammerspoon messages

  func load() { send(["action": "load"]) }
  func readAgain() {
    if dirtyNames.isEmpty { load(); return }
    confirmAction("Refresh configuration", "Discard all unsaved changes and read the latest configuration from disk.", action: "Discard & Refresh") { [unowned self] in load() }
  }
  func discard() {
    let name = file
    confirmAction("Discard changes", "Restore \(name).json to its last loaded or saved state.", action: "Discard") { [unowned self] in
      if let raw = files[name]?.raw, let value = try? JSONParser.parse(raw) { drafts[name] = value }
      invalid = invalid.filter { !$0.key.hasPrefix(name + "/") }
      setStatus("Changes discarded")
    }
  }
  func requiredFieldsMissing(_ name: String) -> Bool {
    guard proxyFiles.contains(name), let client = drafts[name]?["v2rayN"] else { return false }
    let blocks = [client] + (client["locations"]?.array ?? []).compactMap { $0.string.flatMap { client[$0] } }
    return blocks.contains { block in
      if let pac = block["pac"]?.object, pac.has("routing") { return trimmed(pac["routing"]?.string ?? "").isEmpty }
      return false
    }
  }
  func save() {
    let name = file
    guard pending == nil, changed(name) else { return }
    if hasInvalid(name) || requiredFieldsMissing(name) { setStatus("Correct invalid inputs before saving.", error: true); return }
    guard let draft = drafts[name] else { return }
    pending = name
    setStatus("Saving…")
    send(["action": "save", "name": name, "raw": draft.stringify() + "\n"])
  }
  func reload() {
    let dirty = dirtyNames
    if !dirty.isEmpty { setStatus("Save or discard changes in these files first: " + dirty.joined(separator: ", "), error: true); return }
    reloading = true
    send(["action": "reload"])
  }
  func browsePath(current: String, context: PathContext, key: String, completion: @escaping (String, String) -> Void) {
    nextRequest += 1
    let id = String(nextRequest)
    browseCallbacks[id] = completion
    browseKeys[id] = key
    browsing.insert(key)
    var message: [String: Any] = ["action": "browsePath", "id": id, "current": current, "parentDirectory": context.parentDirectory,
                                  "variables": drafts["sync"]?["variable"]?.any ?? [String: Any]()]
    if let type = context.requiredType { message["requiredType"] = type }
    if let app = context.applicationID { message["applicationID"] = app }
    send(message)
  }
  func browseApplication(_ completion: @escaping (String, String?) -> Void) {
    nextRequest += 1
    let id = String(nextRequest)
    appCallbacks[id] = completion
    send(["action": "browseApplication", "id": id])
  }

  func receive(_ message: [String: Any]) {
    let id = message["id"] as? String ?? ""
    switch message["action"] as? String {
    case "applicationBrowsed":
      guard let callback = appCallbacks.removeValue(forKey: id) else { return }
      if let error = message["error"] as? String { setStatus(error, error: true); return }
      if message["cancelled"] as? Bool != true, let bundleID = message["bundleID"] as? String {
        callback(bundleID, message["proxyName"] as? String)
      }
    case "browsed":
      if let key = browseKeys.removeValue(forKey: id) { browsing.remove(key) }
      guard let callback = browseCallbacks.removeValue(forKey: id) else { return }
      if let error = message["error"] as? String { setStatus(error, error: true); return }
      if message["cancelled"] as? Bool != true, let path = message["path"] as? String { callback(path, message["kind"] as? String ?? "") }
    case "loaded":
      proxyApps = (message["proxyApps"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
      appBindings = (message["appBindings"] as? [String: Any] ?? [:]).mapValues { JSON(any: $0) }
      configDirectory = message["configdir"] as? String ?? configDirectory
      AppIdentity.shared.configuredNames = (message["appNames"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
      var loadedFiles: [String: FileState] = [:]
      var loadedDrafts: [String: JSON] = [:]
      for (name, entry) in message["files"] as? [String: Any] ?? [:] {
        let info = entry as? [String: Any] ?? [:]
        var state = FileState(raw: info["raw"] as? String, error: info["error"] as? String, missing: info["missing"] as? Bool ?? false)
        if let raw = state.raw {
          do {
            let value = try JSONParser.parse(raw)
            guard value.isRecord else { throw ConfigError("The root value must be an object") }
            loadedDrafts[name] = value; state.baseline = value
          } catch { state.error = "Invalid JSON: " + error.localizedDescription }
        }
        loadedFiles[name] = state
      }
      files = loadedFiles; drafts = loadedDrafts; invalid = [:]; loaded = true
      setStatus("Configuration loaded · Save, then reload to apply")
    case "saved":
      pending = nil
      if let error = message["error"] as? String { setStatus(error, error: true); return }
      if let name = message["name"] as? String, let raw = message["raw"] as? String {
        files[name] = FileState(raw: raw, baseline: try? JSONParser.parse(raw))
        setStatus("Saved with backup · Reload to apply")
      }
    case "reloadFailed":
      reloading = false
    default: break
    }
  }
}
