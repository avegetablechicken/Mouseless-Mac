// Shortcut display and recording. Values keep the configuration's existing forms:
// modifiers as "", a single name, a list, false, or a ${hyper.…} reference.
import AppKit
import SwiftUI

private let modifierOrder = ["fn", "shift", "control", "option", "command"]
private let specialKeys: [UInt16: String] = [
  36: "Return", 48: "tab", 49: "space", 51: "delete", 53: "escape", 117: "forwarddelete", 115: "home", 119: "end",
  116: "pageup", 121: "pagedown", 123: "left", 124: "right", 125: "down", 126: "up", 76: "enter",
  122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
  103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
]
// Keys whose events always carry the Function flag.
private let functionKeys: Set<UInt16> = [115, 116, 117, 119, 121, 123, 124, 125, 126, 122, 120, 99, 118, 96, 97, 98, 100, 101,
                                         109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

private func modifiers(_ flags: NSEvent.ModifierFlags, keyCode: UInt16? = nil) -> [String] {
  var names: [String] = []
  if flags.contains(.function) && !(keyCode.map(functionKeys.contains) ?? false) { names.append("fn") }
  if flags.contains(.shift) { names.append("shift") }
  if flags.contains(.control) { names.append("control") }
  if flags.contains(.option) { names.append("option") }
  if flags.contains(.command) { names.append("command") }
  return names.sorted { modifierOrder.firstIndex(of: $0)! < modifierOrder.firstIndex(of: $1)! }
}

private func keyName(_ event: NSEvent) -> String? {
  if let name = specialKeys[event.keyCode] { return name }
  guard let text = event.characters(byApplyingModifiers: []), !text.isEmpty,
        text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
  return text.uppercased()
}

/// Glyphs that read poorly on a keycap get their name instead.
func keyCapLabel(_ symbol: String) -> String { symbol == "␣" ? "Space" : symbol }

func modifierValue(_ names: [String], original: JSON?) -> JSON {
  if names.isEmpty { return original?.isArray == true ? .array([]) : .string("") }
  return original?.isArray == true || names.count > 1 ? .array(names.map { .string($0) }) : .string(names[0])
}

extension Store {
  /// Modifier macros a shortcut can reference, excluding the primary Hyper key.
  var modifierMacros: [(String, JSON)] {
    (drafts["keybindings"]?["hyper"]?.object?.entries ?? []).filter { keyFieldKind("keybindings", [.k("hyper"), .k($0.0)]) == .modifiers }
  }
  /// Name of the macro holding the Hyper key itself.
  var hyperKeyName: String {
    drafts["keybindings"]?["hyperKeyName"].flatMap { truthy($0) ? scalarText($0) : nil } ?? "hyper"
  }
  /// Whether a key value is the Hyper key, written out (F18) or as ${hyper.hyper}.
  func isHyperKey(_ key: JSON) -> Bool {
    if macroName(key) == hyperKeyName { return true }
    guard let text = key.string, !text.isEmpty,
          let hyper = drafts["keybindings"]?["hyper"]?[hyperKeyName]?.string, !isReference(hyper) else { return false }
    return text.lowercased() == hyper.lowercased()
  }
  /// Key label; the Hyper key shows as ✧ except in its own definition.
  func keyLabel(_ key: JSON, file: String? = nil, path: Path? = nil) -> String {
    let definition = file == "keybindings" && path == [.k("hyper"), .k(hyperKeyName)]
    return !definition && isHyperKey(key) ? "✧" : keyCapLabel(keyDisplay(key))
  }
  func macroName(_ value: JSON?) -> String? {
    guard let text = value?.string, isReference(text) else { return nil }
    let inner = text.dropFirst(2).dropLast()
    return inner.hasPrefix("hyper.") ? String(inner.dropFirst(6)) : nil
  }
  func validateModifierReferences(_ root: JSON) throws {
    guard let macros = root["hyper"]?.object else { return }
    for name in macros.keys {
      var visited = Set<String>()
      var current: String? = name
      while let key = current {
        guard visited.insert(key).inserted else { throw ConfigError("Modifier presets cannot contain circular references: \(key)") }
        current = macroName(macros[key])
      }
    }
  }

  func symbols(_ value: JSON?, visited: Set<String> = []) -> [String]? {
    switch value {
    case .array(let items)?: return items.map { keyDisplay($0) }
    case .string(let s)? where s.isEmpty: return []
    case .string(let s)? where isReference(s):
      // The Hyper key shows as ✧, matching Hotkey Search (Mod.Hyper.Symbol).
      if macroName(value) == hyperKeyName { return ["✧"] }
      guard let name = macroName(value), !visited.contains(name) else { return nil }
      return drafts["keybindings"]?["hyper"]?[name].flatMap { symbols($0, visited: visited.union([name])) }
    case .string?: return [keyDisplay(value)]
    default: return nil
    }
  }
}

/// Keycaps for a modifier value and key, with macro references shown by name.
struct BindingCaps: View {
  @Environment(Store.self) private var store
  let mods: JSON??
  let key: JSON??

  var body: some View {
    HStack(spacing: 6) {
      if let mods {
        if mods == .bool(false) {
          Text("Disabled").foregroundStyle(.secondary)
        } else if let symbols = store.symbols(mods), !symbols.isEmpty {
          KeyCaps(symbols: symbols)
        }
      }
      if let key {
        if let key, key != .string("") { KeyCaps(symbols: [store.keyLabel(key)]) }
      }
      if isEmpty { Text("Not set").foregroundStyle(.tertiary) }
    }
  }

  private var isEmpty: Bool {
    let noMods = mods == nil || mods! == nil || store.symbols(mods!)?.isEmpty == true
    let noKey = key == nil || key! == nil || key!! == .string("")
    return noMods && noKey && mods != .some(.bool(false)) && store.macroName(mods ?? nil) == nil
  }
}

/// A shortcut shown as text, as in System Settings. Clicking turns it into a field that
/// records the next key combination; the context menu offers macros and text editing.
struct ShortcutButton: View {
  @Environment(Store.self) private var store
  let file: String
  let title: String
  var modsPath: Path?
  var keyPath: Path?
  @State private var recording = false
  @State private var held: [String] = []
  @State private var peak: [String] = []
  @State private var monitors: [Any] = []
  @State private var editingText = false

  private var mods: JSON? { modsPath.flatMap { store.value(file, $0) } }
  private var key: JSON? { keyPath.flatMap { store.value(file, $0) } }
  private var invalid: Bool {
    [modsPath, keyPath].compactMap { $0 }.contains { store.invalid[file + "/" + $0.joined] != nil }
  }

  var body: some View {
    label
      .lineLimit(1)
      .padding(.horizontal, 7).padding(.vertical, 3)
      .frame(minWidth: 96, alignment: .trailing)
      .background {
        if recording {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2.5) }
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { if !recording { start() } }
      .contextMenu { menu }
      .popover(isPresented: $editingText, arrowEdge: .bottom) {
        ShortcutEditor(file: file, title: title, modsPath: modsPath, keyPath: keyPath).environment(store)
      }
      .help("Click to record a new shortcut")
      .accessibilityLabel(title)
      .accessibilityAddTraits(.isButton)
      .onDisappear(perform: stop)
  }

  @ViewBuilder private var label: some View {
    if recording {
      if held.isEmpty {
        Text(keyPath == nil ? "Press Modifiers" : "Type Shortcut").foregroundStyle(.secondary)
      } else {
        Text(held.map { keyDisplay(.string($0)) }.joined())
      }
    } else {
      let macro = store.macroName(mods)
      let symbols = (store.symbols(mods) ?? []).joined()
      // A macro that resolves to a key (the Hyper key) reads better by name.
      let modText = mods == .bool(false) ? "Disabled " : macro != nil && symbols.contains(where: { $0.isLetter || $0.isNumber })
        ? macro!.prefix(1).uppercased() + macro!.dropFirst() + " " : symbols
      let keyText = key.flatMap { $0 == .string("") ? nil : store.keyLabel($0, file: file, path: keyPath) } ?? ""
      if modText.isEmpty && keyText.isEmpty && macro == nil {
        Text(keyPath == nil && modsPath != nil ? "None" : "Not Set").foregroundStyle(.tertiary)
      } else {
        Text(modText + keyText).foregroundStyle(invalid ? Color.red : Color.primary)
      }
    }
  }

  @ViewBuilder private var menu: some View {
    Button("Record Shortcut") { start() }
    if let modsPath, !store.modifierMacros.isEmpty {
      Menu("Use Modifier Set") {
        Button("Hyper   ✧") { store.set(file, modsPath, .string("${hyper.\(store.hyperKeyName)}")) }
        Divider()
        ForEach(store.modifierMacros, id: \.0) { name, value in
          Button("\(name)   \((store.symbols(value) ?? []).joined())") { store.set(file, modsPath, .string("${hyper.\(name)}")) }
        }
      }
    }
    Button("Edit as Text…") { stop(); editingText = true }
    Divider()
    Button("Clear Shortcut", role: .destructive) { stop(); clear() }
  }

  private func clear() {
    if let modsPath { store.update(file, modsPath, modifierValue([], original: mods), invalidKey: file + "/" + modsPath.joined) }
    if let keyPath { store.update(file, keyPath, .string(""), invalidKey: file + "/" + keyPath.joined) }
  }

  private func start() {
    stop()
    recording = true; held = []; peak = []
    let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
      guard recording else { return event }
      handle(event)
      return nil
    }
    // Clicking anywhere else ends recording, like leaving a text field.
    let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
      stop(); return event
    }
    monitors = [keys, clicks].compactMap { $0 }
  }

  private func stop() {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors = []; recording = false; held = []; peak = []
  }

  private func handle(_ event: NSEvent) {
    if event.type == .flagsChanged {
      held = modifiers(event.modifierFlags)
      guard keyPath == nil, let modsPath else { return }
      if held.count >= peak.count { peak = held }
      // Modifier-only values commit when the keys are released.
      if held.isEmpty && !peak.isEmpty {
        store.update(file, modsPath, modifierValue(peak, original: mods), invalidKey: file + "/" + modsPath.joined)
        stop()
      }
      return
    }
    let names = modifiers(event.modifierFlags, keyCode: event.keyCode)
    if names.isEmpty && event.keyCode == 53 { stop(); return }                 // Escape cancels
    if names.isEmpty && event.keyCode == 51 && modsPath != nil { clear(); stop(); return }  // Delete clears
    guard let keyPath, let name = keyName(event) else { return }
    store.update(file, keyPath, .string(name), invalidKey: file + "/" + keyPath.joined)
    // A key pressed alone keeps a referenced modifier macro.
    if let modsPath, !(names.isEmpty && store.macroName(mods) != nil) {
      store.update(file, modsPath, modifierValue(names, original: mods), invalidKey: file + "/" + modsPath.joined)
    }
    stop()
  }
}

struct ShortcutEditor: View {
  @Environment(Store.self) private var store
  let file: String, title: String
  var modsPath: Path?
  var keyPath: Path?
  @State private var recording = false
  @State private var held: [String] = []
  @State private var peak: [String] = []
  @State private var monitor: Any?

  private var mods: JSON? { modsPath.flatMap { store.value(file, $0) } }
  private var prompt: String {
    keyPath == nil ? "Press the modifier keys" : modsPath == nil ? "Press a key" : "Type the new shortcut"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.headline).lineLimit(2)
      Button { recording.toggle() } label: {
        ZStack {
          if recording && held.isEmpty {
            Text(prompt).foregroundStyle(.secondary)
          } else if recording {
            KeyCaps(symbols: held.map { keyCapLabel(keyDisplay(.string($0))) })
          } else {
            BindingCaps(mods: modsPath.map { _ in mods }, key: keyPath.map { store.value(file, $0) })
          }
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .background {
          RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .textBackgroundColor))
            .overlay {
              RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(recording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: recording ? 2 : 1)
            }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(recording ? "Recording — click to stop" : "Click to record")

      if let modsPath, !store.modifierMacros.isEmpty {
        LabeledContent("Modifiers") {
          Picker("", selection: Binding(get: { store.macroName(mods) ?? "" }, set: { name in
            if name.isEmpty {
              store.set(file, modsPath, modifierValue((store.symbols(mods) ?? []).isEmpty ? [] : resolvedNames(), original: .array([])))
            } else {
              store.set(file, modsPath, .string("${hyper.\(name)}"))
            }
          })) {
            Text("Custom").tag("")
            Divider()
            Text("Hyper   ✧").tag(store.hyperKeyName)
            ForEach(store.modifierMacros, id: \.0) { name, value in
              Text("\(name)   \((store.symbols(value) ?? []).joined())").tag(name)
            }
          }
          .labelsHidden()
          .fixedSize()
        }
      }

      DisclosureGroup("Edit as Text", isExpanded: .constant(true)) {
        VStack(alignment: .leading, spacing: 8) {
          if let modsPath {
            LabeledContent("Modifiers") { KeyField(file: file, path: modsPath, value: mods, kind: .modifiers, title: "Modifiers", width: 170) }
          }
          if let keyPath {
            LabeledContent("Key") { KeyField(file: file, path: keyPath, value: store.value(file, keyPath), kind: .key, title: "Key", width: 170) }
          }
        }
        .padding(.top, 6)
      }
      .font(.callout)

      HStack {
        Button("Clear") {
          recording = false
          if let modsPath { store.set(file, modsPath, modifierValue([], original: mods)) }
          if let keyPath { store.set(file, keyPath, .string("")) }
        }
        Spacer()
        Button("Done") { recording = false; held = [] }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(width: 320)
    .onAppear(perform: start)
    .onDisappear(perform: stop)
  }

  private func resolvedNames() -> [String] {
    guard let macro = store.macroName(mods), let value = store.drafts["keybindings"]?["hyper"]?[macro] else { return [] }
    return value.array?.compactMap { $0.string.map { modifierNames[$0.lowercased()] ?? $0 } } ?? value.string.map { [modifierNames[$0.lowercased()] ?? $0] } ?? []
  }

  private func start() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
      guard recording else { return event }
      if event.type == .flagsChanged {
        held = modifiers(event.modifierFlags)
        if keyPath == nil {
          if held.count >= peak.count { peak = held }
          // Modifier-only values commit when the keys are released.
          if held.isEmpty && !peak.isEmpty, let modsPath {
            store.update(file, modsPath, modifierValue(peak, original: mods), invalidKey: file + "/" + modsPath.joined)
            peak = []; recording = false
          }
        }
        return nil
      }
      let names = modifiers(event.modifierFlags, keyCode: event.keyCode)
      if keyPath == nil { return nil }
      if event.keyCode == 53 && names.isEmpty && modsPath != nil { recording = false; held = []; return nil }
      guard let key = keyName(event) else { return nil }
      if let keyPath { store.update(file, keyPath, .string(key), invalidKey: file + "/" + keyPath.joined) }
      // A key pressed alone keeps a referenced modifier macro.
      if let modsPath, !(names.isEmpty && store.macroName(mods) != nil) {
        store.update(file, modsPath, modifierValue(names, original: mods), invalidKey: file + "/" + modsPath.joined)
      }
      held = []; recording = false
      return nil
    }
  }

  private func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}
