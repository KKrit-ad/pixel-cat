// ChatBubbleInput
// ช่องพิมพ์ข้อความเหนือหัวน้อง

import Cocoa

final class ChatBubbleInputView: NSView, NSTextFieldDelegate {
    let field = NSTextField(string: "")
    /// กรอบยืดตามข้อความเหมือนตอนน้องพูด ผู้เรียกรับไปจัดหน้าต่างใหม่ให้อยู่กลางหัวแมวเท่าเดิม
    var onWidthChange: ((CGFloat) -> Void)?

    static let minWidth: CGFloat = 200
    static let maxWidth: CGFloat = 460

    func setPlaceholder(_ text: String) {
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        field.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [.font: BUBBLE_FONT,
                         .paragraphStyle: centered,
                         .foregroundColor: PixelBubble.ink.withAlphaComponent(0.4)]
        )
    }

    /// กว้างพอดีข้อความ ใช้สูตรเดียวกับ BubbleView.size(for:)
    static func width(for text: String) -> CGFloat {
        let w = ceil((text as NSString).size(withAttributes: [.font: BUBBLE_FONT]).width) + 34
        return min(maxWidth, max(minWidth, w))
    }

    func controlTextDidChange(_ obj: Notification) {
        let wanted = Self.width(for: field.stringValue)
        guard abs(wanted - frame.width) >= 1 else { return }
        onWidthChange?(wanted)
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }

    /// กว้างตามที่ขอ สูงเท่ากรอบคำพูดบรรทัดเดียวเป๊ะ ๆ จะได้เด้งขึ้นมาที่เดิมกับตอนน้องพูด
    static func size(width: CGFloat) -> NSSize {
        NSSize(width: width, height: BubbleView.size(for: "อั่งเปา").height)
    }

    init(width: CGFloat, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(origin: .zero, size: Self.size(width: width)))
        field.font = BUBBLE_FONT
        field.textColor = PixelBubble.ink
        field.alignment = .center
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.target = target
        field.action = action
        field.delegate = self
        setPlaceholder("คุยกับอั่งเปา…")
        addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(TAIL_H + 6))
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        PixelBubble.drawChrome(in: ctx, bounds: bounds)
    }
}

let LINES: [String: [String]] = [
    "walk":    ["เหมียว~", "เดินเล่นก่อน", "ไปไหนดี", "หิวจัง", "มีอะไรกินมั้ย", "เมื่อยขา", "เมี๊ยววว"],
    "sit":     ["เหมียว", "นั่งดูทำงานอยู่", "ว่างจัง", "หิวแล้วนะ", "ลูบหน่อยสิ", "เล่นด้วยหน่อย"],
    "lick":    ["แปรงขนอยู่", "อย่ามอง", "สะอาดแล้ว", "เลียๆ"],
    "sleep":   ["Zzz…", "ฝันถึงปลาทู", "อย่าปลุกนะ", "zzZ"],
    "stretch": ["อ๊าาา~", "ยืดหน่อย", "ตื่นแล้ว"],
    "jump":    ["เหมียว!", "อ๊าว!", "ตกใจหมด", "จะทำอะไร!", "ปุ๊กปิ๊ก!"]
]
let NIGHT_LINES = ["ดึกแล้วนะ", "ไปนอนได้แล้ว", "ทำงานอีกแล้วเหรอ", "พักบ้างสิ"]
let DRAG_LINES = ["อุ๊ยยย", "ปล่อยเดี๋ยวนี้", "หวาดเสียว", "วืดดด"]

// ─────────────────────────────────────────────────────────────
// The pet itself
