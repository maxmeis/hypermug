import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import IOKit.hid

/// Runs before NSApplication and the normal runtime. These APIs only inspect existing grants.
enum PermissionDiagnostics {
    private struct Snapshot: Encodable {
        let bundleIdentifier: String
        let bundlePath: String
        let executablePath: String
        let accessibilityGranted: Bool
        let screenRecordingGranted: Bool
        let inputMonitoring: String
    }

    static func runAndExit() -> Never {
        let inputMonitoring: String
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: inputMonitoring = "granted"
        case kIOHIDAccessTypeDenied: inputMonitoring = "denied"
        default: inputMonitoring = "unknown"
        }

        let snapshot = Snapshot(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            bundlePath: Bundle.main.bundlePath,
            executablePath: Bundle.main.executablePath ?? "",
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            inputMonitoring: inputMonitoring
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(snapshot)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("Permission diagnostic failed to encode.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
