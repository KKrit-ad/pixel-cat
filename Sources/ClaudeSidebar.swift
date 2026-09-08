// ClaudeSidebar
// พาไปห้องสนทนาที่เปิดอยู่ในแอป Claude โดยกดแถวใน sidebar ให้เอง
//
// ทางที่ถูกต้องคือ deep link claude://code/continue แต่แอปปิดเส้นทางนั้นไว้ด้วย
// feature gate ฝั่งบัญชี (log: "code entry deep link gated off") ซึ่งเราเปิดเองไม่ได้
// ไฟล์นี้จึงเป็นทางสำรอง: อ่านโครงหน้าตาแอปผ่าน Accessibility แล้วกดแถวให้
// เพราะพึ่งโครงหน้าตาที่แอปเปลี่ยนเมื่อไหร่ก็ได้ ทุกขั้นจึงยอมล้มเหลวเงียบ ๆ
// แล้วให้ผู้เรียกถอยไปดึงแอปขึ้นหน้าแทน

import Cocoa
import ApplicationServices

enum ClaudeSidebar {
    static let bundleID = "com.anthropic.claudefordesktop"

    /// แอป Claude ที่รันอยู่ หาโดยไม่พึ่ง pid ที่ hook บันทึกไว้ ซึ่งค้างง่ายเมื่อแอปถูกเปิดใหม่
    static func runningApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.activationPolicy == .regular }
    }

    /// เลือกแถวที่ตรงที่สุดจากรายชื่อปุ่มใน sidebar ตามลำดับที่เห็นบนจอ
    ///
    /// โครงของ sidebar คือ หัวข้อโฟลเดอร์หนึ่งปุ่ม ตามด้วย "New session in <ชื่อโฟลเดอร์>"
    /// แล้วจึงเป็นแถวห้องของโฟลเดอร์นั้น ส่วนชื่อแถวมีสถานะนำหน้า เช่น "Idle แก้บั๊ก"
    /// แยกออกมาเป็นฟังก์ชันบริสุทธิ์เพื่อให้ตรวจกติกาการจับคู่ได้โดยไม่ต้องมีแอปจริง
    static func rowIndex(labels: [String], project: String, topic: String) -> Int? {
        let wanted = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        var folder = ""
        var inProject: Int?
        var anywhere: Int?
        for (i, label) in labels.enumerated() {
            if i + 1 < labels.count, labels[i + 1] == "New session in \(label)" {
                folder = label
                continue
            }
            if label.hasPrefix("New session in ") { continue }
            guard label == wanted || label.hasSuffix(" " + wanted) else { continue }
            if folder == project, inProject == nil { inProject = i }
            if anywhere == nil { anywhere = i }
        }
        return inProject ?? anywhere
    }

    /// กดแถวของห้องนั้นให้ คืน false เมื่อทำไม่ได้ ผู้เรียกต้องมีทางถอยเสมอ
    @discardableResult
    static func focusSession(topic: String, project: String) -> Bool {
        guard AXIsProcessTrusted(), let app = runningApp() else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium ไม่เปิด accessibility tree จนกว่าจะมีคนขอ ไม่ตั้งค่านี้จะได้ต้นไม้เปล่า
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var buttons = collectButtons(element)
        // sidebar หุบอยู่ก็ไม่มีแถวให้กด กางก่อนแล้วค่อยอ่านใหม่
        if let toggle = buttons.first(where: { $0.label == "Show sidebar" })?.element {
            AXUIElementPerformAction(toggle, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.45)
            buttons = collectButtons(element)
        }
        guard let index = rowIndex(labels: buttons.map(\.label),
                                   project: project, topic: topic) else { return false }
        app.activate()
        return AXUIElementPerformAction(buttons[index].element,
                                        kAXPressAction as CFString) == .success
    }

    private static func collectButtons(
        _ app: AXUIElement
    ) -> [(element: AXUIElement, label: String)] {
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        var found: [(AXUIElement, String)] = []
        var visited = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            // กันต้นไม้ลึกหรือใหญ่ผิดปกติ ไม่ให้ค้างอยู่บน main thread
            guard depth <= 45, visited < 6000 else { return }
            visited += 1
            if string(el, kAXRoleAttribute as String) == "AXButton" {
                let label = [string(el, kAXTitleAttribute as String),
                             string(el, kAXDescriptionAttribute as String)]
                    .compactMap { $0 }.first { !$0.isEmpty }
                if let label { found.append((el, label)) }
            }
            var kids: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
            for kid in (kids as? [AXUIElement]) ?? [] { walk(kid, depth + 1) }
        }
        for window in (windows as? [AXUIElement]) ?? [] { walk(window, 0) }
        return found
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
