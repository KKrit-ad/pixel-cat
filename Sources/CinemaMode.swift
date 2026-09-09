// CinemaMode
// กติกาซ่อนน้องเมื่อแอปด้านหน้าเต็มจอ โดยใช้เฉพาะ PID และขนาดหน้าต่าง
// ไม่อ่านชื่อหน้าต่างหรือภาพบนจอ จึงไม่ต้องขอ Screen Recording

import Foundation
import CoreGraphics

enum CinemaPreference: Int, CaseIterable {
    case automatic = 0
    case everyFullscreen = 1
    case never = 2

    var label: String {
        switch self {
        case .automatic: return "อัตโนมัติ"
        case .everyFullscreen: return "ซ่อนทุก Full Screen"
        case .never: return "ไม่ซ่อน"
        }
    }

    var detail: String {
        switch self {
        case .automatic: return "เฉพาะวิดีโอและเบราว์เซอร์"
        case .everyFullscreen: return "รวม IDE และ Terminal"
        case .never: return "อยู่ด้วยทุกพื้นที่"
        }
    }
}

struct CinemaWindow {
    let ownerPID: Int
    let bounds: CGRect
    let layer: Int
    let alpha: Double
}

enum CinemaModeDetector {
    private static let automaticBundleIDs: Set<String> = [
        // Browsers — ครอบคลุม YouTube, Netflix และเว็บวิดีโอโดยไม่ต้องอ่านข้อความบนจอ
        "com.apple.safari",
        "com.apple.safaritechnologypreview",
        "com.google.chrome",
        "com.google.chrome.canary",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "company.thebrowser.browser",             // Arc
        "com.brave.browser",
        "com.vivaldi.vivaldi",
        "com.operasoftware.opera",
        "com.kagi.kagimacos",                    // Orion
        // Players
        "com.colliderli.iina",
        "org.videolan.vlc",
        "com.apple.quicktimeplayerx",
        "com.apple.tv",
        "com.apple.music",
        "com.plexapp.plex",
        "tv.plex.desktop",
        "com.netflix.netflix"
    ]

    static func isAutomaticApp(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        if automaticBundleIDs.contains(id) { return true }
        // Chromium profiles/variants มักต่อ suffix จาก bundle id หลัก
        return id.hasPrefix("com.google.chrome.")
            || id.hasPrefix("com.microsoft.edgemac.")
            || id.hasPrefix("org.mozilla.firefox.")
            || id.hasPrefix("com.brave.browser.")
    }

    static func isFullscreen(_ bounds: CGRect, on screen: CGRect,
                             tolerance: CGFloat = 6) -> Bool {
        abs(bounds.minX - screen.minX) <= tolerance
            && abs(bounds.minY - screen.minY) <= tolerance
            && abs(bounds.maxX - screen.maxX) <= tolerance
            && abs(bounds.maxY - screen.maxY) <= tolerance
    }

    static func shouldHide(preference: CinemaPreference, bundleID: String,
                           frontmostPID: Int, screen: CGRect,
                           windows: [CinemaWindow]) -> Bool {
        guard preference != .never, frontmostPID > 0 else { return false }
        if preference == .automatic, !isAutomaticApp(bundleID) { return false }
        return windows.contains {
            $0.ownerPID == frontmostPID
                && $0.layer == 0
                && $0.alpha > 0.01
                && isFullscreen($0.bounds, on: screen)
        }
    }
}
