import Foundation
import WorkholicCore

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

/// One-time orders for this Mac, such as a shutdown asked for on the web, and the account's day plan.
struct CommandsResponse: Decodable {
    var commands: [DeviceCommand]
    /// The plan's version. Nil from a server before plans.
    var dayPlanUpdatedAtMs: Int64?
    /// Sent only when the version differs from the one asked with. `.some(nil)` when it was sent but
    /// does not read: a bad plan must not stop the orders from being read, and counts as no plan.
    var dayPlan: AccountPlan??
    /// What `/v1/settings` would say, so one request does both. Nil from a server before this field.
    var settings: CheckedSettings?

    enum CodingKeys: String, CodingKey {
        case commands
        case dayPlanUpdatedAtMs = "day_plan_updated_at_ms"
        case dayPlan = "day_plan"
        case settings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        commands = try values.decode([DeviceCommand].self, forKey: .commands)
        dayPlanUpdatedAtMs = try? values.decodeIfPresent(Int64.self, forKey: .dayPlanUpdatedAtMs)
        if values.contains(.dayPlan) {
            dayPlan = .some(try? values.decode(AccountPlan.self, forKey: .dayPlan))
        }
        settings = try? values.decodeIfPresent(CheckedSettings.self, forKey: .settings)
    }
}

struct CheckedSettings: Decodable {
    var idleThresholdMs: Int64
    /// The limit in force now. Nil when none is set.
    var limitMs: Int64?
    var breaksUpdatedAtMs: Int64
    enum CodingKeys: String, CodingKey {
        case idleThresholdMs = "idle_threshold_ms"
        case limitMs = "limit_ms"
        case breaksUpdatedAtMs = "breaks_updated_at_ms"
    }
}

struct DeviceCommand: Decodable {
    var commandId: String
    var kind: String
    enum CodingKeys: String, CodingKey {
        case commandId = "command_id"
        case kind
    }
}

/// `go` is true only for the first "delivered" of an order nobody cancelled.
struct CommandAck: Decodable {
    var go: Bool
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
    /// A non-2xx answer from the server, with its body or "HTTP <status>".
    case http(status: Int, text: String)
    var description: String {
        switch self { case .http(_, let text): return text }
    }

    /// True only when the server itself said the token is no good. Network errors never are:
    /// their text carries random task ids that can contain "401" by chance.
    static func isSignedOut(_ error: Error) -> Bool {
        if case .http(let status, _)? = error as? ApiError { return status == 401 }
        return false
    }
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

    /// `planAt` is the plan version this Mac has; the plan comes back only when it changed.
    func commands(deviceToken: String, deviceId: String, planAt: Int64?) async throws -> CommandsResponse {
        var url = baseURL.appending(path: "/v1/devices/\(deviceId)/commands")
        if let planAt { url.append(queryItems: [URLQueryItem(name: "plan_at", value: String(planAt))]) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        return try await decode(request)
    }

    /// "delivered" before acting; "failed:<reason>" after, if acting failed.
    func ackCommand(deviceToken: String, deviceId: String, commandId: String, result: String) async throws -> CommandAck {
        try await send(
            path: "/v1/devices/\(deviceId)/commands/\(commandId):ack",
            method: "POST",
            token: deviceToken,
            body: ["result": result]
        )
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
            throw ApiError.http(status: status, text: text.isEmpty ? "HTTP \(status)" : text)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
