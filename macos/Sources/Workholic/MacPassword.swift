import Foundation
import OpenDirectory

/// Checks the Mac password of the user logged in, on this Mac, with no system prompt.
///
/// The system prompt is another process's window, and that process is the active app while the
/// prompt is up: the kiosk block stops holding, and Cmd-Tab or the Dock can bring another app's
/// windows, and whatever is in them, over the cover. Asking in the cover's own window keeps
/// Workholic active the whole time, so nothing else can come forward. The price is Touch ID.
enum MacPassword {
    /// This Mac has an account record to check against. A Mac with none does not lock anyone out.
    static func canCheck() -> Bool {
        (try? userRecord()) != nil
    }

    /// Whether `password` is the logged-in user's. Runs off the main thread: directory services can be slow.
    static func check(_ password: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let record = try? userRecord() else { return false }
            return (try? record.verifyPassword(password)) != nil
        }.value
    }

    private static func userRecord() throws -> ODRecord {
        let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
        return try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
    }
}
