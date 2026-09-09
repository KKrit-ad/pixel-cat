// PetController+Delivery
// Delivery Cat — คิวพัสดุและการตัดสินใจของพ่อ
//
// แยกออกมาจาก PetController.swift เป็น extension ของคลาสเดิม

import Cocoa

extension PetController {

    // MARK: Delivery Cat

    func pollDeliveries(_ dt: Double) {
        guard deliveryEnabled else { return }
        deliveryPoll -= dt
        if deliveryPoll <= 0 {
            deliveryPoll = 0.8
            let arrived = deliveryWatcher.poll()
            if !arrived.isEmpty {
                lastDeliveryStayedLocal = true
                let known = Set(collectingDeliveries.map { $0.url.path })
                collectingDeliveries.append(contentsOf: arrived.filter { !known.contains($0.url.path) })
                deliveryQuiet = 1.2
            }
        }

        guard !collectingDeliveries.isEmpty else {
            showNextDelivery()
            return
        }
        deliveryQuiet -= dt
        guard deliveryQuiet <= 0 else { return }
        let batch = DeliveryBatch(id: UUID(), items: collectingDeliveries,
                                  arrivedAt: Date().timeIntervalSince1970)
        collectingDeliveries.removeAll()
        deliveryHistory.insert(batch, at: 0)
        if deliveryHistory.count > 10 { deliveryHistory.removeLast(deliveryHistory.count - 10) }
        refreshDeliveryMenu()

        if speechOn {
            deliveryQueue.append(batch)
            showNextDelivery()
        } else {
            playDeliveryPose(id: nil, waiting: false)
        }
    }

    func deliveryMessage(_ batch: DeliveryBatch) -> String {
        guard batch.items.count == 1, let item = batch.items.first else {
            return "น้องคาบพัสดุใหม่มาให้ \(batch.items.count) ไฟล์"
        }
        let name = item.url.lastPathComponent
        let short = name.count > 42 ? String(name.prefix(40)) + "…" : name
        return "\(item.kind.label) \(short) เสร็จแล้ว"
    }

    func playDeliveryPose(id: UUID?, waiting: Bool) {
        guard !held else { return }
        if reduceMotionEnabled || effectiveMotionLevel == .calm {
            setState("deliveryReady", duration: waiting ? 12 : 3) { [weak self] in self?.pickIdle() }
            return
        }
        setState("delivery", duration: 1.16) { [weak self] in
            guard let self else { return }
            if waiting, id == self.activeDelivery?.id {
                self.setState("deliveryReady", duration: 99)
            } else {
                self.transitionState(to: "sit", duration: 2.0) { [weak self] in self?.pickIdle() }
            }
        }
    }

    func showNextDelivery() {
        guard speechOn, focusPhase == .idle, !cinemaHidden, !held, !chatBusy,
              activeDelivery == nil, activeWorkNotice == nil, activeContextRescue == nil,
              !deliveryQueue.isEmpty else { return }
        let batch = deliveryQueue.removeFirst()
        activeDelivery = batch
        bubbleTarget = nil
        playDeliveryPose(id: batch.id, waiting: true)
        say(deliveryMessage(batch), for: 14.0,
            actions: [SmartBubbleAction(id: .open, title: "เปิด"),
                      SmartBubbleAction(id: .keepDelivery, title: "เก็บ"),
                      SmartBubbleAction(id: .sendDelivery, title: "ส่ง AI"),
                      SmartBubbleAction(id: .dismissDelivery, title: "ผ่านก่อน")])
    }

    func replaceDeliveryHistory(_ batch: DeliveryBatch) {
        if let index = deliveryHistory.firstIndex(where: { $0.id == batch.id }) {
            deliveryHistory[index] = batch
            refreshDeliveryMenu()
        }
    }

    func uniqueDeliveryDestination(for source: URL, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(source.lastPathComponent)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        var number = 2
        repeat {
            let name = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            number += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    func clearActiveDelivery() {
        activeDelivery = nil
        bubbleView.actions = []
        bubbleView.interactive = false
        bubbleWindow.ignoresMouseEvents = true
        if state == "delivery" || state == "deliveryReady" {
            transitionState(to: "sit", duration: 1.2) { [weak self] in self?.pickIdle() }
        }
    }

    func performDeliveryAction(_ action: SmartBubbleActionID) {
        guard var batch = activeDelivery else { return }
        let existing = batch.items.filter {
            FileManager.default.fileExists(atPath: $0.url.path)
        }
        switch action {
        case .open:
            if ProcessInfo.processInfo.environment["PIXELCAT_SIMDELIVERY"] != nil {
                lastSimulatedDeliveryAction = "open"
            } else if existing.count == 1, let url = existing.first?.url {
                NSWorkspace.shared.open(url)
            } else if !existing.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(existing.map(\.url))
            }
            clearActiveDelivery()
            speakFor = 0
            say(existing.isEmpty ? "พัสดุถูกย้ายไปแล้วนะ" : "เปิดพัสดุให้แล้ว", for: 3.5)

        case .keepDelivery:
            let manager = FileManager.default
            let directory = manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Angpao Deliveries", isDirectory: true)
            var moved: [DeliveryItem] = []
            if ProcessInfo.processInfo.environment["PIXELCAT_SIMDELIVERY"] != nil {
                lastSimulatedDeliveryAction = "keep"
                moved = existing
            } else if (try? manager.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)) != nil {
                for item in existing {
                    let destination = uniqueDeliveryDestination(for: item.url, in: directory)
                    if (try? manager.moveItem(at: item.url, to: destination)) != nil {
                        moved.append(DeliveryItem(url: destination, kind: item.kind,
                                                  discoveredAt: item.discoveredAt))
                    }
                }
            }
            batch.items = moved
            if !moved.isEmpty { replaceDeliveryHistory(batch) }
            clearActiveDelivery()
            speakFor = 0
            say(moved.isEmpty ? "เก็บพัสดุไม่สำเร็จ ลองเปิดดูตำแหน่งก่อนนะ"
                              : "เก็บไว้ใน Documents/Angpao Deliveries แล้ว",
                for: 5.0)

        case .sendDelivery:
            let urls = existing.map(\.url)
            clearActiveDelivery()
            speakFor = 0
            if ProcessInfo.processInfo.environment["PIXELCAT_SIMDELIVERY"] != nil {
                lastSimulatedDeliveryAction = "send"
            } else {
                _ = receiveCourierDrop(files: urls, text: nil)
            }

        case .dismissDelivery:
            lastSimulatedDeliveryAction = "dismiss"
            clearActiveDelivery()
            speakFor = 0
            hideBubble()
            transitionState(to: "sit", duration: 1.2) { [weak self] in self?.pickIdle() }

        case .summarize, .helpFix, .later:
            return
        }
    }
}
