import AppKit
import CoreGraphics

let size: CGFloat = 1024
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
func makeContext() -> CGContext {
    let c = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: size); c.scaleBy(x: 1, y: -1)   // y points down
    return c
}
func col(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: p3, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}
func background(_ c: CGContext, _ top: UInt32, _ bottom: UInt32) {
    let g = CGGradient(colorsSpace: p3, colors: [col(top), col(bottom)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: size * 0.2, y: 0), end: CGPoint(x: size * 0.8, y: size), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let hl = CGGradient(colorsSpace: p3, colors: [col(0xFFFFFF, 0.28), col(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(hl, startCenter: CGPoint(x: 300, y: 120), startRadius: 0, endCenter: CGPoint(x: 300, y: 120), endRadius: 760, options: [])
}
func ellipse(_ c: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: CGColor, rotate: CGFloat = 0) {
    c.saveGState(); c.translateBy(x: cx, y: cy); c.rotate(by: rotate * .pi / 180)
    c.setFillColor(color); c.fillEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)); c.restoreGState()
}
func eye(_ c: CGContext, _ cx: CGFloat, _ cy: CGFloat, r: CGFloat) {
    ellipse(c, cx, cy, r, r * 1.08, col(0x2B2340))
    ellipse(c, cx - r * 0.3, cy - r * 0.38, r * 0.34, r * 0.34, col(0xFFFFFF))
    ellipse(c, cx + r * 0.32, cy + r * 0.3, r * 0.16, r * 0.16, col(0xFFFFFF, 0.9))
}
func blush(_ c: CGContext, _ cx: CGFloat, _ cy: CGFloat) { ellipse(c, cx, cy, 46, 30, col(0xFF8FAB, 0.6)) }
func withShadow(_ c: CGContext, _ body: () -> Void) {
    c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: col(0x0B2A6B, 0.22))
    c.beginTransparencyLayer(auxiliaryInfo: nil); body(); c.endTransparencyLayer(); c.restoreGState()
}
func arc(_ c: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, from: CGFloat, to: CGFloat, width: CGFloat, color: CGColor) {
    c.setStrokeColor(color); c.setLineWidth(width); c.setLineCap(.round)
    c.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: from * .pi / 180, endAngle: to * .pi / 180, clockwise: false); c.strokePath()
}
/// Nose + "w" mouth + optional little tongue
func muzzle(_ c: CGContext, cx: CGFloat, cy: CGFloat, tongue: Bool) {
    if tongue {
        c.setFillColor(col(0xFF7E9D))
        c.addPath(CGPath(roundedRect: CGRect(x: cx - 30, y: cy + 50, width: 60, height: 78), cornerWidth: 30, cornerHeight: 30, transform: nil)); c.fillPath()
        c.setStrokeColor(col(0xE8607F)); c.setLineWidth(8); c.setLineCap(.round)
        c.move(to: CGPoint(x: cx, y: cy + 74)); c.addLine(to: CGPoint(x: cx, y: cy + 104)); c.strokePath()
    }
    c.setStrokeColor(col(0x2B2340)); c.setLineWidth(17); c.setLineCap(.round)
    c.addArc(center: CGPoint(x: cx - 32, y: cy + 32), radius: 32, startAngle: 0.02 * .pi, endAngle: 0.92 * .pi, clockwise: false); c.strokePath()
    c.addArc(center: CGPoint(x: cx + 32, y: cy + 32), radius: 32, startAngle: 0.08 * .pi, endAngle: 0.98 * .pi, clockwise: false); c.strokePath()
    // Nose: inverted rounded triangle
    let nose = CGMutablePath()
    nose.move(to: CGPoint(x: cx - 46, y: cy - 18))
    nose.addQuadCurve(to: CGPoint(x: cx + 46, y: cy - 18), control: CGPoint(x: cx, y: cy - 40))
    nose.addQuadCurve(to: CGPoint(x: cx, y: cy + 34), control: CGPoint(x: cx + 46, y: cy + 22))
    nose.addQuadCurve(to: CGPoint(x: cx - 46, y: cy - 18), control: CGPoint(x: cx - 46, y: cy + 22))
    c.setFillColor(col(0x2B2340)); c.addPath(nose); c.fillPath()
    ellipse(c, cx - 14, cy - 12, 14, 8, col(0xFFFFFF, 0.75))
}
func save(_ c: CGContext, _ name: String) {
    try! NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: name))
}

/// Floppy-eared puppy. tilt: head tilt angle; tongue: whether the tongue sticks out
func floppyDog(_ c: CGContext, tilt: CGFloat, tongue: Bool) {
    c.saveGState()
    c.translateBy(x: 512, y: 600); c.rotate(by: tilt * .pi / 180); c.translateBy(x: -512, y: -600)
    let brown: UInt32 = 0xB97A4E, brownLight: UInt32 = 0xE3A877
    withShadow(c) {
        // The perked-up right ear (behind the head)
        ellipse(c, 735, 345, 92, 170, col(brown), rotate: 28)
        ellipse(c, 735, 352, 50, 118, col(brownLight), rotate: 28)
        // Head
        ellipse(c, 512, 600, 275, 245, col(0xFFFDF8))
        // The drooping left ear (in front of the head)
        ellipse(c, 262, 560, 92, 190, col(brown), rotate: 14)
    }
    // Patch around the right eye
    ellipse(c, 612, 560, 96, 104, col(0xE3A877, 0.9), rotate: -10)
    eye(c, 420, 570, r: 42); eye(c, 610, 570, r: 42)
    blush(c, 352, 672); blush(c, 676, 672)
    muzzle(c, cx: 514, cy: 664, tongue: tongue)
    c.restoreGState()
}

// A: floppy-eared puppy
do {
    let c = makeContext(); background(c, 0x9CE5FF, 0x4C86FF)
    c.saveGState(); c.translateBy(x: 26, y: 6)
    floppyDog(c, tilt: 0, tongue: false)
    c.restoreGState()
    arc(c, cx: 822, cy: 250, r: 86, from: -74, to: -14, width: 30, color: col(0xFFFFFF, 0.95))
    arc(c, cx: 822, cy: 250, r: 148, from: -66, to: -12, width: 30, color: col(0xFFFFFF, 0.6))
    save(c, "A.png")
}
// B: Shiba Inu
do {
    let c = makeContext(); background(c, 0xA6E9FF, 0x4F8BFF)
    let orange: UInt32 = 0xF4A24C
    func earTri(_ pts: [CGPoint], _ color: CGColor, radius: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2))
        p.addArc(tangent1End: pts[1], tangent2End: pts[2], radius: radius)
        p.addArc(tangent1End: pts[2], tangent2End: pts[0], radius: radius)
        p.addArc(tangent1End: pts[0], tangent2End: pts[1], radius: radius)
        p.closeSubpath(); c.setFillColor(color); c.addPath(p); c.fillPath()
    }
    withShadow(c) {
        earTri([CGPoint(x: 250, y: 520), CGPoint(x: 300, y: 215), CGPoint(x: 500, y: 400)], col(orange), radius: 46)
        earTri([CGPoint(x: 774, y: 520), CGPoint(x: 724, y: 215), CGPoint(x: 524, y: 400)], col(orange), radius: 46)
        ellipse(c, 512, 610, 290, 250, col(orange))
    }
    earTri([CGPoint(x: 312, y: 470), CGPoint(x: 330, y: 300), CGPoint(x: 440, y: 410)], col(0xFFD9C2), radius: 26)
    earTri([CGPoint(x: 712, y: 470), CGPoint(x: 694, y: 300), CGPoint(x: 584, y: 410)], col(0xFFD9C2), radius: 26)
    // White mask: both cheeks + muzzle
    c.saveGState()
    c.addEllipse(in: CGRect(x: 222, y: 360, width: 580, height: 500)); c.clip()
    ellipse(c, 380, 720, 170, 150, col(0xFFFDF8)); ellipse(c, 644, 720, 170, 150, col(0xFFFDF8)); ellipse(c, 512, 700, 130, 130, col(0xFFFDF8))
    ellipse(c, 512, 790, 210, 110, col(0xFFFDF8))   // Fill in the chin
    c.restoreGState()
    // Dot eyebrows
    ellipse(c, 418, 488, 30, 20, col(0xFFFDF8), rotate: -14); ellipse(c, 606, 488, 30, 20, col(0xFFFDF8), rotate: 14)
    eye(c, 418, 570, r: 40); eye(c, 606, 570, r: 40)
    blush(c, 336, 676); blush(c, 688, 676)
    muzzle(c, cx: 512, cy: 664, tongue: false)
    arc(c, cx: 770, cy: 300, r: 80, from: -66, to: 8, width: 30, color: col(0xFFFFFF, 0.95))
    arc(c, cx: 770, cy: 300, r: 145, from: -58, to: 2, width: 30, color: col(0xFFFFFF, 0.6))
    save(c, "B.png")
}
// C: puppy with a tilted head (the one used as the app icon)
do {
    let c = makeContext(); background(c, 0xA5EED9, 0x4A8CFF)
    floppyDog(c, tilt: -13, tongue: true)
    arc(c, cx: 760, cy: 235, r: 80, from: -72, to: 2, width: 30, color: col(0xFFFFFF, 0.95))
    arc(c, cx: 760, cy: 235, r: 145, from: -64, to: -4, width: 30, color: col(0xFFFFFF, 0.6))
    save(c, "C.png")
}
// Preview sheet
do {
    let names = ["A", "B", "C"], titles = ["A Floppy ears", "B Shiba Inu", "C Head tilt"]
    let big: CGFloat = 420, small: CGFloat = 120, pad: CGFloat = 60
    let W = pad + CGFloat(names.count) * (big + pad), H = pad + big + 50 + small + 110
    let img = NSImage(size: NSSize(width: W, height: H)); img.lockFocus()
    NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    for (i, n) in names.enumerated() {
        let src = NSImage(contentsOfFile: "\(n).png")!
        let x = pad + CGFloat(i) * (big + pad)
        for (s, y) in [(big, H - pad - big), (small, H - pad - big - 50 - small)] {
            let r = NSRect(x: x + (big - s) / 2, y: y, width: s, height: s)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: s * 0.225, yRadius: s * 0.225).addClip()
            src.draw(in: r); NSGraphicsContext.restoreGraphicsState()
        }
        let p = NSMutableParagraphStyle(); p.alignment = .center
        (titles[i] as NSString).draw(in: NSRect(x: x, y: 24, width: big, height: 44), withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor(white: 0.2, alpha: 1), .paragraphStyle: p])
    }
    img.unlockFocus()
    try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
