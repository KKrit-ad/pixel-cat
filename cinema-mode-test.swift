import Foundation

@main
enum CinemaModeTest {
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let full = CinemaWindow(ownerPID: 42, bounds: screen, layer: 0, alpha: 1)
        let almostFull = CinemaWindow(
            ownerPID: 42,
            bounds: CGRect(x: 2, y: 1, width: 1725, height: 1115),
            layer: 0,
            alpha: 1
        )
        let normal = CinemaWindow(
            ownerPID: 42,
            bounds: CGRect(x: 100, y: 100, width: 1200, height: 800),
            layer: 0,
            alpha: 1
        )
        let otherApp = CinemaWindow(ownerPID: 7, bounds: screen, layer: 0, alpha: 1)

        let autoBrowser = CinemaModeDetector.shouldHide(
            preference: .automatic,
            bundleID: "com.apple.Safari",
            frontmostPID: 42,
            screen: screen,
            windows: [full]
        )
        let autoPlayer = CinemaModeDetector.shouldHide(
            preference: .automatic,
            bundleID: "com.colliderli.iina",
            frontmostPID: 42,
            screen: screen,
            windows: [almostFull]
        )
        let autoIDE = CinemaModeDetector.shouldHide(
            preference: .automatic,
            bundleID: "com.apple.dt.Xcode",
            frontmostPID: 42,
            screen: screen,
            windows: [full]
        )
        let everyIDE = CinemaModeDetector.shouldHide(
            preference: .everyFullscreen,
            bundleID: "com.apple.dt.Xcode",
            frontmostPID: 42,
            screen: screen,
            windows: [full]
        )
        let neverBrowser = CinemaModeDetector.shouldHide(
            preference: .never,
            bundleID: "com.apple.Safari",
            frontmostPID: 42,
            screen: screen,
            windows: [full]
        )
        let wrongPID = CinemaModeDetector.shouldHide(
            preference: .everyFullscreen,
            bundleID: "com.apple.Safari",
            frontmostPID: 42,
            screen: screen,
            windows: [otherApp]
        )
        let notFull = CinemaModeDetector.shouldHide(
            preference: .everyFullscreen,
            bundleID: "com.apple.Safari",
            frontmostPID: 42,
            screen: screen,
            windows: [normal]
        )

        guard autoBrowser, autoPlayer, !autoIDE, everyIDE, !neverBrowser,
              !wrongPID, !notFull else {
            FileHandle.standardError.write(
                "FAIL: Cinema Mode เลือกแอปหรือหน้าต่าง Full Screen ผิด\n".data(using: .utf8)!
            )
            exit(1)
        }
        print("PASS: Cinema Mode hides media full screen, preserves IDEs in auto, and honors all modes")
    }
}
