#!/usr/bin/swift
//
// render_icon.swift
// Renders a SVG file to PNGs at every size needed for an .iconset
// using AppKit + Quartz. AppKit's NSImage(contentsOfFile:) accepts
// SVGs since macOS 13 and rasterises them through CoreSVG, so we
// don't need an external renderer like rsvg-convert.
//
// Usage:
//   swift Scripts/render_icon.swift Resources/icon.svg Resources/AppIcon.iconset
//

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data(
        "usage: render_icon.swift <input.svg> <out.iconset>\n".utf8))
    exit(2)
}

let svgPath = CommandLine.arguments[1]
let outDir  = CommandLine.arguments[2]

let svgURL = URL(fileURLWithPath: svgPath)
guard FileManager.default.fileExists(atPath: svgURL.path) else {
    FileHandle.standardError.write(Data("input not found: \(svgPath)\n".utf8))
    exit(1)
}

try? FileManager.default.createDirectory(
    at: URL(fileURLWithPath: outDir),
    withIntermediateDirectories: true)

guard let img = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write(Data("failed to load SVG\n".utf8))
    exit(1)
}

// macOS .iconset expects: 16, 32, 128, 256, 512 each at 1x and 2x,
// plus a single 1024 (used as 512@2x).
let sizes: [(label: String, px: Int)] = [
    ("16x16",    16),
    ("16x16@2x", 32),
    ("32x32",    32),
    ("32x32@2x", 64),
    ("128x128",      128),
    ("128x128@2x",   256),
    ("256x256",      256),
    ("256x256@2x",   512),
    ("512x512",      512),
    ("512x512@2x",  1024),
]

func render(_ source: NSImage, to size: Int) -> NSImage {
    let dst = NSImage(size: NSSize(width: size, height: size))
    dst.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0)
    dst.unlockFocus()
    return dst
}

for (label, px) in sizes {
    let scaled = render(img, to: px)
    guard let tiff = scaled.tiffRepresentation,
          let rep  = NSBitmapImageRep(data: tiff),
          let png  = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(label)\n".utf8))
        continue
    }
    let out = URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(label).png")
    try? png.write(to: out)
    print("rendered \(out.lastPathComponent) (\(px)px, \(png.count) bytes)")
}
