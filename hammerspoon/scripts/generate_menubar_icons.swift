import CoreGraphics
import Foundation
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? "static/menubar", isDirectory: true)
let sourceIconDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("static/menubar/source")

try FileManager.default.createDirectory(at: outputDirectory,
                                        withIntermediateDirectories: true)

let black = CGColor(gray: 0, alpha: 1)
let white = CGColor(gray: 1, alpha: 1)
let gray = CGColor(gray: 0.55, alpha: 1)

func makeContext(at url: URL, color: CGColor = black) -> CGContext {
    var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        fatalError("Unable to create PDF context at \(url.path)")
    }
    context.beginPDFPage(nil as CFDictionary?)
    context.setFillColor(color)
    context.setStrokeColor(color)
    context.setLineCap(CGLineCap.round)
    context.setLineJoin(CGLineJoin.round)
    return context
}

func finish(_ context: CGContext) {
    context.endPDFPage()
    context.closePDF()
}

func drawSteam(_ context: CGContext, sleepy: Bool) {
    if sleepy {
        context.setLineWidth(1.0)
        for points in [
            [(10.5, 14.0), (14.0, 14.0), (10.5, 11.2), (14.0, 11.2)],
            [(13.0, 17.0), (17.0, 17.0), (13.0, 14.0), (17.0, 14.0)]
        ] {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.0, y: point.1))
            }
            context.addPath(path)
            context.strokePath()
        }
        return
    }

    context.setLineWidth(1.0)
    for offset in [0.0, 4.0] {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5.0 + offset, y: 12.0))
        path.addCurve(to: CGPoint(x: 7.0 + offset, y: 14.8),
                      control1: CGPoint(x: 3.7 + offset, y: 13.1),
                      control2: CGPoint(x: 8.3 + offset, y: 13.5))
        path.addCurve(to: CGPoint(x: 7.0 + offset, y: 17.0),
                      control1: CGPoint(x: 5.7 + offset, y: 15.7),
                      control2: CGPoint(x: 8.3 + offset, y: 15.8))
        context.addPath(path)
        context.strokePath()
    }
}

func drawCaffeine(_ context: CGContext, sleepy: Bool) {
    let cup = CGPath(roundedRect: CGRect(x: 2.5, y: 2.8, width: 10.5, height: 8.2),
                     cornerWidth: 1.3, cornerHeight: 1.3, transform: nil)
    context.addPath(cup)
    context.fillPath()

    context.setLineWidth(1.2)
    let handle = CGMutablePath()
    handle.move(to: CGPoint(x: 13.0, y: 9.2))
    handle.addCurve(to: CGPoint(x: 16.2, y: 7.0),
                    control1: CGPoint(x: 15.0, y: 9.2),
                    control2: CGPoint(x: 15.9, y: 8.8))
    handle.addCurve(to: CGPoint(x: 13.0, y: 4.7),
                    control1: CGPoint(x: 16.5, y: 5.3),
                    control2: CGPoint(x: 14.7, y: 4.7))
    context.addPath(handle)
    context.strokePath()

    drawSteam(context, sleepy: sleepy)
}

func drawNode(_ context: CGContext, at point: CGPoint, radius: CGFloat = 1.6) {
    context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                   width: radius * 2, height: radius * 2))
}

func drawProxy(_ context: CGContext, appIcon: NSImage?, color: CGColor = black) {
    context.setFillColor(color)
    context.setStrokeColor(color)
    context.setLineWidth(1.4)
    let center = CGPoint(x: 8.0, y: 9.2)
    let nodes = [CGPoint(x: 4.2, y: 13.3), CGPoint(x: 12.0, y: 13.3),
                 CGPoint(x: 8.0, y: 4.4)]
    for node in nodes {
        let path = CGMutablePath()
        path.move(to: center)
        path.addLine(to: node)
        context.addPath(path)
        context.strokePath()
    }
    drawNode(context, at: center, radius: 2.0)
    for node in nodes { drawNode(context, at: node) }

    guard let appIcon else { return }
    let appIconFrame = CGRect(x: 8.8, y: 0.2, width: 9.0, height: 9.0)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    appIcon.draw(in: appIconFrame,
                 from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

func installedAppIcon(bundleID: String, resourcePaths: [String]) -> NSImage? {
    if let appURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: bundleID) {
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
    for path in resourcePaths {
        if let icon = NSImage(contentsOfFile: path) { return icon }
    }
    return nil
}

func writeIcon(named name: String, color: CGColor = black,
               draw: (CGContext) -> Void) {
    let context = makeContext(at: outputDirectory.appendingPathComponent(name),
                              color: color)
    draw(context)
    finish(context)
}

writeIcon(named: "caffeine-awake.pdf") { drawCaffeine($0, sleepy: false) }
writeIcon(named: "caffeine-sleepy.pdf") { drawCaffeine($0, sleepy: true) }
writeIcon(named: "proxy.pdf", color: white) {
    drawProxy($0, appIcon: nil, color: white)
}
writeIcon(named: "proxy-disabled.pdf", color: gray) {
    drawProxy($0, appIcon: nil, color: gray)
}

let proxyApps = [
    ("v2rayx", "cenmrev.V2RayX", [
        "/Applications/V2RayX.app/Contents/Resources/AppIcon.icns",
        sourceIconDirectory.appendingPathComponent("v2rayx.png").path,
    ]),
    ("v2rayu", "net.yanue.V2rayU", [
        "/Applications/V2rayU.app/Contents/Resources/AppIcon.icns",
        sourceIconDirectory.appendingPathComponent("v2rayu.png").path,
    ]),
    ("v2rayn", "2dust.v2rayN", ["/Applications/v2rayN.app/Contents/Resources/AppIcon.icns"]),
    ("monocloud", "com.MonoCloud.MonoProxyMac", ["/Applications/MonoProxyMac.app/Contents/Resources/AppIcon.icns"]),
]

for name in ["proxy-system.pdf", "proxy-lab-proxy.pdf"] {
    let path = outputDirectory.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: path.path) {
        try FileManager.default.removeItem(at: path)
    }
}

for (name, _, _) in proxyApps {
    let path = outputDirectory.appendingPathComponent("proxy-\(name).pdf")
    if FileManager.default.fileExists(atPath: path.path) {
        try FileManager.default.removeItem(at: path)
    }
}

for (name, bundleID, resourcePaths) in proxyApps {
    if let icon = installedAppIcon(bundleID: bundleID, resourcePaths: resourcePaths) {
        writeIcon(named: "proxy-\(name).pdf", color: white) {
            drawProxy($0, appIcon: icon, color: white)
        }
    }
}
