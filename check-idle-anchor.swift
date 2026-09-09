import CoreGraphics
import Foundation
import ImageIO

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "cat-sheet.png"
let frameWidth = 128
let frameHeight = 100
let sitFrames = Array(16...19)

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot read \(path)")
}
precondition(image.width == 11008 && image.height == frameHeight)

var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
let context = CGContext(data: &pixels,
                        width: image.width,
                        height: image.height,
                        bitsPerComponent: 8,
                        bytesPerRow: image.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

// Green eye pixels are a stable facial landmark. Tail and ear-tip motion are
// allowed, but the face itself must not drift horizontally while the cat idles.
let landmarks: [(anchor: Double, span: Int, count: Int)] = sitFrames.map { frame in
    var xs = [Int]()
    for y in 0..<frameHeight {
        for localX in 0..<frameWidth {
            let x = frame * frameWidth + localX
            let i = (y * image.width + x) * 4
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if pixels[i + 3] > 0, g >= 55, g * 5 > r * 6, g * 5 > b * 6 {
                xs.append(localX)
            }
        }
    }
    precondition(xs.count >= 8, "frame \(frame) has no usable eye landmark")
    return (Double(xs.reduce(0, +)) / Double(xs.count), xs.max()! - xs.min()! + 1, xs.count)
}

let anchors = landmarks.map(\.anchor)
let drift = anchors.max()! - anchors.min()!
let values = anchors.map { String(format: "%.2f", $0) }.joined(separator: ", ")
let shapes = landmarks.map { "span=\($0.span)/count=\($0.count)" }.joined(separator: ", ")
if drift > 1.0 {
    FileHandle.standardError.write(
        "FAIL: idle face drifts \(String(format: "%.2f", drift)) px; anchors=[\(values)] shapes=[\(shapes)]\n"
            .data(using: .utf8)!
    )
    exit(1)
}
print("PASS: idle face drift \(String(format: "%.2f", drift)) px; anchors=[\(values)]")
