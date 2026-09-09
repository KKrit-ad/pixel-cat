// PetController
// หัวใจของแอป: สถานะ, แอนิเมชัน, เมนู, กล่องงาน และการโต้ตอบทั้งหมด

import Cocoa
import Carbon
import SQLite3

// ─────────────────────────────────────────────────────────────
final class PetController: NSObject {
    enum FocusPhase { case idle, focus, rest }
    enum MotionLevel: Int {
        case calm = 0, normal = 1, playful = 2

        var label: String {
            switch self {
            case .calm: return "สงบ"
            case .normal: return "ปกติ"
            case .playful: return "ซน"
            }
        }
    }
    enum WorkNoticeKind: Equatable { case done, batchDone, input, failed, returned }
    struct WorkSession {
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
    struct WorkNotice {
        let session: WorkSession
        let kind: WorkNoticeKind
        let text: String
    }
    struct CourierPayload {
        let files: [URL]
        let text: String
        let question: String

        init(files: [URL], text: String, question: String = "") {
            self.files = files
            self.text = text
            self.question = question
        }

        func asking(_ question: String) -> CourierPayload {
            CourierPayload(files: files, text: text, question: question)
        }

        var label: String {
            if files.count == 1 { return files[0].lastPathComponent }
            if files.count > 1 { return "\(files.count) ไฟล์" }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 24 ? String(trimmed.prefix(22)) + "…" : trimmed
        }

        var pasteboardText: String {
            let request = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty else {
                if !files.isEmpty { return files.map(\.path).joined(separator: "\n") }
                return text
            }
            if !files.isEmpty {
                let paths = files.map { "- \($0.path)" }.joined(separator: "\n")
                return "\(request)\n\nไฟล์ที่ฉันลากมาให้จาก PixelCat:\n\(paths)"
            }
            return "\(request)\n\nข้อความที่ฉันลากมาให้จาก PixelCat:\n---\n\(text)\n---"
        }
    }
    struct DeliveryBatch {
        let id: UUID
        var items: [DeliveryItem]
        let arrivedAt: Double

        var title: String {
            if items.count == 1 { return items[0].url.lastPathComponent }
            return "พัสดุใหม่ \(items.count) ไฟล์"
        }
    }
    struct ContextRescue {
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

    struct DeferredClaudeEvent {
        let event: String
        let message: String
    }

    // Local observer/rule-engine state. The provider seam can be added later.
    var companionMode: CompanionMode = {
        let raw = UserDefaults.standard.object(forKey: "companionMode") as? Int
        return CompanionMode(rawValue: raw ?? CompanionMode.quietWatch.rawValue) ?? .quietWatch
    }()
    var companionPoll = 2.0
    var companionCooldown = 0.0
    var companionLastApp = ""
    var companionRecentEvent = ""
    var companionMemory = CompanionMemory.load()
    var companionBrain: CompanionBrain = {
        let raw = UserDefaults.standard.object(forKey: "companionBrain") as? Int
        return CompanionBrain(rawValue: raw ?? CompanionBrain.claude.rawValue) ?? .claude
    }()
    lazy var manusCompanion: CompanionProvider? = ManusCompanionProvider()
    lazy var claudeCompanion: CompanionProvider? = ClaudeCompanionProvider()

    /// provider ที่ใช้อยู่จริง — nil แปลว่าตกไป local
    var activeCompanion: CompanionProvider? {
        switch companionBrain {
        case .localOnly: return nil
        case .claude: return claudeCompanion
        // Manus ต้องใช้ key; ถ้ายังไม่ได้ตั้งให้ลอง Claude ที่ล็อกอินไว้ก่อน
        // เพื่อไม่ให้การสลับเมนูทำให้น้องกลายเป็น local แบบเงียบ ๆ
        case .manus: return manusCompanion ?? claudeCompanion
        }
    }
    var companionRequestInFlight = false
    var companionConnectionStatus = "ยังไม่ได้เรียก"

    let window: NSWindow
    let view = CatView()
    var chatWindow: NSWindow?
    var chatTranscript: NSTextView?
    var chatInput: NSTextField?
    var chatSendButton: NSButton?
    var chatBusy = false
    var thinkingCycle = CompanionThinkingCycle()
    var lastThinkingMessage = ""
    var companionReplyProtected = false
    var fileFinder = LocalFileFinder()
    var fileSearchResults: [URL] = []
    var fileSearchTarget: URL?
    var fileSearchMenuItem: NSMenuItem?
    var lastSimulatedRevealPath = ""
    var lastFileSearchStayedLocal = false
    var currentWorkActivitySignature = ""
    var seenWorkActivitySignatures: Set<String> = []
    var activeWorkActivityKind: WorkActivityKind = .idle
    var codexActivityCache: [String: (modified: Date, size: UInt64,
                                               signal: WorkActivitySignal)] = [:]
    let bubbleWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 30),
                                        styleMask: .borderless, backing: .buffered, defer: false)
    let bubbleView = BubbleView()
    var speakFor = 0.0
    var chatIn = Double.random(in: 6...14)
    var speechOn = UserDefaults.standard.object(forKey: "speechOn") as? Bool ?? true
    var statusItem: NSStatusItem!
    var focusMenuItem: NSMenuItem?
    var workInboxItem: NSMenuItem?
    var motionMenuItem: NSMenuItem?
    var cinemaMenuItem: NSMenuItem?
    var timer: Timer?
    var onTop = true                 // น้องลอยเหนือทุกหน้าต่างอยู่ไหม
    var deliveryMenuItem: NSMenuItem?
    var deliveryWatcher = DeliveryWatcher()
    var deliveryEnabled = UserDefaults.standard.object(forKey: "deliveryEnabled") as? Bool
        ?? true
    var deliveryPoll = 0.0
    var deliveryQuiet = 0.0
    var collectingDeliveries: [DeliveryItem] = []
    var deliveryQueue: [DeliveryBatch] = []
    var deliveryHistory: [DeliveryBatch] = []
    var activeDelivery: DeliveryBatch?
    var lastDeliveryStayedLocal = false
    var lastSimulatedDeliveryAction = ""
    static let companionHotKeySignature: OSType = 0x50434154 // "PCAT"
    var companionHotKeyRef: EventHotKeyRef?
    var companionHotKeyHandler: EventHandlerRef?
    var companionHotKeyRegistered = false
    var focusPhase: FocusPhase = .idle
    var focusRemaining = 0.0
    var focusDisplaySecond = -1
    var motionLevel: MotionLevel = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "motionLevel") != nil else { return .normal }
        return MotionLevel(rawValue: defaults.integer(forKey: "motionLevel")) ?? .normal
    }()
    var motionReductionOverride: Bool?       // ใช้เฉพาะ simulation; ปกติอ่านจาก macOS
    var cinemaPreference: CinemaPreference = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "cinemaPreference") != nil else { return .automatic }
        return CinemaPreference(rawValue: defaults.integer(forKey: "cinemaPreference"))
            ?? .automatic
    }()
    var cinemaPoll = 0.0
    var cinemaCandidate: Bool?
    var cinemaCandidateCount = 0
    var cinemaHidden = false
    var cinemaRestoreWindows: [(window: NSWindow, alpha: CGFloat)] = []

    // เก็บเป็นหน่วยสิบเท่า (25 = 2.5x) จะได้เลือกครึ่งขั้นได้
    var scale: CGFloat = {
        let d = UserDefaults.standard
        // คีย์ใหม่: atlas 128x100 ใช้สเกล 0.9 เพื่อคงขนาดบนจอใกล้เวอร์ชัน 64x50 ที่ 1.8x
        var tenths = d.integer(forKey: "catScaleTenths128")
        if tenths == 0 { tenths = 9 }
        return CGFloat(min(max(tenths, 5), 20)) / 10
    }()
    var inboxStamp: Date?
    var inboxPoll = 0.0
    var deferredClaudeEvents: [DeferredClaudeEvent] = []
    var sessPoll = 0.0
    var sessSummary = ""
    var workSessions: [WorkSession] = []
    var workMenuSignature = ""
    var workAlertCount = 0
    var workActiveCount = 0
    var acknowledgedWorkKeys: Set<String> = []
    var waitingReminderSent: Set<String> = []
    var snoozedWorkUntil: [String: Double] = [:]
    var watchedLongWorkKeys: Set<String> = []
    var previousSessionStates: [String: String] = [:]
    var didSeedSessionStates = false
    var workNoticeQueue: [WorkNotice] = []
    var activeWorkNotice: WorkNotice?
    var bubbleTarget: WorkSession?
    var returnRitualTracker = ReturnRitualTracker()
    var pendingReturnRitual: ReturnRitualSummary?
    var lastSimulatedActionPrompt = ""
    var noticeMotionFor = 0.0
    var emotionKind: WorkNoticeKind?
    var ctxWarned = 0.0        // เตือน context ไปแล้วที่กี่ % จะได้ไม่เตือนซ้ำ          // สถานะรวมล่าสุด ใช้กันพูดซ้ำ
    var checkIn = 20.0          // รันสคริปต์ตรวจครั้งแรกหลังเปิด 20 วิ
    var activeStreak = 0.0      // นั่งทำงานต่อเนื่องมากี่วินาที
    var breakNudged = false
    var state = "walk"
    var frameIdx = 0
    var frameTime = 0.0
    var stateTime = 0.0
    var landingMotion = 0.0
    var afterState: (() -> Void)?

    var x: CGFloat = 0
    var y: CGFloat = 0
    var vy: CGFloat = 0
    var dir: CGFloat = 1
    var target: CGFloat?

    var follow = false
    var held = false
    var paused = false
    var didDrag = false
    var vx: CGFloat = 0
    var airborne = false
    var landAction: (() -> Void)?
    var platforms: [Platform] = []
    var plat = Platform(y: 0, minX: 0, maxX: 200, isFloor: true)
    var platRefresh = 0.0
    var lastMouse = NSEvent.mouseLocation
    var mouseSpeed: CGFloat = 0
    var pounceCool = 6.0
    var pounceTarget: CGFloat?
    var hurry = false
    var shepherdTarget: WorkSession?
    var simulatedShepherdRect: CGRect?
    var pendingCourierPayload: CourierPayload?
    var courierChoices: [String: WorkSession] = [:]
    var courierDropRegistered = false
    var courierPasteGeneration = 0
    var courierPastePermissionOverride: Bool?
    var courierFrontmostOverride: Bool?
    var lastSimulatedCourierPaste = false
    var lastSimulatedOpenURL = ""
    var contextRescueOffered: Set<String> = []
    static let rescueHistoryKey = "pixelcat.rescueHistory"
    static let rescueHistoryLimit = 8
    var rescueHistoryItem: NSMenuItem?
    var rescueHistory: [SavedRescue] = {
        let raw = UserDefaults.standard.array(forKey: "pixelcat.rescueHistory") as? [[String: Any]] ?? []
        return raw.compactMap(SavedRescue.init(dictionary:))
    }()
    var activeContextRescue: ContextRescue?
    /// แอปตีลิงก์ห้องกลับมาแล้วอย่างน้อยหนึ่งครั้ง — ครั้งต่อไปดึงแอปขึ้นหน้าเลย ไม่ต้องลองซ้ำ
    var claudeSessionLinkBlocked = false
    var askedForAccessibility = false
    var lastSimulatedNewTaskURL = ""
    var lastSimulatedHandoff = ""
    var codexContextCache: [String: (modified: Date, size: UInt64, percent: Double)] = [:]
    var autoDescending = false
    var climbing = false
    var climbGoal = Platform(y: 0, minX: 0, maxX: 0, isFloor: false)
    var climbSideLeft = true
    var napForced = false
    var walkTime = 0.0
    var zoomies = 0
    var petting = false
    var purrCount = 0
    var hearts: [HeartsView.Heart] = []
    let heartWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 90, height: 90),
                                       styleMask: .borderless, backing: .buffered, defer: false)
    let heartsView = HeartsView()
    let ballWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 55),
                                      styleMask: .borderless, backing: .buffered, defer: false)
    let ballView = PropView()
    var ballOn = false
    var bx: CGFloat = 0, by: CGFloat = 0, bvx: CGFloat = 0, bvy: CGFloat = 0
    var ballSpin = 0.0, ballLife = 0.0, ballHits = 0
    var ballRest: CGFloat?
    let geckoWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 55),
                                       styleMask: .borderless, backing: .buffered, defer: false)
    let geckoView = PropView()
    var geckoOn = false
    var gx: CGFloat = 0, gy: CGFloat = 0, gdir: CGFloat = 1
    var geckoPlat: Platform?
    var geckoLife = 0.0, geckoWait = 0.0, geckoFrame = 0.0
    var geckoIn = Double.random(in: 20...50)
    var blinking = false
    var blinkIn = Double.random(in: 2.0...5.0)
    var blinkFor = 0.0
    var blinkAgain = false

    var spriteW: CGFloat { CGFloat(SPRITE_W) * scale }
    var winH: CGFloat { CGFloat(SPRITE_H + SHADOW_H) * scale }

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
        // feature gate นี้อยู่ฝั่งบัญชี Claude และคงอยู่ข้ามการเปิด PixelCat ใหม่
        // ถ้า log ล่าสุดเคยปฏิเสธแล้ว ให้ใช้ sidebar fallback ตั้งแต่คลิกแรก
        claudeSessionLinkBlocked = ClaudeDeepLinkLog.isRejected(
            ClaudeDeepLinkLog.tail(at: Self.claudeLogPath)
        )
        deliveryWatcher.seed()       // ของที่มีอยู่ก่อนเปิดแอปไม่ใช่พัสดุใหม่
        buildMenu()
        registerCompanionHotKey()
        syncMenu()
        applyFrame()

        if runDebugHarness() { return }   // โหมดจำลองยึดงานไปแล้ว

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

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: geometry

    func currentScreen() -> NSScreen {
        let point = NSPoint(x: x + spriteW / 2, y: y + winH / 2)
        return NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func groundY() -> CGFloat { plat.y }

    func clampX(_ value: CGFloat) -> CGFloat {
        min(max(value, plat.minX), plat.maxX - spriteW)
    }

    func applyFrame() {
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
    func refreshPlatforms() {
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
    func resolvePlatform() {
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

    func landingPlatform(from prevY: CGFloat) -> Platform? {
        guard vy < 0 else { return nil }
        let cx = x + spriteW / 2
        return platforms
            .filter { cx >= $0.minX && cx <= $0.maxX && prevY >= $0.y - 1 && y <= $0.y }
            .max(by: { $0.y < $1.y })
    }

    func leap(toX: CGFloat, up: CGFloat) {
        let g: CGFloat = 2600
        vy = (2 * g * max(45, up)).squareRoot()
        let t = max(0.22, 2 * vy / g)
        vx = max(-1000, min(1000, (toX - x) / t))
        dir = vx >= 0 ? 1 : -1
        airborne = true
        setState("jump", duration: 99)
    }

    func land(on p: Platform) {
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
    func poseName() -> String {
        (state == "walk" && hurry && POSES["run"] != nil) ? "run" : state
    }

    func setState(_ name: String, duration: Double, then after: (() -> Void)? = nil) {
        if name != "walk" { walkTime = 0 }
        state = name
        frameIdx = 0
        frameTime = 0
        stateTime = duration
        afterState = after
    }

    /// Seam เดียวสำหรับเฟรมเชื่อมท่าหลัก: anticipation ก่อนลอยตัว และ settle ก่อนหยุดนิ่ง
    /// Reduce Motion ข้ามเฟรมเชื่อมเพื่อเปลี่ยนท่าโดยตรงและไม่เพิ่มการเคลื่อนไหวเกินจำเป็น
    func transitionState(to name: String, duration: Double,
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
    func dashAcross() {
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

    func pickIdle() {
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

    func doPounce() {
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
    func tickForTests(_ dt: Double) { tick(dt) }

    func tick(_ dt: Double) {
        pollCinemaMode(dt)
        // โฟกัสกับตอนหลับต้องเงียบจริง ๆ ไม่งั้นเสียงน่ารักจะกลายเป็นเสียงกวน
        CatVoice.shared.muted = cinemaHidden || focusPhase != .idle || napForced || state == "sleep"
        pollSessions(dt)
        pollDeliveries(dt)
        runLocalCompanion(dt)
        updateCompanionThinking(dt)
        pollInbox(dt)
        runCheck(dt)
        updateFocus(dt)
        if cinemaHidden {
            // งานและ Focus timer ยังเดินต่อ แต่ไม่แสดง/ส่งเสียงรบกวนหนัง
            enforceCinemaHidden()
            return
        }
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
