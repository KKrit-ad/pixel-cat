// DeliveryWatcher
// เฝ้าเฉพาะชื่อ/ขนาดไฟล์ใน Downloads และ Screenshot บน Desktop แบบ local

import Foundation

enum DeliveryKind: String, Equatable {
    case download
    case screenshot

    var label: String {
        switch self {
        case .download: return "ดาวน์โหลด"
        case .screenshot: return "ภาพหน้าจอ"
        }
    }
}

struct DeliveryItem: Equatable {
    let url: URL
    let kind: DeliveryKind
    let discoveredAt: Double
}

final class DeliveryWatcher {
    private struct Candidate {
        var size: Int64
        var modified: TimeInterval
        var stablePolls: Int
        let kind: DeliveryKind
    }

    private let downloads: URL
    private let desktop: URL
    private let manager: FileManager
    private var seen: Set<String> = []
    private var candidates: [String: Candidate] = [:]

    init(downloads: URL, desktop: URL, manager: FileManager = .default) {
        self.downloads = downloads.standardizedFileURL
        self.desktop = desktop.standardizedFileURL
        self.manager = manager
    }

    convenience init(manager: FileManager = .default) {
        let home = manager.homeDirectoryForCurrentUser
        self.init(downloads: home.appendingPathComponent("Downloads", isDirectory: true),
                  desktop: home.appendingPathComponent("Desktop", isDirectory: true),
                  manager: manager)
    }

    func seed() {
        for file in scan() { seen.insert(file.path) }
        candidates.removeAll()
    }

    func poll(now: Double = Date().timeIntervalSince1970) -> [DeliveryItem] {
        let files = scan()
        let live = Set(files.map(\.path))
        candidates = candidates.filter { live.contains($0.key) }
        var ready: [DeliveryItem] = []

        for file in files where !seen.contains(file.path) {
            if var candidate = candidates[file.path] {
                if candidate.size == file.size && candidate.modified == file.modified {
                    candidate.stablePolls += 1
                } else {
                    candidate.size = file.size
                    candidate.modified = file.modified
                    candidate.stablePolls = 0
                }
                candidates[file.path] = candidate
                if candidate.stablePolls >= 1 {
                    seen.insert(file.path)
                    candidates.removeValue(forKey: file.path)
                    ready.append(DeliveryItem(url: URL(fileURLWithPath: file.path),
                                              kind: candidate.kind,
                                              discoveredAt: now))
                }
            } else {
                candidates[file.path] = Candidate(size: file.size, modified: file.modified,
                                                  stablePolls: 0, kind: file.kind)
            }
        }
        return ready.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    private struct ScannedFile {
        let path: String
        let size: Int64
        let modified: TimeInterval
        let kind: DeliveryKind
    }

    private func scan() -> [ScannedFile] {
        scan(downloads, kind: .download) + scan(desktop, kind: .screenshot)
    }

    private func scan(_ directory: URL, kind: DeliveryKind) -> [ScannedFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard accepts(url, kind: kind),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            return ScannedFile(path: url.standardizedFileURL.path,
                               size: Int64(values.fileSize ?? 0),
                               modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                               kind: kind)
        }
    }

    private func accepts(_ url: URL, kind: DeliveryKind) -> Bool {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        let unfinished = [".crdownload", ".download", ".part", ".partial", ".tmp"]
        guard !name.hasPrefix("."), !unfinished.contains(where: lower.hasSuffix) else {
            return false
        }
        guard kind == .screenshot else { return true }
        return lower.hasPrefix("screenshot")
            || lower.hasPrefix("screen shot")
            || lower.hasPrefix("ภาพหน้าจอ")
    }
}
