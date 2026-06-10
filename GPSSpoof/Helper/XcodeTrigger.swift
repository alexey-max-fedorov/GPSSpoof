import Foundation

/// UI-scripts Xcode (Debug > Simulate Location > <slot>) via osascript.
/// Requires macOS Accessibility permission for the terminal app running the
/// helper. Each apply briefly opens the Product and Debug menus on the Mac.
///
/// The Simulate Location submenu is populated lazily: its items do not exist
/// in the accessibility tree until the menu chain is physically opened, so a
/// one-shot nested click ("click menu item X of menu item Y ...") fails with
/// "Can't get menu item". Open the chain step by step instead.
///
/// The session check and the clicks MUST live in one script: as separate
/// osascript invocations, the Escape that closes the Product menu is still
/// animating when the next invocation clicks the Debug menu, the click gets
/// swallowed, and the chain dies with a spurious "Can't get menu item".
/// Verified live on Xcode 26.5.
enum XcodeTrigger {
    /// Session liveness + slot click in one deterministic sequence. Xcode
    /// keeps Debug > Simulate Location enabled and fully populated even after
    /// the debug session ends (so a slot click on a dead session silently
    /// does nothing), but Product > Stop is only enabled while a scheme
    /// action is in flight — opening the menu makes AppKit revalidate it.
    /// Prints "dead" when no session is running, "clicked" after a
    /// successful slot click.
    static func applyScript(slot: String) -> String {
        """
        tell application "System Events"
          tell process "Xcode"
            set frontmost to true
            try
              click menu bar item "Product" of menu bar 1
              delay 0.4
              set stopEnabled to enabled of menu item "Stop" of menu 1 of menu bar item "Product" of menu bar 1
              key code 53
              if stopEnabled is false then return "dead"
              delay 0.4
              click menu bar item "Debug" of menu bar 1
              delay 0.4
              click menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
              delay 0.4
              click menu item "\(slot)" of menu 1 of menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
              return "clicked"
            on error errMsg number errNum
              key code 53
              key code 53
              error errMsg number errNum
            end try
          end tell
        end tell
        """
    }

    /// v1: the original method — blindly click the slot with no session
    /// check and no auto-relaunch. One menu flash fewer and ~1s faster than
    /// v2, but if the debug session has died, Xcode's stale Simulate
    /// Location menu accepts the click and silently does nothing.
    static func clickScript(slot: String) -> String {
        """
        tell application "System Events"
          tell process "Xcode"
            set frontmost to true
            try
              click menu bar item "Debug" of menu bar 1
              delay 0.4
              click menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
              delay 0.4
              click menu item "\(slot)" of menu 1 of menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
            on error errMsg number errNum
              key code 53
              key code 53
              error errMsg number errNum
            end try
          end tell
        end tell
        """
    }

    static let probeScript = """
        tell application "System Events"
          tell process "Xcode"
            set frontmost to true
            try
              click menu bar item "Debug" of menu bar 1
              delay 0.4
              click menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
              delay 0.4
              set itemNames to name of every menu item of menu 1 of menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
              key code 53
              key code 53
              return itemNames
            on error errMsg number errNum
              key code 53
              key code 53
              error errMsg number errNum
            end try
          end tell
        end tell
        """

    /// Start a fresh Run of the active scheme on the active run destination.
    /// Unlike the System Events menu clicks, this sends Apple events to Xcode
    /// itself, which needs Automation permission on top of Accessibility.
    static let relaunchScript = """
        tell application "Xcode"
          if (count of workspace documents) is 0 then error "no Xcode workspace is open"
          run active workspace document
        end tell
        """

    static func runOsascript(_ script: String)
        -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return (127, "", "failed to launch osascript: \(error.localizedDescription)")
        }
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: stdoutData, encoding: .utf8) ?? "",
                String(data: stderrData, encoding: .utf8) ?? "")
    }

    /// macOS wording varies by version: "not allowed assistive access",
    /// "Not authorized to send Apple events to ...", ...
    private static func permissionDenied(_ lowered: String) -> Bool {
        lowered.contains("assistive access") || lowered.contains("not authorized")
            || lowered.contains("not allowed")
    }

    private static let permissionMessage =
        "macOS blocked controlling Xcode. Grant the terminal app running this "
        + "helper BOTH permissions, then tap Apply again: System Settings > "
        + "Privacy & Security > Accessibility, and Privacy & Security > "
        + "Automation > (your terminal) > Xcode."

    enum MenuApplyResult {
        case clicked                                  // session alive, slot selected
        case sessionDead                              // Product > Stop disabled
        case failed(status: Int, message: String)     // mapped API error
    }

    /// Check the debug session and click Debug > Simulate Location > <slot>
    /// in Xcode, as a single deterministic UI-scripting sequence.
    static func applySimulateLocation(slot: String) -> MenuApplyResult {
        let result = runOsascript(applyScript(slot: slot))
        if result.status == 0 {
            let answer = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return answer == "dead" ? .sessionDead : .clicked
        }
        let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = error.lowercased()
        if permissionDenied(lowered) {
            return .failed(status: 403, message: permissionMessage)
        }
        if lowered.contains("menu item") {
            return .failed(status: 409, message:
                "Xcode has no 'Simulate Location > \(slot)' menu item. Is the "
                + "debug session running? On the Mac, run "
                + "'./spoof.sh helper --probe-menu' to see what Xcode actually lists.")
        }
        return .failed(status: 502, message: "osascript failed: \(error)")
    }

    /// v1 click. Returns nil on success, or (httpStatus, message) mapping
    /// the osascript failure onto the helper's API error contract.
    static func clickSimulateLocation(slot: String) -> (status: Int, message: String)? {
        let result = runOsascript(clickScript(slot: slot))
        if result.status == 0 { return nil }
        let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = error.lowercased()
        if permissionDenied(lowered) {
            return (403, permissionMessage)
        }
        if lowered.contains("menu item") {
            return (409, "Xcode has no 'Simulate Location > \(slot)' menu item. Is the "
                + "debug session running? On the Mac, run "
                + "'./spoof.sh helper --probe-menu' to see what Xcode actually lists.")
        }
        return (502, "osascript failed: \(error)")
    }

    /// Restart the debug Run session. Returns nil on success; the run command
    /// returns as soon as the action is queued, it does not wait for the build.
    static func relaunchDebugSession() -> (status: Int, message: String)? {
        let result = runOsascript(relaunchScript)
        if result.status == 0 { return nil }
        let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = error.lowercased()
        if permissionDenied(lowered) {
            return (403, permissionMessage)
        }
        if lowered.contains("no xcode workspace") {
            return (409, "Xcode has no project open. Open GPSSpoof.xcodeproj on "
                + "the Mac and press Cmd-R once.")
        }
        return (502, "could not restart the Xcode session: \(error)")
    }
}
