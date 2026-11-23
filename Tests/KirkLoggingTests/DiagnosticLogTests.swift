import Foundation
import KirkLogging
import XCTest

final class DiagnosticLogTests: XCTestCase {
    func testFilteredReportJoinsRolesAndIsolatesChannels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        func logger(_ channel: DiagnosticChannel, role: StaticString) throws -> DiagnosticLog {
            try DiagnosticLog(configuration: .init(app: "TestApp", channel: channel, role: role,
                                                   version: "1.0", build: "42"), enabled: true, baseDirectory: root)
        }

        let host = try logger(.dev, role: "host")
        let plugin = try logger(.dev, role: "plugin")
        let release = try logger(.release, role: "host")
        XCTAssertThrowsError(try logger(.dev, role: "host"))
        let operation = UUID()
        host.record(.info, module: "translation", event: "started", operationID: operation)
        host.record(.warning, module: "other", event: "ignored")
        plugin.record(.error, module: "translation", event: "failed", operationID: operation,
                      errorCode: "timeout", elapsedMS: 12)
        release.record(.error, module: "translation", event: "release_only")
        host.setEnabled(false)
        host.record(.error, module: "translation", event: "disabled")
        _ = try await plugin.export(to: root.appendingPathComponent("plugin.json"))
        _ = try await release.export(to: root.appendingPathComponent("release.json"))

        let report = root.appendingPathComponent("report.json")
        let count = try await host.export(to: report, matching: .init(module: "translation"), including: ["plugin"])
        XCTAssertEqual(count, 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let entries = try decoder.decode([DiagnosticRecord].self, from: Data(contentsOf: report))
        XCTAssertEqual(Set(entries.map(\.event)), ["started", "failed"])
        XCTAssertEqual(Set(entries.compactMap(\.operationID)), [operation])
        XCTAssertEqual(entries.first { $0.event == "failed" }?.errorCode, "timeout")
        let permissions = try FileManager.default.attributesOfItem(atPath: host.directory.path)
        XCTAssertEqual(permissions[.posixPermissions] as? Int, 0o700)
    }

    func testBackendRotatesAndRetainsRecentEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try DiagnosticLog(configuration: .init(app: "TestApp", channel: .dev, role: "host",
                                                         version: "1.0", build: "1", maxFileBytes: 800,
                                                         archivedFiles: 2), enabled: true, baseDirectory: root)
        for _ in 0..<40 { log.record(.info, module: "capture", event: "progress") }
        log.record(.error, module: "capture", event: "last")
        let report = root.appendingPathComponent("report.json")
        let errors = try await log.export(to: report, matching: .init(levels: [.error]))
        XCTAssertEqual(errors, 1)
        let logs = try FileManager.default.contentsOfDirectory(at: log.directory, includingPropertiesForKeys: nil)
        XCTAssertGreaterThan(logs.filter { $0.pathExtension == "log" }.count, 1)
        XCTAssertLessThanOrEqual(logs.filter { $0.pathExtension == "log" }.count, 3)

        try await log.clear()
        let remaining = try await log.export(to: report)
        XCTAssertEqual(remaining, 0)
        log.record(.info, module: "capture", event: "after_clear")
        let newEvents = try await log.export(to: report)
        XCTAssertEqual(newEvents, 1)
    }
}
