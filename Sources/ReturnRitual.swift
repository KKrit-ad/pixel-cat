// ReturnRitual
// พิธีต้อนรับกลับมาหลังพ่อหายไปนาน

import Cocoa

enum ReturnRitualImportance: Int {
    case done = 1, waiting = 2, failed = 3
}

struct ReturnRitualEvent: Equatable {
    let key: String
    let title: String
    let source: String
    let state: String
    let updatedAt: Double

    var importance: ReturnRitualImportance? {
        switch state.lowercased() {
        case "idle", "done", "completed": return .done
        case "input", "ask", "waiting": return .waiting
        case "fail", "failed", "error": return .failed
        default: return nil
        }
    }
}

struct ReturnRitualSummary {
    let awaySeconds: Double
    let events: [ReturnRitualEvent]
}

/// ติดตามการหายไป/กลับมาด้วย interface เดียว ไม่ผูกกับ AppKit หรือ provider
struct ReturnRitualTracker {
    let minimumAway: Double
    let activeThreshold: Double
    let eventLimit: Int

    private var awaySince: Double?
    private var eligible = false
    private var previousStates: [String: String] = [:]
    private var captured: [String: ReturnRitualEvent] = [:]

    init(minimumAway: Double = 10 * 60, activeThreshold: Double = 3,
         eventLimit: Int = 3) {
        self.minimumAway = minimumAway
        self.activeThreshold = activeThreshold
        self.eventLimit = eventLimit
    }

    mutating func observe(now: Double, idleSeconds: Double, focusActive: Bool,
                          events: [ReturnRitualEvent]) -> ReturnRitualSummary? {
        let currentStates = Dictionary(uniqueKeysWithValues: events.map { ($0.key, $0.state) })
        let isAway = idleSeconds > activeThreshold

        if awaySince == nil, isAway {
            awaySince = now - idleSeconds
            eligible = idleSeconds >= minimumAway
            captured.removeAll()
        }

        if awaySince != nil {
            eligible = eligible || idleSeconds >= minimumAway
            for event in events where event.importance != nil {
                let changed = previousStates[event.key].map { $0 != event.state } ?? false
                let appearedWhileAway = previousStates[event.key] == nil
                    && event.updatedAt >= (awaySince ?? now)
                if changed || appearedWhileAway { captured[event.key] = event }
            }
        }
        previousStates = currentStates

        guard awaySince != nil, !isAway, eligible, !focusActive else {
            if awaySince != nil, !isAway, !eligible { resetAfterReturn() }
            return nil
        }

        let started = awaySince ?? now
        let important = captured.values.sorted {
            let left = $0.importance?.rawValue ?? 0
            let right = $1.importance?.rawValue ?? 0
            return left == right ? $0.updatedAt > $1.updatedAt : left > right
        }
        let summary = ReturnRitualSummary(
            awaySeconds: max(0, now - started),
            events: Array(important.prefix(eventLimit))
        )
        resetAfterReturn()
        return summary
    }

    private mutating func resetAfterReturn() {
        awaySince = nil
        eligible = false
        captured.removeAll()
    }
}
