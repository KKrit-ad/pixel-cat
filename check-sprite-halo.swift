import CoreGraphics
import Foundation
import ImageIO

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "cat-sheet.png"
let url = URL(fileURLWithPath: path) as CFURL
guard let source = CGImageSourceCreateWithURL(url, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot read \(path)")
}
precondition(image.width == 11008 && image.height == 100)

var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
let context = CGContext(data: &pixels,
                        width: image.width,
                        height: image.height,
                        bitsPerComponent: 8,
                        bytesPerRow: image.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

let catFrames = Array(0...39) + Array(46...85)
var haloPixels = 0
var affectedFrames = Set<Int>()
for frame in catFrames {
    for y in 1..<99 {
        for localX in 1..<127 {
            let x = frame * 128 + localX
            let i = (y * image.width + x) * 4
            guard pixels[i + 3] > 0 else { continue }
            let neighbors = [i - 4, i + 4, i - image.width * 4, i + image.width * 4]
            guard neighbors.contains(where: { pixels[$0 + 3] == 0 }) else { continue }

            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            // The kitten has a dark outline. Very bright neutral pixels that
            // directly touch transparency are remnants of the baked white or
            // checkerboard matte, not intentional fur.
            if min(r, g, b) >= 180 && max(r, g, b) - min(r, g, b) <= 35 {
                haloPixels += 1
                affectedFrames.insert(frame)
            }
        }
    }
}

precondition(haloPixels == 0,
             "white matte halo: \(haloPixels) boundary pixels across frames \(affectedFrames.sorted())")
print("PASS: no bright neutral matte pixels touch transparency in \(catFrames.count) cat frames")
