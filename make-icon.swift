#!/usr/bin/env swift
// Génère AppIcon.icns pour VoxPrompt (fond blanc, accent iris, glyphe waveform).
// Usage : swift make-icon.swift Resources/AppIcon.icns
import AppKit
import CoreGraphics

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon.icns"

// Tailles requises pour un .icns macOS
let sizes: [(px: Int, scale: Int, label: String)] = [
    (16, 1, "16x16"),       (32, 2, "16x16@2x"),
    (32, 1, "32x32"),       (64, 2, "32x32@2x"),
    (128, 1, "128x128"),    (256, 2, "128x128@2x"),
    (256, 1, "256x256"),    (512, 2, "256x256@2x"),
    (512, 1, "512x512"),    (1024, 2, "512x512@2x"),
]

func render(size: CGFloat) -> Data? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // macOS squircle : radius ≈ 22.37% du côté
    let r = size * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // Background gradient : blanc cassé en haut → iris très pâle en bas
    let colors = [
        NSColor(calibratedRed: 1.00, green: 1.00, blue: 1.00, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.94, green: 0.92, blue: 1.00, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.88, green: 0.84, blue: 1.00, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors, locations: [0.0, 0.5, 1.0])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: size * 0.2, y: size),
                           end: CGPoint(x: size * 0.8, y: 0),
                           options: [])

    // Iris glow spot en haut à droite
    if size >= 128 {
        let glowColors = [
            NSColor(calibratedRed: 0.55, green: 0.40, blue: 1.00, alpha: 0.55).cgColor,
            NSColor(calibratedRed: 0.55, green: 0.40, blue: 1.00, alpha: 0.0).cgColor,
        ] as CFArray
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: glowColors, locations: [0.0, 1.0])!
        ctx.drawRadialGradient(glow,
                               startCenter: CGPoint(x: size * 0.75, y: size * 0.75),
                               startRadius: 0,
                               endCenter: CGPoint(x: size * 0.75, y: size * 0.75),
                               endRadius: size * 0.55,
                               options: [])
    }

    // Waveform bars — centrées
    let barCount = 5
    let barWidth = size * 0.07
    let spacing  = size * 0.045
    let totalW = barWidth * CGFloat(barCount) + spacing * CGFloat(barCount - 1)
    let startX = (size - totalW) / 2
    let midY   = size / 2
    // Hauteurs stylisées, pas aléatoires — pour un look propre
    let heightsRatio: [CGFloat] = [0.22, 0.48, 0.36, 0.60, 0.28]

    ctx.saveGState()
    // Léger gradient iris sur les barres
    let barGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [
                                NSColor(calibratedRed: 0.40, green: 0.33, blue: 0.98, alpha: 1).cgColor,
                                NSColor(calibratedRed: 0.85, green: 0.40, blue: 0.95, alpha: 1).cgColor,
                             ] as CFArray,
                             locations: [0.0, 1.0])!

    for i in 0..<barCount {
        let h = size * heightsRatio[i]
        let x = startX + CGFloat(i) * (barWidth + spacing)
        let bar = CGRect(x: x, y: midY - h/2, width: barWidth, height: h)
        let barPath = CGPath(roundedRect: bar, cornerWidth: barWidth/2, cornerHeight: barWidth/2, transform: nil)
        ctx.saveGState()
        ctx.addPath(barPath)
        ctx.clip()
        ctx.drawLinearGradient(barGrad,
                               start: CGPoint(x: x, y: midY - h/2),
                               end: CGPoint(x: x + barWidth, y: midY + h/2),
                               options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // Bord intérieur très subtil
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                       cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.05).cgColor)
    ctx.setLineWidth(1)
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let fm = FileManager.default
let outURL = URL(fileURLWithPath: outPath)
let iconsetDir = outURL.deletingLastPathComponent()
    .appendingPathComponent("AppIcon.iconset")

try? fm.removeItem(at: iconsetDir)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for s in sizes {
    let finalSize = s.px * s.scale
    guard let data = render(size: CGFloat(finalSize)) else { continue }
    let name = "icon_\(s.label).png"
    let fileURL = iconsetDir.appendingPathComponent(name)
    try data.write(to: fileURL)
    print("  \(name) — \(finalSize)px")
}

// Convertir en .icns via iconutil
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", outURL.path]
try proc.run()
proc.waitUntilExit()

if proc.terminationStatus == 0 {
    print("✅ \(outURL.path)")
    try? fm.removeItem(at: iconsetDir)
} else {
    print("❌ iconutil a échoué")
    exit(1)
}
