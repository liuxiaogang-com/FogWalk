import Foundation
import SQLite3

struct RecordingStorageError: LocalizedError {
    let message: String
    var errorDescription: String? { "足迹保存失败：\(message)" }
}

/// Independent append-only journal. Standard location callbacks never rewrite the full library.
actor RecordingStore {
    private final class Handle: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { sqlite3_close(pointer) }
    }
    private let directory: URL
    private var handle: Handle?
    private var journalID = ""

    init(baseDirectory: URL? = nil) {
        directory = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FogWalk/Recording", isDirectory: true)
    }

    private func connection() throws -> OpaquePointer {
        if let handle { return handle.pointer }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var pointer: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("recordings.sqlite").path, &pointer) == SQLITE_OK,
              let pointer else { throw RecordingStorageError(message: "无法打开本地记录库") }
        let opened = Handle(pointer)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=3000;", db: pointer)
        try execute("CREATE TABLE IF NOT EXISTS metadata (id TEXT NOT NULL); CREATE TABLE IF NOT EXISTS points (id INTEGER PRIMARY KEY AUTOINCREMENT, time REAL NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, accuracy REAL NOT NULL, speed REAL NOT NULL, altitude REAL NOT NULL, mode TEXT NOT NULL, context TEXT NOT NULL, UNIQUE(time,lat,lon));", db: pointer)
        let statement = try prepare("SELECT id FROM metadata LIMIT 1", db: pointer)
        if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
            journalID = String(cString: text)
        }
        sqlite3_finalize(statement)
        if journalID.isEmpty {
            journalID = UUID().uuidString
            try execute("INSERT INTO metadata(id) VALUES ('\(journalID)')", db: pointer)
        }
        handle = opened
        return pointer
    }

    private func execute(_ sql: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw RecordingStorageError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RecordingStorageError(message: String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    func append(_ points: [TrackPoint], mode: RecordingMode, context: String) throws -> Int {
        guard !points.isEmpty else { return 0 }
        let db = try connection()
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            let statement = try prepare("INSERT OR IGNORE INTO points(time,lat,lon,accuracy,speed,altitude,mode,context) VALUES (?,?,?,?,?,?,?,?)", db: db)
            defer { sqlite3_finalize(statement) }
            var inserted = 0
            for point in points {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                for (index, value) in [point.timestamp.timeIntervalSince1970, point.coordinate.latitude,
                                       point.coordinate.longitude, point.horizontalAccuracy, point.speed, point.altitude].enumerated() {
                    sqlite3_bind_double(statement, Int32(index + 1), value)
                }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                _ = mode.rawValue.withCString { sqlite3_bind_text(statement, 7, $0, -1, transient) }
                _ = context.withCString { sqlite3_bind_text(statement, 8, $0, -1, transient) }
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw RecordingStorageError(message: String(cString: sqlite3_errmsg(db)))
                }
                inserted += Int(sqlite3_changes(db))
            }
            try execute("COMMIT", db: db)
            return inserted
        } catch {
            try? execute("ROLLBACK", db: db)
            throw error
        }
    }

    func read(after checkpoint: RecordingCheckpoint? = nil) throws -> RecordedBatch {
        let db = try connection()
        let afterID = checkpoint?.journalID == journalID ? checkpoint!.rowID : 0
        let statement = try prepare("SELECT id,time,lat,lon,accuracy,speed,altitude FROM points WHERE id > ? ORDER BY time,id", db: db)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, afterID)
        var points = [TrackPoint]()
        var maximum = afterID
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            maximum = max(maximum, id)
            points.append(TrackPoint(id: id, timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                coordinate: GeoCoordinate(latitude: sqlite3_column_double(statement, 2), longitude: sqlite3_column_double(statement, 3)),
                horizontalAccuracy: sqlite3_column_double(statement, 4), speed: sqlite3_column_double(statement, 5),
                altitude: sqlite3_column_double(statement, 6), source: .recordedDevice))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw RecordingStorageError(message: String(cString: sqlite3_errmsg(db))) }
        return RecordedBatch(checkpoint: RecordingCheckpoint(journalID: journalID, rowID: maximum), points: points)
    }
}
