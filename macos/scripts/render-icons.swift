// Renders worker/public/icon.svg into the web PNG icons and the macOS AppIcon.iconset.
// Usage: swift macos/scripts/render-icons.swift <repo-root>
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let svgURL = root.appending(path: "worker/public/icon.svg")
let svgText = try String(contentsOf: svgURL, encoding: .utf8)

func image(_ svg: String) -> NSImage {
    guard let image = NSImage(data: Data(svg.utf8)) else {
        FileHandle.standardError.write("NSImage could not read the SVG\n".data(using: .utf8)!)
        exit(1)
    }
    return image
}

func writePNG(_ source: NSImage, size: Int, inset: CGFloat, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw CocoaError(.fileWriteUnknown) }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let side = CGFloat(size)
    let rect = NSRect(x: side * inset, y: side * inset, width: side * (1 - 2 * inset), height: side * (1 - 2 * inset))
    source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let rounded = image(svgText)
// iOS masks home-screen icons itself, so that PNG is full-bleed with square corners.
let square = image(svgText.replacingOccurrences(of: #"rx="114""#, with: #"rx="0""#))

let publicDir = root.appending(path: "worker/public")
try writePNG(square, size: 180, inset: 0, to: publicDir.appending(path: "apple-touch-icon.png"))
try writePNG(square, size: 512, inset: 0, to: publicDir.appending(path: "icon-512.png"))

// macOS app icons sit inside a 1024 canvas with about 10% margin.
let iconset = root.appending(path: "macos/Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try writePNG(rounded, size: base, inset: 0.098, to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try writePNG(rounded, size: base * 2, inset: 0.098, to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
print("rendered icons from \(svgURL.path)")
