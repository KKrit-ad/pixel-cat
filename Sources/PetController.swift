// PetController
// หัวใจของแอป: สถานะ, แอนิเมชัน, เมนู, กล่องงาน และการโต้ตอบทั้งหมด

import Cocoa
import Carbon
import SQLite3

// ─────────────────────────────────────────────────────────────
final class PetController: NSObject {
    private enum FocusPhase { case idle, focus, rest }
    private enum MotionLevel: Int {
        case calm = 0, normal = 1, playful = 2

        var label: String {
            switch self {
            case .calm: return "สงบ"
            case .normal: return "ปกติ"
            case .playful: return "ซน"
            }
        }
    }
    private enum WorkNoticeKind: Equatable { case done, batchDone, input, failed, returned }
    private struct WorkSession {
        let source: String          // claude หรือ codex — ใช้แบ่ง section และสร้าง deep link
        let id: String
        let state: String
        let name: String
        let cwd: String
        let message: String
        let updatedAt: Double
        let contextPercent: Double
        let focusURL: String        // warp://session/... ถ้าเทอร์มินัลให้มา
        let appPIDs: [Int]          // สายโปรเซสแม่ — หาแอป GUI ตัวแรกที่สั่งได้
        let sessionID: String       // ใช้ทำ claude://resume?session=... เข้าห้องนั้นตรง ๆ
        let topic: String           // หัวข้อห้องสนทนา — Claude ตั้งชื่อให้เอง
        var activity: WorkActivitySignal = .idle
        var pid: Int = 0            // โปรเซส Claude/Codex ตัวจริง — ตายแล้วห้องนี้ก็ไม่นับ
        var startedAt: Double = 0   // เวลาที่ห้องเริ่ม ใช้บอกว่าห้องไหนเปิดทีหลัง
        var recentFiles: [String] = []  // ไฟล์ที่ห้องนั้นแก้ล่าสุด
        var lastRequest: String = ""    // คำสั่งล่าสุดของพ่อในห้องนั้น
    }
    private struct WorkNotice {
        let session: WorkSession
        let kind: WorkNoticeKind
        let text: String
    }
    private struct CourierPayload {
        let files: [URL]
        let text: String

        var label: String {
            if files.count == 1 { return files[0].lastPathComponent }
            if files.count > 1 { return "\(files.count) ไฟล์" }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 24 ? String(trimmed.prefix(22)) + "…" : trimmed
        }

        var pasteboardText: String {
            if !files.isEmpty { return files.map(\.path).joined(separator: "\n") }
            return text
        }
    }
    private struct ContextRescue {
        let session: WorkSession
        let handoff: String
        let launchURL: URL
    }
    /// handoff ที่เคยเสนอ เก็บลงดิสก์ไว้ให้กดย้อนหลังได้ กรณีกริชปล่อยกรอบให้หายไปเฉย ๆ
    struct SavedRescue {
        let title: String       // ชื่อที่โชว์ในเมนู
        let urlString: String   // deep link เดิม พร้อม handoff ที่แพ็คไว้แล้ว
        let handoff: String     // ข้อความ handoff ไว้วาง pasteboard เหมือนตอนกดสด ๆ
        let savedAt: Date

        var dictionary: [String: Any] {
            ["title": title, "url": urlString, "handoff": handoff,
             "savedAt": savedAt.timeIntervalSince1970]
        }

        init(title: String, urlString: String, handoff: String, savedAt: Date) {
            self.title = title; self.urlString = urlString
            self.handoff = handoff; self.savedAt = savedAt
        }

        init?(dictionary: [String: Any]) {
            guard let title = dictionary["title"] as? String,
                  let urlString = dictionary["url"] as? String,
                  let stamp = dictionary["savedAt"] as? Double else { return nil }
            self.init(title: title, urlString: urlString,
                      handoff: dictionary["handoff"] as? String ?? "",
                      savedAt: Date(timeIntervalSince1970: stamp))
        }

        /// "เมื่อ 2 ชม.ที่แล้ว" อ่านง่ายกว่าเวลาเต็มในเมนู
        var ageText: String {
            let mins = Int(Date().timeIntervalSince(savedAt) / 60)
            if mins < 1 { return "เมื่อครู่" }
            if mins < 60 { return "\(mins) นาทีที่แล้ว" }
            let hours = mins / 60
            if hours < 24 { return "\(hours) ชม.ที่แล้ว" }
            return "\(hours / 24) วันที่แล้ว"
        }
    }

    private struct DeferredClaudeEvent {
        let event: String
        let message: String
    }

    // Local observer/rule-engine state. The provider seam can be added later.
    private var companionMode: CompanionMode = {
        let raw = UserDefaults.standard.object(forKey: "companionMode") as? Int
        return CompanionMode(rawValue: raw ?? CompanionMode.quietWatch.rawValue) ?? .quietWatch
    }()
    private var companionPoll = 2.0
    private var companionCooldown = 0.0
    private var companionLastApp = ""
    private var companionRecentEvent = ""
    private var companionMemory = CompanionMemory.load()
    private var companionBrain: CompanionBrain = {
        let raw = UserDefaults.standard.object(forKey: "companionBrain") as? Int
        return CompanionBrain(rawValue: raw ?? CompanionBrain.claude.rawValue) ?? .claude
    }()
    private lazy var manusCompanion: CompanionProvider? = ManusCompanionProvider()
    private lazy var claudeCompanion: CompanionProvider? = ClaudeCompanionProvider()

    /// provider ที่ใช้อยู่จริง — nil แปลว่าตกไป local
    private var activeCompanion: CompanionProvider? {
        switch companionBrain {
        case .localOnly: return nil
        case .claude: return claudeCompanion
        // Manus ต้องใช้ key; ถ้ายังไม่ได้ตั้งให้ลอง Claude ที่ล็อกอินไว้ก่อน
        // เพื่อไม่ให้การสลับเมนูทำให้น้องกลายเป็น local แบบเงียบ ๆ
        case .manus: return manusCompanion ?? claudeCompanion
        }
    }
    private var companionRequestInFlight = false
    private var companionConnectionStatus = "ยังไม่ได้เรียก"

    private let window: NSWindow
    private let view = CatView()
    private var chatWindow: NSWindow?
    private var chatTranscript: NSTextView?
    private var chatInput: NSTextField?
    private var chatSendButton: NSButton?
    private var chatBusy = false
    private var thinkingCycle = CompanionThinkingCycle()
    private var lastThinkingMessage = ""
    private var companionReplyProtected = false
    private var fileFinder = LocalFileFinder()
    private var fileSearchResults: [URL] = []
    private var fileSearchTarget: URL?
    private var fileSearchMenuItem: NSMenuItem?
    private var lastSimulatedRevealPath = ""
    private var lastFileSearchStayedLocal = false
    private var currentWorkActivitySignature = ""
    private var seenWorkActivitySignatures: Set<String> = []
    private var activeWorkActivityKind: WorkActivityKind = .idle
    private var codexActivityCache: [String: (modified: Date, size: UInt64,
                                               signal: WorkActivitySignal)] = [:]
    private let bubbleWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 30),
                                        styleMask: .borderless, backing: .buffered, defer: false)
    private let bubbleView = BubbleView()
    private var speakFor = 0.0
    private var chatIn = Double.random(in: 6...14)
    private var speechOn = UserDefaults.standard.object(forKey: "speechOn") as? Bool ?? true
    private var statusItem: NSStatusItem!
    private var focusMenuItem: NSMenuItem?
    private var workInboxItem: NSMenuItem?
    private var motionMenuItem: NSMenuItem?
    private var timer: Timer?
    private static let companionHotKeySignature: OSType = 0x50434154 // "PCAT"
    private var companionHotKeyRef: EventHotKeyRef?
    private var companionHotKeyHandler: EventHandlerRef?
    private var companionHotKeyRegistered = false
    private var focusPhase: FocusPhase = .idle
    private var focusRemaining = 0.0
    private var focusDisplaySecond = -1
    private var motionLevel: MotionLevel = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "motionLevel") != nil else { return .normal }
        return MotionLevel(rawValue: defaults.integer(forKey: "motionLevel")) ?? .normal
    }()
    private var motionReductionOverride: Bool?       // ใช้เฉพาะ simulation; ปกติอ่านจาก macOS

    // เก็บเป็นหน่วยสิบเท่า (25 = 2.5x) จะได้เลือกครึ่งขั้นได้
    private var scale: CGFloat = {
        let d = UserDefaults.standard
        // คีย์ใหม่: atlas 128x100 ใช้สเกล 0.9 เพื่อคงขนาดบนจอใกล้เวอร์ชัน 64x50 ที่ 1.8x
        var tenths = d.integer(forKey: "catScaleTenths128")
        if tenths == 0 { tenths = 9 }
        return CGFloat(min(max(tenths, 5), 20)) / 10
    }()
    private var inboxStamp: Date?
    private var inboxPoll = 0.0
    private var deferredClaudeEvents: [DeferredClaudeEvent] = []
    private var sessPoll = 0.0
    private var sessSummary = ""
    private var workSessions: [WorkSession] = []
    private var workMenuSignature = ""
    private var workAlertCount = 0
    private var workActiveCount = 0
    private var acknowledgedWorkKeys: Set<String> = []
    private var waitingReminderSent: Set<String> = []
    private var snoozedWorkUntil: [String: Double] = [:]
    private var watchedLongWorkKeys: Set<String> = []
    private var previousSessionStates: [String: String] = [:]
    private var didSeedSessionStates = false
    private var workNoticeQueue: [WorkNotice] = []
    private var activeWorkNotice: WorkNotice?
    private var bubbleTarget: WorkSession?
    private var returnRitualTracker = ReturnRitualTracker()
    private var pendingReturnRitual: ReturnRitualSummary?
    private var lastSimulatedActionPrompt = ""
    private var noticeMotionFor = 0.0
    private var emotionKind: WorkNoticeKind?
    private var ctxWarned = 0.0        // เตือน context ไปแล้วที่กี่ % จะได้ไม่เตือนซ้ำ          // สถานะรวมล่าสุด ใช้กันพูดซ้ำ
    private var checkIn = 20.0          // รันสคริปต์ตรวจครั้งแรกหลังเปิด 20 วิ
    private var activeStreak = 0.0      // นั่งทำงานต่อเนื่องมากี่วินาที
    private var breakNudged = false
    private var state = "walk"
    private var frameIdx = 0
    private var frameTime = 0.0
    private var stateTime = 0.0
    private var landingMotion = 0.0
    private var afterState: (() -> Void)?

    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var vy: CGFloat = 0
    private var dir: CGFloat = 1
    private var target: CGFloat?

    private var follow = false
    private var held = false
    private var paused = false
    private var didDrag = false
    private var vx: CGFloat = 0
    private var airborne = false
    private var landAction: (() -> Void)?
    private var platforms: [Platform] = []
    private var plat = Platform(y: 0, minX: 0, maxX: 200, isFloor: true)
    private var platRefresh = 0.0
    private var lastMouse = NSEvent.mouseLocation
    private var mouseSpeed: CGFloat = 0
    private var pounceCool = 6.0
    private var pounceTarget: CGFloat?
    private var hurry = false
    private var shepherdTarget: WorkSession?
    private var simulatedShepherdRect: CGRect?
    private var pendingCourierPayload: CourierPayload?
    private var courierChoices: [String: WorkSession] = [:]
    private var courierDropRegistered = false
    private var lastSimulatedOpenURL = ""
    private var contextRescueOffered: Set<String> = []
    private static let rescueHistoryKey = "pixelcat.rescueHistory"
    private static let rescueHistoryLimit = 8
    private var rescueHistoryItem: NSMenuItem?
    private var rescueHistory: [SavedRescue] = {
        let raw = UserDefaults.standard.array(forKey: "pixelcat.rescueHistory") as? [[String: Any]] ?? []
        return raw.compactMap(SavedRescue.init(dictionary:))
    }()
    private var activeContextRescue: ContextRescue?
    private var lastSimulatedNewTaskURL = ""
    private var lastSimulatedHandoff = ""
    private var codexContextCache: [String: (modified: Date, size: UInt64, percent: Double)] = [:]
    private var autoDescending = false
    private var climbing = false
    private var climbGoal = Platform(y: 0, minX: 0, maxX: 0, isFloor: false)
    private var climbSideLeft = true
    private var napForced = false
    private var walkTime = 0.0
    private var zoomies = 0
    private var petting = false
    private var purrCount = 0
    private var hearts: [HeartsView.Heart] = []
    private let heartWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 90, height: 90),
                                       styleMask: .borderless, backing: .buffered, defer: false)
    private let heartsView = HeartsView()
    private let ballWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 55),
                                      styleMask: .borderless, backing: .buffered, defer: false)
    private let ballView = PropView()
    private var ballOn = false
    private var bx: CGFloat = 0, by: CGFloat = 0, bvx: CGFloat = 0, bvy: CGFloat = 0
    private var ballSpin = 0.0, ballLife = 0.0, ballHits = 0
    private var ballRest: CGFloat?
    private let geckoWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 55),
                                       styleMask: .borderless, backing: .buffered, defer: false)
    private let geckoView = PropView()
    private var geckoOn = false
    private var gx: CGFloat = 0, gy: CGFloat = 0, gdir: CGFloat = 1
    private var geckoPlat: Platform?
    private var geckoLife = 0.0, geckoWait = 0.0, geckoFrame = 0.0
    private var geckoIn = Double.random(in: 20...50)
    private var blinking = false
    private var blinkIn = Double.random(in: 2.0...5.0)
    private var blinkFor = 0.0
    private var blinkAgain = false

    private var spriteW: CGFloat { CGFloat(SPRITE_W) * scale }
    private var winH: CGFloat { CGFloat(SPRITE_H + SHADOW_H) * scale }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 110),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        super.init()

        view.pet = self
        window.contentView = view
        window.orderFrontRegardless()

        refreshPlatforms()
        let screen = currentScreen()
        plat = platforms.first(where: { $0.isFloor }) ?? platforms[0]
        x = screen.visibleFrame.midX
        y = plat.y
        target = screen.visibleFrame.midX + 200

        setupBubble()
        setupProp(ballWindow, ballView)
        setupProp(heartWindow, heartsView)
        setupProp(geckoWindow, geckoView)
        geckoWindow.ignoresMouseEvents = false
        geckoView.onClick = { [weak self] in self?.dismissGeckoByClick() }
        buildMenu()
        registerCompanionHotKey()
        syncMenu()
        applyFrame()

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMVOICE"] != nil {
            let voice = CatVoice.shared
            // ครบทุกเสียงและถอด base64 ออกมาเป็น WAV ได้จริง
            var decoded = 0
            for kind in CatSound.allCases {
                guard let b64 = CAT_VOICE_WAV[kind.rawValue],
                      let data = Data(base64Encoded: b64),
                      data.count > 2000,
                      data.prefix(4) == Data("RIFF".utf8),
                      data.dropFirst(8).prefix(4) == Data("WAVE".utf8) else { continue }
                decoded += 1
            }
            let assets = decoded == CatSound.allCases.count

            voice.enabled = true
            voice.muted = false
            let first = voice.play(.mew, minGap: 5.0)
            let throttled = !voice.play(.mew, minGap: 5.0)        // เสียงเดิมรัว ๆ ต้องถูกกัน
            let other = !voice.play(.trill, minGap: 0, gapAny: 0.6) // เสียงอื่นก็ต้องเว้นจังหวะ
            voice.muted = true
            let mutedQuiet = !voice.play(.purr, minGap: 0, gapAny: 0)
            voice.muted = false
            voice.enabled = false
            let offQuiet = !voice.play(.purr, minGap: 0, gapAny: 0)
            voice.enabled = true
            let log = voice.playLog == ["mew"]

            // เปิดโฟกัสแล้วต้องเงียบเองโดยไม่ต้องสั่ง
            self.focusPhase = .focus
            self.focusRemaining = 100
            self.tickForTests(0.016)
            let focusMutes = voice.muted
            self.focusPhase = .idle
            self.focusRemaining = 0
            self.tickForTests(0.016)
            let focusRestores = !voice.muted

            // งาน AI เสร็จต้องมีเสียงเบา ๆ หนึ่งครั้ง และงานถัดไปที่เสร็จไล่กันต้องไม่ดังซ้ำ
            // เดินผ่านทางเดียวกับของจริง (สถานะเปลี่ยน → แจ้งเตือน → ภาษากาย) ไม่เรียกลัด
            voice.resetThrottleForTests()
            self.speechOn = true
            self.focusPhase = .idle
            self.didSeedSessionStates = true
            let doneID = "voice-done"
            func room(_ id: String, _ state: String) -> WorkSession {
                WorkSession(source: "claude", id: id, state: state, name: "pixel-cat",
                            cwd: "/tmp", message: "", updatedAt: Date().timeIntervalSince1970,
                            contextPercent: 10, focusURL: "", appPIDs: [], sessionID: id,
                            topic: "งานเสร็จ")
            }
            self.previousSessionStates = ["claude:\(doneID)": "working"]
            self.detectWorkNotices([room(doneID, "idle")])
            let doneChimed = voice.playLog == ["trill"]
            self.activeWorkNotice = nil
            self.previousSessionStates = ["claude:second-done": "working"]
            self.detectWorkNotices([room("second-done", "idle")])
            let doneQuietRepeat = voice.playLog == ["trill"]
            self.activeWorkNotice = nil
            self.previousSessionStates = ["claude:asking": "working"]
            self.detectWorkNotices([room("asking", "input")])
            let waitingSilent = voice.playLog == ["trill"]
            let doneVoice = doneChimed && doneQuietRepeat && waitingSilent

            let ok = assets && first && throttled && other && mutedQuiet
                && offQuiet && log && focusMutes && focusRestores && doneVoice
            FileHandle.standardError.write(
                ("SIM VOICE assets=\(assets) play=\(first) throttle=\(throttled && other) "
                + "mute=\(mutedQuiet) off=\(offQuiet) log=\(log) "
                + "focus=\(focusMutes && focusRestores) done=\(doneVoice)\n").data(using: .utf8)!
            )
            NSApp.terminate(nil)
            if !ok { exit(2) }
            return
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMOPENROUTE"] != nil {
            // ห้องที่ยังเปิดอยู่ต้องสลับไปหาแอป ไม่ใช่ resume ซึ่งจะได้ห้องซ้ำชื่อเดิม
            // ต้องใช้แอป GUI จริงสักตัว เพราะ PixelCat เองเป็นแอปเมนูบาร์ที่โฟกัสไม่ได้
            let mine = NSWorkspace.shared.runningApplications
                .first { $0.activationPolicy == .regular }
                .map { [Int($0.processIdentifier)] } ?? []
            let sid = "0a1b2c3d-4e5f-6789-abcd-ef0123456789"
            let claude = self.openRoute(focus: "", path: "/tmp", pids: mine, sessionID: sid)
            // ต้องเป็นลิงก์ที่ไปห้องเดิม ไม่ใช่ resume ที่สร้างห้องใหม่จาก transcript
            let link = self.claudeSessionURL(sid)
            let continues = link?.host == "code" && link?.path == "/continue"
                && link?.absoluteString.contains("session=\(sid)") == true
            // deep link ที่เจาะจงแท็บอยู่แล้ว ยังต้องชนะทุกกรณี
            let warp = self.openRoute(focus: "warp://session/abc", path: "/tmp", pids: mine,
                                      sessionID: sid)
            // ไม่มี session id ก็ยังต้องพากลับไปที่แอปหรือโฟลเดอร์ได้
            let app = self.openRoute(focus: "", path: "/tmp", pids: mine, sessionID: "")
            let plain = self.openRoute(focus: "", path: "/tmp", pids: [], sessionID: "")
            let ok = claude == .sessionLink && continues
                && warp == .deepLink && app == .focusApp && plain == .folder
            FileHandle.standardError.write(
                ("SIM OPEN ROUTE claude=\(claude.rawValue) continue=\(continues) "
                + "warp=\(warp.rawValue) app=\(app.rawValue) plain=\(plain.rawValue)\n")
                    .data(using: .utf8)!
            )
            NSApp.terminate(nil)
            if !ok { exit(2) }
            return
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMFILEFINDER"] != nil {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent(
                "pixelcat-file-finder-\(UUID().uuidString)", isDirectory: true
            )
            let documents = root.appendingPathComponent("Documents", isDirectory: true)
            let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
            let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
            let exact = documents.appendingPathComponent("report.pdf")
            let older = downloads.appendingPathComponent("report-old.pdf")
            let ignored = caches.appendingPathComponent("report.pdf")
            let outside = fm.temporaryDirectory.appendingPathComponent(
                "outside-report-\(UUID().uuidString).pdf"
            )
            try! fm.createDirectory(at: documents, withIntermediateDirectories: true)
            try! fm.createDirectory(at: downloads, withIntermediateDirectories: true)
            try! fm.createDirectory(at: caches, withIntermediateDirectories: true)
            for url in [exact, older, ignored, outside] { fm.createFile(atPath: url.path, contents: Data()) }
            let exactPath = exact.resolvingSymlinksInPath().path
            let olderPath = older.resolvingSymlinksInPath().path

            let finder = LocalFileFinder(homeDirectory: root) { _, _ in
                [older.path, exact.path, exact.path, ignored.path, outside.path]
            }
            let parsing = finder.query(from: "/หา README.md") == "README.md"
                && finder.query(from: "ช่วยหาไฟล์ รายงาน.pdf ให้หน่อย") == "รายงาน.pdf"
                && finder.query(from: "โฟลเดอร์ pixel-cat อยู่ไหน") == "pixel-cat"
                && finder.query(from: "วันนี้เป็นยังไงบ้าง") == nil
                && finder.query(from: "/หา   ") == nil
            let rankedResults = finder.find(named: "report.pdf")
            let ranked = rankedResults.map(\.path) == [exactPath, olderPath]
            let adapterResults = LocalFileFinder(homeDirectory: root).find(named: "report.pdf")
            let adapter = adapterResults.contains { $0.path == exactPath }
            if !adapter {
                FileHandle.standardError.write(
                    "SIM FILE FINDER adapter_paths=\(adapterResults.map(\.path))\n".data(using: .utf8)!
                )
            }

            self.fileFinder = finder
            self.speechOn = true
            self.openCompanionChat()
            self.chatInput?.stringValue = "/หา report.pdf"
            self.sendCompanionChat()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let localOnly = self.lastFileSearchStayedLocal
                let ui = self.bubbleView.text.contains("report.pdf")
                    && self.bubbleView.text.contains("~/Documents")
                    && self.fileSearchTarget?.path == exactPath
                let menu = self.fileSearchMenuItem?.submenu?.items.contains {
                    ($0.representedObject as? String) == olderPath
                        && $0.title.contains("~/Downloads")
                } == true
                self.openBubbleTarget()
                let reveal = self.lastSimulatedRevealPath == exactPath
                let deepDir = root.appendingPathComponent("Documents/work/2026/q3/final", isDirectory: true)
                try? fm.createDirectory(at: deepDir, withIntermediateDirectories: true)
                let deep = deepDir.appendingPathComponent("report.pdf")
                let located = finder.displayLocation(for: exact) == "~/Documents"
                    && finder.displayLocation(for: deep) == "~/Documents/…/2026/q3/final"
                if !located {
                    FileHandle.standardError.write(
                        ("SIM FILE FINDER loc1=\(finder.displayLocation(for: exact)) "
                        + "loc2=\(finder.displayLocation(for: deep))\n").data(using: .utf8)!
                    )
                }
                let ok = parsing && ranked && adapter && localOnly && ui && reveal && menu && located
                FileHandle.standardError.write(
                    ("SIM FILE FINDER parse=\(parsing) ranked=\(ranked) adapter=\(adapter) "
                    + "private=\(localOnly) ui=\(ui) reveal=\(reveal) menu=\(menu) "
                    + "located=\(located)\n")
                        .data(using: .utf8)!
                )
                try? fm.removeItem(at: root)
                try? fm.removeItem(at: outside)
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
            return
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMSHORTCUTGECKO"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.activateCompanionChatShortcut()
                let chat = self.chatWindow?.isVisible == true
                self.chatWindow?.orderOut(nil)

                let frame = POSES["gecko"]!.start
                self.geckoView.image = Sheet.shared.frames[frame]
                self.geckoView.pixelMask = Sheet.shared.masks[frame]
                self.geckoWindow.setContentSize(NSSize(
                    width: CGFloat(SPRITE_W) * self.scale,
                    height: CGFloat(SPRITE_H) * self.scale
                ))
                let opaqueIndex = self.geckoView.pixelMask.firstIndex(of: true)!
                let clearIndex = self.geckoView.pixelMask.firstIndex(of: false)!
                func point(for index: Int) -> NSPoint {
                    let column = index % SPRITE_W
                    let row = index / SPRITE_W
                    return NSPoint(
                        x: (CGFloat(column) + 0.5) / CGFloat(SPRITE_W) * self.geckoView.bounds.width,
                        y: self.geckoView.bounds.height
                            - (CGFloat(row) + 0.5) / CGFloat(SPRITE_H) * self.geckoView.bounds.height
                    )
                }
                let opaque = self.geckoView.hitTest(point(for: opaqueIndex)) === self.geckoView
                let transparent = self.geckoView.hitTest(point(for: clearIndex)) == nil
                self.geckoOn = true
                self.geckoWindow.alphaValue = 1
                self.geckoWindow.orderFront(nil)
                let click = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point(for: opaqueIndex), modifierFlags: [],
                    timestamp: 0, windowNumber: self.geckoWindow.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1
                )!
                self.geckoView.mouseDown(with: click)
                let dismissed = !self.geckoOn && !self.geckoWindow.isVisible
                let ok = self.companionHotKeyRegistered && chat && opaque && transparent && dismissed
                FileHandle.standardError.write(
                    ("SIM SHORTCUT GECKO registered=\(self.companionHotKeyRegistered) "
                    + "chat=\(chat) opaque=\(opaque) transparent=\(transparent) "
                    + "dismissed=\(dismissed)\n").data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
            return
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMRETURNRITUAL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let working = ReturnRitualEvent(
                    key: "codex:welcome", title: "งานต้อนรับ", source: "codex",
                    state: "working", updatedAt: 0
                )
                let done = ReturnRitualEvent(
                    key: "codex:welcome", title: "งานต้อนรับ", source: "codex",
                    state: "done", updatedAt: 590
                )

                var longAway = ReturnRitualTracker()
                _ = longAway.observe(now: 0, idleSeconds: 0, focusActive: false,
                                     events: [working])
                _ = longAway.observe(now: 600, idleSeconds: 600, focusActive: false,
                                     events: [done])
                let eligible = longAway.observe(now: 601, idleSeconds: 0,
                                                focusActive: false, events: [done]) != nil

                var shortAway = ReturnRitualTracker()
                _ = shortAway.observe(now: 0, idleSeconds: 0, focusActive: false,
                                      events: [working])
                _ = shortAway.observe(now: 300, idleSeconds: 300, focusActive: false,
                                      events: [done])
                let early = shortAway.observe(now: 301, idleSeconds: 0,
                                              focusActive: false, events: [done]) != nil

                var focusedReturn = ReturnRitualTracker()
                _ = focusedReturn.observe(now: 0, idleSeconds: 0, focusActive: false,
                                          events: [working])
                _ = focusedReturn.observe(now: 600, idleSeconds: 600, focusActive: true,
                                          events: [done])
                let hiddenDuringFocus = focusedReturn.observe(
                    now: 601, idleSeconds: 0, focusActive: true, events: [done]
                ) == nil
                let shownAfterFocus = focusedReturn.observe(
                    now: 602, idleSeconds: 0, focusActive: false, events: [done]
                ) != nil
                let focus = hiddenDuringFocus && shownAfterFocus

                let baseline = (1...4).map {
                    ReturnRitualEvent(key: "\($0 % 2 == 0 ? "claude" : "codex"):\($0)",
                                      title: "งาน \($0)",
                                      source: $0 % 2 == 0 ? "claude" : "codex",
                                      state: "working", updatedAt: 0)
                }
                let changed = [
                    ReturnRitualEvent(key: "codex:1", title: "งาน 1", source: "codex",
                                      state: "done", updatedAt: 560),
                    ReturnRitualEvent(key: "claude:2", title: "งาน 2", source: "claude",
                                      state: "waiting", updatedAt: 570),
                    ReturnRitualEvent(key: "codex:3", title: "งาน 3", source: "codex",
                                      state: "failed", updatedAt: 580),
                    ReturnRitualEvent(key: "claude:4", title: "งาน 4", source: "claude",
                                      state: "done", updatedAt: 590)
                ]
                var importantReturn = ReturnRitualTracker()
                _ = importantReturn.observe(now: 0, idleSeconds: 0, focusActive: false,
                                            events: baseline)
                _ = importantReturn.observe(now: 600, idleSeconds: 600, focusActive: false,
                                            events: changed)
                let important = importantReturn.observe(
                    now: 601, idleSeconds: 0, focusActive: false, events: changed
                )
                let priority = important?.events.map(\.key) == ["codex:3", "claude:2", "claude:4"]
                let once = importantReturn.observe(
                    now: 602, idleSeconds: 0, focusActive: false, events: changed
                ) == nil

                let workFixtures = changed.map { event in
                    WorkSession(
                        source: event.source, id: event.key.components(separatedBy: ":").last ?? event.key,
                        state: event.state, name: event.title, cwd: "/tmp/\(event.title)", message: "",
                        updatedAt: event.updatedAt, contextPercent: 0,
                        focusURL: "codex://threads/\(event.key)", appPIDs: [],
                        sessionID: event.key, topic: event.title
                    )
                }
                self.speechOn = true
                self.focusPhase = .idle
                self.held = false; self.airborne = false; self.climbing = false
                self.motionReductionOverride = false
                self.activeWorkNotice = nil; self.activeContextRescue = nil
                self.workSessions = workFixtures
                self.pendingReturnRitual = important
                self.showPendingReturnRitual()
                let summaryShown = self.bubbleView.text.contains("พ่อกลับมาแล้ว")
                    && self.bubbleView.text.contains("งาน 3")
                    && self.bubbleView.text.contains("งาน 2")
                    && self.bubbleView.text.contains("งาน 4")
                let animation = self.state == "walk" && self.hurry
                let targetBeforeClick = self.bubbleTarget?.id == "3"
                    && self.activeWorkNotice?.kind == .returned
                self.openBubbleTarget()
                let clickable = targetBeforeClick
                    && self.lastSimulatedOpenURL == "codex://threads/codex:3"
                let demo = self.statusItem.menu?.items.contains {
                    $0.title == "ทดลองพิธีต้อนรับ" && $0.action == #selector(self.demoReturnRitual)
                } == true
                let ok = eligible && !early && focus && priority && once
                    && summaryShown && animation && clickable && demo
                FileHandle.standardError.write(
                    ("SIM RETURN RITUAL eligible=\(eligible) early=\(early) "
                    + "focus=\(focus) priority=\(priority) once=\(once) "
                    + "summary=\(summaryShown) animation=\(animation) clickable=\(clickable) "
                    + "demo=\(demo)\n")
                        .data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
            return
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMBUILDTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.sessPoll = 9999; self.inboxPoll = 9999; self.checkIn = 9999
                self.speechOn = true
                self.focusPhase = .idle
                self.motionReductionOverride = false
                self.activeWorkNotice = nil
                self.activeContextRescue = nil

                func rollout(_ payloads: [[String: Any]]) -> Data {
                    payloads.reduce(into: Data()) { data, payload in
                        data.append(try! JSONSerialization.data(withJSONObject: ["payload": payload]))
                        data.append(0x0A)
                    }
                }
                func call(_ id: String, _ command: String, escalated: Bool = false) -> [String: Any] {
                    let approval = escalated ? ",sandbox_permissions:\"require_escalated\"" : ""
                    return ["type": "custom_tool_call", "call_id": id, "name": "exec",
                            "input": "await tools.exec_command({cmd:\"\(command)\"\(approval)})"]
                }
                func output(_ id: String, _ text: String) -> [String: Any] {
                    ["type": "custom_tool_call_output", "call_id": id,
                     "output": [["type": "input_text", "text": text]]]
                }

                let codexBuild = BuildTestAwareness.codexRollout(
                    data: rollout([call("build-1", "./build.sh")]), turnState: "inProgress"
                ).kind == .build
                let codexTest = BuildTestAwareness.codexRollout(
                    data: rollout([call("test-1", "zsh check-app.sh")]), turnState: "inProgress"
                ).kind == .testing
                let codexPass = BuildTestAwareness.codexRollout(
                    data: rollout([call("test-2", "zsh check-app.sh"),
                                   output("test-2", "Script completed\\nPASS: ok")]),
                    turnState: "inProgress"
                ).kind == .testPassed
                let codexFail = BuildTestAwareness.codexRollout(
                    data: rollout([call("test-3", "zsh check-app.sh"),
                                   output("test-3", "Script failed\\nexit=1")]),
                    turnState: "inProgress"
                ).kind == .testFailed
                let codexPermission = BuildTestAwareness.codexRollout(
                    data: rollout([call("test-4", "zsh check-app.sh", escalated: true)]),
                    turnState: "inProgress"
                ).kind == .permission
                let claudeKinds = [
                    BuildTestAwareness.classify(state: "build", message: "", fingerprint: "c1").kind,
                    BuildTestAwareness.classify(state: "test", message: "", fingerprint: "c2").kind,
                    BuildTestAwareness.classify(state: "test_pass", message: "", fingerprint: "c3").kind,
                    BuildTestAwareness.classify(state: "test_fail", message: "", fingerprint: "c4").kind,
                    BuildTestAwareness.classify(state: "permission", message: "", fingerprint: "c5").kind
                ]
                let classify = codexBuild && codexTest && codexPass && codexFail && codexPermission
                    && claudeKinds == [.build, .testing, .testPassed, .testFailed, .permission]

                self.playBuildTestAnimation(.build)
                let build = self.state == "buildWork"
                self.playBuildTestAnimation(.testing)
                let test = self.state == "testWatch"
                self.playBuildTestAnimation(.testPassed)
                let pass = self.state == "testPass"
                self.playBuildTestAnimation(.testFailed)
                let fail = self.state == "testFail"
                self.playBuildTestAnimation(.permission)
                let permission = self.state == "permission"

                let now = Date().timeIntervalSince1970
                let testingSession = WorkSession(
                    source: "codex", id: "testing", state: "working", name: "tests", cwd: "/tmp",
                    message: "", updatedAt: now, contextPercent: 0,
                    focusURL: "codex://threads/testing", appPIDs: [], sessionID: "", topic: "tests",
                    activity: WorkActivitySignal(kind: .testing, fingerprint: "test-priority")
                )
                let transitionTesting = WorkSession(
                    source: "codex", id: "transition", state: "working", name: "tests", cwd: "/tmp",
                    message: "", updatedAt: now, contextPercent: 0,
                    focusURL: "codex://threads/transition", appPIDs: [], sessionID: "", topic: "tests",
                    activity: WorkActivitySignal(kind: .testing, fingerprint: "same-call")
                )
                let transitionPassed = WorkSession(
                    source: "codex", id: "transition", state: "working", name: "tests", cwd: "/tmp",
                    message: "", updatedAt: now, contextPercent: 0,
                    focusURL: "codex://threads/transition", appPIDs: [], sessionID: "", topic: "tests",
                    activity: WorkActivitySignal(kind: .testPassed, fingerprint: "same-call")
                )
                self.currentWorkActivitySignature = ""
                self.updateBuildTestAwareness([transitionTesting])
                let transitionStarted = self.state == "testWatch"
                self.updateBuildTestAwareness([transitionPassed])
                let transition = transitionStarted && self.state == "testPass"

                let staleFailure = WorkSession(
                    source: "codex", id: "old-failure", state: "working", name: "old", cwd: "/tmp",
                    message: "", updatedAt: now - 2, contextPercent: 0,
                    focusURL: "codex://threads/old-failure", appPIDs: [], sessionID: "", topic: "old",
                    activity: WorkActivitySignal(kind: .testFailed, fingerprint: "old-result")
                )
                self.currentWorkActivitySignature = ""
                self.seenWorkActivitySignatures.removeAll()
                self.updateBuildTestAwareness([staleFailure])
                let staleShown = self.state == "testFail"
                self.updateBuildTestAwareness([staleFailure, testingSession])
                let resume = staleShown && self.state == "testWatch"

                let permissionSession = WorkSession(
                    source: "claude", id: "permission", state: "input", name: "approval", cwd: "/tmp",
                    message: "", updatedAt: now - 1, contextPercent: 0,
                    focusURL: "", appPIDs: [], sessionID: "permission", topic: "approval",
                    activity: WorkActivitySignal(kind: .permission, fingerprint: "permission-priority")
                )
                self.currentWorkActivitySignature = ""
                self.updateBuildTestAwareness([testingSession, permissionSession])
                let priority = self.state == "permission"

                self.setState("sit", duration: 99)
                self.focusPhase = .focus
                self.currentWorkActivitySignature = ""
                self.updateBuildTestAwareness([testingSession])
                let focus = self.state == "sit"
                self.focusPhase = .idle

                self.motionReductionOverride = true
                self.playBuildTestAnimation(.testing)
                for _ in 0..<90 { self.tick(1.0 / 60.0) }
                let reduced = self.state == "testWatch" && self.frameIdx == 0
                let shadow = Sheet.shared.spans[65...77].allSatisfy {
                    $0.0 > 0 && $0.0 <= $0.1 && $0.1 < SPRITE_W - 1
                }

                let ok = classify && build && test && pass && fail && permission && transition && resume
                    && priority && focus && reduced && shadow
                FileHandle.standardError.write(
                    ("SIM BUILD TEST classify=\(classify) build=\(build) test=\(test) "
                    + "pass=\(pass) fail=\(fail) permission=\(permission) "
                    + "transition=\(transition) resume=\(resume) "
                    + "priority=\(priority) focus=\(focus) reduced=\(reduced) "
                    + "shadow=\(shadow)\n").data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMCODING"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.sessPoll = 9999; self.inboxPoll = 9999; self.checkIn = 9999
                self.focusPhase = .idle
                self.motionReductionOverride = false
                self.activeWorkNotice = nil
                self.activeContextRescue = nil

                func rollout(_ payloads: [[String: Any]]) -> Data {
                    payloads.reduce(into: Data()) { data, payload in
                        data.append(try! JSONSerialization.data(withJSONObject: ["payload": payload]))
                        data.append(0x0A)
                    }
                }
                let editCall: [String: Any] = [
                    "type": "custom_tool_call", "call_id": "edit-1", "name": "exec",
                    "input": "await tools.apply_patch(\"*** Begin Patch\\n*** End Patch\")"
                ]
                let editOutput: [String: Any] = [
                    "type": "custom_tool_call_output", "call_id": "edit-1",
                    "output": [["type": "input_text", "text": "patch applied"]]
                ]
                let codexActive = BuildTestAwareness.codexRollout(
                    data: rollout([editCall]), turnState: "inProgress"
                ).kind == .coding
                let codexCompletedEdit = BuildTestAwareness.codexRollout(
                    data: rollout([editCall, editOutput]), turnState: "inProgress"
                ).kind == .coding
                let codex = codexActive && codexCompletedEdit
                let claude = BuildTestAwareness.classify(
                    state: "coding", message: "editing main.swift", fingerprint: "claude-edit"
                ).kind == .coding
                let classify = BuildTestAwareness.classify(
                    state: "busy", message: "กำลังแก้โค้ด", fingerprint: "message-edit"
                ).kind == .coding

                self.playBuildTestAnimation(.coding)
                let pose = self.state == "coding"
                let tailSlices = (78...81).map { frame in
                    Sheet.shared.masks[frame].enumerated().compactMap { index, opaque in
                        index % SPRITE_W >= 100 ? opaque : nil
                    }
                }
                let tail = Set(tailSlices).count >= 2

                let now = Date().timeIntervalSince1970
                let codingSession = WorkSession(
                    source: "codex", id: "coding", state: "working", name: "code", cwd: "/tmp",
                    message: "", updatedAt: now, contextPercent: 0,
                    focusURL: "codex://threads/coding", appPIDs: [], sessionID: "", topic: "code",
                    activity: WorkActivitySignal(kind: .coding, fingerprint: "edit-transition")
                )
                let buildSession = WorkSession(
                    source: "codex", id: "coding", state: "working", name: "code", cwd: "/tmp",
                    message: "", updatedAt: now, contextPercent: 0,
                    focusURL: "codex://threads/coding", appPIDs: [], sessionID: "", topic: "code",
                    activity: WorkActivitySignal(kind: .build, fingerprint: "build-transition")
                )
                self.currentWorkActivitySignature = ""
                self.updateBuildTestAwareness([codingSession])
                let codingStarted = self.state == "coding"
                self.updateBuildTestAwareness([buildSession])
                let transition = codingStarted && self.state == "buildWork"

                self.setState("sit", duration: 99)
                self.focusPhase = .focus
                self.currentWorkActivitySignature = ""
                self.updateBuildTestAwareness([codingSession])
                let focus = self.state == "sit"
                self.focusPhase = .idle

                self.motionReductionOverride = true
                self.playBuildTestAnimation(.coding)
                for _ in 0..<90 { self.tick(1.0 / 60.0) }
                let reduced = self.state == "coding" && self.frameIdx == 0
                let shadow = Sheet.shared.spans[78...81].allSatisfy {
                    $0.0 > 0 && $0.0 <= $0.1 && $0.1 < SPRITE_W - 1
                }

                let ok = classify && codex && claude && pose && tail
                    && transition && focus && reduced && shadow
                FileHandle.standardError.write(
                    ("SIM CODING classify=\(classify) codex=\(codex) claude=\(claude) "
                    + "pose=\(pose) tail=\(tail) transition=\(transition) "
                    + "focus=\(focus) reduced=\(reduced) shadow=\(shadow)\n")
                        .data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMSHEPHERD"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.sessPoll = 9999; self.inboxPoll = 9999; self.checkIn = 9999
                let floor = Platform(y: 40, minX: 0, maxX: 1200, isFloor: true)
                self.platforms = [floor]; self.plat = floor
                self.x = 300; self.y = floor.y
                self.focusPhase = .idle; self.airborne = false; self.climbing = false
                self.simulatedShepherdRect = CGRect(x: 850, y: 80, width: 300, height: 500)
                let session = WorkSession(source: "codex", id: "attention", state: "input",
                                          name: "งานที่รอ", cwd: "/tmp", message: "",
                                          updatedAt: 1, contextPercent: 0,
                                          focusURL: "codex://threads/attention", appPIDs: [],
                                          sessionID: "", topic: "งานที่รอ")
                self.startTaskShepherd(session)
                let direction = self.dir > 0 && (self.target ?? 0) > self.x
                let walked = self.state == "walk"
                // ขนาดที่ผู้ใช้บันทึกไว้มีผลต่อความเร็วเดิน จึงเผื่อสูงสุด 10 วินาที
                // ให้ simulation วัดผลลัพธ์ ไม่ผูกกับ scale ของเครื่องที่รันเทสต์
                for _ in 0..<600 where self.state != "point" { self.tick(1.0 / 60.0) }
                let pointed = self.state == "point"
                let targetPresent = self.shepherdTarget?.id == session.id
                self.focusPhase = .focus; self.focusRemaining = 100
                let stateBefore = self.state
                self.startTaskShepherd(WorkSession(
                    source: "claude", id: "deferred", state: "input", name: "deferred",
                    cwd: "", message: "", updatedAt: 1, contextPercent: 0,
                    focusURL: "", appPIDs: [], sessionID: "", topic: ""))
                let focusDeferred = self.state == stateBefore
                    && self.shepherdTarget?.id == session.id && self.focusPhase == .focus
                let openedFromCat = self.openShepherdTargetIfPresent()
                    && self.lastSimulatedOpenURL == session.focusURL
                let clickable = targetPresent && openedFromCat
                let ok = direction && walked && pointed && clickable && focusDeferred
                FileHandle.standardError.write(
                    ("SIM SHEPHERD direction=\(direction) walked=\(walked) pointed=\(pointed) "
                     + "clickable=\(clickable) focusDeferred=\(focusDeferred)\n").data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMCOURIER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.sessPoll = 9999; self.inboxPoll = 9999; self.checkIn = 9999
                let floor = Platform(y: 40, minX: 0, maxX: 1200, isFloor: true)
                self.platforms = [floor]; self.plat = floor
                self.x = 300; self.y = floor.y
                self.focusPhase = .idle; self.airborne = false; self.climbing = false
                self.simulatedShepherdRect = CGRect(x: 850, y: 80, width: 300, height: 500)
                let codex = WorkSession(source: "codex", id: "courier-codex", state: "working",
                                        name: "Codex target", cwd: "/tmp", message: "",
                                        updatedAt: 2, contextPercent: 0,
                                        focusURL: "codex://threads/courier-codex", appPIDs: [],
                                        sessionID: "", topic: "Codex target")
                let claude = WorkSession(source: "claude", id: "courier-claude", state: "working",
                                         name: "Claude target", cwd: "/tmp", message: "",
                                         updatedAt: 1, contextPercent: 0,
                                         focusURL: "warp://session/claude", appPIDs: [],
                                         sessionID: "", topic: "Claude target")
                self.workSessions = [codex, claude]
                let menu = self.makeCourierTargetMenu()
                let titles = menu.items.map(\.title)
                let sections = titles.contains("Codex") && titles.contains("Claude Code")
                    && self.courierChoices.count == 2
                let hostile = "$(touch /tmp/pixelcat-must-not-run); `whoami`"
                let payload = CourierPayload(files: [], text: hostile)
                let safePayload = payload.pasteboardText == hostile
                self.motionLevel = .normal
                self.motionReductionOverride = false
                self.performCourierDelivery(payload, to: codex)
                let animated = self.state == "courier"
                for _ in 0..<360 { self.tick(1.0 / 60.0) }
                let redirected = self.lastSimulatedOpenURL == codex.focusURL
                self.motionReductionOverride = true
                self.lastSimulatedOpenURL = ""
                self.performCourierDelivery(payload, to: claude)
                let reduced = self.state != "courier"
                    && self.lastSimulatedOpenURL == claude.focusURL
                let registered = self.courierDropRegistered
                let ok = registered && sections && safePayload && animated && redirected && reduced
                FileHandle.standardError.write(
                    ("SIM COURIER registered=\(registered) sections=\(sections) "
                     + "safePayload=\(safePayload) animated=\(animated) "
                     + "redirected=\(redirected) reduced=\(reduced)\n").data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMCONTEXTRESCUE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.sessPoll = 9999; self.inboxPoll = 9999; self.checkIn = 9999
                self.speechOn = true
                self.motionReductionOverride = false
                self.focusPhase = .idle; self.held = false; self.airborne = false
                self.climbing = false; self.activeWorkNotice = nil
                // งานจริงของกริชอาจจุด rescue ไปแล้วใน 0.6 วิแรก ต้องล้างก่อนวัด ไม่งั้นเทสต์แพ้เพราะ session จริง
                self.activeContextRescue = nil
                self.contextRescueOffered.removeAll()
                self.workSessions = []
                self.lastSimulatedHandoff = ""
                self.lastSimulatedNewTaskURL = ""
                let makeSession: (String, String, Double) -> WorkSession = { source, id, pct in
                    WorkSession(source: source, id: id, state: "input", name: "pixel-cat",
                                cwd: "/tmp/pixel-cat", message: "implement rescue flow",
                                updatedAt: 1, contextPercent: pct,
                                focusURL: source == "codex" ? "codex://threads/\(id)" : "",
                                appPIDs: [], sessionID: id, topic: "Context Rescue")
                }
                let fixtureURL = URL(fileURLWithPath: "/tmp/pixelcat-context-token-fixture.jsonl")
                let fixture = """
                {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":180000},"model_context_window":200000}}}
                """
                try? fixture.data(using: .utf8)?.write(to: fixtureURL)
                let codexTelemetry = abs(self.codexContextPercent(
                    rolloutPath: fixtureURL.path) - 90) < 0.01
                try? FileManager.default.removeItem(at: fixtureURL)
                let warm = makeSession("claude", "rescue-source", 89)
                self.evaluateContextPressure([warm])
                let belowThreshold = self.activeContextRescue == nil
                let hot = makeSession("claude", "rescue-source", 92)
                self.evaluateContextPressure([hot])
                let threshold = codexTelemetry && belowThreshold
                    && self.activeContextRescue?.session.id == hot.id
                let startedPacking = self.state == "rescuePack"
                self.platRefresh = 9999
                for _ in 0..<100 { self.tick(1.0 / 60.0) }
                let packed = startedPacking && self.state == "rescueReady"
                let offeredCount = self.contextRescueOffered.count
                let opened = self.openContextRescueIfPresent()
                self.evaluateContextPressure([hot])
                let once = opened && offeredCount == 1
                    && self.contextRescueOffered.count == 1 && self.activeContextRescue == nil
                let handoff = self.lastSimulatedHandoff.contains("Context Rescue")
                    && self.lastSimulatedHandoff.contains("pixel-cat")
                    && self.lastSimulatedHandoff.contains("อย่าทำซ้ำ")
                let claudeURL = URLComponents(string: self.lastSimulatedNewTaskURL)
                let claudeNew = claudeURL?.scheme == "claude" && claudeURL?.host == "code"
                    && claudeURL?.path == "/new"
                    && claudeURL?.queryItems?.contains(where: { $0.name == "folder" }) == true
                let codex = self.makeContextRescue(for: makeSession("codex", "codex-rescue", 95))
                let codexURL = codex.flatMap {
                    URLComponents(url: $0.launchURL, resolvingAgainstBaseURL: false)
                }
                let codexNew = codexURL?.scheme == "codex" && codexURL?.host == "new"
                    && codexURL?.queryItems?.contains(where: { $0.name == "prompt" }) == true
                    && codexURL?.queryItems?.contains(where: { $0.name == "path" }) == true

                self.activeContextRescue = nil
                self.focusPhase = .focus; self.focusRemaining = 100
                let deferred = makeSession("claude", "focus-rescue", 94)
                self.evaluateContextPressure([hot, deferred])
                let focusDeferred = self.activeContextRescue == nil

                self.focusPhase = .idle
                self.evaluateContextPressure([makeSession("claude", "rescue-source", 60)])
                self.evaluateContextPressure([hot])
                let reset = self.activeContextRescue?.session.id == hot.id

                // ห้องเก่าที่พ่อเปิดห้องใหม่ในโฟลเดอร์เดียวกันไปแล้ว ต้องไม่ถูกเตือนอีก
                self.activeContextRescue = nil
                self.contextRescueOffered.removeAll()
                self.ctxWarned = 0
                var old = makeSession("claude", "old-room", 99)
                old.startedAt = 100
                var fresh = makeSession("claude", "new-room", 12)
                fresh.startedAt = 200
                self.evaluateContextPressure([old, fresh])
                let supersededQuiet = self.activeContextRescue == nil
                self.evaluateContextPressure([old])
                let stillRescuesAlone = self.activeContextRescue?.session.id == old.id
                let superseded = supersededQuiet && stillRescuesAlone

                // handoff ต้องบอกให้ครบว่าโปรเจกต์คืออะไร ทำอะไรไปแล้ว และห้องเก่าแตะไฟล์ไหน
                let fm = FileManager.default
                let repo = fm.temporaryDirectory
                    .appendingPathComponent("pixelcat-rescue-repo-\(UUID().uuidString)")
                try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
                try? "# Demo\n\nแมวจิ๋วเฝ้างานบนเดสก์ท็อป\n".write(
                    to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
                for args in [["init", "-q"], ["add", "-A"],
                             ["-c", "user.email=cat@pixel", "-c", "user.name=cat",
                              "commit", "-qm", "ปักหมุดงานแรก"]] {
                    _ = self.readOnlyShell("/usr/bin/git", args, in: repo.path)
                }
                try? "ยังไม่คอมมิต".write(to: repo.appendingPathComponent("draft.txt"),
                                          atomically: true, encoding: .utf8)
                var detailed = makeSession("claude", "detail-room", 96)
                detailed = WorkSession(
                    source: "claude", id: detailed.id, state: "idle", name: "demo",
                    cwd: repo.path, message: "", updatedAt: 1, contextPercent: 96,
                    focusURL: "", appPIDs: [], sessionID: detailed.id, topic: "งานเดโม",
                    recentFiles: [repo.path + "/Sources/Demo.swift"],
                    lastRequest: "ทำระบบเดโมให้หน่อย"
                )
                let text = self.contextHandoff(for: detailed)
                let detail = text.contains("แมวจิ๋วเฝ้างานบนเดสก์ท็อป")
                    && text.contains("ปักหมุดงานแรก")
                    && text.contains("branch:")
                    && text.contains("1 ไฟล์ที่ยังไม่คอมมิต")
                    && text.contains("Sources/Demo.swift")
                    && text.contains("ทำระบบเดโมให้หน่อย")
                if let dir = ProcessInfo.processInfo.environment["PIXELCAT_HANDOFF_OUT"] {
                    try? text.write(toFile: dir, atomically: true, encoding: .utf8)
                }
                try? fm.removeItem(at: repo)

                let ok = threshold && once && packed && handoff && codexNew
                    && claudeNew && focusDeferred && reset && superseded && detail
                FileHandle.standardError.write(
                    ("SIM CONTEXT RESCUE threshold=\(threshold) once=\(once) packed=\(packed) "
                     + "handoff=\(handoff) codexNew=\(codexNew) claudeNew=\(claudeNew) "
                     + "focusDeferred=\(focusDeferred) reset=\(reset) "
                     + "superseded=\(superseded) detail=\(detail)\n").data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMANIMATIONANCHOR"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let names = ["walk", "run", "sit", "climb"]
                var maxDrift: CGFloat = 0
                var maxFootDrift: CGFloat = 0
                var driftParts: [String] = []
                var eyeParts: [String] = []
                var footParts: [String] = []
                for name in names {
                    guard let pose = POSES[name] else { continue }
                    eyeParts.append("\(name)=" + (pose.start..<(pose.start + pose.count)).map {
                        Sheet.shared.eyeAnchorsX[$0].map { String(format: "%.2f", $0) } ?? "-"
                    }.joined(separator: "/"))
                    footParts.append("\(name)=" + (pose.start..<(pose.start + pose.count)).map {
                        String(format: "%.0f", Sheet.shared.footAnchorsY[$0])
                    }.joined(separator: "/"))
                    let xs = (pose.start..<(pose.start + pose.count)).compactMap { index in
                        Sheet.shared.eyeAnchorsX[index].map {
                            $0 + Sheet.shared.anchorOffsetsX[index]
                        }
                    }
                    if let lo = xs.min(), let hi = xs.max() {
                        let drift = hi - lo
                        maxDrift = max(maxDrift, drift)
                        driftParts.append("\(name)=\(String(format: "%.1f", drift))")
                    }
                    let feet = (pose.start..<(pose.start + pose.count)).map { index in
                        Sheet.shared.footAnchorsY[index] - Sheet.shared.anchorOffsetsY[index]
                    }
                    if let lo = feet.min(), let hi = feet.max() {
                        maxFootDrift = max(maxFootDrift, hi - lo)
                    }
                }
                self.motionReductionOverride = false
                self.emotionKind = nil
                self.noticeMotionFor = 0
                self.landingMotion = 0
                var noSyntheticWobble = true
                for name in names {
                    guard let pose = POSES[name] else { continue }
                    self.state = name == "run" ? "walk" : name
                    self.hurry = name == "run"
                    for frame in 0..<pose.count {
                        self.frameIdx = frame
                        self.applyFrame()
                        noSyntheticWobble = noSyntheticWobble
                            && self.view.motionX == 0 && self.view.motionY == 0
                    }
                }
                let correctedFrames = zip(Sheet.shared.anchorOffsetsX, Sheet.shared.anchorOffsetsY)
                    .filter { pair in pair.0 != 0 || pair.1 != 0 }.count
                let bodyLocked = maxDrift <= 1.0
                let feetLocked = maxFootDrift == 0
                let locked = bodyLocked && feetLocked && noSyntheticWobble && correctedFrames > 0
                FileHandle.standardError.write(
                    ("SIM ANIMATION ANCHOR locked=\(locked) bodyLocked=\(bodyLocked) "
                     + "feetLocked=\(feetLocked) noSyntheticWobble=\(noSyntheticWobble) "
                     + "correctedFrames=\(correctedFrames) maxDrift=\(String(format: "%.2f", maxDrift)) "
                     + "footDrift=\(String(format: "%.2f", maxFootDrift)) "
                     + "raw=\(driftParts.joined(separator: ",")) "
                     + "eyes=\(eyeParts.joined(separator: ",")) "
                     + "feet=\(footParts.joined(separator: ","))\n")
                        .data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !locked { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMTRANSITIONS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.sessPoll = 9999
                self.inboxPoll = 9999
                self.checkIn = 9999
                self.geckoIn = 9999
                self.motionReductionOverride = false
                self.state = "walk"
                self.transitionState(to: "sit", duration: 1.0)
                let settleBridge = self.state == "stretch"
                self.tick(0.22)
                let settleReached = self.state == "sit"

                self.state = "sit"
                self.transitionState(to: "jump", duration: 0.4)
                let jumpBridge = self.state == "crouch"
                self.tick(0.22)
                let jumpReached = self.state == "jump"

                self.motionReductionOverride = true
                self.state = "walk"
                self.transitionState(to: "sit", duration: 1.0)
                let reducedDirect = self.state == "sit"

                self.motionReductionOverride = false
                self.platRefresh = 9999
                self.pounceCool = 9999
                self.ballOn = false
                self.geckoOn = false
                let mouse = NSEvent.mouseLocation
                let floor = Platform(y: mouse.y - 100, minX: mouse.x - 700,
                                     maxX: mouse.x + 700, isFloor: true)
                self.platforms = [floor]
                self.plat = floor
                self.x = mouse.x - self.spriteW / 2
                self.y = floor.y
                self.follow = true
                self.state = "walk"
                self.lastMouse = mouse
                self.tick(0.01)
                let followSettle = self.state == "stretch"
                self.follow = false

                self.state = "sit"
                self.geckoOn = true
                self.geckoPlat = floor
                self.geckoLife = 10
                self.geckoWait = 10
                self.gx = self.x + self.spriteW / 2
                self.gy = self.y
                self.stepGecko(0.01)
                let geckoAnticipation = self.state == "crouch"

                let ledge = Platform(y: floor.y + 180, minX: floor.minX + 120,
                                     maxX: floor.maxX - 120, isFloor: false,
                                     bottom: floor.y - 20)
                self.platforms = [floor, ledge]
                self.plat = floor
                self.x = floor.minX + 400
                self.y = floor.y
                self.state = "sit"
                self.target = nil
                self.afterState = nil
                self.hurry = false
                self.geckoOn = false
                let startedClimb = self.maybeClimb()
                var climbSettle = false
                if startedClimb {
                    for _ in 0..<300 {
                        self.tick(1.0 / 60.0)
                        if !self.plat.isFloor, !self.airborne {
                            climbSettle = self.state == "stretch"
                            break
                        }
                    }
                }
                let productionPaths = followSettle && geckoAnticipation && climbSettle
                let ok = settleBridge && settleReached && jumpBridge && jumpReached
                    && reducedDirect && productionPaths
                FileHandle.standardError.write(
                    ("SIM TRANSITIONS settleBridge=\(settleBridge) settleReached=\(settleReached) "
                     + "jumpBridge=\(jumpBridge) jumpReached=\(jumpReached) "
                     + "reducedDirect=\(reducedDirect) productionPaths=\(productionPaths) "
                     + "follow=\(followSettle) gecko=\(geckoAnticipation) climb=\(climbSettle)\n")
                        .data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMFOCUS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.focusPhase = .focus
                self.focusRemaining = 0.05
                self.updateFocus(0.1)
                let enteredRest = self.focusPhase == .rest && self.focusRemaining == 300
                self.focusRemaining = 0.05
                self.updateFocus(0.1)
                let finished = self.focusPhase == .idle && self.focusRemaining == 0
                let statusReset = self.statusItem.button?.title == "🐈"
                let ok = enteredRest && finished && statusReset
                FileHandle.standardError.write(
                    "SIM FOCUS rest=\(enteredRest) finished=\(finished) status=\(statusReset)\n"
                        .data(using: .utf8)!
                )
                NSApp.terminate(ok ? nil : self)
                if !ok { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMFOCUSPOUNCE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                let mouse = NSEvent.mouseLocation
                self.plat = Platform(y: mouse.y - 100, minX: mouse.x - 500,
                                     maxX: mouse.x + 500, isFloor: true)
                self.x = mouse.x - self.spriteW / 2
                self.y = self.plat.y
                self.target = nil
                self.follow = false
                self.petting = false
                self.airborne = false
                self.sessPoll = 9999
                self.inboxPoll = 9999
                self.checkIn = 9999
                self.geckoIn = 9999
                self.ballOn = false
                self.geckoOn = false
                self.focusPhase = .focus
                self.focusRemaining = 25 * 60
                self.setState("sit", duration: self.focusRemaining)
                self.pounceCool = 0
                self.mouseSpeed = 0
                self.lastMouse = NSPoint(x: mouse.x - 5000, y: mouse.y)

                self.tick(1.0 / 60.0)
                let pounced = self.state == "crouch" || self.pounceTarget != nil || self.airborne
                let focusAlive = self.focusPhase == .focus && self.focusRemaining > 0
                self.speechOn = true
                self.activeWorkNotice = nil
                self.workNoticeQueue.removeAll()
                self.noticeMotionFor = 0
                let sid = "focus-deferred-work"
                self.previousSessionStates = ["codex:\(sid)": "working"]
                self.didSeedSessionStates = true
                let done = WorkSession(source: "codex", id: sid, state: "done",
                                       name: "pixel-cat", cwd: "", message: "",
                                       updatedAt: Date().timeIntervalSince1970,
                                       contextPercent: 0,
                                       focusURL: "codex://threads/\(sid)", appPIDs: [],
                                       sessionID: "", topic: "งานระหว่างโฟกัส")
                self.detectWorkNotices([done])
                let deferred = self.activeWorkNotice == nil
                    && self.workNoticeQueue.count == 1 && self.noticeMotionFor == 0
                self.handleClaude(event: "done", message: "Claude เสร็จระหว่างโฟกัส")
                let claudeDeferred = self.deferredClaudeEvents.count == 1
                    && self.noticeMotionFor == 0
                for i in 0..<14 {
                    self.handleClaude(event: i % 3 == 0 ? "ask" : "done",
                                      message: "Claude queued event \(i)")
                }
                let claudeQueuePreserved = self.deferredClaudeEvents.count == 15
                self.focusPhase = .idle
                self.showNextWorkNotice()
                let resumed = self.activeWorkNotice?.session.id == sid
                    && self.noticeMotionFor > 0
                self.activeWorkNotice = nil
                self.workNoticeQueue.removeAll()
                self.speakFor = 0
                self.noticeMotionFor = 0
                self.flushDeferredClaudeEvent()
                let claudeResumed = self.deferredClaudeEvents.count == 14
                    && self.noticeMotionFor > 0 && self.emotionKind == .done
                let ok = !pounced && focusAlive && deferred && resumed
                    && claudeDeferred && claudeResumed && claudeQueuePreserved
                FileHandle.standardError.write(
                    ("SIM FOCUS POUNCE pounced=\(pounced) focus=\(focusAlive) "
                    + "deferred=\(deferred) resumed=\(resumed) "
                    + "claudeDeferred=\(claudeDeferred) claudeResumed=\(claudeResumed) "
                    + "claudeQueuePreserved=\(claudeQueuePreserved) "
                    + "state=\(self.state)\n")
                        .data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMMOTIONLEVELS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                let defaults = UserDefaults.standard
                let oldValue = defaults.object(forKey: "motionLevel")
                let oldLevel = self.motionLevel
                let oldOverride = self.motionReductionOverride
                self.motionReductionOverride = false
                self.state = "sit"

                func peak(for level: MotionLevel) -> CGFloat {
                    self.motionLevel = level
                    self.emotionKind = .done
                    var peak: CGFloat = 0
                    for phase in 0..<6 {
                        self.noticeMotionFor = 2.4 - Double(phase) / 10.0
                        self.applyFrame()
                        peak = max(peak, self.view.motionY)
                    }
                    return peak
                }

                let calmPeak = peak(for: .calm)
                let normalPeak = peak(for: .normal)
                let playfulPeak = peak(for: .playful)
                let calm = calmPeak <= 2
                let normal = normalPeak >= 6 && normalPeak <= 8
                let playful = playfulPeak >= 10 && playfulPeak > normalPeak

                self.motionReductionOverride = true
                let reducedPeak = peak(for: .playful)
                let reduce = self.effectiveMotionLevel == .calm && reducedPeak <= 2

                let mouse = NSEvent.mouseLocation
                self.plat = Platform(y: mouse.y - 100, minX: mouse.x - 500,
                                     maxX: mouse.x + 500, isFloor: true)
                self.x = mouse.x - self.spriteW / 2
                self.y = self.plat.y
                self.state = "sit"
                self.focusPhase = .idle
                self.follow = false
                self.petting = false
                self.airborne = false
                self.ballOn = false
                self.geckoOn = false
                self.sessPoll = 9999
                self.inboxPoll = 9999
                self.checkIn = 9999
                self.mouseSpeed = 3000
                self.lastMouse = mouse
                self.pounceCool = 0
                self.tick(1.0 / 60.0)
                let noPounce = self.state != "crouch" && self.pounceTarget == nil
                self.state = "sit"
                self.zoomies = 3
                self.pickIdle()
                let noZoomies = self.zoomies == 0 && !self.hurry
                let calmBehavior = noPounce && noZoomies

                self.hearts.removeAll()
                self.petting = true
                self.petStroke()
                let reducedPetting = self.hearts.isEmpty
                self.petting = false

                let ledge = Platform(y: self.y + 210, minX: mouse.x - 250,
                                     maxX: mouse.x + 250, isFloor: false,
                                     bottom: self.y - 20)
                let floor = Platform(y: self.y, minX: mouse.x - 700,
                                     maxX: mouse.x + 700, isFloor: true)
                self.platforms = [floor, ledge]
                self.plat = ledge
                self.y = ledge.y
                self.x = ledge.minX + 80
                var noAutoDescend = true
                for _ in 0..<100 {
                    self.state = "sit"
                    self.target = nil
                    self.afterState = nil
                    self.autoDescending = false
                    self.pickIdle()
                    if self.autoDescending {
                        noAutoDescend = false
                        break
                    }
                }

                self.motionReductionOverride = false
                self.motionLevel = .playful
                self.state = "crouch"
                self.hurry = true
                self.zoomies = 3
                self.pounceTarget = mouse.x
                self.afterState = { [weak self] in self?.doPounce() }
                let calmItem = NSMenuItem()
                calmItem.tag = 20 + MotionLevel.calm.rawValue
                self.setMotionLevel(calmItem)
                let cancelledActive = self.state == "sit" && !self.hurry
                    && self.zoomies == 0 && self.pounceTarget == nil
                    && self.afterState == nil

                self.climbing = true
                self.y = self.plat.y + 100
                self.state = "climb"
                self.setMotionLevel(calmItem)
                let climbingCancelled = !self.climbing && self.state == "sit"
                    && abs(self.y - self.plat.y) < 1

                defaults.set(MotionLevel.playful.rawValue, forKey: "motionLevel")
                let persisted = MotionLevel(rawValue: defaults.integer(forKey: "motionLevel")) == .playful
                if let oldValue { defaults.set(oldValue, forKey: "motionLevel") }
                else { defaults.removeObject(forKey: "motionLevel") }
                self.motionLevel = oldLevel
                self.motionReductionOverride = oldOverride

                let ok = calm && normal && playful && reduce && calmBehavior
                    && noAutoDescend && reducedPetting && cancelledActive && persisted
                    && climbingCancelled
                FileHandle.standardError.write(
                    ("SIM MOTION LEVELS calm=\(calm) normal=\(normal) playful=\(playful) "
                    + "reduce=\(reduce) calmBehavior=\(calmBehavior) "
                    + "noAutoDescend=\(noAutoDescend) reducedPetting=\(reducedPetting) "
                    + "cancelledActive=\(cancelledActive) climbingCancelled=\(climbingCancelled) "
                    + "persisted=\(persisted) peaks="
                    + "\(Int(calmPeak))/\(Int(normalPeak))/\(Int(playfulPeak))\n")
                        .data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMWORKINBOX"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                self.sessPoll = 0
                self.pollSessions(1)
                let titles = self.workInboxItem?.submenu?.items.map(\.title) ?? []
                let codexHeader = titles.firstIndex(of: "Codex • 2")
                let claudeHeader = titles.firstIndex(of: "Claude Code • 3")
                let separated = codexHeader != nil && claudeHeader != nil
                    && codexHeader! < claudeHeader!
                let codexListed = titles.contains {
                    $0.contains("กำลังทำ") && $0.contains("ปรับกล่องงาน")
                }
                let claudeListed = titles.contains {
                    $0.contains("รอคำตอบ") && $0.contains("backend")
                }
                let codexJump = self.workSessions.first {
                    $0.source == "codex" && $0.id == "codex-active"
                }?.focusURL == "codex://threads/codex-active"
                let counts = self.workSessions.count == 5
                    && self.workAlertCount == 2 && self.workActiveCount == 2
                let menu = self.workInboxTitle == "กล่องงาน • ต้องดู 2"
                let badge = self.statusItem.button?.title.contains("• 2") == true
                let ok = separated && codexListed && claudeListed && codexJump
                    && counts && menu && badge
                FileHandle.standardError.write(
                    ("SIM WORK INBOX separated=\(separated) codex=\(codexListed) "
                    + "claude=\(claudeListed) jump=\(codexJump) counts=\(counts) "
                    + "menu=\(menu) badge=\(badge)\n")
                        .data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMWAITREMINDER"] != nil {
            speechOn = true
            sessPoll = 9999
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                self.sessPoll = 0
                self.pollSessions(1)
                guard let waiting = self.workSessions.first(where: { self.isWaiting($0.state) }) else {
                    FileHandle.standardError.write("SIM WAIT REMINDER missing-session\n".data(using: .utf8)!)
                    NSApp.terminate(nil)
                    exit(2)
                }
                let key = self.noticeKey(waiting)
                let reminded = self.activeWorkNotice?.session.id == waiting.id
                    && self.bubbleView.text.contains("รอคำตอบมา")
                let firstCount = self.waitingReminderSent.count

                self.sessPoll = 0
                self.pollSessions(1)
                let once = firstCount == 1 && self.waitingReminderSent.count == 1
                    && self.workNoticeQueue.isEmpty

                self.openBubbleTarget()
                let acknowledged = self.acknowledgedWorkKeys.contains(key)
                    && self.workAlertCount == 0 && self.activeWorkNotice == nil

                let working = WorkSession(source: waiting.source, id: waiting.id,
                                          state: "working", name: waiting.name, cwd: "",
                                          message: "", updatedAt: Date().timeIntervalSince1970,
                                          contextPercent: waiting.contextPercent,
                                          focusURL: "", appPIDs: [], sessionID: "",
                                          topic: waiting.topic)
                self.detectWorkNotices([working])
                let reset = !self.acknowledgedWorkKeys.contains(key)
                    && !self.waitingReminderSent.contains(key)
                let ok = reminded && once && acknowledged && reset
                FileHandle.standardError.write(
                    ("SIM WAIT REMINDER reminded=\(reminded) once=\(once) "
                    + "acknowledged=\(acknowledged) reset=\(reset)\n")
                        .data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMWORKPOSES"] != nil {
            sessPoll = 9999
            motionReductionOverride = false
            motionLevel = .normal
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                self.sessPoll = 0
                self.pollSessions(1)
                guard let running = self.workSessions.first(where: {
                    ["working", "busy"].contains($0.state)
                }) else {
                    FileHandle.standardError.write("SIM WORK POSES missing-session\n".data(using: .utf8)!)
                    NSApp.terminate(nil)
                    exit(2)
                }
                let key = self.noticeKey(running)
                let watching = ["tilt", "sit"].contains(self.state)
                    && self.watchedLongWorkKeys.contains(key)
                let quiet = self.activeWorkNotice == nil && self.workNoticeQueue.isEmpty
                    && self.speakFor <= 0
                let firstCount = self.watchedLongWorkKeys.count

                self.sessPoll = 0
                self.pollSessions(1)
                let once = firstCount == 1 && self.watchedLongWorkKeys.count == 1

                let done = WorkSession(source: running.source, id: running.id, state: "done",
                                       name: running.name, cwd: running.cwd, message: "",
                                       updatedAt: Date().timeIntervalSince1970,
                                       contextPercent: running.contextPercent,
                                       focusURL: running.focusURL, appPIDs: running.appPIDs,
                                       sessionID: running.sessionID, topic: running.topic)
                self.watchLongRunningWork([done], now: Date().timeIntervalSince1970)
                let reset = !self.watchedLongWorkKeys.contains(key)
                let ok = watching && quiet && once && reset
                FileHandle.standardError.write(
                    ("SIM WORK POSES watching=\(watching) quiet=\(quiet) "
                    + "once=\(once) reset=\(reset)\n")
                        .data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMBATCHDONE"] != nil {
            sessPoll = 9999
            speechOn = true
            motionReductionOverride = false
            motionLevel = .normal
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                self.activeWorkNotice = nil
                self.workNoticeQueue.removeAll()
                self.hearts.removeAll()
                let firstID = "codex-batch-one"
                let secondID = "codex-batch-two"
                self.previousSessionStates = [
                    "codex:\(firstID)": "working",
                    "codex:\(secondID)": "working"
                ]
                self.didSeedSessionStates = true
                let now = Date().timeIntervalSince1970
                let sessions = [
                    WorkSession(source: "codex", id: firstID, state: "done",
                                name: "pixel-cat", cwd: "/tmp", message: "",
                                updatedAt: now - 1, contextPercent: 0,
                                focusURL: "codex://threads/\(firstID)", appPIDs: [],
                                sessionID: "", topic: "งานแรก"),
                    WorkSession(source: "codex", id: secondID, state: "done",
                                name: "pixel-cat", cwd: "/tmp", message: "",
                                updatedAt: now, contextPercent: 0,
                                focusURL: "codex://threads/\(secondID)", appPIDs: [],
                                sessionID: "", topic: "งานที่สอง")
                ]
                self.detectWorkNotices(sessions)
                let notices = [self.activeWorkNotice].compactMap { $0 } + self.workNoticeQueue
                let grouped = self.activeWorkNotice?.kind == .batchDone
                    && self.bubbleView.text.contains("2 งานเสร็จพร้อมกัน")
                let stars = self.hearts.contains { $0.isStar }
                let once = notices.filter { $0.kind == .batchDone }.count == 1
                let targets = notices.count == 1 && notices.first?.session.id == secondID
                let ok = grouped && stars && once && targets
                FileHandle.standardError.write(
                    ("SIM BATCH DONE grouped=\(grouped) stars=\(stars) "
                    + "once=\(once) targets=\(targets)\n")
                        .data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMWORKNOTICE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                self.speechOn = true
                // งานจริงของกริชอาจจุด notice/rescue ไปแล้วก่อน sim เริ่ม ต้องล้างก่อนวัด
                self.activeWorkNotice = nil
                self.workNoticeQueue.removeAll()
                self.activeContextRescue = nil
                self.contextRescueOffered.removeAll()
                self.workSessions = []
                let sid = "12345678-1234-1234-1234-123456789abc"
                self.previousSessionStates = ["claude:\(sid)": "working"]
                self.didSeedSessionStates = true
                let done = WorkSession(source: "claude", id: sid, state: "idle", name: "pixel-cat",
                                       cwd: "/tmp", message: "", updatedAt: Date().timeIntervalSince1970,
                                       contextPercent: 20, focusURL: "", appPIDs: [], sessionID: sid,
                                       topic: "")
                self.detectWorkNotices([done])
                let targeted = self.activeWorkNotice?.session.id == sid
                let clickable = self.bubbleView.interactive && !self.bubbleWindow.ignoresMouseEvents
                let named = self.bubbleView.text.contains("pixel-cat")
                    && self.bubbleView.text.contains("คลิกเปิด")
                let animated = self.activeWorkNotice?.kind == .done && self.noticeMotionFor > 0
                let claudeOK = targeted && clickable && named && animated

                self.activeWorkNotice = nil
                self.workNoticeQueue.removeAll()
                self.noticeMotionFor = 0
                self.speakFor = 0
                let cid = "codex-finished-task"
                self.previousSessionStates = ["codex:\(cid)": "working"]
                let codexDone = WorkSession(source: "codex", id: cid, state: "done",
                                            name: "pixel-cat", cwd: "/tmp", message: "",
                                            updatedAt: Date().timeIntervalSince1970,
                                            contextPercent: 0,
                                            focusURL: "codex://threads/\(cid)", appPIDs: [],
                                            sessionID: "", topic: "รวมกล่องงาน")
                self.detectWorkNotices([codexDone])
                let codexTargeted = self.activeWorkNotice?.session.source == "codex"
                    && self.activeWorkNotice?.session.id == cid
                let codexNamed = self.bubbleView.text.contains("รวมกล่องงาน")
                    && self.bubbleView.text.contains("เปิด Codex")
                let codexJump = self.activeWorkNotice?.session.focusURL
                    == "codex://threads/\(cid)"
                let doneCard = self.bubbleView.actions == [
                    SmartBubbleAction(id: .open, title: "เปิดงาน"),
                    SmartBubbleAction(id: .summarize, title: "สรุปให้")
                ]
                if let path = ProcessInfo.processInfo.environment["PIXELCAT_SMART_ACTION_PREVIEW"] {
                    let bounds = self.bubbleView.bounds
                    if let rep = self.bubbleView.bitmapImageRepForCachingDisplay(in: bounds) {
                        self.bubbleView.cacheDisplay(in: bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: path))
                        }
                    }
                }
                self.performSmartBubbleAction(.summarize)
                let summaryCopied = self.lastSimulatedActionPrompt.contains("สรุปผลลัพธ์")
                let summaryOpened = self.lastSimulatedOpenURL == "codex://threads/\(cid)"

                let failedID = "codex-failed-task"
                self.previousSessionStates = ["codex:\(failedID)": "working"]
                let failed = WorkSession(source: "codex", id: failedID, state: "failed",
                                         name: "pixel-cat", cwd: "/tmp",
                                         message: "tests exited 1",
                                         updatedAt: Date().timeIntervalSince1970,
                                         contextPercent: 0,
                                         focusURL: "codex://threads/\(failedID)", appPIDs: [],
                                         sessionID: "", topic: "แก้ regression")
                self.detectWorkNotices([failed])
                let failedCard = self.bubbleView.actions == [
                    SmartBubbleAction(id: .open, title: "เปิดงาน"),
                    SmartBubbleAction(id: .helpFix, title: "ช่วยแก้")
                ]
                self.performSmartBubbleAction(.helpFix)
                let helpCopied = self.lastSimulatedActionPrompt.contains("tests exited 1")
                    && self.lastSimulatedActionPrompt.contains("รันทดสอบ")
                let helpOpened = self.lastSimulatedOpenURL == "codex://threads/\(failedID)"

                let waitingID = "claude-waiting-task"
                self.previousSessionStates = ["claude:\(waitingID)": "working"]
                let waiting = WorkSession(source: "claude", id: waitingID, state: "input",
                                          name: "pixel-cat", cwd: "/tmp", message: "เลือกสี",
                                          updatedAt: Date().timeIntervalSince1970 - 240,
                                          contextPercent: 30, focusURL: "", appPIDs: [],
                                          sessionID: waitingID, topic: "รอเลือกสี")
                self.detectWorkNotices([waiting])
                let waitingCard = self.bubbleView.actions == [
                    SmartBubbleAction(id: .open, title: "เปิดตอบ"),
                    SmartBubbleAction(id: .later, title: "ไว้ทีหลัง")
                ]
                self.performSmartBubbleAction(.later)
                let snoozed = (self.snoozedWorkUntil["claude:\(waitingID)"] ?? 0)
                    > Date().timeIntervalSince1970 + 250
                let ok = claudeOK && codexTargeted && codexNamed && codexJump
                FileHandle.standardError.write(
                    ("SIM WORK NOTICE claude=\(claudeOK) codex=\(codexTargeted) "
                    + "codexNamed=\(codexNamed) codexJump=\(codexJump)\n")
                        .data(using: .utf8)!
                )
                FileHandle.standardError.write(
                    ("SIM SMART ACTION doneCard=\(doneCard) summaryCopied=\(summaryCopied) "
                    + "summaryOpened=\(summaryOpened)\n").data(using: .utf8)!
                )
                FileHandle.standardError.write(
                    ("SIM SMART ACTION STATUS failedCard=\(failedCard) helpCopied=\(helpCopied) "
                    + "helpOpened=\(helpOpened) waitingCard=\(waitingCard) snoozed=\(snoozed)\n")
                        .data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok || !doneCard || !summaryCopied || !summaryOpened
                    || !failedCard || !helpCopied || !helpOpened || !waitingCard || !snoozed {
                    exit(2)
                }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMWORKEMOTIONS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                self.speechOn = true
                self.motionReductionOverride = false
                self.motionLevel = .normal
                self.sessPoll = 9999
                self.inboxPoll = 9999
                self.checkIn = 9999
                self.geckoIn = 9999
                self.pounceCool = 9999
                self.state = "sit"
                // งานจริงของกริชอาจจุด notice/rescue ไปแล้วก่อน sim เริ่ม ต้องล้างก่อนวัด
                self.activeWorkNotice = nil
                self.workNoticeQueue.removeAll()
                self.activeContextRescue = nil
                self.contextRescueOffered.removeAll()
                self.workSessions = []

                let sid = "87654321-4321-4321-4321-cba987654321"
                self.previousSessionStates = ["claude:\(sid)": "working"]
                self.didSeedSessionStates = true
                let done = WorkSession(source: "claude", id: sid, state: "idle", name: "pixel-cat",
                                       cwd: "/tmp", message: "", updatedAt: Date().timeIntervalSince1970,
                                       contextPercent: 20, focusURL: "", appPIDs: [], sessionID: sid,
                                       topic: "")
                self.detectWorkNotices([done])
                let doneAnticipation = self.state == "crouch"
                var doneLift: CGFloat = 0
                for phase in 0..<6 {
                    self.noticeMotionFor = 2.4 - Double(phase) / 10.0
                    self.applyFrame()
                    doneLift = max(doneLift, self.view.motionY)
                }
                self.noticeMotionFor = 1.6
                self.applyFrame()
                let doneSettled = self.view.motionX == 0 && self.view.motionY == 0
                self.tick(0.20)
                let doneJump = self.state == "jump"
                self.tick(0.43)
                let doneTailUpSettle = self.state == "stretch"
                self.tick(0.20)
                let doneSat = self.state == "sit"
                let doneSequence = doneAnticipation && doneJump && doneTailUpSettle && doneSat
                if let dir = ProcessInfo.processInfo.environment["PIXELCAT_EMOTION_PREVIEW_DIR"] {
                    self.snapshot(to: dir + "/done.png", pose: self.state,
                                  text: self.bubbleView.text)
                }

                self.activeWorkNotice = nil
                self.workNoticeQueue.removeAll()
                self.noticeMotionFor = 0
                self.speakFor = 0
                self.handleClaude(event: "fail", message: "คำสั่งพังแล้ว")
                self.applyFrame()
                let failShake = abs(self.view.motionX)
                let failDroop = self.state == "tilt"
                self.noticeMotionFor = 1.6
                self.tick(0.50)
                self.applyFrame()
                let failSettled = self.view.motionX == 0
                let doneVisible = doneLift >= 6 && doneLift <= 8 && doneSettled
                let failNoShake = failShake == 0 && failSettled
                let failExpression = failDroop && self.state == "sit" && self.view.showTears
                if let dir = ProcessInfo.processInfo.environment["PIXELCAT_EMOTION_PREVIEW_DIR"] {
                    self.snapshot(to: dir + "/failed.png", pose: self.state,
                                  text: "คำสั่งพังแล้ว")
                }
                FileHandle.standardError.write(
                    ("SIM WORK EMOTIONS doneLift=\(Int(doneLift)) doneSettled=\(doneSettled) "
                    + "doneVisible=\(doneVisible) doneSequence=\(doneSequence) "
                    + "failShake=\(Int(failShake)) failSettled=\(failSettled) "
                    + "failNoShake=\(failNoShake) failExpression=\(failExpression) "
                    + "failPose=\(self.state)\n")
                        .data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !doneVisible || !doneSequence || !failNoShake || !failExpression { exit(2) }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMPET"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.startPetting()
                var log = "SIM ลูบ → state=\(self.state) petting=\(self.petting) held=\(self.held)\n"
                for i in 0..<200 {
                    if i % 14 == 0 { self.petStroke() }
                    self.tick(1.0 / 60.0)
                    if i % 40 == 0 {
                        log += String(format: "SIM t=%.1fs  %-8@ หัวใจ %d ดวง  หน้าต่างหัวใจ %.0f,%.0f visible=%@\n",
                                      Double(i)/60, self.state as NSString, self.hearts.count,
                                      self.heartWindow.frame.minX, self.heartWindow.frame.minY,
                                      (self.heartWindow.isVisible ? "Y":"n") as NSString)
                    }
                }
                let r = self.heartsView.bounds
                if let rep = self.heartsView.bitmapImageRepForCachingDisplay(in: r) {
                    self.heartsView.cacheDisplay(in: r, to: rep)
                    if let d = rep.representation(using: .png, properties: [:]) {
                        try? d.write(to: URL(fileURLWithPath: "hearts-snap.png"))
                    }
                }
                self.stopPetting()
                log += "SIM หยุดลูบ → state=\(self.state) petting=\(self.petting)\n"
                FileHandle.standardError.write(log.data(using: .utf8)!)
                NSApp.terminate(nil)
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMTHROW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.throwBall()
                var log = String(format: "SIM โยนบอล → ballOn=%@ bx=%.0f by=%.0f\n",
                                 (self.ballOn ? "Y" : "n") as NSString, self.bx, self.by)
                for i in 0..<180 {
                    self.tick(1.0 / 60.0)
                    if i % 30 == 0 {
                        let w = self.ballWindow
                        log += String(format: "SIM t=%.1fs  บอล x=%.0f y=%.0f | หน้าต่างบอล %.0f,%.0f %.0fx%.0f alpha=%.1f visible=%@ img=%@\n",
                                      Double(i)/60, self.bx, self.by,
                                      w.frame.minX, w.frame.minY, w.frame.width, w.frame.height,
                                      w.alphaValue, (w.isVisible ? "Y":"n") as NSString,
                                      (self.ballView.image != nil ? "Y":"n") as NSString)
                    }
                }
                FileHandle.standardError.write(log.data(using: .utf8)!)
                NSApp.terminate(nil)
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMBALL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.refreshPlatforms()
                let floor = self.platforms.first(where: { $0.isFloor })!
                self.plat = floor
                self.x = floor.minX + 300; self.y = floor.y
                self.platRefresh = 9999
                self.bx = floor.minX + 700; self.by = floor.y + 260
                self.bvx = -40; self.bvy = 0
                self.ballOn = true; self.ballLife = 90; self.ballHits = 0
                if ProcessInfo.processInfo.environment["PIXELCAT_SIMBALL"] == "gecko" {
                    self.ballOn = false
                    self.geckoIn = 0.1
                    self.setState("sleep", duration: 9999)      // ให้น้องหลับอยู่ก่อน
                }
                self.pickIdle()
                var log = String(format: "SIM บอลปล่อยที่ x=%.0f y=%.0f (พื้น=%.0f) แมวอยู่ x=%.0f\n",
                                 self.bx, self.by, floor.y, self.x)
                log += "SIM หลัง pickIdle → state=\(self.state) target=\(self.target.map { String(format: "%.0f", $0) } ?? "-")\n"
                var swats = 0
                for i in 0..<900 {
                    let before = self.ballHits
                    self.tick(1.0 / 60.0)
                    if self.ballHits > before { swats += 1 }
                    if i % 60 == 0 {
                        log += String(format: "SIM t=%ds  แมว %-8@ x=%.0f hurry=%@ | บอล x=%.0f y=%.0f | จิ้งจก on=%@ x=%.0f y=%.0f\n",
                                      i / 60, self.state as NSString, self.x,
                                      (self.hurry ? "Y" : "n") as NSString,
                                      self.bx, self.by,
                                      (self.geckoOn ? "Y" : "n") as NSString, self.gx, self.gy)
                    }
                }
                log += "SIM จบ: ตบทั้งหมด \(swats) ครั้ง  บอลยังอยู่=\(self.ballOn)\n"
                FileHandle.standardError.write(log.data(using: .utf8)!)
                NSApp.terminate(nil)
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.refreshPlatforms()
                let floor = self.platforms.first(where: { $0.isFloor })!
                let tall = ProcessInfo.processInfo.environment["PIXELCAT_SIMTEST"] == "wall"
                let ledgeY = floor.y + (tall ? 700 : 210)
                self.platforms.append(Platform(y: ledgeY, minX: floor.minX + 350,
                                               maxX: floor.minX + 1100, isFloor: false,
                                               bottom: floor.y - 20))
                self.plat = floor
                self.x = floor.minX + 400
                self.y = floor.y
                self.platRefresh = 9999
                var log = String(format: "SIM พื้น=%.0f  ขอบจำลอง=%.0f  แมวเริ่มที่ x=%.0f y=%.0f\n",
                                 floor.y, ledgeY, self.x, self.y)
                let climbed = self.maybeClimb()
                log += "SIM maybeClimb=\(climbed) → state=\(self.state)  (ขอบสูงจากพื้น \(Int(ledgeY - floor.y)) pt)\n"
                var reachedLedge = false
                for i in 0..<480 {
                    self.tick(1.0 / 60.0)
                    if i % 24 == 0 {
                        log += String(format: "SIM t=%.2fs  %-8@ y=%.0f x=%.0f %@\n",
                                      Double(i) / 60, self.state as NSString, self.y, self.x,
                                      (self.airborne ? "ลอย" : (self.climbing ? "ไต่" : "-")) as NSString)
                    }
                    // ยืนยันผลทันทีที่ลงบนขอบสำเร็จ ก่อน pickIdle จะสุ่มพฤติกรรมถัดไป
                    // (เช่น เดินไปกระโดดลง) ซึ่งไม่ใช่ส่วนของการทดสอบปีนขึ้น
                    if !self.airborne, !self.climbing, !self.plat.isFloor,
                       abs(self.y - ledgeY) < 2 {
                        reachedLedge = true
                        break
                    }
                }
                log += String(format: "SIM ปีนเสร็จ: y=%.0f ยืนบน=%@\n", self.y,
                              (reachedLedge ? "ขอบหน้าต่าง" : "พื้น") as NSString)
                let desc = self.maybeDescend()
                log += "SIM maybeDescend=\(desc) → state=\(self.state)\n"
                for i in 0..<900 {
                    self.tick(1.0 / 60.0)
                    if i % 45 == 0 {
                        log += String(format: "SIM ลง t=%.2fs  %-8@ y=%.0f x=%.0f air=%@\n",
                                      Double(i) / 60, self.state as NSString, self.y, self.x,
                                      (self.airborne ? "ลอย" : "-") as NSString)
                    }
                    if !self.airborne && self.plat.isFloor && i > 60 { break }
                }
                log += String(format: "SIM จบ: y=%.0f ยืนบน=%@\n", self.y,
                              (self.plat.isFloor ? "พื้น ✓" : "ขอบหน้าต่าง ✗") as NSString)
                FileHandle.standardError.write(log.data(using: .utf8)!)
                NSApp.terminate(nil)
            }
        }

        // --snapshot out.png [ท่า] [ข้อความ] — วาดนอกจอแล้วออก
        // ทำให้ตรวจงานได้โดยไม่ต้องมีคนดูจอ และไม่ต้องขอสิทธิ์ screen recording
        let argv = CommandLine.arguments
        if let i = argv.firstIndex(of: "--snapshot"), i + 1 < argv.count {
            let out = argv[i + 1]
            let pose = i + 2 < argv.count ? argv[i + 2] : "sit"
            let text = i + 3 < argv.count ? argv[i + 3] : ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.snapshot(to: out, pose: pose, text: text)
                NSApp.terminate(nil)
            }
            return
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SNAP"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                self.setState("sit", duration: 99)
                self.applyFrame()
                let r = self.view.bounds
                if let rep = self.view.bitmapImageRepForCachingDisplay(in: r) {
                    self.view.cacheDisplay(in: r, to: rep)
                    if let d = rep.representation(using: .png, properties: [:]) {
                        try? d.write(to: URL(fileURLWithPath: "view-snap.png"))
                    }
                }
                self.say("หิวจัง เมี๊ยววว", for: 9)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let br = self.bubbleView.bounds
                    FileHandle.standardError.write("DEBUG bubble=\(self.bubbleWindow.frame)\n".data(using: .utf8)!)
                self.refreshPlatforms()
                var pl = "DEBUG platforms=\(self.platforms.count)\n"
                for p in self.platforms.sorted(by: { $0.y > $1.y }).prefix(8) {
                    pl += String(format: "   %@ y=%.0f  x=%.0f…%.0f\n", p.isFloor ? "floor " : "window", p.y, p.minX, p.maxX)
                }
                pl += "DEBUG standing on y=\(self.plat.y) airborne=\(self.airborne)\n"
                FileHandle.standardError.write(pl.data(using: .utf8)!)
                    if let rep = self.bubbleView.bitmapImageRepForCachingDisplay(in: br) {
                        self.bubbleView.cacheDisplay(in: br, to: rep)
                        if let d = rep.representation(using: .png, properties: [:]) {
                            try? d.write(to: URL(fileURLWithPath: "bubble-snap.png"))
                        }
                    }
                    NSApp.terminate(nil)
                }
            }
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMCHATRESILIENCE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let snapshot = CompanionSnapshot(
                    activeApp: "Finder", userIdleSeconds: 4, workingCount: 0,
                    waitingCount: 0, attentionCount: 0, hottestContext: 0,
                    focusActive: false, recentEvent: "", workBriefs: []
                )
                let quotaReply = CompanionChatResilience.claudeCLIFailure(
                    stdout: "You've hit your session limit · resets 7:10pm (Asia/Bangkok)",
                    stderr: "", status: 1
                )
                let claudeQuota = quotaReply.contains("พักถึง 7:10pm")
                    && !quotaReply.lowercased().contains("exit")
                let manusReply = CompanionChatResilience.visibleFailure(
                    providerFailure: "ไม่ได้ตั้ง PIXELCAT_MANUS_API_KEY",
                    message: "คิดถึงน้องจัง", snapshot: snapshot
                )
                let manusMissing = manusReply.contains("น้องก็คิดถึง")
                    && !manusReply.contains("API") && !manusReply.contains("Manus")
                let rawReply = CompanionChatResilience.visibleFailure(
                    providerFailure: "claude CLI จบด้วย exit 1",
                    message: "สวัสดี", snapshot: snapshot
                )
                let rawLower = rawReply.lowercased()
                let rawHidden = !rawLower.contains("exit") && !rawLower.contains("cli")
                    && !rawLower.contains("api") && !rawLower.contains("http")
                let localReply = CompanionChatResilience.localReply(
                    to: "วันนี้เหนื่อยมาก", snapshot: snapshot
                )
                let localNatural = localReply.contains("พ่อ") && !localReply.contains("กริช")
                let ok = claudeQuota && manusMissing && rawHidden && localNatural
                FileHandle.standardError.write(
                    ("SIM CHAT RESILIENCE claudeQuota=\(claudeQuota) "
                    + "manusMissing=\(manusMissing) rawHidden=\(rawHidden) "
                    + "localNatural=\(localNatural)\n").data(using: .utf8)!
                )
                NSApp.terminate(nil)
                if !ok { exit(2) }
            }
            return
        }

        // ยิงสมองที่เลือกจริงหนึ่งครั้ง แล้วตรวจว่าประวัติ handoff กดย้อนหลังได้
        if ProcessInfo.processInfo.environment["PIXELCAT_BRAINTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                var out = "BRAINTEST brain=\(self.companionBrain.label)"
                out += " provider=\(self.activeCompanion?.brandName ?? "none")\n"

                // 1) prompt ต้องมีงานจริงอยู่ในนั้น
                let snapshot = CompanionSnapshot(
                    activeApp: "Warp", userIdleSeconds: 12, workingCount: 1, waitingCount: 1,
                    attentionCount: 0, hottestContext: 91, focusActive: false,
                    recentEvent: "เปิดใช้ Warp",
                    workBriefs: ["Claude Code • pixel-cat • กำลังทำงาน • context 91% • หัวข้อ: ต่อสมอง Claude",
                                 "Codex • ledger-api • รอคำตอบ • context 40%"])
                let block = snapshot.contextBlock
                out += "BRAINTEST context_has_work=\(block.contains("pixel-cat"))"
                out += " has_topic=\(block.contains("หัวข้อ"))"
                out += " has_open_work=\(block.contains("open_work:"))\n"

                // 2) ประวัติ handoff — บันทึกแล้วต้องอ่านกลับมาได้จากดิสก์
                let fake = WorkSession(source: "claude", id: "brain-1", state: "working",
                                       name: "/Users/test/pixel-cat", cwd: "/Users/test/pixel-cat",
                                       message: "ทดสอบ", updatedAt: Date().timeIntervalSince1970,
                                       contextPercent: 93, focusURL: "", appPIDs: [],
                                       sessionID: "s1", topic: "ต่อสมอง Claude")
                self.rescueHistory.removeAll()
                if let rescue = self.makeContextRescue(for: fake) {
                    self.rememberRescue(rescue)
                    self.rememberRescue(rescue)   // เสนอซ้ำต้องไม่เพิ่มรายการ
                }
                let stored = UserDefaults.standard.array(forKey: Self.rescueHistoryKey) as? [[String: Any]] ?? []
                let reloaded = stored.compactMap(SavedRescue.init(dictionary:))
                out += "BRAINTEST history_count=\(self.rescueHistory.count) persisted=\(reloaded.count)"
                out += " has_handoff=\(reloaded.first.map { !$0.handoff.isEmpty } ?? false)"
                out += " title=[\(reloaded.first?.title ?? "-")]\n"
                let menuCount = self.makeRescueHistoryMenu().submenu?.items.count ?? 0
                out += "BRAINTEST menu_items=\(menuCount)\n"
                FileHandle.standardError.write(out.data(using: .utf8)!)

                // 3) ยิงสมองจริง ถ้ามี — offline ใช้ใน regression จะได้ไม่กินโควตาและไม่ต้องรอเน็ต
                // ความทรงจำต้องเข้า prompt และสะสมข้ามการเปิดปิดแอปได้
                self.companionMemory.forgetConversation()
                self.companionMemory.record(fromDad: true, text: "พ่อทดสอบความจำ")
                self.companionMemory.record(fromDad: false, text: "น้องจำได้ค่ะ")
                let reloadedMemory = CompanionMemory.load()
                let mem = self.companionMemory.block
                var m = "BRAINTEST mem_turns=\(reloadedMemory.turns.count)"
                m += " mem_has_history=\(mem.contains("พ่อทดสอบความจำ"))"
                m += " mem_has_age=\(mem.contains("อายุของน้อง"))"
                m += " mem_has_gap=\(mem.contains("คุยกัน") || mem.contains("ครั้งแรก"))"
                m += " age=\(self.companionMemory.ageText) days=\(self.companionMemory.daysTogether)\n"
                let prompt = CompanionPersona.chatPrompt(memory: self.companionMemory,
                                                         snapshot: snapshot, message: "สวัสดี")
                m += "BRAINTEST prompt_is_cat=\(prompt.contains("แมวสาวอายุสองขวบ"))"
                m += " prompt_says_dad=\(prompt.contains("เรียกกริชว่า \"พ่อ\""))"
                m += " prompt_no_ai_claim=\(!prompt.contains("ซื่อสัตย์ว่าเป็น AI"))"
                m += " prompt_has_memory=\(prompt.contains("[ความทรงจำของน้อง]"))\n"
                FileHandle.standardError.write(m.data(using: .utf8)!)

                if ProcessInfo.processInfo.environment["PIXELCAT_BRAINTEST"] == "offline" {
                    FileHandle.standardError.write("BRAINTEST reply=SKIPPED_OFFLINE\n".data(using: .utf8)!)
                    NSApp.terminate(nil); return
                }
                guard let provider = self.activeCompanion else {
                    FileHandle.standardError.write("BRAINTEST reply=SKIPPED_NO_PROVIDER\n".data(using: .utf8)!)
                    NSApp.terminate(nil); return
                }
                // คุยสองรอบติดกัน รอบสองต้องอ้างถึงรอบแรกได้ ถึงจะเรียกว่าจำได้จริง
                let first = "น้องจำไว้นะ ของโปรดของพ่อคือปลาทูทอด"
                let second = "เมื่อกี้พ่อบอกว่าของโปรดพ่อคืออะไรนะ"
                let started = Date()
                provider.chat(message: first, memory: self.companionMemory,
                              snapshot: snapshot) { outcome in
                    guard case .reply(let reply1) = outcome else {
                        if case .failure(let reason) = outcome {
                            FileHandle.standardError.write("BRAINTEST reply=FAIL reason=\(reason)\n"
                                .data(using: .utf8)!)
                        }
                        NSApp.terminate(nil); return
                    }
                    self.companionMemory.record(fromDad: true, text: first)
                    self.companionMemory.record(fromDad: false, text: reply1)
                    FileHandle.standardError.write("BRAINTEST turn1=\(reply1)\n".data(using: .utf8)!)

                    self.provider2(provider, message: second, snapshot: snapshot) { reply2 in
                        let secs = String(format: "%.1f", Date().timeIntervalSince(started))
                        let remembered = reply2.contains("ปลาทู")
                        let line = "BRAINTEST turn2=\(reply2)\nBRAINTEST reply=OK secs=\(secs)"
                            + " remembered=\(remembered) turns_saved=\(self.companionMemory.turns.count)"
                            + " age=\(self.companionMemory.ageText) days=\(self.companionMemory.daysTogether)\n"
                        FileHandle.standardError.write(line.data(using: .utf8)!)
                        NSApp.terminate(nil)
                    }
                }
            }
            return
        }

        // เทียบกล่องพิมพ์กับกรอบคำพูดว่าเป็นกรอบเดียวกันจริง โดยไม่ต้องนั่งดูหน้าจอ
        if ProcessInfo.processInfo.environment["PIXELCAT_SNAPCHAT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                self.setState("sit", duration: 99)
                self.applyFrame()
                self.openCompanionChat()
                if ProcessInfo.processInfo.environment["PIXELCAT_SIMTHINKING"] != nil {
                    self.chatWindow?.orderOut(nil)
                    self.chatBusy = true
                    self.motionReductionOverride = false
                    self.focusPhase = .idle
                    self.beginCompanionThinking()
                    let listen = self.thinkingCycle.phase == .listening
                        && self.state == "tilt"

                    var dotMessages = Set<String>()
                    for _ in 0..<4 {
                        self.updateCompanionThinking(0.45)
                        dotMessages.insert(self.lastThinkingMessage)
                    }
                    let dots = dotMessages.contains("อั่งเปากำลังคิด·")
                        && dotMessages.contains("อั่งเปากำลังคิด··")
                        && dotMessages.contains("อั่งเปากำลังคิด···")
                    self.updateCompanionThinking(7.0)
                    let long = self.thinkingCycle.phase == .longThinking
                        && self.lastThinkingMessage == "ขอคิดอีกนิดนะ…"

                    let starsBefore = self.hearts.count
                    self.finishCompanionThinking(success: true, message: "นึกออกแล้ว", seconds: 2)
                    let success = self.thinkingCycle.phase == .idle && !self.chatBusy
                        && ["aha", "stretch"].contains(self.state)
                        && self.hearts.count > starsBefore

                    self.chatBusy = true
                    self.beginCompanionThinking()
                    self.updateCompanionThinking(0.6)
                    self.finishCompanionThinking(success: false, message: "ต่อไม่สำเร็จ", seconds: 2)
                    let failure = self.thinkingCycle.phase == .idle && self.state == "tilt"

                    let starsAfterFailure = self.hearts.count
                    self.motionReductionOverride = true
                    self.chatBusy = true
                    self.beginCompanionThinking()
                    self.updateCompanionThinking(0.6)
                    let reducedThinking = self.state == "sit"
                    self.finishCompanionThinking(success: true, message: "ตอบแบบนิ่ง", seconds: 2)
                    let reduced = reducedThinking && self.state == "sit"
                        && self.hearts.count == starsAfterFailure

                    self.motionReductionOverride = false
                    self.focusPhase = .focus
                    self.focusRemaining = 120
                    self.setState("sit", duration: 120)
                    self.chatBusy = true
                    self.beginCompanionThinking()
                    self.updateCompanionThinking(0.6)
                    self.finishCompanionThinking(success: true, message: "ตอบในโฟกัส", seconds: 2)
                    let focus = self.state == "sit" && self.focusPhase == .focus
                    self.focusPhase = .idle

                    let noticeSession = WorkSession(
                        source: "codex", id: "thinking-notice", state: "done",
                        name: "pixel-cat", cwd: "/tmp", message: "", updatedAt: 1,
                        contextPercent: 0, focusURL: "codex://threads/thinking-notice",
                        appPIDs: [], sessionID: "", topic: "งานระหว่างคิด")
                    self.workNoticeQueue.removeAll()
                    self.activeWorkNotice = WorkNotice(session: noticeSession, kind: .done,
                                                       text: "งานระหว่างคิดเสร็จแล้ว")
                    self.bubbleTarget = noticeSession
                    self.speakFor = 8
                    self.chatBusy = true
                    self.beginCompanionThinking()
                    let pausedNotice = self.activeWorkNotice == nil
                        && self.workNoticeQueue.first?.session.id == noticeSession.id
                    self.finishCompanionThinking(success: true, message: "คำตอบต้องไม่ถูกทับ", seconds: 5)
                    self.showNextWorkNotice()
                    let notice = pausedNotice && self.activeWorkNotice == nil
                        && self.workNoticeQueue.first?.session.id == noticeSession.id
                        && self.bubbleView.text == "คำตอบต้องไม่ถูกทับ"
                    let sitSpans = Array(Sheet.shared.spans[16...19])
                    let newSpans = Array(Sheet.shared.spans[59...64])
                    let sitLo = sitSpans.map(\.0).min() ?? 0
                    let sitHi = sitSpans.map(\.1).max() ?? (SPRITE_W - 1)
                    let shadow = newSpans.allSatisfy {
                        $0.0 >= sitLo - 2 && $0.1 <= sitHi + 2
                    }
                    let stopped = self.thinkingCycle.phase == .idle && !self.chatBusy

                    let ok = listen && dots && long && success && failure && reduced
                        && focus && notice && shadow && stopped
                    FileHandle.standardError.write(
                        ("SIM THINKING listen=\(listen) dots=\(dots) long=\(long) "
                        + "success=\(success) failure=\(failure) reduced=\(reduced) "
                        + "focus=\(focus) notice=\(notice) shadow=\(shadow) "
                        + "stopped=\(stopped)\n").data(using: .utf8)!
                    )
                    NSApp.terminate(nil)
                    if !ok { exit(2) }
                    return
                }
                let sample = "วันนี้งานเป็นไงบ้าง"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.chatInput?.stringValue = sample
                    self.chatWindow?.fieldEditor(false, for: self.chatInput)?.string = sample
                    self.resizeChatBubble(to: ChatBubbleInputView.width(for: sample))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let content = self.chatWindow?.contentView else { NSApp.terminate(nil); return }
                    let r = content.bounds
                    if let rep = content.bitmapImageRepForCachingDisplay(in: r) {
                        content.cacheDisplay(in: r, to: rep)
                        if let d = rep.representation(using: .png, properties: [:]) {
                            try? d.write(to: URL(fileURLWithPath: "chat-input-snap.png"))
                        }
                    }
                    var out = "SNAPCHAT input=\(self.chatWindow?.frame ?? .zero) chars=\(self.chatInput?.stringValue.count ?? -1)\n"
                    self.chatWindow?.orderOut(nil)
                    self.say("วันนี้งานเดินดีเลยนะกริช", for: 9)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let br = self.bubbleView.bounds
                        if let rep = self.bubbleView.bitmapImageRepForCachingDisplay(in: br) {
                            self.bubbleView.cacheDisplay(in: br, to: rep)
                            if let d = rep.representation(using: .png, properties: [:]) {
                                try? d.write(to: URL(fileURLWithPath: "chat-speech-snap.png"))
                            }
                        }
                        out += "SNAPCHAT speech=\(self.bubbleWindow.frame)\n"
                        FileHandle.standardError.write(out.data(using: .utf8)!)
                        NSApp.terminate(nil)
                    }
                }
            }
            return
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let opaque = Sheet.shared.masks.map { $0.filter { $0 }.count }
                var out = "DEBUG frames=\(Sheet.shared.frames.count) opaquePx=\(opaque)\n"
                out += "DEBUG window=\(self.window.frame) visible=\(self.window.isVisible) level=\(self.window.level.rawValue)\n"
                out += "DEBUG screenVisible=\(self.currentScreen().visibleFrame) state=\(self.state) dir=\(self.dir)\n"
                out += "DEBUG hasImage=\(self.view.image != nil) maskOn=\(self.view.mask.filter { $0 }.count)\n"
                FileHandle.standardError.write(out.data(using: .utf8)!)
            }
        }

        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick(1.0 / 30.0)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        if let hotKey = companionHotKeyRef { UnregisterEventHotKey(hotKey) }
        if let handler = companionHotKeyHandler { RemoveEventHandler(handler) }
    }

    // MARK: menu

    private var reduceMotionEnabled: Bool {
        motionReductionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var effectiveMotionLevel: MotionLevel {
        reduceMotionEnabled ? .calm : motionLevel
    }

    private func makeMotionMenu() -> NSMenu {
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

    private func buildMenu() {
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
        menu.addItem(makeCompanionMenuItem())
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
        m.addItem(makeCompanionMenuItem())
        m.addItem(makeFileSearchMenuItem())

        // เด้งข้างตัวน้อง ถ้าชิดขอบขวาจอให้ไปโผล่ทางซ้ายแทน
        let f0 = window.frame
        let screenMaxX = window.screen?.visibleFrame.maxX ?? f0.maxX
        let onRight = f0.maxX + 190 < screenMaxX
        let at = NSPoint(x: onRight ? f0.maxX + 4 : f0.minX - 4, y: f0.maxY)
        m.popUp(positioning: nil, at: at, in: nil)
    }

    // MARK: Interactive Manus companion

    /// Carbon hot key ใช้งานได้ทั่วระบบโดยไม่ต้องขอ Accessibility/Input Monitoring
    private func registerCompanionHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let controller = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == PetController.companionHotKeySignature,
                      hotKeyID.id == 1 else { return OSStatus(eventNotHandledErr) }
                let pet = Unmanaged<PetController>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { pet.activateCompanionChatShortcut() }
                return noErr
            },
            1, &eventType, controller, &companionHotKeyHandler
        )
        guard handlerStatus == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: Self.companionHotKeySignature, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), hotKeyID,
            GetApplicationEventTarget(), 0, &companionHotKeyRef
        )
        companionHotKeyRegistered = registerStatus == noErr
        if !companionHotKeyRegistered, let handler = companionHotKeyHandler {
            RemoveEventHandler(handler)
            companionHotKeyHandler = nil
        }
    }

    @objc private func activateCompanionChatShortcut() {
        if let chatWindow, chatWindow.isVisible, let chatInput {
            NSApp.activate(ignoringOtherApps: true)
            chatWindow.makeKeyAndOrderFront(nil)
            chatWindow.makeFirstResponder(chatInput)
            return
        }
        openCompanionChat()
    }

    @objc private func openCompanionChat() {
        let width: CGFloat = 300
        if chatWindow == nil {
            let bubble = ChatBubbleInputView(width: width, target: self, action: #selector(sendCompanionChat))
            let w = CompanionInputPanel(contentRect: NSRect(origin: .zero, size: bubble.frame.size),
                                        styleMask: .borderless, backing: .buffered, defer: false)
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false                       // กรอบพิกเซลมีขอบของตัวเองอยู่แล้ว
            w.level = bubbleWindow.level
            w.collectionBehavior = window.collectionBehavior
            w.isReleasedWhenClosed = false
            w.contentView = bubble
            bubble.onWidthChange = { [weak self] newWidth in self?.resizeChatBubble(to: newWidth) }
            chatWindow = w
            chatInput = bubble.field
            chatSendButton = nil
        }
        chatInput?.stringValue = ""
        resizeChatBubble(to: ChatBubbleInputView.minWidth)
        guard let w = chatWindow else { return }
        w.level = bubbleWindow.level                  // ตามชั้นเดียวกับกรอบคำพูดเสมอ
        placeChatBubble()
        speakFor = 0
        companionReplyProtected = false
        hideBubble()                                  // อย่าให้คำพูดเดิมซ้อนกล่องพิมพ์
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.chatWindow, let input = self.chatInput else { return }
            window.makeFirstResponder(input)
            (input.currentEditor() as? NSTextView)?.insertionPointColor = PixelBubble.ink
        }
    }

    /// กล่องพิมพ์กับกรอบคำพูดยืนที่เดียวกัน พอกดส่งแล้ว "กำลังคิด" จึงเด้งขึ้นตรงนั้นพอดี
    private func placeChatBubble() {
        guard let w = chatWindow else { return }
        let size = w.frame.size
        let bx = (x + spriteW / 2 - size.width / 2).rounded()
        let by = (y + winH - 1).rounded()
        w.setFrameOrigin(NSPoint(x: bx, y: by))
    }

    private func resizeChatBubble(to width: CGFloat) {
        guard let w = chatWindow else { return }
        w.setContentSize(ChatBubbleInputView.size(width: width))
        placeChatBubble()
    }

    @objc private func sendCompanionChat() {
        guard !chatBusy, let input = chatInput else { return }
        let message = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        if let query = fileFinder.query(from: message) {
            input.stringValue = ""
            chatBusy = true
            chatSendButton?.isEnabled = false
            chatWindow?.orderOut(nil)
            beginCompanionThinking()
            lastFileSearchStayedLocal = true
            setCompanionConnectionStatus("กำลังค้นหาในเครื่อง")
            say("น้องกำลังดมหา \(String(query.prefix(48)))…", for: 120)
            let finder = fileFinder
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let results = finder.find(named: query)
                DispatchQueue.main.async {
                    guard let self, self.chatBusy else { return }
                    self.chatSendButton?.isEnabled = true
                    self.finishLocalFileSearch(query: query, results: results)
                }
            }
            return
        }
        input.stringValue = ""; chatBusy = true; chatSendButton?.isEnabled = false
        chatWindow?.orderOut(nil)
        beginCompanionThinking()
        let snapshot = localCompanionSnapshot()
        if let provider = activeCompanion {
            setCompanionConnectionStatus("กำลังคุยกับอั่งเปา")
            provider.chat(message: message, memory: companionMemory, snapshot: snapshot) { [weak self] outcome in
                guard let self else { return }
                self.chatSendButton?.isEnabled = true
                switch outcome {
                case .reply(let text):
                    self.setCompanionConnectionStatus("เชื่อมต่อแล้ว")
                    // จำทั้งสองฝั่งไว้ ครั้งหน้าน้องจะต่อบทเดิมได้
                    self.companionMemory.record(fromDad: true, text: message)
                    self.companionMemory.record(fromDad: false, text: text)
                    self.finishCompanionThinking(success: true, message: text, seconds: 10.0)
                case .failure(let reason):
                    self.setCompanionConnectionStatus("สมองออนไลน์พักอยู่ • ตอบแบบ local")
                    if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
                        FileHandle.standardError.write(
                            "COMPANION CHAT provider=\(provider.brandName) failure=\(String(reason.prefix(240)))\n"
                                .data(using: .utf8)!
                        )
                    }
                    let fallback = CompanionChatResilience.visibleFailure(
                        providerFailure: reason, message: message, snapshot: snapshot
                    )
                    // คุยไม่ติดก็ยังจำทั้งสิ่งที่พ่อพูดและคำตอบ local ไว้ให้บทต่อไปต่อเนื่อง
                    self.companionMemory.record(fromDad: true, text: message)
                    self.companionMemory.record(fromDad: false, text: fallback)
                    self.finishCompanionThinking(success: false, message: fallback, seconds: 8.0)
                }
            }
        } else {
            setCompanionConnectionStatus(brainUnavailableText)
            let reply = localChatReply(to: message, snapshot: snapshot)
            // ให้เห็นจังหวะรับฟัง/คิดแม้คำตอบ local จะพร้อมทันที
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, self.chatBusy else { return }
                self.chatSendButton?.isEnabled = true
                self.companionMemory.record(fromDad: true, text: message)
                self.companionMemory.record(fromDad: false, text: reply)
                self.finishCompanionThinking(success: true, message: reply, seconds: 8.0)
            }
        }
    }

    private func beginCompanionThinking() {
        // ผู้ใช้ตั้งใจเริ่มคุย: พัก notice ปัจจุบันไว้ก่อน แล้วค่อยแสดงใหม่หลังคำตอบจบ
        if let notice = activeWorkNotice {
            workNoticeQueue.insert(notice, at: 0)
            activeWorkNotice = nil
        }
        if let rescue = activeContextRescue {
            contextRescueOffered.remove(noticeKey(rescue.session))
            activeContextRescue = nil
        }
        bubbleTarget = nil
        fileSearchTarget = nil
        shepherdTarget = nil
        companionReplyProtected = false
        thinkingCycle.start()
        lastThinkingMessage = ""
        target = nil
        hurry = false
        if focusPhase == .idle, !held {
            setState(reduceMotionEnabled ? "sit" : "tilt", duration: 999)
        }
        refreshCompanionThinking(force: true)
    }

    private func finishLocalFileSearch(query: String, results: [URL]) {
        fileSearchResults = results
        refreshFileSearchMenu()
        setCompanionConnectionStatus("ค้นหาในเครื่องแล้ว")
        guard let first = results.first else {
            finishCompanionThinking(
                success: false,
                message: "น้องหา ‘\(String(query.prefix(48)))’ ในโฟลเดอร์ของพ่อไม่เจอค่ะ",
                seconds: 6.0
            )
            return
        }
        let folder = fileFinder.displayLocation(for: first)
        let more = results.count > 1 ? " • มีอีก \(results.count - 1) รายการในเมนู" : ""
        finishCompanionThinking(
            success: true,
            message: "เจอ \(first.lastPathComponent) ที่ \(folder)\(more) • คลิกเพื่อเปิดใน Finder",
            seconds: 12.0
        )
        guard speechOn else { return }
        fileSearchTarget = first
        bubbleView.interactive = true
        bubbleWindow.ignoresMouseEvents = false
    }

    private func revealFoundFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if ProcessInfo.processInfo.environment["PIXELCAT_SIMFILEFINDER"] != nil {
            lastSimulatedRevealPath = url.path
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func updateCompanionThinking(_ dt: Double) {
        guard chatBusy, thinkingCycle.phase != .idle else { return }
        let oldPhase = thinkingCycle.phase
        thinkingCycle.advance(by: dt)
        if oldPhase == .listening, thinkingCycle.phase == .thinking,
           focusPhase == .idle, !held {
            setState(reduceMotionEnabled ? "sit" : (POSES["think"] == nil ? "sit" : "think"),
                     duration: 999)
        }
        refreshCompanionThinking(force: oldPhase != thinkingCycle.phase)
    }

    private func refreshCompanionThinking(force: Bool = false) {
        let message = thinkingCycle.message
        guard !message.isEmpty, force || message != lastThinkingMessage else { return }
        lastThinkingMessage = message
        say(message, for: 120.0)
    }

    private func finishCompanionThinking(success: Bool, message: String, seconds: Double) {
        thinkingCycle.stop()
        lastThinkingMessage = ""
        chatBusy = false
        companionReplyProtected = speechOn
        guard focusPhase == .idle, !held else {
            if focusPhase != .idle { setState("sit", duration: max(1, focusRemaining)) }
            say(message, for: seconds)
            return
        }
        if success {
            if reduceMotionEnabled {
                setState("sit", duration: 1.4) { [weak self] in self?.pickIdle() }
            } else {
                let pose = POSES["aha"] == nil ? "stretch" : "aha"
                setState(pose, duration: 0.75) { [weak self] in
                    self?.setState("sit", duration: 2.0) { [weak self] in self?.pickIdle() }
                }
                CatVoice.shared.play(.trill, minGap: 2.0)
                let sparkleCount = effectiveMotionLevel == .playful ? 4 : 2
                for i in 0..<sparkleCount {
                    hearts.append(HeartsView.Heart(x: spriteW * (0.38 + CGFloat(i) * 0.1),
                                                   y: spriteW * 0.55,
                                                   vy: CGFloat(34 + i * 5), life: 0.8,
                                                   s: max(0.7, scale * 0.75), isStar: true))
                }
                stepHearts(0)
            }
        } else {
            setState(reduceMotionEnabled ? "sit" : "tilt", duration: 0.45) { [weak self] in
                self?.setState("sit", duration: 2.2) { [weak self] in self?.pickIdle() }
            }
        }
        say(message, for: seconds)
    }

    private func appendChat(_ text: String) {
        guard let transcript = chatTranscript else { return }
        transcript.textStorage?.append(NSAttributedString(string: text)); transcript.scrollToEndOfDocument(nil)
    }

    private func removeThinkingLine() {
        guard let transcript = chatTranscript else { return }
        transcript.string = transcript.string.replacingOccurrences(of: "อั่งเปากำลังคิด…\n\n", with: "")
        transcript.scrollToEndOfDocument(nil)
    }

    private func localChatReply(to message: String, snapshot: CompanionSnapshot) -> String {
        CompanionChatResilience.localReply(to: message, snapshot: snapshot)
    }

    @objc private func resetCompanionChatTask() {
        ManusCompanionProvider.resetChatTask()
        companionMemory.forgetConversation()   // ลืมแค่บทสนทนา อายุกับจำนวนครั้งที่คุยยังอยู่
        setCompanionConnectionStatus("พร้อมใช้งาน • ยังไม่ได้เรียก")
        say("น้องลืมที่คุยกันไปแล้วนะ แต่ยังจำพ่อได้อยู่", for: 4.0)
    }

    // MARK: Local AI companion (Phase 1)

    private func makeCompanionMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: companionMenuTitle(), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "AI companion")
        for mode in [CompanionMode.off, .quietWatch, .companion] {
            let title = mode == .off ? "ปิด AI companion" : "\(mode.label) — \(mode == .quietWatch ? "รับรู้แต่พูดเฉพาะเรื่องสำคัญ" : "คุยเป็นครั้งคราว")"
            let entry = NSMenuItem(title: title, action: #selector(setCompanionMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = mode.rawValue
            entry.state = mode == companionMode ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(.separator())
        let brainHeader = NSMenuItem(title: "สมองที่ใช้ตอบ", action: nil, keyEquivalent: "")
        brainHeader.isEnabled = false
        submenu.addItem(brainHeader)
        for brain in CompanionBrain.allCases {
            let entry = NSMenuItem(title: "\(brain.label) — \(brain.detail)",
                                   action: #selector(setCompanionBrain(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = brain.rawValue
            entry.state = brain == companionBrain ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let chat = NSMenuItem(title: "คุยกับอั่งเปา…", action: #selector(activateCompanionChatShortcut),
                              keyEquivalent: "c")
        chat.target = self
        chat.keyEquivalentModifierMask = [.control, .option]
        submenu.addItem(chat)
        let reset = NSMenuItem(title: "ให้น้องลืมบทสนทนาที่ผ่านมา", action: #selector(resetCompanionChatTask), keyEquivalent: "")
        reset.target = self
        submenu.addItem(reset)
        let note = NSMenuItem(title: "ทำงาน local ยังไม่ส่งข้อมูลออก", action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(note)
        item.submenu = submenu
        return item
    }

    private func makeFileSearchMenuItem() -> NSMenuItem {
        let count = fileSearchResults.count
        let title = count == 0 ? "ของที่น้องหาเจอ" : "ของที่น้องหาเจอ • \(count)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "ผลค้นหาในเครื่อง")
        if fileSearchResults.isEmpty {
            let empty = NSMenuItem(title: "พิมพ์ /หา ชื่อไฟล์ ในกล่องคุย", action: nil,
                                   keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for url in fileSearchResults {
                let parent = fileFinder.displayLocation(for: url)
                let entry = NSMenuItem(
                    title: "\(url.lastPathComponent) — \(parent)",
                    action: #selector(openFoundFile(_:)), keyEquivalent: ""
                )
                entry.target = self
                entry.representedObject = url.path
                menu.addItem(entry)
            }
        }
        item.submenu = menu
        return item
    }

    private func refreshFileSearchMenu() {
        guard let item = fileSearchMenuItem else { return }
        let replacement = makeFileSearchMenuItem()
        item.title = replacement.title
        item.submenu = replacement.submenu
    }

    @objc private func openFoundFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        revealFoundFile(URL(fileURLWithPath: path))
    }

    @objc private func setCompanionMode(_ sender: NSMenuItem) {
        guard let mode = CompanionMode(rawValue: sender.tag) else { return }
        companionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "companionMode")
        companionCooldown = mode == .off ? 0 : 20
        if mode == .companion && activeCompanion != nil && !companionRequestInFlight {
            setCompanionConnectionStatus("พร้อมใช้งาน • ยังไม่ได้เรียก")
        }
        if mode == .off {
            if activeWorkNotice == nil { hideBubble() }
        } else {
            say(mode == .quietWatch ? "น้องจะเฝ้าเงียบ ๆ นะ" : "น้องจะคอยคุยด้วยเป็นครั้งคราวนะ", for: 3.0)
        }
        syncCompanionMenu()
    }

    private func syncCompanionMenu() {
        guard let menu = statusItem?.menu else { return }
        for item in menu.items where item.title.hasPrefix("AI companion") {
            item.title = companionMenuTitle()
            for child in item.submenu?.items ?? [] {
                if child.action == #selector(setCompanionBrain(_:)) {
                    if let brain = CompanionBrain(rawValue: child.tag) { child.state = brain == companionBrain ? .on : .off }
                } else if child.action == #selector(setCompanionMode(_:)),
                          let mode = CompanionMode(rawValue: child.tag) {
                    child.state = mode == companionMode ? .on : .off
                }
            }
        }
    }

    private func companionMenuTitle() -> String {
        "AI companion • \(companionMode.label) • \(companionBrain.label): \(companionConnectionStatus)"
    }

    private func setCompanionConnectionStatus(_ status: String) {
        guard companionConnectionStatus != status else { return }
        companionConnectionStatus = status
        syncCompanionMenu()
        if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
            FileHandle.standardError.write("COMPANION STATUS \(status)\n".data(using: .utf8)!)
        }
    }

    private func localCompanionSnapshot() -> CompanionSnapshot {
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .init(rawValue: ~0)!)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "เดสก์ท็อป"
        let waiting = workSessions.filter { isWaiting($0.state) }.count
        let working = workSessions.filter { ["working", "busy"].contains($0.state) }.count
        let attention = workSessions.filter { needsAttention($0.state) }.count
        let hottest = workSessions.map(\.contextPercent).max() ?? 0
        if app != companionLastApp {
            companionLastApp = app
            companionRecentEvent = "เปิดใช้ \(app)"
        }
        return CompanionSnapshot(activeApp: app, userIdleSeconds: idle, workingCount: working,
                                 waitingCount: waiting, attentionCount: attention,
                                 hottestContext: hottest, focusActive: focusPhase != .idle,
                                 recentEvent: companionRecentEvent,
                                 workBriefs: companionWorkBriefs())
    }

    /// ชื่อโปรเจกต์สำหรับส่งออกนอกเครื่อง — เอาเฉพาะโฟลเดอร์ท้ายสุด ไม่ให้ path เต็มหลุดไปหา AI
    private func companionProjectName(_ session: WorkSession) -> String {
        let raw = session.name.isEmpty ? session.cwd : session.name
        let leaf = raw.hasPrefix("/") ? (raw as NSString).lastPathComponent : raw
        let cleaned = leaf.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "ไม่ทราบชื่อ" : noticeProjectName(cleaned)
    }

    /// ใช้เฉพาะใน BRAINTEST — ยิงรอบสองเพื่อดูว่าน้องจำรอบแรกได้ไหม
    fileprivate func provider2(_ provider: CompanionProvider, message: String,
                               snapshot: CompanionSnapshot, done: @escaping (String) -> Void) {
        provider.chat(message: message, memory: companionMemory, snapshot: snapshot) { outcome in
            switch outcome {
            case .reply(let text): done(text)
            case .failure(let reason): done("FAIL: \(reason)")
            }
        }
    }

    /// สรุปงานจริงให้ AI อ่าน — ส่งแค่ชื่อโฟลเดอร์ท้ายสุด ไม่ส่ง path เต็ม ไม่ส่งเนื้อแชทหรือโค้ด
    private func companionWorkBriefs(limit: Int = 6) -> [String] {
        workSessions
            .sorted { workStateRank($0.state) > workStateRank($1.state) }
            .prefix(limit)
            .map { session in
                var parts = [workSourceName(session),
                             companionProjectName(session),
                             workStateLabel(session)]
                if session.contextPercent > 0 {
                    parts.append("context \(Int(session.contextPercent.rounded()))%")
                }
                let topic = session.topic.trimmingCharacters(in: .whitespacesAndNewlines)
                if !topic.isEmpty { parts.append("หัวข้อ: \(topic)") }
                return parts.joined(separator: " • ")
            }
    }

    /// บอกให้ตรงว่าสมองที่เลือกใช้ไม่ได้เพราะอะไร ไม่ใช่ "ไม่ได้ตั้ง API key" ลอย ๆ
    private var brainUnavailableText: String {
        switch companionBrain {
        case .localOnly: return "Local เท่านั้น • ไม่ส่งข้อมูลออก"
        case .claude: return "ไม่พบ claude CLI และไม่มี ANTHROPIC_API_KEY • ใช้ local"
        case .manus: return "ไม่ได้ตั้ง PIXELCAT_MANUS_API_KEY • ใช้ local"
        }
    }

    @objc private func setCompanionBrain(_ sender: NSMenuItem) {
        guard let brain = CompanionBrain(rawValue: sender.tag) else { return }
        companionBrain = brain
        UserDefaults.standard.set(brain.rawValue, forKey: "companionBrain")
        setCompanionConnectionStatus(activeCompanion.map { "\($0.brandName) • พร้อมใช้งาน" } ?? brainUnavailableText)
        say("เปลี่ยนสมองเป็น \(brain.label) แล้วนะ", for: 3.5)
        syncCompanionMenu()
    }

    private func companionDecision(for snapshot: CompanionSnapshot) -> CompanionDecision? {
        guard companionMode == .companion, !snapshot.focusActive, !held,
              activeWorkNotice == nil, activeContextRescue == nil,
              snapshot.userIdleSeconds >= 45 else { return nil }
        if snapshot.waitingCount > 0 {
            return CompanionDecision(message: "มีงานรอคำตอบอยู่ \(snapshot.waitingCount) งานนะ", mood: "concerned", cooldown: 900)
        }
        if snapshot.hottestContext >= 80 {
            return CompanionDecision(message: "เห็น context ใกล้เต็มแล้วนะ ค่อย ๆ ตรวจ handoff ได้เลย", mood: "curious", cooldown: 1200)
        }
        if snapshot.workingCount > 0 {
            return CompanionDecision(message: "น้องเห็นมีงานกำลังทำอยู่ \(snapshot.workingCount) งาน เดี๋ยวนั่งเฝ้าให้", mood: "quiet", cooldown: 1200)
        }
        return nil
    }

    private func runLocalCompanion(_ dt: Double) {
        guard companionMode != .off, !chatBusy else { return }
        companionPoll -= dt
        companionCooldown = max(0, companionCooldown - dt)
        guard companionPoll <= 0 else { return }
        companionPoll = 5.0
        let snapshot = localCompanionSnapshot()
        guard companionCooldown <= 0, let fallback = companionDecision(for: snapshot) else { return }
        if let provider = activeCompanion, !companionRequestInFlight {
            companionRequestInFlight = true
            setCompanionConnectionStatus("กำลังทำงานอยู่")
            provider.decide(memory: companionMemory, snapshot: snapshot) { [weak self] decision in
                guard let self else { return }
                self.companionRequestInFlight = false
                self.setCompanionConnectionStatus(decision == nil ? "API error • ใช้ local" : "เชื่อมต่อแล้ว")
                let brand = provider.brandName
                self.applyCompanionDecision(decision ?? fallback, source: decision == nil ? "local-fallback" : brand)
            }
            return
        }
        if activeCompanion == nil { setCompanionConnectionStatus(self.brainUnavailableText) }
        applyCompanionDecision(fallback, source: "local")
    }

    private func applyCompanionDecision(_ decision: CompanionDecision, source: String) {
        companionCooldown = decision.cooldown
        if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
            FileHandle.standardError.write("COMPANION \(source) mood=\(decision.mood) msg=\(decision.message)\n".data(using: .utf8)!)
        }
        guard !decision.message.isEmpty else { return }
        if decision.mood == "concerned" {
            setState("tilt", duration: 0.8) { [weak self] in self?.setState("sit", duration: 2.0) }
        } else if decision.mood == "curious" {
            setState("tilt", duration: 0.9)
        }
        say(decision.message, for: 4.5)
    }

    /// วาดน้อง (+ ลูกโป่งถ้ามีข้อความ) ลง PNG โดยไม่ต้องพึ่งหน้าจอ
    private func snapshot(to path: String, pose: String, text: String) {
        setState(POSES[pose] != nil ? pose : "sit", duration: 99)
        applyFrame()
        func bitmap(_ v: NSView) -> NSBitmapImageRep? {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep
        }
        var bub: NSBitmapImageRep? = nil
        if !text.isEmpty {
            bubbleView.text = text
            let sz = BubbleView.size(for: text)
            bubbleWindow.setContentSize(sz)
            bubbleView.frame = NSRect(origin: .zero, size: sz)
            bubbleView.needsDisplay = true
            bub = bitmap(bubbleView)
        }
        guard let cat = bitmap(view) else { return }
        let gap: CGFloat = bub == nil ? 0 : 6
        let W = max(CGFloat(cat.pixelsWide), CGFloat(bub?.pixelsWide ?? 0))
        let H = CGFloat(cat.pixelsHigh) + (bub.map { CGFloat($0.pixelsHigh) + gap } ?? 0)
        let canvas = NSImage(size: NSSize(width: W, height: H))
        canvas.lockFocus()
        NSColor(calibratedRed: 0.957, green: 0.965, blue: 0.949, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: W, height: H))
        NSGraphicsContext.current?.imageInterpolation = .none
        cat.draw(in: NSRect(x: (W - CGFloat(cat.pixelsWide)) / 2, y: 0,
                            width: CGFloat(cat.pixelsWide), height: CGFloat(cat.pixelsHigh)))
        if let b = bub {
            b.draw(in: NSRect(x: (W - CGFloat(b.pixelsWide)) / 2,
                              y: CGFloat(cat.pixelsHigh) + gap,
                              width: CGFloat(b.pixelsWide), height: CGFloat(b.pixelsHigh)))
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write("snapshot -> \(path)  \(Int(W))x\(Int(H))\n".data(using: .utf8)!)
    }

    private func item(_ title: String, _ action: Selector, tag: Int = -1) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.tag = tag
        return mi
    }

    private func syncMenu() {
        statusItem.menu?.items.first(where: { $0.tag == 0 })?.state = follow ? .on : .off
        statusItem.menu?.items.first(where: { $0.tag == 1 })?.state = paused ? .on : .off
        statusItem.menu?.items.first(where: { $0.tag == 2 })?.state = onTop ? .on : .off
        statusItem.menu?.items.first(where: { $0.tag == 3 })?.state = speechOn ? .on : .off
        statusItem.menu?.items.first(where: { $0.title == "เสียงเหมียว" })?.state =
            CatVoice.shared.enabled ? .on : .off
        if let sizes = statusItem.menu?.items.first(where: { $0.title == "ขนาด" })?.submenu {
            for mi in sizes.items { mi.state = (CGFloat(mi.tag) / 10 == scale) ? .on : .off }
        }
        motionMenuItem?.title = "ความซน • \(effectiveMotionLevel.label)"
        motionMenuItem?.submenu = makeMotionMenu()
        updateFocusUI(force: true)
    }

    private var workInboxTitle: String {
        if workAlertCount > 0 { return "กล่องงาน • ต้องดู \(workAlertCount)" }
        if workActiveCount > 0 { return "กล่องงาน • กำลังทำ \(workActiveCount)" }
        if !workSessions.isEmpty { return "กล่องงาน • ล่าสุด \(workSessions.count)" }
        return "กล่องงาน • ไม่มีงานล่าสุด"
    }

    private func workStateLabel(_ session: WorkSession) -> String {
        switch session.activity.kind {
        case .coding: return "⌨️ กำลังแก้โค้ด"
        case .build: return "🛠 กำลัง build"
        case .testing: return "🧪 กำลังทดสอบ"
        case .testPassed: return "✅ test ผ่าน"
        case .testFailed: return "🔴 test พัง"
        case .permission: return "🟠 รอ permission"
        case .idle: break
        }
        switch session.state {
        case "input", "ask", "waiting": return "🟠 รอคำตอบ"
        case "working", "busy": return "🔵 กำลังทำ"
        case "fail", "failed", "error": return "🔴 พัง"
        case "interrupted": return "⚪️ หยุดแล้ว"
        case "idle", "done": return "✅ เสร็จแล้ว"
        default: return "⚪️ \(state)"
        }
    }

    private func workStateRank(_ state: String) -> Int {
        switch state {
        case "input", "ask", "waiting", "fail", "failed", "error": return 0
        case "working", "busy": return 1
        case "idle", "done": return 2
        default: return 3
        }
    }

    private func needsAttention(_ state: String) -> Bool {
        ["input", "ask", "waiting", "fail", "failed", "error"].contains(state)
    }

    private func isWaiting(_ state: String) -> Bool {
        ["input", "ask", "waiting"].contains(state)
    }

    private func recalculateWorkCounts() {
        workAlertCount = workSessions.filter {
            needsAttention($0.state) && !acknowledgedWorkKeys.contains(noticeKey($0))
        }.count
        workActiveCount = workSessions.filter {
            ["working", "busy"].contains($0.state)
        }.count
    }

    private func acknowledgeWork(source: String, id: String) {
        let key = "\(source):\(id)"
        acknowledgedWorkKeys.insert(key)
        waitingReminderSent.insert(key)
        recalculateWorkCounts()
        refreshWorkInboxUI()
    }

    private func sessionHeadline(_ session: WorkSession) -> String {
        session.topic.isEmpty ? session.name : session.topic
    }

    private func addWorkSection(_ source: String, title: String, to menu: NSMenu) {
        let sessions = workSessions.filter { $0.source == source }
        let header = NSMenuItem(title: "\(title) • \(sessions.count)", action: nil,
                                keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        guard !sessions.isEmpty else {
            let empty = NSMenuItem(title: "    ไม่มีงานใน 15 นาทีล่าสุด", action: nil,
                                   keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for session in sessions.prefix(INBOX_MAX) {
            let context = session.contextPercent > 0
                ? " • ctx \(Int(session.contextPercent.rounded()))%" : ""
            let title = "\(workStateLabel(session)) • \(sessionHeadline(session))"
            let entry = NSMenuItem(title: title, action: #selector(openWorkSession(_:)),
                                   keyEquivalent: "")
            entry.target = self
            let canJump = !session.focusURL.isEmpty || !resumeID(session.sessionID).isEmpty
                || focusableApp(session.appPIDs) != nil
            entry.representedObject = [session.focusURL, session.cwd,
                                       session.appPIDs.map(String.init).joined(separator: ","),
                                       resumeID(session.sessionID), session.source, session.id,
                                       isSessionAlive(session) ? "alive" : "gone"]
            entry.isEnabled = canJump
                || (!session.cwd.isEmpty && FileManager.default.fileExists(atPath: session.cwd))
            if canJump { entry.title = "↩︎ " + title }
            menu.addItem(entry)

            // บรรทัดรอง: โปรเจกต์และ context แยกจากชื่อ task/session
            var sub = session.topic.isEmpty ? "" : session.name
            if !context.isEmpty { sub += sub.isEmpty ? String(context.dropFirst(3)) : context }
            if !sub.isEmpty {
                let where_ = NSMenuItem(title: "    \(sub)", action: nil, keyEquivalent: "")
                where_.isEnabled = false
                menu.addItem(where_)
            }
            if !session.message.isEmpty {
                let shortened = session.message.count > 72
                    ? String(session.message.prefix(72)) + "…" : session.message
                let detail = NSMenuItem(title: "    \(shortened)", action: nil,
                                        keyEquivalent: "")
                detail.isEnabled = false
                menu.addItem(detail)
            }
        }
        if sessions.count > INBOX_MAX {
            let more = NSMenuItem(title: "… และอีก \(sessions.count - INBOX_MAX) งาน",
                                  action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }
    }

    private func makeWorkInboxMenu() -> NSMenu {
        let menu = NSMenu()
        addWorkSection("codex", title: "Codex", to: menu)
        menu.addItem(.separator())
        addWorkSection("claude", title: "Claude Code", to: menu)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "↩︎ = พาไป session นั้น • ไม่มี = เปิดโฟลเดอร์", action: nil,
                              keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        return menu
    }

    private func refreshWorkInboxUI() {
        workInboxItem?.title = workInboxTitle
        workInboxItem?.submenu = makeWorkInboxMenu()
        updateStatusTitle()
    }

    /// คลิกรายการในกล่องงาน — ถ้าเทอร์มินัลให้ URL ต่อแท็บมา ให้กระโดดไปแท็บนั้นเลย
    /// ไม่งั้นถอยไปเปิดโฟลเดอร์โปรเจกต์เหมือนเดิม (เทอร์มินัลส่วนใหญ่ยังไม่มี URL แบบนี้)
    /// แอป GUI ตัวแรกในสายโปรเซส — .app ตัวแรกที่เจออาจเป็นโปรเซสลูกที่สั่งไม่ได้
    /// (เช่น claude helper ของแอปเดสก์ท็อป) เลยต้องไล่ทั้งสายและเช็ค activationPolicy
    /// session id ที่ปลอดภัยพอจะใส่ลง URL — รับเฉพาะรูปแบบ UUID (ตัวอักษร ตัวเลข ขีด)
    /// ห้องนั้นยังเปิดอยู่จริงไหม ดูจากโปรเซสที่ hook บันทึกไว้
    private func isSessionAlive(_ session: WorkSession) -> Bool {
        guard session.pid > 0 else { return false }
        return kill(pid_t(session.pid), 0) == 0 || errno != ESRCH
    }

    private func resumeID(_ raw: String) -> String {
        guard raw.count >= 8, raw.count <= 64 else { return "" }
        let ok = CharacterSet(charactersIn: "abcdefABCDEF0123456789-")
        return raw.unicodeScalars.allSatisfy(ok.contains) ? raw : ""
    }

    private func focusableApp(_ pids: [Int]) -> NSRunningApplication? {
        for p in pids {
            guard let a = NSRunningApplication(processIdentifier: pid_t(p)) else { continue }
            if a.activationPolicy == .regular { return a }
        }
        return nil
    }

    @objc private func openWorkSession(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count >= 4 else { return }
        if parts.count >= 6 { acknowledgeWork(source: parts[4], id: parts[5]) }
        openTarget(focus: parts[0], path: parts[1], pidList: parts[2], sessionID: parts[3])
    }

    private func openTarget(_ session: WorkSession) {
        if ProcessInfo.processInfo.environment["PIXELCAT_SIMCOURIER"] != nil
            || ProcessInfo.processInfo.environment["PIXELCAT_SIMSHEPHERD"] != nil
            || ProcessInfo.processInfo.environment["PIXELCAT_SIMWORKNOTICE"] != nil
            || ProcessInfo.processInfo.environment["PIXELCAT_SIMRETURNRITUAL"] != nil {
            lastSimulatedOpenURL = session.focusURL.isEmpty ? session.cwd : session.focusURL
            return
        }
        openTarget(focus: session.focusURL, path: session.cwd,
                   pidList: session.appPIDs.map(String.init).joined(separator: ","),
                   sessionID: resumeID(session.sessionID))
    }

    /// หาหน้าต่างของแอปที่เป็นเจ้าของงาน โดยอ่านเฉพาะ bounds/PID จาก Window Server
    /// แล้วแปลงพิกัดบนซ้ายของ Quartz เป็นพิกัดล่างซ้ายของ AppKit
    private func taskWindowRect(_ session: WorkSession) -> CGRect? {
        if let simulatedShepherdRect { return simulatedShepherdRect }
        var pids = Set(session.appPIDs.map(Int32.init))
        if session.source == "codex" {
            for app in NSWorkspace.shared.runningApplications {
                let name = (app.localizedName ?? "").lowercased()
                let bundle = (app.bundleIdentifier ?? "").lowercased()
                if name.contains("codex") || bundle.contains("codex") {
                    pids.insert(app.processIdentifier)
                }
            }
        }
        guard !pids.isEmpty else { return nil }
        let flip = NSScreen.screens.first?.frame.maxY ?? 900
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return list.compactMap { item -> CGRect? in
            guard (item[kCGWindowLayer as String] as? Int) == 0,
                  let pid = item[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let b = item[kCGWindowBounds as String] as? [String: CGFloat],
                  let bx = b["X"], let by = b["Y"], let bw = b["Width"], let bh = b["Height"],
                  bw > 170, bh > 100 else { return nil }
            return CGRect(x: bx, y: flip - by - bh, width: bw, height: bh)
        }.max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    /// เดินไปทางหน้าต่างที่ต้องดู แล้วชี้ค้างไว้; ไม่แย่ง Focus mode
    private func startTaskShepherd(_ session: WorkSession) {
        guard focusPhase == .idle, !held, !airborne, !climbing else { return }
        shepherdTarget = session
        let destination = taskWindowRect(session)
        let targetMidX = destination?.midX
            ?? (session.source == "codex" ? plat.maxX : plat.minX)
        let goRight = targetMidX >= x + spriteW / 2
        dir = goRight ? 1 : -1
        let distance = min(220, max(84, abs(targetMidX - (x + spriteW / 2))))
        target = clampX(x + dir * distance)
        hurry = false
        setState("walk", duration: 99) { [weak self] in
            guard let self, self.shepherdTarget != nil else { return }
            self.setState("point", duration: 8.0) { [weak self] in
                self?.shepherdTarget = nil
                self?.pickIdle()
            }
        }
    }

    /// CatView เรียกเมื่อคลิกตัวน้องระหว่างชี้งาน; bubble และตัวน้องเปิดปลายทางเดียวกัน
    func openShepherdTargetIfPresent() -> Bool {
        guard let session = shepherdTarget else { return false }
        shepherdTarget = nil
        acknowledgeWork(source: session.source, id: session.id)
        openTarget(session)
        return true
    }

    // MARK: Context Rescue

    /// สรุปข้อมูลที่แอปรู้จริงเท่านั้น แล้วให้ task ใหม่ตรวจ working tree ต่อเอง
    /// จึงไม่แต่งสถานะงานหรืออ้างว่ามีรายละเอียดที่ไม่ได้อ่านจาก session
    /// รันคำสั่งอ่านอย่างเดียวในโฟลเดอร์งาน คืนบรรทัดที่อ่านได้ ไม่ค้างถ้าคำสั่งเงียบ
    private func readOnlyShell(_ launch: String, _ args: [String], in cwd: String,
                               limit: Int = 4000) -> String {
        guard !cwd.isEmpty,
              FileManager.default.fileExists(atPath: cwd) else { return "" }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launch)
        task.arguments = args
        task.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return "" }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// หนึ่งประโยคว่าโปรเจกต์นี้คืออะไร หยิบจากเอกสารในโฟลเดอร์ ไม่ต้องให้ห้องใหม่เดา
    private func projectSummary(cwd: String) -> String {
        for doc in ["CLAUDE.md", "README.md"] {
            let path = cwd + "/" + doc
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#*_> "))
                guard line.count >= 12, !line.hasPrefix("!"), !line.hasPrefix("[") else { continue }
                return String(line.prefix(200))
            }
        }
        return ""
    }

    /// สภาพโค้ดตอนนี้จริง ๆ — ห้องใหม่จะได้เห็นว่าอะไรถูกคอมมิตไปแล้ว ไม่ทำซ้ำ
    private func repositoryBriefing(cwd: String) -> [String] {
        guard !readOnlyShell("/usr/bin/git", ["rev-parse", "--is-inside-work-tree"],
                             in: cwd, limit: 20).isEmpty else { return [] }
        var lines: [String] = []
        let branch = readOnlyShell("/usr/bin/git", ["rev-parse", "--abbrev-ref", "HEAD"],
                                   in: cwd, limit: 120)
        if !branch.isEmpty { lines.append("branch: \(branch)") }
        let log = readOnlyShell("/usr/bin/git", ["log", "-5", "--pretty=format:%h %ad %s",
                                                "--date=format:%m-%d %H:%M"], in: cwd, limit: 1200)
        if !log.isEmpty {
            lines.append("คอมมิตล่าสุด (งานที่ทำเสร็จไปแล้ว ห้ามทำซ้ำ):")
            lines.append(contentsOf: log.split(separator: "\n").map { "  - " + $0 })
        }
        let status = readOnlyShell("/usr/bin/git", ["status", "--porcelain"], in: cwd, limit: 4000)
        if status.isEmpty {
            lines.append("working tree: สะอาด ไม่มีงานค้างกลางคัน")
        } else {
            let changed = status.split(separator: "\n")
            lines.append("working tree: มี \(changed.count) ไฟล์ที่ยังไม่คอมมิต")
            lines.append(contentsOf: changed.prefix(10).map { "  - " + $0.trimmingCharacters(in: .whitespaces) })
        }
        return lines
    }

    private func contextHandoff(for session: WorkSession) -> String {
        let source = workSourceName(session)
        let topic = sessionHeadline(session)
        let latest = session.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceLink: String
        if !session.focusURL.isEmpty {
            sourceLink = session.focusURL
        } else if session.source == "claude",
                  let link = claudeSessionURL(resumeID(session.sessionID)) {
            sourceLink = link.absoluteString
        } else {
            sourceLink = "(ไม่มี deep link ของ task ต้นทาง)"
        }
        var lines = [
            "ทำงานนี้ต่อจาก Context Rescue ของ PixelCat",
            "",
            "แหล่งที่มา: \(source)",
            "โปรเจกต์: \(session.name)",
            "หัวข้องาน: \(topic)",
            "สถานะล่าสุด: \(session.state)",
            "context ล่าสุด: \(Int(session.contextPercent.rounded()))%",
            "โฟลเดอร์งาน: \(session.cwd.isEmpty ? "(ไม่ทราบ)" : session.cwd)",
            "task ต้นทาง: \(sourceLink)"
        ]
        if !latest.isEmpty {
            lines.append("ข้อความสถานะล่าสุด: " + String(latest.prefix(800)))
        }

        let summary = projectSummary(cwd: session.cwd)
        if !summary.isEmpty {
            lines.append(contentsOf: ["", "โปรเจกต์นี้คืออะไร: " + summary])
        }
        let request = session.lastRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !request.isEmpty {
            lines.append(contentsOf: ["", "คำสั่งล่าสุดของผู้ใช้ในห้องเก่า:",
                                      String(request.prefix(400))])
        }
        if !session.recentFiles.isEmpty {
            let shown = session.recentFiles.map { path -> String in
                guard !session.cwd.isEmpty, path.hasPrefix(session.cwd + "/") else { return path }
                return String(path.dropFirst(session.cwd.count + 1))
            }
            lines.append(contentsOf: ["", "ไฟล์ที่ห้องเก่าแก้ล่าสุด:"]
                         + shown.map { "  - " + $0 })
        }
        let repo = repositoryBriefing(cwd: session.cwd)
        if !repo.isEmpty {
            lines.append(contentsOf: [""] + repo)
        }

        lines.append(contentsOf: [
            "",
            "เริ่มงานแบบนี้:",
            "1. อ่าน git log และ working tree ข้างบน แล้วเปิดไฟล์ที่เกี่ยวข้องเพื่อดูว่าหัวข้องานนี้ทำเสร็จไปแล้วหรือยัง",
            "2. ถ้าเสร็จแล้ว อย่าทำซ้ำ — บอกผู้ใช้สั้น ๆ ว่าเสร็จแล้วที่คอมมิตไหน แล้วถามว่าจะให้ทำอะไรต่อ",
            "3. ถ้ายังไม่เสร็จ สรุปสิ่งที่เหลือก่อน แล้วทำต่อโดยไม่ย้อนงานที่เสร็จไปแล้ว",
            "หากข้อมูลไม่พอให้ถามผู้ใช้สั้น ๆ หนึ่งคำถาม"
        ])
        return lines.joined(separator: "\n")
    }

    /// Adapter ของ deep link สองแอปอยู่หลัง interface เดียว: session เข้า, rescue ออก
    private func makeContextRescue(for session: WorkSession) -> ContextRescue? {
        let handoff = contextHandoff(for: session)
        var components = URLComponents()
        if session.source == "codex" {
            components.scheme = "codex"
            components.host = "new"
            components.queryItems = [URLQueryItem(name: "prompt", value: handoff)]
            if !session.cwd.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "path", value: session.cwd))
            }
        } else {
            components.scheme = "claude"
            components.host = "code"
            components.path = "/new"
            components.queryItems = [URLQueryItem(name: "prompt", value: handoff)]
            if !session.cwd.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "folder", value: session.cwd))
            }
        }
        guard let launchURL = components.url else { return nil }
        return ContextRescue(session: session, handoff: handoff, launchURL: launchURL)
    }

    private func offerContextRescue(for session: WorkSession) {
        let key = noticeKey(session)
        guard session.contextPercent >= 90,
              !contextRescueOffered.contains(key),
              focusPhase == .idle, !held, !airborne, !climbing,
              activeWorkNotice == nil, activeContextRescue == nil,
              speechOn, let rescue = makeContextRescue(for: session) else { return }
        contextRescueOffered.insert(key)
        rememberRescue(rescue)
        activeContextRescue = rescue
        shepherdTarget = nil
        let waitReady: () -> Void = { [weak self] in
            guard let self, self.activeContextRescue != nil else { return }
            self.setState("rescueReady", duration: 12.0) { [weak self] in
                self?.activeContextRescue = nil
                self?.pickIdle()
            }
        }
        if reduceMotionEnabled { waitReady() }
        else { setState("rescuePack", duration: 1.4, then: waitReady) }
        say("context \(Int(session.contextPercent.rounded()))% • คาบ handoff พร้อมแล้ว คลิกเพื่อเปิดงานใหม่",
            for: 12.0, target: session)
    }

    /// เก็บ handoff ที่เพิ่งเสนอ ให้กดย้อนหลังได้แม้กรอบคำพูดหายไปแล้ว
    private func rememberRescue(_ rescue: ContextRescue) {
        let title = "\(workSourceName(rescue.session)) • \(companionProjectName(rescue.session))"
            + " • context \(Int(rescue.session.contextPercent.rounded()))%"
        let entry = SavedRescue(title: title, urlString: rescue.launchURL.absoluteString,
                                handoff: rescue.handoff, savedAt: Date())
        // งานเดิมที่เสนอซ้ำ ให้ทับอันเก่า ไม่ให้เมนูรก
        rescueHistory.removeAll { $0.title == title }
        rescueHistory.insert(entry, at: 0)
        if rescueHistory.count > Self.rescueHistoryLimit {
            rescueHistory = Array(rescueHistory.prefix(Self.rescueHistoryLimit))
        }
        persistRescueHistory()
    }

    private func persistRescueHistory() {
        UserDefaults.standard.set(rescueHistory.map(\.dictionary), forKey: Self.rescueHistoryKey)
        rescueHistoryItem?.submenu = makeRescueHistoryMenu().submenu
    }

    private func makeRescueHistoryMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Handoff ที่เคยเสนอ", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Handoff ที่เคยเสนอ")
        if rescueHistory.isEmpty {
            let empty = NSMenuItem(title: "ยังไม่มี handoff ที่เคยเสนอ", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for (index, saved) in rescueHistory.enumerated() {
                let entry = NSMenuItem(title: "\(saved.title) — \(saved.ageText)",
                                       action: #selector(openSavedRescue(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = index
                submenu.addItem(entry)
            }
            submenu.addItem(.separator())
            let clear = NSMenuItem(title: "ล้างประวัติ handoff", action: #selector(clearRescueHistory),
                                   keyEquivalent: "")
            clear.target = self
            submenu.addItem(clear)
        }
        item.submenu = submenu
        return item
    }

    @objc private func openSavedRescue(_ sender: NSMenuItem) {
        guard rescueHistory.indices.contains(sender.tag) else { return }
        let saved = rescueHistory[sender.tag]
        guard let url = URL(string: saved.urlString) else {
            say("ลิงก์ handoff อันนี้เสียแล้ว เปิดให้ไม่ได้นะกริช", for: 4.0); return
        }
        if ProcessInfo.processInfo.environment["PIXELCAT_SIMCONTEXTRESCUE"] != nil {
            lastSimulatedNewTaskURL = saved.urlString
            lastSimulatedHandoff = saved.handoff
        } else {
            if !saved.handoff.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(saved.handoff, forType: .string)
            }
            NSWorkspace.shared.open(url)
        }
        say("เปิด handoff ของ \(saved.title) ให้แล้วนะ", for: 4.0)
    }

    @objc private func clearRescueHistory() {
        rescueHistory.removeAll()
        persistRescueHistory()
        say("ล้างประวัติ handoff แล้วนะ", for: 3.0)
    }

    /// ประเมินทุก session แต่เสนอ rescue เพียงครั้งเดียวจนกว่า context จะลดต่ำกว่า 70%
    /// ห้องที่พ่อเปิดห้องใหม่ในโฟลเดอร์เดียวกันไปแล้ว ถือว่าย้ายไปทำต่อที่นั่นแล้ว
    /// ไม่ต้องเตือน context หรือคาบ handoff มาให้อีก
    private func supersededSessions(_ sessions: [WorkSession]) -> Set<String> {
        var superseded = Set<String>()
        for session in sessions where !session.cwd.isEmpty {
            let hasNewerRoom = sessions.contains {
                $0.cwd == session.cwd && noticeKey($0) != noticeKey(session)
                    && $0.startedAt > session.startedAt
            }
            if hasNewerRoom { superseded.insert(noticeKey(session)) }
        }
        return superseded
    }

    private func evaluateContextPressure(_ allSessions: [WorkSession]) {
        let superseded = supersededSessions(allSessions)
        let sessions = allSessions.filter { !superseded.contains(noticeKey($0)) }
        let liveKeys = Set(sessions.filter { $0.contextPercent >= 70 }.map(noticeKey))
        contextRescueOffered.formIntersection(liveKeys)
        guard let hottest = sessions.filter({ $0.contextPercent > 0 })
            .max(by: { $0.contextPercent < $1.contextPercent }) else {
            ctxWarned = 0
            return
        }
        let step = hottest.contextPercent >= 90 ? 90.0
            : (hottest.contextPercent >= 80 ? 80.0 : 0)
        if step > ctxWarned {
            ctxWarned = step
            if step == 80, focusPhase == .idle, !held {
                setState("sit", duration: 5) { [weak self] in self?.pickIdle() }
                say("context ใช้ไป \(Int(hottest.contextPercent.rounded()))% แล้วนะ", for: 5)
            }
        } else if hottest.contextPercent < 70 {
            ctxWarned = 0
        }
        if let candidate = sessions
            .filter({ $0.contextPercent >= 90 && !contextRescueOffered.contains(noticeKey($0)) })
            .max(by: { $0.contextPercent < $1.contextPercent }) {
            offerContextRescue(for: candidate)
        }
    }

    @discardableResult
    func openContextRescueIfPresent() -> Bool {
        guard let rescue = activeContextRescue else { return false }
        activeContextRescue = nil
        bubbleTarget = nil
        bubbleView.interactive = false
        bubbleWindow.ignoresMouseEvents = true
        let simulated = ProcessInfo.processInfo.environment["PIXELCAT_SIMCONTEXTRESCUE"] != nil
        if simulated {
            lastSimulatedNewTaskURL = rescue.launchURL.absoluteString
            lastSimulatedHandoff = rescue.handoff
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(rescue.handoff, forType: .string)
            if !NSWorkspace.shared.open(rescue.launchURL) {
                openTarget(rescue.session)
            }
        }
        speakFor = 0
        hideBubble()
        transitionState(to: "sit", duration: 1.5)
        return true
    }

    // MARK: Drag Courier

    func courierDropRegistrationChanged(_ registered: Bool) {
        courierDropRegistered = registered
    }

    func courierDragEntered() {
        guard focusPhase == .idle, !held else { return }
        setState("point", duration: 99)
        say("ฝากอะไรให้น้องคาบไปส่งได้เลย", for: 2.0)
    }

    func courierDragExited() {
        guard pendingCourierPayload == nil, focusPhase == .idle else { return }
        transitionState(to: "sit", duration: 1.0)
    }

    @discardableResult
    func receiveCourierDrop(files: [URL], text: String?) -> Bool {
        let safeFiles = files.filter(\.isFileURL)
        let safeText = safeFiles.isEmpty
            ? (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !safeFiles.isEmpty || !safeText.isEmpty else { return false }
        pendingCourierPayload = CourierPayload(files: safeFiles, text: safeText)
        let menu = makeCourierTargetMenu()
        guard !courierChoices.isEmpty else {
            pendingCourierPayload = nil
            say("ยังไม่มีงาน Codex หรือ Claude ให้ส่ง", for: 3.5)
            return true
        }
        say("จะให้น้องส่งไปงานไหน?", for: 3.5)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: view.bounds.midX, y: view.bounds.maxY - 4), in: view)
        return true
    }

    private func makeCourierTargetMenu() -> NSMenu {
        let menu = NSMenu(title: "ส่งด้วยน้องแมว")
        courierChoices.removeAll()
        for (source, title) in [("codex", "Codex"), ("claude", "Claude Code")] {
            let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            let sessions = workSessions.filter { $0.source == source }.prefix(6)
            if sessions.isEmpty {
                let empty = NSMenuItem(title: "  ไม่มีงานล่าสุด", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            } else {
                for session in sessions {
                    let token = UUID().uuidString
                    courierChoices[token] = session
                    let item = NSMenuItem(title: "  " + sessionHeadline(session),
                                          action: #selector(chooseCourierTarget(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.representedObject = token
                    menu.addItem(item)
                }
            }
            if source == "codex" { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "คัดลอกไว้ให้วางด้วย ⌘V", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        return menu
    }

    @objc private func chooseCourierTarget(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String,
              let session = courierChoices[token], let payload = pendingCourierPayload else { return }
        courierChoices.removeAll()
        pendingCourierPayload = nil
        performCourierDelivery(payload, to: session)
    }

    private func performCourierDelivery(_ payload: CourierPayload, to session: WorkSession) {
        shepherdTarget = nil
        activeWorkNotice = nil
        activeContextRescue = nil
        bubbleTarget = nil
        if ProcessInfo.processInfo.environment["PIXELCAT_SIMCOURIER"] == nil {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(payload.pasteboardText, forType: .string)
        }
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.hurry = false
            self.openTarget(session)
            self.say("ส่ง \(payload.label) ให้ \(self.workSourceName(session)) แล้ว • วางด้วย ⌘V",
                     for: 7.0, target: session)
            self.transitionState(to: "sit", duration: 2.0)
        }
        // Calm และ Reduce Motion ใช้การส่งทันที ไม่เริ่ม courier แล้วถูก tick ถัดไปยกเลิกกลางทาง
        guard effectiveMotionLevel != .calm else {
            finish()
            return
        }
        let targetMidX = taskWindowRect(session)?.midX
            ?? (session.source == "codex" ? plat.maxX : plat.minX)
        dir = targetMidX >= x + spriteW / 2 ? 1 : -1
        target = clampX(x + dir * 120)
        hurry = true
        setState("courier", duration: 99, then: finish)
    }

    /// ทางที่จะพากลับไปหางาน เรียงตามความเจาะจง แยกออกมาเป็นค่าเดียวเพื่อตรวจได้
    enum OpenRoute: String { case deepLink, sessionLink, focusApp, folder, none }

    /// ลิงก์ที่พาไปห้องเดิมในแอป Claude ไม่ใช่เปิดห้องใหม่
    ///
    /// claude://resume สร้างห้องใหม่จาก transcript เดิม พอห้องนั้นยังเปิดอยู่
    /// จะได้ห้องชื่อซ้ำเพิ่มมาอีกอัน ส่วน claude://code/continue จะไปหาห้องที่มีอยู่
    /// ในรายการของแอปแล้วเปลี่ยนหน้าไปที่ห้องนั้นตรง ๆ ใช้ได้ทั้งห้องที่เปิดและปิดอยู่
    private func claudeSessionURL(_ sessionID: String) -> URL? {
        guard !sessionID.isEmpty, var c = URLComponents(string: "claude://code/continue") else {
            return nil
        }
        c.queryItems = [URLQueryItem(name: "session", value: sessionID),
                        URLQueryItem(name: "source", value: "pixelcat")]
        return c.url
    }

    private func openRoute(focus: String, path: String, pids: [Int],
                           sessionID: String) -> OpenRoute {
        if (focus.hasPrefix("warp://") || focus.hasPrefix("codex://")), URL(string: focus) != nil {
            return .deepLink
        }
        if claudeSessionURL(sessionID) != nil { return .sessionLink }
        if focusableApp(pids) != nil { return .focusApp }
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) { return .folder }
        return .none
    }

    private func openTarget(focus: String, path: String, pidList: String, sessionID: String) {
        let pids = pidList.split(separator: ",").compactMap { Int($0) }
        switch openRoute(focus: focus, path: path, pids: pids, sessionID: sessionID) {
        case .deepLink:
            // deep link ที่เจาะจงแท็บ — Warp สำหรับ Claude Code, codex:// สำหรับ Codex
            if let u = URL(string: focus), NSWorkspace.shared.open(u) { return }
        case .sessionLink:
            if let u = claudeSessionURL(sessionID), NSWorkspace.shared.open(u) { return }
        case .focusApp, .folder, .none:
            break
        }
        if let app = focusableApp(pids) { app.activate(); return }
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func noticeProjectName(_ name: String) -> String {
        name.count > 26 ? String(name.prefix(24)) + "…" : name
    }

    private func noticeKey(_ session: WorkSession) -> String {
        "\(session.source):\(session.id)"
    }

    private func workSourceName(_ session: WorkSession) -> String {
        session.source == "codex" ? "Codex" : "Claude"
    }

    private func returnRitualEvent(_ session: WorkSession) -> ReturnRitualEvent {
        ReturnRitualEvent(
            key: noticeKey(session),
            title: noticeProjectName(sessionHeadline(session)),
            source: session.source,
            state: session.state,
            updatedAt: session.updatedAt
        )
    }

    private func captureReturnRitual(_ sessions: [WorkSession], now: Double,
                                     idleSeconds: Double? = nil) {
        let idle = idleSeconds ?? CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: .init(rawValue: ~0)!
        )
        guard let summary = returnRitualTracker.observe(
            now: now, idleSeconds: idle, focusActive: focusPhase != .idle,
            events: sessions.map(returnRitualEvent)
        ) else { return }
        pendingReturnRitual = summary
    }

    private func returnRitualText(_ summary: ReturnRitualSummary) -> String {
        let minutes = max(10, Int(summary.awaySeconds / 60))
        guard !summary.events.isEmpty else {
            return "พ่อกลับมาแล้ว! หายไป \(minutes) นาที น้องคิดถึงนะคะ ทุกอย่างเรียบร้อยดี"
        }
        let items = summary.events.map { event -> String in
            let symbol: String
            switch event.importance {
            case .failed: symbol = "!"
            case .waiting: symbol = "?"
            case .done: symbol = "✓"
            case nil: symbol = "•"
            }
            return "\(symbol) \(event.title)"
        }.joined(separator: " • ")
        return "พ่อกลับมาแล้ว! ระหว่าง \(minutes) นาทีนี้: \(items) • คลิกดูงานสำคัญสุด"
    }

    private func showPendingReturnRitual() {
        guard let summary = pendingReturnRitual,
              focusPhase == .idle, !held, !airborne, !climbing, !chatBusy,
              activeWorkNotice == nil, activeContextRescue == nil else { return }
        pendingReturnRitual = nil
        let keys = Set(summary.events.map(\.key))
        workNoticeQueue.removeAll { keys.contains(noticeKey($0.session)) }
        let primary = summary.events.first.flatMap { event in
            workSessions.first { noticeKey($0) == event.key }
        }
        let text = returnRitualText(summary)

        shepherdTarget = nil
        if speechOn, let primary {
            activeWorkNotice = WorkNotice(session: primary, kind: .returned, text: text)
            say(text, for: 12.0, target: primary,
                actions: [SmartBubbleAction(id: .open, title: "เปิดงาน")])
        } else if speechOn {
            say(text, for: 7.0)
        }

        if reduceMotionEnabled || effectiveMotionLevel == .calm {
            playWorkEmotion(.returned)
            return
        }
        hurry = true
        target = clampX(NSEvent.mouseLocation.x - spriteW / 2)
        setState("walk", duration: 99) { [weak self] in
            guard let self else { return }
            self.hurry = false
            self.playWorkEmotion(.returned)
        }
    }

    /// พรีวิวจากเมนูโดยใช้สถานะงานจริง เพื่อดูทั้งท่าวิ่งและลิงก์เปิดงานได้ทันที
    @objc private func demoReturnRitual() {
        let events = workSessions.map(returnRitualEvent)
            .filter { $0.importance != nil }
            .sorted {
                let left = $0.importance?.rawValue ?? 0
                let right = $1.importance?.rawValue ?? 0
                return left == right ? $0.updatedAt > $1.updatedAt : left > right
            }
        pendingReturnRitual = ReturnRitualSummary(
            awaySeconds: 12 * 60,
            events: Array(events.prefix(3))
        )
        showPendingReturnRitual()
    }

    /// เปรียบเทียบสถานะราย session เพื่อบอกให้ชัดว่า "งานไหน" เปลี่ยน ไม่ใช่แค่สรุปรวม
    private func detectWorkNotices(_ sessions: [WorkSession]) {
        let next = Dictionary(uniqueKeysWithValues: sessions.map { (noticeKey($0), $0.state) })
        guard didSeedSessionStates else {
            previousSessionStates = next
            didSeedSessionStates = true
            return
        }
        let old = previousSessionStates
        previousSessionStates = next
        let finishedTogether = Set(sessions.compactMap { session -> String? in
            let key = noticeKey(session)
            guard let before = old[key],
                  ["idle", "done"].contains(session.state),
                  ["working", "busy", "input", "ask", "waiting"].contains(before)
            else { return nil }
            return key
        })
        let batchTargetKey = finishedTogether.count >= 2
            ? sessions.filter { finishedTogether.contains(noticeKey($0)) }
                .max(by: { $0.updatedAt < $1.updatedAt }).map(noticeKey)
            : nil

        for session in sessions.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            let key = noticeKey(session)
            guard let before = old[key], before != session.state else { continue }
            acknowledgedWorkKeys.remove(key)
            waitingReminderSent.remove(key)
            snoozedWorkUntil.removeValue(forKey: key)
            let name = noticeProjectName(sessionHeadline(session))
            let source = workSourceName(session)
            let notice: WorkNotice?
            switch session.state {
            case "idle" where ["working", "busy", "input", "ask", "waiting"].contains(before),
                 "done" where ["working", "busy", "input", "ask", "waiting"].contains(before):
                if let batchTargetKey {
                    guard key == batchTargetKey else { continue }
                    notice = WorkNotice(
                        session: session, kind: .batchDone,
                        text: "★ \(finishedTogether.count) งานเสร็จพร้อมกัน • คลิกเปิดงานล่าสุดใน \(source)"
                    )
                } else {
                    notice = WorkNotice(session: session, kind: .done,
                                        text: "✓ \(name) เสร็จแล้ว • คลิกเปิด \(source)")
                }
            case "input", "ask", "waiting":
                notice = WorkNotice(session: session, kind: .input,
                                    text: "\(name) รอคำตอบ • คลิกเปิด \(source)")
            case "fail", "failed", "error":
                notice = WorkNotice(session: session, kind: .failed,
                                    text: "! \(name) มีปัญหา • คลิกเปิด \(source)")
            default:
                notice = nil
            }
            if let notice { enqueueWorkNotice(notice) }
        }
    }

    /// เตือนซ้ำเฉพาะงานที่รอเกินกำหนด ยังไม่ถูกเปิดดู และไม่อยู่ในโหมดโฟกัส
    private func remindLongWaitingWork(_ sessions: [WorkSession], now: Double) {
        let live = Set(sessions.map(noticeKey))
        acknowledgedWorkKeys = acknowledgedWorkKeys.intersection(live)
        snoozedWorkUntil = snoozedWorkUntil.filter { live.contains($0.key) }
        waitingReminderSent = Set(waitingReminderSent.filter { key in
            sessions.contains { noticeKey($0) == key && isWaiting($0.state) }
        })
        guard focusPhase == .idle, !held else { return }

        for session in sessions.sorted(by: { $0.updatedAt < $1.updatedAt })
        where isWaiting(session.state) && now - session.updatedAt >= WAIT_REMINDER_AFTER {
            let key = noticeKey(session)
            guard now >= (snoozedWorkUntil[key] ?? 0) else { continue }
            guard !acknowledgedWorkKeys.contains(key), !waitingReminderSent.contains(key) else {
                continue
            }
            waitingReminderSent.insert(key)
            let minutes = max(1, Int((now - session.updatedAt) / 60))
            let name = noticeProjectName(sessionHeadline(session))
            let source = workSourceName(session)
            enqueueWorkNotice(WorkNotice(
                session: session, kind: .input,
                text: "\(name) รอคำตอบมา \(minutes) นาทีแล้ว • คลิกเปิด \(source)"
            ))
        }
    }

    /// งานที่รันนานทำให้น้องหยุดเดินมานั่งเฝ้าเงียบ ๆ เพียงหนึ่งครั้งต่อช่วง working
    private func watchLongRunningWork(_ sessions: [WorkSession], now: Double) {
        let running = sessions.filter { ["working", "busy"].contains($0.state) }
        let live = Set(running.map(noticeKey))
        watchedLongWorkKeys = watchedLongWorkKeys.intersection(live)
        guard focusPhase == .idle, activeWorkNotice == nil, !held, !airborne,
              !climbing, !petting, !napForced,
              ["walk", "sit", "lick", "stretch"].contains(state) else { return }

        guard let session = running.sorted(by: { $0.updatedAt < $1.updatedAt }).first(where: {
            now - $0.updatedAt >= LONG_WORK_POSE_AFTER
                && !watchedLongWorkKeys.contains(noticeKey($0))
        }) else { return }

        watchedLongWorkKeys.insert(noticeKey(session))
        if effectiveMotionLevel == .calm {
            transitionState(to: "sit", duration: 5.0) { [weak self] in self?.pickIdle() }
        } else {
            setState("tilt", duration: effectiveMotionLevel == .playful ? 1.0 : 0.65) {
                [weak self] in
                self?.setState("sit", duration: 5.0) { [weak self] in self?.pickIdle() }
            }
        }
    }

    private func enqueueWorkNotice(_ notice: WorkNotice) {
        let duplicate = activeWorkNotice.map {
            $0.session.source == notice.session.source
                && $0.session.id == notice.session.id && $0.kind == notice.kind
        } == true || workNoticeQueue.contains {
            $0.session.source == notice.session.source
                && $0.session.id == notice.session.id && $0.kind == notice.kind
        }
        guard !duplicate else { return }
        // สวิตช์ "พูดได้" คุมเฉพาะ bubble; ภาษากายต้องยังแจ้งสถานะได้เสมอ
        guard speechOn else {
            if focusPhase == .idle { playWorkEmotion(notice.kind) }
            return
        }
        workNoticeQueue.append(notice)
        showNextWorkNotice()
    }

    private func showNextWorkNotice() {
        guard speechOn, focusPhase == .idle, !held, !chatBusy, !companionReplyProtected,
              activeWorkNotice == nil, activeContextRescue == nil,
              !workNoticeQueue.isEmpty else { return }
        let notice = workNoticeQueue.removeFirst()
        activeWorkNotice = notice
        if [.testPassed, .testFailed, .permission].contains(notice.session.activity.kind) {
            currentWorkActivitySignature = workActivitySignature(notice.session)
            seenWorkActivitySignatures.insert(currentWorkActivitySignature)
            playBuildTestAnimation(notice.session.activity.kind)
        } else {
            playWorkEmotion(notice.kind)
        }
        say(notice.text, for: 8.0, target: notice.session,
            actions: smartActions(for: notice.kind))
        switch notice.kind {
        case .input:
            startTaskShepherd(notice.session)
        case .failed:
            // ให้เห็นท่าร้องไห้ก่อน แล้วค่อยพาไปยังหน้าต่างที่ต้องแก้
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in
                guard let self, self.activeWorkNotice?.session.id == notice.session.id else { return }
                self.startTaskShepherd(notice.session)
            }
        case .done, .batchDone, .returned:
            shepherdTarget = nil
            break
        }
    }

    private func smartActions(for kind: WorkNoticeKind) -> [SmartBubbleAction] {
        switch kind {
        case .done, .batchDone:
            return [SmartBubbleAction(id: .open, title: "เปิดงาน"),
                    SmartBubbleAction(id: .summarize, title: "สรุปให้")]
        case .returned:
            return [SmartBubbleAction(id: .open, title: "เปิดงาน")]
        case .input:
            return [SmartBubbleAction(id: .open, title: "เปิดตอบ"),
                    SmartBubbleAction(id: .later, title: "ไว้ทีหลัง")]
        case .failed:
            return [SmartBubbleAction(id: .open, title: "เปิดงาน"),
                    SmartBubbleAction(id: .helpFix, title: "ช่วยแก้")]
        }
    }

    func performSmartBubbleAction(_ action: SmartBubbleActionID) {
        guard let notice = activeWorkNotice, let session = bubbleTarget else { return }
        switch action {
        case .open:
            openBubbleTarget()
        case .summarize:
            let prompt = "ช่วยสรุปผลลัพธ์ของงานนี้เป็น 3 ข้อสั้น ๆ และบอกสิ่งที่ควรตรวจหรือทำต่อ"
            deliverSmartPrompt(prompt, to: session,
                               confirmation: "คัดลอกคำขอสรุปแล้ว • วางด้วย ⌘V")
        case .helpFix:
            let latest = session.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = latest.isEmpty ? "" : "\nข้อความล่าสุด: \(String(latest.prefix(500)))"
            let prompt = "ช่วยวิเคราะห์สาเหตุที่งานนี้พังจาก error ล่าสุด แก้ให้เรียบร้อย และรันทดสอบที่เกี่ยวข้อง\(detail)"
            deliverSmartPrompt(prompt, to: session,
                               confirmation: "คัดลอกคำขอช่วยแก้แล้ว • วางด้วย ⌘V")
        case .later:
            guard notice.kind == .input else { return }
            let key = noticeKey(session)
            snoozedWorkUntil[key] = Date().timeIntervalSince1970 + 5 * 60
            waitingReminderSent.remove(key)
            activeWorkNotice = nil
            bubbleTarget = nil
            shepherdTarget = nil
            bubbleView.actions = []
            speakFor = 0
            say("ได้เลย อีก 5 นาทีน้องค่อยเตือนใหม่นะ", for: 3.5)
        }
    }

    private func deliverSmartPrompt(_ prompt: String, to session: WorkSession,
                                    confirmation: String) {
        let simulated = ProcessInfo.processInfo.environment["PIXELCAT_SIMWORKNOTICE"] != nil
        if simulated {
            lastSimulatedActionPrompt = prompt
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(prompt, forType: .string)
        }
        acknowledgeWork(source: session.source, id: session.id)
        activeWorkNotice = nil
        bubbleTarget = nil
        shepherdTarget = nil
        bubbleView.actions = []
        openTarget(session)
        speakFor = 0
        say(confirmation, for: 6.0)
    }

    /// ภาษากายของสถานะงาน แยกจาก bubble เพื่อให้ทั้ง session hooks และ inbox hooks ใช้ร่วมกัน
    private func playWorkEmotion(_ kind: WorkNoticeKind) {
        guard !held else { return }
        emotionKind = kind
        noticeMotionFor = 2.4
        let level = effectiveMotionLevel
        switch kind {
        case .done, .batchDone, .returned:
            // เสียงบอกว่า AI ทำงานเสร็จ: ครืดสั้น ๆ เบากว่าเสียงเล่นครึ่งหนึ่ง
            // และเว้นจังหวะยาว งานหลายตัวเสร็จไล่กันก็ได้ยินครั้งเดียว
            if kind != .returned {
                CatVoice.shared.play(.trill, minGap: 20.0, gapAny: 1.5, volumeScale: 0.8)
            }
            // สงบ=ยืดแล้วนั่ง, ปกติ/ซน=เด้งหนึ่งครั้ง; ไม่มีโหมดไหนสั่นวน
            let s = max(0.7, scale * 0.85)
            let isBatch = kind == .batchDone
            let heartCount = reduceMotionEnabled ? 0 : (isBatch
                ? (level == .calm ? 4 : (level == .normal ? 10 : 14))
                : (level == .calm ? 2 : (level == .normal ? 6 : 9)))
            for i in 0..<heartCount {
                hearts.append(HeartsView.Heart(
                    x: spriteW * (0.15 + CGFloat(i % 7) * 0.11), y: CGFloat(i % 3) * 5,
                    vy: CGFloat(48 + i * 5), life: 1.5, s: s,
                    isStar: isBatch ? i % 2 == 0 : i % 3 == 0))
            }
            stepHearts(0)
            if level == .calm {
                setState("stretch", duration: 0.4) { [weak self] in
                    self?.setState("sit", duration: 2.8) { [weak self] in self?.pickIdle() }
                }
            } else {
                transitionState(to: "jump", duration: 0.42) { [weak self] in
                    self?.transitionState(to: "sit", duration: 2.8) { [weak self] in
                        self?.pickIdle()
                    }
                }
            }
        case .input:
            // เอียงหัวหนึ่งครั้งแล้วนั่งรอ แทนการโยกต่อเนื่อง
            let tiltFor = level == .calm ? 0.8 : (level == .normal ? 1.25 : 1.7)
            setState("tilt", duration: tiltFor) { [weak self] in
                self?.setState("sit", duration: 3.2) { [weak self] in self?.pickIdle() }
            }
        case .failed:
            // ก้ม/เอียงหัวหนึ่งจังหวะ แล้วหลับตานั่งร้องไห้ โดยไม่เขย่าลำตัว
            setState("tilt", duration: level == .calm ? 0.3 : 0.45) { [weak self] in
                self?.setState("sit", duration: 4.0) { [weak self] in self?.pickIdle() }
            }
        }
        applyFrame()
    }

    /// Interface ฝั่งภาพรับศัพท์กลางเพียงชนิดเดียว ไม่ต้องรู้ว่า event มาจาก Codex หรือ Claude
    private func playBuildTestAnimation(_ kind: WorkActivityKind) {
        guard focusPhase == .idle, !held, !chatBusy else { return }
        activeWorkActivityKind = kind
        target = nil
        hurry = false
        switch kind {
        case .coding:
            setState("coding", duration: 999)
        case .build:
            setState("buildWork", duration: 999)
        case .testing:
            setState("testWatch", duration: 999)
        case .testPassed:
            setState("testPass", duration: 1.25) { [weak self] in
                self?.setState("sit", duration: 2.4) { [weak self] in self?.pickIdle() }
            }
        case .testFailed:
            // กระดาษ error และน้ำตาอยู่ในเฟรมแล้ว จึงไม่เพิ่ม shake/wobble ซ้ำ
            setState("testFail", duration: 3.8) { [weak self] in
                self?.setState("sit", duration: 2.4) { [weak self] in self?.pickIdle() }
            }
        case .permission:
            setState("permission", duration: 6.0) { [weak self] in
                self?.setState("sit", duration: 3.0)
            }
        case .idle:
            break
        }
        applyFrame()
    }

    /// เลือกกิจกรรมที่ต้องเห็นที่สุดเพียงหนึ่งงาน ป้องกันหลาย task แย่งท่ากันทุกครึ่งวินาที
    private func updateBuildTestAwareness(_ sessions: [WorkSession]) {
        let signaled = sessions.filter { $0.activity.kind != .idle }
            .map { ($0, workActivitySignature($0)) }
        let liveSignatures = Set(signaled.map(\.1))
        seenWorkActivitySignatures.formIntersection(liveSignatures)
        let oneShot: Set<WorkActivityKind> = [.testPassed, .testFailed, .permission]
        let candidates = signaled.filter {
            !oneShot.contains($0.0.activity.kind) || !seenWorkActivitySignatures.contains($0.1)
        }
        guard let selected = candidates.max(by: {
            if $0.0.activity.kind.priority == $1.0.activity.kind.priority {
                return $0.0.updatedAt < $1.0.updatedAt
            }
            return $0.0.activity.kind.priority < $1.0.activity.kind.priority
        }) else {
            currentWorkActivitySignature = ""
            if [WorkActivityKind.coding, .build, .testing].contains(activeWorkActivityKind),
               ["coding", "buildWork", "testWatch"].contains(state) {
                activeWorkActivityKind = .idle
                setState("sit", duration: 2.0) { [weak self] in self?.pickIdle() }
            }
            return
        }

        let session = selected.0
        let signature = selected.1
        guard signature != currentWorkActivitySignature,
              focusPhase == .idle, !held, !chatBusy,
              activeWorkNotice == nil, activeContextRescue == nil else { return }
        currentWorkActivitySignature = signature
        if oneShot.contains(session.activity.kind) {
            seenWorkActivitySignatures.insert(signature)
        }
        playBuildTestAnimation(session.activity.kind)
    }

    private func workActivitySignature(_ session: WorkSession) -> String {
        noticeKey(session) + ":" + session.activity.kind.rawValue
            + ":" + session.activity.fingerprint
    }

    private var focusActionTitle: String {
        switch focusPhase {
        case .idle: return "เริ่มโฟกัส 25 นาที"
        case .focus: return "หยุดโฟกัส • \(focusClock)"
        case .rest: return "จบเวลาพัก • \(focusClock)"
        }
    }

    private var focusClock: String {
        let total = max(0, Int(ceil(focusRemaining)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func updateFocusUI(force: Bool = false) {
        let second = max(0, Int(ceil(focusRemaining)))
        guard force || second != focusDisplaySecond else { return }
        focusDisplaySecond = second
        focusMenuItem?.title = focusActionTitle
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        let badge = workAlertCount > 0 ? " • \(workAlertCount)" : ""
        switch focusPhase {
        case .idle: statusItem.button?.title = "🐈\(badge)"
        case .focus: statusItem.button?.title = "🐈 \(focusClock)\(badge)"
        case .rest: statusItem.button?.title = "🐈 พัก \(focusClock)\(badge)"
        }
    }

    @objc private func toggleFocus() {
        if focusPhase == .idle {
            if let rescue = activeContextRescue {
                // ผู้ใช้เลือก Focus หลังเห็นกล่องแล้ว: คืนสิทธิ์ให้เตือนซ้ำหลัง Focus จบ
                contextRescueOffered.remove(noticeKey(rescue.session))
                activeContextRescue = nil
                bubbleTarget = nil
                speakFor = 0
                hideBubble()
            }
            focusPhase = .focus
            focusRemaining = 25 * 60
            focusDisplaySecond = -1
            activeStreak = 0
            breakNudged = false
            target = nil
            hurry = false
            say("เริ่มโฟกัส 25 นาที เราเงียบเป็นเพื่อนนะ", for: 4)
            transitionState(to: "sit", duration: focusRemaining)
        } else {
            focusPhase = .idle
            focusRemaining = 0
            focusDisplaySecond = -1
            napForced = false
            say("หยุดโหมดโฟกัสแล้ว", for: 2.5)
            pickIdle()
        }
        updateFocusUI(force: true)
    }

    private func updateFocus(_ dt: Double) {
        guard focusPhase != .idle else { return }
        focusRemaining = max(0, focusRemaining - dt)
        updateFocusUI()
        guard focusRemaining <= 0 else { return }

        if focusPhase == .focus {
            focusPhase = .rest
            focusRemaining = 5 * 60
            focusDisplaySecond = -1
            activeStreak = 0
            breakNudged = false
            updateFocusUI(force: true)
            say("ครบ 25 นาทีแล้ว พักสายตา 5 นาทีนะ", for: 6)
            setState("stretch", duration: 1.6) { [weak self] in
                guard let self, self.focusPhase == .rest else { return }
                self.setState("sleep", duration: self.focusRemaining)
            }
        } else {
            focusPhase = .idle
            focusRemaining = 0
            focusDisplaySecond = -1
            napForced = false
            updateFocusUI(force: true)
            say("พักครบแล้ว พร้อมลุยต่อไหม", for: 5)
            setState("stretch", duration: 1.6) { [weak self] in self?.pickIdle() }
        }
    }

    @objc private func toggleFollow() {
        follow.toggle()
        if follow { say("ตามติดเลย"); setState("walk", duration: 99) } else { pickIdle() }
        syncMenu()
    }

    private var onTop = true

    @objc private func toggleVoice() {
        CatVoice.shared.enabled.toggle()
        if CatVoice.shared.enabled {
            CatVoice.shared.play(.mew, minGap: 0)     // ให้ได้ยินทันทีว่าเปิดแล้วเสียงเป็นยังไง
        } else {
            CatVoice.shared.stopAll()
        }
        syncMenu()
    }

    @objc private func toggleSpeech() {
        speechOn.toggle()
        UserDefaults.standard.set(speechOn, forKey: "speechOn")
        if speechOn {
            showNextWorkNotice()
            if activeWorkNotice == nil {
                say("เหมียว~")
                CatVoice.shared.play(.meow, minGap: 0)
            }
        } else {
            workNoticeQueue.removeAll()
            activeContextRescue = nil
            speakFor = 0
            hideBubble()
        }
        syncMenu()
    }

    @objc private func toggleOnTop() {
        onTop.toggle()
        window.level = onTop ? .floating
                             : NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)))
        bubbleWindow.level = window.level
        heartWindow.level = window.level
        ballWindow.level = window.level
        geckoWindow.level = window.level
        syncMenu()
    }

    @objc private func togglePause() {
        paused.toggle()
        if paused { transitionState(to: "sit", duration: 999) } else { pickIdle() }
        syncMenu()
    }

    @objc private func napNow() {
        napForced = true
        say("ง่วงแล้ว…")
        setState("sleep", duration: 99999)   // หลับยาวจนกว่าจะปลุก
    }

    @objc private func wakeNow() {
        napForced = false
        say("อ๊าาา~")
        setState("stretch", duration: 1.6) { [weak self] in self?.pickIdle() }
    }

    @objc private func comeHere() {
        say("มาแล้วววว")
        target = NSEvent.mouseLocation.x - spriteW / 2
        setState("walk", duration: 99) { [weak self] in
            self?.transitionState(to: "sit", duration: 4)
        }
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        scale = CGFloat(sender.tag) / 10
        UserDefaults.standard.set(sender.tag, forKey: "catScaleTenths128")
        x = clampX(x)
        y = groundY()
        applyFrame()
        syncMenu()
    }

    @objc private func setMotionLevel(_ sender: NSMenuItem) {
        guard let level = MotionLevel(rawValue: sender.tag - 20) else { return }
        motionLevel = level
        UserDefaults.standard.set(level.rawValue, forKey: "motionLevel")
        cancelEnergeticMotionIfNeeded()
        applyFrame()
        syncMenu()
        if reduceMotionEnabled {
            say("เปิด Reduce Motion อยู่ เลยขยับแบบสงบนะ", for: 3.2)
        } else {
            say("ปรับความซนเป็น \(level.label) แล้ว", for: 2.4)
        }
    }

    /// หยุดเฉพาะ motion แรงที่กำลังเตรียมหรือกำลังวิ่งเมื่อเข้า Calm/Reduce Motion
    /// การเดินธรรมดายังทำต่อได้ เพราะไม่ได้ตั้ง hurry หรือ energetic intent เหล่านี้
    private func cancelEnergeticMotionIfNeeded() {
        guard effectiveMotionLevel == .calm else { return }
        zoomies = 0
        let shouldSettle = hurry || pounceTarget != nil || autoDescending || climbing
        hurry = false
        pounceTarget = nil
        guard shouldSettle, !airborne else { return }
        if climbing {
            // การไต่แนวดิ่งยังไม่ได้เปลี่ยน plat จึงกลับมานั่งบนขอบต้นทางได้โดยไม่ตกกลางอากาศ
            climbing = false
            y = plat.y
            x = clampX(x)
        }
        autoDescending = false
        target = nil
        afterState = nil
        setState("sit", duration: 3.0)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: คำพูด

    private func setupBubble() {
        bubbleWindow.isOpaque = false
        bubbleWindow.backgroundColor = .clear
        bubbleWindow.hasShadow = false
        bubbleWindow.level = window.level
        bubbleWindow.collectionBehavior = window.collectionBehavior
        bubbleWindow.ignoresMouseEvents = true
        bubbleView.pet = self
        bubbleWindow.contentView = bubbleView
        bubbleWindow.alphaValue = 0
    }

    private func say(_ text: String, for seconds: Double = 2.6,
                     target: WorkSession? = nil,
                     actions: [SmartBubbleAction] = []) {
        guard speechOn else { return }
        // ข้อความแจ้งงานสำคัญอยู่ค้างให้อ่านและคลิกได้ ไม่ให้อารมณ์พูดเล่นมาทับ
        if (activeWorkNotice != nil || activeContextRescue != nil) && target == nil { return }
        bubbleView.text = text
        bubbleView.actions = actions
        fileSearchTarget = nil
        bubbleTarget = target
        bubbleView.interactive = target != nil || !actions.isEmpty
        bubbleWindow.ignoresMouseEvents = target == nil && actions.isEmpty
        let size = BubbleView.size(for: text, actions: actions)
        bubbleWindow.setContentSize(size)
        placeBubble()
        bubbleWindow.orderFront(nil)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.12
            bubbleWindow.animator().alphaValue = 1
        }
        speakFor = seconds
    }

    private func placeBubble() {
        let size = bubbleWindow.frame.size
        let bx = (x + spriteW / 2 - size.width / 2).rounded()
        let by = (y + winH - 1).rounded()
        bubbleWindow.setFrameOrigin(NSPoint(x: bx, y: by))
    }

    private func hideBubble() {
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.15
            bubbleWindow.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.speakFor <= 0 else { return }
            self.bubbleWindow.orderOut(nil)
            self.bubbleWindow.ignoresMouseEvents = true
            self.bubbleView.interactive = false
            self.bubbleView.actions = []
            self.companionReplyProtected = false
            self.activeWorkNotice = nil
            self.activeContextRescue = nil
            if self.shepherdTarget?.id == self.bubbleTarget?.id {
                self.shepherdTarget = nil
            }
            self.bubbleTarget = nil
            self.fileSearchTarget = nil
            self.showNextWorkNotice()
        })
    }

    /// BubbleView เรียกเมธอดนี้เมื่อกล่องแจ้งงานถูกคลิก
    func openBubbleTarget() {
        if let file = fileSearchTarget {
            fileSearchTarget = nil
            bubbleView.interactive = false
            bubbleWindow.ignoresMouseEvents = true
            revealFoundFile(file)
            speakFor = 0
            hideBubble()
            return
        }
        if openContextRescueIfPresent() { return }
        guard let target = bubbleTarget else { return }
        acknowledgeWork(source: target.source, id: target.id)
        activeWorkNotice = nil
        bubbleTarget = nil
        bubbleView.interactive = false
        bubbleWindow.ignoresMouseEvents = true
        openTarget(target)
        speakFor = 0
        hideBubble()
    }

    private func ambientLine() -> String {
        let h = Calendar.current.component(.hour, from: Date())
        if (h >= 23 || h < 5), state != "sleep", Double.random(in: 0..<1) < 0.35 {
            return NIGHT_LINES.randomElement()!
        }
        return (LINES[state] ?? LINES["sit"]!).randomElement()!
    }

    // MARK: geometry

    private func currentScreen() -> NSScreen {
        let point = NSPoint(x: x + spriteW / 2, y: y + winH / 2)
        return NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func groundY() -> CGFloat { plat.y }

    private func clampX(_ value: CGFloat) -> CGFloat {
        min(max(value, plat.minX), plat.maxX - spriteW)
    }

    private func applyFrame() {
        var name = poseName()
        let sadExpression = emotionKind == .failed && noticeMotionFor > 0
        if sadExpression, name == "sit", POSES["sitBlink"] != nil {
            name = "sitBlink"
        } else if blinking, POSES[name + "Blink"] != nil {
            name += "Blink"
        }
        let pose = POSES[name]!
        let index = pose.start + min(frameIdx, pose.count - 1)
        view.image = Sheet.shared.frames[index]
        view.mask = Sheet.shared.masks[index]
        view.span = Sheet.shared.spans[index]
        view.anchorX = Sheet.shared.anchorOffsetsX[index]
        view.anchorY = Sheet.shared.anchorOffsetsY[index]
        view.flip = dir < 0
        view.showShadow = !held && y <= groundY() + 1   // ยกขึ้นกลางอากาศแล้วเงาหาย

        // Small, pixel-aligned secondary motions make the sprite feel less
        // mechanical without softening its outline or changing hit testing.
        let phase = frameIdx % max(1, pose.count)
        view.motionX = 0
        view.motionY = 0
        view.motionHeight = 0
        view.showTears = sadExpression && poseName() == "sit"
        switch poseName() {
        case "lick":  view.motionY = [0, 1][phase % 2]
        case "sleep": view.motionHeight = [0, 1][phase % 2]
        case "held":
            view.motionX = [-1, 1][phase % 2]
            view.motionY = [0, 1][phase % 2]
        default: break
        }
        // ภาษากายของกล่องงานเป็นจังหวะเดียว และปรับความแรงตามระดับความซน
        if noticeMotionFor > 0, let kind = emotionKind {
            let p = Int((2.4 - noticeMotionFor) * 10) % 6
            let level = effectiveMotionLevel
            switch kind {
            case .done, .batchDone, .returned:
                // เด้งขึ้นเป็นโค้งเดียวแล้วหยุด ไม่โยกซ้ายขวาหรือวนซ้ำ
                if noticeMotionFor > 1.7 {
                    switch level {
                    case .calm: view.motionY += [0, 1, 2, 1, 0, 0][p]
                    case .normal: view.motionY += [0, 4, 7, 4, 1, 0][p]
                    case .playful: view.motionY += [0, 6, 11, 6, 2, 0][p]
                    }
                }
            case .input:
                if noticeMotionFor > 1.7 {
                    switch level {
                    case .calm: break
                    case .normal:
                        view.motionX += [-1, 0, 1, 0, 0, 0][p]
                        view.motionY += [0, 1, 0, 1, 0, 0][p]
                    case .playful:
                        view.motionX += [-2, 0, 2, 0, -1, 0][p]
                        view.motionY += [0, 2, 0, 2, 0, 0][p]
                    }
                }
            case .failed:
                // ยุบตัวลงครั้งเดียว ไม่มี motion แกน X และไม่สั่นวน
                if noticeMotionFor > 1.7 {
                    switch level {
                    case .calm: break
                    case .normal: view.motionY += [0, -1, -2, -2, -1, 0][p]
                    case .playful: view.motionY += [0, -1, -3, -3, -1, 0][p]
                    }
                }
            }
        }
        if landingMotion > 0.14 {
            view.motionHeight = -3
        } else if landingMotion > 0 {
            view.motionHeight = 1
        }
        let dp = 1 / (window.screen?.backingScaleFactor ?? 2)
        let sx = (x / dp).rounded() * dp, sy = (y / dp).rounded() * dp
        window.setFrame(NSRect(x: sx, y: sy, width: spriteW, height: winH), display: false)
        if speakFor > 0 { placeBubble() }
        view.needsDisplay = true
    }

    // MARK: ลูบ

    func startPetting() {
        held = false
        petting = true
        napForced = false
        landAction = nil
        purrCount = 0
        setState("sit", duration: 9999)
        say("ครืดๆ", for: 2.2)
        CatVoice.shared.play(.purr, minGap: 1.0)
    }

    func petStroke() {
        guard petting, !reduceMotionEnabled else { return }
        let s = scale * 0.8
        hearts.append(HeartsView.Heart(x: CGFloat.random(in: 0...(spriteW - 7 * s)),
                                       y: 0, vy: CGFloat.random(in: 34...52),
                                       life: 1.3, s: s))
        purrCount += 1
        if purrCount % 3 == 0 {
            say(["ครืดๆ", "อีกๆ", "ตรงนั้นแหละ", "ครืดดด", "สบายจัง"].randomElement()!, for: 2.0)
            CatVoice.shared.play(.purr, minGap: 2.0)
        }
    }

    func stopPetting() {
        guard petting else { return }
        petting = false
        say(["อีกสิ", "หมดแล้วเหรอ", "เอาอีก"].randomElement()!, for: 1.7)
        CatVoice.shared.play(.mew, minGap: 3.0)
        setState("stretch", duration: 0.8) { [weak self] in self?.pickIdle() }
    }

    private func stepHearts(_ dt: Double) {
        if hearts.isEmpty {
            if heartWindow.isVisible { heartWindow.orderOut(nil) }
            return
        }
        for i in hearts.indices {
            hearts[i].y += hearts[i].vy * CGFloat(dt)
            hearts[i].life -= CGFloat(dt)
        }
        hearts.removeAll { $0.life <= 0 }
        heartWindow.setContentSize(NSSize(width: spriteW, height: spriteW))
        heartWindow.setFrameOrigin(NSPoint(x: x.rounded(), y: (y + winH * 0.5).rounded()))
        if !heartWindow.isVisible { heartWindow.orderFront(nil); heartWindow.alphaValue = 1 }
        heartsView.hearts = hearts
        heartsView.needsDisplay = true
    }

    // MARK: ลูกบอล กับ จิ้งจก

    private func propImage(_ name: String, _ i: Int) -> CGImage {
        let p = POSES[name]!
        return Sheet.shared.frames[p.start + ((i % p.count) + p.count) % p.count]
    }

    private func setupProp(_ w: NSWindow, _ v: NSView) {
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = window.level
        w.collectionBehavior = window.collectionBehavior
        w.ignoresMouseEvents = true
        w.contentView = v
        w.alphaValue = 0
    }

    @objc func throwBall() {
        let side: CGFloat = Bool.random() ? 1 : -1
        bx = min(max(x + spriteW / 2 + side * spriteW * 2.2, plat.minX + 30), plat.maxX - 30)
        by = plat.y + 180
        bvx = (x + spriteW / 2 - bx) > 0 ? 60 : -60
        bvy = 0
        ballOn = true; ballLife = 80; ballHits = 0; ballRest = nil
        ballWindow.setContentSize(NSSize(width: spriteW, height: CGFloat(SPRITE_H) * scale))
        ballWindow.alphaValue = 1
        ballWindow.orderFront(nil)
        say(["ลูกบอล!", "อะไรน่ะ", "เอาละ"].randomElement()!, for: 1.4)
        if !airborne && !held && !petting {
            setState("tilt", duration: 0.9) { [weak self] in self?.pickIdle() }
        }
    }

    private func despawnBall() {
        ballOn = false
        ballWindow.orderOut(nil)
    }

    private func stepBall(_ dt: Double) {
        guard ballOn else { return }
        ballLife -= dt
        if ballLife <= 0 { despawnBall(); return }

        let prevY = by
        bvy -= 2000 * CGFloat(dt)
        bx += bvx * CGFloat(dt)
        by += bvy * CGFloat(dt)

        if bvy <= 0 {
            let hit = platforms.filter { bx >= $0.minX && bx <= $0.maxX && prevY >= $0.y - 3 && by <= $0.y }
                               .max(by: { $0.y < $1.y })
            if let p = hit {
                by = p.y
                bvy = -bvy * 0.50
                if abs(bvy) < 45 { bvy = 0 }
                bvx *= 0.86
                ballRest = p.y
            } else if let r = ballRest, by < r - 0.5, abs(bvy) < 80 {
                by = r; bvy = 0            // กันบอลไถลจมลงไปใต้พื้น
            }
        }
        if abs(bvy) < 1 { bvx *= CGFloat(pow(0.52, dt)) }        // แรงเสียดทานตอนกลิ้ง
        let f = currentScreen().frame
        if bx < f.minX + 10 { bx = f.minX + 10; bvx = abs(bvx) * 0.55 }
        if bx > f.maxX - 10 { bx = f.maxX - 10; bvx = -abs(bvx) * 0.55 }
        if by < f.minY - 300 { despawnBall(); return }

        ballSpin += Double(bvx) * dt * 0.09
        ballView.image = propImage("ball", Int(ballSpin.rounded()))
        ballView.needsDisplay = true
        ballWindow.setFrameOrigin(NSPoint(x: (bx - 16 * scale).rounded(), y: by.rounded()))
    }

    private func spawnGecko() {
        let vf = currentScreen().visibleFrame        // จิ้งจกต้องโผล่บนจอเดียวกับแมว
        let here = platforms.filter { $0.y >= vf.minY - 2 && $0.y <= vf.maxY }
        var pool = here.filter { !$0.isFloor && $0.y > y + 40 }
        if pool.isEmpty { pool = here.filter { !$0.isFloor } }
        if pool.isEmpty { pool = here }               // ไม่มีขอบหน้าต่างเลย → ให้วิ่งบนพื้น
        guard let p = pool.randomElement(), p.maxX - p.minX > 140 else {
            geckoIn = Double.random(in: 25...45); return
        }
        geckoPlat = p
        gx = CGFloat.random(in: (p.minX + 40)...(p.maxX - 40))
        gy = p.y
        gdir = Bool.random() ? 1 : -1
        geckoOn = true; geckoLife = 26; geckoWait = 0.8; geckoFrame = 0
        geckoWindow.setContentSize(NSSize(width: spriteW, height: CGFloat(SPRITE_H) * scale))
        updateGeckoFrame()
        geckoWindow.alphaValue = 1
        geckoWindow.orderFront(nil)
        // ถ้าแมวกำลังอยู่เฉย ๆ ให้หันไปสนใจทันที ไม่ต้องรอรอบ idle ถัดไป
        guard !airborne, !held, !climbing else { return }
        if state == "sleep" {
            guard !napForced else { return }          // ถ้าสั่งให้นอนจากเมนู ก็ปล่อยให้นอน
            say(["เอ๊ะ อะไรน่ะ", "ตื่นแล้ว!", "ได้ยินเสียง"].randomElement()!, for: 1.7)
            setState("stretch", duration: 0.9) { [weak self] in self?.pickIdle() }
        } else if ["sit", "lick", "stretch"].contains(state) {
            pickIdle()
        }
    }

    private func despawnGecko(escaped: Bool) {
        geckoOn = false
        geckoPlat = nil
        geckoWindow.orderOut(nil)
        geckoIn = Double.random(in: 45...110)
        if escaped { say(["หนีไปได้…", "แง หลุด", "ไว้เจอกันใหม่"].randomElement()!, for: 1.8) }
    }

    private func dismissGeckoByClick() {
        guard geckoOn else { return }
        despawnGecko(escaped: false)
        guard focusPhase == .idle, !held, !airborne, !climbing, !chatBusy else { return }
        say(["แวบ! หายไปแล้ว", "จ๊ะเอ๋!", "พ่อจับได้ก่อนน้องอีก"].randomElement()!, for: 2.0)
        setState("tilt", duration: 0.7) { [weak self] in self?.pickIdle() }
    }

    private func updateGeckoFrame() {
        let pose = POSES["gecko"]!
        let index = pose.start + (Int(geckoFrame * pose.fps) % pose.count)
        geckoView.image = Sheet.shared.frames[index]
        geckoView.pixelMask = Sheet.shared.masks[index]
        geckoView.needsDisplay = true
    }

    private func stepGecko(_ dt: Double) {
        if !geckoOn {
            geckoIn -= dt
            if geckoIn <= 0 { spawnGecko() }
            return
        }
        geckoLife -= dt
        if geckoLife <= 0 { despawnGecko(escaped: false); return }
        guard let p = geckoPlat else { despawnGecko(escaped: false); return }

        geckoWait -= dt
        if geckoWait <= 0 {                                   // วิ่งเป็นช่วง ๆ แบบจิ้งจก
            gx += gdir * 150 * CGFloat(dt)
            if gx < p.minX + 20 { gdir = 1 }
            if gx > p.maxX - 20 { gdir = -1 }
            if Double.random(in: 0..<1) < dt * 1.6 { geckoWait = Double.random(in: 0.5...1.8) }
            geckoFrame += dt
        }
        // แมวเข้ามาใกล้ → เผ่น
        if !airborne, abs(gy - y) < 12, abs(gx - (x + spriteW / 2)) < 70 {
            despawnGecko(escaped: true)
            transitionState(to: "jump", duration: 0.4) { [weak self] in
                self?.transitionState(to: "sit", duration: 2)
            }
            return
        }
        updateGeckoFrame()
        geckoWindow.setFrameOrigin(NSPoint(x: (gx - 16 * scale).rounded(), y: gy.rounded()))
    }

    /// ไล่ลูกบอลถ้าอยู่แพลตฟอร์มเดียวกัน
    private func maybeChaseBall() -> Bool {
        guard ballOn, !airborne, abs(by - plat.y) < 10,
              bx >= plat.minX, bx <= plat.maxX else { return false }
        hurry = true
        target = clampX(bx - spriteW / 2)
        setState("walk", duration: 99) { [weak self] in self?.swatBall() }
        return true
    }

    private func swatBall() {
        hurry = false
        dir = bx > x + spriteW / 2 ? 1 : -1
        setState("crouch", duration: 0.45) { [weak self] in
            guard let self else { return }
            self.bvx = self.dir * CGFloat.random(in: 280...560)
            self.bvy = CGFloat.random(in: 190...330)
            self.ballHits += 1
            self.say(["ตึ่ง!", "ตะปบ!", "ไปเลย!", "อีกที"].randomElement()!, for: 1.3)
            self.setState("jump", duration: 0.35) { [weak self] in
                guard let self else { return }
                if self.ballHits >= 7 { self.despawnBall(); self.say("เบื่อแล้ว", for: 1.5) }
                self.pickIdle()
            }
        }
    }

    private func maybeChaseGecko() -> Bool {
        guard geckoOn, let gp = geckoPlat, !airborne else { return false }
        if abs(gp.y - plat.y) < 6 {
            hurry = true
            target = clampX(gx - spriteW / 2)
            setState("walk", duration: 99)
            if Double.random(in: 0..<1) < 0.5 { say(["จิ้งจก!", "เจอแล้ว!"].randomElement()!, for: 1.5) }
            return true
        }
        return maybeClimb()
    }

    private func maybeDescend() -> Bool {
        guard !plat.isFloor, !airborne else { return false }
        let cx = x + spriteW / 2
        let below = platforms.filter { $0.y < plat.y - 20 }
        guard !below.isEmpty else { return false }

        // ต้องเล็งให้พ้นขอบ ไม่งั้นตอนตกลงมาจะไปเกาะแพลตฟอร์มเดิมซ้ำ
        let goLeft = (cx - plat.minX) < (plat.maxX - cx)
        let landX = goLeft ? plat.minX - spriteW * 1.3 : plat.maxX + spriteW * 0.3
        let landCx = landX + spriteW / 2
        guard below.contains(where: { landCx >= $0.minX && landCx <= $0.maxX }) else { return false }

        dir = goLeft ? -1 : 1
        target = goLeft ? plat.minX : plat.maxX - spriteW      // เดินไปที่ขอบก่อน
        autoDescending = true
        setState("walk", duration: 99) { [weak self] in
            guard let self else { return }
            guard self.effectiveMotionLevel != .calm else {
                self.autoDescending = false
                self.target = nil
                self.setState("sit", duration: 3.0)
                return
            }
            self.say(["ลงละ", "โดดดด", "หื่ม", "สูงจัง"].randomElement()!, for: 1.3)
            self.setState("crouch", duration: 0.4) { [weak self] in
                guard let self else { return }
                self.leap(toX: landX, up: 55)
                self.landAction = { [weak self] in
                    guard let self else { return }
                    self.autoDescending = false
                    self.setState("stretch", duration: 0.8) { self.pickIdle() }
                }
            }
        }
        return true
    }

    /// ไต่ขึ้นข้างหน้าต่าง — ใช้เมื่อขอบบนสูงเกินกระโดดถึง
    private func maybeScaleWall() -> Bool {
        guard !airborne, !climbing else { return false }
        var best: (p: Platform, left: Bool, standX: CGFloat)?
        for p in platforms where !p.isFloor && p.y > y + 70 && p.bottom <= y + 70 {
            for left in [true, false] {
                let sx = left ? p.minX - spriteW * 0.62 : p.maxX - spriteW * 0.38
                guard sx >= plat.minX, sx <= plat.maxX - spriteW else { continue }
                if best == nil || abs(sx - x) < abs(best!.standX - x) {
                    best = (p, left, sx)
                }
            }
        }
        guard let pick = best, abs(pick.standX - x) < 1000 else { return false }

        hurry = true
        target = pick.standX
        setState("walk", duration: 99) { [weak self] in
            guard let self else { return }
            self.hurry = false
            self.dir = pick.left ? 1 : -1            // หันหน้าเข้าหาผนัง
            self.x = pick.standX
            self.climbGoal = pick.p
            self.climbSideLeft = pick.left
            self.climbing = true
            self.say(self.geckoOn ? ["จิ้งจก! รอก่อน", "ไต่ขึ้นไปละ"].randomElement()!
                                  : ["ปีนขึ้นไปหน่อย", "ขึ้นไปดูข้างบน", "เกาะได้"].randomElement()!, for: 1.8)
            self.setState("climb", duration: 999)
        }
        return true
    }

    /// ปีนขึ้นขอบหน้าต่าง — ถ้ามีจิ้งจกอยู่ข้างบนจะเล็งไปที่จิ้งจก
    private func maybeClimb() -> Bool {
        guard !airborne, !follow, platforms.count > 1 else { return false }
        let cx = x + spriteW / 2
        var candidates = platforms.filter {
            $0.y > y + 34 && $0.y < y + 250 && $0.maxX - $0.minX > spriteW * 2.2
        }
        if geckoOn, let gp = geckoPlat, gp.y > y + 20 { candidates = [gp] }
        guard let p = candidates.min(by: {
            abs(max($0.minX, min(cx, $0.maxX)) - cx) < abs(max($1.minX, min(cx, $1.maxX)) - cx)
        }) else { return maybeScaleWall() }

        let aimX = geckoOn && geckoPlat.map({ abs($0.y - p.y) < 2 }) == true ? gx : cx
        let landX = min(max(aimX, p.minX + spriteW), p.maxX - spriteW) - spriteW / 2
        guard abs(landX - x) < 460 else { return maybeScaleWall() }

        dir = landX > x ? 1 : -1
        say(geckoOn ? ["จิ้งจก!", "เจอแล้ว!", "อย่าหนีนะ"].randomElement()!
                    : ["มีอะไรอยู่ข้างบน", "ปีนหน่อย", "ขึ้นไปนั่งดีกว่า"].randomElement()!, for: 1.6)
        setState("crouch", duration: 0.8) { [weak self] in
            guard let self else { return }
            self.leap(toX: landX, up: (p.y - self.y) + 70)
            self.landAction = { [weak self] in
                guard let self else { return }
                if self.geckoOn, let gp = self.geckoPlat, abs(gp.y - self.plat.y) < 6 {
                    self.target = self.clampX(self.gx - self.spriteW / 2)
                    self.setState("walk", duration: 99)
                } else {
                    self.transitionState(to: "sit", duration: Double.random(in: 2...5))
                }
            }
        }
        return true
    }

    // MARK: แพลตฟอร์ม — พื้นจอ + ขอบบนของหน้าต่างแอปอื่น

    struct Platform {
        var y: CGFloat
        var minX: CGFloat
        var maxX: CGFloat
        var isFloor: Bool
        var bottom: CGFloat = -1_000_000     // ขอบล่างของหน้าต่าง ใช้ดูว่าไต่ขึ้นข้างได้ไหม
    }

    /// อ่านตำแหน่งหน้าต่างที่เปิดอยู่ ไม่ต้องขอ permission ใด ๆ
    /// (ชื่อหน้าต่างต้องขอ Screen Recording แต่ bounds ไม่ต้อง — เราใช้แค่ bounds)
    private func refreshPlatforms() {
        var out: [Platform] = []
        for s in NSScreen.screens {
            let f = s.visibleFrame
            out.append(Platform(y: f.minY, minX: f.minX, maxX: f.maxX, isFloor: true))
        }
        let flip = NSScreen.screens.first?.frame.maxY ?? 900
        let mypid = ProcessInfo.processInfo.processIdentifier

        // เก็บหน้าต่างตามลำดับหน้า→หลัง เพื่อเช็กว่าขอบบนโดนบังหรือเปล่า
        var rects: [CGRect] = []
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                guard (w[kCGWindowLayer as String] as? Int) == 0,
                      (w[kCGWindowOwnerPID as String] as? Int32) != mypid,
                      let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                      let bx0 = b["X"], let by0 = b["Y"], let bw = b["Width"], let bh = b["Height"],
                      bw > 170, bh > 100 else { continue }
                rects.append(CGRect(x: bx0, y: flip - by0 - bh, width: bw, height: bh))
            }
        }
        for (i, r) in rects.enumerated() {
            guard let scr = NSScreen.screens.first(where: { $0.frame.intersects(r) }) else { continue }
            let vf = scr.visibleFrame
            // ต้องมีที่ว่างเหนือขอบพอให้แมวยืนโดยไม่ทับแถบเมนู
            guard r.maxY > vf.minY + 70, r.maxY <= vf.maxY - winH * 0.6 else { continue }
            // ขอบบนต้องไม่ถูกหน้าต่างที่อยู่หน้ากว่าบัง ไม่งั้นแมวจะดูลอยอยู่กลางอากาศ
            let strip = CGRect(x: r.minX, y: r.maxY - 3, width: r.width, height: 6)
            if rects.prefix(i).contains(where: { $0.intersects(strip) }) { continue }
            out.append(Platform(y: r.maxY,
                                minX: max(r.minX, vf.minX), maxX: min(r.maxX, vf.maxX),
                                isFloor: false, bottom: r.minY))
        }
        platforms = out.filter { $0.maxX - $0.minX > spriteW * 2.2 }
        if platforms.isEmpty {
            let f = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            platforms = [Platform(y: f.minY, minX: f.minX, maxX: f.maxX, isFloor: true)]
        }
    }

    /// จับคู่ตัวแมวกับแพลตฟอร์มที่ยืนอยู่ ถ้าหน้าต่างถูกปิด/ย้ายไป จะร่วงลงมา
    private func resolvePlatform() {
        guard !airborne, !held, !climbing else { return }
        let cx = x + spriteW / 2
        let under = platforms.filter { cx >= $0.minX - 6 && cx <= $0.maxX + 6 && abs($0.y - y) < 34 }
        if let best = under.min(by: { abs($0.y - y) < abs($1.y - y) }) {
            plat = best
            y = best.y
        } else {
            airborne = true; vy = 0; vx = 0
            landAction = { [weak self] in self?.setState("stretch", duration: 0.7) { self?.pickIdle() } }
            if Double.random(in: 0..<1) < 0.55 { say("เอ๊ะ!", for: 1.2) }
        }
    }

    private func landingPlatform(from prevY: CGFloat) -> Platform? {
        guard vy < 0 else { return nil }
        let cx = x + spriteW / 2
        return platforms
            .filter { cx >= $0.minX && cx <= $0.maxX && prevY >= $0.y - 1 && y <= $0.y }
            .max(by: { $0.y < $1.y })
    }

    private func leap(toX: CGFloat, up: CGFloat) {
        let g: CGFloat = 2600
        vy = (2 * g * max(45, up)).squareRoot()
        let t = max(0.22, 2 * vy / g)
        vx = max(-1000, min(1000, (toX - x) / t))
        dir = vx >= 0 ? 1 : -1
        airborne = true
        setState("jump", duration: 99)
    }

    private func land(on p: Platform) {
        plat = p
        y = p.y
        vy = 0; vx = 0
        airborne = false
        landingMotion = 0.24
        x = min(max(x, p.minX), p.maxX - spriteW)
        let act = landAction
        landAction = nil
        if let act { act() } else { setState("stretch", duration: 0.7) { [weak self] in self?.pickIdle() } }
    }

    // MARK: behaviour

    /// ตอน hurry ให้ใช้ท่าวิ่งแทนท่าเดิน
    private func poseName() -> String {
        (state == "walk" && hurry && POSES["run"] != nil) ? "run" : state
    }

    private func setState(_ name: String, duration: Double, then after: (() -> Void)? = nil) {
        if name != "walk" { walkTime = 0 }
        state = name
        frameIdx = 0
        frameTime = 0
        stateTime = duration
        afterState = after
    }

    /// Seam เดียวสำหรับเฟรมเชื่อมท่าหลัก: anticipation ก่อนลอยตัว และ settle ก่อนหยุดนิ่ง
    /// Reduce Motion ข้ามเฟรมเชื่อมเพื่อเปลี่ยนท่าโดยตรงและไม่เพิ่มการเคลื่อนไหวเกินจำเป็น
    private func transitionState(to name: String, duration: Double,
                                 then after: (() -> Void)? = nil) {
        let current = poseName()
        guard !reduceMotionEnabled else {
            setState(name, duration: duration, then: after)
            return
        }
        if name == "jump", current != "crouch" {
            setState("crouch", duration: 0.18) { [weak self] in
                self?.setState(name, duration: duration, then: after)
            }
        } else if name == "sit", ["walk", "run", "jump"].contains(current) {
            setState("stretch", duration: 0.18) { [weak self] in
                self?.setState(name, duration: duration, then: after)
            }
        } else {
            setState(name, duration: duration, then: after)
        }
    }

    /// พุ่งข้ามแพลตฟอร์มไปอีกฝั่งแบบวิ่งเล่น
    private func dashAcross() {
        let span = plat.maxX - plat.minX - spriteW
        guard span > spriteW else { setState("sit", duration: 1.5); return }
        let cx = x + spriteW / 2
        let goRight = cx < (plat.minX + plat.maxX) / 2
        let far = goRight ? plat.maxX - spriteW - CGFloat.random(in: 0...span * 0.25)
                          : plat.minX + CGFloat.random(in: 0...span * 0.25)
        hurry = true
        target = clampX(far)
        setState("walk", duration: 99)
    }

    private func pickIdle() {
        if focusPhase == .focus {
            target = nil
            hurry = false
            setState("sit", duration: max(1, focusRemaining))
            return
        }
        if focusPhase == .rest {
            target = nil
            hurry = false
            setState("sleep", duration: max(1, focusRemaining))
            return
        }
        if paused { setState("sit", duration: 999); return }
        hurry = false
        napForced = false
        if maybeChaseBall() { return }
        let calmMotion = effectiveMotionLevel == .calm
        if !calmMotion, maybeChaseGecko() { return }
        if !calmMotion, !plat.isFloor,
           Double.random(in: 0..<1) < 0.32, maybeDescend() { return }
        if !calmMotion, Double.random(in: 0..<1) < 0.12, maybeClimb() { return }
        if calmMotion {
            // โหมดสงบตัดพฤติกรรมแรงที่เกิดเอง แต่ยังเดิน/นอน/เลียอุ้งเท้าได้ตามธรรมชาติ
            zoomies = 0
            switch Double.random(in: 0..<1) {
            case ..<0.32:
                setState("sleep", duration: Double.random(in: 75...180)) { [weak self] in
                    self?.setState("stretch", duration: 1.2)
                }
            case ..<0.62: transitionState(to: "sit", duration: Double.random(in: 4...8))
            case ..<0.78: setState("lick", duration: Double.random(in: 3...5))
            default:
                let lo = plat.minX, hi = max(plat.minX + 1, plat.maxX - spriteW)
                target = CGFloat.random(in: lo...hi)
                setState("walk", duration: 99)
            }
            return
        }
        if zoomies > 0 { zoomies -= 1; dashAcross(); return }
        if Double.random(in: 0..<1) < 0.07 {
            zoomies = Int.random(in: 2...4)
            say(["วิ่งเล่นแป๊บ", "วู้ววว", "อยู่เฉยไม่ได้"].randomElement()!, for: 1.6)
            dashAcross()
            return
        }
        if Double.random(in: 0..<1) < 0.09 {
            setState("tilt", duration: Double.random(in: 1.6...2.8))
            return
        }
        switch Double.random(in: 0..<1) {
        case ..<0.20:
            setState("sleep", duration: Double.random(in: 60...180)) { [weak self] in
                self?.setState("stretch", duration: 1.6)
            }
        case ..<0.42: transitionState(to: "sit", duration: Double.random(in: 2.5...6))
        case ..<0.60: setState("lick", duration: Double.random(in: 2.5...5))
        case ..<0.68: setState("stretch", duration: 1.6)
        default:
            let lo = plat.minX, hi = max(plat.minX + 1, plat.maxX - spriteW)
            target = CGFloat.random(in: lo...hi)
            setState("walk", duration: 99)
        }
    }

    func grab() {
        napForced = false
        held = true
        didDrag = false
        airborne = false
        vx = 0; vy = 0
        landAction = nil
        setState("held", duration: 999)
        applyFrame()
    }

    func dragTo(x newX: CGFloat, y newY: CGFloat) {
        if !didDrag { say(DRAG_LINES.randomElement()!, for: 1.8) }
        didDrag = true
        x = newX
        y = newY
        vy = 0
        window.setFrameOrigin(NSPoint(x: x, y: y))
        if speakFor > 0 { placeBubble() }
    }

    func release() {
        guard held else { return }
        held = false
        let cx = x + spriteW / 2
        let landing = platforms.filter { cx >= $0.minX && cx <= $0.maxX && $0.y <= y + 4 }
                               .max(by: { $0.y < $1.y })
        if let p = landing, abs(p.y - y) < 6 {
            plat = p; y = p.y; vy = 0; vx = 0; airborne = false
            if didDrag {
                setState("stretch", duration: 0.9) { [weak self] in self?.pickIdle() }
            } else {
                say(LINES["jump"]!.randomElement()!, for: 1.9)
                transitionState(to: "jump", duration: 0.4) { [weak self] in
                    self?.transitionState(to: "sit", duration: 2.5)
                }
            }
        } else {
            vy = 0; vx = 0; airborne = true          // ปล่อยกลางอากาศ → ร่วงลงไปหาแพลตฟอร์มที่ใกล้ที่สุด
            landAction = { [weak self] in
                guard let self else { return }
                self.say("โอ๊ย!", for: 1.5)
                self.setState("stretch", duration: 0.8) { [weak self] in self?.pickIdle() }
            }
            setState("jump", duration: 99)
        }
    }

    private func doPounce() {
        guard focusPhase == .idle, effectiveMotionLevel != .calm else {
            pounceTarget = nil
            target = nil
            afterState = nil
            setState("sit", duration: 3.0)
            return
        }
        let m = NSEvent.mouseLocation
        let tx = (pounceTarget ?? m.x) - spriteW / 2
        pounceTarget = nil
        leap(toX: tx, up: max(60, min(240, m.y - y)))
        landAction = { [weak self] in
            guard let self else { return }
            let hit = abs(NSEvent.mouseLocation.x - (self.x + self.spriteW / 2)) < 70
            self.say(hit ? ["ได้แล้ว!", "ตะปบ!"].randomElement()!
                         : ["พลาด!", "หนีไปได้", "แง"].randomElement()!, for: 1.7)
            CatVoice.shared.play(hit ? .trill : .mrrp, minGap: 1.5)
            self.transitionState(to: "sit", duration: 2.2)
        }
    }

    /// อ่านกล่องจดหมายถ้าไฟล์ถูกแก้ไขใหม่ แล้วให้น้องตอบสนอง
    private func pollInbox(_ dt: Double) {
        inboxPoll -= dt
        guard inboxPoll <= 0 else { return }
        inboxPoll = 0.4
        guard let attr = try? FileManager.default.attributesOfItem(atPath: INBOX),
              let mod = attr[.modificationDate] as? Date else { return }
        if let seen = inboxStamp, mod <= seen { return }
        let first = inboxStamp == nil
        inboxStamp = mod
        if first { return }                       // ครั้งแรกแค่จำเวลาไว้ ไม่ต้องพูดของเก่า
        guard let raw = try? String(contentsOfFile: INBOX, encoding: .utf8) else { return }
        let line = raw.split(separator: "\n").last.map(String.init) ?? ""
        let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
        guard let event = parts.first, !event.isEmpty else { return }
        let msg = parts.count > 1 ? parts[1] : ""
        let ev = event.trimmingCharacters(in: .whitespaces)
        if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
            FileHandle.standardError.write("INBOX event=\(ev) msg=\(msg)\n".data(using: .utf8)!)
        }
        handleClaude(event: ev, message: msg)
    }

    private func handleClaude(event: String, message: String) {
        guard !held, focusPhase == .idle else {
            // อ่าน stamp ของไฟล์แล้วจึงต้องเก็บ event ไว้ ไม่เช่นนั้น hook ที่เข้าระหว่าง Focus จะหายถาวร
            let deferred = DeferredClaudeEvent(event: event, message: message)
            if deferredClaudeEvents.last?.event != event
                || deferredClaudeEvents.last?.message != message {
                deferredClaudeEvents.append(deferred)
            }
            return
        }
        let activity = BuildTestAwareness.classify(
            state: event, message: message,
            fingerprint: "claude-inbox:\(event):\(message)"
        )
        if activity.kind != .idle {
            playBuildTestAnimation(activity.kind)
            let fallback: String
            switch activity.kind {
            case .coding: fallback = "กำลังแก้โค้ดอยู่ • แป๊บเดียวนะ"
            case .build: fallback = "กำลัง build อยู่นะ 🔧"
            case .testing: fallback = "กำลังรัน test • ลุ้นอยู่"
            case .testPassed: fallback = "test ผ่านแล้ว!"
            case .testFailed: fallback = "test พังแล้ว • น้องเก็บ error ไว้ให้"
            case .permission: fallback = "มี permission รอให้กดอยู่นะ"
            case .idle: fallback = ""
            }
            say(message.isEmpty ? fallback : message,
                for: activity.kind == .permission ? 6.0 : 3.8)
            return
        }
        let fallback: String
        switch event {
        case "busy":
            fallback = "ทำงานอยู่นะ"
            setState("walk", duration: Double.random(in: 3...6))
        case "done":
            fallback = "เสร็จแล้วน้า~"
            playWorkEmotion(.done)
        case "ask":
            fallback = "มาดูหน่อยสิ"
            playWorkEmotion(.input)
        case "fail":
            fallback = "พังแล้ว!"
            playWorkEmotion(.failed)
        default: return
        }
        say(message.isEmpty ? fallback : message, for: event == "ask" ? 5.0 : 3.4)
    }

    private func flushDeferredClaudeEvent() {
        guard focusPhase == .idle, !held, activeWorkNotice == nil,
              activeContextRescue == nil,
              speakFor <= 0, !deferredClaudeEvents.isEmpty else { return }
        let deferred = deferredClaudeEvents.removeFirst()
        handleClaude(event: deferred.event, message: deferred.message)
    }

    /// รันสคริปต์ตรวจ (ลง time / งานค้าง) — ต้องให้แอปเป็นคนรัน ไม่ใช่ launchd
    /// เพราะ macOS กัน background process ไม่ให้อ่าน ~/Desktop
    private func runCheck(_ dt: Double) {
        checkIn -= dt
        guard checkIn <= 0 else { return }
        checkIn = 900                                    // ทุก 15 นาที
        let path = NSString(string: "~/.pixelcat/check.sh").expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else { return }
        DispatchQueue.global(qos: .utility).async {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/bin/zsh")
            t.arguments = [path]
            try? t.run()
        }
    }

    /// นั่งทำงานติดกันนานเกินไป ให้น้องมายืดตัวเตือน
    /// นับเฉพาะตอนมีการขยับเมาส์/คีย์ ถ้าลุกไปแล้ว (ว่างเกิน 3 นาที) ให้รีเซ็ต
    private func breakReminder(_ dt: Double) {
        guard focusPhase == .idle else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .init(rawValue: ~0)!)
        if idle > 180 { activeStreak = 0; breakNudged = false; return }
        guard idle < 60 else { return }
        activeStreak += dt
        if activeStreak > 50 * 60 && !breakNudged {
            breakNudged = true
            setState("stretch", duration: 5) { [weak self] in self?.pickIdle() }
            say("นั่งมา 50 นาทีแล้ว ลุกยืดหน่อย", for: 6)
        }
    }

    private func sqliteText(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: raw)
    }

    /// อ่านสถานะ turn ล่าสุดของ Codex โดยเปิดฐานข้อมูลแบบ read-only เท่านั้น
    private func latestCodexTurnStates() -> [String: String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(CODEX_HISTORY_DB, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        let sql = """
            SELECT turn.thread_id, turn.status
            FROM thread_turns AS turn
            JOIN (
                SELECT thread_id, MAX(rollout_ordinal) AS ordinal
                FROM thread_turns GROUP BY thread_id
            ) AS latest
              ON latest.thread_id = turn.thread_id
             AND latest.ordinal = turn.rollout_ordinal
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [:] }
        defer { sqlite3_finalize(statement) }

        var states: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            states[sqliteText(statement, 0)] = sqliteText(statement, 1)
        }
        return states
    }

    /// อ่าน token_count ล่าสุดจากท้าย rollout เท่านั้น (สูงสุด 256 KiB)
    /// ใช้ window ที่ Codex บันทึกมากับ event จึงไม่ต้อง hard-code context size ของโมเดล
    private func codexContextPercent(rolloutPath: String) -> Double {
        guard !rolloutPath.isEmpty else { return 0 }
        let attributes = try? FileManager.default.attributesOfItem(atPath: rolloutPath)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if let cached = codexContextCache[rolloutPath],
           cached.modified == modified, cached.size == fileSize {
            return cached.percent
        }
        guard
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: rolloutPath)) else {
            return 0
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return 0 }
        let cap: UInt64 = 512 * 1024
        let start = size > cap ? size - cap : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return 0 }
        var lines = data.split(separator: 0x0A)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any],
                  let used = usage["total_tokens"] as? NSNumber,
                  let window = info["model_context_window"] as? NSNumber,
                  window.doubleValue > 0 else { continue }
            let percent = min(100, max(0, used.doubleValue * 100 / window.doubleValue))
            codexContextCache[rolloutPath] = (modified, fileSize, percent)
            return percent
        }
        return 0
    }

    private func codexWorkActivity(rolloutPath: String,
                                   turnState: String) -> WorkActivitySignal {
        guard !rolloutPath.isEmpty else { return .idle }
        let attributes = try? FileManager.default.attributesOfItem(atPath: rolloutPath)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if let cached = codexActivityCache[rolloutPath],
           cached.modified == modified, cached.size == fileSize {
            return cached.signal
        }
        let signal = BuildTestAwareness.codexRollout(path: rolloutPath, turnState: turnState)
        codexActivityCache[rolloutPath] = (modified, fileSize, signal)
        return signal
    }

    private func loadCodexSessions(now: Double) -> [WorkSession] {
        let turnStates = latestCodexTurnStates()
        guard !turnStates.isEmpty else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(CODEX_STATE_DB, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        var schemaStatement: OpaquePointer?
        var hasRolloutPath = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1,
                              &schemaStatement, nil) == SQLITE_OK,
           let schemaStatement {
            while sqlite3_step(schemaStatement) == SQLITE_ROW {
                if sqliteText(schemaStatement, 1) == "rollout_path" {
                    hasRolloutPath = true
                    break
                }
            }
            sqlite3_finalize(schemaStatement)
        }
        let rolloutColumn = hasRolloutPath ? "rollout_path" : "''"
        let sql = """
            SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''), 'งาน Codex'),
                   cwd, updated_at, \(rolloutColumn), preview
            FROM threads
            WHERE archived = 0 AND preview <> '' AND thread_source = 'user'
              AND updated_at >= ?
            ORDER BY updated_at DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(now - SESSION_STALE))

        var sessions: [WorkSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqliteText(statement, 0)
            guard let rawState = turnStates[id] else { continue }
            let state: String
            switch rawState {
            case "inProgress": state = "working"
            case "completed": state = "done"
            case "failed": state = "failed"
            case "interrupted": state = "interrupted"
            default: continue
            }
            let rawTitle = sqliteText(statement, 1)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let topic = rawTitle.count > 70 ? String(rawTitle.prefix(68)) + "…" : rawTitle
            let cwd = sqliteText(statement, 2)
            let project = cwd.isEmpty ? "Codex"
                : URL(fileURLWithPath: cwd).lastPathComponent
            let updatedAt = Double(sqlite3_column_int64(statement, 3))
            let rolloutPath = sqliteText(statement, 4)
            let contextPercent = codexContextPercent(rolloutPath: rolloutPath)
            let activity = codexWorkActivity(rolloutPath: rolloutPath, turnState: rawState)
            let preview = sqliteText(statement, 5)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sessions.append(WorkSession(source: "codex", id: id, state: state,
                                        name: project, cwd: cwd, message: String(preview.prefix(800)),
                                        updatedAt: updatedAt, contextPercent: contextPercent,
                                        focusURL: "codex://threads/\(id)", appPIDs: [],
                                        sessionID: "", topic: topic, activity: activity))
        }
        return sessions
    }

    /// รวมสถานะจาก Codex และ Claude Code ในกล่องเดียว แต่แยก section ตอนแสดงผล
    private func pollSessions(_ dt: Double) {
        sessPoll -= dt
        guard sessPoll <= 0 else { return }
        sessPoll = 0.5
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: SESSIONS)) ?? []
        let now = Date().timeIntervalSince1970
        var waiting: [String] = []
        var working = 0
        var sessions = [WorkSession]()
        for n in names where !n.hasPrefix(".") && !n.contains(".tmp") {
            guard let d = fm.contents(atPath: SESSIONS + "/" + n),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let at = j["at"] as? Double, now - at < SESSION_STALE,
                  let st = j["state"] as? String else { continue }
            let cwd = (j["cwd"] as? String) ?? ""
            let dir = (j["dir"] as? String) ?? ""
            let name = !dir.isEmpty ? dir
                : (!cwd.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : "งานหนึ่ง")
            let message = (j["msg"] as? String) ?? ""
            let activity = BuildTestAwareness.classify(
                state: st, message: message,
                fingerprint: "claude:\(n):\(Int(at * 1000))"
            )
            let normalizedState: String
            switch activity.kind {
            case .coding, .build, .testing: normalizedState = "working"
            case .testPassed: normalizedState = "done"
            case .testFailed: normalizedState = "failed"
            case .permission: normalizedState = "input"
            case .idle: normalizedState = st
            }
            let pct = (j["ctx_pct"] as? Double) ?? 0
            let focus = (j["focus_url"] as? String) ?? ""
            let apids = (j["app_pids"] as? [Int]) ?? []
            // ไฟล์รุ่นเก่ายังไม่มี session_id แต่ชื่อไฟล์ก็คือ UUID เดียวกัน
            let sid = (j["session_id"] as? String) ?? n
            let topic = (j["topic"] as? String) ?? ""
            let pid = (j["pid"] as? Int) ?? 0
            // ห้องที่โปรเซสตายไปแล้วแต่ไฟล์ยังค้าง ไม่ควรถูกนับหรือเอามาเตือน context
            if pid > 0, kill(pid_t(pid), 0) != 0, errno == ESRCH { continue }
            sessions.append(WorkSession(source: "claude", id: n, state: normalizedState, name: name, cwd: cwd,
                                        message: message, updatedAt: at,
                                        contextPercent: pct,
                                        focusURL: focus.hasPrefix("warp://") ? focus : "",
                                        appPIDs: apids, sessionID: sid, topic: topic,
                                        activity: activity, pid: pid,
                                        startedAt: (j["started"] as? Double) ?? at,
                                        recentFiles: ((j["files"] as? [String]) ?? []).prefix(8).map { $0 },
                                        lastRequest: (j["last_user"] as? String) ?? ""))
            if ["input", "ask", "waiting"].contains(normalizedState) { waiting.append(name) }
            else if ["working", "busy"].contains(normalizedState) { working += 1 }
        }
        let codexSessions = loadCodexSessions(now: now)
        sessions.append(contentsOf: codexSessions)
        working += codexSessions.filter { ["working", "busy"].contains($0.state) }.count
        sessions.sort {
            let left = workStateRank($0.state), right = workStateRank($1.state)
            return left == right ? $0.updatedAt > $1.updatedAt : left < right
        }
        captureReturnRitual(sessions, now: now)
        detectWorkNotices(sessions)
        updateBuildTestAwareness(sessions)
        remindLongWaitingWork(sessions, now: now)
        watchLongRunningWork(sessions, now: now)
        let signature = sessions.map {
            "\($0.source)|\($0.id)|\($0.state)|\($0.name)|\($0.cwd)|\($0.message)|\(Int($0.contextPercent.rounded()))|\(Int($0.updatedAt))"
        }.joined(separator: "\n")
        if signature != workMenuSignature {
            workMenuSignature = signature
            workSessions = sessions
            recalculateWorkCounts()
            refreshWorkInboxUI()
        }
        evaluateContextPressure(sessions)
        // สรุปเป็นสตริงเดียว เปลี่ยนเมื่อไหร่ค่อยพูด จะได้ไม่พูดซ้ำทุกครึ่งวินาที
        let summary = waiting.isEmpty ? (working > 0 ? "w\(working)" : "idle")
                                      : "a" + waiting.sorted().joined(separator: ",")
        guard summary != sessSummary else { return }
        let prev = sessSummary
        sessSummary = summary
        if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
            FileHandle.standardError.write("SESS \(prev) -> \(summary)\n".data(using: .utf8)!)
        }
        // กล่องแจ้งเตือนราย session ถูกสร้างใน detectWorkNotices แล้ว จึงไม่พูดสรุปรวม
        // ซ้ำอีกครั้งตรงนี้ (ซึ่งเคยทำให้ไม่รู้ว่างานไหนเสร็จ)
    }

    /// ให้ regression หมุนหนึ่งเฟรมได้ โดยไม่ต้องเปิด tick ทั้งก้อน
    func tickForTests(_ dt: Double) { tick(dt) }

    private func tick(_ dt: Double) {
        // โฟกัสกับตอนหลับต้องเงียบจริง ๆ ไม่งั้นเสียงน่ารักจะกลายเป็นเสียงกวน
        CatVoice.shared.muted = focusPhase != .idle || napForced || state == "sleep"
        pollSessions(dt)
        runLocalCompanion(dt)
        updateCompanionThinking(dt)
        pollInbox(dt)
        runCheck(dt)
        updateFocus(dt)
        cancelEnergeticMotionIfNeeded()
        breakReminder(dt)
        if held && (NSEvent.pressedMouseButtons & 1) == 0 { release() }
        if petting && (NSEvent.pressedMouseButtons & 1) == 0 { stopPetting() }
        let hadEmotion = noticeMotionFor > 0
        noticeMotionFor = max(0, noticeMotionFor - dt)
        if hadEmotion && noticeMotionFor == 0 { emotionKind = nil }
        if activeWorkNotice == nil && activeContextRescue == nil { showPendingReturnRitual() }
        if pendingReturnRitual == nil && activeWorkNotice == nil && activeContextRescue == nil {
            showNextWorkNotice()
        }
        if activeWorkNotice == nil && activeContextRescue == nil { flushDeferredClaudeEvent() }

        if speakFor > 0 {
            speakFor -= dt
            if speakFor <= 0 { hideBubble() }
        } else if speechOn && !held && focusPhase == .idle {
            chatIn -= dt
            if chatIn <= 0 {
                chatIn = Double.random(in: 14...32)
                let chance = (state == "sleep") ? 0.35 : 0.7
                if Double.random(in: 0..<1) < chance { say(ambientLine()) }
            }
        }

        guard !held else {                       // ถูกอุ้มอยู่ — แกว่งขาไปมา
            let p = POSES["held"]!
            frameTime += dt
            if frameTime > 1 / p.fps { frameTime = 0; frameIdx = (frameIdx + 1) % p.count }
            applyFrame()
            return
        }

        platRefresh -= dt
        if platRefresh <= 0 { platRefresh = 1.5; refreshPlatforms(); resolvePlatform() }
        stepBall(dt)
        stepGecko(dt)
        stepHearts(dt)
        if petting { blinking = true }

        if airborne {
            let prevY = y
            vy -= 2600 * CGFloat(dt)
            x += vx * CGFloat(dt)
            y += vy * CGFloat(dt)
            state = "jump"; frameIdx = 0
            let scr = currentScreen().frame
            x = min(max(x, scr.minX - 8), scr.maxX - spriteW + 8)
            if let p = landingPlatform(from: prevY) {
                land(on: p)
            } else if let floor = platforms.first(where: { $0.isFloor }), y < floor.y - 240 {
                land(on: floor)                      // ตกหลุดออกนอกจอ — ดึงกลับพื้น
            }
        } else if climbing {
            guard platforms.contains(where: { abs($0.y - climbGoal.y) < 3 && $0.minX <= climbGoal.minX + 8 })
            else {                                    // หน้าต่างหายไประหว่างไต่ → ร่วง
                climbing = false; airborne = true; vy = 0; vx = 0
                say("อ๊ากก", for: 1.4)
                CatVoice.shared.play(.mrrp, minGap: 1.0)
                landAction = { [weak self] in self?.setState("stretch", duration: 0.8) { self?.pickIdle() } }
                setState("jump", duration: 99)
                return
            }
            let remaining = max(0, climbGoal.y - y)
            let climbBeat: [CGFloat] = [105, 190, 105, 190]
            let beatSpeed = climbBeat[frameIdx % climbBeat.count]
            let speed = remaining < 28 ? min(beatSpeed, 95) : beatSpeed
            y += speed * CGFloat(dt)
            if y >= climbGoal.y {
                y = climbGoal.y
                plat = climbGoal
                climbing = false
                x = climbSideLeft ? climbGoal.minX + 6 : climbGoal.maxX - spriteW - 6
                setState("stretch", duration: 0.7) { [weak self] in self?.pickIdle() }
            }
        } else {
            y = plat.y
        }

        if blinking {
            blinkFor -= dt
            if blinkFor <= 0 {
                blinking = false
                blinkIn = blinkAgain ? 0.13 : Double.random(in: 2.5...6.0)
                blinkAgain = false
            }
        } else {
            blinkIn -= dt
            if blinkIn <= 0 {
                blinking = true
                blinkFor = 0.12
                blinkAgain = Double.random(in: 0..<1) < 0.3   // บางทีก็กระพริบสองที
            }
        }

        let pose = POSES[poseName()]!
        frameTime += dt
        let freezeStatusAnimation = reduceMotionEnabled
            && ["coding", "buildWork", "testWatch", "testPass", "testFail", "permission"].contains(poseName())
        if !freezeStatusAnimation, frameTime > 1.0 / pose.fps {
            frameTime = 0
            frameIdx = (frameIdx + 1) % pose.count
        }
        landingMotion = max(0, landingMotion - dt)

        // ── ตะปบเคอร์เซอร์: ขยับเมาส์เร็ว ๆ ใกล้น้อง แล้วน้องจะหมอบแล้วพุ่ง ──
        let mouse = NSEvent.mouseLocation
        let moved = hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y)
        mouseSpeed = mouseSpeed * 0.7 + (moved / CGFloat(max(dt, 0.001))) * 0.3
        lastMouse = mouse
        pounceCool -= dt
        if focusPhase == .idle, effectiveMotionLevel != .calm,
           !airborne, !follow, !petting,
           pounceCool <= 0, mouseSpeed > 1200,
           ["walk", "sit", "lick", "stretch"].contains(state),
           abs(mouse.x - (x + spriteW / 2)) < 320,
           mouse.y > y - 30, mouse.y < y + 340 {
            pounceCool = 14
            pounceTarget = mouse.x
            dir = mouse.x > x + spriteW / 2 ? 1 : -1
            say(["จ้องอยู่…", "อย่าขยับนะ", "จับได้แน่"].randomElement()!, for: 1.3)
            setState("crouch", duration: 1.0) { [weak self] in self?.doPounce() }
        }

        if state == "walk" || state == "courier" {
            walkTime += dt
            if walkTime > 25 { walkTime = 0; target = nil; afterState = nil; pickIdle(); return }
            var goal = target ?? x
            if follow { goal = clampX(NSEvent.mouseLocation.x - spriteW / 2) }
            let delta = goal - x
            if abs(delta) < 4 {
                if follow {
                    transitionState(to: "sit", duration: 0.6)
                } else if let next = afterState {
                    afterState = nil
                    target = nil
                    next()
                } else {
                    pickIdle()
                }
            } else {
                dir = delta > 0 ? 1 : -1
                let speed: CGFloat = follow ? (60 + 16 * scale)
                                           : (hurry ? (70 + 20 * scale) : (30 + 8 * scale))
                let before = x
                x = clampX(x + dir * speed * CGFloat(dt))
                if abs(x - before) < 0.02 {          // ติดขอบแพลตฟอร์ม ไปต่อไม่ได้
                    target = nil
                    hurry = false
                    if let next = afterState { afterState = nil; next() } else { pickIdle() }
                }
            }
        } else if !airborne {
            stateTime -= dt
            if stateTime <= 0 {
                let next = afterState
                afterState = nil
                if let next { next() } else { pickIdle() }
            }
        }

        applyFrame()
    }
}
