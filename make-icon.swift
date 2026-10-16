// 生成 IconKeeper 自己的图标：1024 满版方图，系统会自动裁成圆角
// 用法：make-icon <输出 png>
import AppKit

let size = 1024
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSGradient(
    starting: NSColor(srgbRed: 0.99, green: 0.74, blue: 0.85, alpha: 1),
    ending: NSColor(srgbRed: 0.64, green: 0.55, blue: 0.88, alpha: 1))!
    .draw(in: rect, angle: -60)

// 两层分开上色：对勾用渐变里的紫，盾牌用白
let config = NSImage.SymbolConfiguration(pointSize: 600, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: 0.70, green: 0.50, blue: 0.86, alpha: 1), .white]))
if let symbol = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
