import Foundation

@main
enum DeliveryWatcherTest {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "pixelcat-delivery-\(UUID().uuidString)", isDirectory: true
        )
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let old = downloads.appendingPathComponent("old.pdf")
        try Data("old".utf8).write(to: old)
        let watcher = DeliveryWatcher(downloads: downloads, desktop: desktop)
        watcher.seed()
        guard watcher.poll(now: 1).isEmpty else { exit(1) }

        let report = downloads.appendingPathComponent("report.pdf")
        try Data("part".utf8).write(to: report)
        guard watcher.poll(now: 2).isEmpty else { exit(1) }
        // ขนาดยังเปลี่ยนอยู่ต้องไม่คาบไฟล์ครึ่งเดียวมาให้
        let handle = try FileHandle(forWritingTo: report)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ial".utf8))
        try handle.close()
        guard watcher.poll(now: 3).isEmpty else { exit(1) }
        let download = watcher.poll(now: 4)

        let screenshot = desktop.appendingPathComponent("Screenshot 2026-09-09 at 10.00.00.png")
        try Data("png".utf8).write(to: screenshot)
        _ = watcher.poll(now: 5)
        let capture = watcher.poll(now: 6)

        let partial = downloads.appendingPathComponent("movie.crdownload")
        try Data("x".utf8).write(to: partial)
        _ = watcher.poll(now: 7)
        let ignored = watcher.poll(now: 8)

        let ok = download.count == 1 && download[0].url.lastPathComponent == "report.pdf"
            && download[0].kind == .download
            && capture.count == 1 && capture[0].kind == .screenshot
            && ignored.isEmpty
        guard ok else {
            FileHandle.standardError.write(
                "FAIL: watcher แจ้งไฟล์เก่า ไฟล์ยังโหลดไม่เสร็จ หรือแยก screenshot ผิด\n"
                    .data(using: .utf8)!
            )
            exit(1)
        }
        print("PASS: watcher emits only new stable downloads and screenshots")
    }
}
