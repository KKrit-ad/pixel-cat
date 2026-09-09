// ClaudeDeepLinkLog
// อ่านผลตอบรับของ Claude deep link โดยจำ byte offset จริง ไม่ใช่ความยาวของ tail

import Foundation

enum ClaudeDeepLinkLog {
    static func cursor(at path: String) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? handle.close() }
        return (try? handle.seekToEnd()) ?? 0
    }

    static func text(at path: String, since cursor: UInt64) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        // Claude อาจ rotate/truncate main.log ระหว่างรอ ถ้าไฟล์สั้นลงให้อ่านไฟล์ใหม่ทั้งก้อน
        let start = size >= cursor ? cursor : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func tail(at path: String, bytes: UInt64 = 65_536) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func isRejected(_ text: String) -> Bool {
        text.contains("code entry deep link gated off")
            || text.contains("code entry link invalid")
            || text.contains("unrecognized code path")
    }
}
