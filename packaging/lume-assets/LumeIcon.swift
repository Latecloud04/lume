import CoreGraphics
import Foundation
import ImageIO

// Deterministic, code-native source for the Lume app icon. Keep this drawing
// in lockstep with LumeIcon.svg: a pale rounded square and one broken mint
// quota ring, with no text, character art, or gradients.

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: LumeIcon.swift ICONSET_DIR\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let fileManager = FileManager.default
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, filename) in sizes {
    let pixels = size
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: pixels,
              height: pixels,
              bitsPerComponent: 8,
              bytesPerRow: pixels * 4,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        throw NSError(domain: "LumeIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "unable to create bitmap context"])
    }

    let canvas = CGFloat(pixels)
    context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    let inset = canvas * 0.086
    let cornerRadius = canvas * 0.205
    let square = CGRect(x: inset, y: inset, width: canvas - (inset * 2), height: canvas - (inset * 2))
    context.addPath(CGPath(roundedRect: square, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
    context.setFillColor(CGColor(red: 0.956, green: 0.969, blue: 0.961, alpha: 1.0))
    context.fillPath()

    let center = CGPoint(x: canvas * 0.5, y: canvas * 0.5)
    let radius = canvas * 0.293
    let ring = CGMutablePath()
    ring.addArc(center: center, radius: radius, startAngle: -0.96, endAngle: 4.45, clockwise: false)
    context.addPath(ring)
    context.setStrokeColor(CGColor(red: 0.329, green: 0.835, blue: 0.698, alpha: 1.0))
    context.setLineWidth(max(2.0, canvas * 0.070))
    context.setLineCap(.round)
    context.strokePath()

    guard let image = context.makeImage() else {
        throw NSError(domain: "LumeIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "unable to create icon image"])
    }
    let destinationURL = outputDirectory.appendingPathComponent(filename)
    guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "LumeIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "unable to create PNG destination"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "LumeIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "unable to write PNG"])
    }
}
