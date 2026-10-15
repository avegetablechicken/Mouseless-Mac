// Hosts the SwiftUI configuration view in a regular titled window.
import AppKit
import SwiftUI

@MainActor final class ConfigurationWindowController: NSObject, NSWindowDelegate {
  let store = Store()
  private(set) var window: NSWindow?

  init(send: @escaping ([String: Any]) -> Void) {
    store.send = send
  }

  func show() {
    if window == nil {
      window = makeWindow()
      store.load()
    }
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
  }

  /// Closing only hides the window; drafts stay until Hammerspoon reloads.
  func teardown() {
    window?.delegate = nil
    window?.orderOut(nil)
    window?.contentViewController = nil
    window = nil
  }

  private func makeWindow() -> NSWindow {
    let host = NSHostingController(rootView: ConfigurationView().environment(store))
    host.sceneBridgingOptions = [.toolbars, .title]
    let window = NSWindow(contentViewController: host)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.title = "Configuration"
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.minSize = NSSize(width: 820, height: 540)
    let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let size = NSSize(width: min(1080, screen.width - 60), height: min(780, screen.height - 60))
    window.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: false)
    window.setFrameUsingName("HammerspoonConfiguration")
    window.setFrameAutosaveName("HammerspoonConfiguration")
    return window
  }
}
