// Sprites
// นิยามท่าทางและตัวถอดสไปรต์ชีท

import Cocoa

struct Pose {
    let start: Int
    let count: Int
    let fps: Double
}

let POSES: [String: Pose] = [
    "walk":        Pose(start: 0, count: 4, fps: 9.0),
    "walkBlink":   Pose(start: 4, count: 4, fps: 9.0),
    "run":         Pose(start: 8, count: 4, fps: 12.0),
    "runBlink":    Pose(start: 12, count: 4, fps: 12.0),
    "sit":         Pose(start: 16, count: 4, fps: 2.2),
    "sitBlink":    Pose(start: 20, count: 4, fps: 2.2),
    "tilt":        Pose(start: 24, count: 2, fps: 1.6),
    "lick":        Pose(start: 26, count: 2, fps: 2.5),
    "sleep":       Pose(start: 28, count: 2, fps: 1.0),
    "stretch":     Pose(start: 30, count: 2, fps: 2.0),
    "crouch":      Pose(start: 32, count: 2, fps: 4.0),
    "climb":       Pose(start: 34, count: 4, fps: 7.0),
    "held":        Pose(start: 38, count: 2, fps: 3.0),
    "ball":        Pose(start: 40, count: 4, fps: 8.0),
    "gecko":       Pose(start: 44, count: 2, fps: 7.0),
    "jump":        Pose(start: 46, count: 1, fps: 1.0),
    "point":       Pose(start: 47, count: 4, fps: 3.2),
    "courier":     Pose(start: 51, count: 4, fps: 9.0),
    "rescuePack":  Pose(start: 55, count: 3, fps: 2.2),
    "rescueReady": Pose(start: 58, count: 1, fps: 1.0),
    "think":       Pose(start: 59, count: 4, fps: 2.2),
    "aha":         Pose(start: 63, count: 2, fps: 5.0),
    "buildWork":   Pose(start: 65, count: 3, fps: 3.0),
    "testWatch":   Pose(start: 68, count: 3, fps: 2.4),
    "testPass":    Pose(start: 71, count: 2, fps: 4.0),
    "testFail":    Pose(start: 73, count: 3, fps: 2.4),
    "permission":  Pose(start: 76, count: 2, fps: 2.0),
    "coding":      Pose(start: 78, count: 4, fps: 5.2)
]

// Pixel-aligned atlas metadata. ค่านี้เป็นส่วนหนึ่งของ sprite asset ไม่ได้คำนวณจาก test runtime
// เฟรมที่ไม่อยู่ในตารางใช้ (0, 0); blink cycle ใช้ค่าเดียวกับเฟรมปกติที่คู่กัน
let FRAME_ANCHOR_OFFSETS: [Int: (x: CGFloat, y: CGFloat)] = [
    0: (2, 0), 1: (2, 0), 4: (2, 0), 5: (2, 0),
    8: (2, 0), 9: (1, 0), 10: (-1, 0),
    12: (2, 0), 13: (1, 0), 14: (-1, 0),
    34: (-1, 0), 35: (3, 0), 37: (5, -2)
]

final class Sheet {
    static let shared = Sheet()
    private(set) var frames: [CGImage] = []
    private(set) var masks: [[Bool]] = []
    private(set) var spans: [(Int, Int)] = []
    private(set) var eyeAnchorsX: [CGFloat?] = []
    private(set) var footAnchorsY: [CGFloat] = []
    private(set) var anchorOffsetsX: [CGFloat] = []
    private(set) var anchorOffsetsY: [CGFloat] = []

    init() {
        guard let data = Data(base64Encoded: SHEET_BASE64, options: .ignoreUnknownCharacters),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fatalError("ไม่สามารถโหลดสไปรต์ชีทได้")
        }
        let total = full.width / SPRITE_W
        var bytes = [UInt8](repeating: 0, count: full.width * full.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: full.width, height: full.height,
                                      bitsPerComponent: 8, bytesPerRow: full.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(full, in: CGRect(x: 0, y: 0, width: full.width, height: full.height))
        }
        for i in 0..<total {
            if let cropped = full.cropping(to: CGRect(x: i * SPRITE_W, y: 0,
                                                      width: SPRITE_W, height: SPRITE_H)) {
                frames.append(cropped)
            }
            var mask = [Bool](repeating: false, count: SPRITE_W * SPRITE_H)
            for y in 0..<SPRITE_H {
                for x in 0..<SPRITE_W {
                    let offset = (y * full.width + i * SPRITE_W + x) * 4 + 3
                    mask[y * SPRITE_W + x] = bytes[offset] > 0
                }
            }
            masks.append(mask)
            var eyeXs: [Int] = []
            for y in 0..<SPRITE_H {
                for x in 0..<SPRITE_W {
                    let offset = (y * full.width + i * SPRITE_W + x) * 4
                    let r = Int(bytes[offset]), g = Int(bytes[offset + 1])
                    let b = Int(bytes[offset + 2]), a = Int(bytes[offset + 3])
                    if a > 0, g >= 55, g * 5 > r * 6, g * 5 > b * 6 { eyeXs.append(x) }
                }
            }
            let eyeCenter = eyeXs.isEmpty ? nil
                : CGFloat(eyeXs.reduce(0, +)) / CGFloat(eyeXs.count)
            eyeAnchorsX.append(eyeCenter)
            let opaqueRows = (0..<SPRITE_H).filter { y in
                (0..<SPRITE_W).contains { x in mask[y * SPRITE_W + x] }
            }
            let contactY = opaqueRows.max() ?? (SPRITE_H - 1)
            footAnchorsY.append(CGFloat(contactY))

            // เงาควรตามเฉพาะรูปทรงที่เชื่อมถึงพื้น ไม่ตาม particle ที่ลอยอยู่
            // เช่น ก้อนความคิดและดาวของท่าตอบสำเร็จ จึง flood-fill จากแถวสัมผัสพื้น
            var grounded = [Bool](repeating: false, count: SPRITE_W * SPRITE_H)
            var queue: [Int] = []
            for x in 0..<SPRITE_W {
                let index = contactY * SPRITE_W + x
                if mask[index] {
                    grounded[index] = true
                    queue.append(index)
                }
            }
            var cursor = 0
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % SPRITE_W
                let y = index / SPRITE_W
                let neighbors = [
                    x > 0 ? index - 1 : -1,
                    x + 1 < SPRITE_W ? index + 1 : -1,
                    y > 0 ? index - SPRITE_W : -1,
                    y + 1 < SPRITE_H ? index + SPRITE_W : -1
                ]
                for next in neighbors where next >= 0 && mask[next] && !grounded[next] {
                    grounded[next] = true
                    queue.append(next)
                }
            }
            let groundedXs = grounded.enumerated().compactMap { index, connected in
                connected ? index % SPRITE_W : nil
            }
            let lo = groundedXs.min() ?? 0
            let hi = groundedXs.max() ?? (SPRITE_W - 1)
            spans.append((lo, hi))
        }

        // Anchor metadata ใช้ offset จำนวนเต็มเท่านั้นเพื่อคง nearest-neighbour และความคมของ pixel art
        anchorOffsetsX = [CGFloat](repeating: 0, count: frames.count)
        anchorOffsetsY = [CGFloat](repeating: 0, count: frames.count)
        for (index, offset) in FRAME_ANCHOR_OFFSETS where index < frames.count {
            anchorOffsetsX[index] = offset.x
            anchorOffsetsY[index] = offset.y
        }
    }
}
