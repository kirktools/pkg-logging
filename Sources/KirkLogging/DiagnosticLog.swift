import CocoaLumberjack
import Darwin
import Foundation

public enum DiagnosticLevel: String, Codable, Sendable {
    case debug, info, warning, error
}

public enum DiagnosticChannel: String, Codable, Sendable {
    case release, dev
}

/// 可持久化字段的清单。事件和错误分类使用源码中的常量，关联编号使用随机 UUID。
public struct DiagnosticRecord: Codable, Sendable {
    public let schema: Int
    public let timestamp: Date
    public let app: String
    public let channel: DiagnosticChannel
    public let role: String
    public let version: String
    public let build: String
    public let runID: UUID
    public let operationID: UUID?
    public let level: DiagnosticLevel
    public let module: String
    public let event: String
    public let errorCode: String?
    public let elapsedMS: Double?
}

public struct DiagnosticFilter: Sendable {
    public var since: Date?
    public var module: StaticString?
    public var levels: Set<DiagnosticLevel>

    public init(since: Date? = nil, module: StaticString? = nil, levels: Set<DiagnosticLevel> = []) {
        self.since = since
        self.module = module
        self.levels = levels
    }

    fileprivate func includes(_ record: DiagnosticRecord) -> Bool {
        if let since, record.timestamp < since { return false }
        if let module, record.module != module.description { return false }
        return levels.isEmpty || levels.contains(record.level)
    }
}

/// 每个 App 通道中的每种进程角色持有一个实例。宿主与插件可传递同一个操作 UUID。
public final class DiagnosticLog: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let app: StaticString
        public let channel: DiagnosticChannel
        public let role: StaticString
        public let version: String
        public let build: String
        public let maxFileBytes: UInt64
        public let archivedFiles: UInt
        public let rollingInterval: TimeInterval

        public init(app: StaticString, channel: DiagnosticChannel, role: StaticString,
                    version: String, build: String, maxFileBytes: UInt64 = 1_048_576,
                    archivedFiles: UInt = 3, rollingInterval: TimeInterval = 86_400) {
            self.app = app
            self.channel = channel
            self.role = role
            self.version = version
            self.build = build
            self.maxFileBytes = maxFileBytes
            self.archivedFiles = archivedFiles
            self.rollingInterval = rollingInterval
        }
    }

    public enum SetupError: Error {
        case invalidConfiguration, unsafeDirectory, writerAlreadyRunning, lockUnavailable
    }

    public let directory: URL
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "kirktools.diagnostics", qos: .utility)
    private let pending = DispatchSemaphore(value: 256)
    private let state = NSLock()
    private var active: Bool
    private var dropped = 0
    private let backend = DDLog()
    private let fileLogger: DDFileLogger
    private let fileManager: DDLogFileManagerDefault
    private let lockFile: Int32
    private let runID = UUID()

    public init(configuration: Configuration, enabled: Bool, baseDirectory: URL? = nil) throws {
        guard Self.isIdentifier(configuration.app.description), Self.isIdentifier(configuration.role.description),
              Self.isIdentifier(configuration.version), Self.isIdentifier(configuration.build),
              configuration.maxFileBytes > 0, configuration.archivedFiles > 0,
              configuration.rollingInterval.isFinite, configuration.rollingInterval > 0 else {
            throw SetupError.invalidConfiguration
        }
        let root = baseDirectory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        var path = root
        for name in [configuration.app.description, configuration.channel.rawValue, configuration.role.description] {
            path.appendPathComponent(name, isDirectory: true)
            try Self.preparePrivateDirectory(path)
        }
        let descriptor = open(path.appendingPathComponent(".writer.lock").path,
                              O_CREAT | O_NOFOLLOW | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SetupError.lockUnavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SetupError.writerAlreadyRunning
        }
        self.configuration = configuration
        directory = path
        active = enabled
        lockFile = descriptor
        fileManager = DDLogFileManagerDefault(logsDirectory: path.path)
        fileManager.maximumNumberOfLogFiles = configuration.archivedFiles
        fileManager.logFilesDiskQuota = 0 // 由单文件大小和保留数量共同限制。
        fileLogger = DDFileLogger(logFileManager: fileManager)
        fileLogger.maximumFileSize = configuration.maxFileBytes
        fileLogger.rollingFrequency = configuration.rollingInterval
        fileLogger.doNotReuseLogFiles = true
        fileLogger.logFormatter = nil
        backend.add(fileLogger)
    }

    deinit {
        backend.flushLog()
        backend.remove(fileLogger)
        backend.flushLog()
        close(lockFile)
    }

    public var droppedEvents: Int { state.withLock { dropped } }

    public func setEnabled(_ enabled: Bool) { state.withLock { active = enabled } }

    /// 在开始、关键阶段及结束时分别调用，避免等待整次操作完成才留下记录。
    public func record(_ level: DiagnosticLevel, module: StaticString, event: StaticString,
                       operationID: UUID? = nil, errorCode: StaticString? = nil, elapsedMS: Double? = nil) {
        guard state.withLock({ active }) else { return }
        guard Self.isIdentifier(module.description), Self.isIdentifier(event.description),
              errorCode.map({ Self.isIdentifier($0.description) }) ?? true,
              elapsedMS.map({ $0.isFinite && $0 >= 0 }) ?? true,
              pending.wait(timeout: .now()) == .success else {
            state.withLock { dropped += 1 }
            return
        }
        let entry = DiagnosticRecord(schema: 1, timestamp: .now, app: configuration.app.description,
                                     channel: configuration.channel, role: configuration.role.description,
                                     version: configuration.version, build: configuration.build, runID: runID,
                                     operationID: operationID, level: level, module: module.description,
                                     event: event.description, errorCode: errorCode?.description, elapsedMS: elapsedMS)
        queue.async { [self] in
            defer { pending.signal() }
            guard let data = try? Self.encoder().encode(entry), let line = String(data: data, encoding: .utf8) else {
                state.withLock { dropped += 1 }
                return
            }
            let message = DDLogMessage(format: "%@", formatted: line, level: .all, flag: .info,
                                       context: 0, file: "", function: nil, line: 0, tag: nil,
                                       options: [], timestamp: entry.timestamp)
            backend.log(asynchronous: false, message: message)
        }
    }

    /// 导出当前通道中指定角色的允许字段。传入插件角色可按操作编号与宿主记录一起排查。
    public func export(to destination: URL, matching filter: DiagnosticFilter = .init(),
                       including roles: [StaticString] = []) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result {
                    backend.flushLog()
                    return try writeReport(to: destination, matching: filter, including: roles)
                })
            }
        }
    }

    /// 清除本实例拥有的角色日志。其他进程通过各自的实例清除。
    public func clear() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                continuation.resume(with: Result {
                    backend.flushLog()
                    backend.remove(fileLogger)
                    backend.flushLog()
                    defer { backend.add(fileLogger) }
                    for path in fileManager.unsortedLogFilePaths {
                        try FileManager.default.removeItem(atPath: path)
                    }
                })
            }
        }
    }

    private func writeReport(to destination: URL, matching filter: DiagnosticFilter,
                             including roles: [StaticString]) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var entries: [DiagnosticRecord] = []
        for role in Set(roles.map(\.description) + [configuration.role.description]) {
            guard Self.isIdentifier(role) else { throw SetupError.invalidConfiguration }
            let folder = directory.deletingLastPathComponent().appendingPathComponent(role, isDirectory: true)
            guard let folderValues = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  folderValues.isDirectory == true, folderValues.isSymbolicLink != true else { continue }
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
            for file in files where file.pathExtension == "log" {
                guard let values = try? file.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size <= 16 * 1_048_576,
                      let contents = try? Data(contentsOf: file) else { continue }
                for line in contents.split(separator: 10) {
                    guard let record = try? decoder.decode(DiagnosticRecord.self, from: Data(line)),
                          record.schema == 1, record.app == configuration.app.description,
                          record.channel == configuration.channel, record.role == role,
                          Self.isSafe(record), filter.includes(record) else { continue }
                    entries.append(record)
                }
            }
        }
        let encoder = Self.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries.sorted { $0.timestamp < $1.timestamp }).write(to: destination, options: .atomic)
        return entries.count
    }

    private static func preparePrivateDirectory(_ url: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw SetupError.unsafeDirectory
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func isSafe(_ record: DiagnosticRecord) -> Bool {
        [record.version, record.build, record.module, record.event].allSatisfy(isIdentifier)
            && (record.errorCode.map(isIdentifier) ?? true)
    }

    private static func isIdentifier(_ value: String) -> Bool {
        (1...96).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        } && value != "." && value != ".."
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}
