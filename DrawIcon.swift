import AppKit

let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let rounded = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
rounded.addClip()
NSGradient(starting: NSColor(calibratedRed: 0.35, green: 0.28, blue: 0.9, alpha: 1), ending: NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.31, alpha: 1))!.draw(in: rounded, angle: -60)
for row in 0..<3 {
    for column in 0..<3 {
        let rect = NSRect(x: 223 + column * 206, y: 223 + row * 206, width: 166, height: 166)
        NSColor(calibratedWhite: 1, alpha: row == 2 && column == 0 ? 0.5 : 0.93).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 39, yRadius: 39).fill()
    }
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
