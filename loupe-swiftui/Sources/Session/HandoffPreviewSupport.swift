#if DEBUG
import Foundation

// MARK: - Preview / launch-arg support
// Boots straight into a finished session with a rich handoff so the bento dock
// can be exercised in the simulator via the `-LoupePreviewHandoff` launch argument.
extension Pairing {
    static let preview = Pairing(host: URL(string: "http://127.0.0.1:4173")!, token: "preview")
}

extension SessionStore {
    static var previewHandoff: SessionStore {
        let snapshot = try! JSONDecoder().decode(SessionSnapshot.self, from: Data(previewHandoffJSON.utf8))
        return SessionStore(snapshot: snapshot, pairing: .preview)
    }
}

private let previewHandoffJSON = """
{
  "id": "preview-handoff",
  "harnessId": "claude-code",
  "message": "Review product updates: collapse low-signal rows in the session screen",
  "status": "completed",
  "events": [
    { "id": 1, "type": "claude", "kind": "message", "text": "Spinning up a branch and tracing how transcript rows render." },
    { "id": 2, "type": "claude", "kind": "tool_use", "toolName": "Grep", "text": "Grep: addEvent in daemon.js" },
    { "id": 3, "type": "claude", "kind": "tool_use", "toolName": "Read", "text": "Read: daemon.js" },
    { "id": 4, "type": "claude", "kind": "message", "text": "Found the shell + edit event labels. Collapsing raw commands under \\"Ran a command\\" and \\"Edited files\\"." },
    { "id": 5, "type": "claude", "kind": "file_change", "path": "daemon.js", "changeKind": "edit", "status": "modified", "additions": 107, "deletions": 2, "patch": "@@ -2772,7 +2772,9 @@\\n-      const path = item.path || \\"\\";\\n-      addEvent(session, { type: \\"action\\", tool: \\"edit\\", text: path });\\n+      const changes = normalizeCodexFileChanges(item);\\n+      if (changes.length) {\\n+        for (const change of changes) {" },
    { "id": 6, "type": "claude", "kind": "file_change", "path": "loupe-swiftui/Sources/Session/SessionView.swift", "changeKind": "edit", "status": "modified", "additions": 64, "deletions": 120, "patch": "@@ SessionView @@\\n-HandoffCard(event:)\\n+HandoffDock(summary:)" },
    { "id": 7, "type": "claude", "kind": "file_change", "path": "loupe-swiftui/Sources/Session/HandoffDock.swift", "changeKind": "write", "status": "added", "additions": 240, "deletions": 0, "patch": "@@ new file @@\\n+struct HandoffDock: View { ... }" },
    { "id": 8, "type": "claude", "kind": "tool_use", "toolName": "Bash", "text": "xcodebuild -scheme LoupeSwiftUI build" },
    { "id": 9, "type": "branch", "kind": "created", "branch": "loupe/patchit-24-5607qn", "base": "main", "repo": "sixi3/loupe" },
    { "id": 10, "type": "branch", "kind": "committed", "branch": "loupe/patchit-24-5607qn" },
    { "id": 11, "type": "branch", "kind": "pr_ready", "repo": "sixi3/loupe", "prNumber": 24, "prUrl": "https://github.com/sixi3/loupe/pull/24" },
    { "id": 12, "type": "handoff", "kind": "ready", "handoff": {
        "tldr": "Reshaped the session screen so low-signal rows collapse and the handoff lives in a sticky bento dock.",
        "what_changed": [
          "Collapsed raw shell + edit rows under \\"Ran a command\\" / \\"Edited files\\" labels.",
          "Added a sticky HandoffDock of bento pills at the bottom of the session.",
          "Each pill opens a bottom drawer with the full detail.",
          "Retired the inline handoff card in favour of the dock."
        ],
        "files_changed": ["daemon.js", "loupe-swiftui/Sources/Session/SessionView.swift", "loupe-swiftui/Sources/Session/HandoffDock.swift"],
        "tests_run": ["xcodebuild succeeded", "node --check daemon.js passed"],
        "tests_not_run": ["No UI snapshot tests yet for the dock."],
        "assumptions": ["Sticky dock should only appear once the run completes."],
        "risks": ["Drawer detents may feel tall on small devices."],
        "confidence": 0.88
      }
    },
    { "id": 13, "type": "done", "status": "completed" }
  ],
  "nextEventId": 14,
  "startedAt": "2026-06-03T10:00:00Z",
  "exitCode": 0,
  "dispatch": {
    "ticket": {
      "repo": "sixi3/loupe",
      "number": 24,
      "title": "Review product updates",
      "url": "https://github.com/sixi3/loupe/issues/24",
      "kind": "issue"
    },
    "mode": "branch"
  },
  "branch": { "name": "loupe/patchit-24-5607qn", "base": "main", "repo": "sixi3/loupe" }
}
"""
#endif
