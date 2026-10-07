import Foundation
import SQLite3
import WorkholicCore

struct StoredInterval: Sendable, Equatable {
    var intervalId: String
    var startWallMs: Int64
    var endWallMs: Int64
    var durationMs: Int64
    var appKey: String
    var displayName: String
    var marksJson: String
    var bootId: String
}

@MainActor
final class LocalStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private(set) var open: OpenSlice?
    private var openId: String?
    private var openMarks: [Mark] = []
    private var bootId: String = ""

    struct Mark: Codable, Equatable {
        var at_ms: Int64
        var input_ms: Int64
    }

    init() throws {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("tech.joeljacob.workholic", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("capture.db").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw StoreError.message("Could not open the local database")
        }
        try exec(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS local_interval (
              interval_id TEXT PRIMARY KEY,
              start_wall_ms INTEGER NOT NULL,
              end_wall_ms INTEGER NOT NULL,
              duration_ms INTEGER NOT NULL,
              app_key TEXT NOT NULL,
              app_display_name TEXT,
              source TEXT NOT NULL,
              attendance TEXT NOT NULL,
              input_marks_json TEXT NOT NULL,
              boot_id TEXT,
              sealed INTEGER NOT NULL,
              uploaded INTEGER NOT NULL DEFAULT 0,
              upload_eligible INTEGER NOT NULL DEFAULT 1
            );
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """
        )
    }

    func closeOpenAtLaunch() {
        guard let id = singleText("SELECT interval_id FROM local_interval WHERE sealed = 0 LIMIT 1") else { return }
        let duration = singleInt("SELECT duration_ms FROM local_interval WHERE interval_id = ?", text: id) ?? 0
        if duration <= 0 {
            run("DELETE FROM local_interval WHERE interval_id = ?", [.text(id)])
        } else {
            run("UPDATE local_interval SET sealed = 1 WHERE interval_id = ?", [.text(id)])
        }
        clearOpen()
    }

    func setBootId(_ bootId: String) {
        self.bootId = bootId
    }

    func apply(step: CaptureStep, displayName: String, idleMs: Int64) {
        switch step {
        case .hold:
            break
        case .start(let appKey, let wallMs, let uptimeMs):
            start(appKey: appKey, displayName: displayName, wallMs: wallMs, uptimeMs: uptimeMs)
        case .extend(let addMs):
            extend(addMs: addMs, idleMs: idleMs)
        case .seal:
            seal()
        case .sealAndStart(let appKey, let wallMs, let uptimeMs):
            seal()
            start(appKey: appKey, displayName: displayName, wallMs: wallMs, uptimeMs: uptimeMs)
        case .fillSeal(let fillMs, let restartWallMs, let restartUptimeMs, let appKey):
            extend(addMs: fillMs, idleMs: idleMs)
            seal()
            start(appKey: appKey, displayName: displayName, wallMs: restartWallMs, uptimeMs: restartUptimeMs)
        }
    }

    func seal() {
        guard let id = openId else { return }
        let duration = open?.durationMs ?? 0
        if duration <= 0 || openMarks.isEmpty {
            run("DELETE FROM local_interval WHERE interval_id = ?", [.text(id)])
        } else {
            run("UPDATE local_interval SET sealed = 1 WHERE interval_id = ?", [.text(id)])
        }
        clearOpen()
    }

    func pending(limit: Int) -> [StoredInterval] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT interval_id, start_wall_ms, end_wall_ms, duration_ms, app_key, app_display_name, input_marks_json, boot_id
        FROM local_interval
        WHERE sealed = 1 AND uploaded = 0 AND upload_eligible = 1 AND duration_ms > 0
        ORDER BY start_wall_ms
        LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var rows: [StoredInterval] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                StoredInterval(
                    intervalId: columnText(statement, 0),
                    startWallMs: sqlite3_column_int64(statement, 1),
                    endWallMs: sqlite3_column_int64(statement, 2),
                    durationMs: sqlite3_column_int64(statement, 3),
                    appKey: columnText(statement, 4),
                    displayName: columnText(statement, 5),
                    marksJson: columnText(statement, 6),
                    bootId: columnText(statement, 7)
                )
            )
        }
        return rows
    }

    func markUploaded(_ ids: [String]) {
        for id in ids {
            run("UPDATE local_interval SET uploaded = 1 WHERE interval_id = ?", [.text(id)])
        }
    }

    func markIneligible(_ ids: [String]) {
        for id in ids {
            run("UPDATE local_interval SET upload_eligible = 0 WHERE interval_id = ?", [.text(id)])
        }
    }

    func attendedMs(dayStart: Int64, dayEnd: Int64) -> Int64 {
        sumClipped(
            """
            SELECT start_wall_ms, end_wall_ms FROM local_interval
            WHERE duration_ms > 0 AND end_wall_ms > ? AND start_wall_ms < ?
            """,
            dayStart: dayStart,
            dayEnd: dayEnd
        )
    }

    private func start(appKey: String, displayName: String, wallMs: Int64, uptimeMs: Int64) {
        if openId != nil { seal() }
        let id = UUID().uuidString.lowercased()
        let name = String(displayName.prefix(100)).unicodeScalars.filter { !$0.properties.isJoinControl && !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        run(
            """
            INSERT INTO local_interval (
              interval_id, start_wall_ms, end_wall_ms, duration_ms, app_key, app_display_name,
              source, attendance, input_marks_json, boot_id, sealed, uploaded, upload_eligible
            ) VALUES (?, ?, ?, 0, ?, ?, 'os-window', 'input', '[]', ?, 0, 0, 1)
            """,
            [.text(id), .int(wallMs), .int(wallMs), .text(appKey), .text(name), .text(bootId)]
        )
        openId = id
        openMarks = []
        open = OpenSlice(appKey: appKey, startWallMs: wallMs, durationMs: 0, uptimeMs: uptimeMs)
    }

    private func extend(addMs: Int64, idleMs: Int64) {
        guard let id = openId, var slice = open, addMs > 0 else { return }
        slice.durationMs += addMs
        slice.uptimeMs += addMs
        let end = slice.endWallMs
        openMarks.append(Mark(at_ms: end, input_ms: end - max(0, idleMs)))
        let marks = (try? String(data: JSONEncoder().encode(openMarks), encoding: .utf8)) ?? "[]"
        run(
            "UPDATE local_interval SET duration_ms = ?, end_wall_ms = ?, input_marks_json = ? WHERE interval_id = ?",
            [.int(slice.durationMs), .int(end), .text(marks), .text(id)]
        )
        open = slice
    }

    private func clearOpen() {
        open = nil
        openId = nil
        openMarks = []
    }

    private func sumClipped(_ sql: String, dayStart: Int64, dayEnd: Int64) -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_int64(statement, 1, dayStart)
        sqlite3_bind_int64(statement, 2, dayEnd)
        var total: Int64 = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            total += clippedMs(
                start: sqlite3_column_int64(statement, 0),
                end: sqlite3_column_int64(statement, 1),
                dayStart: dayStart,
                dayEnd: dayEnd
            )
        }
        return total
    }

    private func singleText(_ sql: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, 0)
    }

    private func singleInt(_ sql: String, text: String) -> Int64? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, text, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite"
            throw StoreError.message(message)
        }
    }

    private func run(_ sql: String, _ binds: [SQLValue]) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        for (index, bind) in binds.enumerated() {
            switch bind {
            case .int(let value):
                sqlite3_bind_int64(statement, Int32(index + 1), value)
            case .text(let value):
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            }
        }
        sqlite3_step(statement)
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: raw)
    }
}

private enum SQLValue {
    case int(Int64)
    case text(String)
}

enum StoreError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let text): return text } }
}
