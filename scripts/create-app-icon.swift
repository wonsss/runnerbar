#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("RunnerBar.iconset")
let output = resources.appendingPathComponent("RunnerBar.icns")

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(size: Int, to url: URL) throws {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: dimension, height: dimension)
    NSColor.clear.setFill()
    rect.fill()

    let inset = dimension * 0.08
    let appRect = rect.insetBy(dx: inset, dy: inset)
    let radius = dimension * 0.18
    let background = NSBezierPath(roundedRect: appRect, xRadius: radius, yRadius: radius)
    NSGradient(
        colors: [
            NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.10, alpha: 1),
            NSColor(calibratedRed: 0.11, green: 0.15, blue: 0.18, alpha: 1)
        ]
    )?.draw(in: background, angle: 315)

    NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
    background.lineWidth = max(1, dimension * 0.012)
    background.stroke()

    let barHeight = dimension * 0.09
    let barY = appRect.maxY - dimension * 0.18
    let barRect = NSRect(x: appRect.minX + dimension * 0.12, y: barY, width: appRect.width - dimension * 0.24, height: barHeight)
    let bar = NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
    NSColor(calibratedRed: 0.17, green: 0.85, blue: 0.38, alpha: 1).setFill()
    bar.fill()

    let nodeY = appRect.midY - dimension * 0.08
    let nodeRadius = dimension * 0.07
    let nodeXs = [appRect.minX + dimension * 0.25, appRect.midX, appRect.maxX - dimension * 0.25]
    NSColor(calibratedWhite: 1, alpha: 0.26).setStroke()
    let connector = NSBezierPath()
    connector.move(to: NSPoint(x: nodeXs[0], y: nodeY))
    connector.line(to: NSPoint(x: nodeXs[2], y: nodeY))
    connector.lineWidth = max(2, dimension * 0.018)
    connector.stroke()

    for (index, x) in nodeXs.enumerated() {
        let nodeRect = NSRect(x: x - nodeRadius, y: nodeY - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2)
        let node = NSBezierPath(ovalIn: nodeRect)
        if index == 1 {
            NSColor(calibratedRed: 0.17, green: 0.85, blue: 0.38, alpha: 1).setFill()
        } else {
            NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
        }
        node.fill()
    }

    let text = "RB" as NSString
    let font = NSFont.systemFont(ofSize: dimension * 0.22, weight: .heavy)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1)
    ]
    let textSize = text.size(withAttributes: attributes)
    let textRect = NSRect(
        x: appRect.midX - textSize.width / 2,
        y: appRect.minY + dimension * 0.15,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: textRect, withAttributes: attributes)

    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "RunnerBarIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render icon"])
    }
    try png.write(to: url)
}

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in entries {
    try drawIcon(size: size, to: iconset.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    throw NSError(domain: "RunnerBarIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

print(output.path)
