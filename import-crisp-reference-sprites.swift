import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let frameWidth = 128
private let frameHeight = 100
private let frameCount = 47

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
        throw NSError(domain: "PixelCatCrispImport", code: 1,
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

/// Removes only bright neutral pixels connected to the crop boundary. This
/// strips both the baked checkerboard and plain white backgrounds while
/// preserving enclosed white muzzle, chest, paw, and eye-highlight pixels.
private func extractSprite(_ crop: Crop, from source: CGImage) -> CGImage {
    let margin = 5
    let x = max(0, crop.x - margin)
    let y = max(0, crop.y - margin)
    let maxX = min(source.width, crop.x + crop.width + margin)
    let maxY = min(source.height, crop.y + crop.height + margin)
    let width = maxX - x, height = maxY - y
    let rect = CGRect(x: x, y: y, width: width, height: height)
    let image = source.cropping(to: rect)!

    let context = bitmapContext(width: width, height: height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)

    func isBackground(_ index: Int) -> Bool {
        let i = index * 4
        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
        return min(r, g, b) >= 170 && max(r, g, b) - min(r, g, b) <= 45
    }

    var outside = [Bool](repeating: false, count: width * height)
    var queue = [Int]()
    func seed(_ px: Int, _ py: Int) {
        let index = py * width + px
        if !outside[index], isBackground(index) {
            outside[index] = true
            queue.append(index)
        }
    }
    for px in 0..<width { seed(px, 0); seed(px, height - 1) }
    for py in 0..<height { seed(0, py); seed(width - 1, py) }

    var cursor = 0
    while cursor < queue.count {
        let index = queue[cursor]
        cursor += 1
        let px = index % width, py = index / width
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let nx = px + dx, ny = py + dy
            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
            let next = ny * width + nx
            if !outside[next], isBackground(next) {
                outside[next] = true
                queue.append(next)
            }
        }
    }

    for index in 0..<(width * height) {
        if outside[index] {
            pixels[index * 4] = 0
            pixels[index * 4 + 1] = 0
            pixels[index * 4 + 2] = 0
            pixels[index * 4 + 3] = 0
        } else {
            pixels[index * 4 + 3] = 255
        }
    }
    return context.makeImage()!
}

/// The generated climb source already has alpha. Snap it to a hard binary
/// mask before nearest-neighbor scaling so semi-transparent matte pixels
/// cannot create a light fringe in the app.
private func extractTransparentSprite(_ crop: Crop, from source: CGImage) -> CGImage {
    let margin = 5
    let x = max(0, crop.x - margin), y = max(0, crop.y - margin)
    let maxX = min(source.width, crop.x + crop.width + margin)
    let maxY = min(source.height, crop.y + crop.height + margin)
    let width = maxX - x, height = maxY - y
    let image = source.cropping(to: CGRect(x: x, y: y, width: width, height: height))!
    let context = bitmapContext(width: width, height: height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
    for index in 0..<(width * height) {
        let i = index * 4
        if pixels[i + 3] < 96 {
            pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
        } else {
            pixels[i + 3] = 255
        }
    }
    return context.makeImage()!
}

private func renderTransparent(_ crop: Crop, from source: CGImage) -> CGImage {
    let image = extractTransparentSprite(crop, from: source)
    let context = bitmapContext(width: frameWidth, height: frameHeight)
    context.interpolationQuality = .none
    context.setShouldAntialias(false)
    let scale = min(CGFloat(frameWidth - 8) / CGFloat(image.width),
                    CGFloat(frameHeight - 4) / CGFloat(image.height))
    let width = (CGFloat(image.width) * scale).rounded()
    let height = (CGFloat(image.height) * scale).rounded()
    let x = ((CGFloat(frameWidth) - width) / 2).rounded()
    context.draw(image, in: CGRect(x: x, y: crop.yOffset, width: width, height: height))
    return context.makeImage()!
}

private func render(_ crop: Crop, from source: CGImage) -> CGImage {
    let image = extractSprite(crop, from: source)
    let context = bitmapContext(width: frameWidth, height: frameHeight)
    context.clear(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    context.interpolationQuality = .none
    context.setShouldAntialias(false)

    let scale = min(CGFloat(frameWidth - 8) / CGFloat(image.width),
                    CGFloat(frameHeight - 4) / CGFloat(image.height))
    let width = (CGFloat(image.width) * scale).rounded()
    let height = (CGFloat(image.height) * scale).rounded()
    let x = ((CGFloat(frameWidth) - width) / 2).rounded()
    context.draw(image, in: CGRect(x: x, y: crop.yOffset, width: width, height: height))
    return context.makeImage()!
}

private func closedEyes(_ image: CGImage) -> CGImage {
    let context = bitmapContext(width: frameWidth, height: frameHeight)
    context.draw(image, in: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    let pixels = context.data!.bindMemory(to: UInt8.self, capacity: frameWidth * frameHeight * 4)

    var green = Set<Int>()
    for y in 0..<frameHeight {
        for x in 0..<frameWidth {
            let index = y * frameWidth + x
            let i = index * 4
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if pixels[i + 3] > 0, g > 55, g > r * 6 / 5, g > b * 6 / 5 {
                green.insert(index)
            }
        }
    }

    var eyes = [(minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int)]()
    while let seed = green.first {
        green.remove(seed)
        var queue = [seed], cursor = 0
        var minX = seed % frameWidth, maxX = minX
        var minY = seed / frameWidth, maxY = minY
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % frameWidth, y = index / frameWidth
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < frameWidth, ny >= 0, ny < frameHeight else { continue }
                    let next = ny * frameWidth + nx
                    if green.remove(next) != nil { queue.append(next) }
                }
            }
        }
        if queue.count >= 4 { eyes.append((minX, minY, maxX, maxY, queue.count)) }
    }

    for eye in eyes.sorted(by: { $0.count > $1.count }).prefix(2) {
        let minX = max(0, eye.minX - 2), maxX = min(frameWidth - 1, eye.maxX + 2)
        let minY = max(0, eye.minY - 2), maxY = min(frameHeight - 1, eye.maxY + 2)
        var nearbyColors = [UInt32: Int]()
        for y in max(0, minY - 8)...min(frameHeight - 1, maxY + 8) {
            for x in max(0, minX - 8)...min(frameWidth - 1, maxX + 8) {
                if x >= minX, x <= maxX, y >= minY, y <= maxY { continue }
                let i = (y * frameWidth + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                guard pixels[i + 3] > 0,
                      max(r, g, b) - min(r, g, b) < 32,
                      r >= 70, r <= 190 else { continue }
                let color = UInt32(r << 16 | g << 8 | b)
                nearbyColors[color, default: 0] += 1
            }
        }
        let fur = nearbyColors.max(by: { $0.value < $1.value })?.key ?? 0x87909A
        let furR = UInt8((fur >> 16) & 0xff)
        let furG = UInt8((fur >> 8) & 0xff)
        let furB = UInt8(fur & 0xff)
        for y in minY...maxY {
            for x in minX...maxX {
                let target = (y * frameWidth + x) * 4
                guard pixels[target + 3] > 0 else { continue }
                pixels[target] = furR
                pixels[target + 1] = furG
                pixels[target + 2] = furB
                pixels[target + 3] = 255
            }
        }
        let lineY = (eye.minY + eye.maxY) / 2
        for x in (minX + 2)..<(maxX - 1) {
            let i = (lineY * frameWidth + x) * 4
            guard pixels[i + 3] > 0 else { continue }
            pixels[i] = 24; pixels[i + 1] = 29; pixels[i + 2] = 35; pixels[i + 3] = 255
            if lineY > 0 {
                let below = ((lineY - 1) * frameWidth + x) * 4
                pixels[below] = 24; pixels[below + 1] = 29; pixels[below + 2] = 35; pixels[below + 3] = 255
            }
        }
    }
    return context.makeImage()!
}

private func shifted(_ image: CGImage, y: CGFloat) -> CGImage {
    let context = bitmapContext(width: frameWidth, height: frameHeight)
    context.draw(image, in: CGRect(x: 0, y: y,
                                   width: CGFloat(frameWidth), height: CGFloat(frameHeight)))
    return context.makeImage()!
}

/// Locks a multi-frame front-facing animation to one facial anchor. ImageGen
/// may move the character a few pixels between cells even when the intended
/// motion is only in the tail or ears; aligning the green-eye centroid keeps
/// the torso visually stationary without erasing that secondary motion.
private func alignedToFirstEyeAnchor(_ images: [CGImage]) -> [CGImage] {
    func eyeAnchor(_ image: CGImage) -> CGFloat {
        let context = bitmapContext(width: frameWidth, height: frameHeight)
        context.draw(image, in: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
        let pixels = context.data!.bindMemory(to: UInt8.self,
                                               capacity: frameWidth * frameHeight * 4)
        var totalX = 0, count = 0
        for y in 0..<frameHeight {
            for x in 0..<frameWidth {
                let i = (y * frameWidth + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if pixels[i + 3] > 0, g >= 55, g * 5 > r * 6, g * 5 > b * 6 {
                    totalX += x
                    count += 1
                }
            }
        }
        precondition(count >= 8, "Cannot find the green-eye anchor")
        return CGFloat(totalX) / CGFloat(count)
    }

    guard let first = images.first else { return [] }
    let target = eyeAnchor(first)
    return images.map { image in
        let offset = (target - eyeAnchor(image)).rounded()
        let context = bitmapContext(width: frameWidth, height: frameHeight)
        context.clear(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.draw(image, in: CGRect(x: offset, y: 0,
                                       width: CGFloat(frameWidth), height: CGFloat(frameHeight)))
        return context.makeImage()!
    }
}

private func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path) as CFURL
    let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "PixelCatCrispImport", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot write image: \(path)"])
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 5 else {
    fatalError("Usage: import-crisp-reference-sprites.swift poses.png actions.png movement.png output.png [installed-sheet.png] [climb-strip.png] [sit-strip.png]")
}
let poses = try loadImage(arguments[1])
let actions = try loadImage(arguments[2])
let movement = try loadImage(arguments[3])
let outputPath = arguments[4]
let installedPath = arguments.count > 5 ? arguments[5] : "cat-sheet.png"
let climbPath = arguments.count > 6 ? arguments[6] : "climb-frames-v2-generated.png"
let sitPath = arguments.count > 7 ? arguments[7] : "sit-idle-frames-v2-generated.png"
let installed = try loadImage(installedPath)
let climbSource = try loadImage(climbPath)
let sitSource = try loadImage(sitPath)
let installedFrameCount: Int
let installedPropFrames: ClosedRange<Int>
switch installed.width / frameWidth {
case 45:
    installedFrameCount = 45
    installedPropFrames = 38...43
case 47:
    installedFrameCount = 47
    installedPropFrames = 40...45
default:
    fatalError("Installed sheet must have 45 or 47 frames of 128 px")
}
let installedFrameWidth = installed.width / installedFrameCount
let installedFrameHeight = installed.height

// Movement sheet: top row walk, bottom row run.
let walkCrops = [
    Crop(80, 146, 323, 218), Crop(529, 146, 313, 222),
    Crop(927, 151, 328, 211), Crop(1357, 146, 322, 222)
]
let runCrops = [
    Crop(71, 517, 370, 205), Crop(541, 517, 286, 221),
    Crop(921, 505, 355, 233), Crop(1389, 499, 303, 211)
]
let walk = walkCrops.map { render($0, from: movement) }
let run = runCrops.map { render($0, from: movement) }

// Pose sheet.
let low = render(Crop(126, 423, 378, 225), from: poses)
let stretchClosed = render(Crop(607, 391, 356, 277), from: poses)
let sleep = render(Crop(1079, 464, 311, 186), from: poses)
let jump = render(Crop(296, 687, 313, 262), from: poses)
let stretchHappy = render(Crop(786, 687, 332, 277), from: poses)

// Action sheet: head tilt, lick, and dangling/held.
let tilt = render(Crop(111, 257, 337, 419), from: actions)
let lick = render(Crop(520, 273, 341, 402), from: actions)
let held = render(Crop(1395, 225, 254, 477), from: actions)

// ImageGen strips: four real idle beats and four alternating climb beats.
// The seated strip has real alpha. The climb strip has a baked checkerboard,
// so it intentionally goes through the boundary-connected matte remover.
let sitIdleRaw = [
    Crop(95, 120, 390, 470), Crop(620, 120, 390, 470),
    Crop(1140, 120, 400, 470), Crop(1665, 120, 410, 470)
].map { renderTransparent($0, from: sitSource) }
let sitIdle = alignedToFirstEyeAnchor(sitIdleRaw)
let climb = [
    Crop(115, 75, 390, 545), Crop(630, 75, 390, 545),
    Crop(1130, 75, 440, 545), Crop(1670, 75, 410, 545)
].map { render($0, from: climbSource) }

var frames = [CGImage]()
frames.append(contentsOf: walk)
frames.append(contentsOf: walk.map(closedEyes))
frames.append(contentsOf: run)
frames.append(contentsOf: run.map(closedEyes))
frames.append(contentsOf: sitIdle)
frames.append(contentsOf: sitIdle.map(closedEyes))
frames.append(contentsOf: [tilt, shifted(tilt, y: 1)])
frames.append(contentsOf: [lick, shifted(lick, y: 1)])
frames.append(contentsOf: [sleep, shifted(sleep, y: 1)])
frames.append(contentsOf: [stretchClosed, stretchHappy])
frames.append(contentsOf: [low, stretchHappy])
frames.append(contentsOf: climb)
frames.append(contentsOf: [held, shifted(held, y: 1)])

// Preserve PixelCat's existing ball and gecko frames.
for index in installedPropFrames {
    let crop = installed.cropping(to: CGRect(x: index * installedFrameWidth, y: 0,
                                              width: installedFrameWidth,
                                              height: installedFrameHeight))!
    let context = bitmapContext(width: frameWidth, height: frameHeight)
    context.interpolationQuality = .none
    context.draw(crop, in: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    frames.append(context.makeImage()!)
}
frames.append(jump)
precondition(frames.count == frameCount)

let sheet = bitmapContext(width: frameWidth * frameCount, height: frameHeight)
sheet.clear(CGRect(x: 0, y: 0, width: frameWidth * frameCount, height: frameHeight))
for (index, frame) in frames.enumerated() {
    sheet.draw(frame, in: CGRect(x: index * frameWidth, y: 0,
                                 width: frameWidth, height: frameHeight))
}
try writePNG(sheet.makeImage()!, to: outputPath)

let columns = 8, rows = 6, previewScale = 2
let contact = bitmapContext(width: columns * frameWidth, height: rows * frameHeight)
contact.setFillColor(CGColor(red: 0.957, green: 0.965, blue: 0.949, alpha: 1))
contact.fill(CGRect(x: 0, y: 0, width: columns * frameWidth, height: rows * frameHeight))
for (index, frame) in frames.enumerated() {
    let column = index % columns, row = index / columns
    contact.draw(frame, in: CGRect(x: column * frameWidth,
                                   y: (rows - row - 1) * frameHeight,
                                   width: frameWidth, height: frameHeight))
}
let preview = bitmapContext(width: columns * frameWidth * previewScale,
                            height: rows * frameHeight * previewScale)
preview.interpolationQuality = .none
preview.draw(contact.makeImage()!, in: CGRect(x: 0, y: 0,
                                               width: columns * frameWidth * previewScale,
                                               height: rows * frameHeight * previewScale))
let previewPath = URL(fileURLWithPath: outputPath).deletingPathExtension().path + "-preview.png"
try writePNG(preview.makeImage()!, to: previewPath)

print("wrote \(outputPath) (\(frameWidth * frameCount)x\(frameHeight), \(frames.count) frames)")
print("wrote \(previewPath) (\(columns)x\(rows) contact preview)")
