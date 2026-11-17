// Gera os ícones do AirView no estilo vidro do macOS (fundo azul vibrante + TV de vidro fosco + brilho especular).
// Uso: swift mac/Assets/make_icons.swift   (a partir da pasta do projeto)
// Saídas: mac/Assets/AppIcon.icns, android/res/drawable-xhdpi/{icon,banner}.png
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Desenha o símbolo (TV de vidro + ondas) dentro de `rect`.
func drawGlassTV(in rect: NSRect) {
    let u = rect.width / 100 // unidade relativa

    // Tela de vidro fosco
    let screen = NSRect(x: rect.minX + 14 * u, y: rect.minY + 30 * u, width: 72 * u, height: 50 * u)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 9 * u, yRadius: 9 * u)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x06204F, 0.35)
    shadow.shadowBlurRadius = 6 * u
    shadow.shadowOffset = NSSize(width: 0, height: -2.5 * u)
    shadow.set()
    color(0xFFFFFF, 0.16).setFill()
    screenPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0xFFFFFF, 0.42), color(0xFFFFFF, 0.10), color(0xFFFFFF, 0.04)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: screenPath, angle: -70)
    // Borda luminosa (mais forte em cima, como luz batendo no vidro)
    NSGraphicsContext.saveGraphicsState()
    screenPath.lineWidth = 1.6 * u
    screenPath.addClip()
    color(0xFFFFFF, 0.55).setStroke()
    screenPath.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let rim = NSBezierPath(roundedRect: screen.insetBy(dx: 0.8 * u, dy: 0.8 * u), xRadius: 8.2 * u, yRadius: 8.2 * u)
    let rimStroke = NSBezierPath(cgPath: rim.cgPath.copy(strokingWithWidth: 0.9 * u, lineCap: .round,
                                                         lineJoin: .round, miterLimit: 1))
    NSGradient(colors: [color(0xFFFFFF, 0.9), color(0xFFFFFF, 0.0)])!.draw(in: rimStroke, angle: -90)

    // Pé
    let neck = NSBezierPath(roundedRect: NSRect(x: rect.midX - 3 * u, y: rect.minY + 22 * u, width: 6 * u, height: 8 * u),
                            xRadius: 1.5 * u, yRadius: 1.5 * u)
    color(0xFFFFFF, 0.30).setFill()
    neck.fill()
    let base = NSBezierPath(roundedRect: NSRect(x: rect.midX - 15 * u, y: rect.minY + 18 * u, width: 30 * u, height: 5 * u),
                            xRadius: 2.5 * u, yRadius: 2.5 * u)
    NSGradient(colors: [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0.25)])!.draw(in: base, angle: -90)

    // Ondas de transmissão saindo do centro da tela
    let center = NSPoint(x: screen.midX, y: screen.minY + 13 * u)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0xFFFFFF, 0.6)
    glow.shadowBlurRadius = 3 * u
    glow.set()
    color(0xFFFFFF).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 3.6 * u, y: center.y - 3.6 * u, width: 7.2 * u, height: 7.2 * u)).fill()
    for (i, radius) in [11.0, 19.0, 27.0].enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: CGFloat(radius) * u, startAngle: 38, endAngle: 142)
        arc.lineWidth = 3.6 * u
        arc.lineCapStyle = .round
        color(0xFFFFFF, 1 - CGFloat(i) * 0.22).setStroke()
        arc.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// Fundo vibrante com brilho especular, recortado em `path`.
func drawBackground(_ path: NSBezierPath, in rect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [color(0x38C8F8), color(0x2F7BF5), color(0x1747C8)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: rect, angle: -50)
    // Luz suave no canto superior esquerdo
    NSGradient(colors: [color(0xA5F3FF, 0.5), color(0xA5F3FF, 0)])!
        .draw(fromCenter: NSPoint(x: rect.minX + rect.width * 0.2, y: rect.maxY - rect.height * 0.15), radius: 0,
              toCenter: NSPoint(x: rect.minX + rect.width * 0.2, y: rect.maxY - rect.height * 0.15),
              radius: rect.width * 0.7, options: [])
    // Brilho especular do vidro no topo
    let sheen = NSBezierPath(ovalIn: NSRect(x: rect.minX - rect.width * 0.25, y: rect.minY + rect.height * 0.52,
                                            width: rect.width * 1.5, height: rect.height * 0.9))
    NSGradient(colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0.0)])!.draw(in: sheen, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // Contorno fino de vidro
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    path.lineWidth = max(1, rect.width * 0.012)
    color(0xFFFFFF, 0.35).setStroke()
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func render(width: Int, height: Int, _ draw: (NSRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Ícone quadrado: fundo arredondado (grade de ícones do macOS: 824/1024 com margem) + símbolo.
func appIcon(size: Int, margin: CGFloat) -> Data {
    render(width: size, height: size) { rect in
        let inset = rect.width * margin
        let tile = rect.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0x000000, 0.28)
        shadow.shadowBlurRadius = rect.width * 0.025
        shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.01)
        shadow.set()
        color(0x2F7BF5).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        drawBackground(path, in: tile)
        drawGlassTV(in: tile.insetBy(dx: tile.width * 0.08, dy: tile.width * 0.08))
    }
}

func write(_ data: Data, _ relative: String) {
    let url = root.appendingPathComponent(relative)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

// macOS: .iconset → .icns
let iconset = root.appendingPathComponent("mac/Assets/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
for base in [16, 32, 128, 256, 512] {
    write(appIcon(size: base, margin: 100.0 / 1024), "mac/Assets/AppIcon.iconset/icon_\(base)x\(base).png")
    write(appIcon(size: base * 2, margin: 100.0 / 1024), "mac/Assets/AppIcon.iconset/icon_\(base)x\(base)@2x.png")
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("mac/Assets/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

// Android TV: ícone do app e banner da tela inicial (xhdpi = resolução de TV 1080p)
write(appIcon(size: 192, margin: 0.04), "android/res/drawable-xhdpi/icon.png")
write(render(width: 640, height: 360) { rect in
    let path = NSBezierPath(rect: rect)
    drawBackground(path, in: rect)
    drawGlassTV(in: NSRect(x: rect.minX + 30, y: rect.midY - 120, width: 240, height: 240))
    let style = NSMutableParagraphStyle()
    style.alignment = .left
    let title = NSAttributedString(string: "AirView", attributes: [
        .font: NSFont.systemFont(ofSize: 74, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: style,
    ])
    let size = title.boundingRect(with: NSSize(width: 340, height: 360), options: [.usesLineFragmentOrigin])
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x06204F, 0.35)
    shadow.shadowBlurRadius = 8
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.set()
    title.draw(in: NSRect(x: 290, y: rect.midY - size.height / 2, width: 340, height: size.height))
    NSGraphicsContext.restoreGraphicsState()
}, "android/res/drawable-xhdpi/banner.png")

print("Ícones gerados.")
