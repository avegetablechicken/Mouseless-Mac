// File sync pages: files on this Mac copied into configuration folders, and the path variables those folders use.
import AppKit
import SwiftUI

enum SyncPathPart: Hashable {
  case text(String), variable(String), command(String)
}

/// Splits a sync path into literal text, ${NAME} variables, and $(command) substitutions.
func syncPathParts(_ path: String) -> [SyncPathPart] {
  let regex = try! NSRegularExpression(pattern: #"\$\{([^}]+)\}|\$\(([^)]*)\)"#)
  let ns = path as NSString
  var parts: [SyncPathPart] = []
  var offset = 0
  for match in regex.matches(in: path, range: NSRange(location: 0, length: ns.length)) {
    if match.range.location > offset {
      parts.append(.text(ns.substring(with: NSRange(location: offset, length: match.range.location - offset))))
    }
    if match.range(at: 1).location != NSNotFound {
      parts.append(.variable(ns.substring(with: match.range(at: 1))))
    } else {
      parts.append(.command(ns.substring(with: match.range(at: 2))))
    }
    offset = match.range.location + match.range.length
  }
  if offset < ns.length { parts.append(.text(ns.substring(from: offset))) }
  return parts
}

private let variablePalette: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .indigo, .brown]

private func withoutTrailingSlash(_ path: String) -> String {
  var result = path
  while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
  return result
}

extension Store {
  var syncVariables: JObject { value("sync", [.k("variable")])?.object ?? JObject() }

  /// Each path variable keeps one color; environment variables are gray.
  func variableTint(_ name: String) -> Color {
    guard let index = syncVariables.keys.firstIndex(of: name) else { return .gray }
    return variablePalette[index % variablePalette.count]
  }

  /// Expands variables, then environment variables, and ~, as fs.lua does. Command substitutions are never run.
  func resolveSyncPath(_ path: String, depth: Int = 0) -> String? {
    var result = ""
    for part in syncPathParts(path) {
      switch part {
      case .text(let text): result += text
      case .variable(let name):
        if depth < 12, let value = syncVariables[name]?.string, let resolved = resolveSyncPath(value, depth: depth + 1) {
          result += resolved
        } else if let environment = ProcessInfo.processInfo.environment[name] {
          result += environment
        } else {
          return nil
        }
      case .command: return nil
      }
    }
    if result == "~" || result.hasPrefix("~/") { result = NSHomeDirectory() + result.dropFirst() }
    return result
  }

  /// Writes a chosen path from the variable whose folder contains it most closely, or from ~.
  func compactSyncPath(_ absolute: String, excluding: String? = nil) -> String {
    var best: (name: String, root: String)?
    for name in syncVariables.keys where name != excluding && !variableDepends(name, on: excluding) {
      guard let value = syncVariables[name]?.string, let resolved = resolveSyncPath(value) else { continue }
      let root = withoutTrailingSlash(resolved)
      guard root != "/", absolute == root || absolute.hasPrefix(root + "/") else { continue }
      if root.count > best?.root.count ?? -1 { best = (name, root) }
    }
    if let best { return "${\(best.name)}" + absolute.dropFirst(best.root.count) }
    let home = NSHomeDirectory()
    if absolute == home || absolute.hasPrefix(home + "/") { return "~" + absolute.dropFirst(home.count) }
    return absolute
  }

  /// Whether a variable's folder is built on another variable, directly or through others.
  func variableDepends(_ name: String, on other: String?, depth: Int = 0) -> Bool {
    guard let other, depth < 12, let value = syncVariables[name]?.string else { return false }
    return syncPathParts(value).contains { part in
      guard case .variable(let used) = part else { return false }
      return used == other || variableDepends(used, on: other, depth: depth + 1)
    }
  }

  /// Sources and variables whose paths use a variable directly.
  func variableUsers(_ name: String) -> (files: [String], variables: [String]) {
    let reference = "${" + name + "}"
    let files = value("sync", [.k("file")])?.object ?? JObject()
    let users = files.keys.filter { key in
      key.contains(reference) || syncDestination(files[key]).contains(reference)
    }
    return (users, syncVariables.keys.filter { $0 != name && (syncVariables[$0]?.string ?? "").contains(reference) })
  }
}

/// A mapping's destination is a folder path, or a list whose first item is the folder.
func syncDestination(_ value: JSON?) -> String {
  value?.string ?? value?.array?.first?.string ?? ""
}

// MARK: - Path display

struct VariableChip: View {
  @Environment(Store.self) private var store
  let name: String
  var large = false

  var body: some View {
    let tint = store.variableTint(name)
    Text(name)
      .font(.system(large ? .callout : .caption, design: .rounded).weight(.semibold))
      .foregroundStyle(tint)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, large ? 9 : 7).padding(.vertical, large ? 3 : 2)
      .background(Capsule().fill(tint.opacity(0.14)))
      .help(store.resolveSyncPath("${\(name)}") ?? "Not defined")
  }
}

/// A path with its variables shown as colored chips.
struct RichPath: View {
  let path: String
  var font: Font = .callout
  var secondary = false

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(syncPathParts(path).enumerated()), id: \.offset) { _, part in
        switch part {
        case .text(let text):
          Text(text).font(font).foregroundStyle(secondary ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
        case .variable(let name):
          VariableChip(name: name)
        case .command(let command):
          Label(command, systemImage: "terminal")
            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .help("Output of a shell command")
        }
      }
    }
  }
}

/// The Finder icon of a synced file or folder, or a placeholder when it doesn't exist.
struct SyncFileIcon: View {
  @Environment(Store.self) private var store
  let path: String
  var size: CGFloat = 28

  var body: some View {
    if let resolved = store.resolveSyncPath(path), FileManager.default.fileExists(atPath: resolved) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: resolved)).resizable().interpolation(.high).frame(width: size, height: size)
    } else {
      Image(systemName: path.hasSuffix("/") ? "folder.badge.questionmark" : "questionmark.square.dashed")
        .font(.system(size: size * 0.62)).foregroundStyle(.tertiary).frame(width: size, height: size)
        .help("Not found on this Mac")
    }
  }
}

private func pathName(_ path: String) -> (name: String, parent: String) {
  let trimmed = withoutTrailingSlash(path)
  guard let slash = trimmed.lastIndex(of: "/") else { return (trimmed, "") }
  let parent = String(trimmed[..<slash])
  return (String(trimmed[trimmed.index(after: slash)...]), parent.isEmpty ? "/" : parent)
}

// MARK: - Pages

struct FileMappingsPage: View {
  @Environment(Store.self) private var store
  @State private var selection: String?

  var body: some View {
    let files = store.value("sync", [.k("file")])?.object ?? JObject()
    Section {
      ForEach(files.keys, id: \.self) { source in
        let (name, parent) = pathName(source)
        SelectableRow(selected: selection == source, select: { selection = source }) {
          Button { store.panel = .syncFile(source) } label: {
            HStack(spacing: 10) {
              SyncFileIcon(path: source)
              VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                RichPath(path: parent, font: .caption, secondary: true)
              }
              .layoutPriority(1)
              Spacer(minLength: 16)
              Image(systemName: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
              RichPath(path: syncDestination(files[source]))
              Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        .contextMenu {
          Button("Edit…") { store.panel = .syncFile(source) }
          Button("Delete", role: .destructive) { store.deleteEntry("sync", [.k("file"), .k(source)]) }
        }
      }
      if files.isEmpty { EmptyRow(text: "No synced files") }
      ListControls(add: { _ in addMapping(files) },
                   remove: selection.map { source in { store.deleteEntry("sync", [.k("file"), .k(source)]); selection = nil } },
                   applications: false)
    } footer: {
      Text("When a file or folder on the left changes, it's copied into the folder on the right. Sync is one-way; nothing is copied back.")
    }
  }

  private func addMapping(_ files: JObject) {
    store.browsePath(current: "~/", context: PathContext(), key: "sync/new") { path, kind in
      var source = store.compactSyncPath(path)
      if kind == "directory" && !source.hasSuffix("/") { source += "/" }
      if files[source] == nil {
        let destination = store.syncVariables.keys.first.map { "${\($0)}" } ?? "~/"
        store.set("sync", [.k("file"), .k(source)], .string(destination))
      }
      store.panel = .syncFile(source)
    }
  }
}

struct PathVariablesPage: View {
  @Environment(Store.self) private var store
  @State private var selection: String?

  var body: some View {
    let variables = store.syncVariables
    Section {
      ForEach(variables.keys, id: \.self) { name in
        SelectableRow(selected: selection == name, select: { selection = name }) {
          Button { store.panel = .syncVariable(name) } label: {
            HStack(spacing: 10) {
              VariableChip(name: name, large: true)
              Spacer(minLength: 16)
              RichPath(path: variables[name]?.string ?? "")
              Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        .contextMenu {
          Button("Edit…") { store.panel = .syncVariable(name) }
          Button("Delete", role: .destructive) { store.deleteEntry("sync", [.k("variable"), .k(name)]) }
            .disabled(store.pathVariableReferenced(name))
        }
      }
      if variables.isEmpty { EmptyRow(text: "No variables") }
      ListControls(add: { _ in
        store.ask(PromptRequest(title: "Add Path Variable", message: "Name a folder that file mappings can start from.",
                                label: "Name", placeholder: "CONFIG_DIR", monospaced: true,
                                validate: { name in
                                  if name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
                                    return "Use letters, digits, and underscores."
                                  }
                                  return variables.has(name) ? "This variable already exists." : nil
                                },
                                commit: { name in
                                  store.set("sync", [.k("variable"), .k(name)], .string("~/"))
                                  store.panel = .syncVariable(name)
                                }))
      }, remove: selection.flatMap { name in
        store.pathVariableReferenced(name) ? nil : { store.deleteEntry("sync", [.k("variable"), .k(name)]); selection = nil }
      }, applications: false)
    } footer: {
      Text("Variables name the folders that file mappings start from, and can build on one another. Variables in use can't be deleted.")
    }
  }
}

// MARK: - Panels

/// Edits a path as a starting folder (a variable, the home folder, or the disk root) plus the path inside it.
struct SyncPathEditor: View {
  @Environment(Store.self) private var store
  let path: String
  var folder = false
  /// The variable being edited, which can't build on itself.
  var excluding: String? = nil
  let commit: (String) -> Void
  @State private var rest = ""

  enum Base: Hashable { case variable(String), home, root }

  var body: some View {
    let (base, _) = split(path)
    let resolved = store.resolveSyncPath(path)
    Picker(selection: Binding(get: { base }, set: { commit(join($0, rest)) })) {
      ForEach(choices(base), id: \.self) { name in
        Label(name, systemImage: "folder.fill").tag(Base.variable(name))
      }
      if !choices(base).isEmpty { Divider() }
      Label("Home Folder", systemImage: "house").tag(Base.home)
      Label("Full Path", systemImage: "internaldrive").tag(Base.root)
    } label: {
      TitleLabel(title: "Starts from")
    }
    FormRow {
      HStack(spacing: 6) {
        PlainField(text: $rest, prompt: base == .root ? "/path" : "Folder or file inside", alignment: .trailing,
                   onFocusChange: { if !$0 { commitRest() } }, onSubmit: commitRest)
        Button("Choose…") {
          store.browsePath(current: path, context: PathContext(requiredType: folder ? "directory" : nil), key: "sync/editor") { chosen, kind in
            var compact = store.compactSyncPath(chosen, excluding: excluding)
            if kind == "directory" && !folder && !compact.hasSuffix("/") { compact += "/" }
            commit(compact)
          }
        }
        .controlSize(.small)
      }
    } label: {
      TitleLabel(title: "Path")
    }
    LabeledContent("Location on this Mac") {
      Text(resolved ?? "Can't be shown")
        .font(.callout).foregroundStyle(.secondary)
        .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
    .onAppear { rest = split(path).1 }
    .onChange(of: path) { rest = split(path).1 }
  }

  private func choices(_ base: Base) -> [String] {
    var names = store.syncVariables.keys.filter { $0 != excluding && !store.variableDepends($0, on: excluding) }
    if case .variable(let current) = base, !names.contains(current) { names.append(current) }
    return names
  }

  private func split(_ path: String) -> (Base, String) {
    if case .variable(let name)? = syncPathParts(path).first, path.hasPrefix("${\(name)}") {
      let rest = path.dropFirst(name.count + 3)
      return (.variable(name), String(rest.hasPrefix("/") ? rest.dropFirst() : rest))
    }
    if path == "~" || path.hasPrefix("~/") { return (.home, String(path.dropFirst(2))) }
    return (.root, path)
  }

  private func join(_ base: Base, _ rest: String) -> String {
    let rest = rest.hasPrefix("/") && base != .root ? String(rest.dropFirst()) : rest
    switch base {
    case .variable(let name): return "${\(name)}" + (rest.isEmpty ? "" : "/" + rest)
    case .home: return "~/" + rest
    case .root: return rest.hasPrefix("/") || rest.hasPrefix("$") ? rest : "/" + rest
    }
  }

  private func commitRest() {
    let next = join(split(path).0, trimmed(rest))
    if next != path { commit(next) }
  }
}

struct SyncFilePanel: View {
  @Environment(Store.self) private var store
  let source: String

  var body: some View {
    let path: Path = [.k("file"), .k(source)]
    let value = store.value("sync", path)
    Section {
      SyncPathEditor(path: source) { next in
        do {
          try store.renameMapping("sync", path, to: next)
          store.panel = .syncFile(trimmed(next))
        } catch {
          store.setStatus(error.localizedDescription, error: true)
        }
      }
    } header: {
      Text("File or Folder")
    } footer: {
      Text("Watched for changes. A folder path ends with “/”.")
    }
    Section {
      SyncPathEditor(path: syncDestination(value), folder: true) { next in
        store.set("sync", value?.array != nil ? path.appending(0) : path, .string(next))
      }
    } header: {
      Text("Copy Into")
    } footer: {
      Text("Changed files are copied into this folder.")
    }
    if let process = value?.array?.dropFirst().first?["post_process"] {
      Section {
        LabeledContent("Post-processing") { Text(scalarText(process)).font(.callout.monospaced()).foregroundStyle(.secondary) }
      }
    }
  }
}

struct SyncVariablePanel: View {
  @Environment(Store.self) private var store
  let name: String
  @State private var text = ""

  var body: some View {
    let path: Path = [.k("variable"), .k(name)]
    let users = store.variableUsers(name)
    Section {
      FormRow {
        PlainField(text: $text, prompt: "Name", monospaced: true, alignment: .trailing, invalid: store.invalid["sync/variable/@name"] != nil,
                   onFocusChange: { if !$0 { rename(path) } }, onSubmit: { rename(path) })
      } label: {
        TitleLabel(title: "Name", helpText: "Mappings that use it are renamed too")
      }
      .onAppear { text = name }
      .onChange(of: name) { text = name }
    }
    Section {
      SyncPathEditor(path: store.value("sync", path)?.string ?? "", folder: true, excluding: name) { next in
        store.set("sync", path, .string(next))
      }
    } header: {
      Text("Folder")
    }
    if !users.files.isEmpty || !users.variables.isEmpty {
      Section {
        ForEach(users.variables, id: \.self) { other in
          Button { store.panel = .syncVariable(other) } label: {
            HStack { VariableChip(name: other); Spacer(); RichPath(path: store.syncVariables[other]?.string ?? "", secondary: true) }
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        ForEach(users.files, id: \.self) { source in
          Button { store.panel = .syncFile(source) } label: {
            HStack(spacing: 8) {
              SyncFileIcon(path: source, size: 20)
              Text(pathName(source).name)
              Spacer()
              RichPath(path: source, font: .caption, secondary: true)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      } header: {
        Text("Used By")
      }
    }
  }

  private func rename(_ path: Path) {
    let next = trimmed(text)
    guard next != name else { store.clearInvalid("sync/variable/@name"); return }
    guard next.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
      store.markInvalid("sync/variable/@name", "Use letters, digits, and underscores.")
      return
    }
    do {
      try store.renameMapping("sync", path, to: next)
      store.clearInvalid("sync/variable/@name")
      store.panel = .syncVariable(next)
    } catch {
      store.markInvalid("sync/variable/@name", error.localizedDescription)
    }
  }
}
