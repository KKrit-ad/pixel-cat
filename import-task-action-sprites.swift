import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func load(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("cannot load \(path)")
    }
    return image
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(
        url, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("cannot create \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(path)") }
}

func rgba(_ image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &pixels, width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return pixels
}

func image(width: Int, height: Int, pixels: inout [UInt8]) -> CGImage {
    let context = CGContext(data: &pixels, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

let args = CommandLine.arguments
guard args.count == 5 || args.count == 6 else {
    fatalError("usage: swift import-task-action-sprites.swift generated.png old-sheet.png strip.png combined.png [task-actions|context-rescue]")
}
let mode = args.count == 6 ? args[5] : "task-actions"
let generatedFrameCount = mode == "context-rescue" ? 4 : 8
let oldFrameCount = mode == "context-rescue" ? 55 : 47
let generated = load(args[1])
let oldSheet = load(args[2])
precondition(oldSheet.width == oldFrameCount * 128 && oldSheet.height == 100,
             "expected current \(oldFrameCount)-frame atlas")

let width = generated.width, height = generated.height
var pixels = rgba(generated)
func index(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }
func isMatte(_ x: Int, _ y: Int) -> Bool {
    let i = index(x, y)
    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
    return min(r, g, b) >= 214 && max(r, g, b) - min(r, g, b) <= 30
}

// Only erase pale neutral pixels connected to the image border. White fur and
// envelopes remain protected by their closed dark pixel-art outlines.
var outside = [Bool](repeating: false, count: width * height)
var queue: [(Int, Int)] = []
for x in 0..<width { queue.append((x, 0)); queue.append((x, height - 1)) }
for y in 0..<height { queue.append((0, y)); queue.append((width - 1, y)) }
var cursor = 0
while cursor < queue.count {
    let (x, y) = queue[cursor]; cursor += 1
    let p = y * width + x
    if outside[p] || !isMatte(x, y) { continue }
    outside[p] = true
    if x > 0 { queue.append((x - 1, y)) }
    if x + 1 < width { queue.append((x + 1, y)) }
    if y > 0 { queue.append((x, y - 1)) }
    if y + 1 < height { queue.append((x, y + 1)) }
}
for y in 0..<height {
    for x in 0..<width where outside[y * width + x] {
        let i = index(x, y)
        pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
    }
}

// Peel any bright neutral matte fringe that was antialiased into the subject.
// A real pixel-art outline is dark, so this stops at the outline instead of
// eating the pale muzzle, paws, or envelope enclosed behind it.
for _ in 0..<12 {
    var fringe: [(Int, Int)] = []
    for y in 1..<(height - 1) {
        for x in 1..<(width - 1) {
            let i = index(x, y)
            guard pixels[i + 3] > 0 else { continue }
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            guard min(r, g, b) >= 180, max(r, g, b) - min(r, g, b) <= 35 else { continue }
            let transparentNeighbor = [index(x - 1, y), index(x + 1, y),
                                       index(x, y - 1), index(x, y + 1)]
                .contains { pixels[$0 + 3] == 0 }
            if transparentNeighbor { fringe.append((x, y)) }
        }
    }
    if fringe.isEmpty { break }
    for (x, y) in fringe {
        let i = index(x, y)
        pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
    }
}
let cleaned = image(width: width, height: height, pixels: &pixels)

let stripContext = CGContext(data: nil, width: generatedFrameCount * 128, height: 100,
                             bitsPerComponent: 8, bytesPerRow: generatedFrameCount * 128 * 4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
stripContext.interpolationQuality = .none
stripContext.setShouldAntialias(false)

struct Bounds { let x: Int; let y: Int; let width: Int; let height: Int }
var bounds: [Bounds] = []
for frame in 0..<generatedFrameCount {
    let x0 = frame * width / generatedFrameCount
    let x1 = (frame + 1) * width / generatedFrameCount
    var minX = x1, minY = height, maxX = x0, maxY = 0
    for y in 0..<height {
        for x in x0..<x1 where pixels[index(x, y) + 3] > 8 {
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    precondition(maxX >= minX && maxY >= minY, "empty generated frame \(frame)")
    bounds.append(Bounds(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
}

for frame in 0..<generatedFrameCount {
    let b = bounds[frame]
    guard let crop = cleaned.cropping(to: CGRect(x: b.x, y: b.y, width: b.width, height: b.height)) else {
        fatalError("cannot crop frame \(frame)")
    }
    let groupPointing = mode == "task-actions" && frame < 4
    let maxW: CGFloat = mode == "context-rescue" ? 118 : (groupPointing ? 110 : 118)
    let maxH: CGFloat = mode == "context-rescue" ? 88 : (groupPointing ? 88 : 72)
    let scale = min(maxW / CGFloat(b.width), maxH / CGFloat(b.height))
    let dw = floor(CGFloat(b.width) * scale)
    let dh = floor(CGFloat(b.height) * scale)
    let dx = CGFloat(frame * 128) + floor((128 - dw) / 2)
    let dy: CGFloat = 5
    stripContext.draw(crop, in: CGRect(x: dx, y: dy, width: dw, height: dh))
}
let rawStrip = stripContext.makeImage()!
var stripPixels = rgba(rawStrip)
let stripWidth = rawStrip.width
let stripHeight = rawStrip.height
func stripIndex(_ x: Int, _ y: Int) -> Int { (y * stripWidth + x) * 4 }
for _ in 0..<8 {
    var fringe: [(Int, Int)] = []
    for y in 1..<(stripHeight - 1) {
        for x in 1..<(stripWidth - 1) {
            let i = stripIndex(x, y)
            guard stripPixels[i + 3] > 0 else { continue }
            let r = Int(stripPixels[i]), g = Int(stripPixels[i + 1]), b = Int(stripPixels[i + 2])
            guard min(r, g, b) >= 180, max(r, g, b) - min(r, g, b) <= 35 else { continue }
            let touchesAlpha = [stripIndex(x - 1, y), stripIndex(x + 1, y),
                                stripIndex(x, y - 1), stripIndex(x, y + 1)]
                .contains { stripPixels[$0 + 3] == 0 }
            if touchesAlpha { fringe.append((x, y)) }
        }
    }
    if fringe.isEmpty { break }
    for (x, y) in fringe {
        let i = stripIndex(x, y)
        stripPixels[i] = 0; stripPixels[i + 1] = 0
        stripPixels[i + 2] = 0; stripPixels[i + 3] = 0
    }
}
let strip = image(width: stripWidth, height: stripHeight, pixels: &stripPixels)
write(strip, to: args[3])

let combinedFrameCount = oldFrameCount + generatedFrameCount
let combined = CGContext(data: nil, width: combinedFrameCount * 128, height: 100,
                         bitsPerComponent: 8, bytesPerRow: combinedFrameCount * 128 * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
combined.interpolationQuality = .none
combined.setShouldAntialias(false)
combined.draw(oldSheet, in: CGRect(x: 0, y: 0, width: oldSheet.width, height: oldSheet.height))
combined.draw(strip, in: CGRect(x: oldSheet.width, y: 0, width: strip.width, height: strip.height))
write(combined.makeImage()!, to: args[4])
print("generated \(generatedFrameCount) transparent frames and combined \(combinedFrameCount)-frame atlas")
