// PetController+CompanionChat
// กล่องคุยกับอั่งเปา และวงจรคิด/ตอบ
//
// แยกออกมาจาก PetController.swift เป็น extension ของคลาสเดิม

import Cocoa
import Carbon

extension PetController {

    // MARK: Interactive Manus companion

    /// Carbon hot key ใช้งานได้ทั่วระบบโดยไม่ต้องขอ Accessibility/Input Monitoring
    func registerCompanionHotKey() {
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

    @objc func activateCompanionChatShortcut() {
        if let chatWindow, chatWindow.isVisible, let chatInput {
            NSApp.activate(ignoringOtherApps: true)
            chatWindow.makeKeyAndOrderFront(nil)
            chatWindow.makeFirstResponder(chatInput)
            return
        }
        // ถ้ากล่อง Drag-to-Ask ถูกปิดด้วย Esc แล้วผู้ใช้กดคีย์ลัดภายหลัง
        // ให้กลับมาเป็นการคุยปกติ ไม่พ่วงไฟล์เก่าที่ค้างไว้โดยไม่ตั้งใจ
        pendingCourierPayload = nil
        openCompanionChat()
    }

    @objc func openCompanionChat() {
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
            w.onCancel = { [weak self] in self?.cancelCourierQuestion() }
            bubble.onWidthChange = { [weak self] newWidth in self?.resizeChatBubble(to: newWidth) }
            chatWindow = w
            chatInput = bubble.field
            chatSendButton = nil
        }
        let askingAboutFile = pendingCourierPayload != nil
        let initialText = pendingCourierPayload.map(suggestedCourierQuestion) ?? ""
        chatInput?.stringValue = initialText
        (chatWindow?.contentView as? ChatBubbleInputView)?.setPlaceholder(
            askingAboutFile ? "อยากถาม AI ว่าอะไรเกี่ยวกับไฟล์นี้…" : "คุยกับอั่งเปา…"
        )
        resizeChatBubble(to: initialText.isEmpty
            ? ChatBubbleInputView.minWidth : ChatBubbleInputView.width(for: initialText))
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
            if askingAboutFile { input.selectText(nil) }
        }
    }

    /// กล่องพิมพ์กับกรอบคำพูดยืนที่เดียวกัน พอกดส่งแล้ว "กำลังคิด" จึงเด้งขึ้นตรงนั้นพอดี
    func placeChatBubble() {
        guard let w = chatWindow else { return }
        let size = w.frame.size
        let bx = (x + spriteW / 2 - size.width / 2).rounded()
        let by = (y + winH - 1).rounded()
        w.setFrameOrigin(NSPoint(x: bx, y: by))
    }

    func resizeChatBubble(to width: CGFloat) {
        guard let w = chatWindow else { return }
        w.setContentSize(ChatBubbleInputView.size(width: width))
        placeChatBubble()
    }

    @objc func sendCompanionChat() {
        guard !chatBusy, let input = chatInput else { return }
        let message = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        if pendingCourierPayload != nil {
            guard let menu = prepareCourierQuestion(message) else { return }
            say("จะให้น้องเอาคำถามไปส่งงานไหน?", for: 4.0)
            menu.popUp(positioning: nil,
                       at: NSPoint(x: view.bounds.midX, y: view.bounds.maxY - 4), in: view)
            // popUp เป็น synchronous; ถ้าเลือกจริง chooseCourierTarget จะล้าง payload ไปแล้ว
            if pendingCourierPayload != nil {
                pendingCourierPayload = nil
                courierChoices.removeAll()
                say("ยังไม่ได้ส่งนะ ลากมาให้น้องใหม่ได้เสมอ", for: 3.0)
                transitionState(to: "sit", duration: 1.0)
            }
            return
        }
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

    func beginCompanionThinking() {
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

    func finishLocalFileSearch(query: String, results: [URL]) {
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

    func revealFoundFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if ProcessInfo.processInfo.environment["PIXELCAT_SIMFILEFINDER"] != nil {
            lastSimulatedRevealPath = url.path
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func updateCompanionThinking(_ dt: Double) {
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

    func refreshCompanionThinking(force: Bool = false) {
        let message = thinkingCycle.message
        guard !message.isEmpty, force || message != lastThinkingMessage else { return }
        lastThinkingMessage = message
        say(message, for: 120.0)
    }

    func finishCompanionThinking(success: Bool, message: String, seconds: Double) {
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

    func appendChat(_ text: String) {
        guard let transcript = chatTranscript else { return }
        transcript.textStorage?.append(NSAttributedString(string: text)); transcript.scrollToEndOfDocument(nil)
    }

    func removeThinkingLine() {
        guard let transcript = chatTranscript else { return }
        transcript.string = transcript.string.replacingOccurrences(of: "อั่งเปากำลังคิด…\n\n", with: "")
        transcript.scrollToEndOfDocument(nil)
    }

    func localChatReply(to message: String, snapshot: CompanionSnapshot) -> String {
        CompanionChatResilience.localReply(to: message, snapshot: snapshot)
    }

    @objc func resetCompanionChatTask() {
        ManusCompanionProvider.resetChatTask()
        companionMemory.forgetConversation()   // ลืมแค่บทสนทนา อายุกับจำนวนครั้งที่คุยยังอยู่
        setCompanionConnectionStatus("พร้อมใช้งาน • ยังไม่ได้เรียก")
        say("น้องลืมที่คุยกันไปแล้วนะ แต่ยังจำพ่อได้อยู่", for: 4.0)
    }
}
