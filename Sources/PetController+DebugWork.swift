// PetController+DebugWork
// โหมดจำลอง: งาน AI, พัสดุ และเส้นทางกลับไปหางาน
//
// ครอบคลุม PIXELCAT_SIMDELIVERY, SIMCINEMA, SIMVOICE, SIMOPENROUTE, SIMFILEFINDER,
// SIMSHORTCUTGECKO, SIMRETURNRITUAL, SIMBUILDTEST, SIMCODING, SIMSHEPHERD,
// SIMCOURIER, SIMCONTEXTRESCUE

import Cocoa

extension PetController {

    /// - Returns: true = โหมดจำลองยึดการทำงานไปแล้ว ไม่ต้องเดินนาฬิกาต่อ
    func runDebugWorkHarness() -> Bool {
        if ProcessInfo.processInfo.environment["PIXELCAT_SIMDELIVERY"] != nil {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent(
                "pixelcat-delivery-ui-\(UUID().uuidString)", isDirectory: true
            )
            let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
            let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
            try? fm.createDirectory(at: downloads, withIntermediateDirectories: true)
            try? fm.createDirectory(at: desktop, withIntermediateDirectories: true)
            deliveryWatcher = DeliveryWatcher(downloads: downloads, desktop: desktop)
            deliveryWatcher.seed()
            try? Data("one".utf8).write(to: downloads.appendingPathComponent("one.pdf"))
            try? Data("two".utf8).write(to: downloads.appendingPathComponent("two.png"))
            deliveryPoll = 0; pollDeliveries(1.0)   // พบครั้งแรก แต่ยังรอขนาดนิ่ง
            deliveryPoll = 0; pollDeliveries(1.0)   // stable แล้ว เริ่มรวมพัสดุ
            deliveryQuiet = 0; pollDeliveries(0.01)
            let detected = activeDelivery?.items.count == 2
            let grouped = deliveryHistory.first?.items.count == 2
            let pose = state == "delivery" || state == "deliveryReady"
            let actionIDs = Set(bubbleView.actions.map(\.id))
            let actions = actionIDs == Set([.open, .keepDelivery, .sendDelivery,
                                            .dismissDelivery])
            let local = lastDeliveryStayedLocal
            try? fm.removeItem(at: root)
            let ok = detected && grouped && pose && actions && local
            FileHandle.standardError.write(
                "SIM DELIVERY detected=\(detected) grouped=\(grouped) pose=\(pose) "
                    .appending("actions=\(actions) local=\(local)\n").data(using: .utf8)!
            )
            NSApp.terminate(nil)
            if !ok { exit(2) }
            return true
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMCINEMA"] != nil {
            // ตรวจ integration ของหน้าต่างทุกชนิด โดยไม่ต้องเปิดวิดีโอ Full Screen จริง
            let simChat = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 240, height: 120),
                                   styleMask: .borderless, backing: .buffered, defer: false)
            chatWindow = simChat
            for w in [bubbleWindow, heartWindow, ballWindow, geckoWindow, simChat] {
                w.alphaValue = 1
                w.orderFrontRegardless()
            }
            let all = companionWindows()
            let startedVisible = all.allSatisfy(\.isVisible)
            setCinemaHidden(true)
            let hiddenAll = cinemaHidden && all.allSatisfy { !$0.isVisible }
            setCinemaHidden(false)
            let restoredAll = !cinemaHidden && all.allSatisfy(\.isVisible)
            let modes = makeCinemaMenu().items.count == CinemaPreference.allCases.count
            let ok = startedVisible && hiddenAll && restoredAll && modes
            FileHandle.standardError.write(
                "SIM CINEMA hidden=\(hiddenAll) restored=\(restoredAll) modes=\(modes)\n"
                    .data(using: .utf8)!
            )
            NSApp.terminate(nil)
            if !ok { exit(2) }
            return true
        }

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
            return true
        }

        if ProcessInfo.processInfo.environment["PIXELCAT_SIMOPENROUTE"] != nil {
            // ผลจาก Claude จริงในเครื่องต้องไม่ทำให้ simulation เปลี่ยนเงื่อนไขเริ่มต้น
            self.claudeSessionLinkBlocked = false
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
                && link?.absoluteString.contains("session=local_\(sid)") == true
            // deep link ที่เจาะจงแท็บอยู่แล้ว ยังต้องชนะทุกกรณี
            let warp = self.openRoute(focus: "warp://session/abc", path: "/tmp", pids: mine,
                                      sessionID: sid)
            // ไม่มี session id ก็ยังต้องพากลับไปที่แอปหรือโฟลเดอร์ได้
            let app = self.openRoute(focus: "", path: "/tmp", pids: mine, sessionID: "")
            // ไม่มีอะไรเจาะจงเลย ยังต้องพากลับไปที่แอปหรือโฟลเดอร์ได้เสมอ
            // (ได้ focusApp เมื่อแอป Claude เปิดอยู่บนเครื่องที่รันเทสต์)
            let plainRoute = self.openRoute(focus: "", path: "/tmp", pids: [], sessionID: "")
            let plain = plainRoute == .folder || plainRoute == .focusApp

            // ลิงก์ห้องถูกปิด และยังไม่ได้สิทธิ์ Accessibility ก็ต้องยังไปถึงห้องนั้นได้
            // ด้วย resume — ยอมมีห้องซ้ำ ดีกว่ากดแล้วไม่ไปไหน
            let noPermission = self.fallbackRoute(pids: [], path: "", sessionID: sid, topic: "")
            let withPermission = self.fallbackRoute(pids: [], path: "", sessionID: sid,
                                                    topic: "งานเดโม")
            let alwaysArrives = noPermission == .resume
                && (withPermission == .sidebarRow || !AXIsProcessTrusted())

            // จับคู่แถวใน sidebar: ชื่อซ้ำกันได้ ต้องเลือกอันที่อยู่ใต้โฟลเดอร์ของงานนั้น
            let labels = ["Show sidebar",
                          "cha-landing", "New session in cha-landing",
                          "Idle แก้บั๊ก", "Idle งานอื่น",
                          "pixel-cat", "New session in pixel-cat",
                          "Idle แก้บั๊ก", "Idle เสียงน้อง"]
            let picked = ClaudeSidebar.rowIndex(labels: labels, project: "pixel-cat",
                                                topic: "แก้บั๊ก")
            // ไม่มีในโฟลเดอร์นั้นก็ยอมใช้ที่อื่น ดีกว่ากดแล้วไม่ไปไหน
            let elsewhere = ClaudeSidebar.rowIndex(labels: labels, project: "ไม่มีโฟลเดอร์นี้",
                                                   topic: "เสียงน้อง")
            // หัวข้อโฟลเดอร์กับปุ่มสร้างห้องใหม่ ต้องไม่ถูกนับเป็นแถวห้อง
            let notHeader = ClaudeSidebar.rowIndex(labels: labels, project: "",
                                                   topic: "pixel-cat") == nil
            let noTopic = ClaudeSidebar.rowIndex(labels: labels, project: "pixel-cat",
                                                  topic: "  ") == nil
            let rows = picked == 7 && elsewhere == 8 && notHeader && noTopic
            // แอปปิดลิงก์ห้องไว้ ต้องเลิกยิงลิงก์แล้วดึงแอปขึ้นหน้าแทน ไม่ใช่กดแล้วเงียบ
            self.claudeSessionLinkBlocked = true
            let blocked = self.openRoute(focus: "", path: "/tmp", pids: mine, sessionID: sid)
            self.claudeSessionLinkBlocked = false
            let ok = claude == .sessionLink && continues && blocked == .focusApp
                && warp == .deepLink && app == .focusApp && plain && rows && alwaysArrives
            FileHandle.standardError.write(
                ("SIM OPEN ROUTE claude=\(claude.rawValue) continue=\(continues) "
                + "blocked=\(blocked.rawValue) warp=\(warp.rawValue) "
                + "app=\(app.rawValue) plain=\(plain) rows=\(rows) "
                + "arrives=\(alwaysArrives)\n")
                    .data(using: .utf8)!
            )
            NSApp.terminate(nil)
            if !ok { exit(2) }
            return true
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
            return true
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
            return true
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
            return true
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
                let dragged = URL(fileURLWithPath: "/tmp/drag report.pdf")
                let accepted = self.receiveCourierDrop(files: [dragged], text: nil)
                let askVisible = self.chatWindow?.isVisible == true
                    && self.pendingCourierPayload?.files == [dragged]
                let suggested = self.chatInput?.stringValue == "ช่วยสรุปไฟล์นี้ให้หน่อย"
                let listeningPose = self.state == "tilt" || self.reduceMotionEnabled
                let askMenu = self.prepareCourierQuestion("หาประเด็นสำคัญสามข้อ")
                let composed = self.pendingCourierPayload?.pasteboardText ?? ""
                let asked = askMenu != nil
                    && composed.contains("หาประเด็นสำคัญสามข้อ")
                    && composed.contains(dragged.path)
                self.pendingCourierPayload = nil
                self.courierChoices.removeAll()
                self.chatWindow?.orderOut(nil)
                let menu = self.makeCourierTargetMenu()
                let titles = menu.items.map(\.title)
                let sections = titles.contains("Codex") && titles.contains("Claude Code")
                    && self.courierChoices.count == 2
                let hostile = "$(touch /tmp/pixelcat-must-not-run); `whoami`"
                let payload = CourierPayload(files: [], text: hostile)
                let safePayload = payload.pasteboardText == hostile
                self.motionLevel = .normal
                self.motionReductionOverride = false
                self.courierPastePermissionOverride = true
                self.courierFrontmostOverride = true
                self.performCourierDelivery(payload, to: codex)
                let animated = self.state == "courier"
                for _ in 0..<360 { self.tick(1.0 / 60.0) }
                let redirected = self.lastSimulatedOpenURL == codex.focusURL
                let autoPaste = self.lastSimulatedCourierPaste
                self.motionReductionOverride = true
                self.lastSimulatedOpenURL = ""
                self.performCourierDelivery(payload, to: claude)
                let reduced = self.state != "courier"
                    && self.lastSimulatedOpenURL == claude.focusURL
                let registered = self.courierDropRegistered
                let dragToAsk = accepted && askVisible && suggested && listeningPose && asked
                let ok = registered && sections && safePayload && animated && redirected && reduced
                    && dragToAsk && autoPaste
                FileHandle.standardError.write(
                    ("SIM COURIER registered=\(registered) sections=\(sections) "
                     + "safePayload=\(safePayload) animated=\(animated) "
                     + "redirected=\(redirected) reduced=\(reduced) "
                     + "dragToAsk=\(dragToAsk) autoPaste=\(autoPaste)\n").data(using: .utf8)!
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

        return false
    }
}
