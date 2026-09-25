// Draws the app icon at 1024 x 1024 and writes Resources/AppIcon.png.
// Run from the repo root: swift scripts/make-icon.swift, then scripts/build-app.sh makes the .icns from it.
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// macOS icon grid: an 824 point rounded square centred on the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(0x1e40af), rgb(0x172554)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Signal bars, rising left to right, above the stick.
let barColor = rgb(0x34c759)
for i in 0..<4 {
    let h = CGFloat(70 + i * 55)
    let r = CGRect(x: 262 + CGFloat(i) * 78, y: 560, width: 52, height: h)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.setFillColor(barColor)
    ctx.fillPath()
}

// The USB stick: a white body and a grey connector with two holes.
ctx.addPath(CGPath(roundedRect: CGRect(x: 220, y: 330, width: 450, height: 170), cornerWidth: 40, cornerHeight: 40, transform: nil))
ctx.setFillColor(rgb(0xf5f5f7))
ctx.fillPath()
ctx.setFillColor(rgb(0xc7c7cc))
ctx.fill(CGRect(x: 670, y: 360, width: 130, height: 110))
ctx.setFillColor(rgb(0x8e8e93))
ctx.fill(CGRect(x: 715, y: 425, width: 34, height: 22))
ctx.fill(CGRect(x: 715, y: 383, width: 34, height: 22))
// A small light on the body, like the stick's own.
ctx.setFillColor(rgb(0x34c759))
ctx.fillEllipse(in: CGRect(x: 262, y: 400, width: 30, height: 30))

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
print("wrote Resources/AppIcon.png")
