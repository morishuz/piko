#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    fputs("Icon validation failed: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: validate-app-icon.swift MASTER.png DECODED.iconset")
}

func validate(_ url: URL, size: Int) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("Cannot read \(url.path)")
    }
    guard image.width == size, image.height == size else {
        fail("\(url.lastPathComponent): expected \(size)×\(size)")
    }
    var rgba = [UInt8](repeating: 0, count: size * size * 4)
    rgba.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fail("Cannot decode RGBA") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    }
    func alpha(_ x: Int, _ y: Int) -> UInt8 { rgba[(y * size + x) * 4 + 3] }

    // Validate the entire canvas border, not merely the presence of an alpha channel.
    for i in 0..<size {
        guard alpha(i, 0) == 0, alpha(i, size - 1) == 0,
              alpha(0, i) == 0, alpha(size - 1, i) == 0 else {
            fail("\(url.lastPathComponent): opaque outer border")
        }
    }
    // Sample near the tile's bounding-box corners, away from the antialiasing
    // footprint at the very smallest resolutions.
    let corner = Int(Double(size) * 0.10)
    for (x, y) in [(corner, corner), (size - 1 - corner, corner),
                   (corner, size - 1 - corner), (size - 1 - corner, size - 1 - corner)] {
        guard alpha(x, y) == 0 else {
            fail("\(url.lastPathComponent): rounded tile corner is not transparent")
        }
    }
    guard alpha(size / 2, size / 2) == 255,
          alpha(size / 2, Int(Double(size) * 0.2)) == 255 else {
        fail("\(url.lastPathComponent): artwork is missing or translucent")
    }
    let hasAntialiasing = stride(from: 3, to: rgba.count, by: 4).contains {
        rgba[$0] > 0 && rgba[$0] < 255
    }
    guard hasAntialiasing else { fail("\(url.lastPathComponent): no smooth alpha edge") }
    print("Verified \(url.lastPathComponent): \(size)px, transparent margins and rounded corners")
}

validate(URL(fileURLWithPath: CommandLine.arguments[1]), size: 1024)
let iconset = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
var expected: [String: Int] = [:]
for size in [16, 32, 128, 256, 512] {
    expected["icon_\(size)x\(size).png"] = size
    expected["icon_\(size)x\(size)@2x.png"] = size * 2
}
let actual = try FileManager.default.contentsOfDirectory(atPath: iconset.path)
    .filter { $0.hasSuffix(".png") }
guard Set(actual) == Set(expected.keys) else { fail("ICNS representations are missing or unexpected") }
for name in expected.keys.sorted() {
    validate(iconset.appendingPathComponent(name), size: expected[name]!)
}
