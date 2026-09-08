import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let frameWidth = 128
private let frameHeight = 100
private let sourceFrameCount = 65

private let ink = CGColor(red: 0.17, green: 0.19, blue: 0.22, alpha: 1)
private let fur = CGColor(red: 0.49, green: 0.53, blue: 0.58, alpha: 1)
private let lightFur = CGColor(red: 0.65, green: 0.69, blue: 0.72, alpha: 1)
private let gold = CGColor(red: 1.0, green: 0.70, blue: 0.16, alpha: 1)
private let goldShade = CGColor(red: 0.88, green: 0.48, blue: 0.08, alpha: 1)
private let blue = CGColor(red: 0.30, green: 0.66, blue: 0.91, alpha: 1)
private let green = CGColor(red: 0.29, green: 0.78, blue: 0.34, alpha: 1)
private let red = CGColor(red: 0.91, green: 0.25, blue: 0.25, alpha: 1)
private let pink = CGColor(red: 1.0, green: 0.48, blue: 0.55, alpha: 1)
private let paper = CGColor(red: 0.91, green: 0.89, blue: 0.79, alpha: 1)
private let screen = CGColor(red: 0.20, green: 0.27, blue: 0.32, alpha: 1)

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

func pattern(_ ctx: CGContext, rows: [String], x: CGFloat, y: CGFloat,
             scale: CGFloat, color: CGColor) {
    ctx.setFillColor(color)
    for (row, line) in rows.reversed().enumerated() {
        for (column, pixel) in line.enumerated() where pixel == "#" {
            ctx.fill(CGRect(x: x + CGFloat(column) * scale,
                            y: y + CGFloat(row) * scale,
                            width: scale, height: scale))
        }
    }
}

/// หมวกนิรภัยทรงเตี้ย ไม่บังตา และขยับแสงสะท้อนหนึ่งพิกเซลในแต่ละเฟรม
func builderHat(_ ctx: CGContext, baseX: CGFloat, frame: Int) {
    rect(ctx, ink, baseX + 37, 78, 49, 7)
    rect(ctx, ink, baseX + 42, 84, 39, 8)
    rect(ctx, ink, baseX + 49, 92, 25, 5)
    rect(ctx, goldShade, baseX + 39, 80, 45, 3)
    rect(ctx, gold, baseX + 44, 84, 35, 6)
    rect(ctx, gold, baseX + 51, 90, 21, 5)
    rect(ctx, goldShade, baseX + 59, 85, 5, 10)
    rect(ctx, paper, baseX + 50 + CGFloat(frame), 92, 6, 2)

    // ค้อนเล็กข้างอุ้งเท้า ทำให้สามเฟรมอ่านว่า “กำลัง build” ไม่ใช่แค่ใส่หมวก
    let lift = CGFloat([0, 2, 1][frame])
    rect(ctx, ink, baseX + 87, 25 + lift, 5, 22)
    rect(ctx, goldShade, baseX + 88, 27 + lift, 3, 18)
    rect(ctx, ink, baseX + 82, 44 + lift, 15, 7)
    rect(ctx, lightFur, baseX + 84, 46 + lift, 11, 3)
}

/// หน้าจอทดสอบพร้อมจุด progress; ใช้เฟรมฐานที่ตาเปิด/หลับสลับกันจึงดูเหมือนกำลังลุ้น
func testMonitor(_ ctx: CGContext, baseX: CGFloat, frame: Int) {
    let y = CGFloat(7 + (frame == 1 ? 1 : 0))
    rect(ctx, ink, baseX + 82, y, 35, 26)
    rect(ctx, screen, baseX + 85, y + 4, 29, 18)
    rect(ctx, ink, baseX + 94, y - 4, 10, 5)
    rect(ctx, ink, baseX + 88, y - 6, 22, 3)
    for i in 0...frame {
        rect(ctx, blue, baseX + 89 + CGFloat(i * 7), y + 14, 4, 4)
    }
    rect(ctx, green, baseX + 89, y + 7, CGFloat(7 + frame * 5), 3)
}

/// ชูอุ้งเท้าขวาและมีเครื่องหมายผ่านขนาดเล็กเพื่ออ่านสถานะได้แม้เปิด Reduce Motion
func passingPaw(_ ctx: CGContext, baseX: CGFloat, high: Bool) {
    let lift: CGFloat = high ? 4 : 0
    // แขนไล่พิกเซลขึ้นเป็นแนวเฉียง จึงไม่ดูเหมือนป้ายสี่เหลี่ยมข้างหน้า
    rect(ctx, ink, baseX + 76, 44 + lift, 9, 12)
    rect(ctx, fur, baseX + 79, 45 + lift, 5, 10)
    rect(ctx, ink, baseX + 80, 53 + lift, 9, 13)
    rect(ctx, fur, baseX + 82, 54 + lift, 5, 11)
    rect(ctx, ink, baseX + 83, 63 + lift, 14, 13)
    rect(ctx, lightFur, baseX + 86, 66 + lift, 8, 7)
    rect(ctx, pink, baseX + 89, 67 + lift, 4, 4)
    rect(ctx, pink, baseX + 86, 71 + lift, 2, 2)
    rect(ctx, pink, baseX + 93, 71 + lift, 2, 2)
    rect(ctx, ink, baseX + 85, 74 + lift, 3, 3)
    rect(ctx, ink, baseX + 91, 74 + lift, 3, 3)
    pattern(ctx, rows: ["#....", ".#...", "..#.#", "...#."],
            x: baseX + 101, y: 74, scale: 3, color: ink)
    pattern(ctx, rows: ["#....", ".#...", "..#.#", "...#."],
            x: baseX + 102, y: 75, scale: 2, color: green)
}

/// กระดาษ error อยู่ในอุ้งเท้าและหยดน้ำตาไหลลงทีละช่วง ตัวน้องไม่ถูกเขย่า
func failedPaper(_ ctx: CGContext, baseX: CGFloat, frame: Int) {
    let y = CGFloat(17 + (frame == 1 ? 1 : 0))
    rect(ctx, ink, baseX + 74, y, 38, 34)
    rect(ctx, paper, baseX + 77, y + 3, 32, 28)
    pattern(ctx, rows: ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
            x: baseX + 86, y: y + 9, scale: 3, color: red)
    rect(ctx, ink, baseX + 72, y + 8, 8, 7)
    rect(ctx, lightFur, baseX + 74, y + 10, 5, 4)
    rect(ctx, ink, baseX + 106, y + 8, 8, 7)
    rect(ctx, lightFur, baseX + 107, y + 10, 5, 4)

    let drop = CGFloat(frame * 4)
    rect(ctx, blue, baseX + 49, 47 - drop, 4, CGFloat(5 + frame * 2))
    rect(ctx, blue, baseX + 70, 48 - drop, 4, CGFloat(4 + frame * 2))
}

/// ป้ายถาม permission ขยับขึ้นเล็กน้อยแทนการสั่นวน
func permissionSign(_ ctx: CGContext, baseX: CGFloat, raised: Bool) {
    let lift: CGFloat = raised ? 3 : 0
    rect(ctx, ink, baseX + 79, 42 + lift, 5, 34)
    rect(ctx, goldShade, baseX + 80, 44 + lift, 3, 30)
    rect(ctx, ink, baseX + 75, 69 + lift, 47, 27)
    rect(ctx, paper, baseX + 78, 72 + lift, 41, 21)
    pattern(ctx, rows: [".###.", "#...#", "...#.", "..#..", ".....", "..#.."],
            x: baseX + 91, y: 75 + lift, scale: 3, color: goldShade)
    rect(ctx, ink, baseX + 75, 48 + lift, 9, 7)
    rect(ctx, lightFur, baseX + 77, 50 + lift, 5, 4)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fatalError("usage: swift make-build-test-sprites.swift base-65.png awareness-strip.png combined-78.png")
}

let source = load(arguments[1])
precondition(source.width == sourceFrameCount * frameWidth && source.height == frameHeight,
             "expected a 65-frame 128x100 atlas")

let frameCount = 13
let stripContext = CGContext(data: nil, width: frameCount * frameWidth, height: frameHeight,
                             bitsPerComponent: 8, bytesPerRow: frameCount * frameWidth * 4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
stripContext.interpolationQuality = .none
stripContext.setShouldAntialias(false)

// build 3, test 3, pass 2, fail 3, permission 2
let sourceFrames = [16, 17, 19, 16, 20, 17, 16, 17, 20, 21, 20, 16, 17]
for (outputFrame, sourceFrame) in sourceFrames.enumerated() {
    guard let crop = source.cropping(to: CGRect(x: sourceFrame * frameWidth, y: 0,
                                                width: frameWidth, height: frameHeight)) else {
        fatalError("cannot crop source frame \(sourceFrame)")
    }
    let baseX = CGFloat(outputFrame * frameWidth)
    stripContext.draw(crop, in: CGRect(x: baseX, y: 0,
                                      width: CGFloat(frameWidth), height: CGFloat(frameHeight)))
    switch outputFrame {
    case 0...2: builderHat(stripContext, baseX: baseX, frame: outputFrame)
    case 3...5: testMonitor(stripContext, baseX: baseX, frame: outputFrame - 3)
    case 6...7: passingPaw(stripContext, baseX: baseX, high: outputFrame == 7)
    case 8...10: failedPaper(stripContext, baseX: baseX, frame: outputFrame - 8)
    default: permissionSign(stripContext, baseX: baseX, raised: outputFrame == 12)
    }
}

let strip = stripContext.makeImage()!
write(strip, to: arguments[2])

let combinedContext = CGContext(data: nil, width: 78 * frameWidth, height: frameHeight,
                                bitsPerComponent: 8, bytesPerRow: 78 * frameWidth * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
combinedContext.interpolationQuality = .none
combinedContext.setShouldAntialias(false)
combinedContext.draw(source, in: CGRect(x: 0, y: 0,
                                       width: CGFloat(source.width), height: CGFloat(frameHeight)))
combinedContext.draw(strip, in: CGRect(x: CGFloat(source.width), y: 0,
                                      width: CGFloat(strip.width), height: CGFloat(frameHeight)))
write(combinedContext.makeImage()!, to: arguments[3])
print("generated build=3 test=3 pass=2 fail=3 permission=2 and combined a 78-frame atlas")
