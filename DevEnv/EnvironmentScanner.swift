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
    let isInPath: Bool
}

extension RuntimeInstallation {
    private enum CodingKeys: String, CodingKey {
        case id, executable, actualExecutable, version, state, error, isEffective, isInPath
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        executable = try values.decode(String.self, forKey: .executable)
        actualExecutable = try values.decodeIfPresent(String.self, forKey: .actualExecutable)
        version = try values.decodeIfPresent(String.self, forKey: .version)
        state = try values.decode(RuntimeState.self, forKey: .state)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        isEffective = try values.decode(Bool.self, forKey: .isEffective)
        isInPath = try values.decodeIfPresent(Bool.self, forKey: .isInPath) ?? true
    }
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
        Set(installations.filter(\.isInPath).compactMap(\.version)).count > 1
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
    func directoryEntries(atPath path: String) throws -> [String]
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

    func directoryEntries(atPath path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
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
        if URL(fileURLWithPath: executable).lastPathComponent == "brew" {
            var environment = ProcessInfo.processInfo.environment
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            environment["HOMEBREW_NO_INSTALL_FROM_API"] = "1"
            process.environment = environment
        }
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
        let homebrewFormula: String
    }

    private struct RuntimeProviderInstallation: Sendable {
        let runtimeID: String
        let version: String
        let executable: String
    }

    private struct MiseInstallation: Decodable {
        let version: String
        let installPath: String

        private enum CodingKeys: String, CodingKey {
            case version
            case installPath = "install_path"
        }
    }

    private struct UVInstallation: Decodable {
        let version: String
        let path: String
    }

    private let runtimeDefinitions = [
        RuntimeDefinition(id: "node", name: "Node.js", executable: "node", arguments: ["--version"], homebrewFormula: "node"),
        RuntimeDefinition(id: "python", name: "Python", executable: "python3", arguments: ["--version"], homebrewFormula: "python"),
        RuntimeDefinition(id: "go", name: "Go", executable: "go", arguments: ["version"], homebrewFormula: "go"),
        RuntimeDefinition(id: "java", name: "Java", executable: "java", arguments: ["-version"], homebrewFormula: "openjdk"),
        RuntimeDefinition(id: "rust", name: "Rust", executable: "rustc", arguments: ["--version"], homebrewFormula: "rust"),
        RuntimeDefinition(id: "ruby", name: "Ruby", executable: "ruby", arguments: ["--version"], homebrewFormula: "ruby"),
        RuntimeDefinition(id: "lua", name: "Lua", executable: "lua", arguments: ["-v"], homebrewFormula: "lua"),
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

        let homebrew = scanHomebrew(path: path, issues: &issues)
        let homebrewInstallations = homebrew.available ? homebrew.executable.map {
            scanHomebrewRuntimes(executable: $0, issues: &issues)
        } ?? [] : []
        let miseInstallations = scanMiseRuntimes(path: path, issues: &issues)
        let nvmInstallations = scanNVMInstallations(issues: &issues)
        let uvInstallations = scanUVInstallations(path: path, issues: &issues)
        let pyenvInstallations = scanPyenvInstallations(path: path, issues: &issues)
        let javaHomeInstallations = scanJavaHomeInstallations(issues: &issues)
        let rustupInstallations = scanRustupInstallations(path: path, issues: &issues)
        let runtimes = runtimeDefinitions.map { definition in
            scanRuntime(
                definition,
                path: path,
                providers: (homebrewInstallations + miseInstallations + nvmInstallations + uvInstallations + pyenvInstallations
                    + javaHomeInstallations + rustupInstallations)
                    .filter { $0.runtimeID == definition.id },
                issues: &issues
            )
        }
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
        providers: [RuntimeProviderInstallation],
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
                isEffective: installations.isEmpty,
                isInPath: true
            ))
        }

        for installation in providers.sorted(by: providerInstallationOrder) {
            let executable = standardizedPath(installation.executable)
            let available = machine.isExecutableFile(atPath: executable)
            let actual = available ? standardizedPath(machine.resolvingSymlinksInPath(executable)) : executable
            guard seenTargets.insert(actual).inserted else { continue }
            let error = available ? nil : "可执行文件不可用"
            if let error {
                issues.append("\(definition.name)：\(error)（\(executable)）")
            }
            installations.append(RuntimeInstallation(
                id: actual,
                executable: executable,
                actualExecutable: available && actual != executable ? actual : nil,
                version: installation.version,
                state: available ? .discovered : .failed,
                error: error,
                isEffective: false,
                isInPath: false
            ))
        }

        return RuntimeSnapshot(id: definition.id, name: definition.name, installations: installations)
    }

    private func scanMiseRuntimes(path: [String], issues: inout [String]) -> [RuntimeProviderInstallation] {
        let candidates = path.map { absoluteExecutable("mise", directory: $0) }
            + (machine.environment["HOME"].map { ["\($0)/.local/bin/mise"] } ?? [])
            + ["/opt/homebrew/bin/mise", "/usr/local/bin/mise"]
        guard let executable = candidates.first(where: { machine.isExecutableFile(atPath: $0) }) else { return [] }
        let result = machine.command(executable: executable, arguments: ["ls", "--installed", "--json"])
        guard result.status == 0, !result.timedOut else {
            issues.append("mise Runtime Provider：\(result.timedOut ? "命令超时" : "读取失败")")
            return []
        }
        guard let data = result.output.data(using: .utf8),
              let installed = try? JSONDecoder().decode([String: [MiseInstallation]].self, from: data) else {
            issues.append("mise Runtime Provider：输出解析失败")
            return []
        }
        return runtimeDefinitions.flatMap { definition in
            installed[definition.id, default: []].map { installation in
                RuntimeProviderInstallation(
                    runtimeID: definition.id,
                    version: installation.version,
                    executable: standardizedPath("\(installation.installPath)/bin/\(definition.executable)")
                )
            }
        }
    }

    private func scanNVMInstallations(issues: inout [String]) -> [RuntimeProviderInstallation] {
        guard let root = machine.environment["NVM_DIR"] ?? machine.environment["HOME"].map({ "\($0)/.nvm" }),
              root.hasPrefix("/") else { return [] }
        let versionRoot = standardizedPath("\(root)/versions/node")
        let entries: [String]
        do {
            entries = try machine.directoryEntries(atPath: versionRoot)
        } catch {
            let fileError = error as NSError
            if fileError.domain != NSCocoaErrorDomain || fileError.code != CocoaError.fileReadNoSuchFile.rawValue {
                issues.append("nvm Runtime Provider：读取失败（\(versionRoot)）")
            }
            return []
        }
        return entries.compactMap { entry in
            let directory = "\(versionRoot)/\(entry)"
            guard let version = nvmVersion(from: directory) else { return nil }
            return RuntimeProviderInstallation(runtimeID: "node", version: version, executable: "\(directory)/bin/node")
        }
    }

    private func scanUVInstallations(path: [String], issues: inout [String]) -> [RuntimeProviderInstallation] {
        let candidates = path.map { absoluteExecutable("uv", directory: $0) }
            + (machine.environment["HOME"].map { ["\($0)/.local/bin/uv"] } ?? [])
            + ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        guard let executable = candidates.first(where: { machine.isExecutableFile(atPath: $0) }) else { return [] }
        let result = machine.command(executable: executable, arguments: ["python", "list", "--only-installed", "--output-format", "json"])
        guard result.status == 0, !result.timedOut else {
            issues.append("uv Python Runtime Provider：\(result.timedOut ? "命令超时" : "读取失败")")
            return []
        }
        guard let data = result.output.data(using: .utf8),
              let installed = try? JSONDecoder().decode([UVInstallation].self, from: data) else {
            issues.append("uv Python Runtime Provider：输出解析失败")
            return []
        }
        return installed.map {
            RuntimeProviderInstallation(runtimeID: "python", version: $0.version, executable: standardizedPath($0.path))
        }
    }

    private func scanPyenvInstallations(path: [String], issues: inout [String]) -> [RuntimeProviderInstallation] {
        let root = machine.environment["PYENV_ROOT"] ?? machine.environment["HOME"].map { "\($0)/.pyenv" }
        guard let root, root.hasPrefix("/") else { return [] }
        let candidates = path.map { absoluteExecutable("pyenv", directory: $0) }
            + ["\(root)/bin/pyenv", "/opt/homebrew/bin/pyenv", "/usr/local/bin/pyenv"]
        guard let executable = candidates.first(where: { machine.isExecutableFile(atPath: $0) }) else { return [] }
        let result = machine.command(executable: executable, arguments: ["versions", "--bare"])
        guard result.status == 0, !result.timedOut else {
            issues.append("pyenv Python Runtime Provider：\(result.timedOut ? "命令超时" : "读取失败")")
            return []
        }
        return result.output.split(whereSeparator: \.isNewline).compactMap { line in
            let version = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !version.isEmpty, version != "system" else { return nil }
            return RuntimeProviderInstallation(
                runtimeID: "python",
                version: version,
                executable: standardizedPath("\(root)/versions/\(version)/bin/python3")
            )
        }
    }

    private func scanJavaHomeInstallations(issues: inout [String]) -> [RuntimeProviderInstallation] {
        let executable = "/usr/libexec/java_home"
        guard machine.isExecutableFile(atPath: executable) else { return [] }
        let result = machine.command(executable: executable, arguments: ["-V"])
        guard result.status == 0, !result.timedOut else {
            issues.append("java_home Java Runtime Provider：\(result.timedOut ? "命令超时" : "读取失败")")
            return []
        }

        let installations = result.output.split(whereSeparator: \.isNewline).compactMap { line -> RuntimeProviderInstallation? in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.range(of: #"^[0-9][^ ]* \([^)]*\) \"[^\"]+\" - \"[^\"]+\" /"#, options: .regularExpression) != nil,
                  let pathStart = value.range(of: #" /"#, options: .backwards)?.upperBound else { return nil }
            let version = String(value[..<value.firstIndex(of: " ")!])
            let home = "/" + value[pathStart...]
            let java = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("java")
                .path
            return RuntimeProviderInstallation(runtimeID: "java", version: version, executable: java)
        }
        guard !installations.isEmpty else {
            issues.append("java_home Java Runtime Provider：输出解析失败")
            return []
        }
        return installations
    }

    private func scanRustupInstallations(path: [String], issues: inout [String]) -> [RuntimeProviderInstallation] {
        let candidates = path.map { absoluteExecutable("rustup", directory: $0) }
            + (machine.environment["CARGO_HOME"].map { ["\($0)/bin/rustup"] } ?? [])
            + (machine.environment["HOME"].map { ["\($0)/.cargo/bin/rustup"] } ?? [])
            + ["/opt/homebrew/bin/rustup", "/usr/local/bin/rustup"]
        guard let executable = candidates.first(where: { machine.isExecutableFile(atPath: $0) }) else { return [] }

        let root = machine.environment["RUSTUP_HOME"] ?? machine.environment["HOME"].map { "\($0)/.rustup" }
        guard let root, root.hasPrefix("/") else { return [] }
        let result = machine.command(executable: executable, arguments: ["toolchain", "list"])
        guard result.status == 0, !result.timedOut else {
            issues.append("rustup Rust Runtime Provider：\(result.timedOut ? "命令超时" : "读取失败")")
            return []
        }

        let lines = result.output.split(whereSeparator: \.isNewline)
        if lines.count == 1, lines[0].trimmingCharacters(in: .whitespacesAndNewlines) == "no installed toolchains" {
            return []
        }
        let installations = lines.compactMap { line -> RuntimeProviderInstallation? in
            guard let name = line.split(whereSeparator: \.isWhitespace).first,
                  !name.contains("/"), !name.contains("..") else { return nil }
            let toolchain = String(name)
            return RuntimeProviderInstallation(
                runtimeID: "rust",
                version: toolchain,
                executable: standardizedPath("\(root)/toolchains/\(toolchain)/bin/rustc")
            )
        }
        guard !installations.isEmpty else {
            issues.append("rustup Rust Runtime Provider：输出解析失败")
            return []
        }
        return installations
    }

    private func nvmVersion(from directory: String) -> String? {
        let name = URL(fileURLWithPath: directory).lastPathComponent
        guard name.range(
            of: #"^v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$"#,
            options: .regularExpression
        ) != nil else { return nil }
        return String(name.dropFirst())
    }

    private func scanHomebrew(path: [String], issues: inout [String]) -> HomebrewSnapshot {
        let pathCandidates = path.map { absoluteExecutable("brew", directory: $0) }
        let candidates = pathCandidates + ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let executable = candidates.first(where: { machine.isExecutableFile(atPath: $0) }) else {
            return HomebrewSnapshot(executable: nil, version: nil, available: false, error: nil)
        }
        let result = machine.command(executable: executable, arguments: ["--version"])
        guard result.status == 0, !result.timedOut, let version = normalizedVersion(result.output) else {
            let error = result.timedOut ? "命令超时" : "版本读取失败"
            issues.append("Homebrew：\(error)")
            return HomebrewSnapshot(executable: executable, version: nil, available: false, error: error)
        }
        return HomebrewSnapshot(executable: executable, version: version, available: true, error: nil)
    }

    private func scanHomebrewRuntimes(
        executable: String,
        issues: inout [String]
    ) -> [RuntimeProviderInstallation] {
        let versionsResult = machine.command(executable: executable, arguments: ["list", "--formula", "--versions"])
        guard versionsResult.status == 0, !versionsResult.timedOut else {
            issues.append("Homebrew Runtime Provider：\(versionsResult.timedOut ? "命令超时" : "读取失败")")
            return []
        }

        let formulaVersions = versionsResult.output.split(whereSeparator: \.isNewline).compactMap { line -> (RuntimeDefinition, String, [String])? in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count > 1,
                  let formula = fields.first,
                  let definition = runtimeDefinitions.first(where: {
                      formula == $0.homebrewFormula || formula.hasPrefix("\($0.homebrewFormula)@")
                  }) else { return nil }
            return (definition, formula, Array(fields.dropFirst()))
        }
        guard !formulaVersions.isEmpty else { return [] }

        let cellarResult = machine.command(executable: executable, arguments: ["--cellar"])
        guard cellarResult.status == 0,
              !cellarResult.timedOut,
              let cellar = normalizedVersion(cellarResult.output) else {
            issues.append("Homebrew Runtime Provider：\(cellarResult.timedOut ? "命令超时" : "读取失败")")
            return []
        }

        return formulaVersions.flatMap { definition, formula, versions in
            versions.map { version in
                RuntimeProviderInstallation(
                    runtimeID: definition.id,
                    version: version,
                    executable: URL(fileURLWithPath: cellar, isDirectory: true)
                        .appendingPathComponent(formula, isDirectory: true)
                        .appendingPathComponent(version, isDirectory: true)
                        .appendingPathComponent("bin", isDirectory: true)
                        .appendingPathComponent(definition.executable)
                        .path
                )
            }
        }
    }

    private func providerInstallationOrder(
        _ lhs: RuntimeProviderInstallation,
        _ rhs: RuntimeProviderInstallation
    ) -> Bool {
        let versionOrder = lhs.version.compare(rhs.version, options: [.numeric, .caseInsensitive])
        return versionOrder == .orderedSame ? lhs.executable < rhs.executable : versionOrder == .orderedDescending
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
