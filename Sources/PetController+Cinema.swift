// PetController+Cinema
// Cinema Mode — ซ่อนน้องเมื่อแอปด้านหน้าเต็มจอ
//
// แยกออกมาจาก PetController.swift เป็น extension ของคลาสเดิม

import Cocoa

extension PetController {

    // MARK: Cinema Mode

    /// หน้าต่างทุกชิ้นที่เป็นส่วนหนึ่งของน้อง — status item ไม่รวม เพื่อให้เปลี่ยนโหมดกลับได้
    func companionWindows() -> [NSWindow] {
        var windows = [window, bubbleWindow, heartWindow, ballWindow, geckoWindow]
        if let chatWindow { windows.append(chatWindow) }
        return windows
    }

    /// ระหว่างดูหนัง โค้ดส่วนอื่นอาจพยายามเปิด bubble/พร็อพขึ้นมาใหม่
    /// เก็บหน้าต่างใหม่นั้นไว้ด้วย แล้วซ่อนทันทีเพื่อกลับมาได้ครบหลังออก Full Screen
    func enforceCinemaHidden() {
        guard cinemaHidden else { return }
        for w in companionWindows() where w.isVisible {
            if !cinemaRestoreWindows.contains(where: { $0.window === w }) {
                cinemaRestoreWindows.append((w, w.alphaValue))
            }
            w.orderOut(nil)
        }
    }

    func setCinemaHidden(_ hidden: Bool) {
        guard hidden != cinemaHidden else {
            if hidden { enforceCinemaHidden() }
            return
        }
        if hidden {
            cinemaHidden = true
            cinemaRestoreWindows = companionWindows().filter(\.isVisible).map { ($0, $0.alphaValue) }
            enforceCinemaHidden()
            return
        }

        cinemaHidden = false
        let restore = cinemaRestoreWindows
        cinemaRestoreWindows.removeAll()
        guard !restore.isEmpty else { return }

        if reduceMotionEnabled || effectiveMotionLevel == .calm {
            for item in restore {
                item.window.alphaValue = item.alpha
                item.window.orderFrontRegardless()
            }
            return
        }

        for item in restore {
            item.window.alphaValue = 0
            item.window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for item in restore { item.window.animator().alphaValue = item.alpha }
        }
    }

    /// แปลงพิกัด Window Server (ต้นกำเนิดบนซ้าย) เป็น AppKit (ล่างซ้าย)
    /// อ่านแค่ PID/layer/alpha/bounds จึงไม่ต้องมี Screen Recording permission
    func cinemaWindowsOnScreen() -> [CinemaWindow] {
        let flip = NSScreen.screens.first?.frame.maxY ?? 900
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return list.compactMap { item in
            guard let owner = (item[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                  let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let raw = item[kCGWindowBounds as String] as? [String: Any],
                  let x = (raw["X"] as? NSNumber)?.doubleValue,
                  let y = (raw["Y"] as? NSNumber)?.doubleValue,
                  let width = (raw["Width"] as? NSNumber)?.doubleValue,
                  let height = (raw["Height"] as? NSNumber)?.doubleValue,
                  width > 0, height > 0 else { return nil }
            let bounds = CGRect(x: CGFloat(x), y: flip - CGFloat(y + height),
                                width: CGFloat(width), height: CGFloat(height))
            let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return CinemaWindow(ownerPID: owner, bounds: bounds, layer: layer, alpha: alpha)
        }
    }

    func cinemaShouldHideNow() -> Bool {
        guard cinemaPreference != .never,
              let app = NSWorkspace.shared.frontmostApplication else { return false }
        let screen = window.screen?.frame ?? currentScreen().frame
        return CinemaModeDetector.shouldHide(
            preference: cinemaPreference,
            bundleID: app.bundleIdentifier ?? "",
            frontmostPID: Int(app.processIdentifier),
            screen: screen,
            windows: cinemaWindowsOnScreen()
        )
    }

    /// debounce สองรอบ ป้องกันน้องกะพริบหายระหว่าง animation เข้า/ออก Full Screen
    func pollCinemaMode(_ dt: Double, force: Bool = false) {
        cinemaPoll -= dt
        guard force || cinemaPoll <= 0 else { return }
        cinemaPoll = 0.35
        let desired = cinemaShouldHideNow()
        if cinemaCandidate == desired {
            cinemaCandidateCount += 1
        } else {
            cinemaCandidate = desired
            cinemaCandidateCount = 1
        }
        guard force || cinemaCandidateCount >= 2 else { return }
        setCinemaHidden(desired)
    }
}
