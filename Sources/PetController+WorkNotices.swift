// PetController+WorkNotices
// พิธีต้อนรับกลับมา และคิวแจ้งเตือนสถานะงาน
//
// แยกออกมาจาก PetController.swift เป็น extension ของคลาสเดิม

import Cocoa

extension PetController {

    func noticeProjectName(_ name: String) -> String {
        name.count > 26 ? String(name.prefix(24)) + "…" : name
    }

    func noticeKey(_ session: WorkSession) -> String {
        "\(session.source):\(session.id)"
    }

    func workSourceName(_ session: WorkSession) -> String {
        session.source == "codex" ? "Codex" : "Claude"
    }

    func returnRitualEvent(_ session: WorkSession) -> ReturnRitualEvent {
        ReturnRitualEvent(
            key: noticeKey(session),
            title: noticeProjectName(sessionHeadline(session)),
            source: session.source,
            state: session.state,
            updatedAt: session.updatedAt
        )
    }

    func captureReturnRitual(_ sessions: [WorkSession], now: Double,
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

    func returnRitualText(_ summary: ReturnRitualSummary) -> String {
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

    func showPendingReturnRitual() {
        guard let summary = pendingReturnRitual,
              focusPhase == .idle, !cinemaHidden, !held, !airborne, !climbing, !chatBusy,
              activeWorkNotice == nil, activeContextRescue == nil,
              activeDelivery == nil else { return }
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
    @objc func demoReturnRitual() {
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
    func detectWorkNotices(_ sessions: [WorkSession]) {
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
    func remindLongWaitingWork(_ sessions: [WorkSession], now: Double) {
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
    func watchLongRunningWork(_ sessions: [WorkSession], now: Double) {
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

    func enqueueWorkNotice(_ notice: WorkNotice) {
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

    func showNextWorkNotice() {
        guard speechOn, focusPhase == .idle, !cinemaHidden, !held, !chatBusy,
              !companionReplyProtected,
              activeWorkNotice == nil, activeContextRescue == nil, activeDelivery == nil,
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

    func smartActions(for kind: WorkNoticeKind) -> [SmartBubbleAction] {
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
        if activeDelivery != nil {
            performDeliveryAction(action)
            return
        }
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
        case .keepDelivery, .sendDelivery, .dismissDelivery:
            return
        }
    }

    func deliverSmartPrompt(_ prompt: String, to session: WorkSession,
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
    func playWorkEmotion(_ kind: WorkNoticeKind) {
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
    func playBuildTestAnimation(_ kind: WorkActivityKind) {
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
    func updateBuildTestAwareness(_ sessions: [WorkSession]) {
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

    func workActivitySignature(_ session: WorkSession) -> String {
        noticeKey(session) + ":" + session.activity.kind.rawValue
            + ":" + session.activity.fingerprint
    }

    var focusActionTitle: String {
        switch focusPhase {
        case .idle: return "เริ่มโฟกัส 25 นาที"
        case .focus: return "หยุดโฟกัส • \(focusClock)"
        case .rest: return "จบเวลาพัก • \(focusClock)"
        }
    }

    var focusClock: String {
        let total = max(0, Int(ceil(focusRemaining)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    func updateFocusUI(force: Bool = false) {
        let second = max(0, Int(ceil(focusRemaining)))
        guard force || second != focusDisplaySecond else { return }
        focusDisplaySecond = second
        focusMenuItem?.title = focusActionTitle
        updateStatusTitle()
    }

    func updateStatusTitle() {
        let badge = workAlertCount > 0 ? " • \(workAlertCount)" : ""
        switch focusPhase {
        case .idle: statusItem.button?.title = "🐈\(badge)"
        case .focus: statusItem.button?.title = "🐈 \(focusClock)\(badge)"
        case .rest: statusItem.button?.title = "🐈 พัก \(focusClock)\(badge)"
        }
    }

    @objc func toggleFocus() {
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

    func updateFocus(_ dt: Double) {
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

    @objc func toggleFollow() {
        follow.toggle()
        if follow { say("ตามติดเลย"); setState("walk", duration: 99) } else { pickIdle() }
        syncMenu()
    }

    @objc func toggleVoice() {
        CatVoice.shared.enabled.toggle()
        if CatVoice.shared.enabled {
            CatVoice.shared.play(.mew, minGap: 0)     // ให้ได้ยินทันทีว่าเปิดแล้วเสียงเป็นยังไง
        } else {
            CatVoice.shared.stopAll()
        }
        syncMenu()
    }

    @objc func toggleSpeech() {
        speechOn.toggle()
        UserDefaults.standard.set(speechOn, forKey: "speechOn")
        if speechOn {
            showNextWorkNotice()
            if activeWorkNotice == nil { showNextDelivery() }
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

    @objc func toggleOnTop() {
        onTop.toggle()
        window.level = onTop ? .floating
                             : NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)))
        bubbleWindow.level = window.level
        heartWindow.level = window.level
        ballWindow.level = window.level
        geckoWindow.level = window.level
        syncMenu()
    }

    @objc func togglePause() {
        paused.toggle()
        if paused { transitionState(to: "sit", duration: 999) } else { pickIdle() }
        syncMenu()
    }

    @objc func napNow() {
        napForced = true
        say("ง่วงแล้ว…")
        setState("sleep", duration: 99999)   // หลับยาวจนกว่าจะปลุก
    }

    @objc func wakeNow() {
        napForced = false
        say("อ๊าาา~")
        setState("stretch", duration: 1.6) { [weak self] in self?.pickIdle() }
    }

    @objc func comeHere() {
        say("มาแล้วววว")
        target = NSEvent.mouseLocation.x - spriteW / 2
        setState("walk", duration: 99) { [weak self] in
            self?.transitionState(to: "sit", duration: 4)
        }
    }

    @objc func setSize(_ sender: NSMenuItem) {
        scale = CGFloat(sender.tag) / 10
        UserDefaults.standard.set(sender.tag, forKey: "catScaleTenths128")
        x = clampX(x)
        y = groundY()
        applyFrame()
        syncMenu()
    }

    @objc func setMotionLevel(_ sender: NSMenuItem) {
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

    @objc func setCinemaPreference(_ sender: NSMenuItem) {
        guard let preference = CinemaPreference(rawValue: sender.tag - 60) else { return }
        cinemaPreference = preference
        UserDefaults.standard.set(preference.rawValue, forKey: "cinemaPreference")
        cinemaPoll = 0
        cinemaCandidate = nil
        cinemaCandidateCount = 0
        pollCinemaMode(0, force: true)
        syncMenu()
        if !cinemaHidden { say("Cinema Mode: \(preference.label)", for: 2.2) }
    }

    /// หยุดเฉพาะ motion แรงที่กำลังเตรียมหรือกำลังวิ่งเมื่อเข้า Calm/Reduce Motion
    /// การเดินธรรมดายังทำต่อได้ เพราะไม่ได้ตั้ง hurry หรือ energetic intent เหล่านี้
    func cancelEnergeticMotionIfNeeded() {
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
}
