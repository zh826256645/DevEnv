import AppKit
import Darwin
import Foundation

enum MachineToolSearchPathSource: String, Codable, Sendable {
    case defaultLoginShell
    case appProcessFallback
}

struct MachineToolSearchPathSnapshot: Codable, Sendable {
    let entries: [String]
    let source: MachineToolSearchPathSource
}

struct MachineSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 15
    static let localServiceTimeoutNotice = "本地服务：命令超时"
    static let localServiceFailureNotice = "本地服务：读取失败"

    let schemaVersion: Int
    let scannedAt: Date
    let system: SystemSnapshot
    let localServices: [LocalServiceSnapshot]
    let machineToolSearchPath: MachineToolSearchPathSnapshot
    let runtimes: [RuntimeSnapshot]
    let databaseInstallationOverviews: [DatabaseInstallationOverview]
    let homebrew: HomebrewSnapshot
    let packageManagers: [PackageManagerSnapshot]
    let terminalApplications: [TerminalApplicationSnapshot]
    let shellInstallations: [ShellInstallationSnapshot]
    let gitCLI: GitCLISnapshot
    let gitLFS: GitLFSSnapshot?
    let userGitConfiguration: UserGitConfigurationSnapshot?
    let gitSigningConfiguration: GitSigningConfigurationSnapshot?
    let gitCredentialHelpers: [String]?
    let githubAuthenticationConfiguration: GitHubAuthenticationConfigurationSnapshot
    let issues: [String]

    var path: [String] { machineToolSearchPath.entries }

    var localServiceScanNotice: String? {
        issues.first { $0 == Self.localServiceTimeoutNotice || $0 == Self.localServiceFailureNotice }
    }

    func applying(_ dynamicStatus: DynamicStatusSnapshot) -> MachineSnapshot {
        MachineSnapshot(
            schemaVersion: schemaVersion,
            scannedAt: scannedAt,
            system: system,
            localServices: dynamicStatus.localServices,
            machineToolSearchPath: machineToolSearchPath,
            runtimes: runtimes,
            databaseInstallationOverviews: dynamicStatus.databaseInstallationOverviews,
            homebrew: homebrew,
            packageManagers: packageManagers,
            terminalApplications: terminalApplications,
            shellInstallations: shellInstallations,
            gitCLI: gitCLI,
            gitLFS: gitLFS,
            userGitConfiguration: userGitConfiguration,
            gitSigningConfiguration: gitSigningConfiguration,
            gitCredentialHelpers: gitCredentialHelpers,
            githubAuthenticationConfiguration: githubAuthenticationConfiguration,
            issues: issues
        )
    }
}

enum ListenerAddressFamily: String, Codable, Sendable {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"
}

struct ListenerBinding: Codable, Hashable, Sendable {
    let address: String
    let port: UInt16
    let family: ListenerAddressFamily

    var isLoopback: Bool {
        family == .ipv4 ? address.split(separator: ".").first == "127" : address == "::1"
    }
}

enum LocalServiceAttributionKind: String, Codable, Sendable {
    case project
    case application
}

struct LocalServiceAttribution: Codable, Hashable, Sendable {
    let kind: LocalServiceAttributionKind
    let name: String
    let path: String
}

enum LocalServiceRuntime: String, Codable, CaseIterable, Sendable {
    case python, node, bun, go, rust, java

    init?(processName: String) {
        let name = processName.lowercased()
        if name.hasPrefix("python") { self = .python; return }
        switch name {
        case "node", "nodejs": self = .node
        case "bun", "bun.exe": self = .bun
        case "java": self = .java
        default: return nil
        }
    }

    var manifests: [String] {
        switch self {
        case .python: ["pyproject.toml"]
        case .node, .bun: ["package.json"]
        case .go: ["go.mod"]
        case .rust: ["Cargo.toml"]
        case .java: ["pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
        }
    }
}

struct LocalServiceSnapshot: Codable, Identifiable, Sendable {
    var id: Int32 { pid }

    let processName: String
    let pid: Int32
    let bindings: [ListenerBinding]
    let attribution: LocalServiceAttribution?
    let runtime: LocalServiceRuntime?
    let artifactPath: String?

    init(
        processName: String,
        pid: Int32,
        bindings: [ListenerBinding],
        attribution: LocalServiceAttribution? = nil,
        runtime: LocalServiceRuntime? = nil,
        artifactPath: String? = nil
    ) {
        self.processName = processName
        self.pid = pid
        self.bindings = bindings
        self.attribution = attribution
        self.runtime = runtime
        self.artifactPath = artifactPath
    }
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

enum RuntimeInstallationSource: String, Codable, CaseIterable, Hashable, Sendable {
    case system
    case homebrew
    case mise
    case nvm
    case uv
    case pyenv
    case javaHome
    case rustup
    case rbenv
    case path

    var displayName: String {
        switch self {
        case .system: "系统"
        case .homebrew: "Homebrew"
        case .mise: "mise"
        case .nvm: "nvm"
        case .uv: "uv"
        case .pyenv: "pyenv"
        case .javaHome: "java_home"
        case .rustup: "rustup"
        case .rbenv: "rbenv"
        case .path: "PATH"
        }
    }
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
    var sources: [RuntimeInstallationSource]
}

extension RuntimeInstallation {
    private enum CodingKeys: String, CodingKey {
        case id, executable, actualExecutable, version, state, error, isEffective, isInPath, sources
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
        sources = try values.decode([RuntimeInstallationSource].self, forKey: .sources)
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

enum DatabaseDiscoveryState: String, Codable, Sendable {
    case discovered
    case notFound
    case unknown
}

enum DatabaseListeningState: String, Codable, Sendable {
    case listening
    case notListening
    case unknown
}

enum DatabaseInstallationSource: String, Codable, CaseIterable, Hashable, Sendable {
    case path
    case homebrew
    case localService

    var displayName: String {
        switch self {
        case .path: "PATH"
        case .homebrew: "Homebrew"
        case .localService: "本地服务"
        }
    }
}

struct DatabaseInstallation: Codable, Identifiable, Sendable {
    let id: String
    let executable: String
    let actualExecutable: String?
    let version: String?
    let error: String?
    let sources: [DatabaseInstallationSource]
    let homebrewFormula: String?
    let listeningState: DatabaseListeningState
}

struct DatabaseInstallationOverview: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let installations: [DatabaseInstallation]
    let discoveryState: DatabaseDiscoveryState
    let listeningState: DatabaseListeningState

    var listeningCount: Int {
        installations.filter { $0.listeningState == .listening }.count
    }
}

struct HomebrewSnapshot: Codable, Sendable {
    let executable: String?
    let version: String?
    let available: Bool
    let error: String?
}

enum PackageManagerState: String, Codable, Sendable {
    case available
    case unavailable
    case configured
    case failed
}

struct PackageManagerSnapshot: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let executable: String?
    let actualExecutable: String?
    let version: String?
    let state: PackageManagerState
    let error: String?
}

struct TerminalApplicationSnapshot: Codable, Identifiable, Sendable {
    var id: String { bundleIdentifier }

    let name: String
    let version: String?
    let bundleIdentifier: String
    let path: String
}

struct ShellInstallationSnapshot: Codable, Identifiable, Sendable {
    var id: String { path }

    let name: String
    let path: String
    let isDefault: Bool
    let isAvailable: Bool
}

enum GitCLIState: String, Codable, Sendable {
    case available
    case unavailable
    case failed
}

struct GitCLISnapshot: Codable, Sendable {
    let executable: String?
    let version: String?
    let state: GitCLIState
}

struct GitLFSSnapshot: Codable, Sendable {
    let version: String?
    let state: GitCLIState
}

struct DefaultGitIdentitySnapshot: Codable, Sendable {
    let name: String?
    let email: String?
}

enum UserExcludesFileSource: String, Codable, Sendable {
    case explicitConfiguration
    case gitDefault
}

struct UserExcludesFileSnapshot: Codable, Sendable {
    let path: String
    let source: UserExcludesFileSource
    let exists: Bool
}

struct UserGitConfigurationSnapshot: Codable, Sendable {
    let defaultIdentity: DefaultGitIdentitySnapshot
    let defaultBranch: String?
    let excludesFile: UserExcludesFileSnapshot
}

struct GitSigningConfigurationSnapshot: Codable, Sendable {
    let format: String?
    let signingKey: String?
    let commitSigning: String?
    let tagSigning: String?
}

struct GitHubAuthenticationConfigurationSnapshot: Codable, Sendable {
    let cliState: GitCLIState
    let gitProtocol: String?
    let localConfigurationExists: Bool
    let ghTokenExists: Bool
    let githubTokenExists: Bool

    var isConfigured: Bool {
        localConfigurationExists || ghTokenExists || githubTokenExists
    }
}

struct ScanResult: Sendable {
    let snapshot: MachineSnapshot
    let canPersist: Bool
}

struct DynamicStatusSnapshot: Sendable {
    let localServices: [LocalServiceSnapshot]
    let databaseInstallationOverviews: [DatabaseInstallationOverview]
}

enum DynamicStatusRefreshError: LocalizedError, Sendable {
    case timedOut
    case failed

    var errorDescription: String? {
        switch self {
        case .timedOut: "本地服务读取超时"
        case .failed: "本地服务读取失败"
        }
    }
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

struct InstalledApplication: Sendable {
    let name: String
    let version: String?
    let path: String
}

protocol MachineAccess: Sendable {
    var environment: [String: String] { get }
    var hostName: String { get }
    var currentUserName: String { get }
    var currentDirectoryPath: String { get }
    var userHomeDirectoryPath: String? { get }
    var defaultLoginShellPath: String? { get }
    func diskSpace() -> DiskSpace
    func isExecutableFile(atPath path: String) -> Bool
    func fileExists(atPath path: String) -> Bool
    func directoryEntries(atPath path: String) throws -> [String]
    func fileData(atPath path: String) throws -> Data
    func resolvingSymlinksInPath(_ path: String) -> String
    func executablePath(forPID pid: Int32) throws -> String
    func workingDirectoryPath(forPID pid: Int32) throws -> String
    func processArguments(forPID pid: Int32) throws -> [String]
    func application(bundleIdentifier: String) -> InstalledApplication?
    func captureMachineToolSearchPath(
        usingLoginShell executable: String,
        token: String,
        timeout: TimeInterval
    ) -> MachineCommandResult
    func command(executable: String, arguments: [String], timeout: TimeInterval) -> MachineCommandResult
}

extension MachineAccess {
    func command(executable: String, arguments: [String]) -> MachineCommandResult {
        command(executable: executable, arguments: arguments, timeout: 2)
    }
}

struct LiveMachineAccess: MachineAccess {
    private let environmentOverride: [String: String]?
    private let homeDirectoryOverride: String?

    init(environment: [String: String]? = nil, homeDirectoryPath: String? = nil) {
        environmentOverride = environment
        homeDirectoryOverride = homeDirectoryPath
    }

    var environment: [String: String] { environmentOverride ?? ProcessInfo.processInfo.environment }
    var hostName: String { ProcessInfo.processInfo.hostName }
    var currentUserName: String {
        guard let name = getpwuid(geteuid())?.pointee.pw_name else { return NSUserName() }
        return String(cString: name)
    }
    var currentDirectoryPath: String { FileManager.default.currentDirectoryPath }
    var userHomeDirectoryPath: String? {
        if let homeDirectoryOverride { return homeDirectoryOverride }
        guard let directory = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return String(cString: directory)
    }
    var defaultLoginShellPath: String? {
        guard let shell = getpwuid(getuid())?.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }

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

    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func directoryEntries(atPath path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }

    func fileData(atPath path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func resolvingSymlinksInPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func executablePath(forPID pid: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func workingDirectoryPath(forPID pid: Int32) throws -> String {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    func processArguments(forPID pid: Int32) throws -> [String] {
        var capacity: Int32 = 0
        var capacitySize = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.argmax", &capacity, &capacitySize, nil, 0) == 0,
              capacity > 0, capacity <= 1_048_576 else { throw POSIXError(.EIO) }
        var bytes = [UInt8](repeating: 0, count: Int(capacity))
        var size = bytes.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { throw POSIXError(.EIO) }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 16_384,
              let executableEnd = bytes[MemoryLayout<Int32>.size..<size].firstIndex(of: 0) else {
            throw POSIXError(.EINVAL)
        }
        var offset = executableEnd
        while offset < size, bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            guard offset < size, let end = bytes[offset..<size].firstIndex(of: 0),
                  let value = String(bytes: bytes[offset..<end], encoding: .utf8) else {
                throw POSIXError(.EINVAL)
            }
            arguments.append(value)
            offset = end + 1
        }
        // Stop at argc: the remaining buffer can contain environment secrets.
        return arguments
    }

    func application(bundleIdentifier: String) -> InstalledApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let bundle = Bundle(url: url) else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApplication(
            name: name,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            path: url.standardizedFileURL.path
        )
    }

    func captureMachineToolSearchPath(
        usingLoginShell executable: String,
        token: String,
        timeout: TimeInterval
    ) -> MachineCommandResult {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devenv-machine-tool-path-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            return MachineCommandResult(output: "", status: -1, timedOut: false)
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let markerFormat = "\\036\(token)\\037%s\\036\(token)\\037"
        let shellName = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        let pathArgument = shellName == "fish" ? "(/usr/bin/printenv PATH)" : "\"$PATH\""
        let script = "printf '\(markerFormat)' \(pathArgument) >> \"$DEVENV_MACHINE_TOOL_PATH_FILE\""
        let process = Process()
        let inputPipe: Pipe?
        guard let homeDirectory = userHomeDirectoryPath, homeDirectory.hasPrefix("/") else {
            return MachineCommandResult(output: "", status: -1, timedOut: false)
        }

        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        var processEnvironment = environment
        processEnvironment["PWD"] = homeDirectory
        processEnvironment["OLDPWD"] = homeDirectory
        processEnvironment["DEVENV_MACHINE_TOOL_PATH_FILE"] = outputURL.path
        process.environment = processEnvironment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        switch shellName {
        case "csh", "tcsh":
            inputPipe = Pipe()
            process.arguments = ["-l"]
            process.standardInput = inputPipe
        case "fish":
            inputPipe = nil
            process.arguments = ["--login", "--interactive", "--command", script]
            process.standardInput = FileHandle.nullDevice
        default:
            inputPipe = nil
            process.arguments = ["-l", "-i", "-c", script]
            process.standardInput = FileHandle.nullDevice
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            if let inputPipe {
                try inputPipe.fileHandleForWriting.write(contentsOf: Data("\(script)\nexit\n".utf8))
                try? inputPipe.fileHandleForWriting.close()
            }
        } catch {
            if process.isRunning { process.terminate() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return MachineCommandResult(output: "", status: -1, timedOut: false)
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return MachineCommandResult(output: "", status: -1, timedOut: true)
        }

        guard let handle = try? FileHandle(forReadingFrom: outputURL) else {
            return MachineCommandResult(output: "", status: process.terminationStatus, timedOut: false)
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 131_073),
              data.count <= 131_072,
              let output = String(data: data, encoding: .utf8) else {
            return MachineCommandResult(output: "", status: process.terminationStatus, timedOut: false)
        }
        return MachineCommandResult(output: output, status: process.terminationStatus, timedOut: false)
    }

    func command(executable: String, arguments: [String], timeout: TimeInterval) -> MachineCommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        if URL(fileURLWithPath: executable).lastPathComponent == "brew" {
            var environment = ProcessInfo.processInfo.environment
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            process.environment = environment
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return MachineCommandResult(output: "", status: -1, timedOut: false)
        }
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return MachineCommandResult(output: output, status: process.terminationStatus, timedOut: timedOut)
    }
}

struct EnvironmentScanner: Sendable {
    private struct LocalServiceAccumulator {
        var processName = ""
        var bindings: Set<ListenerBinding> = []
    }

    private struct RuntimeDefinition: Sendable {
        let id: String
        let name: String
        let executable: String
        let arguments: [String]
        let homebrewFormula: String
    }

    private struct PackageManagerDefinition: Sendable {
        let id: String
        let name: String
    }

    private struct TerminalDefinition: Sendable {
        let name: String
        let bundleIdentifier: String
    }

    private struct RuntimeProviderInstallation: Sendable {
        let runtimeID: String
        let version: String
        let executable: String
        let source: RuntimeInstallationSource
    }

    private struct LocalServiceScan {
        let services: [LocalServiceSnapshot]
        let executablePaths: [Int32: String]
        let executablePathFailures: Set<Int32>
        let complete: Bool
    }

    private struct HomebrewFormulaInstallation {
        let formula: String
        let versions: [String]
    }

    private struct HomebrewInventory {
        let formulas: [HomebrewFormulaInstallation]
        let cellar: String?
        let failureReason: String?

        static let empty = HomebrewInventory(formulas: [], cellar: nil, failureReason: nil)
    }

    private struct DatabaseCandidate {
        let executable: String
        let actualExecutable: String
        var version: String?
        var sources: [DatabaseInstallationSource]
        var homebrewFormula: String?
        var error: String?
    }

    private enum MySQLFamilyDatabase: CaseIterable {
        case mysql
        case mariadb

        var id: String { self == .mysql ? "mysql" : "mariadb" }
        var name: String { self == .mysql ? "MySQL" : "MariaDB" }
        var formula: String { self == .mysql ? "mysql" : "mariadb" }
        var executableNames: [String] { self == .mysql ? ["mysqld"] : ["mariadbd", "mysqld"] }
    }

    private enum MongoDBOrRedis: CaseIterable {
        case mongodb
        case redis

        var id: String { self == .mongodb ? "mongodb" : "redis" }
        var name: String { self == .mongodb ? "MongoDB" : "Redis" }
        var executable: String { self == .mongodb ? "mongod" : "redis-server" }
        var formula: String { self == .mongodb ? "mongodb-community" : "redis" }
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

    private let packageManagerDefinitions = [
        PackageManagerDefinition(id: "uv", name: "uv"),
        PackageManagerDefinition(id: "bun", name: "Bun"),
        PackageManagerDefinition(id: "npm", name: "npm"),
        PackageManagerDefinition(id: "pnpm", name: "pnpm"),
        PackageManagerDefinition(id: "yarn", name: "Yarn"),
    ]

    private let terminalDefinitions = [
        TerminalDefinition(name: "Terminal", bundleIdentifier: "com.apple.Terminal"),
        TerminalDefinition(name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2"),
        TerminalDefinition(name: "Warp", bundleIdentifier: "dev.warp.Warp-Stable"),
        TerminalDefinition(name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty"),
        TerminalDefinition(name: "Alacritty", bundleIdentifier: "org.alacritty"),
        TerminalDefinition(name: "kitty", bundleIdentifier: "net.kovidgoyal.kitty"),
        TerminalDefinition(name: "WezTerm", bundleIdentifier: "com.github.wez.wezterm"),
    ]

    private let machine: any MachineAccess
    private let loginShellPathTimeout: TimeInterval

    init(machine: any MachineAccess = LiveMachineAccess(), loginShellPathTimeout: TimeInterval = 3) {
        self.machine = machine
        self.loginShellPathTimeout = loginShellPathTimeout
    }

    func scan() -> ScanResult {
        var issues: [String] = []
        let toolSearchPath = resolveMachineToolSearchPath(notices: &issues)
        let path = toolSearchPath.entries

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
        let localServiceScan = scanLocalServices(issues: &issues)

        let homebrew = scanHomebrew(path: path, issues: &issues)
        let packageManagers = scanPackageManagers(path: path, issues: &issues)
        let terminalApplications = scanTerminalApplications()
        let shellInstallations = scanShellInstallations(notices: &issues)
        let gitCLI = scanGitCLI(path: path, notices: &issues)
        let gitAvailable = gitCLI.state == .available
        let gitLFS = gitAvailable ? scanGitLFS(path: path, notices: &issues) : nil
        let userGitConfiguration = gitAvailable ? gitCLI.executable.flatMap {
            scanUserGitConfiguration(executable: $0, notices: &issues)
        } : nil
        let gitSigningConfiguration = gitAvailable ? gitCLI.executable.flatMap {
            scanGitSigningConfiguration(executable: $0, notices: &issues)
        } : nil
        let gitCredentialHelpers = gitAvailable ? gitCLI.executable.flatMap {
            scanGitCredentialHelpers(executable: $0, notices: &issues)
        } : nil
        let githubAuthenticationConfiguration = scanGitHubAuthenticationConfiguration(path: path, notices: &issues)
        let homebrewInventory = homebrew.available ? homebrew.executable.map {
            scanHomebrewInventory(executable: $0, issues: &issues)
        } ?? .empty : .empty
        let homebrewInstallations = scanHomebrewRuntimes(inventory: homebrewInventory)
        let miseInstallations = scanMiseRuntimes(path: path, issues: &issues)
        let nvmInstallations = scanNVMInstallations(issues: &issues)
        let uvInstallations = scanUVInstallations(path: path, issues: &issues)
        let pyenvInstallations = scanPyenvInstallations(path: path, issues: &issues)
        let javaHomeInstallations = scanJavaHomeInstallations(issues: &issues)
        let rustupInstallations = scanRustupInstallations(path: path, issues: &issues)
        let rbenvInstallations = scanRbenvInstallations(path: path, issues: &issues)
        let runtimes = runtimeDefinitions.map { definition in
            scanRuntime(
                definition,
                path: path,
                providers: (homebrewInstallations + miseInstallations + nvmInstallations + uvInstallations + pyenvInstallations
                    + javaHomeInstallations + rustupInstallations + rbenvInstallations)
                    .filter { $0.runtimeID == definition.id },
                issues: &issues
            )
        }
        let databaseInstallationOverviews = [scanPostgreSQL(
            path: path,
            homebrew: homebrewInventory,
            homebrewAvailabilityFailed: homebrew.error != nil,
            localServices: localServiceScan,
            issues: &issues
        )] + scanMySQLFamily(
            path: path,
            homebrew: homebrewInventory,
            homebrewAvailabilityFailed: homebrew.error != nil,
            localServices: localServiceScan,
            issues: &issues
        ) + scanMongoDBAndRedis(
            path: path,
            homebrew: homebrewInventory,
            homebrewAvailabilityFailed: homebrew.error != nil,
            localServices: localServiceScan,
            notices: &issues
        )
        let snapshot = MachineSnapshot(
            schemaVersion: MachineSnapshot.currentSchemaVersion,
            scannedAt: Date(),
            system: system,
            localServices: localServiceScan.services,
            machineToolSearchPath: toolSearchPath,
            runtimes: runtimes,
            databaseInstallationOverviews: databaseInstallationOverviews,
            homebrew: homebrew,
            packageManagers: packageManagers,
            terminalApplications: terminalApplications,
            shellInstallations: shellInstallations,
            gitCLI: gitCLI,
            gitLFS: gitLFS,
            userGitConfiguration: userGitConfiguration,
            gitSigningConfiguration: gitSigningConfiguration,
            gitCredentialHelpers: gitCredentialHelpers,
            githubAuthenticationConfiguration: githubAuthenticationConfiguration,
            issues: issues
        )
        return ScanResult(
            snapshot: snapshot,
            canPersist: system.macOSVersion != nil && system.architecture != nil
        )
    }

    func refreshDynamicStatus(
        in snapshot: MachineSnapshot
    ) -> Result<DynamicStatusSnapshot, DynamicStatusRefreshError> {
        var issues: [String] = []
        let localServices = scanLocalServices(issues: &issues)
        guard localServices.complete else {
            return .failure(issues.contains(MachineSnapshot.localServiceTimeoutNotice) ? .timedOut : .failed)
        }
        return .success(DynamicStatusSnapshot(
            localServices: localServices.services,
            databaseInstallationOverviews: refreshDatabaseListeningStates(
                snapshot.databaseInstallationOverviews,
                localServices: localServices
            )
        ))
    }

    private func refreshDatabaseListeningStates(
        _ overviews: [DatabaseInstallationOverview],
        localServices: LocalServiceScan
    ) -> [DatabaseInstallationOverview] {
        let listeningPaths = Set(localServices.executablePaths.values.map {
            standardizedPath(machine.resolvingSymlinksInPath($0))
        })
        let failedProcessNames = Set(localServices.services
            .filter { localServices.executablePathFailures.contains($0.pid) }
            .map { $0.processName.lowercased() })
        let processNamesByDatabase = [
            "postgresql": Set(["postgres"]),
            "mysql": Set(["mysqld"]),
            "mariadb": Set(["mariadbd", "mysqld"]),
            "mongodb": Set(["mongod", "mongos"]),
            "redis": Set(["redis-server"]),
        ]

        return overviews.map { overview in
            guard !overview.installations.isEmpty else { return overview }
            let hasRelevantPathFailure = !failedProcessNames.isDisjoint(
                with: processNamesByDatabase[overview.id, default: []]
            )
            let installations = overview.installations.map { installation in
                let listeningState: DatabaseListeningState = if listeningPaths.contains(installation.id) {
                    .listening
                } else if hasRelevantPathFailure {
                    .unknown
                } else {
                    .notListening
                }
                return DatabaseInstallation(
                    id: installation.id,
                    executable: installation.executable,
                    actualExecutable: installation.actualExecutable,
                    version: installation.version,
                    error: installation.error,
                    sources: installation.sources,
                    homebrewFormula: installation.homebrewFormula,
                    listeningState: listeningState
                )
            }
            let listeningState: DatabaseListeningState = if installations.contains(where: {
                $0.listeningState == .listening
            }) {
                .listening
            } else if installations.contains(where: { $0.listeningState == .unknown }) {
                .unknown
            } else {
                .notListening
            }
            return DatabaseInstallationOverview(
                id: overview.id,
                name: overview.name,
                installations: installations,
                discoveryState: overview.discoveryState,
                listeningState: listeningState
            )
        }
    }

    private func scanTerminalApplications() -> [TerminalApplicationSnapshot] {
        terminalDefinitions.compactMap { definition in
            machine.application(bundleIdentifier: definition.bundleIdentifier).map {
                TerminalApplicationSnapshot(
                    name: $0.name.isEmpty ? definition.name : $0.name,
                    version: $0.version,
                    bundleIdentifier: definition.bundleIdentifier,
                    path: standardizedPath($0.path)
                )
            }
        }
    }

    private func scanShellInstallations(notices: inout [String]) -> [ShellInstallationSnapshot] {
        let defaultPath = machine.defaultLoginShellPath
            .flatMap { $0.isEmpty ? nil : $0 }
            .map(standardizedPath)
        if defaultPath == nil {
            notices.append("Default Login Shell：读取失败")
        }

        var registeredPaths: [String] = []
        var registryWasRead = false
        do {
            guard let contents = String(data: try machine.fileData(atPath: "/etc/shells"), encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            registeredPaths = contents.split(whereSeparator: \.isNewline).compactMap { line in
                let path = line.trimmingCharacters(in: .whitespaces)
                guard path.hasPrefix("/"), !path.hasPrefix("#") else { return nil }
                return standardizedPath(path)
            }
            registryWasRead = true
        } catch {
            notices.append("Shell Installation：读取失败")
        }

        let registeredPathSet = Set(registeredPaths)
        var seen = Set<String>()
        let orderedPaths = ([defaultPath].compactMap { $0 } + registeredPaths).filter { seen.insert($0).inserted }
        let installations = orderedPaths.compactMap { path -> ShellInstallationSnapshot? in
            let isDefault = path == defaultPath
            let isExecutable = machine.isExecutableFile(atPath: path)
            let isAvailable = isExecutable && (!isDefault || !registryWasRead || registeredPathSet.contains(path))
            guard isDefault || isAvailable else { return nil }
            return ShellInstallationSnapshot(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                isDefault: isDefault,
                isAvailable: isAvailable
            )
        }
        if let defaultPath,
           !machine.isExecutableFile(atPath: defaultPath) || (registryWasRead && !registeredPathSet.contains(defaultPath)) {
            notices.append("Default Login Shell：不可用")
        }
        return installations
    }

    private func scanGitCLI(path: [String], notices: inout [String]) -> GitCLISnapshot {
        guard let executable = path.lazy.map({ absoluteExecutable("git", directory: $0) })
            .first(where: { machine.isExecutableFile(atPath: $0) }) else {
            return GitCLISnapshot(executable: nil, version: nil, state: .unavailable)
        }
        let result = machine.command(executable: executable, arguments: ["--version"])
        let version = result.status == 0 && !result.timedOut ? gitVersion(from: result.output) : nil
        guard let version else {
            let failureReason = result.timedOut ? "命令超时" : "版本读取失败"
            notices.append("Git CLI：\(failureReason)")
            return GitCLISnapshot(executable: executable, version: nil, state: .failed)
        }
        return GitCLISnapshot(executable: executable, version: version, state: .available)
    }

    private func scanGitLFS(path: [String], notices: inout [String]) -> GitLFSSnapshot {
        guard let executable = path.lazy.map({ absoluteExecutable("git-lfs", directory: $0) })
            .first(where: { machine.isExecutableFile(atPath: $0) }) else {
            return GitLFSSnapshot(version: nil, state: .unavailable)
        }
        let result = machine.command(executable: executable, arguments: ["version"])
        let version = result.status == 0 && !result.timedOut ? gitLFSVersion(from: result.output) : nil
        guard let version else {
            notices.append("Git LFS：\(result.timedOut ? "命令超时" : "版本读取失败")")
            return GitLFSSnapshot(version: nil, state: .failed)
        }
        return GitLFSSnapshot(version: version, state: .available)
    }

    private func scanGitHubAuthenticationConfiguration(
        path: [String],
        notices: inout [String]
    ) -> GitHubAuthenticationConfigurationSnapshot {
        let environment = machine.environment
        let configurationDirectory = environment["GH_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : "\($0)/gh" }
            ?? environment["HOME"].flatMap { $0.isEmpty ? nil : "\($0)/.config/gh" }
        let localConfigurationExists = configurationDirectory.map {
            machine.fileExists(atPath: standardizedPath("\($0)/hosts.yml"))
        } ?? false
        let ghTokenExists = environment["GH_TOKEN"].map { !$0.isEmpty } ?? false
        let githubTokenExists = environment["GITHUB_TOKEN"].map { !$0.isEmpty } ?? false

        guard let executable = path.lazy.map({ absoluteExecutable("gh", directory: $0) })
            .first(where: { machine.isExecutableFile(atPath: $0) }) else {
            return GitHubAuthenticationConfigurationSnapshot(
                cliState: .unavailable,
                gitProtocol: nil,
                localConfigurationExists: localConfigurationExists,
                ghTokenExists: ghTokenExists,
                githubTokenExists: githubTokenExists
            )
        }

        guard localConfigurationExists else {
            return GitHubAuthenticationConfigurationSnapshot(
                cliState: .available,
                gitProtocol: nil,
                localConfigurationExists: false,
                ghTokenExists: ghTokenExists,
                githubTokenExists: githubTokenExists
            )
        }

        let result = machine.command(
            executable: executable,
            arguments: ["config", "get", "git_protocol", "--host", "github.com"]
        )
        let protocolValue = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let missing = result.status == 1 && protocolValue.isEmpty
        let validProtocol = ["https", "ssh"].contains(protocolValue)
        let failed = result.timedOut || (!missing && result.status != 0) || (!protocolValue.isEmpty && !validProtocol)
        if failed {
            notices.append("GitHub CLI Configuration：\(result.timedOut ? "命令超时" : "读取失败")")
        }

        return GitHubAuthenticationConfigurationSnapshot(
            cliState: failed ? .failed : .available,
            gitProtocol: !failed && validProtocol ? protocolValue : nil,
            localConfigurationExists: localConfigurationExists,
            ghTokenExists: ghTokenExists,
            githubTokenExists: githubTokenExists
        )
    }

    private func scanUserGitConfiguration(
        executable: String,
        notices: inout [String]
    ) -> UserGitConfigurationSnapshot? {
        let keys = ["user.name", "user.email", "init.defaultBranch", "core.excludesFile"]
        var values: [String: String] = [:]

        for key in keys {
            let arguments = ["config", "--global"]
                + (key == "core.excludesFile" ? ["--path"] : [])
                + ["--get", key]
            let result = machine.command(executable: executable, arguments: arguments)
            let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.timedOut {
                notices.append("User Git Configuration：命令超时")
                return nil
            }
            if result.status == 1, value.isEmpty { continue }
            guard result.status == 0 else {
                notices.append("User Git Configuration：读取失败")
                return nil
            }
            if !value.isEmpty { values[key] = value }
        }

        let source: UserExcludesFileSource
        let excludesPath: String
        if let configuredPath = values["core.excludesFile"] {
            source = .explicitConfiguration
            excludesPath = absoluteUserPath(configuredPath)
        } else {
            guard let home = machine.environment["HOME"], !home.isEmpty else { return nil }
            source = .gitDefault
            let configurationDirectory = machine.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config").path
            excludesPath = standardizedPath(URL(
                fileURLWithPath: absoluteUserPath(configurationDirectory),
                isDirectory: true
            ).appendingPathComponent("git/ignore").path)
        }

        return UserGitConfigurationSnapshot(
            defaultIdentity: DefaultGitIdentitySnapshot(
                name: values["user.name"],
                email: values["user.email"]
            ),
            defaultBranch: values["init.defaultBranch"],
            excludesFile: UserExcludesFileSnapshot(
                path: excludesPath,
                source: source,
                exists: machine.fileExists(atPath: excludesPath)
            )
        )
    }

    private func scanGitSigningConfiguration(
        executable: String,
        notices: inout [String]
    ) -> GitSigningConfigurationSnapshot? {
        let keys = ["gpg.format", "user.signingKey", "commit.gpgSign", "tag.gpgSign"]
        var values: [String: String] = [:]

        for key in keys {
            let result = machine.command(
                executable: executable,
                arguments: ["config", "--global", "--get", key]
            )
            let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.timedOut {
                notices.append("Git Signing Configuration：命令超时")
                return nil
            }
            if result.status == 1, value.isEmpty { continue }
            guard result.status == 0 else {
                notices.append("Git Signing Configuration：读取失败")
                return nil
            }
            if !value.isEmpty { values[key] = value }
        }

        return GitSigningConfigurationSnapshot(
            format: values["gpg.format"],
            signingKey: values["user.signingKey"],
            commitSigning: values["commit.gpgSign"],
            tagSigning: values["tag.gpgSign"]
        )
    }

    private func scanGitCredentialHelpers(executable: String, notices: inout [String]) -> [String]? {
        let result = machine.command(
            executable: executable,
            arguments: ["config", "--global", "--null", "--get-all", "credential.helper"]
        )
        if result.timedOut {
            notices.append("Git Credential Helpers：命令超时")
            return nil
        }
        if result.status == 1, result.output.isEmpty { return [] }
        guard result.status == 0 else {
            notices.append("Git Credential Helpers：读取失败")
            return nil
        }
        guard !result.output.isEmpty else { return [] }

        var values = result.output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if result.output.last == "\0" { values.removeLast() }
        return values.map(credentialHelperLabel)
    }

    private func credentialHelperLabel(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "清空 helper chain" }
        guard !value.hasPrefix("!") else { return "自定义命令" }

        var token = ""
        var quote: Character?
        var escaping = false
        for character in value {
            if escaping {
                token.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { token.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                break
            } else {
                token.append(character)
            }
        }

        let name = URL(fileURLWithPath: token).lastPathComponent
        return name.hasPrefix("git-credential-") ? String(name.dropFirst("git-credential-".count)) : name
    }

    private func absoluteUserPath(_ path: String) -> String {
        if path == "~", let home = machine.environment["HOME"] { return standardizedPath(home) }
        if path.hasPrefix("~/"), let home = machine.environment["HOME"] {
            return standardizedPath(URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(path.dropFirst(2))).path)
        }
        if path.hasPrefix("/") { return standardizedPath(path) }
        let home = machine.environment["HOME"] ?? machine.currentDirectoryPath
        return standardizedPath(URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(path).path)
    }

    private func gitVersion(from output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        let prefix = "git version "
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix(prefix) else { return nil }
        let version = String(value.dropFirst(prefix.count))
        guard version.range(
            of: #"^[0-9]+(?:\.[0-9A-Za-z]+)+(?:[-.A-Za-z0-9+() ]*)$"#,
            options: .regularExpression
        ) != nil else { return nil }
        return version
    }

    private func gitLFSVersion(from output: String) -> String? {
        guard let value = output.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            value.hasPrefix("git-lfs/") else { return nil }
        let version = value.dropFirst("git-lfs/".count).split(whereSeparator: \.isWhitespace).first.map(String.init)
        guard let version,
              version.range(of: #"^[0-9]+(?:\.[0-9A-Za-z]+)+(?:[-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
        else { return nil }
        return version
    }

    private func scanLocalServices(issues: inout [String]) -> LocalServiceScan {
        let result = machine.command(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcftn"]
        )
        if result.timedOut {
            issues.append(MachineSnapshot.localServiceTimeoutNotice)
            return LocalServiceScan(services: [], executablePaths: [:], executablePathFailures: [], complete: false)
        }
        let hasNoMatches = result.status == 1 && result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard result.status == 0 || hasNoMatches else {
            issues.append(MachineSnapshot.localServiceFailureNotice)
            return LocalServiceScan(services: [], executablePaths: [:], executablePathFailures: [], complete: false)
        }

        var services: [Int32: LocalServiceAccumulator] = [:]
        var currentPID: Int32?
        var currentFamily: ListenerAddressFamily?

        for line in result.output.split(whereSeparator: \.isNewline) {
            let value = String(line.dropFirst())
            switch line.first {
            case "p":
                currentPID = Int32(value)
                currentFamily = nil
            case "c":
                if let currentPID { services[currentPID, default: LocalServiceAccumulator()].processName = value }
            case "t":
                currentFamily = ListenerAddressFamily(rawValue: value)
            case "n":
                guard let currentPID, let currentFamily,
                      let binding = listenerBinding(from: value, family: currentFamily) else { continue }
                services[currentPID, default: LocalServiceAccumulator()].bindings.insert(binding)
            default:
                continue
            }
        }

        var snapshots = services.compactMap { pid, service -> LocalServiceSnapshot? in
            guard !service.processName.isEmpty, !service.bindings.isEmpty else { return nil }
            let bindings = service.bindings.sorted {
                if $0.port != $1.port { return $0.port < $1.port }
                if $0.family != $1.family { return $0.family.rawValue < $1.family.rawValue }
                return $0.address < $1.address
            }
            return LocalServiceSnapshot(processName: service.processName, pid: pid, bindings: bindings)
        }.sorted {
            if $0.bindings[0].port != $1.bindings[0].port { return $0.bindings[0].port < $1.bindings[0].port }
            if $0.processName != $1.processName { return $0.processName < $1.processName }
            return $0.pid < $1.pid
        }
        var executablePaths: [Int32: String] = [:]
        var executablePathFailures: Set<Int32> = []
        for service in snapshots {
            do {
                executablePaths[service.pid] = standardizedPath(try machine.executablePath(forPID: service.pid))
            } catch {
                executablePathFailures.insert(service.pid)
            }
        }
        snapshots = snapshots.map { service in
            attributedLocalService(service, executablePath: executablePaths[service.pid])
        }
        return LocalServiceScan(
            services: snapshots,
            executablePaths: executablePaths,
            executablePathFailures: executablePathFailures,
            complete: true
        )
    }

    private func listenerBinding(from name: String, family: ListenerAddressFamily) -> ListenerBinding? {
        let value = name.hasSuffix(" (LISTEN)") ? String(name.dropLast(9)) : name
        guard let separator = value.lastIndex(of: ":"),
              let port = UInt16(value[value.index(after: separator)...]) else { return nil }
        var address = String(value[..<separator])
        if address.first == "[", address.last == "]" { address = String(address.dropFirst().dropLast()) }
        guard !address.isEmpty else { return nil }
        return ListenerBinding(address: address, port: port, family: family)
    }

    private func attributedLocalService(
        _ service: LocalServiceSnapshot,
        executablePath: String?
    ) -> LocalServiceSnapshot {
        var runtime = executablePath.flatMap { LocalServiceRuntime(processName: URL(fileURLWithPath: $0).lastPathComponent) }
            ?? LocalServiceRuntime(processName: service.processName)
        let application = executablePath.flatMap(containingApplicationPath).map { path in
            LocalServiceAttribution(
                kind: .application, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path: path
            )
        }
        if runtime == nil, let application {
            return LocalServiceSnapshot(
                processName: service.processName, pid: service.pid, bindings: service.bindings,
                attribution: application, artifactPath: executablePath
            )
        }
        let workingDirectory = try? machine.workingDirectoryPath(forPID: service.pid)
        var artifactPath = executablePath
        var roots: (nameRoot: String, serviceRoot: String)?
        if runtime == .java,
           let arguments = try? machine.processArguments(forPID: service.pid),
           let launch = javaLaunchPaths(arguments, workingDirectory: workingDirectory) {
            artifactPath = launch.jar ?? executablePath
            let candidates = launch.paths.compactMap { path in
                projectRoots(startingAt: path, runtime: .java)
            }
            if Set(candidates.map(\.serviceRoot)).count == 1 { roots = candidates.first }
        } else if runtime == nil, let executablePath {
            roots = projectRoots(startingAt: URL(fileURLWithPath: executablePath).deletingLastPathComponent().path, runtime: nil)
            if let roots {
                // ponytail: adjacent-manifest inference; use binary build metadata if external builds need language attribution.
                let candidates = LocalServiceRuntime.allCases.filter { candidate in
                    candidate != .bun && candidate.manifests.contains {
                        machine.fileExists(atPath: roots.serviceRoot + "/" + $0)
                    }
                }
                if candidates.count == 1, let candidate = candidates.first, candidate == .go || candidate == .rust {
                    runtime = candidate
                }
            }
        } else if let workingDirectory {
            roots = projectRoots(startingAt: workingDirectory, runtime: runtime)
        }
        if roots == nil, runtime == nil, let workingDirectory {
            roots = projectRoots(startingAt: workingDirectory, runtime: nil)
        }
        var attribution: LocalServiceAttribution?
        if let roots {
            attribution = LocalServiceAttribution(
                kind: .project,
                name: URL(fileURLWithPath: roots.nameRoot).lastPathComponent,
                path: roots.serviceRoot
            )
        } else {
            attribution = application
        }
        return LocalServiceSnapshot(
            processName: service.processName, pid: service.pid, bindings: service.bindings,
            attribution: attribution, runtime: runtime, artifactPath: artifactPath
        )
    }

    private func serviceArgumentPath(_ value: String, workingDirectory: String?) -> String? {
        guard !value.isEmpty, value.utf8.count < Int(MAXPATHLEN),
              value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
              value.hasPrefix("/") || workingDirectory != nil else { return nil }
        let absolute = value.hasPrefix("/") ? value : workingDirectory! + "/" + value
        let path = standardizedPath(machine.resolvingSymlinksInPath(absolute))
        return machine.fileExists(atPath: path) ? path : nil
    }

    private func javaLaunchPaths(_ arguments: [String], workingDirectory: String?) -> (paths: [String], jar: String?)? {
        var classPaths: [String]?
        var modulePaths: [String]?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-jar" {
                let jar = arguments.indices.contains(index + 1)
                    ? serviceArgumentPath(arguments[index + 1], workingDirectory: workingDirectory) : nil
                return (jar.map { [URL(fileURLWithPath: $0).deletingLastPathComponent().path] } ?? [], jar)
            }
            let pathOptions = ["-cp", "-classpath", "--class-path", "-p", "--module-path"]
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pathOptions.contains(String(parts[0])) {
                let value: String
                if parts.count == 2 {
                    value = String(parts[1])
                } else {
                    index += 1
                    guard index < arguments.count else { return ([], nil) }
                    value = arguments[index]
                }
                let paths = value.split(separator: ":", omittingEmptySubsequences: false).compactMap { entry -> String? in
                    let path = entry.isEmpty ? "." : String(entry)
                    let candidate = path.hasSuffix("/*") ? String(path.dropLast(2)) : path
                    guard let resolved = serviceArgumentPath(candidate, workingDirectory: workingDirectory) else { return nil }
                    return resolved.hasSuffix(".jar") ? URL(fileURLWithPath: resolved).deletingLastPathComponent().path : resolved
                }
                if ["-p", "--module-path"].contains(String(parts[0])) {
                    modulePaths = paths
                } else {
                    classPaths = paths
                }
            } else if ["--add-opens", "--add-exports", "--add-reads", "--add-modules", "--limit-modules", "--patch-module"].contains(argument) {
                index += 1
            } else if !argument.hasPrefix("-") || argument == "-m" || argument == "--module" || argument.hasPrefix("--module=") {
                break // Anything after the main class/module belongs to the application, not the JVM.
            }
            index += 1
        }
        guard classPaths != nil || modulePaths != nil else { return nil }
        return ((classPaths ?? []) + (modulePaths ?? []), nil)
    }

    private func containingApplicationPath(for executablePath: String) -> String? {
        var candidate = URL(fileURLWithPath: executablePath)
        while candidate.path != "/" {
            if candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame { return candidate.path }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private func projectRoots(startingAt path: String, runtime: LocalServiceRuntime?) -> (nameRoot: String, serviceRoot: String)? {
        var directory = standardizedPath(path)
        var nearestRoot: String?
        let homeDirectory = machine.userHomeDirectoryPath.map(standardizedPath)
        let manifests = runtime?.manifests ?? LocalServiceRuntime.allCases.flatMap(\.manifests)
        while directory != "/", directory != homeDirectory {
            let hasGitRoot = machine.fileExists(atPath: directory + "/.git")
            if manifests.contains(where: { machine.fileExists(atPath: directory + "/" + $0) }) {
                nearestRoot = nearestRoot ?? directory
            }
            if hasGitRoot {
                guard runtime != nil || nearestRoot != nil else { return nil }
                return (directory, nearestRoot ?? directory)
            }
            let parent = URL(fileURLWithPath: directory).deletingLastPathComponent().path
            guard parent != directory else { return nearestRoot.map { ($0, $0) } }
            directory = parent
        }
        return nearestRoot.map { ($0, $0) }
    }

    private func scanPostgreSQL(
        path: [String],
        homebrew: HomebrewInventory,
        homebrewAvailabilityFailed: Bool,
        localServices: LocalServiceScan,
        issues: inout [String]
    ) -> DatabaseInstallationOverview {
        var candidates: [DatabaseCandidate] = []

        func addCandidate(
            executable: String,
            actualExecutable: String,
            version: String?,
            source: DatabaseInstallationSource,
            homebrewFormula: String? = nil,
            error: String?
        ) {
            mergeDatabaseCandidate(DatabaseCandidate(
                executable: executable,
                actualExecutable: actualExecutable,
                version: version,
                sources: [source],
                homebrewFormula: homebrewFormula,
                error: error
            ), into: &candidates)
        }

        func readVersion(executable: String) -> (String?, String?) {
            let result = machine.command(executable: executable, arguments: ["--version"])
            guard result.status == 0, !result.timedOut, let version = postgreSQLVersion(from: result.output) else {
                return (nil, "版本读取失败")
            }
            return (version, nil)
        }

        for directory in path {
            let executable = absoluteExecutable("postgres", directory: directory)
            guard machine.isExecutableFile(atPath: executable) else { continue }
            let actual = standardizedPath(machine.resolvingSymlinksInPath(executable))
            guard !candidates.contains(where: { $0.actualExecutable == actual }) else { continue }
            let (version, error) = readVersion(executable: executable)
            if let error { issues.append("PostgreSQL：\(error)（\(executable)）") }
            addCandidate(executable: executable, actualExecutable: actual, version: version, source: .path, error: error)
        }

        if let cellar = homebrew.cellar {
            for formula in homebrew.formulas where formula.formula == "postgresql" || formula.formula.hasPrefix("postgresql@") {
                for version in formula.versions {
                    let executable = URL(fileURLWithPath: cellar, isDirectory: true)
                        .appendingPathComponent(formula.formula, isDirectory: true)
                        .appendingPathComponent(version, isDirectory: true)
                        .appendingPathComponent("bin", isDirectory: true)
                        .appendingPathComponent("postgres")
                        .path
                    let available = machine.isExecutableFile(atPath: executable)
                    let actual = available
                        ? standardizedPath(machine.resolvingSymlinksInPath(executable))
                        : standardizedPath(executable)
                    let error = available ? nil : "可执行文件不可用"
                    if let error { issues.append("PostgreSQL：\(error)（\(executable)）") }
                    addCandidate(
                        executable: executable,
                        actualExecutable: actual,
                        version: version,
                        source: .homebrew,
                        homebrewFormula: formula.formula,
                        error: error
                    )
                }
            }
        }

        let hasPostgreSQLFormula = homebrew.formulas.contains {
            $0.formula == "postgresql" || $0.formula.hasPrefix("postgresql@")
        }
        let homebrewProviderFailed = homebrewAvailabilityFailed
            || (homebrew.failureReason != nil && (homebrew.formulas.isEmpty || hasPostgreSQLFormula))
        if homebrewProviderFailed, let failure = homebrew.failureReason {
            issues.append("PostgreSQL Database Provider：Homebrew \(failure)")
        } else if homebrewProviderFailed {
            issues.append("PostgreSQL Database Provider：Homebrew 读取失败")
        }

        var listeningPaths: Set<String> = []
        var relevantPathFailure = false
        for service in localServices.services {
            if let executable = localServices.executablePaths[service.pid] {
                let actual = standardizedPath(machine.resolvingSymlinksInPath(executable))
                guard URL(fileURLWithPath: actual).lastPathComponent == "postgres" else { continue }
                listeningPaths.insert(actual)
                if !candidates.contains(where: { $0.actualExecutable == actual }) {
                    let (version, error) = readVersion(executable: actual)
                    if let error { issues.append("PostgreSQL：\(error)（\(actual)）") }
                    addCandidate(
                        executable: actual,
                        actualExecutable: actual,
                        version: version,
                        source: .localService,
                        error: error
                    )
                } else {
                    addCandidate(
                        executable: actual,
                        actualExecutable: actual,
                        version: nil,
                        source: .localService,
                        error: nil
                    )
                }
            } else if service.processName.caseInsensitiveCompare("postgres") == .orderedSame,
                      localServices.executablePathFailures.contains(service.pid) {
                relevantPathFailure = true
                issues.append("PostgreSQL：进程路径读取失败（PID \(service.pid)）")
            }
        }

        let installations = candidates.map { candidate in
            let listeningState: DatabaseListeningState = if listeningPaths.contains(candidate.actualExecutable) {
                .listening
            } else if !localServices.complete || relevantPathFailure {
                .unknown
            } else {
                .notListening
            }
            return DatabaseInstallation(
                id: candidate.actualExecutable,
                executable: candidate.executable,
                actualExecutable: candidate.executable == candidate.actualExecutable ? nil : candidate.actualExecutable,
                version: candidate.version,
                error: candidate.error,
                sources: candidate.sources,
                homebrewFormula: candidate.homebrewFormula,
                listeningState: listeningState
            )
        }
        let providerFailed = homebrewProviderFailed || !localServices.complete || relevantPathFailure
        let discoveryState: DatabaseDiscoveryState = if !installations.isEmpty {
            .discovered
        } else if providerFailed {
            .unknown
        } else {
            .notFound
        }
        let listeningState: DatabaseListeningState = if installations.contains(where: { $0.listeningState == .listening }) {
            .listening
        } else if installations.contains(where: { $0.listeningState == .unknown }) || providerFailed {
            .unknown
        } else {
            .notListening
        }
        return DatabaseInstallationOverview(
            id: "postgresql",
            name: "PostgreSQL",
            installations: installations,
            discoveryState: discoveryState,
            listeningState: listeningState
        )
    }

    private func postgreSQLVersion(from output: String) -> String? {
        guard let value = normalizedVersion(output) else { return nil }
        let prefix = "postgres (PostgreSQL) "
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : nil
    }

    private func mergeDatabaseCandidate(
        _ candidate: DatabaseCandidate,
        into candidates: inout [DatabaseCandidate]
    ) {
        guard let index = candidates.firstIndex(where: { $0.actualExecutable == candidate.actualExecutable }) else {
            candidates.append(candidate)
            return
        }
        candidates[index].version = candidates[index].version ?? candidate.version
        candidates[index].error = candidates[index].version == nil
            ? candidates[index].error ?? candidate.error
            : nil
        candidates[index].homebrewFormula = candidates[index].homebrewFormula ?? candidate.homebrewFormula
        let sources = candidates[index].sources + candidate.sources
        candidates[index].sources = DatabaseInstallationSource.allCases.filter(Set(sources).contains)
    }

    private func scanMongoDBAndRedis(
        path: [String],
        homebrew: HomebrewInventory,
        homebrewAvailabilityFailed: Bool,
        localServices: LocalServiceScan,
        notices: inout [String]
    ) -> [DatabaseInstallationOverview] {
        MongoDBOrRedis.allCases.map { database in
            var candidates: [DatabaseCandidate] = []

            func addCandidate(
                executable: String,
                actualExecutable: String,
                version: String?,
                source: DatabaseInstallationSource,
                homebrewFormula: String? = nil,
                notice: String?
            ) {
                mergeDatabaseCandidate(DatabaseCandidate(
                    executable: executable,
                    actualExecutable: actualExecutable,
                    version: version,
                    sources: [source],
                    homebrewFormula: homebrewFormula,
                    error: notice
                ), into: &candidates)
            }

            func readVersion(executable: String) -> (String?, String?) {
                let result = machine.command(executable: executable, arguments: ["--version"])
                let version = mongoDBOrRedisVersion(from: result.output, database: database)
                return result.status == 0 && !result.timedOut && version != nil
                    ? (version, nil)
                    : (nil, "版本读取失败")
            }

            for directory in path {
                let executable = absoluteExecutable(database.executable, directory: directory)
                guard machine.isExecutableFile(atPath: executable) else { continue }
                let actual = standardizedPath(machine.resolvingSymlinksInPath(executable))
                guard !candidates.contains(where: { $0.actualExecutable == actual }) else { continue }
                let (version, notice) = readVersion(executable: executable)
                if let notice { notices.append("\(database.name)：\(notice)（\(executable)）") }
                addCandidate(
                    executable: executable,
                    actualExecutable: actual,
                    version: version,
                    source: .path,
                    notice: notice
                )
            }

            if let cellar = homebrew.cellar {
                for formula in homebrew.formulas where formula.formula == database.formula
                    || formula.formula.hasPrefix("\(database.formula)@") {
                    for version in formula.versions {
                        let executable = URL(fileURLWithPath: cellar, isDirectory: true)
                            .appendingPathComponent(formula.formula, isDirectory: true)
                            .appendingPathComponent(version, isDirectory: true)
                            .appendingPathComponent("bin", isDirectory: true)
                            .appendingPathComponent(database.executable)
                            .path
                        let available = machine.isExecutableFile(atPath: executable)
                        let actual = available
                            ? standardizedPath(machine.resolvingSymlinksInPath(executable))
                            : standardizedPath(executable)
                        let notice = available ? nil : "可执行文件不可用"
                        if let notice { notices.append("\(database.name)：\(notice)（\(executable)）") }
                        addCandidate(
                            executable: executable,
                            actualExecutable: actual,
                            version: version,
                            source: .homebrew,
                            homebrewFormula: formula.formula,
                            notice: notice
                        )
                    }
                }
            }

            let hasFormula = homebrew.formulas.contains {
                $0.formula == database.formula || $0.formula.hasPrefix("\(database.formula)@")
            }
            let homebrewProviderFailed = homebrewAvailabilityFailed
                || (homebrew.failureReason != nil && (homebrew.formulas.isEmpty || hasFormula))
            if homebrewProviderFailed, let failure = homebrew.failureReason {
                notices.append("\(database.name) Database Provider：Homebrew \(failure)")
            } else if homebrewProviderFailed {
                notices.append("\(database.name) Database Provider：Homebrew 读取失败")
            }

            var listeningPaths: Set<String> = []
            var relevantPathFailure = false
            for service in localServices.services {
                guard let executable = localServices.executablePaths[service.pid] else {
                    if service.processName.caseInsensitiveCompare(database.executable) == .orderedSame,
                       localServices.executablePathFailures.contains(service.pid) {
                        relevantPathFailure = true
                        notices.append("\(database.name)：进程路径读取失败（PID \(service.pid)）")
                    }
                    continue
                }
                let actual = standardizedPath(machine.resolvingSymlinksInPath(executable))
                guard URL(fileURLWithPath: actual).lastPathComponent.caseInsensitiveCompare(database.executable) == .orderedSame else {
                    continue
                }
                listeningPaths.insert(actual)
                if candidates.contains(where: { $0.actualExecutable == actual }) {
                    addCandidate(
                        executable: actual,
                        actualExecutable: actual,
                        version: nil,
                        source: .localService,
                        notice: nil
                    )
                } else {
                    let (version, notice) = readVersion(executable: actual)
                    if let notice { notices.append("\(database.name)：\(notice)（\(actual)）") }
                    addCandidate(
                        executable: actual,
                        actualExecutable: actual,
                        version: version,
                        source: .localService,
                        notice: notice
                    )
                }
            }

            let installations = candidates.map { candidate in
                let listeningState: DatabaseListeningState = if listeningPaths.contains(candidate.actualExecutable) {
                    .listening
                } else if !localServices.complete || relevantPathFailure {
                    .unknown
                } else {
                    .notListening
                }
                return DatabaseInstallation(
                    id: candidate.actualExecutable,
                    executable: candidate.executable,
                    actualExecutable: candidate.executable == candidate.actualExecutable ? nil : candidate.actualExecutable,
                    version: candidate.version,
                    error: candidate.error,
                    sources: candidate.sources,
                    homebrewFormula: candidate.homebrewFormula,
                    listeningState: listeningState
                )
            }
            let providerFailed = homebrewProviderFailed || !localServices.complete || relevantPathFailure
            let discoveryState: DatabaseDiscoveryState = if !installations.isEmpty {
                .discovered
            } else if providerFailed {
                .unknown
            } else {
                .notFound
            }
            let listeningState: DatabaseListeningState = if installations.contains(where: { $0.listeningState == .listening }) {
                .listening
            } else if installations.contains(where: { $0.listeningState == .unknown }) || providerFailed {
                .unknown
            } else {
                .notListening
            }
            return DatabaseInstallationOverview(
                id: database.id,
                name: database.name,
                installations: installations,
                discoveryState: discoveryState,
                listeningState: listeningState
            )
        }
    }

    private func mongoDBOrRedisVersion(from output: String, database: MongoDBOrRedis) -> String? {
        guard let value = normalizedVersion(output) else { return nil }
        switch database {
        case .mongodb:
            let prefix = "db version v"
            guard value.hasPrefix(prefix) else { return nil }
            return value.dropFirst(prefix.count).split(whereSeparator: \.isWhitespace).first.map(String.init)
        case .redis:
            return value.split(whereSeparator: \.isWhitespace)
                .first { $0.hasPrefix("v=") }
                .map { String($0.dropFirst(2)) }
        }
    }

    private func scanMySQLFamily(
        path: [String],
        homebrew: HomebrewInventory,
        homebrewAvailabilityFailed: Bool,
        localServices: LocalServiceScan,
        issues: inout [String]
    ) -> [DatabaseInstallationOverview] {
        var candidates: [MySQLFamilyDatabase: [DatabaseCandidate]] = [:]
        var listeningPaths: [MySQLFamilyDatabase: Set<String>] = [:]
        var relevantPathFailures: Set<MySQLFamilyDatabase> = []
        var classificationFailures: Set<MySQLFamilyDatabase> = []
        var reportedAmbiguousPaths: Set<String> = []

        func addCandidate(
            database: MySQLFamilyDatabase,
            executable: String,
            actualExecutable: String,
            version: String?,
            source: DatabaseInstallationSource,
            homebrewFormula: String? = nil,
            error: String?
        ) {
            var databaseCandidates = candidates[database, default: []]
            mergeDatabaseCandidate(DatabaseCandidate(
                executable: executable,
                actualExecutable: actualExecutable,
                version: version,
                sources: [source],
                homebrewFormula: homebrewFormula,
                error: error
            ), into: &databaseCandidates)
            candidates[database] = databaseCandidates
        }

        for directory in path {
            for executableName in ["mysqld", "mariadbd"] {
                let executable = absoluteExecutable(executableName, directory: directory)
                guard machine.isExecutableFile(atPath: executable) else { continue }
                let actual = standardizedPath(machine.resolvingSymlinksInPath(executable))
                let knownDatabase: MySQLFamilyDatabase? = URL(fileURLWithPath: actual).lastPathComponent == "mariadbd"
                    ? .mariadb
                    : nil
                let result = machine.command(executable: executable, arguments: ["--version"])
                let details = mysqlFamilyVersion(from: result, knownDatabase: knownDatabase)
                guard let database = details.database else {
                    classificationFailures.formUnion(MySQLFamilyDatabase.allCases)
                    if reportedAmbiguousPaths.insert(actual).inserted {
                        issues.append("MySQL/MariaDB：无法分类 mysqld（\(executable)）")
                    }
                    continue
                }
                if let error = details.error { issues.append("\(database.name)：\(error)（\(executable)）") }
                addCandidate(
                    database: database,
                    executable: executable,
                    actualExecutable: actual,
                    version: details.version,
                    source: .path,
                    error: details.error
                )
            }
        }

        if let cellar = homebrew.cellar {
            for database in MySQLFamilyDatabase.allCases {
                for formula in homebrew.formulas where formula.formula == database.formula
                    || formula.formula.hasPrefix("\(database.formula)@") {
                    for version in formula.versions {
                        let directory = URL(fileURLWithPath: cellar, isDirectory: true)
                            .appendingPathComponent(formula.formula, isDirectory: true)
                            .appendingPathComponent(version, isDirectory: true)
                            .appendingPathComponent("bin", isDirectory: true)
                        let executablePaths = database.executableNames.map {
                            directory.appendingPathComponent($0).path
                        }
                        let executable = executablePaths.first(where: { machine.isExecutableFile(atPath: $0) })
                            ?? executablePaths[0]
                        let available = machine.isExecutableFile(atPath: executable)
                        let actual = available
                            ? standardizedPath(machine.resolvingSymlinksInPath(executable))
                            : standardizedPath(executable)
                        let error = available ? nil : "可执行文件不可用"
                        if let error { issues.append("\(database.name)：\(error)（\(executable)）") }
                        addCandidate(
                            database: database,
                            executable: executable,
                            actualExecutable: actual,
                            version: version,
                            source: .homebrew,
                            homebrewFormula: formula.formula,
                            error: error
                        )
                    }
                }
            }
        }

        var homebrewProviderFailures: Set<MySQLFamilyDatabase> = []
        for database in MySQLFamilyDatabase.allCases {
            let hasFormula = homebrew.formulas.contains {
                $0.formula == database.formula || $0.formula.hasPrefix("\(database.formula)@")
            }
            let providerFailed = homebrewAvailabilityFailed
                || (homebrew.failureReason != nil && (homebrew.formulas.isEmpty || hasFormula))
            guard providerFailed else { continue }
            homebrewProviderFailures.insert(database)
            if let failure = homebrew.failureReason {
                issues.append("\(database.name) Database Provider：Homebrew \(failure)")
            } else {
                issues.append("\(database.name) Database Provider：Homebrew 读取失败")
            }
        }

        for service in localServices.services {
            guard let executable = localServices.executablePaths[service.pid] else {
                guard localServices.executablePathFailures.contains(service.pid) else { continue }
                switch service.processName.lowercased() {
                case "mariadbd":
                    relevantPathFailures.insert(.mariadb)
                    issues.append("MariaDB：进程路径读取失败（PID \(service.pid)）")
                case "mysqld":
                    relevantPathFailures.formUnion(MySQLFamilyDatabase.allCases)
                    issues.append("MySQL/MariaDB：进程路径读取失败（PID \(service.pid)）")
                default:
                    continue
                }
                continue
            }

            let actual = standardizedPath(machine.resolvingSymlinksInPath(executable))
            let executableName = URL(fileURLWithPath: actual).lastPathComponent.lowercased()
            guard executableName == "mysqld" || executableName == "mariadbd" else { continue }
            let existingDatabase = MySQLFamilyDatabase.allCases.first {
                candidates[$0, default: []].contains { $0.actualExecutable == actual }
            }
            let details: (database: MySQLFamilyDatabase?, version: String?, error: String?)
            if let existingDatabase {
                details = (existingDatabase, nil, nil)
            } else {
                let knownDatabase: MySQLFamilyDatabase? = executableName == "mariadbd" ? .mariadb : nil
                details = mysqlFamilyVersion(
                    from: machine.command(executable: actual, arguments: ["--version"]),
                    knownDatabase: knownDatabase
                )
            }
            guard let database = details.database else {
                classificationFailures.formUnion(MySQLFamilyDatabase.allCases)
                if reportedAmbiguousPaths.insert(actual).inserted {
                    issues.append("MySQL/MariaDB：无法分类 mysqld（\(actual)）")
                }
                continue
            }
            listeningPaths[database, default: []].insert(actual)
            if let error = details.error { issues.append("\(database.name)：\(error)（\(actual)）") }
            addCandidate(
                database: database,
                executable: actual,
                actualExecutable: actual,
                version: details.version,
                source: .localService,
                error: details.error
            )
        }

        return MySQLFamilyDatabase.allCases.map { database in
            let installations = candidates[database, default: []].map { candidate in
                let listeningState: DatabaseListeningState = if listeningPaths[database, default: []]
                    .contains(candidate.actualExecutable) {
                    .listening
                } else if !localServices.complete || relevantPathFailures.contains(database) {
                    .unknown
                } else {
                    .notListening
                }
                return DatabaseInstallation(
                    id: candidate.actualExecutable,
                    executable: candidate.executable,
                    actualExecutable: candidate.executable == candidate.actualExecutable ? nil : candidate.actualExecutable,
                    version: candidate.version,
                    error: candidate.error,
                    sources: candidate.sources,
                    homebrewFormula: candidate.homebrewFormula,
                    listeningState: listeningState
                )
            }
            let providerFailed = homebrewProviderFailures.contains(database)
                || !localServices.complete
                || relevantPathFailures.contains(database)
                || classificationFailures.contains(database)
            let discoveryState: DatabaseDiscoveryState = if !installations.isEmpty {
                .discovered
            } else if providerFailed {
                .unknown
            } else {
                .notFound
            }
            let listeningState: DatabaseListeningState = if installations.contains(where: { $0.listeningState == .listening }) {
                .listening
            } else if installations.contains(where: { $0.listeningState == .unknown })
                || !localServices.complete
                || relevantPathFailures.contains(database)
                || homebrewProviderFailures.contains(database)
                || (installations.isEmpty && classificationFailures.contains(database)) {
                .unknown
            } else {
                .notListening
            }
            return DatabaseInstallationOverview(
                id: database.id,
                name: database.name,
                installations: installations,
                discoveryState: discoveryState,
                listeningState: listeningState
            )
        }
    }

    private func mysqlFamilyVersion(
        from result: MachineCommandResult,
        knownDatabase: MySQLFamilyDatabase?
    ) -> (database: MySQLFamilyDatabase?, version: String?, error: String?) {
        guard result.status == 0, !result.timedOut, let value = normalizedVersion(result.output) else {
            return (knownDatabase, nil, knownDatabase == nil ? nil : "版本读取失败")
        }
        let fields = value.split(whereSeparator: \.isWhitespace)
        guard let marker = fields.firstIndex(where: { $0.caseInsensitiveCompare("Ver") == .orderedSame }),
              fields.indices.contains(marker + 1) else {
            return (knownDatabase, nil, knownDatabase == nil ? nil : "版本读取失败")
        }
        let productDetails = fields[(marker + 1)...].joined(separator: " ").lowercased()
        let mentionsMySQL = productDetails.range(of: #"\bmysql\b"#, options: .regularExpression) != nil
        let database = knownDatabase
            ?? (productDetails.contains("mariadb") ? .mariadb : mentionsMySQL ? .mysql : nil)
        guard let database else { return (nil, nil, nil) }
        let versionIndex = fields.indices.contains(marker + 3)
            && fields[marker + 2].caseInsensitiveCompare("Distrib") == .orderedSame
            ? marker + 3
            : marker + 1
        let version = fields[versionIndex].split(separator: "-").first.map(String.init)
        guard let version, version.first?.isNumber == true else { return (database, nil, "版本读取失败") }
        return (database, version, nil)
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
                isInPath: true,
                sources: inferredRuntimeSources(executable: executable, actualExecutable: actual)
            ))
        }

        for installation in providers.sorted(by: providerInstallationOrder) {
            let executable = standardizedPath(installation.executable)
            let available = machine.isExecutableFile(atPath: executable)
            let actual = available ? standardizedPath(machine.resolvingSymlinksInPath(executable)) : executable
            if let index = installations.firstIndex(where: { $0.id == actual }) {
                installations[index].sources = mergedSources(installations[index].sources, installation.source)
                continue
            }
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
                isInPath: false,
                sources: [installation.source]
            ))
        }

        return RuntimeSnapshot(id: definition.id, name: definition.name, installations: installations)
    }

    private func scanPackageManagers(path: [String], issues: inout [String]) -> [PackageManagerSnapshot] {
        packageManagerDefinitions.map { definition in
            guard let executable = path.lazy.map({ absoluteExecutable(definition.id, directory: $0) })
                .first(where: machine.isExecutableFile) else {
                return PackageManagerSnapshot(
                    id: definition.id,
                    name: definition.name,
                    executable: nil,
                    actualExecutable: nil,
                    version: nil,
                    state: .unavailable,
                    error: nil
                )
            }
            let actual = standardizedPath(machine.resolvingSymlinksInPath(executable))
            if ["pnpm", "yarn"].contains(definition.id), actual.lowercased().contains("/corepack/") {
                return PackageManagerSnapshot(
                    id: definition.id,
                    name: definition.name,
                    executable: executable,
                    actualExecutable: actual == executable ? nil : actual,
                    version: nil,
                    state: .configured,
                    error: nil
                )
            }
            let result = machine.command(executable: executable, arguments: ["--version"])
            let version = result.status == 0 && !result.timedOut ? packageManagerVersion(result.output) : nil
            let error = version == nil ? (result.timedOut ? "命令超时" : "版本读取失败") : nil
            if let error { issues.append("包管理器：\(definition.name) \(error)") }
            return PackageManagerSnapshot(
                id: definition.id,
                name: definition.name,
                executable: executable,
                actualExecutable: actual == executable ? nil : actual,
                version: version,
                state: version == nil ? .failed : .available,
                error: error
            )
        }
    }

    private func packageManagerVersion(_ output: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:^|\s)v?([0-9]+(?:\.[0-9]+){1,2}(?:-[0-9A-Za-z.-]+)?)"#
        ) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let versionRange = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[versionRange])
    }

    private func scanMiseRuntimes(path: [String], issues: inout [String]) -> [RuntimeProviderInstallation] {
        let candidates = path.map { absoluteExecutable("mise", directory: $0) }
            + (machine.environment["HOME"].map { ["\($0)/.local/bin/mise"] } ?? [])
            + ["/opt/homebrew/bin/mise", "/usr/local/bin/mise"]
        guard let executable = candidates.first(where: { machine.isExecutableFile(atPath: $0) }) else { return [] }
        let result = machine.command(executable: executable, arguments: ["ls", "--installed", "--json"])
        guard result.status == 0, !result.timedOut else {
            issues.append("mise 版本来源：\(result.timedOut ? "命令超时" : "读取失败")")
            return []
        }
        guard let data = result.output.data(using: .utf8),
              let installed = try? JSONDecoder().decode([String: [MiseInstallation]].self, from: data) else {
            issues.append("mise 版本来源：输出解析失败")
            return []
        }
        return runtimeDefinitions.flatMap { definition in
            installed[definition.id, default: []].map { installation in
                RuntimeProviderInstallation(
                    runtimeID: definition.id,
                    version: installation.version,
                    executable: standardizedPath("\(installation.installPath)/bin/\(definition.executable)"),
                    source: .mise
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
                issues.append("nvm 版本来源：读取失败（\(versionRoot)）")
            }
            return []
        }
        return entries.compactMap { entry in
            let directory = "\(versionRoot)/\(entry)"
            guard let version = nvmVersion(from: directory) else { return nil }
            return RuntimeProviderInstallation(
                runtimeID: "node",
                version: version,
                executable: "\(directory)/bin/node",
                source: .nvm
            )
        }
    }

    private func scanUVInstallations(path: [String], issues: inout [String]) -> [RuntimeProviderInstallation] {
        let candidates = path.map { absoluteExecutable("uv", directory: $0) }
            + (machine.environment["HOME"].map { ["\($0)/.local/bin/uv"] } ?? [])
            + ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        guard let executable = candidates.first(where: { machine.isExecutableFile(atPath: $0) }) else { return [] }
        let result = machine.command(executable: executable, arguments: ["python", "list", "--only-installed", "--output-format", "json"])
        guard result.status == 0, !result.timedOut else {
            issues.append("uv Python 版本来源：\(result.timedOut ? "命令超时" : "读取失败")")
            return []
        }
        guard let data = result.output.data(using: .utf8),
              let installed = try? JSONDecoder().decode([UVInstallation].self, from: data) else {
            issues.append("uv Python 版本来源：输出解析失败")
            return []
        }
        return installed.map {
            RuntimeProviderInstallation(
                runtimeID: "python",
                version: $0.version,
                executable: standardizedPath($0.path),
                source: .uv
            )
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
            issues.append("pyenv Python 版本来源：\(result.timedOut ? "命令超时" : "读取失败")")
            return []
        }
        return result.output.split(whereSeparator: \.isNewline).compactMap { line in
            let version = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !version.isEmpty, version != "system" else { return nil }
            return RuntimeProviderInstallation(
                runtimeID: "python",
                version: version,
                executable: standardizedPath("\(root)/versions/\(version)/bin/python3"),
                source: .pyenv
            )
        }
    }

    private func scanJavaHomeInstallations(issues: inout [String]) -> [RuntimeProviderInstallation] {
        let executable = "/usr/libexec/java_home"
        guard machine.isExecutableFile(atPath: executable) else { return [] }
        let result = machine.command(executable: executable, arguments: ["-V"])
        guard result.status == 0, !result.timedOut else {
            issues.append("java_home Java 版本来源：\(result.timedOut ? "命令超时" : "读取失败")")
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
            return RuntimeProviderInstallation(runtimeID: "java", version: version, executable: java, source: .javaHome)
        }
        guard !installations.isEmpty else {
            issues.append("java_home Java 版本来源：输出解析失败")
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
            issues.append("rustup Rust 版本来源：\(result.timedOut ? "命令超时" : "读取失败")")
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
                executable: standardizedPath("\(root)/toolchains/\(toolchain)/bin/rustc"),
                source: .rustup
            )
        }
        guard !installations.isEmpty else {
            issues.append("rustup Rust 版本来源：输出解析失败")
            return []
        }
        return installations
    }

    private func scanRbenvInstallations(path: [String], issues: inout [String]) -> [RuntimeProviderInstallation] {
        let root = machine.environment["RBENV_ROOT"] ?? machine.environment["HOME"].map { "\($0)/.rbenv" }
        guard let root, root.hasPrefix("/") else { return [] }
        let candidates = path.map { absoluteExecutable("rbenv", directory: $0) }
            + ["\(root)/bin/rbenv", "/opt/homebrew/bin/rbenv", "/usr/local/bin/rbenv"]
        guard let executable = candidates.first(where: { machine.isExecutableFile(atPath: $0) }) else { return [] }

        let result = machine.command(executable: executable, arguments: ["versions", "--bare"])
        guard result.status == 0, !result.timedOut else {
            issues.append("rbenv Ruby 版本来源：\(result.timedOut ? "命令超时" : "读取失败")")
            return []
        }
        let lines = result.output.split(whereSeparator: \.isNewline)
        let installations = lines.compactMap { line -> RuntimeProviderInstallation? in
            let version = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !version.isEmpty, version != "system" else { return nil }
            return RuntimeProviderInstallation(
                runtimeID: "ruby",
                version: version,
                executable: standardizedPath("\(root)/versions/\(version)/bin/ruby"),
                source: .rbenv
            )
        }
        guard !lines.isEmpty else {
            issues.append("rbenv Ruby 版本来源：输出解析失败")
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

    private func scanHomebrewInventory(executable: String, issues: inout [String]) -> HomebrewInventory {
        let versionsResult = machine.command(executable: executable, arguments: ["list", "--formula", "--versions"])
        guard versionsResult.status == 0, !versionsResult.timedOut else {
            let failure = versionsResult.timedOut ? "命令超时" : "读取失败"
            issues.append("Homebrew 版本来源：\(failure)")
            return HomebrewInventory(formulas: [], cellar: nil, failureReason: failure)
        }

        let formulas = versionsResult.output.split(whereSeparator: \.isNewline).compactMap { line -> HomebrewFormulaInstallation? in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count > 1, let formula = fields.first else { return nil }
            let isRuntime = runtimeDefinitions.contains {
                formula == $0.homebrewFormula || formula.hasPrefix("\($0.homebrewFormula)@")
            }
            let isDatabase = ["postgresql", "mysql", "mariadb", "mongodb-community", "redis"].contains {
                formula == $0 || formula.hasPrefix("\($0)@")
            }
            guard isRuntime || isDatabase else { return nil }
            return HomebrewFormulaInstallation(formula: formula, versions: Array(fields.dropFirst()))
        }
        guard !formulas.isEmpty else { return .empty }

        let cellarResult = machine.command(executable: executable, arguments: ["--cellar"])
        guard cellarResult.status == 0,
              !cellarResult.timedOut,
              let cellar = normalizedVersion(cellarResult.output) else {
            let failure = cellarResult.timedOut ? "命令超时" : "读取失败"
            issues.append("Homebrew 版本来源：\(failure)")
            return HomebrewInventory(formulas: formulas, cellar: nil, failureReason: failure)
        }

        return HomebrewInventory(formulas: formulas, cellar: cellar, failureReason: nil)
    }

    private func scanHomebrewRuntimes(inventory: HomebrewInventory) -> [RuntimeProviderInstallation] {
        guard let cellar = inventory.cellar else { return [] }
        return inventory.formulas.flatMap { installation -> [RuntimeProviderInstallation] in
            guard let definition = runtimeDefinitions.first(where: {
                installation.formula == $0.homebrewFormula || installation.formula.hasPrefix("\($0.homebrewFormula)@")
            }) else { return [] }
            let formula = installation.formula
            let runtimeExecutable = definition.id == "python" && formula.hasPrefix("python@")
                ? "python\(formula.dropFirst("python@".count))"
                : definition.executable
            return installation.versions.map { version in
                RuntimeProviderInstallation(
                    runtimeID: definition.id,
                    version: version,
                    executable: URL(fileURLWithPath: cellar, isDirectory: true)
                        .appendingPathComponent(formula, isDirectory: true)
                        .appendingPathComponent(version, isDirectory: true)
                        .appendingPathComponent("bin", isDirectory: true)
                        .appendingPathComponent(runtimeExecutable)
                        .path,
                    source: .homebrew
                )
            }
        }
    }

    private func inferredRuntimeSources(
        executable: String,
        actualExecutable: String
    ) -> [RuntimeInstallationSource] {
        let paths = [standardizedPath(executable), actualExecutable]
        var sources: [RuntimeInstallationSource] = []

        if paths.contains(where: isSystemExecutable) { sources.append(.system) }

        let home = machine.environment["HOME"]
        let roots: [(RuntimeInstallationSource, [String])] = [
            (.homebrew, ["/opt/homebrew/Cellar", "/usr/local/Cellar"]),
            (.mise, absoluteRoots(
                machine.environment["MISE_DATA_DIR"],
                machine.environment["XDG_DATA_HOME"].map { "\($0)/mise" },
                home.map { "\($0)/.local/share/mise" }
            )),
            (.nvm, absoluteRoots(machine.environment["NVM_DIR"], home.map { "\($0)/.nvm" })),
            (.uv, absoluteRoots(
                machine.environment["UV_PYTHON_INSTALL_DIR"],
                machine.environment["XDG_DATA_HOME"].map { "\($0)/uv/python" },
                home.map { "\($0)/.local/share/uv/python" }
            )),
            (.pyenv, absoluteRoots(machine.environment["PYENV_ROOT"], home.map { "\($0)/.pyenv" })),
            (.rustup, absoluteRoots(
                machine.environment["RUSTUP_HOME"],
                home.map { "\($0)/.rustup" },
                machine.environment["CARGO_HOME"],
                home.map { "\($0)/.cargo" }
            )),
            (.rbenv, absoluteRoots(machine.environment["RBENV_ROOT"], home.map { "\($0)/.rbenv" })),
        ]

        for (source, directories) in roots where paths.contains(where: { path in
            directories.contains(where: { isPath(path, inside: $0) })
        }) {
            sources.append(source)
        }

        return sources.isEmpty ? [.path] : sortedSources(sources)
    }

    private func absoluteRoots(_ roots: String?...) -> [String] {
        roots.compactMap { root in
            guard let root, root.hasPrefix("/") else { return nil }
            return standardizedPath(root)
        }
    }

    private func isSystemExecutable(_ path: String) -> Bool {
        ["/bin", "/sbin", "/usr/bin", "/usr/sbin", "/System", "/Library/Apple/usr/bin"]
            .contains { isPath(path, inside: $0) }
    }

    private func isPath(_ path: String, inside directory: String) -> Bool {
        path == directory || path.hasPrefix(directory + "/")
    }

    private func mergedSources(
        _ sources: [RuntimeInstallationSource],
        _ source: RuntimeInstallationSource
    ) -> [RuntimeInstallationSource] {
        sortedSources((sources.filter { $0 != .path }) + [source])
    }

    private func sortedSources(_ sources: [RuntimeInstallationSource]) -> [RuntimeInstallationSource] {
        RuntimeInstallationSource.allCases.filter(Set(sources).contains)
    }

    private func providerInstallationOrder(
        _ lhs: RuntimeProviderInstallation,
        _ rhs: RuntimeProviderInstallation
    ) -> Bool {
        let versionOrder = lhs.version.compare(rhs.version, options: [.numeric, .caseInsensitive])
        return versionOrder == .orderedSame ? lhs.executable < rhs.executable : versionOrder == .orderedDescending
    }

    private func resolveMachineToolSearchPath(notices: inout [String]) -> MachineToolSearchPathSnapshot {
        let fallback = normalizedPathEntries(from: machine.environment["PATH"] ?? "") ?? []
        guard let shell = machine.defaultLoginShellPath,
              shell.hasPrefix("/"),
              machine.isExecutableFile(atPath: shell) else {
            appendMachineToolSearchPathFallbackNotice(reason: "Default Login Shell 不可用", notices: &notices)
            return MachineToolSearchPathSnapshot(entries: fallback, source: .appProcessFallback)
        }

        let token = "DEVENV_MACHINE_TOOL_PATH_V1_\(UUID().uuidString)"
        let marker = "\u{1E}\(token)\u{1F}"
        let result = machine.captureMachineToolSearchPath(
            usingLoginShell: shell,
            token: token,
            timeout: loginShellPathTimeout
        )

        let reason: String
        if result.timedOut {
            reason = "Default Login Shell 初始化超时"
        } else if result.status != 0 {
            reason = "Default Login Shell 初始化失败"
        } else if let value = framedPathValue(from: result.output, marker: marker),
                  let entries = normalizedPathEntries(from: value) {
            return MachineToolSearchPathSnapshot(entries: entries, source: .defaultLoginShell)
        } else {
            reason = "Default Login Shell 返回的 PATH 无效"
        }

        appendMachineToolSearchPathFallbackNotice(reason: reason, notices: &notices)
        return MachineToolSearchPathSnapshot(entries: fallback, source: .appProcessFallback)
    }

    private func framedPathValue(from output: String, marker: String) -> String? {
        let components = output.components(separatedBy: marker)
        guard components.count == 3 else { return nil }
        return components[1]
    }

    private func normalizedPathEntries(from value: String) -> [String]? {
        guard !value.isEmpty, value.utf8.count <= 65_536 else { return nil }
        guard value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { return nil }

        let base = URL(fileURLWithPath: machine.currentDirectoryPath, isDirectory: true)
        var entries: [String] = []
        for component in value.split(separator: ":", omittingEmptySubsequences: false) {
            let rawPath = component.isEmpty ? machine.currentDirectoryPath : String(component)
            let normalized = URL(fileURLWithPath: rawPath, relativeTo: base).standardizedFileURL.path
            guard normalized.hasPrefix("/") else { return nil }
            entries.append(normalized)
        }
        return entries
    }

    private func appendMachineToolSearchPathFallbackNotice(reason: String, notices: inout [String]) {
        notices.append(
            "Machine Tool Search PATH：\(reason)，已回退到 App 进程 PATH；请检查 Shell 启动配置后重新扫描"
        )
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
        guard (try? decoder.decode(Header.self, from: data).schemaVersion) == MachineSnapshot.currentSchemaVersion else {
            return nil
        }
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
