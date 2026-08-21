import Foundation

struct MachineSnapshot: Codable, Sendable {
    let schemaVersion: Int
    let scannedAt: Date
    let system: SystemSnapshot
    let path: [String]
    let runtimes: [RuntimeSnapshot]
    let homebrew: HomebrewSnapshot
    let issues: [String]
}

struct SystemSnapshot: Codable, Sendable {
    let macOSVersion: String?
    let build: String?
    let architecture: String?
    let hostName: String
    let memoryBytes: UInt64?
    let diskTotalBytes: UInt64?
    let diskFreeBytes: UInt64?
}

enum RuntimeState: String, Codable, Sendable {
    case discovered
    case unavailable
    case failed
}

struct RuntimeInstallation: Codable, Identifiable, Sendable {
    let id: String
    let executable: String
    let actualExecutable: String?
    let version: String?
    let state: RuntimeState
    let error: String?
    let isEffective: Bool
}

struct RuntimeSnapshot: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let installations: [RuntimeInstallation]

    var state: RuntimeState {
        if installations.isEmpty { return .unavailable }
        return installations.contains { $0.state == .discovered } ? .discovered : .failed
    }

    var hasPathVersionConflict: Bool {
        Set(installations.compactMap(\.version)).count > 1
    }
}

struct HomebrewSnapshot: Codable, Sendable {
    let executable: String?
    let version: String?
    let available: Bool
    let error: String?
}

struct ScanResult: Sendable {
    let snapshot: MachineSnapshot
    let canPersist: Bool
}

struct MachineCommandResult: Sendable {
    let output: String
    let status: Int32
    let timedOut: Bool
}

struct DiskSpace: Sendable {
    let totalBytes: UInt64?
    let freeBytes: UInt64?
}

protocol MachineAccess: Sendable {
    var environment: [String: String] { get }
    var hostName: String { get }
    var currentDirectoryPath: String { get }
    func diskSpace() -> DiskSpace
    func isExecutableFile(atPath path: String) -> Bool
    func resolvingSymlinksInPath(_ path: String) -> String
    func command(executable: String, arguments: [String]) -> MachineCommandResult
}

struct LiveMachineAccess: MachineAccess {
    var environment: [String: String] { ProcessInfo.processInfo.environment }
    var hostName: String { ProcessInfo.processInfo.hostName }
    var currentDirectoryPath: String { FileManager.default.currentDirectoryPath }

    func diskSpace() -> DiskSpace {
        let attributes = (try? FileManager.default.attributesOfFileSystem(forPath: "/")) ?? [:]
        return DiskSpace(
            totalBytes: attributes[.systemSize] as? UInt64,
            freeBytes: attributes[.systemFreeSize] as? UInt64
        )
    }

    func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func resolvingSymlinksInPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func command(executable: String, arguments: [String]) -> MachineCommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return MachineCommandResult(output: "", status: -1, timedOut: false)
        }
        let timedOut = finished.wait(timeout: .now() + 2) == .timedOut
        if timedOut {
            process.terminate()
            process.waitUntilExit()
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return MachineCommandResult(output: output, status: process.terminationStatus, timedOut: timedOut)
    }
}

struct EnvironmentScanner: Sendable {
    private struct RuntimeDefinition: Sendable {
        let id: String
        let name: String
        let executable: String
        let arguments: [String]
    }

    private let runtimeDefinitions = [
        RuntimeDefinition(id: "node", name: "Node.js", executable: "node", arguments: ["--version"]),
        RuntimeDefinition(id: "python", name: "Python", executable: "python3", arguments: ["--version"]),
        RuntimeDefinition(id: "go", name: "Go", executable: "go", arguments: ["version"]),
        RuntimeDefinition(id: "java", name: "Java", executable: "java", arguments: ["-version"]),
        RuntimeDefinition(id: "rust", name: "Rust", executable: "rustc", arguments: ["--version"]),
        RuntimeDefinition(id: "ruby", name: "Ruby", executable: "ruby", arguments: ["--version"]),
        RuntimeDefinition(id: "lua", name: "Lua", executable: "lua", arguments: ["-v"]),
    ]

    private let machine: any MachineAccess

    init(machine: any MachineAccess = LiveMachineAccess()) {
        self.machine = machine
    }

    func scan() -> ScanResult {
        let path = pathEntries()
        var issues: [String] = []

        let version = machine.command(executable: "/usr/bin/sw_vers", arguments: ["-productVersion"])
        let build = machine.command(executable: "/usr/bin/sw_vers", arguments: ["-buildVersion"])
        let architecture = machine.command(executable: "/usr/bin/uname", arguments: ["-m"])
        let memory = machine.command(executable: "/usr/sbin/sysctl", arguments: ["-n", "hw.memsize"])
        let disk = machine.diskSpace()

        let memoryValue = value(from: memory, issue: "内存信息", issues: &issues).flatMap(UInt64.init)
        let system = SystemSnapshot(
            macOSVersion: value(from: version, issue: "macOS 版本", issues: &issues),
            build: value(from: build, issue: "macOS Build", issues: &issues),
            architecture: value(from: architecture, issue: "芯片架构", issues: &issues),
            hostName: machine.hostName,
            memoryBytes: memoryValue,
            diskTotalBytes: disk.totalBytes,
            diskFreeBytes: disk.freeBytes
        )

        let runtimes = runtimeDefinitions.map { scanRuntime($0, path: path, issues: &issues) }
        let homebrew = scanHomebrew(issues: &issues)
        let snapshot = MachineSnapshot(
            schemaVersion: 2,
            scannedAt: Date(),
            system: system,
            path: path,
            runtimes: runtimes,
            homebrew: homebrew,
            issues: issues
        )
        return ScanResult(
            snapshot: snapshot,
            canPersist: system.macOSVersion != nil && system.architecture != nil
        )
    }

    private func scanRuntime(
        _ definition: RuntimeDefinition,
        path: [String],
        issues: inout [String]
    ) -> RuntimeSnapshot {
        var seenTargets: Set<String> = []
        var installations: [RuntimeInstallation] = []

        for directory in path {
            let executable = absoluteExecutable(definition.executable, directory: directory)
            guard machine.isExecutableFile(atPath: executable) else { continue }
            let actual = standardizedPath(machine.resolvingSymlinksInPath(executable))
            guard seenTargets.insert(actual).inserted else { continue }

            let result = machine.command(executable: executable, arguments: definition.arguments)
            let version = result.status == 0 ? normalizedVersion(result.output) : nil
            let error = version == nil ? "版本读取失败" : nil
            if let error {
                issues.append("\(definition.name)：\(error)（\(executable)）")
            }
            installations.append(RuntimeInstallation(
                id: actual,
                executable: executable,
                actualExecutable: actual == executable ? nil : actual,
                version: version,
                state: version == nil ? .failed : .discovered,
                error: error,
                isEffective: installations.isEmpty
            ))
        }

        return RuntimeSnapshot(id: definition.id, name: definition.name, installations: installations)
    }

    private func scanHomebrew(issues: inout [String]) -> HomebrewSnapshot {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let executable = candidates.first(where: { machine.isExecutableFile(atPath: $0) }) else {
            return HomebrewSnapshot(executable: nil, version: nil, available: false, error: nil)
        }
        let result = machine.command(executable: executable, arguments: ["--version"])
        guard let version = normalizedVersion(result.output), result.status == 0 || !version.isEmpty else {
            let error = result.timedOut ? "命令超时" : "版本读取失败"
            issues.append("Homebrew：\(error)")
            return HomebrewSnapshot(executable: executable, version: nil, available: false, error: error)
        }
        return HomebrewSnapshot(executable: executable, version: version, available: true, error: nil)
    }

    private func pathEntries() -> [String] {
        guard let value = machine.environment["PATH"] else { return [] }
        return value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    }

    private func absoluteExecutable(_ name: String, directory: String) -> String {
        let base = URL(fileURLWithPath: machine.currentDirectoryPath, isDirectory: true)
        let directoryURL = URL(fileURLWithPath: directory, relativeTo: base).standardizedFileURL
        return standardizedPath(directoryURL.appendingPathComponent(name).path)
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func value(from result: MachineCommandResult, issue: String, issues: inout [String]) -> String? {
        guard result.status == 0, let value = normalizedVersion(result.output) else {
            issues.append("\(issue)：读取失败")
            return nil
        }
        return value
    }

    private func normalizedVersion(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("Python ") { return String(value.dropFirst(7)) }
        if value.hasPrefix("Homebrew ") { return String(value.dropFirst(9)) }
        if value.hasPrefix("go version ") {
            return value.split(separator: " ").dropFirst(2).first.map { String($0).dropFirst(2).description }
        }
        if value.hasPrefix("rustc ") { return value.split(separator: " ").dropFirst().first.map(String.init) }
        if value.hasPrefix("ruby ") { return value.split(separator: " ").dropFirst().first.map(String.init) }
        if value.hasPrefix("Lua ") { return value.split(separator: " ").dropFirst().first.map(String.init) }
        if let firstQuote = value.firstIndex(of: "\""),
           let endQuote = value[value.index(after: firstQuote)...].firstIndex(of: "\"") {
            return String(value[value.index(after: firstQuote)..<endQuote])
        }
        if value.first == "v", value.dropFirst().first?.isNumber == true { return String(value.dropFirst()) }
        return value
    }
}

struct SnapshotStore: Sendable {
    private struct Header: Decodable { let schemaVersion: Int }

    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevEnv", isDirectory: true)
        fileURL = directory.appendingPathComponent("machine-snapshot.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> MachineSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard (try? decoder.decode(Header.self, from: data).schemaVersion) == 2 else { return nil }
        return try? decoder.decode(MachineSnapshot.self, from: data)
    }

    func save(_ snapshot: MachineSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}
