// Views
// NSView ทั้งหมด: ตัวแมว, หัวใจ, พร็อพ และกรอบคำพูด

import Cocoa

// ─────────────────────────────────────────────────────────────
// The view: draws one frame, and is transparent to clicks
// everywhere the cat isn't.
// ─────────────────────────────────────────────────────────────
final class CatView: NSView {
    var image: CGImage?
    var mask: [Bool] = []
    var flip = false
    var span: (Int, Int) = (0, SPRITE_W - 1)
    var showShadow = true
    var motionX: CGFloat = 0
    var motionY: CGFloat = 0
    var motionHeight: CGFloat = 0
    var anchorX: CGFloat = 0
    var anchorY: CGFloat = 0
    var showTears = false
    weak var pet: PetController?

    private var dragOffset = NSPoint.zero
    private var startMouse = NSPoint.zero
    private var lastPt = NSPoint.zero
    private var strokeSum: CGFloat = 0
    private var petting = false

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL, .string])
        pet?.courierDropRegistrationChanged(true)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pet?.courierDragEntered()
        let pasteboard = sender.draggingPasteboard
        return pasteboard.canReadObject(forClasses: [NSURL.self, NSString.self]) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        pet?.courierDragExited()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        let text = pasteboard.string(forType: .string)
        return pet?.receiveCourierDrop(files: urls, text: text) ?? false
    }

    // ให้คลิกแรกถึงมือ view เลย ไม่ถูกกลืนไปกับการ activate แอป
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let u = bounds.width / CGFloat(SPRITE_W)          // 1 พิกเซลสไปรต์ = กี่ point
        // ชุดภาพเป็นพิกเซลอาร์ต: nearest-neighbor ทำให้เส้นขอบคมทั้งตอนย่อและขยาย
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        let shadowH = CGFloat(SHADOW_H) * u
        ctx.saveGState()
        if flip {
            ctx.translateBy(x: bounds.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        if showShadow {
            // เงาอิงความกว้างจริงของเฟรมนั้น ๆ นอนกว้าง นั่งแคบ
            let x0 = CGFloat(span.0) * u + anchorX * u
            let x1 = CGFloat(span.1 + 1) * u + anchorX * u
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.20).cgColor)
            ctx.fill(CGRect(x: x0 + u, y: u, width: max(0, x1 - x0 - 2 * u), height: u))
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.13).cgColor)
            ctx.fill(CGRect(x: x0 + 2 * u, y: 0, width: max(0, x1 - x0 - 4 * u), height: u))
        }
        // Secondary motion is expressed in source-pixel units. Keeping every
        // offset integral lets the nearest-neighbour renderer stay razor sharp.
        ctx.draw(img, in: CGRect(x: (anchorX + motionX) * u,
                                 y: shadowH + (anchorY + motionY) * u,
                                 width: bounds.width,
                                 height: bounds.height - shadowH + motionHeight * u))
        if showTears {
            // น้ำตาพิกเซลสำหรับท่านั่งเศร้า — วาดในพิกัด source เพื่อให้คมทุกสเกล
            let tearBlue = NSColor(srgbRed: 0.31, green: 0.72, blue: 0.91, alpha: 1).cgColor
            let shine = NSColor(srgbRed: 0.72, green: 0.92, blue: 1.0, alpha: 1).cgColor
            for tx in [49, 75] as [CGFloat] {
                ctx.setFillColor(tearBlue)
                ctx.fill(CGRect(x: (tx + anchorX + motionX) * u,
                                y: (shadowH / u + 39 + anchorY + motionY) * u,
                                width: 4 * u, height: 13 * u))
                ctx.setFillColor(shine)
                ctx.fill(CGRect(x: (tx + 1 + anchorX + motionX) * u,
                                y: (shadowH / u + 48 + anchorY + motionY) * u,
                                width: u, height: 3 * u))
            }
        }
        ctx.restoreGState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let parent = superview else { return nil }
        let p = convert(point, from: parent)
        guard bounds.contains(p), !mask.isEmpty else { return nil }
        let u = bounds.width / CGFloat(SPRITE_W)
        guard p.y >= CGFloat(SHADOW_H) * u else { return nil }   // แถบเงาคลิกทะลุได้
        var sx = Int(p.x / u)
        if flip { sx = SPRITE_W - 1 - sx }
        sx -= Int((anchorX + motionX).rounded())
        let sy = Int((bounds.height - p.y) / u + anchorY + motionY)
        guard sx >= 0, sx < SPRITE_W, sy >= 0, sy < SPRITE_H else { return nil }
        return mask[sy * SPRITE_W + sx] ? self : nil
    }

    private var downAt = Date()
    private var didGrab = false

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        let mouse = NSEvent.mouseLocation
        startMouse = mouse
        lastPt = mouse
        strokeSum = 0
        petting = false
        didGrab = false
        downAt = Date()
        dragOffset = NSPoint(x: mouse.x - win.frame.minX, y: mouse.y - win.frame.minY)
        if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
            FileHandle.standardError.write("MOUSEDOWN ที่ \(mouse)\n".data(using: .utf8)!)
        }
        // ยังไม่อุ้มทันที — รอดูว่าเป็นคลิกสั้น (เปิดเมนู) หรือกดค้าง (อุ้ม)
        DispatchQueue.main.asyncAfter(deadline: .now() + HOLD_DELAY) { [weak self] in
            guard let self, !self.didGrab, !self.petting else { return }
            guard NSEvent.pressedMouseButtons & 1 != 0 else { return }   // ปล่อยไปแล้ว
            let m = NSEvent.mouseLocation
            guard hypot(m.x - self.startMouse.x, m.y - self.startMouse.y) < 6 else { return }
            self.didGrab = true
            if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
                FileHandle.standardError.write("CLICK ค้าง -> อุ้ม\n".data(using: .utf8)!)
            }
            self.pet?.grab()
        }
    }

    /// เริ่มอุ้มทันทีถ้ายังไม่ได้อุ้ม — ใช้ตอนลากเร็วก่อนครบเวลากดค้าง
    private func grabIfNeeded() {
        guard !didGrab else { return }
        didGrab = true
        pet?.grab()
    }

    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        let fromStart = hypot(m.x - startMouse.x, m.y - startMouse.y)
        let step = hypot(m.x - lastPt.x, m.y - lastPt.y)
        lastPt = m

        if petting {
            if fromStart > 95 {                      // ลากออกไปไกล = เปลี่ยนเป็นอุ้ม
                petting = false
                pet?.stopPetting()
                didGrab = true
                pet?.grab()
                pet?.dragTo(x: m.x - dragOffset.x, y: m.y - dragOffset.y)
            } else {
                strokeSum += step
                if strokeSum > 26 { strokeSum = 0; pet?.petStroke() }
            }
            return
        }
        // ขยับไกลหรือเร็ว = อุ้ม / ขยับใกล้ ๆ ช้า ๆ = ลูบ
        if fromStart > 70 || step > 14 {
            grabIfNeeded()
            pet?.dragTo(x: m.x - dragOffset.x, y: m.y - dragOffset.y)
            return
        }
        strokeSum += step
        if strokeSum > 45 {
            strokeSum = 0
            petting = true
            pet?.startPetting()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let mm = NSEvent.mouseLocation
        if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
            let d = hypot(mm.x - startMouse.x, mm.y - startMouse.y)
            let dt = Date().timeIntervalSince(downAt)
            FileHandle.standardError.write(String(format:"MOUSEUP petting=%@ didGrab=%@ moved=%.1f dt=%.2f\n",
                "\(petting)","\(didGrab)",d,dt).data(using: .utf8)!)
        }
        if petting { petting = false; pet?.stopPetting(); return }
        if didGrab { pet?.release(); return }
        let m = NSEvent.mouseLocation
        let moved = hypot(m.x - startMouse.x, m.y - startMouse.y)
        if moved < 6 && Date().timeIntervalSince(downAt) < HOLD_DELAY + 0.15 {
            if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
                FileHandle.standardError.write("CLICK สั้น -> เปิดเมนู\n".data(using: .utf8)!)
            }
            if pet?.openContextRescueIfPresent() != true
                && pet?.openShepherdTargetIfPresent() != true {
                pet?.showQuickMenu()                  // คลิกสั้น ไม่ขยับ
            }
        } else {
            pet?.release()
        }
    }
}

/// หัวใจลอยตอนถูกลูบ — วาดเป็นพิกเซลล้วน
final class HeartsView: NSView {
    struct Heart {
        var x: CGFloat
        var y: CGFloat
        var vy: CGFloat
        var life: CGFloat
        var s: CGFloat
        var isStar: Bool = false
    }
    var hearts: [Heart] = []
    private static let rows = ["..#.#..", ".#####.", ".#####.", "..###..", "...#..."]
    private static let starRows = ["..#..", "#####", ".###.", "#####", "..#.."]
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(false)
        for h in hearts {
            let a = min(1, h.life / 0.35)
            let color = h.isStar
                ? NSColor(srgbRed: 1.0, green: 0.78, blue: 0.18, alpha: a)
                : NSColor(srgbRed: 0.886, green: 0.475, blue: 0.545, alpha: a)
            let rows = h.isStar ? HeartsView.starRows : HeartsView.rows
            ctx.setFillColor(color.cgColor)
            for (ry, row) in rows.enumerated() {
                for (rx, ch) in row.enumerated() where ch == "#" {
                    ctx.fill(CGRect(x: h.x + CGFloat(rx) * h.s,
                                    y: h.y + CGFloat(rows.count - 1 - ry) * h.s,
                                    width: h.s, height: h.s))
                }
            }
        }
    }
}

/// หน้าต่างเล็ก ๆ สำหรับของประกอบฉาก — เลือกรับคลิกตาม alpha mask ได้
final class PropView: NSView {
    var image: CGImage?
    var pixelMask: [Bool] = []
    var onClick: (() -> Void)? {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil, bounds.contains(point), pixelMask.count == SPRITE_W * SPRITE_H,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let sx = min(SPRITE_W - 1, max(0, Int(point.x / bounds.width * CGFloat(SPRITE_W))))
        let sy = min(SPRITE_H - 1, max(0, Int((bounds.height - point.y) / bounds.height * CGFloat(SPRITE_H))))
        return pixelMask[sy * SPRITE_W + sx] ? self : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        ctx.draw(img, in: bounds)
    }
}

// ─────────────────────────────────────────────────────────────
// กรอบคำพูด — หน้าต่างแยกอีกใบ ลอยเหนือหัวแมว คลิกทะลุได้
// ─────────────────────────────────────────────────────────────
let BUBBLE_FONT = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
let TAIL_H: CGFloat = 5

/// กรอบพิกเซลอาร์ตของอั่งเปา — ใช้ร่วมกันทั้งกล่องคำพูดและกล่องพิมพ์ จะได้เป็นภาษาเดียวกัน
enum PixelBubble {
    static let ink = NSColor(srgbRed: 0.169, green: 0.184, blue: 0.212, alpha: 1)   // #2b3036
    static let paper = NSColor(srgbRed: 0.949, green: 0.961, blue: 0.949, alpha: 1) // #f2f5f2

    /// แปดเหลี่ยม = สี่เหลี่ยมสองอันซ้อนกัน ให้มุมบิ่นแบบพิกเซลอาร์ต
    static func octagon(_ r: CGRect, cut: CGFloat) -> [CGRect] {
        [CGRect(x: r.minX, y: r.minY + cut, width: r.width, height: r.height - cut * 2),
         CGRect(x: r.minX + cut, y: r.minY, width: r.width - cut * 2, height: r.height)]
    }

    /// วาดตัวกรอบ + หางชี้ลงหาหัวแมว โดยเว้นพื้นที่หางไว้ด้านล่างเสมอ
    static func drawChrome(in ctx: CGContext, bounds: CGRect) {
        let w = bounds.width, bodyH = bounds.height - TAIL_H
        let body = CGRect(x: 0, y: TAIL_H, width: w, height: bodyH)
        let cx = (w / 2).rounded()
        ctx.setShouldAntialias(false)

        ctx.setFillColor(ink.cgColor)
        ctx.fill(octagon(body, cut: 3))
        for i in 0...Int(TAIL_H) - 1 {                       // หางชี้ลงหาหัวแมว
            let hw = CGFloat(1 + i)
            ctx.fill(CGRect(x: cx - hw, y: CGFloat(i), width: hw * 2, height: 1))
        }

        ctx.setFillColor(paper.cgColor)
        ctx.fill(octagon(body.insetBy(dx: 1.5, dy: 1.5), cut: 2.5))
        for i in 2...Int(TAIL_H) - 1 {
            let hw = CGFloat(i - 1)
            ctx.fill(CGRect(x: cx - hw, y: CGFloat(i), width: hw * 2, height: 1))
        }
        ctx.fill(CGRect(x: cx - 3, y: TAIL_H - 1, width: 6, height: 3))  // ลบรอยต่อหางกับกรอบ
        ctx.setShouldAntialias(true)
    }
}

enum SmartBubbleActionID: String {
    case open
    case summarize
    case helpFix
    case later
}

struct SmartBubbleAction: Equatable {
    let id: SmartBubbleActionID
    let title: String
}

final class BubbleView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var actions: [SmartBubbleAction] = [] {
        didSet {
            actionRects.removeAll()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    weak var pet: PetController?
    var interactive = false {
        didSet {
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    private let ink = PixelBubble.ink
    private var actionRects: [(SmartBubbleActionID, CGRect)] = []

    static func size(for text: String, actions: [SmartBubbleAction] = []) -> NSSize {
        let s = (text as NSString).size(withAttributes: [.font: BUBBLE_FONT])
        guard !actions.isEmpty else {
            return NSSize(width: ceil(s.width) + 22, height: ceil(s.height) + 12 + TAIL_H)
        }
        let buttonWidth = actions.reduce(CGFloat(0)) { total, action in
            total + ceil((action.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold)]).width) + 18
        } + CGFloat(max(0, actions.count - 1) * 6)
        return NSSize(width: max(ceil(s.width) + 22, buttonWidth + 16),
                      height: ceil(s.height) + 36 + TAIL_H)
    }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        if interactive { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let action = actionRects.first(where: { $0.1.contains(point) })?.0 {
            pet?.performSmartBubbleAction(action)
        } else {
            pet?.openBubbleTarget()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, bodyH = bounds.height - TAIL_H
        PixelBubble.drawChrome(in: ctx, bounds: bounds)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let hasActions = !actions.isEmpty
        (text as NSString).draw(
            in: CGRect(x: 5, y: TAIL_H + (hasActions ? 29 : 6),
                       width: w - 10, height: bodyH - (hasActions ? 34 : 12)),
            withAttributes: [.font: BUBBLE_FONT, .foregroundColor: ink, .paragraphStyle: para])
        guard hasActions else { actionRects.removeAll(); return }

        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let widths = actions.map {
            ceil(($0.title as NSString).size(withAttributes: [.font: font]).width) + 18
        }
        let total = widths.reduce(0, +) + CGFloat(max(0, actions.count - 1) * 6)
        var x = ((w - total) / 2).rounded()
        actionRects.removeAll(keepingCapacity: true)
        for (index, action) in actions.enumerated() {
            let rect = CGRect(x: x, y: TAIL_H + 5, width: widths[index], height: 18)
            actionRects.append((action.id, rect))
            ctx.setFillColor(ink.cgColor)
            ctx.fill(PixelBubble.octagon(rect, cut: 2))
            ctx.setFillColor(PixelBubble.paper.cgColor)
            ctx.fill(PixelBubble.octagon(rect.insetBy(dx: 1.5, dy: 1.5), cut: 1.5))
            let label = NSMutableParagraphStyle(); label.alignment = .center
            (action.title as NSString).draw(
                in: rect.insetBy(dx: 4, dy: 3),
                withAttributes: [.font: font, .foregroundColor: ink, .paragraphStyle: label])
            x += widths[index] + 6
        }
    }
}

/// ช่องพิมพ์ที่เป็นกรอบคำพูดของอั่งเปาเอง — กรอบพิกเซล หางชี้ลงหาหัวแมว เหมือนตอนน้องพูด
/// สมองอีกตัวของอั่งเปา — Claude Haiku 4.5
/// เลือกทางเชื่อมต่อเอง: มี ANTHROPIC_API_KEY ก็ยิง API ตรง (เร็วกว่า)
/// ไม่มีก็เรียก `claude -p` ที่กริชล็อกอินไว้แล้ว (ใช้ Claude Code subscription ไม่เสียเงินเพิ่ม)
