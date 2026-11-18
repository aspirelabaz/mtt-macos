import AppKit

// Renders MTT's app icon at 1024x1024 (macOS icon grid: 824pt body, 100pt margin).
// Usage: swiftc -O scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon icon_1024.png
// then resize into App/MTT/Assets.xcassets/AppIcon.appiconset (see its Contents.json).
let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Body: rounded square with a soft shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

// Gradient: green (Android side) to blue (Mac side), diagonal.
ctx.saveGState()
ctx.addPath(path); ctx.clip()
let colors = [NSColor(red: 0.20, green: 0.80, blue: 0.52, alpha: 1).cgColor,
              NSColor(red: 0.10, green: 0.55, blue: 0.85, alpha: 1).cgColor,
              NSColor(red: 0.22, green: 0.30, blue: 0.80, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 120, y: 920), end: CGPoint(x: 900, y: 110), options: [])
// Subtle top highlight.
let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, in rect: CGRect, color: NSColor) {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else {
        fatalError("missing symbol \(name)")
    }
    // Keep aspect ratio, centered in rect.
    let s = img.size
    let scale = min(rect.width / s.width, rect.height / s.height)
    let w = s.width * scale, h = s.height * scale
    img.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
}

// Phone: white body, light screen with a folder, small camera dot.
let phone = CGRect(x: 250, y: 215, width: 380, height: 600)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 70, cornerHeight: 70, transform: nil))
ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
ctx.restoreGState()

let screen = phone.insetBy(dx: 26, dy: 26)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 48, cornerHeight: 48, transform: nil)); ctx.clip()
let screenGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(red: 0.86, green: 0.96, blue: 0.93, alpha: 1).cgColor,
             NSColor(red: 0.82, green: 0.90, blue: 0.99, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(screenGrad, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
ctx.restoreGState()

// Camera dot.
ctx.setFillColor(NSColor(red: 0.18, green: 0.24, blue: 0.32, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: phone.midX - 14, y: screen.maxY - 44, width: 28, height: 28))

// Folder on the screen.
drawSymbol("folder.fill", pointSize: 200, weight: .regular,
           in: CGRect(x: screen.midX - 115, y: screen.midY - 40, width: 230, height: 200),
           color: NSColor(red: 0.13, green: 0.58, blue: 0.86, alpha: 1))

// Transfer badge: white circle with two-way arrows, bottom right.
let badge = CGRect(x: 545, y: 170, width: 290, height: 290)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillEllipse(in: badge)
ctx.restoreGState()
drawSymbol("arrow.left.arrow.right", pointSize: 160, weight: .bold, in: badge.insetBy(dx: 62, dy: 62),
           color: NSColor(red: 0.12, green: 0.50, blue: 0.84, alpha: 1))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
