#!/usr/bin/env swift
// Generates the app icon in the same periodic-table style as M3 Tracker: atomic number
// "27", tipped 45° to the left, the "Dl" symbol, and the name along the bottom, on
// a white tile.
// Run with:
//   swift Tools/generate_icon.swift
//
// Produces two variants, because the name is an unreadable smudge at the 16
// and 32 point sizes macOS uses in Finder lists and dialogs:
//   Resources/AppIcon.png       — full tile, used from 128pt up
//   Resources/AppIcon-small.png — no name, larger symbol, used at 16-64pt

import AppKit

let textColor = NSColor.black

func renderIcon(includeName: Bool) -> NSImage {
let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))

image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no graphics context")
}

// A small margin keeps the tile from looking oversized beside other Dock icons.
let margin = canvas * 0.045
let tile = CGRect(x: margin, y: margin, width: canvas - margin * 2, height: canvas - margin * 2)
let side = tile.width
let cornerRadius = side * 0.215

let tilePath = CGPath(roundedRect: tile, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// MARK: - White body

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bodyColors = [
    NSColor(white: 1.0, alpha: 1.0).cgColor,
    NSColor(white: 0.90, alpha: 1.0).cgColor,
] as CFArray
let bodyGradient = CGGradient(colorsSpace: colorSpace, colors: bodyColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(
    bodyGradient,
    start: CGPoint(x: tile.minX, y: tile.maxY),
    end: CGPoint(x: tile.maxX, y: tile.minY),
    options: []
)

// Glossy sheen sweeping across the upper-left, as in the reference art.
let gloss = CGMutablePath()
gloss.move(to: CGPoint(x: tile.minX, y: tile.minY + side * 0.52))
gloss.addCurve(
    to: CGPoint(x: tile.minX + side * 0.68, y: tile.maxY),
    control1: CGPoint(x: tile.minX + side * 0.30, y: tile.minY + side * 0.78),
    control2: CGPoint(x: tile.minX + side * 0.34, y: tile.maxY)
)
gloss.addLine(to: CGPoint(x: tile.minX, y: tile.maxY))
gloss.closeSubpath()
ctx.addPath(gloss)
ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
ctx.fillPath()

ctx.restoreGState()

// A hairline edge, so the white tile doesn't vanish against light backgrounds.
ctx.addPath(tilePath)
ctx.setStrokeColor(NSColor(white: 0.0, alpha: 0.12).cgColor)
ctx.setLineWidth(canvas * 0.004)
ctx.strokePath()

// MARK: - Text

func draw(_ string: String, size: CGFloat, at point: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .bold),
        .foregroundColor: textColor,
    ]
    NSAttributedString(string: string, attributes: attributes).draw(at: point)
}

func size(of string: String, size: CGFloat) -> NSSize {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .bold)
    ]
    return NSAttributedString(string: string, attributes: attributes).size()
}

// Atomic number, top-left, tipped 45° to the left (counterclockwise) about
// its own centre. Nudged up in the small variant so it still reads once the
// name is gone.
let number = "27"
let numberSize = side * (includeName ? 0.115 : 0.135)
let numberInset = side * 0.075
let numberBox = size(of: number, size: numberSize)
let numberCentre = CGPoint(
    x: tile.minX + numberInset + numberBox.width / 2,
    y: tile.maxY - numberInset - numberBox.height / 2
)
ctx.saveGState()
ctx.translateBy(x: numberCentre.x, y: numberCentre.y)
ctx.rotate(by: .pi / 4)
draw(number, size: numberSize, at: CGPoint(x: -numberBox.width / 2, y: -numberBox.height / 2))
ctx.restoreGState()

// The element symbol, centred. Without the name below it, it grows and recentres to
// fill the tile.
let symbol = "Dl"
// A two-letter symbol is wider than M3's "M³", so the nameless variant can't grow as far without
// running into the 27; it sits a little below centre to clear it.
let symbolSize = side * (includeName ? 0.50 : 0.54)
let symbolBox = size(of: symbol, size: symbolSize)
draw(symbol, size: symbolSize, at: CGPoint(
    x: tile.midX - symbolBox.width / 2,
    y: includeName ? tile.minY + side * 0.27 : tile.midY - symbolBox.height / 2 - side * 0.04
))

// Name along the bottom.
if includeName {
    let nameSize = side * 0.077
    let name = "DiskLens"
    let nameWidth = size(of: name, size: nameSize).width
    draw(name, size: nameSize, at: CGPoint(
        x: tile.midX - nameWidth / 2,
        y: tile.minY + side * 0.105
    ))
}

image.unlockFocus()
return image
}

// MARK: - Write PNGs

func write(_ image: NSImage, to path: String) throws {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("failed to render PNG")
    }
    try png.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}

try write(renderIcon(includeName: true), to: "Resources/AppIcon.png")
try write(renderIcon(includeName: false), to: "Resources/AppIcon-small.png")
