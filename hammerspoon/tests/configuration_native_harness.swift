// Standalone host for the native Configuration window, for checking layout without
// loading it into Hammerspoon. Reads config files but never writes them.
//
//   cd ~/.hammerspoon && xcrun swiftc -parse-as-library -swift-version 5 \
//     src/configuration/{JSON,Model,Components,Controls,Shortcut,Nodes,Pages,Panels,Sync,Views,Window}.swift \
//     tests/configuration_native_harness.swift -o /tmp/configuration-harness
//   /tmp/configuration-harness [--config DIR] [--tab GROUP,TAB] [--open FILE:PATH] [--sheet FILE:PATH] [--dark] [--edit-json] [--snapshot FILE.png]
import AppKit
import SwiftUI

@main @MainActor enum Harness {
  static var controller: ConfigurationWindowController!

  static func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
  }

  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let directory = argument("--config") ?? NSHomeDirectory() + "/.hammerspoon"
    controller = ConfigurationWindowController { message in
      DispatchQueue.main.async { handle(message, directory: directory) }
    }
    if CommandLine.arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
    controller.show()
    controller.window?.animationBehavior = .none
    if let tab = argument("--tab")?.split(separator: ",").compactMap({ Int($0) }), tab.count == 2 {
      controller.store.selection = TabID(group: tab[0], tab: tab[1])
    }
    if let snapshot = argument("--snapshot") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        if let window = controller.window {
          let task = Process()
          task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
          task.arguments = ["-x", "-o", "-l", String(window.windowNumber), snapshot]
          try? task.run(); task.waitUntilExit()
        }
        exit(0)
      }
    }
    app.run()
  }

  static func handle(_ message: [String: Any], directory: String) {
    let store = controller.store
    switch message["action"] as? String {
    case "load":
      var files: [String: Any] = [:]
      for name in ["misc", "keybindings", "application", "proxy", "proxy-local", "sync", "localization"] {
        let path = directory + "/config/" + name + ".json"
        if let raw = try? String(contentsOfFile: path, encoding: .utf8) { files[name] = ["raw": raw] }
        else { files[name] = ["raw": "{}", "missing": true] }
      }
      var bindings: [String: Any] = [:]
      if let raw = (files["keybindings"] as? [String: Any])?["raw"] as? String,
         let launcher = (try? JSONParser.parse(raw))?["hotkeys"]?["appkeys"]?.array {
        for (index, entry) in launcher.enumerated() {
          let id = entry["bundleID"]?.string ?? entry["bundleID"]?[0]?.string
          if let id, NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            bindings[String(index)] = ["appid": id, "source": entry.any]
          }
        }
      }
      let proxies = ["V2RayX": "cenmrev.V2RayX", "V2rayU": "net.yanue.V2rayU", "v2rayN": "2dust.v2rayN",
                     "MonoCloud": "com.MonoCloud.MonoProxyMac", "Clash Verge Rev": "io.github.clash-verge-rev.clash-verge-rev"]
      store.receive(["action": "loaded", "files": files, "appNames": [String: Any](), "configdir": directory,
                     "proxyApps": proxies.mapValues { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
                     "appBindings": bindings])
      // --prompt-multiline shows a multi-line text prompt.
      if CommandLine.arguments.contains("--prompt-multiline") {
        store.ask(PromptRequest(title: "Add Cleanup Pattern", label: "Pattern", initial: "(.*)\n\nSource: .*", monospaced: true, multiline: true, commit: { _ in }))
      }
      if CommandLine.arguments.contains("--edit-json"), let draft = store.drafts[store.file] {
        store.editJSON("Edit \(store.file).json", draft) { _ in }
      }
      // --open misc:proxy/0/candidates/1 pushes the page for that entry.
      if let target = argument("--open"), let colon = target.firstIndex(of: ":") {
        let file = String(target[..<colon])
        var path: Path = []
        for part in target[target.index(after: colon)...].split(separator: "/") {
          path.append(Int(part).map { .i($0) } ?? .k(String(part)))
        }
        store.open(file, path, title: store.displayTitle(file, path, store.value(file, path), path.last!.description))
      }
      // --panel kind:args opens an editor sheet, e.g. verification:0 or proxyClient:proxy:v2rayN.
      if let spec = argument("--panel")?.split(separator: ":", omittingEmptySubsequences: false).map(String.init), let kind = spec.first {
        switch kind {
        case "verification": store.panel = .verification(Int(spec[1]) ?? 0)
        case "appLauncher": store.panel = .appLauncher(Int(spec[1]) ?? 0)
        case "remote": store.panel = .remoteDesktop(spec[1])
        case "window": store.panel = .windowRule(list: spec[1], index: Int(spec[2]) ?? 0, app: spec[3])
        case "duck": store.panel = .mountainDuck(Int(spec[1]) ?? 0)
        case "proxyClient": store.panel = .proxyClient(file: spec[1], name: spec[2])
        case "inputSources": store.panel = .inputSources(spec[1])
        case "resource": store.panel = .resource(spec[1])
        case "syncFile": store.panel = .syncFile(spec.dropFirst().joined(separator: ":"))
        case "syncVariable": store.panel = .syncVariable(spec[1])
        case "shortcut":
          let path: Path = spec[2].split(separator: "/").map { Int($0).map { .i($0) } ?? .k(String($0)) }
          store.panel = .shortcut(file: spec[1], path: path, title: path.last?.description ?? "")
        default: break
        }
      }
      // --sheet keybindings:hotkeys/com.apple.Terminal/someAction opens details in a sheet.
      if let target = argument("--sheet"), let colon = target.firstIndex(of: ":") {
        let file = String(target[..<colon])
        let path: Path = target[target.index(after: colon)...].split(separator: "/").map { Int($0).map { .i($0) } ?? .k(String($0)) }
        store.present(NodeRoute(file: file, path: path, title: store.displayTitle(file, path, store.value(file, path), path.last!.description)), from: .page)
      }
    case "save":
      print("SAVE", message["name"] ?? "", (message["raw"] as? String)?.count ?? 0)
      store.receive(["action": "saved", "name": message["name"] ?? "", "raw": message["raw"] ?? ""])
    case "browsePath":
      store.receive(["action": "browsed", "id": message["id"] ?? "", "cancelled": true])
    case "browseApplication":
      store.receive(["action": "applicationBrowsed", "id": message["id"] ?? "", "cancelled": true])
    case "reload":
      print("RELOAD")
      store.receive(["action": "reloadFailed"])
    default: break
    }
  }
}
