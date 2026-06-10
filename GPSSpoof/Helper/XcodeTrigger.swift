import Foundation

/// UI-scripts Xcode (Debug > Simulate Location > <slot>) via osascript.
/// Requires macOS Accessibility permission for the terminal app running the
/// helper. Each click briefly opens the Debug menu on the Mac's screen.
///
/// The Simulate Location submenu is populated lazily: its items do not exist
/// in the accessibility tree until the menu chain is physically opened, so a
/// one-shot nested click ("click menu item X of menu 1 of menu item Y ...")
/// fails with "Can't get menu item". Open the chain step by step instead.
/// Verified live on Xcode 26.5.
enum XcodeTrigger {
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

    /// Click Debug > Simulate Location > <slot> in Xcode.
    /// Returns nil on success, or (httpStatus, message) mapping the osascript
    /// failure onto the helper's API error contract.
    static func clickSimulateLocation(slot: String) -> (status: Int, message: String)? {
        let result = runOsascript(clickScript(slot: slot))
        if result.status == 0 { return nil }
        let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = error.lowercased()
        // macOS wording varies by version: "not allowed assistive access",
        // "Not authorized to send Apple events to System Events", ...
        if lowered.contains("assistive access") || lowered.contains("not authorized")
            || lowered.contains("not allowed") {
            return (403, "macOS blocked UI scripting. Grant Accessibility permission to "
                + "the terminal app running this helper (System Settings > "
                + "Privacy & Security > Accessibility; if it still fails, also "
                + "check Privacy & Security > Automation), then tap Apply again.")
        }
        if lowered.contains("menu item") {
            return (409, "Xcode has no 'Simulate Location > \(slot)' menu item. Is the "
                + "debug session running? On the Mac, run "
                + "'./spoof.sh helper --probe-menu' to see what Xcode actually lists.")
        }
        return (502, "osascript failed: \(error)")
    }
}
