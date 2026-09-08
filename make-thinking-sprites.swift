import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let frameWidth = 128
private let frameHeight = 100
private let sourceFrameCount = 59

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("cannot load \(path)")
    }
    return image
}

func write(_ image: CGImage, to path: String) {
    guard let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("cannot create \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "cannot write \(path)")
}

func pixelBubble(_ ctx: CGContext, x: CGFloat, y: CGFloat, size: CGFloat) {
    let outline = CGColor(red: 0.17, green: 0.19, blue: 0.22, alpha: 1)
    let blue = CGColor(red: 0.47, green: 0.68, blue: 0.90, alpha: 1)
    ctx.setFillColor(outline)
    ctx.fill(CGRect(x: x + 1, y: y, width: size - 2, height: size))
    ctx.fill(CGRect(x: x, y: y + 1, width: size, height: size - 2))
    if size >= 4 {
        ctx.setFillColor(blue)
        ctx.fill(CGRect(x: x + 2, y: y + 2, width: size - 4, height: size - 4))
    }
}

/// อุ้งเท้าแตะคางเบา ๆ วาดทับหน้าอกเดิมโดยใช้สีเดียวกับตัวและเส้นขอบเข้ม
func thinkingPaw(_ ctx: CGContext, baseX: CGFloat, lift: CGFloat) {
    let outline = CGColor(red: 0.17, green: 0.19, blue: 0.22, alpha: 1)
    let fur = CGColor(red: 0.49, green: 0.53, blue: 0.58, alpha: 1)
    let light = CGColor(red: 0.65, green: 0.69, blue: 0.72, alpha: 1)
    let y: CGFloat = 43 + lift
    ctx.setFillColor(outline)
    ctx.fill(CGRect(x: baseX + 68, y: y + 2, width: 11, height: 7))
    ctx.fill(CGRect(x: baseX + 70, y: y, width: 8, height: 10))
    ctx.setFillColor(fur)
    ctx.fill(CGRect(x: baseX + 70, y: y + 3, width: 7, height: 5))
    ctx.fill(CGRect(x: baseX + 72, y: y + 1, width: 5, height: 7))
    ctx.setFillColor(light)
    ctx.fill(CGRect(x: baseX + 71, y: y + 7, width: 5, height: 1))
}

private let starRows = [
    "...#...",
    "...#...",
    ".#.#.#.",
    "..###..",
    "#######",
    "..###..",
    ".#.#.#."
]

func ahaStar(_ ctx: CGContext, baseX: CGFloat, large: Bool) {
    let scale: CGFloat = large ? 2 : 1
    let originX = baseX + (large ? 100 : 106)
    let originY: CGFloat = large ? 75 : 82
    let outline = CGColor(red: 0.17, green: 0.19, blue: 0.22, alpha: 1)
    let gold = CGColor(red: 1.0, green: 0.75, blue: 0.22, alpha: 1)
    for (pass, color) in [outline, gold].enumerated() {
        ctx.setFillColor(color)
        for (row, line) in starRows.enumerated() {
            for (column, value) in line.enumerated() where value == "#" {
            let rect = CGRect(x: originX + CGFloat(column) * scale,
                              y: originY + CGFloat(starRows.count - 1 - row) * scale,
                              width: scale, height: scale)
                ctx.fill(pass == 0 ? rect.insetBy(dx: -1, dy: -1) : rect)
            }
        }
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fatalError("usage: swift make-thinking-sprites.swift base-59.png thinking-strip.png combined-65.png")
}

let source = load(arguments[1])
precondition(source.width == sourceFrameCount * frameWidth && source.height == frameHeight,
             "expected a 59-frame 128x100 atlas")

let stripContext = CGContext(data: nil, width: 6 * frameWidth, height: frameHeight,
                             bitsPerComponent: 8, bytesPerRow: 6 * frameWidth * 4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
stripContext.interpolationQuality = .none
stripContext.setShouldAntialias(false)

// เฟรมที่สามใช้ sitBlink เพื่อให้ loop คิดยาว ๆ ยังกระพริบตาตามธรรมชาติ
let sourceFrames = [16, 17, 20, 19, 16, 17]
for (outputFrame, sourceFrame) in sourceFrames.enumerated() {
    guard let crop = source.cropping(to: CGRect(x: sourceFrame * frameWidth, y: 0,
                                                width: frameWidth, height: frameHeight)) else {
        fatalError("cannot crop source frame \(sourceFrame)")
    }
    let baseX = CGFloat(outputFrame * frameWidth)
    stripContext.draw(crop, in: CGRect(x: baseX, y: 0,
                                      width: CGFloat(frameWidth), height: CGFloat(frameHeight)))
    if outputFrame < 4 {
        thinkingPaw(stripContext, baseX: baseX, lift: [0, 1, 0, -1][outputFrame])
        let bubbleCount = [1, 2, 3, 2][outputFrame]
        if bubbleCount >= 1 { pixelBubble(stripContext, x: baseX + 97, y: 69, size: 4) }
        if bubbleCount >= 2 { pixelBubble(stripContext, x: baseX + 103, y: 76, size: 6) }
        if bubbleCount >= 3 { pixelBubble(stripContext, x: baseX + 111, y: 84, size: 8) }
    } else {
        ahaStar(stripContext, baseX: baseX, large: outputFrame == 5)
    }
}

let strip = stripContext.makeImage()!
write(strip, to: arguments[2])

let combinedContext = CGContext(data: nil, width: 65 * frameWidth, height: frameHeight,
                                bitsPerComponent: 8, bytesPerRow: 65 * frameWidth * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
combinedContext.interpolationQuality = .none
combinedContext.setShouldAntialias(false)
combinedContext.draw(source, in: CGRect(x: 0, y: 0,
                                       width: CGFloat(source.width), height: CGFloat(frameHeight)))
combinedContext.draw(strip, in: CGRect(x: CGFloat(source.width), y: 0,
                                      width: CGFloat(strip.width), height: CGFloat(frameHeight)))
write(combinedContext.makeImage()!, to: arguments[3])
print("generated think=4 + aha=2 and combined a 65-frame atlas")
