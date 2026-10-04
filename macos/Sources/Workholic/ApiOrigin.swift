import Foundation

/// The worker this build talks to. For a local worker use http://127.0.0.1:8787.
enum ApiOrigin {
    static let baseURL = URL(string: "https://workaholic.joeljacob.tech")!
}
