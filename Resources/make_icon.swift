// Genera Resources/AppIcon.icns: swift Resources/make_icon.swift
import AppKit

func drawIcon(_ ctx: CGContext, size: CGFloat) {
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    let space = CGColorSpaceCreateDeviceRGB()
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    }
    func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
    }

    // Corpo: griglia icone macOS (824×824 su tela 1024)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath); ctx.setFillColor(color(0x1B2638)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x34486B), color(0x101826)], [0, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    let center = CGPoint(x: 512, y: 500)

    // Ghiera esterna
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.5))
    ctx.addPath(circle(center, 300)); ctx.setFillColor(color(0x1A202C)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(circle(center, 300)); ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x4A5670), color(0x161B26)], [0, 1]),
                           start: CGPoint(x: 512, y: 800), end: CGPoint(x: 512, y: 200), options: [])
    ctx.restoreGState()
    ctx.addPath(circle(center, 236)); ctx.setFillColor(color(0x080B12)); ctx.fillPath()

    // Lente
    ctx.saveGState()
    ctx.addPath(circle(center, 210)); ctx.clip()
    ctx.drawRadialGradient(gradient([color(0x5B8CFF), color(0x2346A8), color(0x0A1430)], [0, 0.45, 1]),
                           startCenter: CGPoint(x: 470, y: 560), startRadius: 10,
                           endCenter: center, endRadius: 210, options: [])
    ctx.restoreGState()
    ctx.addPath(circle(center, 210)); ctx.setStrokeColor(color(0x7FA2FF, 0.35)); ctx.setLineWidth(6); ctx.strokePath()

    // Pupilla e riflessi
    ctx.addPath(circle(center, 92)); ctx.setFillColor(color(0x03060C)); ctx.fillPath()
    ctx.addPath(CGPath(ellipseIn: CGRect(x: 405, y: 560, width: 120, height: 80), transform: nil))
    ctx.setFillColor(color(0xFFFFFF, 0.38)); ctx.fillPath()
    ctx.addPath(circle(CGPoint(x: 585, y: 430), 22)); ctx.setFillColor(color(0xFFFFFF, 0.22)); ctx.fillPath()

    // Pallino REC
    let rec = CGPoint(x: 772, y: 772)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: color(0xFF3B30, 0.9))
    ctx.addPath(circle(rec, 50)); ctx.setFillColor(color(0xFF3B30)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(circle(CGPoint(x: rec.x - 14, y: rec.y + 16), 16)); ctx.setFillColor(color(0xFFFFFF, 0.45)); ctx.fillPath()
}

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Una sola immagine per dimensione in pixel, massimo 512 px: le PNG con sfumature e ombre pesano molto
// (la 1024 px da sola ~470 KB) e i duplicati 1x/2x raddoppierebbero il file. Obiettivo: app < 1 MB.
for (base, scale) in [(16, 1), (16, 2), (32, 2), (128, 1), (128, 2), (256, 2)] {
    let px = base * scale
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawIcon(ctx, size: CGFloat(px))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}

let out = dir.appendingPathComponent("AppIcon.icns").path
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out]
try! task.run(); task.waitUntilExit()
try! FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_256x256@2x.png"),
                                  to: FileManager.default.temporaryDirectory.appendingPathComponent("rtspoverlay-icon-preview.png"))
print(task.terminationStatus == 0 ? "Creato \(out)" : "iconutil fallito")
