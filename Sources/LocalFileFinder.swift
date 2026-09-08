// LocalFileFinder
// ค้นไฟล์ในเครื่องแบบ local ล้วน ไม่ส่ง path ออกนอกเครื่อง

import Cocoa

/// แปลภาษาที่พ่อใช้ค้นหาไฟล์ โดยแยกจาก AI provider เพื่อไม่ส่งชื่อหรือ path ออกจากเครื่อง
struct LocalFileFinder {
    private let homeDirectory: URL
    private let spotlight: (String, URL) -> [String]

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         spotlight: ((String, URL) -> [String])? = nil) {
        self.homeDirectory = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.spotlight = spotlight ?? Self.runSpotlight
    }

    func query(from message: String) -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n"), text.count <= 180 else { return nil }

        let prefixes = ["/หา ", "/find ", "หาไฟล์ ", "หาโฟลเดอร์ ",
                        "ช่วยหาไฟล์ ", "ช่วยหาโฟลเดอร์ "]
        if let prefix = prefixes.first(where: { text.lowercased().hasPrefix($0.lowercased()) }) {
            return cleanQuery(String(text.dropFirst(prefix.count)))
        }

        let suffixes = [" อยู่ไหน", " อยู่ที่ไหน", " อยู่ตรงไหน"]
        if (text.hasPrefix("ไฟล์ ") || text.hasPrefix("โฟลเดอร์ ")),
           let suffix = suffixes.first(where: { text.hasSuffix($0) }) {
            let head = text.hasPrefix("ไฟล์ ") ? "ไฟล์ " : "โฟลเดอร์ "
            return cleanQuery(String(text.dropFirst(head.count).dropLast(suffix.count)))
        }
        return nil
    }

    func find(named query: String, limit: Int = 5) -> [URL] {
        guard limit > 0 else { return [] }
        var candidates = spotlight(query, homeDirectory).map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath()
        }
        if safeCandidates(candidates).count < limit {
            candidates.append(contentsOf: scanFileNames(containing: query, matchLimit: 200).map {
                $0.standardizedFileURL.resolvingSymlinksInPath()
            })
        }
        let safe = safeCandidates(candidates)
        let needle = query.lowercased()
        return Array(safe.sorted { left, right in
            let leftScore = matchScore(left, needle: needle)
            let rightScore = matchScore(right, needle: needle)
            if leftScore != rightScore { return leftScore < rightScore }
            let leftDate = modificationDate(left)
            let rightDate = modificationDate(right)
            if leftDate != rightDate { return leftDate > rightDate }
            return left.path.localizedStandardCompare(right.path) == .orderedAscending
        }.prefix(limit))
    }

    /// บอกตำแหน่งแบบ ~/Documents/… เพื่อให้พ่อรู้ว่าไฟล์อยู่ไหนจริง ๆ ไม่ใช่แค่ชื่อโฟลเดอร์แม่ที่ซ้ำกันได้
    func displayLocation(for url: URL, maxComponents: Int = 4) -> String {
        let folder = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let homePath = homeDirectory.path
        guard folder.path == homePath || folder.path.hasPrefix(homePath + "/") else {
            return folder.path
        }
        let relative = String(folder.path.dropFirst(homePath.count))
            .split(separator: "/").map(String.init)
        guard !relative.isEmpty else { return "~" }
        guard relative.count > maxComponents else {
            return "~/" + relative.joined(separator: "/")
        }
        // โฟลเดอร์ลึกมากก็ย่อช่วงกลาง แต่ยังเห็นต้นทางและปลายทางชัด
        let head = relative.prefix(1)
        let tail = relative.suffix(maxComponents - 1)
        return "~/" + (head + ["…"] + tail).joined(separator: "/")
    }

    private func safeCandidates(_ candidates: [URL]) -> [URL] {
        let homePath = homeDirectory.path.hasSuffix("/")
            ? homeDirectory.path : homeDirectory.path + "/"
        var seen = Set<String>()
        return candidates.filter { url in
            let path = url.path
            guard (path == homeDirectory.path || path.hasPrefix(homePath)),
                  FileManager.default.fileExists(atPath: path),
                  !path.hasPrefix(homePath + "Library/Caches/"),
                  !path.hasPrefix(homePath + ".Trash/") else { return false }
            return seen.insert(path).inserted
        }
    }

    private func cleanQuery(_ raw: String) -> String? {
        var query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" ให้หน่อย", " ให้ที", " หน่อย"] where query.hasSuffix(suffix) {
            query = String(query.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if query.count >= 2,
           ((query.hasPrefix("\"") && query.hasSuffix("\""))
            || (query.hasPrefix("'") && query.hasSuffix("'"))) {
            query = String(query.dropFirst().dropLast())
        }
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 120 else { return nil }
        return query
    }

    private func matchScore(_ url: URL, needle: String) -> Int {
        let name = url.lastPathComponent.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        if name == needle { return 0 }
        if stem == needle { return 1 }
        if name.hasPrefix(needle) { return 2 }
        if name.contains(needle) { return 3 }
        return 4
    }

    private func modificationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    private func scanFileNames(containing query: String, matchLimit: Int) -> [URL] {
        let needle = query.lowercased()
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let walker = FileManager.default.enumerator(
            at: homeDirectory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        let pruned = Set(["Library", "node_modules", "Pods", "DerivedData", ".build"])
        var found: [URL] = []
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 80_000 || found.count >= matchLimit { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, pruned.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            if url.lastPathComponent.lowercased().contains(needle) { found.append(url) }
        }
        return found
    }

    private static func runSpotlight(query: String, home: URL) -> [String] {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["-onlyin", home.path, "-name", query]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        // อ่านขณะ process กำลังเขียน ป้องกัน pipe เต็มแล้วทั้งสองฝั่งรอกันเมื่อผลลัพธ์เยอะ
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }
}
