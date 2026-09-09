// PetController+DebugMotion
// โหมดจำลอง: แอนิเมชัน โฟกัส และการแจ้งเตือนงาน
//
// ครอบคลุม PIXELCAT_SIMANIMATIONANCHOR, SIMTRANSITIONS, SIMFOCUS, SIMFOCUSPOUNCE,
// SIMMOTIONLEVELS, SIMWORKINBOX, SIMWAITREMINDER, SIMWORKPOSES,
// SIMBATCHDONE, SIMWORKNOTICE, SIMWORKEMOTIONS

import Cocoa

extension PetController {

    /// - Returns: true = โหมดจำลองยึดการทำงานไปแล้ว ไม่ต้องเดินนาฬิกาต่อ
    func runDebugMotionHarness() -> Bool {
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

        return false
    }
}
