import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let frameWidth = 128
private let frameHeight = 100
private let sourceFrameCount = 78

private let ink = CGColor(red: 0.17, green: 0.19, blue: 0.22, alpha: 1)
private let fur = CGColor(red: 0.49, green: 0.53, blue: 0.58, alpha: 1)
private let lightFur = CGColor(red: 0.65, green: 0.69, blue: 0.72, alpha: 1)
private let keyboard = CGColor(red: 0.28, green: 0.34, blue: 0.39, alpha: 1)
private let keyboardTop = CGColor(red: 0.40, green: 0.48, blue: 0.54, alpha: 1)
private let key = CGColor(red: 0.56, green: 0.75, blue: 0.85, alpha: 1)
private let activeKey = CGColor(red: 0.32, green: 0.88, blue: 0.60, alpha: 1)

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

func rect(_ ctx: CGContext, _ color: CGColor,
          _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: x, y: y, width: width, height: height))
}

/// คีย์บอร์ดทรงพิกเซลเตี้ย วางหน้าขาโดยไม่บังหน้า และมีปุ่มที่สว่างตามอุ้งเท้า
func drawKeyboard(_ ctx: CGContext, baseX: CGFloat, frame: Int) {
    rect(ctx, ink, baseX + 30, 5, 68, 18)
    rect(ctx, ink, baseX + 35, 22, 58, 5)
    rect(ctx, keyboard, baseX + 33, 8, 62, 12)
    rect(ctx, keyboardTop, baseX + 38, 20, 52, 4)

    for row in 0..<2 {
        for column in 0..<8 {
            let isLeftTap = frame % 2 == 0 && row == 1 && column == 2
            let isRightTap = frame % 2 == 1 && row == 1 && column == 5
            rect(ctx, isLeftTap || isRightTap ? activeKey : key,
                 baseX + 36 + CGFloat(column * 7), 10 + CGFloat(row * 6), 4, 3)
        }
    }
    rect(ctx, key, baseX + 49, 7, 30, 3)
}

/// อุ้งเท้าสลับยกทีละข้าง; ตัวฐานใช้ sit 4 เฟรมจึงได้หางสะบัดตามจังหวะเดียวกัน
func drawTypingPaws(_ ctx: CGContext, baseX: CGFloat, frame: Int) {
    let leftLift: CGFloat = frame % 2 == 0 ? 2 : 0
    let rightLift: CGFloat = frame % 2 == 1 ? 2 : 0

    rect(ctx, ink, baseX + 43, 22 + leftLift, 14, 11)
    rect(ctx, fur, baseX + 46, 24 + leftLift, 9, 7)
    rect(ctx, lightFur, baseX + 47, 24 + leftLift, 7, 3)
    rect(ctx, ink, baseX + 70, 22 + rightLift, 14, 11)
    rect(ctx, fur, baseX + 72, 24 + rightLift, 9, 7)
    rect(ctx, lightFur, baseX + 73, 24 + rightLift, 7, 3)

    // เส้น motion สั้น ๆ เฉพาะข้างที่ยก ไม่ทำให้ทั้งตัวสั่น
    let motionX = frame % 2 == 0 ? baseX + 41 : baseX + 85
    rect(ctx, activeKey, motionX, 34, 2, 4)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fatalError("usage: swift make-coding-sprites.swift base-78.png coding-strip.png combined-82.png")
}

let source = load(arguments[1])
precondition(source.width == sourceFrameCount * frameWidth && source.height == frameHeight,
             "expected a 78-frame 128x100 atlas")

let frameCount = 4
let stripContext = CGContext(data: nil, width: frameCount * frameWidth, height: frameHeight,
                             bitsPerComponent: 8, bytesPerRow: frameCount * frameWidth * 4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
stripContext.interpolationQuality = .none
stripContext.setShouldAntialias(false)

for (outputFrame, sourceFrame) in [16, 17, 18, 19].enumerated() {
    guard let crop = source.cropping(to: CGRect(x: sourceFrame * frameWidth, y: 0,
                                                width: frameWidth, height: frameHeight)) else {
        fatalError("cannot crop source frame \(sourceFrame)")
    }
    let baseX = CGFloat(outputFrame * frameWidth)
    stripContext.draw(crop, in: CGRect(x: baseX, y: 0,
                                      width: CGFloat(frameWidth), height: CGFloat(frameHeight)))
    drawKeyboard(stripContext, baseX: baseX, frame: outputFrame)
    drawTypingPaws(stripContext, baseX: baseX, frame: outputFrame)
}

let strip = stripContext.makeImage()!
write(strip, to: arguments[2])

let combinedContext = CGContext(data: nil, width: 82 * frameWidth, height: frameHeight,
                                bitsPerComponent: 8, bytesPerRow: 82 * frameWidth * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
combinedContext.interpolationQuality = .none
combinedContext.setShouldAntialias(false)
combinedContext.draw(source, in: CGRect(x: 0, y: 0,
                                       width: CGFloat(source.width), height: CGFloat(frameHeight)))
combinedContext.draw(strip, in: CGRect(x: CGFloat(source.width), y: 0,
                                      width: CGFloat(strip.width), height: CGFloat(frameHeight)))
write(combinedContext.makeImage()!, to: arguments[3])
print("generated coding=4 and combined an 82-frame atlas")
