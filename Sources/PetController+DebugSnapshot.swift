// PetController+DebugSnapshot
// โหมดจำลอง: ของเล่น สแนปชอต และการยิงสมองจริง
//
// ครอบคลุม PIXELCAT_SIMPET, SIMTHROW, SIMBALL, SIMTEST, SNAP, SIMCHATRESILIENCE,
// BRAINTEST, SNAPCHAT, DEBUG

import Cocoa

extension PetController {

    /// - Returns: true = โหมดจำลองยึดการทำงานไปแล้ว ไม่ต้องเดินนาฬิกาต่อ
    func runDebugSnapshotHarness() -> Bool {
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
            return true
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
            return true
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
            return true
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
            return true
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

        return false
    }
}
