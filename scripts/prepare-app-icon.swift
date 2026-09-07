#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fputs("usage: prepare-app-icon.swift INPUT.png OUTPUT.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard
    let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fputs("Could not read \(inputURL.path)\n", stderr)
    exit(1)
}

let width = image.width
let height = image.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
    | CGImageAlphaInfo.premultipliedLast.rawValue

let drewImage = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else { return false }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}

guard drewImage else {
    fputs("Could not create an RGBA drawing context\n", stderr)
    exit(1)
}

func isExteriorBackground(_ pixelIndex: Int) -> Bool {
    let offset = pixelIndex * bytesPerPixel
    let red = Int(pixels[offset])
    let green = Int(pixels[offset + 1])
    let blue = Int(pixels[offset + 2])
    let brightest = max(red, green, blue)
    let darkest = min(red, green, blue)
    return darkest >= 96 && brightest - darkest <= 40
}

var exterior = [Bool](repeating: false, count: width * height)
var queue: [Int] = []
queue.reserveCapacity(width * height / 8)

func enqueueIfBackground(x: Int, y: Int) {
    let index = y * width + x
    guard !exterior[index], isExteriorBackground(index) else { return }
    exterior[index] = true
    queue.append(index)
}

for x in 0..<width {
    enqueueIfBackground(x: x, y: 0)
    enqueueIfBackground(x: x, y: height - 1)
}
for y in 0..<height {
    enqueueIfBackground(x: 0, y: y)
    enqueueIfBackground(x: width - 1, y: y)
}

var cursor = 0
while cursor < queue.count {
    let index = queue[cursor]
    cursor += 1
    let x = index % width
    let y = index / width

    if x > 0 { enqueueIfBackground(x: x - 1, y: y) }
    if x + 1 < width { enqueueIfBackground(x: x + 1, y: y) }
    if y > 0 { enqueueIfBackground(x: x, y: y - 1) }
    if y + 1 < height { enqueueIfBackground(x: x, y: y + 1) }
}

let backgroundSamples = [
    (x: width / 2, y: 1),
    (x: width / 2, y: height - 2),
    (x: 1, y: height / 2),
    (x: width - 2, y: height / 2),
]
let backgroundColor = backgroundSamples.reduce(into: (red: 0, green: 0, blue: 0)) { result, point in
    let offset = (point.y * width + point.x) * bytesPerPixel
    result.red += Int(pixels[offset])
    result.green += Int(pixels[offset + 1])
    result.blue += Int(pixels[offset + 2])
}
let sampleCount = backgroundSamples.count
let fillRed = UInt8(backgroundColor.red / sampleCount)
let fillGreen = UInt8(backgroundColor.green / sampleCount)
let fillBlue = UInt8(backgroundColor.blue / sampleCount)

for index in queue {
    let offset = index * bytesPerPixel
    pixels[offset] = fillRed
    pixels[offset + 1] = fillGreen
    pixels[offset + 2] = fillBlue
    pixels[offset + 3] = 255
}

let data = Data(pixels) as CFData
guard
    let provider = CGDataProvider(data: data),
    let cleanedImage = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )
else {
    fputs("Could not prepare the icon artwork\n", stderr)
    exit(1)
}

// A legacy ICNS must contain its own silhouette: older Finder/Dock versions
// do not apply the newer system mask. Keep the artwork on an inset rounded
// tile, with real transparency outside it, at every downstream resolution.
let canvasSize = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
guard let canvas = CGContext(
    data: nil,
    width: canvasSize,
    height: canvasSize,
    bitsPerComponent: 8,
    bytesPerRow: canvasSize * 4,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    fputs("Could not create the icon canvas\n", stderr)
    exit(1)
}
canvas.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
canvas.setShouldAntialias(true)
canvas.interpolationQuality = .high
canvas.addPath(CGPath(roundedRect: tile, cornerWidth: 206, cornerHeight: 206, transform: nil))
canvas.clip()
canvas.draw(cleanedImage, in: tile)

guard
    let finalImage = canvas.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )
else {
    fputs("Could not prepare the icon PNG\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, finalImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("Could not write \(outputURL.path)\n", stderr)
    exit(1)
}
