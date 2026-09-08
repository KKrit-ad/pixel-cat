import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Converts the multi-row kitten reference atlas into PixelCat's fixed
// 45-frame, 128x100 strip. The four ball and two gecko frames are preserved
// from the currently installed sheet.

private let frameWidth = 128
private let frameHeight = 100
private let frameCount = 45

struct Crop {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let yOffset: CGFloat

    init(_ x: Int, _ y: Int, _ width: Int, _ height: Int, yOffset: CGFloat = 2) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.yOffset = yOffset
    }
}

private func loadImage(_ path: String) throws -> CGImage {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "PixelCatSpriteImport", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot read image: \(path)"])
    }
    return image
}

private func bitmapContext(width: Int, height: Int) -> CGContext {
    CGContext(data: nil,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: width * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

private func render(_ crop: Crop, from source: CGImage) -> CGImage {
    // CGImage crop coordinates are top-left based.
    let rect = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
    guard let image = source.cropping(to: rect) else {
        fatalError("Invalid crop: \(rect)")
    }

    let context = bitmapContext(width: frameWidth, height: frameHeight)
    context.clear(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    context.interpolationQuality = .high
    context.setShouldAntialias(true)

    let scale = min(0.64,
                    CGFloat(frameWidth - 8) / CGFloat(crop.width),
                    CGFloat(frameHeight - 4) / CGFloat(crop.height))
    let width = CGFloat(crop.width) * scale
    let height = CGFloat(crop.height) * scale
    let x = (CGFloat(frameWidth) - width) / 2
    context.draw(image, in: CGRect(x: x, y: crop.yOffset, width: width, height: height))
    return context.makeImage()!
}

private func closedEyes(_ image: CGImage) -> CGImage {
    let context = bitmapContext(width: frameWidth, height: frameHeight)
    context.draw(image, in: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    guard let data = context.data else { return image }
    let pixels = data.bindMemory(to: UInt8.self, capacity: frameWidth * frameHeight * 4)

    var candidates = [(x: Int, y: Int)]()
    for y in 0..<frameHeight {
        for x in 0..<frameWidth {
            let i = (y * frameWidth + x) * 4
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if pixels[i + 3] > 160, g > 45, g > r * 6 / 5, g > b * 6 / 5 {
                candidates.append((x, y))
            }
        }
    }

    var remaining = Set(candidates.map { $0.y * frameWidth + $0.x })
    var eyes = [(minX: Int, minY: Int, maxX: Int, maxY: Int)]()
    while let seed = remaining.first {
        remaining.remove(seed)
        var queue = [seed]
        var cursor = 0
        var minX = seed % frameWidth, maxX = minX
        var minY = seed / frameWidth, maxY = minY
        while cursor < queue.count {
            let point = queue[cursor]
            cursor += 1
            let x = point % frameWidth, y = point / frameWidth
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < frameWidth, ny >= 0, ny < frameHeight else { continue }
                    let next = ny * frameWidth + nx
                    if remaining.remove(next) != nil { queue.append(next) }
                }
            }
        }
        if queue.count >= 2 { eyes.append((minX, minY, maxX, maxY)) }
    }

    for eye in eyes.prefix(2) {
        let centerY = (eye.minY + eye.maxY) / 2
        let minX = max(0, eye.minX - 1), maxX = min(frameWidth - 1, eye.maxX + 1)
        let minY = max(0, eye.minY - 1), maxY = min(frameHeight - 1, eye.maxY + 1)
        let patchHeight = maxY - minY + 1
        for y in minY...maxY {
            for x in minX...maxX {
                // Pull real fur texture down from the forehead instead of
                // painting a flat patch over the eye.
                let sourceY = min(frameHeight - 1, y + patchHeight + 1)
                let source = (sourceY * frameWidth + x) * 4
                let i = (y * frameWidth + x) * 4
                pixels[i] = pixels[source]
                pixels[i + 1] = pixels[source + 1]
                pixels[i + 2] = pixels[source + 2]
                pixels[i + 3] = pixels[source + 3]
            }
        }
        let lineY = centerY
        for x in (minX + 1)..<maxX {
            let i = (lineY * frameWidth + x) * 4
            pixels[i] = 34; pixels[i + 1] = 31; pixels[i + 2] = 36; pixels[i + 3] = 255
        }
    }
    return context.makeImage()!
}

private func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "PixelCatSpriteImport", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot create output: \(path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "PixelCatSpriteImport", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot finalize output: \(path)"])
    }
}

let arguments = CommandLine.arguments
let referencePath = arguments.count > 1 ? arguments[1] : "Codex Image Sep 1, 2026, 05_55_21 PM.png"
let outputPath = arguments.count > 2 ? arguments[2] : "cat-sheet-reference.png"
let installedPath = arguments.count > 3 ? arguments[3] : "cat-sheet.png"

let reference = try loadImage(referencePath)
let installed = try loadImage(installedPath)
guard reference.width == 1619, reference.height == 971 else {
    fatalError("Expected the 1619x971 reference atlas, got \(reference.width)x\(reference.height)")
}
guard installed.width % frameCount == 0, installed.height > 0 else {
    fatalError("Expected an installed 45-frame sheet, got \(installed.width)x\(installed.height)")
}
let installedFrameWidth = installed.width / frameCount
let installedFrameHeight = installed.height

let walk = [
    Crop(15, 179, 150, 125), Crop(409, 181, 147, 123),
    Crop(771, 181, 157, 125), Crop(1140, 182, 165, 123)
]
let run = [
    Crop(15, 327, 191, 108), Crop(255, 321, 196, 116),
    Crop(756, 336, 220, 99), Crop(1238, 329, 187, 113)
]
let sit = [
    Crop(29, 11, 122, 149), Crop(174, 13, 142, 147),
    Crop(336, 13, 123, 147), Crop(482, 12, 134, 148)
]

var frames = [CGImage]()
let walkFrames = walk.map { render($0, from: reference) }
frames.append(contentsOf: walkFrames)
frames.append(contentsOf: walkFrames.map(closedEyes))

let runFrames = run.map { render($0, from: reference) }
frames.append(contentsOf: runFrames)
frames.append(contentsOf: runFrames.map(closedEyes))

let sitFrames = sit.map { render($0, from: reference) }
frames.append(contentsOf: sitFrames)
frames.append(contentsOf: sitFrames.map(closedEyes))

// tilt, lick, sleep, stretch, crouch, climb, held
frames.append(render(Crop(482, 12, 134, 148), from: reference))
frames.append(render(Crop(650, 27, 149, 133), from: reference))
frames.append(render(Crop(174, 13, 142, 147), from: reference))
frames.append(render(Crop(336, 13, 123, 147), from: reference))
frames.append(render(Crop(1405, 81, 158, 82), from: reference))
frames.append(render(Crop(1405, 81, 158, 82, yOffset: 4), from: reference))
frames.append(render(Crop(828, 51, 150, 108), from: reference))
frames.append(render(Crop(998, 51, 175, 108), from: reference))
frames.append(render(Crop(998, 51, 175, 108), from: reference))
frames.append(render(Crop(1188, 55, 195, 105), from: reference))
frames.append(render(Crop(310, 634, 76, 178), from: reference))
frames.append(render(Crop(442, 617, 99, 179), from: reference))
frames.append(render(Crop(603, 431, 120, 176), from: reference))
frames.append(render(Crop(603, 431, 120, 176, yOffset: 4), from: reference))

// Keep the app-specific ball and gecko assets; they are not represented as
// isolated, animation-ready frames in the kitten reference atlas.
for index in 38...43 {
    let rect = CGRect(x: index * installedFrameWidth, y: 0,
                      width: installedFrameWidth, height: installedFrameHeight)
    let prop = installed.cropping(to: rect)!
    let context = bitmapContext(width: frameWidth, height: frameHeight)
    context.interpolationQuality = .none
    context.draw(prop, in: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    frames.append(context.makeImage()!)
}

frames.append(render(Crop(603, 431, 120, 176), from: reference))
precondition(frames.count == frameCount)

let sheet = bitmapContext(width: frameWidth * frameCount, height: frameHeight)
sheet.clear(CGRect(x: 0, y: 0, width: frameWidth * frameCount, height: frameHeight))
for (index, frame) in frames.enumerated() {
    sheet.draw(frame, in: CGRect(x: index * frameWidth, y: 0, width: frameWidth, height: frameHeight))
}
try writePNG(sheet.makeImage()!, to: outputPath)

let columns = 9, rows = 5, previewScale = 2
let contact = bitmapContext(width: columns * frameWidth, height: rows * frameHeight)
contact.setFillColor(CGColor(red: 0.957, green: 0.965, blue: 0.949, alpha: 1))
contact.fill(CGRect(x: 0, y: 0, width: columns * frameWidth, height: rows * frameHeight))
for (index, frame) in frames.enumerated() {
    let column = index % columns
    let row = index / columns
    contact.draw(frame, in: CGRect(x: column * frameWidth,
                                   y: (rows - row - 1) * frameHeight,
                                   width: frameWidth,
                                   height: frameHeight))
}
let preview = bitmapContext(width: columns * frameWidth * previewScale,
                            height: rows * frameHeight * previewScale)
preview.interpolationQuality = .none
preview.draw(contact.makeImage()!, in: CGRect(x: 0, y: 0,
                                               width: columns * frameWidth * previewScale,
                                               height: rows * frameHeight * previewScale))
let outputURL = URL(fileURLWithPath: outputPath)
let previewPath = outputURL.deletingPathExtension().path + "-preview.png"
try writePNG(preview.makeImage()!, to: previewPath)

print("wrote \(outputPath) (\(frameWidth * frameCount)x\(frameHeight), \(frames.count) frames)")
print("wrote \(previewPath) (\(columns)x\(rows) contact preview)")
