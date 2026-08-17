// Genera Resources/BatutaMLX.icns dibujando el icono por código (sin recursos
// binarios que revisar a ciegas ni herramientas de diseño).
//   swift make-icon.swift
// Cada tamaño se dibuja de nuevo — no se reescala — para que los 16 px se vean
// nítidos en el Finder y en la lista de ítems de inicio.

import AppKit
import Foundation

/// Dibuja el icono a un tamaño dado. Todas las medidas son fracciones de `s`
/// para que la composición sea idéntica en cada resolución.
func drawIcon(size s: CGFloat, in ctx: CGContext) {
    // Fondo: «squircle» con degradado índigo → violeta, el gesto de macOS 26.
    let inset = s * 0.045
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.235
    let bg = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                    transform: nil)
    ctx.saveGState()
    ctx.addPath(bg)
    ctx.clip()
    let colors = [
        CGColor(red: 0.20, green: 0.18, blue: 0.42, alpha: 1),
        CGColor(red: 0.42, green: 0.25, blue: 0.72, alpha: 1),
    ] as CFArray
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s),
                               end: CGPoint(x: s, y: 0), options: [])
    }
    ctx.restoreGState()

    // Arco de movimiento: el gesto que traza la batuta al dirigir.
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.30))
    ctx.setLineWidth(s * 0.052)
    ctx.setLineCap(.round)
    let arc = CGMutablePath()
    arc.addArc(center: CGPoint(x: s * 0.50, y: s * 0.46), radius: s * 0.275,
               startAngle: .pi * 0.92, endAngle: .pi * 1.72, clockwise: false)
    ctx.addPath(arc)
    ctx.strokePath()
    ctx.restoreGState()

    // La batuta: mango grueso abajo-izquierda, punta fina arriba-derecha.
    let grip = CGPoint(x: s * 0.315, y: s * 0.290)
    let tip = CGPoint(x: s * 0.735, y: s * 0.760)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
    // Cuerpo cónico: dos bordes que convergen en la punta.
    let dx = tip.x - grip.x, dy = tip.y - grip.y
    let len = sqrt(dx * dx + dy * dy)
    let nx = -dy / len, ny = dx / len            // normal unitaria
    let halfGrip = s * 0.038, halfTip = s * 0.011
    let shaft = CGMutablePath()
    shaft.move(to: CGPoint(x: grip.x + nx * halfGrip, y: grip.y + ny * halfGrip))
    shaft.addLine(to: CGPoint(x: tip.x + nx * halfTip, y: tip.y + ny * halfTip))
    shaft.addArc(center: tip, radius: halfTip,
                 startAngle: atan2(ny, nx), endAngle: atan2(-ny, -nx), clockwise: true)
    shaft.addLine(to: CGPoint(x: grip.x - nx * halfGrip, y: grip.y - ny * halfGrip))
    shaft.closeSubpath()
    ctx.addPath(shaft)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
    // Pomo del mango.
    ctx.addEllipse(in: CGRect(x: grip.x - s * 0.072, y: grip.y - s * 0.072,
                              width: s * 0.144, height: s * 0.144))
    ctx.setFillColor(CGColor(red: 0.99, green: 0.97, blue: 0.94, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    drawIcon(size: CGFloat(size), in: gctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: ".build/BatutaMLX.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// Nombres que exige iconutil.
for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                      (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try png(size: base * scale).write(to: iconset.appendingPathComponent(name))
}

try? fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let out = Process()
out.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
out.arguments = ["-c", "icns", iconset.path, "-o", "Resources/BatutaMLX.icns"]
try out.run()
out.waitUntilExit()
guard out.terminationStatus == 0 else { exit(out.terminationStatus) }
print("Resources/BatutaMLX.icns generado")
