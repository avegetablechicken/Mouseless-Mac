// Reusable controls styled after System Settings.
import AppKit
import SwiftUI

struct IconTile: View {
  let symbol: String
  let tint: Color
  var size: CGFloat = 22

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
      .fill(tint.gradient)
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: symbol)
          .font(.system(size: size * 0.52, weight: .semibold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
      }
      .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
  }
}

struct AppIcon: View {
  let id: String
  var size: CGFloat = 18

  var body: some View {
    if let image = AppIdentity.shared.icon(id) {
      Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
    } else {
      Image(systemName: "app.dashed").font(.system(size: size * 0.8)).foregroundStyle(.tertiary).frame(width: size, height: size)
    }
  }
}

/// App icon and name when the text names an installed application.
struct AppLabel: View {
  let id: String
  var fallback: String? = nil
  var body: some View {
    HStack(spacing: 7) {
      AppIcon(id: id, size: 18)
      if let name = AppIdentity.shared.name(id) ?? fallback {
        Text(name).lineLimit(1)
      } else {
        Text("Not installed").foregroundStyle(.tertiary).lineLimit(1)
      }
    }
  }
}

// Row controls stay hidden until the pointer is over the row, as in System Settings lists.
private struct RowHoveredKey: EnvironmentKey { static let defaultValue = true }
private struct FieldAlignmentKey: EnvironmentKey { static let defaultValue: TextAlignment? = nil }
private struct NavigationContextKey: EnvironmentKey { static let defaultValue = NavigationContext.root }
extension EnvironmentValues {
  var rowHovered: Bool {
    get { self[RowHoveredKey.self] }
    set { self[RowHoveredKey.self] = newValue }
  }
  var navigationContext: NavigationContext {
    get { self[NavigationContextKey.self] }
    set { self[NavigationContextKey.self] = newValue }
  }
  var fieldAlignment: TextAlignment? {
    get { self[FieldAlignmentKey.self] }
    set { self[FieldAlignmentKey.self] = newValue }
  }
}

private struct HoverRow: ViewModifier {
  @State private var hovering = false
  func body(content: Content) -> some View {
    content
      .environment(\.rowHovered, hovering)
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
  }
}
private struct HoverReveal: ViewModifier {
  @Environment(\.rowHovered) private var rowHovered
  func body(content: Content) -> some View {
    content
      .opacity(rowHovered ? 1 : 0)
      .allowsHitTesting(rowHovered)
      .animation(.easeOut(duration: 0.12), value: rowHovered)
  }
}

extension View {
  func hoverRow() -> some View { modifier(HoverRow()) }
  /// Secondary row controls appear with the pointer.
  func revealOnHover() -> some View { modifier(HoverReveal()) }
}

struct RemoveButton: View {
  var help = "Delete"
  let action: () -> Void
  @Environment(\.rowHovered) private var rowHovered
  @State private var hovering = false
  var body: some View {
    Button(action: action) {
      Image(systemName: "minus.circle.fill")
        .font(.system(size: 13))
        .foregroundStyle(hovering ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
    }
    .buttonStyle(.borderless)
    .onHover { hovering = $0 }
    .opacity(rowHovered ? 1 : 0)
    .allowsHitTesting(rowHovered)
    .animation(.easeOut(duration: 0.12), value: rowHovered)
    .help(help)
    .accessibilityLabel(help)
  }
}

struct ToolButton: View {
  let title: String
  var symbol: String? = nil
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }
}

/// "Add" control; when the entry is an application it offers manual entry or browsing.
struct AddEntryButton: View {
  @Environment(Store.self) private var store
  var title = "Add…"
  var needsApplication = false
  var proxy = false
  var compact = false
  let action: (_ id: String, _ proxyName: String?) -> Void

  var body: some View {
    if needsApplication {
      Menu {
        Button("Enter Manually…") { action("", nil) }
        Button(proxy ? "Browse Applications…" : "Choose Application…") { store.browseApplication { id, name in action(id, name) } }
      } label: {
        if compact { Image(systemName: "plus") } else { Text(title) }
      }
      .menuStyle(.button)
      .buttonStyle(.bordered)
      .fixedSize()
      .controlSize(.small)
    } else {
      Button { action("", nil) } label: {
        if compact { Image(systemName: "plus") } else { Text(title) }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }
}

/// Section actions sit at the trailing edge, below the rows they affect.
struct ToolsRow<Content: View>: View {
  @ViewBuilder let content: Content
  var body: some View {
    HStack(spacing: 8) { Spacer(minLength: 0); content }
  }
}

struct EmptyRow: View {
  let text: String
  var body: some View { Text(text).foregroundStyle(.secondary).font(.callout) }
}

struct TitleLabel: View {
  let title: String
  var helpText: String? = nil
  var appID: String? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let appID, AppIdentity.shared.isApplication(appID) {
        HStack(spacing: 7) { AppIcon(id: appID, size: 18); Text(title) }
      } else {
        Text(title)
      }
      if let helpText { Text(helpText).font(.caption).foregroundStyle(.secondary) }
    }
  }
}

/// A stock text field, as in System Settings: no bezel at rest, native font, focus ring and baseline.
struct PlainField: View {
  let text: Binding<String>
  var prompt = "Not set"
  var monospaced = false
  var alignment: TextAlignment = .trailing
  var invalid = false
  var secondary = false
  /// Wraps and shows every line of the text; Option-Return inserts a line break.
  var multiline = false
  var onFocusChange: ((Bool) -> Void)? = nil
  var onSubmit: (() -> Void)? = nil
  @FocusState private var focused: Bool

  var body: some View {
    TextField("", text: text, prompt: Text(prompt), axis: multiline ? .vertical : .horizontal)
      .labelsHidden()
      .lineLimit(multiline ? 1...12 : 1...1)
      .multilineTextAlignment(alignment)
      .foregroundStyle(invalid ? AnyShapeStyle(.red) : secondary && !focused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      .focused($focused)
      .onChange(of: focused) { onFocusChange?(focused) }
      .onSubmit { onSubmit?() }
  }
}

/// A settings row: label on the leading side, controls trailing, sharing one text baseline.
struct FormRow<Label: View, Content: View>: View {
  @ViewBuilder let content: Content
  @ViewBuilder let label: Label
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      label
      Spacer(minLength: 16)
      content
    }
  }
}

struct FieldChrome: View {
  let focused: Bool
  var hovering = false
  var invalid = false
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    shape
      .fill(focused ? AnyShapeStyle(Color(nsColor: .textBackgroundColor)) : hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
      .overlay {
        if invalid { shape.strokeBorder(.red.opacity(0.85), lineWidth: 1.5) }
        else if focused { shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 2.5) }
      }
      .animation(.easeOut(duration: 0.12), value: hovering)
  }
}

/// A removable value in a wrapping row, drawn as a soft token.
struct Chip<Content: View>: View {
  var help = "Delete"
  let remove: () -> Void
  @ViewBuilder let content: Content
  var body: some View {
    HStack(spacing: 0) {
      content
      RemoveButton(help: help, action: remove).padding(.trailing, 4)
    }
    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.45)))
    .hoverRow()
  }
}

/// Shortcut symbols drawn as keycaps.
struct KeyCaps: View {
  let symbols: [String]
  var tint: Color? = nil
  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
        Text(symbol)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(tint ?? .primary)
          .frame(minWidth: 14)
          .padding(.horizontal, 5).padding(.vertical, 2)
          .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .fill(tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
              .shadow(color: .black.opacity(tint == nil ? 0.18 : 0), radius: 0.5, y: 0.5)
          }
      }
    }
  }
}

struct FlowLayout: Layout {
  var spacing: CGFloat = 6
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 400
    var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width { y += line + spacing; x = 0; line = 0 }
      x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
    }
    return CGSize(width: min(width, widest), height: y + line)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX && x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing; line = max(line, size.height)
    }
  }
}

func textWidth(_ text: String, minimum: CGFloat = 70, maximum: CGFloat = 240) -> CGFloat {
  let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
  return min(maximum, max(minimum, width + 24))
}

// MARK: - JSON editor

final class CodeTextView: NSTextView {
  override func insertTab(_ sender: Any?) { insertText("  ", replacementRange: selectedRange()) }
}

struct CodeEditor: NSViewRepresentable {
  @Binding var text: String

  private static let token = try! NSRegularExpression(
    pattern: #""(?:\\.|[^"\\])*"|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|\b(?:true|false|null)\b|[{}\[\],:]"#)
  private static func color(_ light: NSColor, _ dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
  }
  private static let keyColor = color(NSColor(red: 0.45, green: 0.32, blue: 0.72, alpha: 1), NSColor(red: 0.78, green: 0.63, blue: 0.94, alpha: 1))
  private static let stringColor = color(NSColor(red: 0.14, green: 0.47, blue: 0.31, alpha: 1), NSColor(red: 0.62, green: 0.84, blue: 0.68, alpha: 1))
  private static let numberColor = color(NSColor(red: 0.68, green: 0.34, blue: 0.09, alpha: 1), NSColor(red: 0.94, green: 0.71, blue: 0.48, alpha: 1))
  private static let literalColor = color(NSColor(red: 0.19, green: 0.36, blue: 0.77, alpha: 1), NSColor(red: 0.59, green: 0.72, blue: 1, alpha: 1))

  static func highlight(_ storage: NSTextStorage) {
    let text = storage.string as NSString
    let full = NSRange(location: 0, length: text.length)
    storage.beginEditing()
    storage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor], range: full)
    for match in token.matches(in: storage.string, range: full) {
      let value = text.substring(with: match.range)
      let color: NSColor
      if value.hasPrefix("\"") {
        let rest = text.substring(from: match.range.location + match.range.length)
        color = rest.range(of: #"^\s*:"#, options: .regularExpression) != nil ? keyColor : stringColor
      } else if let first = value.first, first == "-" || first.isNumber { color = numberColor }
      else if ["true", "false", "null"].contains(value) { color = literalColor }
      else { color = .secondaryLabelColor }
      storage.addAttribute(.foregroundColor, value: color, range: match.range)
    }
    storage.endEditing()
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = CodeTextView.scrollableTextView()
    let old = scroll.documentView as! NSTextView
    let textView = CodeTextView(frame: old.frame, textContainer: old.textContainer)
    scroll.documentView = textView
    textView.delegate = context.coordinator
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.textContainerInset = NSSize(width: 6, height: 8)
    textView.drawsBackground = true
    textView.backgroundColor = .textBackgroundColor
    textView.string = text
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    if let storage = textView.textStorage { CodeEditor.highlight(storage) }
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.wantsLayer = true
    scroll.layer?.cornerRadius = 8
    scroll.layer?.borderWidth = 1
    scroll.layer?.borderColor = NSColor.separatorColor.cgColor
    DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
    textView.string = text
    if let storage = textView.textStorage { CodeEditor.highlight(storage) }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    init(text: Binding<String>) { self.text = text }
    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
      if let storage = textView.textStorage {
        let selection = textView.selectedRanges
        CodeEditor.highlight(storage)
        textView.selectedRanges = selection
      }
    }
  }
}

// MARK: - Actions

enum NodeAction {
  /// Adds an entry; application entries offer choosing an app or typing a bundle ID.
  case add(String, application: Bool = false, proxy: Bool = false, run: (_ id: String, _ proxyName: String?) -> Void)
  case item(String, () -> Void)
  case delete(String, () -> Void)

  var isAdd: Bool { if case .add = self { return true }; return false }
}

struct NodeActionItems: View {
  @Environment(Store.self) private var store
  let actions: [NodeAction]
  var body: some View {
    ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
      switch action {
      case .add(let title, let application, let proxy, let run):
        if application {
          Button(proxy ? "\(title) from Applications…" : "\(title) from Applications…") { store.browseApplication { run($0, $1) } }
          Button("\(title) by Bundle ID…") { run("", nil) }
        } else {
          Button("\(title)…") { run("", nil) }
        }
      case .item(let title, let run):
        Button(title, action: run)
      case .delete(let title, let run):
        if index > 0 { Divider() }
        Button(title, role: .destructive, action: run)
      }
    }
  }
}

/// Compact "…" menu for a group's actions, placed on its title row.
struct ActionsMenu: View {
  let actions: [NodeAction]
  var body: some View {
    if !actions.isEmpty {
      Menu { NodeActionItems(actions: actions) } label: {
        Image(systemName: "ellipsis.circle").font(.system(size: 14)).foregroundStyle(.secondary)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Actions")
    }
  }
}

/// Footer buttons for a list: other actions in a menu, adding as the trailing button.
struct ActionButtons: View {
  @Environment(Store.self) private var store
  let actions: [NodeAction]
  var body: some View {
    let others = actions.filter { !$0.isAdd }
    let adds = actions.filter { $0.isAdd }
    ToolsRow {
      if others.count == 1, case .item(let title, let run) = others[0] {
        Button(title, action: run).buttonStyle(.bordered).controlSize(.small)
      } else if !others.isEmpty {
        Menu { NodeActionItems(actions: others) } label: { Image(systemName: "ellipsis") }
          .menuStyle(.button).buttonStyle(.bordered).menuIndicator(.hidden).fixedSize().controlSize(.small)
          .help("More actions")
      }
      ForEach(Array(adds.enumerated()), id: \.offset) { _, action in
        if case .add(let title, let application, let proxy, let run) = action {
          if application {
            Menu { NodeActionItems(actions: [action]) } label: { Label(title, systemImage: "plus") }
              .menuStyle(.button).buttonStyle(.bordered).fixedSize().controlSize(.small)
              .accessibilityLabel(proxy ? "Add proxy" : title)
          } else {
            Button { run("", nil) } label: { Label(title, systemImage: "plus") }
              .buttonStyle(.bordered).controlSize(.small)
          }
        }
      }
    }
    .labelStyle(.titleAndIcon)
  }
}
