// Generates assets/dmg-background.png — DMG window background.
// Run: swift scripts/make-dmg-background.swift
import AppKit

let width: CGFloat = 800
let height: CGFloat = 500

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

// Background — vertical gradient (mint → blue), softened
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.243, green: 0.871, blue: 0.522, alpha: 1.0),  // mint #3DDC84
    NSColor(srgbRed: 0.118, green: 0.533, blue: 0.898, alpha: 1.0)   // blue #1E88E5
])!
gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 270)

// Soften with translucent white veil so text & icons are readable
NSColor(white: 1, alpha: 0.78).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// AppKit Y origin = bottom. Window window'da Y de aşağıdan yukarıya. Icon row Y'sini hesaplayalım.
// Icon positions in DMG window are top-down (set by AppleScript). The arrow between them
// in the BACKGROUND IMAGE must match where Finder will render the icons. Finder renders
// the icons at (200, 220) and (600, 220) where Y is from the TOP of the window (in 800x500),
// which corresponds to backgroundImageY = height - 220 = 280 in AppKit bottom-up coords.

// Title — top of window
let title = "Drag OpenMacBattery → Applications"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
    .foregroundColor: NSColor(white: 0.15, alpha: 1)
]
let titleSize = (title as NSString).size(withAttributes: titleAttrs)
(title as NSString).draw(
    at: NSPoint(x: (width - titleSize.width) / 2, y: height - 60),
    withAttributes: titleAttrs
)

// Subtitle
let sub = "to install. macOS may warn on first launch — right-click → Open."
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
    .foregroundColor: NSColor(white: 0.35, alpha: 1)
]
let subSize = (sub as NSString).size(withAttributes: subAttrs)
(sub as NSString).draw(
    at: NSPoint(x: (width - subSize.width) / 2, y: height - 90),
    withAttributes: subAttrs
)

// Arrow — between icon positions; Finder positions are top-down (200,220) and (600,220).
// In AppKit coords (bottom-up): Y = height - 220 ≈ 280. Icons are 100px tall, so center line ~280.
// Arrow horizontal centerline a bit higher, ~270 (just above the icon labels), drawing through middle of icons.
let arrowY: CGFloat = 280
let arrowFromX: CGFloat = 280     // right edge of left icon area
let arrowToX: CGFloat = 520       // left edge of right icon area

NSColor(white: 0.25, alpha: 0.45).setStroke()
let line = NSBezierPath()
line.lineWidth = 4
line.lineCapStyle = .round
line.lineJoinStyle = .round
line.move(to: NSPoint(x: arrowFromX, y: arrowY))
line.line(to: NSPoint(x: arrowToX, y: arrowY))
line.stroke()

let head = NSBezierPath()
head.lineWidth = 4
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.move(to: NSPoint(x: arrowToX, y: arrowY))
head.line(to: NSPoint(x: arrowToX - 16, y: arrowY + 12))
head.move(to: NSPoint(x: arrowToX, y: arrowY))
head.line(to: NSPoint(x: arrowToX - 16, y: arrowY - 12))
head.stroke()

// "drag" hint above arrow
let drag = "drag"
let dragAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(white: 0.30, alpha: 1)
]
let dragSize = (drag as NSString).size(withAttributes: dragAttrs)
(drag as NSString).draw(
    at: NSPoint(x: (arrowFromX + arrowToX) / 2 - dragSize.width / 2, y: arrowY + 8),
    withAttributes: dragAttrs
)

// Footer — bottom
let footer = "OpenMacBattery — open source per-app battery monitor"
let footAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
    .foregroundColor: NSColor(white: 0.45, alpha: 1)
]
let footSize = (footer as NSString).size(withAttributes: footAttrs)
(footer as NSString).draw(
    at: NSPoint(x: (width - footSize.width) / 2, y: 30),
    withAttributes: footAttrs
)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep  = NSBitmapImageRep(data: tiff),
      let png  = rep.representation(using: .png, properties: [:]) else {
    fputs("Could not encode PNG\n", stderr); exit(1)
}
let outURL = URL(fileURLWithPath: "assets/dmg-background.png")
try png.write(to: outURL)
print("Wrote: \(outURL.path)")
