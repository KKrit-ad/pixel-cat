import Foundation

@main
enum ClaudeLinkMonitorTest {
    static func main() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent(
            "pixelcat-claude-link-\(UUID().uuidString).log"
        )
        defer { try? fm.removeItem(at: url) }

        // จำลอง main.log จริงที่ยาวเกิน tail 8 KB ไปแล้ว
        try Data(repeating: 65, count: 12_000).write(to: url)
        let cursor = ClaudeDeepLinkLog.cursor(at: url.path)
        let line = "\n[info] claudeURLHandler: code entry deep link gated off\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()

        let added = ClaudeDeepLinkLog.text(at: url.path, since: cursor)
        guard added == line, ClaudeDeepLinkLog.isRejected(added) else {
            FileHandle.standardError.write(
                "FAIL: มองไม่เห็นคำปฏิเสธที่ Claude เพิ่งต่อท้าย log\n".data(using: .utf8)!
            )
            exit(1)
        }

        // ถ้า Claude หมุน log แล้วไฟล์สั้นลง ต้องเริ่มอ่านไฟล์ใหม่ ไม่ใช้ offset เก่า
        let rotated = "[warn] claudeURLHandler: code entry link invalid ?session\n"
        try Data(rotated.utf8).write(to: url)
        let afterRotation = ClaudeDeepLinkLog.text(at: url.path, since: cursor)
        guard afterRotation == rotated, ClaudeDeepLinkLog.isRejected(afterRotation) else {
            FileHandle.standardError.write(
                "FAIL: ตาม log ไม่ทันหลังไฟล์ถูกหมุน\n".data(using: .utf8)!
            )
            exit(1)
        }

        print("PASS: Claude deep-link rejection is detected after append and log rotation")
    }
}
