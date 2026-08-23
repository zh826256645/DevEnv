import Foundation

struct MachineSnapshot: Codable, Sendable {
    static let localServiceTimeoutNotice = "本地服务：命令超时"
    static let localServiceFailureNotice = "本地服务：读取失败"

    let schemaVersion: Int
    let scannedAt: Date
    let system: SystemSnapshot
    let localServices: [LocalServiceSnapshot]
    let path: [String]
    let runtimes: [RuntimeSnapshot]
    let homebrew: HomebrewSnapshot
    let gitCLI: GitCLISnapshot
    let gitLFS: GitLFSSnapshot?
    let userGitConfiguration: UserGitConfigurationSnapshot?
    let gitSigningConfiguration: GitSigningConfigurationSnapshot?
    let gitCredentialHelpers: [String]?
    let githubAuthenticationConfiguration: GitHubAuthenticationConfigurationSnapshot
    let issues: [String]

    var localServiceScanNotice: String? {
        issues.first { $0 == Self.localServiceTimeoutNotice || $0 == Self.localServiceFailureNotice }
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

struct LocalServiceSnapshot: Codable, Identifiable, Sendable {
    var id: Int32 { pid }

    let processName: String
    let pid: Int32
    let bindings: [ListenerBinding]
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
    func fileExists(atPath path: String) -> Bool
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

    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
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
        let localServices = scanLocalServices(issues: &issues)

        let homebrew = scanHomebrew(path: path, issues: &issues)
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
        let homebrewInstallations = homebrew.available ? homebrew.executable.map {
            scanHomebrewRuntimes(executable: $0, issues: &issues)
        } ?? [] : []
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
        let snapshot = MachineSnapshot(
            schemaVersion: 7,
            scannedAt: Date(),
            system: system,
            localServices: localServices,
            path: path,
            runtimes: runtimes,
            homebrew: homebrew,
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

    private func scanLocalServices(issues: inout [String]) -> [LocalServiceSnapshot] {
        let result = machine.command(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcftn"]
        )
        if result.timedOut {
            issues.append(MachineSnapshot.localServiceTimeoutNotice)
            return []
        }
        let hasNoMatches = result.status == 1 && result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard result.status == 0 || hasNoMatches else {
            issues.append(MachineSnapshot.localServiceFailureNotice)
            return []
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

        return services.compactMap { pid, service -> LocalServiceSnapshot? in
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

    private func scanRbenvInstallations(path: [String], issues: inout [String]) -> [RuntimeProviderInstallation] {
        let root = machine.environment["RBENV_ROOT"] ?? machine.environment["HOME"].map { "\($0)/.rbenv" }
        guard let root, root.hasPrefix("/") else { return [] }
        let candidates = path.map { absoluteExecutable("rbenv", directory: $0) }
            + ["\(root)/bin/rbenv", "/opt/homebrew/bin/rbenv", "/usr/local/bin/rbenv"]
        guard let executable = candidates.first(where: { machine.isExecutableFile(atPath: $0) }) else { return [] }

        let result = machine.command(executable: executable, arguments: ["versions", "--bare"])
        guard result.status == 0, !result.timedOut else {
            issues.append("rbenv Ruby Runtime Provider：\(result.timedOut ? "命令超时" : "读取失败")")
            return []
        }
        let lines = result.output.split(whereSeparator: \.isNewline)
        let installations = lines.compactMap { line -> RuntimeProviderInstallation? in
            let version = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !version.isEmpty, version != "system" else { return nil }
            return RuntimeProviderInstallation(
                runtimeID: "ruby",
                version: version,
                executable: standardizedPath("\(root)/versions/\(version)/bin/ruby")
            )
        }
        guard !lines.isEmpty else {
            issues.append("rbenv Ruby Runtime Provider：输出解析失败")
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
            let runtimeExecutable = definition.id == "python" && formula.hasPrefix("python@")
                ? "python\(formula.dropFirst("python@".count))"
                : definition.executable
            return versions.map { version in
                RuntimeProviderInstallation(
                    runtimeID: definition.id,
                    version: version,
                    executable: URL(fileURLWithPath: cellar, isDirectory: true)
                        .appendingPathComponent(formula, isDirectory: true)
                        .appendingPathComponent(version, isDirectory: true)
                        .appendingPathComponent("bin", isDirectory: true)
                        .appendingPathComponent(runtimeExecutable)
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
        guard (try? decoder.decode(Header.self, from: data).schemaVersion) == 7 else { return nil }
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
