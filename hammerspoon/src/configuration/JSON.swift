// Order-preserving JSON. Configuration files keep their key order and formatting
// matches JSON.stringify(value, null, 2), which the previous editor used.
import Foundation

struct JObject: Equatable {
  private(set) var keys: [String] = []
  private var storage: [String: JSON] = [:]

  init() {}
  init(_ entries: [(String, JSON)]) { for (key, value) in entries { self[key] = value } }

  subscript(key: String) -> JSON? {
    get { storage[key] }
    set {
      if let value = newValue {
        if storage.updateValue(value, forKey: key) == nil { keys.append(key) }
      } else if storage.removeValue(forKey: key) != nil {
        keys.removeAll { $0 == key }
      }
    }
  }
  var entries: [(String, JSON)] { keys.map { ($0, storage[$0]!) } }
  var count: Int { keys.count }
  var isEmpty: Bool { keys.isEmpty }
  func has(_ key: String) -> Bool { storage[key] != nil }

  // Renames in place so the entry keeps its position.
  mutating func rename(_ old: String, to new: String) {
    guard old != new, let value = storage.removeValue(forKey: old) else { return }
    storage[new] = value
    if let index = keys.firstIndex(of: old) { keys[index] = new }
  }
  mutating func insertFirst(_ key: String, _ value: JSON) {
    self[key] = nil
    keys.insert(key, at: 0); storage[key] = value
  }
}

enum JSON: Equatable {
  case object(JObject), array([JSON]), string(String), number(Double), bool(Bool), null

  var object: JObject? { if case .object(let o) = self { return o }; return nil }
  var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
  var string: String? { if case .string(let s) = self { return s }; return nil }
  var number: Double? { if case .number(let n) = self { return n }; return nil }
  var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
  var isRecord: Bool { object != nil }
  var isArray: Bool { array != nil }
  var isNull: Bool { self == .null }
  var isContainer: Bool { isRecord || isArray }

  subscript(key: String) -> JSON? { object?[key] }
  subscript(index: Int) -> JSON? {
    guard let a = array, index >= 0, index < a.count else { return nil }
    return a[index]
  }
  subscript(key: PK) -> JSON? {
    switch key {
    case .k(let k): return self[k]
    case .i(let i): return self[i]
    }
  }

  /// Child keys in display order: object keys or array indices.
  var childKeys: [PK] {
    switch self {
    case .object(let o): return o.keys.map { .k($0) }
    case .array(let a): return a.indices.map { .i($0) }
    default: return []
    }
  }
  var childCount: Int { object?.count ?? array?.count ?? 0 }

  init(any value: Any?) {
    switch value {
    case nil, is NSNull: self = .null
    case let n as NSNumber:
      self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
    case let s as String: self = .string(s)
    case let a as [Any]: self = .array(a.map { JSON(any: $0) })
    case let d as [String: Any]:
      self = .object(JObject(d.keys.sorted().map { ($0, JSON(any: d[$0])) }))
    default: self = .null
    }
  }

  var any: Any {
    switch self {
    case .object(let o):
      var d: [String: Any] = [:]
      for (k, v) in o.entries { d[k] = v.any }
      return d
    case .array(let a): return a.map { $0.any }
    case .string(let s): return s
    case .number(let n): return n
    case .bool(let b): return b
    case .null: return NSNull()
    }
  }

  var typeName: String {
    switch self {
    case .object: return "object"
    case .array: return "array"
    case .string: return "string"
    case .number: return "number"
    case .bool: return "boolean"
    case .null: return "null"
    }
  }
}

enum PK: Hashable, CustomStringConvertible {
  case k(String), i(Int)
  var description: String {
    switch self {
    case .k(let k): return k
    case .i(let i): return String(i)
    }
  }
  var key: String? { if case .k(let k) = self { return k }; return nil }
  var index: Int? { if case .i(let i) = self { return i }; return nil }
}
typealias Path = [PK]

extension Array where Element == PK {
  var strings: [String] { compactMap { $0.key } }
  var joined: String { map { $0.description }.joined(separator: "/") }
  func at(_ i: Int) -> PK? {
    let index = i < 0 ? count + i : i
    return index >= 0 && index < count ? self[index] : nil
  }
  var last1: String? { last?.key }
  func appending(_ k: String) -> Path { self + [.k(k)] }
  func appending(_ i: Int) -> Path { self + [.i(i)] }
  var parent: Path { Array(dropLast()) }
  func first(is key: String) -> Bool { first?.key == key }
}

struct ConfigError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

// MARK: - Path access

extension JSON {
  func at(_ path: Path) -> JSON? {
    var current: JSON? = self
    for key in path {
      guard let value = current else { return nil }
      current = value[key]
    }
    return current
  }

  /// Creates missing parents as objects or arrays, as the previous editor did.
  mutating func assign(_ path: Path, _ value: JSON) throws {
    guard let head = path.first else { self = value; return }
    let rest = Array(path.dropFirst())
    switch (self, head) {
    case (.object(var o), .k(let k)):
      var child = o[k] ?? .null
      if child == .null, let next = rest.first { child = next.index != nil ? .array([]) : .object(JObject()) }
      if !rest.isEmpty && !child.isContainer { throw ConfigError("The parent configuration must be an object or array.") }
      try child.assign(rest, value)
      o[k] = child; self = .object(o)
    case (.array(var a), .i(let i)):
      while a.count <= i { a.append(.null) }
      var child = a[i]
      if child == .null, let next = rest.first { child = next.index != nil ? .array([]) : .object(JObject()) }
      if !rest.isEmpty && !child.isContainer { throw ConfigError("The parent configuration must be an object or array.") }
      try child.assign(rest, value)
      a[i] = child; self = .array(a)
    default:
      throw ConfigError("The parent configuration must be an object or array.")
    }
  }

  /// Removes an object key or array element; missing paths are ignored.
  mutating func remove(_ path: Path) {
    guard let head = path.first else { return }
    let rest = Array(path.dropFirst())
    switch (self, head) {
    case (.object(var o), .k(let k)):
      if rest.isEmpty { o[k] = nil } else if var child = o[k] { child.remove(rest); o[k] = child }
      self = .object(o)
    case (.array(var a), .i(let i)) where i >= 0 && i < a.count:
      if rest.isEmpty { a.remove(at: i) } else { a[i].remove(rest) }
      self = .array(a)
    default: break
    }
  }
}

// MARK: - Parsing

struct JSONParser {
  private let bytes: [UInt8]
  private var position = 0

  static func parse(_ text: String) throws -> JSON {
    var parser = JSONParser(bytes: Array(text.utf8))
    parser.skipWhitespace()
    let value = try parser.parseValue()
    parser.skipWhitespace()
    if parser.position < parser.bytes.count { throw parser.error("Unexpected non-whitespace character after JSON") }
    return value
  }

  private init(bytes: [UInt8]) { self.bytes = bytes }

  private func error(_ message: String) -> ConfigError {
    // Report a 1-based line and column, which is easier to find in the editor.
    var line = 1, column = 1
    for byte in bytes.prefix(position) { if byte == 10 { line += 1; column = 1 } else if byte & 0xC0 != 0x80 { column += 1 } }
    return ConfigError("\(message) at line \(line), column \(column)")
  }
  private var current: UInt8? { position < bytes.count ? bytes[position] : nil }
  private mutating func skipWhitespace() {
    while let c = current, c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { position += 1 }
  }
  private mutating func expect(_ literal: String) throws {
    for byte in literal.utf8 {
      guard current == byte else { throw error("Unexpected token") }
      position += 1
    }
  }

  private mutating func parseValue() throws -> JSON {
    guard let c = current else { throw error("Unexpected end of JSON input") }
    switch c {
    case UInt8(ascii: "{"): return try parseObject()
    case UInt8(ascii: "["): return try parseArray()
    case UInt8(ascii: "\""): return .string(try parseString())
    case UInt8(ascii: "t"): try expect("true"); return .bool(true)
    case UInt8(ascii: "f"): try expect("false"); return .bool(false)
    case UInt8(ascii: "n"): try expect("null"); return .null
    case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
    default: throw error("Unexpected token")
    }
  }

  private mutating func parseObject() throws -> JSON {
    position += 1
    var object = JObject()
    skipWhitespace()
    if current == UInt8(ascii: "}") { position += 1; return .object(object) }
    while true {
      skipWhitespace()
      guard current == UInt8(ascii: "\"") else { throw error("Expected property name") }
      let key = try parseString()
      skipWhitespace()
      guard current == UInt8(ascii: ":") else { throw error("Expected ':' after property name") }
      position += 1
      skipWhitespace()
      object[key] = try parseValue()
      skipWhitespace()
      if current == UInt8(ascii: ",") { position += 1; continue }
      if current == UInt8(ascii: "}") { position += 1; return .object(object) }
      throw error("Expected ',' or '}' after property value")
    }
  }

  private mutating func parseArray() throws -> JSON {
    position += 1
    var array: [JSON] = []
    skipWhitespace()
    if current == UInt8(ascii: "]") { position += 1; return .array(array) }
    while true {
      skipWhitespace()
      array.append(try parseValue())
      skipWhitespace()
      if current == UInt8(ascii: ",") { position += 1; continue }
      if current == UInt8(ascii: "]") { position += 1; return .array(array) }
      throw error("Expected ',' or ']' after array element")
    }
  }

  private mutating func parseHex4() throws -> UInt32 {
    guard position + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[position..<position+4], as: UTF8.self), radix: 16)
    else { throw error("Bad Unicode escape") }
    position += 4
    return value
  }

  private mutating func parseString() throws -> String {
    position += 1
    var output: [UInt8] = []
    while true {
      guard let c = current else { throw error("Unterminated string") }
      position += 1
      switch c {
      case UInt8(ascii: "\""): return String(decoding: output, as: UTF8.self)
      case UInt8(ascii: "\\"):
        guard let e = current else { throw error("Unterminated string") }
        position += 1
        switch e {
        case UInt8(ascii: "\""): output.append(0x22)
        case UInt8(ascii: "\\"): output.append(0x5C)
        case UInt8(ascii: "/"): output.append(0x2F)
        case UInt8(ascii: "b"): output.append(0x08)
        case UInt8(ascii: "f"): output.append(0x0C)
        case UInt8(ascii: "n"): output.append(0x0A)
        case UInt8(ascii: "r"): output.append(0x0D)
        case UInt8(ascii: "t"): output.append(0x09)
        case UInt8(ascii: "u"):
          var scalar = try parseHex4()
          if (0xD800...0xDBFF).contains(scalar), position + 6 <= bytes.count,
             bytes[position] == UInt8(ascii: "\\"), bytes[position+1] == UInt8(ascii: "u") {
            let saved = position
            position += 2
            let low = try parseHex4()
            if (0xDC00...0xDFFF).contains(low) { scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00) } else { position = saved }
          }
          output.append(contentsOf: Array(String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8))
        default: throw error("Bad escaped character")
        }
      default:
        if c < 0x20 { throw error("Bad control character in string literal") }
        output.append(c)
      }
    }
  }

  private mutating func parseNumber() throws -> JSON {
    let start = position
    if current == UInt8(ascii: "-") { position += 1 }
    guard let first = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else { throw error("No number after minus sign") }
    if first == UInt8(ascii: "0") { position += 1 } else { while let c = current, (48...57).contains(c) { position += 1 } }
    if current == UInt8(ascii: ".") {
      position += 1
      guard let c = current, (48...57).contains(c) else { throw error("Unterminated fractional number") }
      while let c = current, (48...57).contains(c) { position += 1 }
    }
    if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
      position += 1
      if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { position += 1 }
      guard let c = current, (48...57).contains(c) else { throw error("Exponent part is missing a number") }
      while let c = current, (48...57).contains(c) { position += 1 }
    }
    return .number(Double(String(decoding: bytes[start..<position], as: UTF8.self)) ?? 0)
  }
}

// MARK: - Serialization

extension JSON {
  static func formatNumber(_ n: Double) -> String {
    guard n.isFinite else { return "null" }
    if n == n.rounded(), abs(n) < 1e21 { return String(format: "%.0f", n == 0 ? 0 : n) }
    // Swift prints exponents as e-07; JavaScript prints e-7.
    var text = "\(n)"
    if let range = text.range(of: #"e([+-])0+(\d)"#, options: .regularExpression) {
      let exponent = text[range]
      let sign = exponent.contains("-") ? "-" : "+"
      let digits = exponent.drop { !$0.isNumber }.drop { $0 == "0" }
      text.replaceSubrange(range, with: "e" + sign + digits)
    }
    return text
  }

  static func quote(_ s: String) -> String {
    var result = "\""
    for scalar in s.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "\u{08}": result += "\\b"
      case "\u{0C}": result += "\\f"
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      default:
        if scalar.value < 0x20 { result += String(format: "\\u%04x", scalar.value) } else { result.unicodeScalars.append(scalar) }
      }
    }
    return result + "\""
  }

  func stringify(indent: String = "  ", level: String = "") -> String {
    switch self {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n): return JSON.formatNumber(n)
    case .string(let s): return JSON.quote(s)
    case .array(let a):
      if a.isEmpty { return "[]" }
      let inner = level + indent
      return "[\n" + a.map { inner + $0.stringify(indent: indent, level: inner) }.joined(separator: ",\n") + "\n" + level + "]"
    case .object(let o):
      if o.isEmpty { return "{}" }
      let inner = level + indent
      return "{\n" + o.entries.map { inner + JSON.quote($0.0) + ": " + $0.1.stringify(indent: indent, level: inner) }
        .joined(separator: ",\n") + "\n" + level + "}"
    }
  }

  var compact: String {
    switch self {
    case .array(let a): return "[" + a.map { $0.compact }.joined(separator: ",") + "]"
    case .object(let o): return "{" + o.entries.map { JSON.quote($0.0) + ":" + $0.1.compact }.joined(separator: ",") + "}"
    default: return stringify()
    }
  }
}
