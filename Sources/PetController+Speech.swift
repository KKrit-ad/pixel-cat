// PetController+Speech
// กรอบคำพูดและการพูดของน้อง
//
// แยกออกมาจาก PetController.swift เป็น extension ของคลาสเดิม

import Cocoa

extension PetController {

    // MARK: คำพูด

    func setupBubble() {
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

    func say(_ text: String, for seconds: Double = 2.6,
                     target: WorkSession? = nil,
                     actions: [SmartBubbleAction] = []) {
        guard speechOn else { return }
        // ข้อความแจ้งงานสำคัญอยู่ค้างให้อ่านและคลิกได้ ไม่ให้อารมณ์พูดเล่นมาทับ
        if (activeWorkNotice != nil || activeContextRescue != nil || activeDelivery != nil)
            && target == nil && actions.isEmpty { return }
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

    func placeBubble() {
        let size = bubbleWindow.frame.size
        let bx = (x + spriteW / 2 - size.width / 2).rounded()
        let by = (y + winH - 1).rounded()
        bubbleWindow.setFrameOrigin(NSPoint(x: bx, y: by))
    }

    func hideBubble() {
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
            self.activeDelivery = nil
            if self.shepherdTarget?.id == self.bubbleTarget?.id {
                self.shepherdTarget = nil
            }
            self.bubbleTarget = nil
            self.fileSearchTarget = nil
            self.showNextWorkNotice()
            self.showNextDelivery()
        })
    }

    /// BubbleView เรียกเมธอดนี้เมื่อกล่องแจ้งงานถูกคลิก
    func openBubbleTarget() {
        if activeDelivery != nil {
            performDeliveryAction(.open)
            return
        }
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

    func ambientLine() -> String {
        let h = Calendar.current.component(.hour, from: Date())
        if (h >= 23 || h < 5), state != "sleep", Double.random(in: 0..<1) < 0.35 {
            return NIGHT_LINES.randomElement()!
        }
        return (LINES[state] ?? LINES["sit"]!).randomElement()!
    }
}
