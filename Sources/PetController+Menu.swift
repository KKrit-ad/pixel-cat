// PetController+Menu
// เมนู 🐈 บนแถบเมนู
//
// แยกออกมาจาก PetController.swift เป็น extension ของคลาสเดิม

import Cocoa

extension PetController {

    // MARK: menu

    var reduceMotionEnabled: Bool {
        motionReductionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var effectiveMotionLevel: MotionLevel {
        reduceMotionEnabled ? .calm : motionLevel
    }

    func makeMotionMenu() -> NSMenu {
        let menu = NSMenu()
        for level in [MotionLevel.calm, .normal, .playful] {
            let detail: String
            switch level {
            case .calm: detail = "ขยับน้อย ไม่เด้งดีใจ"
            case .normal: detail = "สมดุล"
            case .playful: detail = "ท่าทางและหัวใจเพิ่ม"
            }
            let entry = NSMenuItem(title: "\(level.label) — \(detail)",
                                   action: #selector(setMotionLevel(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = 20 + level.rawValue
            entry.state = effectiveMotionLevel == level ? .on : .off
            menu.addItem(entry)
        }
        if reduceMotionEnabled {
            menu.addItem(.separator())
            let note = NSMenuItem(title: "macOS Reduce Motion กำลังบังคับโหมดสงบ",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        return menu
    }

    var cinemaMenuTitle: String {
        "Cinema Mode • \(cinemaPreference.label)"
    }

    func makeCinemaMenu() -> NSMenu {
        let menu = NSMenu()
        for preference in CinemaPreference.allCases {
            let entry = NSMenuItem(
                title: "\(preference.label) — \(preference.detail)",
                action: #selector(setCinemaPreference(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.tag = 60 + preference.rawValue
            entry.state = cinemaPreference == preference ? .on : .off
            menu.addItem(entry)
        }
        return menu
    }

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐈"

        let menu = NSMenu()
        let focus = item("เริ่มโฟกัส 25 นาที", #selector(toggleFocus), tag: 4)
        focusMenuItem = focus
        menu.addItem(focus)
        let work = NSMenuItem(title: workInboxTitle, action: nil, keyEquivalent: "")
        workInboxItem = work
        work.submenu = makeWorkInboxMenu()
        menu.addItem(work)
        menu.addItem(.separator())
        menu.addItem(item("ตามเมาส์", #selector(toggleFollow), tag: 0))
        menu.addItem(item("โยนลูกบอล", #selector(throwBall)))
        menu.addItem(item("ให้นอน", #selector(napNow)))
        menu.addItem(item("ปลุก / ยืดตัว", #selector(wakeNow)))
        menu.addItem(item("เรียกมาหาเมาส์", #selector(comeHere)))
        menu.addItem(item("ทดลองพิธีต้อนรับ", #selector(demoReturnRitual)))
        menu.addItem(.separator())

        let sizeItem = NSMenuItem(title: "ขนาด", action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (label, value) in [("0.5× จิ๋วสุด", 5), ("0.7× เล็ก", 7), ("0.9× ปกติ", 9),
                               ("1.2× กลาง", 12), ("1.5× ใหญ่", 15), ("2× ใหญ่มาก", 20)] {
            let mi = NSMenuItem(title: label, action: #selector(setSize(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = value
            mi.state = (CGFloat(value) / 10 == scale) ? .on : .off
            sizes.addItem(mi)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)
        let motionItem = NSMenuItem(title: "ความซน • \(effectiveMotionLevel.label)",
                                    action: nil, keyEquivalent: "")
        motionMenuItem = motionItem
        motionItem.submenu = makeMotionMenu()
        menu.addItem(motionItem)
        let cinemaItem = NSMenuItem(title: cinemaMenuTitle, action: nil, keyEquivalent: "")
        cinemaMenuItem = cinemaItem
        cinemaItem.submenu = makeCinemaMenu()
        menu.addItem(cinemaItem)
        menu.addItem(makeCompanionMenuItem())
        deliveryMenuItem = makeDeliveryMenuItem()
        menu.addItem(deliveryMenuItem!)
        fileSearchMenuItem = makeFileSearchMenuItem()
        menu.addItem(fileSearchMenuItem!)
        rescueHistoryItem = makeRescueHistoryMenu()
        menu.addItem(rescueHistoryItem!)
        menu.addItem(item("พูดได้", #selector(toggleSpeech), tag: 3))
        menu.addItem(item("ลอยเหนือทุกหน้าต่าง", #selector(toggleOnTop), tag: 2))
        menu.addItem(item("หยุดนิ่ง", #selector(togglePause), tag: 1))
        menu.addItem(.separator())
        menu.addItem(item("ออก", #selector(quit)))
        statusItem.menu = menu
    }

    /// เมนูลัดที่เด้งข้างตัวน้องเมื่อคลิกสั้น ๆ
    func showQuickMenu() {
        let m = NSMenu()
        m.addItem(item(focusActionTitle, #selector(toggleFocus)))
        let work = NSMenuItem(title: workInboxTitle, action: nil, keyEquivalent: "")
        work.submenu = makeWorkInboxMenu()
        m.addItem(work)
        m.addItem(.separator())
        m.addItem(item("โยนลูกบอล", #selector(throwBall)))
        m.addItem(item("ให้นอน", #selector(napNow)))
        m.addItem(item("ปลุก / ยืดตัว", #selector(wakeNow)))
        m.addItem(item("เรียกมาหาเมาส์", #selector(comeHere)))
        m.addItem(item("ทดลองพิธีต้อนรับ", #selector(demoReturnRitual)))
        m.addItem(.separator())
        let f = item("ตามเมาส์", #selector(toggleFollow)); f.state = follow ? .on : .off
        m.addItem(f)
        let sp = item("พูดได้", #selector(toggleSpeech)); sp.state = speechOn ? .on : .off
        m.addItem(sp)
        let voice = item("เสียงเหมียว", #selector(toggleVoice))
        voice.state = CatVoice.shared.enabled ? .on : .off
        m.addItem(voice)
        let motion = NSMenuItem(title: "ความซน • \(effectiveMotionLevel.label)",
                                action: nil, keyEquivalent: "")
        motion.submenu = makeMotionMenu()
        m.addItem(motion)
        let cinema = NSMenuItem(title: cinemaMenuTitle, action: nil, keyEquivalent: "")
        cinema.submenu = makeCinemaMenu()
        m.addItem(cinema)
        m.addItem(makeCompanionMenuItem())
        m.addItem(makeDeliveryMenuItem())
        m.addItem(makeFileSearchMenuItem())

        // เด้งข้างตัวน้อง ถ้าชิดขอบขวาจอให้ไปโผล่ทางซ้ายแทน
        let f0 = window.frame
        let screenMaxX = window.screen?.visibleFrame.maxX ?? f0.maxX
        let onRight = f0.maxX + 190 < screenMaxX
        let at = NSPoint(x: onRight ? f0.maxX + 4 : f0.minX - 4, y: f0.maxY)
        m.popUp(positioning: nil, at: at, in: nil)
    }
}
