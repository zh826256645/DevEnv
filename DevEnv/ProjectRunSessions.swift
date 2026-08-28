import AppKit
import Combine
import Darwin
import Foundation
import SwiftTerm

enum ProjectRunSessionState: Equatable, Sendable {
    case inactive
    case starting
    case running
    case stopping
    case exited(Int32)
    case launchFailed(String)

    var isLive: Bool {
        switch self {
        case .starting, .running, .stopping: true
        case .inactive, .exited, .launchFailed: false
        }
    }
}

struct ProjectRunTrustRequest: Equatable, Sendable {
    let configuration: ProjectRunConfiguration
    let projectRoot: String
    let command: String
    let workingDirectory: String
}

enum ProjectRunActionResult: Equatable, Sendable {
    case needsTrust(ProjectRunTrustRequest)
    case started
    case rejected(String)
}

@MainActor
protocol ProjectRunProcessEngine: AnyObject {
    var terminalView: NSView { get }
    var onExit: ((Int32?) -> Void)? { get set }

    func start(
        executable: String,
        arguments: [String],
        loginName: String,
        workingDirectory: String
    ) throws
    func signalProcessGroups(_ signal: Int32)
}

@MainActor
protocol ProjectRunEngineFactory {
    func makeEngine() -> any ProjectRunProcessEngine
}

protocol ProjectRunShellProviding {
    func defaultLoginShell() throws -> String
}

@MainActor
protocol ProjectRunScheduling {
    func schedule(after delay: Duration, _ action: @escaping () -> Void)
}

enum ProjectRunLaunchError: LocalizedError {
    case defaultLoginShellUnavailable
    case processDidNotStart

    var errorDescription: String? {
        switch self {
        case .defaultLoginShellUnavailable: "Default Login Shell 不可用或不可执行"
        case .processDidNotStart: "PTY 进程启动失败"
        }
    }
}

struct LiveProjectRunShellProvider: ProjectRunShellProviding {
    func defaultLoginShell() throws -> String {
        guard let shellPointer = getpwuid(getuid())?.pointee.pw_shell else {
            throw ProjectRunLaunchError.defaultLoginShellUnavailable
        }
        let shell = URL(fileURLWithPath: String(cString: shellPointer)).standardizedFileURL.path
        guard NSString(string: shell).isAbsolutePath,
              FileManager.default.isExecutableFile(atPath: shell) else {
            throw ProjectRunLaunchError.defaultLoginShellUnavailable
        }
        return shell
    }
}

@MainActor
struct MainProjectRunScheduler: ProjectRunScheduling {
    func schedule(after delay: Duration, _ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

@MainActor
struct SwiftTermProjectRunEngineFactory: ProjectRunEngineFactory {
    func makeEngine() -> any ProjectRunProcessEngine {
        SwiftTermProjectRunEngine()
    }
}

@MainActor
final class SwiftTermProjectRunEngine: NSObject, ProjectRunProcessEngine, @preconcurrency LocalProcessTerminalViewDelegate {
    let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
    var terminalView: NSView { terminal }
    var onExit: ((Int32?) -> Void)?
    private var processMonitor: DispatchSourceProcess?
    private var monitoredPID: pid_t?
    private var trackedProcessGroups: Set<pid_t> = []
    private var trackedSessionID: pid_t?

    override init() {
        super.init()
        terminal.processDelegate = self
    }

    func start(
        executable: String,
        arguments: [String],
        loginName: String,
        workingDirectory: String
    ) throws {
        let previousPID = terminal.process.shellPid
        terminal.startProcess(
            executable: executable,
            args: arguments,
            execName: loginName,
            currentDirectory: workingDirectory
        )
        let pid = terminal.process.shellPid
        guard pid > 0, pid != previousPID || terminal.process.running else {
            throw ProjectRunLaunchError.processDidNotStart
        }
        trackedProcessGroups = [pid]
        trackedSessionID = pid
        monitor(pid)
    }

    func signalProcessGroups(_ signal: Int32) {
        let rootPID = terminal.process.shellPid
        if rootPID > 0 {
            trackedProcessGroups.formUnion(processGroups(rootedAt: rootPID))
        }
        if let trackedSessionID, trackedSessionID > 0 {
            trackedProcessGroups.formUnion(processGroups(inSession: trackedSessionID))
        }
        for group in trackedProcessGroups {
            Darwin.kill(-group, signal)
        }
        if signal == SIGKILL {
            trackedProcessGroups.removeAll()
            trackedSessionID = nil
        }
    }

    func processTerminated(source _: TerminalView, exitCode rawWaitStatus: Int32?) {
        finish(pid: terminal.process.shellPid, rawWaitStatus: rawWaitStatus)
    }

    func sizeChanged(source _: LocalProcessTerminalView, newCols _: Int, newRows _: Int) {}
    func setTerminalTitle(source _: LocalProcessTerminalView, title _: String) {}
    func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}

    private func monitor(_ pid: pid_t) {
        processMonitor?.cancel()
        monitoredPID = pid
        let monitor = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        monitor.setEventHandler { [weak self] in
            var status: Int32 = 0
            guard waitpid(pid, &status, WNOHANG) == pid else { return }
            self?.finish(pid: pid, rawWaitStatus: status)
        }
        processMonitor = monitor
        monitor.activate()
    }

    private func processGroups(rootedAt rootPID: pid_t) -> Set<pid_t> {
        var pending = [rootPID]
        var processes: Set<pid_t> = []
        while let process = pending.popLast() {
            guard processes.insert(process).inserted else { continue }
            let capacity = Int(proc_listchildpids(process, nil, 0))
            guard capacity > 0 else { continue }
            var children = [pid_t](repeating: 0, count: capacity)
            let count = children.withUnsafeMutableBytes {
                proc_listchildpids(process, $0.baseAddress, Int32($0.count))
            }
            if count > 0 {
                pending.append(contentsOf: children.prefix(Int(count)))
            }
        }
        return Set(processes.compactMap { process in
            let group = getpgid(process)
            return group > 0 ? group : nil
        })
    }

    private func processGroups(inSession sessionID: pid_t) -> Set<pid_t> {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var processes = [pid_t](repeating: 0, count: capacity)
        let count = processes.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [] }
        return Set(processes.prefix(Int(count)).compactMap { process in
            guard process > 0, getsid(process) == sessionID else { return nil }
            let group = getpgid(process)
            return group > 0 ? group : nil
        })
    }

    private func finish(pid: pid_t, rawWaitStatus: Int32?) {
        guard monitoredPID == pid else { return }
        monitoredPID = nil
        processMonitor?.cancel()
        processMonitor = nil
        guard let rawWaitStatus else {
            onExit?(nil)
            return
        }
        let signal = rawWaitStatus & 0x7f
        onExit?(signal == 0 ? (rawWaitStatus >> 8) & 0xff : 128 + signal)
    }
}

@MainActor
final class ProjectRunSession: ObservableObject, Identifiable {
    let id: String
    let terminalView: NSView
    @Published fileprivate(set) var state: ProjectRunSessionState = .inactive
    @Published fileprivate(set) var lastSuccessfulCommand: String?

    fileprivate let engine: any ProjectRunProcessEngine
    fileprivate var pendingStopExitCode: Int32?

    fileprivate init(configurationID: String, engine: any ProjectRunProcessEngine) {
        id = configurationID
        terminalView = engine.terminalView
        self.engine = engine
    }
}

struct ProjectRunWorkingDirectory {
    static func resolve(projectRoot: String, relativePath: String) throws -> (relativePath: String, path: String) {
        let storedRoot = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL
        let root = storedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard root.path == storedRoot.path else {
            throw ProjectRunConfigurationError.workingDirectoryOutsideProject
        }
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let relativePath = trimmedPath.isEmpty ? "." : trimmedPath
        guard !NSString(string: relativePath).isAbsolutePath else {
            throw ProjectRunConfigurationError.workingDirectoryMustBeRelative
        }
        guard !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw ProjectRunConfigurationError.workingDirectoryOutsideProject
        }
        let unresolved = root.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
        guard unresolved.path == root.path || unresolved.path.hasPrefix(root.path + "/") else {
            throw ProjectRunConfigurationError.workingDirectoryOutsideProject
        }
        let directory = unresolved.resolvingSymlinksInPath().standardizedFileURL
        guard directory.path == root.path || directory.path.hasPrefix(root.path + "/") else {
            throw ProjectRunConfigurationError.workingDirectoryOutsideProject
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw ProjectRunConfigurationError.workingDirectoryMissing
        }
        guard isDirectory.boolValue else {
            throw ProjectRunConfigurationError.workingDirectoryNotDirectory
        }
        return (
            directory.path == root.path ? "." : String(directory.path.dropFirst(root.path.count + 1)),
            directory.path
        )
    }
}

@MainActor
final class ProjectRunCoordinator: ObservableObject {
    @Published private(set) var sessions: [String: ProjectRunSession] = [:]

    private static let trustedRootsKey = "trustedProjectRunRoots"
    private let engineFactory: any ProjectRunEngineFactory
    private let shellProvider: any ProjectRunShellProviding
    private let defaults: UserDefaults
    private let scheduler: any ProjectRunScheduling

    init(
        engineFactory: any ProjectRunEngineFactory,
        shellProvider: any ProjectRunShellProviding,
        defaults: UserDefaults = .standard,
        scheduler: any ProjectRunScheduling
    ) {
        self.engineFactory = engineFactory
        self.shellProvider = shellProvider
        self.defaults = defaults
        self.scheduler = scheduler
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            engineFactory: SwiftTermProjectRunEngineFactory(),
            shellProvider: LiveProjectRunShellProvider(),
            defaults: defaults,
            scheduler: MainProjectRunScheduler()
        )
    }

    func session(for configurationID: String) -> ProjectRunSession? {
        sessions[configurationID]
    }

    func activeConfigurationsFirst(
        _ configurations: [ProjectRunConfiguration]
    ) -> [ProjectRunConfiguration] {
        configurations.filter { sessions[$0.id]?.state.isLive == true }
            + configurations.filter { sessions[$0.id]?.state.isLive != true }
    }

    func run(_ configuration: ProjectRunConfiguration, project: ProjectRecord) -> ProjectRunActionResult {
        switch project.availability {
        case .available:
            run(configuration, projectRoot: project.path)
        case .unknown:
            .rejected("正在确认项目是否可用")
        case let .unavailable(reason):
            .rejected("项目不可用，不能执行：\(reason)")
        }
    }

    func run(_ configuration: ProjectRunConfiguration, projectRoot: String) -> ProjectRunActionResult {
        guard sessions[configuration.id]?.state.isLive != true else {
            return .rejected("该运行配置已有活动会话")
        }
        do {
            let directory = try ProjectRunWorkingDirectory.resolve(
                projectRoot: projectRoot,
                relativePath: configuration.workingDirectory
            )
            let request = ProjectRunTrustRequest(
                configuration: configuration,
                projectRoot: projectRoot,
                command: configuration.command,
                workingDirectory: directory.path
            )
            guard trustedRoots.contains(projectRoot) else { return .needsTrust(request) }
            return launch(request)
        } catch {
            return reject(configurationID: configuration.id, error: error)
        }
    }

    func confirmTrustAndRun(_ request: ProjectRunTrustRequest) -> ProjectRunActionResult {
        var roots = trustedRoots
        roots.insert(request.projectRoot)
        defaults.set(Array(roots).sorted(), forKey: Self.trustedRootsKey)
        return launch(request)
    }

    func stop(configurationID: String) {
        guard let session = sessions[configurationID], session.state.isLive else { return }
        session.state = .stopping
        session.pendingStopExitCode = nil
        session.engine.signalProcessGroups(SIGINT)
        objectWillChange.send()
        scheduler.schedule(after: .seconds(2)) { [weak self, weak session] in
            guard let self, let session, session.state == .stopping else { return }
            session.engine.signalProcessGroups(SIGTERM)
            self.scheduler.schedule(after: .seconds(2)) { [weak self, weak session] in
                guard let self, let session, session.state == .stopping else { return }
                session.engine.signalProcessGroups(SIGKILL)
                session.state = .exited(session.pendingStopExitCode ?? 137)
                self.objectWillChange.send()
            }
        }
    }

    func removeProjects(
        projectIDs: Set<String>,
        from projectsModel: ProjectsViewModel
    ) -> ProjectRemovalSummary? {
        let configurationIDs = Set(
            projectsModel.runConfigurations()
                .filter { projectIDs.contains($0.projectID) }
                .map(\.id)
        )
        guard let summary = projectsModel.remove(projectIDs: projectIDs) else { return nil }
        for configurationID in configurationIDs {
            if let session = sessions[configurationID], session.state.isLive {
                session.engine.signalProcessGroups(SIGKILL)
            }
            sessions.removeValue(forKey: configurationID)
        }
        defaults.set(Array(trustedRoots.subtracting(projectIDs)).sorted(), forKey: Self.trustedRootsKey)
        objectWillChange.send()
        return summary
    }

    func terminateAllForApplicationExit() {
        for session in sessions.values {
            session.engine.signalProcessGroups(SIGKILL)
        }
        sessions.removeAll()
        objectWillChange.send()
    }

    func closeTerminal(configurationID: String) {
        guard sessions[configurationID]?.state.isLive != true else { return }
        sessions.removeValue(forKey: configurationID)
    }

    private var trustedRoots: Set<String> {
        Set(defaults.stringArray(forKey: Self.trustedRootsKey) ?? [])
    }

    private func launch(_ request: ProjectRunTrustRequest) -> ProjectRunActionResult {
        guard sessions[request.configuration.id]?.state.isLive != true else {
            return .rejected("该运行配置已有活动会话")
        }
        do {
            let directory = try ProjectRunWorkingDirectory.resolve(
                projectRoot: request.projectRoot,
                relativePath: request.configuration.workingDirectory
            )
            let shell = try shellProvider.defaultLoginShell()
            let session = sessions[request.configuration.id] ?? makeSession(for: request.configuration.id)
            session.state = .starting
            objectWillChange.send()
            try session.engine.start(
                executable: shell,
                arguments: ["-i", "-c", request.configuration.command],
                loginName: "-\(URL(fileURLWithPath: shell).lastPathComponent)",
                workingDirectory: directory.path
            )
            session.lastSuccessfulCommand = request.configuration.command
            session.state = .running
            objectWillChange.send()
            return .started
        } catch {
            return reject(configurationID: request.configuration.id, error: error)
        }
    }

    private func makeSession(for configurationID: String) -> ProjectRunSession {
        let session = ProjectRunSession(configurationID: configurationID, engine: engineFactory.makeEngine())
        session.engine.onExit = { [weak self, weak session] exitCode in
            guard let self, let session else { return }
            if session.state == .stopping {
                session.pendingStopExitCode = exitCode
                return
            }
            session.engine.signalProcessGroups(SIGKILL)
            session.state = .exited(exitCode ?? -1)
            self.objectWillChange.send()
        }
        sessions[configurationID] = session
        return session
    }

    private func reject(configurationID: String, error: Error) -> ProjectRunActionResult {
        let message = error.localizedDescription
        let session = sessions[configurationID] ?? makeSession(for: configurationID)
        session.state = .launchFailed(message)
        objectWillChange.send()
        return .rejected(message)
    }
}
