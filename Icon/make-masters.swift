#!/usr/bin/env swift
//
// make-masters.swift
//
// Regenerates the editable placeholder master images for Beamhook's icons:
//   Icon/master-1024.png    — 1024x1024 app-icon master (blue→indigo rounded rect + white glyph)
//   Icon/menubar-master.png — 64x64 monochrome (black + alpha) menubar template glyph
//
// These masters are the editable sources. To resize them into the actual asset
// catalog PNGs, run ./Icon/make-icons.sh afterwards.
//
// Usage:  swift Icon/make-masters.swift
//

import AppKit
import Foundation

let iconDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

// MARK: - Helpers

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to encode PNG: \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        try data.write(to: url)
        print("wrote \(url.lastPathComponent)")
    } catch {
        FileHandle.standardError.write("Failed to write \(url.path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

func bitmapRep(width: Int, height: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)
    return rep
}

func symbolImage(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        FileHandle.standardError.write("System symbol not found: \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    let configured = base.withSymbolConfiguration(config) ?? base
    // Tint the (template) symbol into a solid color image.
    let size = configured.size
    let tinted = NSImage(size: size)
    tinted.lockFocus()
    configured.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1.0)
    color.set()
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

// MARK: - App icon master (1024x1024)

func makeAppMaster() {
    let dim = 1024
    let rep = bitmapRep(width: dim, height: dim)
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let canvas = NSRect(x: 0, y: 0, width: CGFloat(dim), height: CGFloat(dim))

    // Rounded-rect background with a vertical blue→indigo gradient.
    let inset: CGFloat = CGFloat(dim) * 0.08
    let rect = canvas.insetBy(dx: inset, dy: inset)
    let radius = rect.width * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()

    let blue = NSColor(srgbRed: 0.20, green: 0.45, blue: 0.95, alpha: 1.0)
    let indigo = NSColor(srgbRed: 0.28, green: 0.18, blue: 0.70, alpha: 1.0)
    let gradient = NSGradient(starting: blue, ending: indigo)!
    gradient.draw(in: rect, angle: -90)

    // White SF Symbol "playpause.fill" centered at ~50% of the canvas.
    let glyphTarget = CGFloat(dim) * 0.50
    let glyph = symbolImage("playpause.fill", pointSize: glyphTarget, color: .white)
    var gsize = glyph.size
    let scale = glyphTarget / max(gsize.width, gsize.height)
    gsize = NSSize(width: gsize.width * scale, height: gsize.height * scale)
    let gOrigin = NSPoint(x: (CGFloat(dim) - gsize.width) / 2.0,
                          y: (CGFloat(dim) - gsize.height) / 2.0)
    glyph.draw(in: NSRect(origin: gOrigin, size: gsize),
               from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    writePNG(rep, to: iconDir.appendingPathComponent("master-1024.png"))
}

// MARK: - Menubar master (64x64, black + alpha, transparent background)

func makeMenubarMaster() {
    let dim = 64
    let rep = bitmapRep(width: dim, height: dim)
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // Transparent background (already cleared); draw black glyph with alpha.
    let glyphTarget = CGFloat(dim) * 0.80
    let glyph = symbolImage("playpause.fill", pointSize: glyphTarget, color: .black)
    var gsize = glyph.size
    let scale = glyphTarget / max(gsize.width, gsize.height)
    gsize = NSSize(width: gsize.width * scale, height: gsize.height * scale)
    let gOrigin = NSPoint(x: (CGFloat(dim) - gsize.width) / 2.0,
                          y: (CGFloat(dim) - gsize.height) / 2.0)
    glyph.draw(in: NSRect(origin: gOrigin, size: gsize),
               from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    writePNG(rep, to: iconDir.appendingPathComponent("menubar-master.png"))
}

makeAppMaster()
makeMenubarMaster()
