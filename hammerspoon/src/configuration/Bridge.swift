// Lua entry point. Messages use the same JSON protocol as the previous web editor.
import AppKit

private let registryIndex: Int32 = -1_001_000  // LUA_REGISTRYINDEX for Lua 5.4 with 32-bit int
private let mainThreadIndex: lua_Integer = 1     // LUA_RIDX_MAINTHREAD
private let noReference: Int32 = -2              // LUA_NOREF

@MainActor private enum Bridge {
  static var state: OpaquePointer?
  static var callback = noReference
  static var controller: ConfigurationWindowController?

  static var window: ConfigurationWindowController {
    if let controller { return controller }
    let created = ConfigurationWindowController(send: send)
    controller = created
    return created
  }

  static func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
    // Leave the SwiftUI action first; Lua may open modal panels.
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        guard let L = state, callback != noReference else { return }
        let top = lua_gettop(L)
        lua_rawgeti(L, registryIndex, lua_Integer(callback))
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
          buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { _ = lua_pushlstring(L, $0, buffer.count) }
        }
        if lua_pcallk(L, 1, 0, 0, 0, nil) != 0 {
          controller?.store.setStatus(luaString(L, -1) ?? "Hammerspoon could not handle the request.", error: true)
        }
        lua_settop(L, top)
      }
    }
  }

  /// Runs when the Lua state closes, so no callback can reach a stale state.
  static func reset() {
    controller?.teardown()
    controller = nil
    state = nil
    callback = noReference
  }
}

private func luaString(_ L: OpaquePointer?, _ index: Int32) -> String? {
  var length = 0
  guard let pointer = lua_tolstring(L, index, &length) else { return nil }
  return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
}

private func register(_ L: OpaquePointer?, _ name: String, _ function: lua_CFunction) {
  lua_pushcclosure(L, function, 0)
  lua_setfield(L, -2, name)
}

@_cdecl("luaopen_configuration_native")
public func luaopen_configuration_native(_ L: OpaquePointer?) -> Int32 {
  MainActor.assumeIsolated {
    Bridge.reset()
    lua_rawgeti(L, registryIndex, mainThreadIndex)
    Bridge.state = lua_tothread(L, -1)
    lua_settop(L, -2)
  }
  lua_createtable(L, 0, 5)
  register(L, "setCallback") { L in
    MainActor.assumeIsolated {
      if Bridge.callback != noReference { luaL_unref(L, registryIndex, Bridge.callback) }
      lua_settop(L, 1)
      Bridge.callback = luaL_ref(L, registryIndex)
    }
    return 0
  }
  register(L, "show") { _ in
    MainActor.assumeIsolated { Bridge.window.show() }
    return 0
  }
  register(L, "receive") { L in
    let text = luaString(L, 1) ?? ""
    MainActor.assumeIsolated {
      guard let data = text.data(using: .utf8),
            let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
      Bridge.controller?.store.receive(message)
    }
    return 0
  }
  register(L, "isVisible") { L in
    let visible = MainActor.assumeIsolated { Bridge.controller?.window?.isVisible ?? false }
    lua_pushboolean(L, visible ? 1 : 0)
    return 1
  }
  register(L, "close") { _ in
    MainActor.assumeIsolated { Bridge.controller?.window?.orderOut(nil) }
    return 0
  }
  lua_createtable(L, 0, 1)
  lua_pushcclosure(L, { _ in MainActor.assumeIsolated { Bridge.reset() }; return 0 }, 0)
  lua_setfield(L, -2, "__gc")
  _ = lua_setmetatable(L, -2)
  return 1
}
