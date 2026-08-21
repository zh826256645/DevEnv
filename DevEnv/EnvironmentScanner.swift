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

struct RuntimeSnapshot: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let executable: String?
    let version: String?
    let state: RuntimeState
    let error: String?
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

struct EnvironmentScanner: Sendable {
    private struct CommandResult {
        let output: String
        let status: Int32
        let timedOut: Bool
    }

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

    func scan() -> ScanResult {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["PATH", default: ""].split(separator: ":").map(String.init)
        var issues: [String] = []

        let version = command(path: ["/usr/bin/sw_vers"], arguments: ["-productVersion"])
        let build = command(path: ["/usr/bin/sw_vers"], arguments: ["-buildVersion"])
        let architecture = command(path: ["/usr/bin/uname"], arguments: ["-m"])
        let memory = command(path: ["/usr/sbin/sysctl"], arguments: ["-n", "hw.memsize"])
        let fileSystem = (try? FileManager.default.attributesOfFileSystem(forPath: "/")) ?? [:]

        let memoryValue = value(from: memory, issue: "内存信息", issues: &issues).flatMap(UInt64.init)
        let system = SystemSnapshot(
            macOSVersion: value(from: version, issue: "macOS 版本", issues: &issues),
            build: value(from: build, issue: "macOS Build", issues: &issues),
            architecture: value(from: architecture, issue: "芯片架构", issues: &issues),
            hostName: ProcessInfo.processInfo.hostName,
            memoryBytes: memoryValue,
            diskTotalBytes: fileSystem[.systemSize] as? UInt64,
            diskFreeBytes: fileSystem[.systemFreeSize] as? UInt64
        )

        let runtimes = runtimeDefinitions.map { definition in
            scanRuntime(definition, path: path, issues: &issues)
        }
        let homebrew = scanHomebrew(issues: &issues)
        let snapshot = MachineSnapshot(
            schemaVersion: 1,
            scannedAt: Date(),
            system: system,
            path: path,
            runtimes: runtimes,
            homebrew: homebrew,
            issues: issues
        )
        let canPersist = system.macOSVersion != nil && system.architecture != nil
        return ScanResult(snapshot: snapshot, canPersist: canPersist)
    }

    private func scanRuntime(_ definition: RuntimeDefinition, path: [String], issues: inout [String]) -> RuntimeSnapshot {
        guard let executable = resolve(definition.executable, in: path) else {
            return RuntimeSnapshot(id: definition.id, name: definition.name, executable: nil, version: nil, state: .unavailable, error: nil)
        }
        let result = command(path: [executable], arguments: definition.arguments)
        guard let output = normalizedVersion(result.output), result.status == 0 || !output.isEmpty else {
            let error = result.timedOut ? "命令超时" : "版本读取失败"
            issues.append("\(definition.name)：\(error)")
            return RuntimeSnapshot(id: definition.id, name: definition.name, executable: executable, version: nil, state: .failed, error: error)
        }
        return RuntimeSnapshot(id: definition.id, name: definition.name, executable: executable, version: output, state: .discovered, error: nil)
    }

    private func scanHomebrew(issues: inout [String]) -> HomebrewSnapshot {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return HomebrewSnapshot(executable: nil, version: nil, available: false, error: nil)
        }
        let result = command(path: [executable], arguments: ["--version"])
        guard let version = normalizedVersion(result.output), result.status == 0 || !version.isEmpty else {
            let error = result.timedOut ? "命令超时" : "版本读取失败"
            issues.append("Homebrew：\(error)")
            return HomebrewSnapshot(executable: executable, version: nil, available: false, error: error)
        }
        return HomebrewSnapshot(executable: executable, version: version, available: true, error: nil)
    }

    private func resolve(_ name: String, in path: [String]) -> String? {
        path.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func value(from result: CommandResult, issue: String, issues: inout [String]) -> String? {
        guard result.status == 0, let value = normalizedVersion(result.output) else {
            issues.append("\(issue)：读取失败")
            return nil
        }
        return value
    }

    private func normalizedVersion(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).map(String.init).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("Python ") { return String(value.dropFirst(7)) }
        if value.hasPrefix("Homebrew ") { return String(value.dropFirst(9)) }
        if value.hasPrefix("go version ") { return value.split(separator: " ").dropFirst(2).first.map { String($0).dropFirst(2).description } }
        if value.hasPrefix("rustc ") { return value.split(separator: " ").dropFirst().first.map(String.init) }
        if value.hasPrefix("ruby ") { return String(value.dropFirst(5)) }
        if value.hasPrefix("Lua ") { return String(value.dropFirst(4)) }
        if let firstQuote = value.firstIndex(of: "\""), let endQuote = value[value.index(after: firstQuote)...].firstIndex(of: "\"") {
            return String(value[value.index(after: firstQuote)..<endQuote])
        }
        if value.first == "v", value.dropFirst().first?.isNumber == true { return String(value.dropFirst()) }
        return value
    }

    private func command(path: [String], arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path[0])
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return CommandResult(output: "", status: -1, timedOut: false)
        }
        let timedOut = finished.wait(timeout: .now() + 2) == .timedOut
        if timedOut {
            process.terminate()
            process.waitUntilExit()
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(output: output, status: process.terminationStatus, timedOut: timedOut)
    }
}

struct SnapshotStore: Sendable {
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevEnv", isDirectory: true)
        fileURL = directory.appendingPathComponent("machine-snapshot.json")
    }

    func load() -> MachineSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(MachineSnapshot.self, from: data), snapshot.schemaVersion == 1 else { return nil }
        return snapshot
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
