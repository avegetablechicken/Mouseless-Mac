import AppKit
import CoreText

// Native rasterizer for the generator's rect/line/text SVG subset.
final class SVG: NSObject, XMLParserDelegate {
    let context: CGContext
    let outlineText: Bool
    var textAttributes: [String: String] = [:]
    var characters = ""
    init(_ context: CGContext, outlineText: Bool = false) { self.context = context; self.outlineText = outlineText }
    func color(_ value: String?) -> CGColor? {
        guard let value = value, value.hasPrefix("#"), let rgb = UInt32(value.dropFirst(), radix: 16) else { return nil }
        return CGColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        func n(_ key: String) -> CGFloat { CGFloat(Double(a[key] ?? "0") ?? 0) }
        if name == "text" { textAttributes = a; characters = ""; return }
        context.setLineWidth(n("stroke-width"))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let p: CGPath
        if name == "rect" {
            p = CGPath(roundedRect: CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height")), cornerWidth: n("rx"), cornerHeight: n("rx"), transform: nil)
        } else if name == "line" {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: n("x1"), y: n("y1")))
            path.addLine(to: CGPoint(x: n("x2"), y: n("y2")))
            p = path
        } else { return }
        if let fill = color(a["fill"]) { context.setFillColor(fill); context.addPath(p); context.fillPath() }
        if let stroke = color(a["stroke"]) { context.setStrokeColor(stroke); context.addPath(p); context.strokePath() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { characters += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name != "text" { return }
        let a = textAttributes
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(Double(a["font-size"]!)!), nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(a["fill"])!]
        let text = NSAttributedString(string: characters, attributes: attrs)
        let line = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.saveGState()
        context.translateBy(x: CGFloat(Double(a["x"]!)!) - CGFloat(width) / 2, y: CGFloat(Double(a["y"]!)!))
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        if outlineText {
            context.setFillColor(color(a["fill"])!)
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for i in 0..<count {
                    var transform = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
                    if let path = CTFontCreatePathForGlyph(font, glyphs[i], &transform) {
                        context.addPath(path); context.fillPath()
                    }
                }
            }
        } else { CTLineDraw(line, context) }
        context.restoreGState()
    }
}
func bitmap(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func write(_ context: CGContext, _ path: String) throws {
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
let source = CommandLine.arguments[1], destination = CommandLine.arguments[2]
let pdfMode = CommandLine.arguments.dropFirst(3).contains("--pdf")
let svgMode = CommandLine.arguments.dropFirst(3).contains("--verify-svg")
let lines = try String(contentsOfFile: source + "/manifest.tsv", encoding: .utf8).split(separator: "\n")
let cellW = 220, cellH = 142, columns = 5, rows = (lines.count + 4) / 5 + (svgMode ? 1 : 0)
let sheet = bitmap(columns * cellW, rows * cellH)
sheet.setFillColor(CGColor(gray: 1, alpha: 1)); sheet.fill(CGRect(x: 0, y: 0, width: columns * cellW, height: rows * cellH))
if svgMode {
    let apps = ["/Applications/Hammerspoon.app", "/System/Applications/Calculator.app",
                "/System/Applications/Notes.app", "/System/Applications/System Settings.app",
                "/System/Applications/Utilities/Terminal.app"]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: sheet, flipped: false)
    for (index, app) in apps.enumerated() {
        let x = index * cellW, y = (rows - 1) * cellH
        NSWorkspace.shared.icon(forFile: app).draw(in: CGRect(x: x + 62, y: y + 31, width: 96, height: 96))
        let name = URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
        let label = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        sheet.textPosition = CGPoint(x: CGFloat(x + 110) - CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil)) / 2, y: CGFloat(y + 16))
        CTLineDraw(label, sheet)
    }
    NSGraphicsContext.restoreGraphicsState()
}
for (index, line) in lines.enumerated() {
    let fields = line.split(separator: "\t").map(String.init)
    let c = bitmap(192, 192)
    if svgMode {
        let url = URL(fileURLWithPath: source + "/" + fields[0] + ".svg")
        guard let image = NSImage(contentsOf: url), image.isValid,
              image.size == NSSize(width: 192, height: 192) else { fatalError("Invalid native SVG: " + fields[0]) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: 192, height: 192))
        NSGraphicsContext.restoreGraphicsState()
        let pixels = c.data!.assumingMemoryBound(to: UInt8.self)
        guard pixels[3] == 0, (0..<192*192).contains(where: { pixels[$0*4+3] > 0 })
            else { fatalError("Empty or opaque SVG: " + fields[0]) }
    } else {
        var mediaBox = CGRect(x: 0, y: 0, width: 192, height: 192)
        let pdfURL = URL(fileURLWithPath: destination + "/" + fields[0] + ".pdf")
        let drawing: CGContext
        if pdfMode {
            drawing = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil)!
            drawing.beginPDFPage(nil)
        } else { drawing = c }
        drawing.translateBy(x: 0, y: 192); drawing.scaleBy(x: 2, y: -2)
        let parser = XMLParser(data: try Data(contentsOf: URL(fileURLWithPath: source + "/" + fields[0] + ".svg")))
        let delegate = SVG(drawing, outlineText: pdfMode); parser.delegate = delegate
        guard parser.parse() else { fatalError("Invalid SVG: " + fields[0]) }
        if pdfMode {
            drawing.endPDFPage(); drawing.closePDF()
            let document = CGPDFDocument(pdfURL as CFURL)!
            guard document.numberOfPages == 1, let page = document.page(at: 1),
                  page.getBoxRect(.mediaBox) == mediaBox else { fatalError("Invalid PDF: " + fields[0]) }
            c.drawPDFPage(page)
            guard NSImage(contentsOf: pdfURL) != nil else { fatalError("AppKit cannot load " + fields[0]) }
        } else { try write(c, destination + "/" + fields[0] + ".png") }
    }
    let x = (index % columns) * cellW, y = (rows - 1 - (svgMode ? 1 : 0) - index / columns) * cellH
    sheet.draw(c.makeImage()!, in: CGRect(x: x + 62, y: y + 31, width: 96, height: 96))
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
    let label = CTLineCreateWithAttributedString(NSAttributedString(string: fields[1], attributes: attrs))
    sheet.textPosition = CGPoint(x: CGFloat(x + 110) - CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil)) / 2, y: CGFloat(y + 16))
    CTLineDraw(label, sheet)
}
try write(sheet, svgMode ? destination + "/svg-preview.png" : (pdfMode ? source + "/pdf-preview.png" : destination + "/preview.png"))
print(svgMode ? "Verified native SVG rendering and transparency for \(lines.count) icons" : (pdfMode ? "Exported and verified \(lines.count) vector PDFs; preview: \(source)/pdf-preview.png" : "Rendered \(lines.count) transparent PNGs and preview.png"))
