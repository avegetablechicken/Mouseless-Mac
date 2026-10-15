// Controls shared by the purpose-built pages: token fields, app lists, conditions,
// window filters, and catalogs read from the system (input sources, sounds).
import AppKit
import Carbon
import SwiftUI

// MARK: - Value helpers

extension Store {
  /// A string or list field read as a list.
  func stringList(_ file: String, _ path: Path) -> [String] {
    switch value(file, path) {
    case .string(let s)?: return s.isEmpty ? [] : [s]
    case .array(let a)?: return a.compactMap { $0.string }
    default: return []
    }
  }
  /// Writes a list back in the field's existing form: one item stays a plain string when it was one.
  func setStringList(_ file: String, _ path: Path, _ list: [String], removeWhenEmpty: Bool = false) {
    let original = value(file, path)
    if list.isEmpty && removeWhenEmpty { if original != nil { deleteEntry(file, path) }; return }
    if list.count == 1 && (original == nil || original?.string != nil) && original?.isArray != true {
      set(file, path, .string(list[0]))
    } else {
      set(file, path, .array(list.map { .string($0) }))
    }
  }
  func listBinding(_ file: String, _ path: Path, removeWhenEmpty: Bool = true) -> Binding<[String]> {
    Binding(get: { self.stringList(file, path) }, set: { self.setStringList(file, path, $0, removeWhenEmpty: removeWhenEmpty) })
  }
  func stringBinding(_ file: String, _ path: Path, removeWhenEmpty: Bool = false) -> Binding<String> {
    Binding(get: { self.value(file, path)?.string ?? "" }, set: { text in
      if text.isEmpty && removeWhenEmpty { if self.value(file, path) != nil { self.deleteEntry(file, path) } }
      else { self.set(file, path, .string(text)) }
    })
  }
  /// Optional switches are removed when off, so files only record what differs from the default.
  func flagBinding(_ file: String, _ path: Path, default fallback: Bool = false) -> Binding<Bool> {
    Binding(get: { self.value(file, path)?.bool ?? fallback }, set: { on in
      if on == fallback { if self.value(file, path) != nil { self.deleteEntry(file, path) } }
      else { self.set(file, path, .bool(on)) }
    })
  }
  func numberBinding(_ file: String, _ path: Path, default fallback: Double) -> Binding<Double> {
    Binding(get: { self.value(file, path)?.number ?? fallback }, set: { self.set(file, path, .number(($0 * 1000).rounded() / 1000)) })
  }
  func move(_ file: String, _ path: Path, from: Int, to: Int) {
    guard var items = value(file, path)?.array, items.indices.contains(from), items.indices.contains(to) else { return }
    items.swapAt(from, to)
    set(file, path, .array(items))
  }
  /// Renames an object key in place, rejecting empty and duplicate names.
  func renameKey(_ file: String, _ parent: Path, from old: String, to new: String) throws {
    let name = trimmed(new)
    guard name != old else { return }
    if name.isEmpty { throw ConfigError("Enter a name.") }
    guard var object = value(file, parent)?.object, object.has(old) else { throw ConfigError("This entry is no longer available.") }
    if object.has(name) { throw ConfigError("“\(name)” already exists.") }
    object.rename(old, to: name)
    try assign(file, parent, .object(object))
    mark()
  }
}

// MARK: - Prompt

struct PromptRequest: Identifiable {
  let id = UUID()
  var title: String
  var message = ""
  var label = ""
  var placeholder = ""
  var initial = ""
  var actionTitle = "Add"
  var monospaced = false
  /// Edits text that may contain line breaks: Return inserts one, Command-Return commits, and the text is kept as typed.
  var multiline = false
  var validate: @MainActor (String) -> String? = { _ in nil }
  var commit: @MainActor (String) -> Void
}

struct PromptSheet: View {
  @Environment(Store.self) private var store
  let request: PromptRequest
  @State private var text = ""
  @FocusState private var focused: Bool

  var body: some View {
    let error = text.isEmpty ? nil : request.validate(text)
    VStack(alignment: .leading, spacing: 14) {
      SheetHeader(title: request.title, message: request.message)
      VStack(alignment: .leading, spacing: 6) {
        if !request.label.isEmpty { Text(request.label).font(.callout.weight(.medium)) }
        if request.multiline {
          TextEditor(text: $text)
            .font(request.monospaced ? .system(.body, design: .monospaced) : .body)
            .scrollContentBackground(.hidden)
            .padding(5)
            .frame(height: 110)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .overlay(alignment: .topLeading) {
              if text.isEmpty {
                Text(request.placeholder).font(request.monospaced ? .system(.body, design: .monospaced) : .body)
                  .foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.vertical, 5).allowsHitTesting(false)
              }
            }
            .focused($focused)
        } else {
          TextField("", text: $text, prompt: Text(request.placeholder))
            .labelsHidden().textFieldStyle(.roundedBorder)
            .font(request.monospaced ? .system(.body, design: .monospaced) : .body)
            .focused($focused)
            .onSubmit(commit)
        }
      }
      ErrorText(text: error)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { store.prompt = nil }.keyboardShortcut(.cancelAction)
        Button(request.actionTitle, action: commit)
          .keyboardShortcut(request.multiline ? KeyboardShortcut(.return, modifiers: .command) : .defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(trimmed(text).isEmpty || error != nil)
      }
    }
    .padding(22)
    .frame(width: 440)
    .onAppear { text = request.initial; focused = true }
  }

  private func commit() {
    let value = request.multiline ? text : trimmed(text)
    guard !trimmed(value).isEmpty, request.validate(value) == nil else { return }
    store.prompt = nil
    request.commit(value)
  }
}

extension Store {
  func ask(_ request: PromptRequest) { prompt = request }
}

// MARK: - Token field

/// A native token field; tokens are separated by Return so patterns may contain commas.
struct TokenField: NSViewRepresentable {
  @Binding var tokens: [String]
  var placeholder = ""
  var monospaced = false

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSTokenField {
    let field = NSTokenField()
    field.delegate = context.coordinator
    field.tokenStyle = .rounded
    field.tokenizingCharacterSet = CharacterSet(charactersIn: "\n")
    field.placeholderString = placeholder
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .exterior
    field.font = monospaced ? .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
    field.cell?.wraps = true
    field.cell?.isScrollable = false
    field.alignment = .right
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.objectValue = tokens
    return field
  }

  func updateNSView(_ field: NSTokenField, context: Context) {
    context.coordinator.parent = self
    if field.currentEditor() == nil, (field.objectValue as? [String]) != tokens { field.objectValue = tokens }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTokenField, context: Context) -> CGSize? {
    let width = proposal.width ?? 320
    field.preferredMaxLayoutWidth = width
    let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 22
    return CGSize(width: width, height: max(22, height))
  }

  final class Coordinator: NSObject, NSTokenFieldDelegate {
    var parent: TokenField
    init(_ parent: TokenField) { self.parent = parent }
    private func publish(_ field: NSTokenField) {
      let values = (field.objectValue as? [Any] ?? []).compactMap { $0 as? String }.map(trimmed).filter { !$0.isEmpty }
      if values != parent.tokens { parent.tokens = values }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
      if let field = notification.object as? NSTokenField { publish(field) }
    }
    func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
      DispatchQueue.main.async { self.publish(tokenField) }
      return tokens
    }
  }
}

/// A labeled row holding a token field.
struct TokenRow: View {
  let title: String
  var help: String? = nil
  @Binding var tokens: [String]
  var placeholder = "Add…"
  var monospaced = false
  var body: some View {
    FormRow {
      TokenField(tokens: $tokens, placeholder: placeholder, monospaced: monospaced).frame(maxWidth: 380)
    } label: { TitleLabel(title: title, helpText: help) }
  }
}

// MARK: - App lists

/// An app list in the style of System Settings: select a row, then add or remove with + and −.
/// Rows for list indices whose identities include a scope.
/// The grouped form misplaces section boundaries when rows in different sections share IDs.
struct ScopedRows<Content: View>: View {
  private struct Key: Hashable { let scope: String, index: Int }
  let scope: String
  let indices: [Int]
  @ViewBuilder let content: (Int) -> Content

  var body: some View {
    ForEach(indices.map { Key(scope: scope, index: $0) }, id: \.self) { content($0.index) }
  }
}

struct AppListEditor: View {
  @Environment(Store.self) private var store
  let file: String, path: Path
  var ordered = false
  var empty = "No apps"
  var removeWhenEmpty = false
  @State private var selection: Int?

  var body: some View {
    let ids = store.stringList(file, path)
    let order = AppIdentity.shared.installedFirst(Array(ids.indices)) { ids[$0] }
    let position = selection.flatMap { order.firstIndex(of: $0) }
    ScopedRows(scope: "\(file)/\(path)", indices: order) { index in
      let rank = order.firstIndex(of: index) ?? 0
      let id = ids[index]
      HStack(spacing: 10) {
        if ordered { Text("\(rank + 1)").font(.callout.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 14) }
        AppLabel(id: id)
        Spacer(minLength: 12)
        Text(id).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(RoundedRectangle(cornerRadius: 6).fill(selection == index ? Color.accentColor.opacity(0.18) : .clear))
      .contentShape(Rectangle())
      .onTapGesture { selection = selection == index ? nil : index }
      .contextMenu {
        if ordered {
          Button("Move Up") { move(ids, order, rank, rank - 1) }.disabled(rank == 0)
          Button("Move Down") { move(ids, order, rank, rank + 1) }.disabled(rank == order.count - 1)
          Divider()
        }
        Button("Remove", role: .destructive) { remove(ids, index) }
      }
    }
    if ids.isEmpty { EmptyRow(text: empty) }
    ListControls(
      add: { id in if !ids.contains(id) { store.setStringList(file, path, ids + [id]) } },
      remove: selection.map { index in { remove(ids, index) } },
      moveUp: ordered ? position.flatMap { p in p > 0 ? { move(ids, order, p, p - 1) } : nil } : nil,
      moveDown: ordered ? position.flatMap { p in p < order.count - 1 ? { move(ids, order, p, p + 1) } : nil } : nil)
  }

  private func remove(_ ids: [String], _ index: Int) {
    var list = ids
    list.remove(at: index)
    store.setStringList(file, path, list, removeWhenEmpty: removeWhenEmpty)
    selection = nil
  }
  /// Moves within the displayed order, which becomes the saved order.
  private func move(_ ids: [String], _ order: [Int], _ from: Int, _ to: Int) {
    guard order.indices.contains(to) else { return }
    var list = order.map { ids[$0] }
    list.swapAt(from, to)
    store.setStringList(file, path, list)
    selection = to
  }
}

/// The + − control under a list. Adding an app offers the app chooser or a typed bundle ID.
struct ListControls: View {
  @Environment(Store.self) private var store
  var add: ((String) -> Void)?
  var addTitle = "Add App"
  var remove: (() -> Void)?
  var moveUp: (() -> Void)? = nil
  var moveDown: (() -> Void)? = nil
  var applications = true

  var body: some View {
    HStack(spacing: 6) {
      ControlGroup {
        if applications {
          Menu {
            Button("Choose Application…") { store.browseApplication { id, _ in add?(id) } }
            Button("Enter Bundle ID…") {
              store.ask(PromptRequest(title: addTitle, label: "Bundle ID", placeholder: "com.example.App",
                                      validate: { AppIdentity.shared.isApplication($0) ? nil : "Use a bundle ID such as com.apple.Safari." },
                                      commit: { add?($0) }))
            }
          } label: { Image(systemName: "plus") }
          .menuIndicator(.hidden)
        } else {
          Button { add?("") } label: { Image(systemName: "plus") }
        }
        Button { remove?() } label: { Image(systemName: "minus") }.disabled(remove == nil)
      }
      .controlGroupStyle(.navigation)
      .fixedSize()
      .controlSize(.small)
      if moveUp != nil || moveDown != nil {
        ControlGroup {
          Button { moveUp?() } label: { Image(systemName: "chevron.up") }.disabled(moveUp == nil)
          Button { moveDown?() } label: { Image(systemName: "chevron.down") }.disabled(moveDown == nil)
        }
        .controlGroupStyle(.navigation).fixedSize().controlSize(.small)
      }
      Spacer()
    }
  }
}

// MARK: - Conditions

/// Network and shell conditions shared by proxy rules, proxy clients, and Mountain Duck.
struct ConditionEditor: View {
  @Environment(Store.self) private var store
  let file: String, path: Path
  var exitCodeNote: String? = nil

  var body: some View {
    TokenRow(title: "Wi-Fi network", help: "Network name patterns (SSID)", tokens: store.listBinding(file, path.appending("ssid")))
    TokenRow(title: "Ethernet address", help: "IPv4 address patterns on a USB LAN adapter", tokens: store.listBinding(file, path.appending("etherNet")),
             monospaced: true)
    FormRow {
      PlainField(text: store.stringBinding(file, path.appending("shell_command"), removeWhenEmpty: true), prompt: "None", monospaced: true)
        .frame(maxWidth: 380)
    } label: { TitleLabel(title: "Shell command", helpText: exitCodeNote ?? "Matches when the command succeeds") }
    let others = (store.value(file, path)?.object?.keys ?? []).filter { !["ssid", "etherNet", "shell_command"].contains($0) }
    ForEach(others, id: \.self) { key in
      NodeView(file: file, path: path.appending(key), value: store.value(file, path.appending(key)), key: key, depth: 1,
               onRemove: { store.deleteEntry(file, path.appending(key)) })
    }
  }
}

func conditionSummary(_ value: JSON?) -> String {
  guard let object = value?.object, !object.isEmpty else { return "Always" }
  var parts: [String] = []
  if let ssid = object["ssid"] { parts.append("Wi-Fi " + ((ssid.array?.compactMap { $0.string }) ?? [ssid.string ?? ""]).joined(separator: ", ")) }
  if let ether = object["etherNet"] { parts.append("Ethernet " + ((ether.array?.compactMap { $0.string }) ?? [ether.string ?? ""]).joined(separator: ", ")) }
  if let shell = object["shell_command"]?.string { parts.append("“\(shell)”") }
  return parts.isEmpty ? "Custom" : parts.joined(separator: " or ")
}

// MARK: - Window filters

/// Which windows something applies to. Every field is optional; unknown fields are kept.
struct WindowFilterFields: View {
  @Environment(Store.self) private var store
  let file: String, path: Path
  var showsURLs = false
  var showsSheets = true

  var body: some View {
    TokenRow(title: "Window titles", help: "Only windows whose title matches", tokens: store.listBinding(file, path.appending("allowTitles")))
    TokenRow(title: "Excluded titles", help: "Skip windows whose title matches; ^$ means untitled", tokens: store.listBinding(file, path.appending("rejectTitles")))
    TokenRow(title: "Window roles", help: "Accessibility roles, such as AXStandardWindow; * for any", tokens: store.listBinding(file, path.appending("allowRoles")),
             monospaced: true)
    if showsURLs {
      TokenRow(title: "Web page URLs", help: "Browser tab URL patterns", tokens: store.listBinding(file, path.appending("allowURLs")), monospaced: true)
    }
    if showsSheets {
      Toggle(isOn: store.flagBinding(file, path.appending("allowSheet"))) { TitleLabel(title: "Include sheets") }.toggleStyle(.switch)
      Toggle(isOn: store.flagBinding(file, path.appending("allowPopover"))) { TitleLabel(title: "Include popovers") }.toggleStyle(.switch)
    }
    let known: Set<String> = ["allowTitles", "rejectTitles", "allowRoles", "allowURLs", "allowSheet", "allowPopover", "delay"]
    let others = (store.value(file, path)?.object?.keys ?? []).filter { !known.contains($0) }
    ForEach(others, id: \.self) { key in
      NodeView(file: file, path: path.appending(key), value: store.value(file, path.appending(key)), key: key, depth: 1,
               onRemove: { store.deleteEntry(file, path.appending(key)) })
    }
  }
}

// MARK: - System catalogs

enum InputSources {
  struct Source: Hashable { let id: String, name: String }
  static let all: [Source] = {
    let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                  kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
    func property(_ source: TISInputSource, _ key: CFString) -> String? {
      guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
      return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
    var seen = Set<String>()
    return list.compactMap { source in
      guard let id = property(source, kTISPropertyInputSourceID), seen.insert(id).inserted else { return nil }
      return Source(id: id, name: property(source, kTISPropertyLocalizedName) ?? id)
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }()
  static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
}

/// Input source pop-up; sources not installed on this Mac stay selectable by ID.
struct InputSourcePicker: View {
  @Binding var selection: String
  var body: some View {
    Picker("", selection: $selection) {
      ForEach(InputSources.all, id: \.id) { Text($0.name).tag($0.id) }
      if !selection.isEmpty && !InputSources.all.contains(where: { $0.id == selection }) {
        Divider()
        Text(selection).tag(selection)
      }
    }
    .labelsHidden()
    .fixedSize()
  }
}

enum SystemSounds {
  static let names: [String] = {
    let folders = ["/System/Library/Sounds", NSHomeDirectory() + "/Library/Sounds", "/Library/Sounds"]
    var names = Set<String>()
    for folder in folders {
      for file in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where !file.hasPrefix(".") {
        names.insert((file as NSString).deletingPathExtension)
      }
    }
    return names.sorted()
  }()
}
