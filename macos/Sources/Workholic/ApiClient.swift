import Foundation

struct LoginResponse: Decodable {
    var sessionToken: String
    var expiresAtMs: Int64
    var username: String
    var timezone: String

    enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
        case expiresAtMs = "expires_at_ms"
        case username
        case timezone
    }
}

struct EnrollResponse: Decodable {
    var deviceToken: String
    enum CodingKeys: String, CodingKey { case deviceToken = "device_token" }
}

struct SettingsResponse: Decodable {
    var username: String
    var timezone: String
    var idleThresholdMs: Int64
    /// The limit in force now. Nil when none is set, or from a server before this field.
    var limitMs: Int64?
    /// When the account's break settings last changed. Nil from a server before this field.
    var breaksUpdatedAtMs: Int64?
    enum CodingKeys: String, CodingKey {
        case username
        case timezone
        case idleThresholdMs = "idle_threshold_ms"
        case limitMs = "limit_ms"
        case breaksUpdatedAtMs = "breaks_updated_at_ms"
    }
}

struct StatsResponse: Decodable {
    var timezone: String
    var days: [StatsDay]
}

struct StatsDay: Decodable {
    var day: String
    var creditedMs: Int64
    var ceilingMs: Int64?
    var over: Bool?
    enum CodingKeys: String, CodingKey {
        case day
        case creditedMs = "credited_ms"
        case ceilingMs = "ceiling_ms"
        case over
    }
}

struct BreakItemPayload: Codable {
    var id: String
    var message: String
    var minutes: Int
    var rest: Bool
}

struct BreakSettingsPayload: Codable {
    var enabled: Bool
    var everyMinutes: Int
    var items: [BreakItemPayload]
    /// Zero until the account has saved break settings once.
    var updatedAtMs: Int64?
    /// The newer kinds. Nil when talking to an account from before them.
    var recurringEnabled: Bool? = nil
    var overtime: OvertimeRule? = nil
    var scheduled: [ScheduledItem]? = nil
    enum CodingKeys: String, CodingKey {
        case enabled
        case everyMinutes = "every_minutes"
        case items
        case updatedAtMs = "updated_at_ms"
        case recurringEnabled = "recurring_enabled"
        case overtime
        case scheduled
    }
}

struct UploadAck: Decodable {
    var accepted: Int?
    var duplicateBatch: Bool?
    var error: String?
    enum CodingKeys: String, CodingKey {
        case accepted
        case duplicateBatch = "duplicate_batch"
        case error
    }
}

enum ApiError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let text): return text } }
}

struct ApiClient {
    var baseURL: URL

    func login(username: String, password: String) async throws -> LoginResponse {
        try await send(path: "/v1/login", method: "POST", token: nil, body: ["username": username, "password": password])
    }

    func enroll(sessionToken: String, deviceId: String, displayName: String) async throws -> EnrollResponse {
        try await send(
            path: "/v1/devices",
            method: "POST",
            token: sessionToken,
            body: [
                "device_id": deviceId,
                "display_name": displayName,
                "platform": "macos",
                "role": "collector",
            ]
        )
    }

    func settings(token: String) async throws -> SettingsResponse {
        try await send(path: "/v1/settings", method: "GET", token: token, body: nil)
    }

    func stats(token: String) async throws -> StatsResponse {
        try await send(path: "/v1/stats", method: "GET", token: token, body: nil)
    }

    func breaks(token: String) async throws -> BreakSettingsPayload {
        try await send(path: "/v1/breaks", method: "GET", token: token, body: nil)
    }

    func saveBreaks(sessionToken: String, settings: BreakSettingsPayload) async throws -> BreakSettingsPayload {
        var request = URLRequest(url: baseURL.appending(path: "/v1/breaks"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(settings)
        return try await decode(request)
    }

    func upload(deviceToken: String, deviceId: String, body: Data) async throws -> UploadAck {
        var request = URLRequest(url: baseURL.appending(path: "/v1/devices/\(deviceId)/intervals:upload"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return try await decode(request)
    }

    private func send<Response: Decodable>(path: String, method: String, token: String?, body: [String: String]?) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await decode(request)
    }

    private func decode<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ApiError.message(text.isEmpty ? "HTTP \(status)" : text)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
