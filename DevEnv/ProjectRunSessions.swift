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
    case stopFailed(String)
    case restarting
    case restartFailed(String)
    case stopped(Int32)
    case exited(Int32)
    case launchFailed(String)

    var isLive: Bool {
        switch self {
        case .starting, .running, .stopping, .stopFailed, .restarting, .restartFailed: true
        case .inactive, .stopped, .exited, .launchFailed: false
        }
    }

    var isStopping: Bool {
        switch self {
        case .stopping, .stopFailed, .restarting: true
        default: false
        }
    }

    var canRestart: Bool {
        switch self {
        case .running, .restartFailed: true
        default: false
        }
    }

    var statusTitle: String {
        switch self {
        case .inactive: "未启动"
        case .starting: "正在启动"
        case .running: "运行中"
        case .stopping: "正在停止"
        case .stopFailed: "停止失败"
        case .restarting: "正在重启"
        case .restartFailed: "重启失败"
        case .stopped: "已停止"
        case let .exited(code): code == 0 ? "已停止" : "异常退出"
        case .launchFailed: "启动失败"
        }
    }

    var summaryCategory: ProjectRunSessionSummaryCategory {
        switch self {
        case .starting, .running, .stopping, .restarting: .running
        case .stopped, .exited(0): .stopped
        case .inactive: .ignored
        case .stopFailed, .restartFailed, .launchFailed, .exited: .exceptional
        }
    }
}

struct ProjectRunSessionSummary: Equatable, Sendable {
    let running: Int
    let stopped: Int
    let exceptional: Int
}

struct ProjectRunExecution: Identifiable, Equatable, Sendable {
    let id: UUID
    let configurationID: String
    let command: String
    let projectRoot: String
    let workingDirectory: String

    init(
        id: UUID = UUID(),
        configurationID: String,
        command: String,
        projectRoot: String,
        workingDirectory: String
    ) {
        self.id = id
        self.configurationID = configurationID
        self.command = command
        self.projectRoot = projectRoot
        self.workingDirectory = workingDirectory
    }
}

enum ProjectRunSessionSummaryCategory: Equatable, Sendable {
    case running
    case stopped
    case exceptional
    case ignored
}

struct ProjectRunTrustRequest: Equatable, Sendable {
    let configuration: ProjectRunConfiguration
    let projectRoot: String
    let command: String
    let workingDirectory: String
    let commandWasDraft: Bool

    init(
        configuration: ProjectRunConfiguration,
        projectRoot: String,
        command: String,
        workingDirectory: String,
        commandWasDraft: Bool = false
    ) {
        self.configuration = configuration
        self.projectRoot = projectRoot
        self.command = command
        self.workingDirectory = workingDirectory
        self.commandWasDraft = commandWasDraft
    }
}

struct ProjectRunBatchIntent: Equatable, Sendable {
    let startRequests: [ProjectRunTrustRequest]
}

struct ProjectRunBatchTrustReview: Equatable, Sendable {
    let intent: ProjectRunBatchIntent
    let projectRootsRequiringTrust: [String]
}

struct ProjectRunBatchStopIntent: Equatable, Sendable {
    let executionIDs: [ProjectRunExecution.ID]
}

enum ProjectRunActionResult: Equatable, Sendable {
    case needsTrust(ProjectRunTrustRequest)
    case started
    case rejected(String)
}

enum ProjectRunSignalTargets {
    static func signal(
        _ signal: Int32,
        requestedGroups: Set<pid_t>,
        ownedGroups: Set<pid_t>,
        currentProcessGroup: () -> pid_t = getpgrp,
        send: (pid_t, Int32) -> Bool = { group, signal in
            Darwin.kill(-group, signal) == 0 || errno == ESRCH
        }
    ) -> Bool {
        let currentProcessGroup = currentProcessGroup()
        let targets = requestedGroups.intersection(ownedGroups)
            .filter { $0 > 1 && $0 != currentProcessGroup }
            .sorted()
        var succeeded = true
        for group in targets {
            if !send(group, signal) {
                succeeded = false
            }
        }
        return succeeded
    }
}

struct ProjectRunOwnedProcess {
    let userID: uid_t
    let terminalDevice: UInt32
    let processGroup: pid_t
}

struct ProjectRunProcessSnapshot: Sendable {
    let processID: pid_t
    let userID: uid_t
    let terminalDevice: UInt32
    let processGroup: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

enum ProjectRunProcessSnapshotReader {
    static func read(userID: uid_t) -> [ProjectRunProcessSnapshot]? {
        guard let processes = allProcessIDs(userID: userID) else { return nil }
        var snapshots: [ProjectRunProcessSnapshot] = []
        for process in processes where process > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &info, size) == size else {
                continue
            }
            snapshots.append(ProjectRunProcessSnapshot(
                processID: process,
                userID: info.pbi_uid,
                terminalDevice: info.e_tdev,
                processGroup: pid_t(info.pbi_pgid),
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            ))
        }
        return snapshots
    }

    private static func allProcessIDs(userID: uid_t) -> [pid_t]? {
        let type = UInt32(PROC_UID_ONLY)
        let typeInfo = UInt32(userID)
        var byteCapacity = Int(proc_listpids(type, typeInfo, nil, 0)) + 32 * MemoryLayout<pid_t>.size
        guard byteCapacity > 32 * MemoryLayout<pid_t>.size else { return nil }
        for _ in 0..<3 {
            var processes = [pid_t](
                repeating: 0,
                count: byteCapacity / MemoryLayout<pid_t>.size
            )
            let byteCount = processes.withUnsafeMutableBytes {
                proc_listpids(
                    type,
                    typeInfo,
                    $0.baseAddress,
                    Int32($0.count * MemoryLayout<pid_t>.size)
                )
            }
            guard byteCount > 0 else { return nil }
            if byteCount < byteCapacity {
                return Array(processes.prefix(Int(byteCount) / MemoryLayout<pid_t>.size))
            }
            byteCapacity *= 2
        }
        return nil
    }
}

enum ProjectRunPhysicalMemory {
    static func total(processIDs: Set<pid_t>) -> UInt64? {
        total(processIDs: processIDs, read: physicalFootprint)
    }

    static func total(
        processIDs: Set<pid_t>,
        read: (pid_t) -> UInt64?
    ) -> UInt64? {
        var total: UInt64 = 0
        for processID in processIDs {
            guard let bytes = read(processID) else { return nil }
            let addition = total.addingReportingOverflow(bytes)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }

    private static func physicalFootprint(processID: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(processID, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }
}

enum ProjectRunProcessOwnership {
    static func processGroups(
        in processes: [ProjectRunOwnedProcess],
        userID: uid_t,
        terminalDevice: UInt32
    ) -> Set<pid_t> {
        Set(processes.compactMap { process in
            guard process.userID == userID,
                  process.terminalDevice == terminalDevice,
                  process.processGroup > 1 else { return nil }
            return process.processGroup
        })
    }

    static func revalidatedGroup(witnessedGroup: pid_t, currentGroup: pid_t) -> pid_t? {
        witnessedGroup > 1 && currentGroup == witnessedGroup ? witnessedGroup : nil
    }
}

final class ProjectRunPTYOwnershipToken {
    let terminalDevice: UInt32
    private let masterDescriptor: Int32

    init?(masterDescriptor: Int32) {
        guard masterDescriptor >= 0 else { return nil }
        let descriptorFlags = fcntl(masterDescriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(masterDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else { return nil }
        let heldDescriptor = dup(masterDescriptor)
        guard heldDescriptor >= 0 else { return nil }
        guard fcntl(heldDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            close(heldDescriptor)
            return nil
        }
        guard let slaveName = ptsname(heldDescriptor) else {
            close(heldDescriptor)
            return nil
        }
        var metadata = stat()
        guard lstat(slaveName, &metadata) == 0 else {
            close(heldDescriptor)
            return nil
        }
        let terminalDevice = UInt32(metadata.st_rdev)
        guard terminalDevice > 0, terminalDevice != UInt32.max else {
            close(heldDescriptor)
            return nil
        }
        self.masterDescriptor = heldDescriptor
        self.terminalDevice = terminalDevice
    }

    deinit {
        close(masterDescriptor)
    }
}

enum ProjectRunProcessIdentityState {
    case current(processGroup: pid_t)
    case gone
    case uncertain
}

struct ProjectRunProcessIdentityToken {
    let processID: pid_t
    private let startSeconds: UInt64
    private let startMicroseconds: UInt64

    init?(processID: pid_t) {
        guard let info = Self.info(for: processID) else { return nil }
        self.init(processID: processID, info: info)
    }

    init(processID: pid_t, info: proc_bsdinfo) {
        self.processID = processID
        startSeconds = info.pbi_start_tvsec
        startMicroseconds = info.pbi_start_tvusec
    }

    init(snapshot: ProjectRunProcessSnapshot) {
        processID = snapshot.processID
        startSeconds = snapshot.startSeconds
        startMicroseconds = snapshot.startMicroseconds
    }

    var state: ProjectRunProcessIdentityState {
        guard let info = Self.info(for: processID) else {
            return Darwin.kill(processID, 0) != 0 && errno == ESRCH ? .gone : .uncertain
        }
        guard info.pbi_start_tvsec == startSeconds,
              info.pbi_start_tvusec == startMicroseconds else { return .gone }
        return .current(processGroup: pid_t(info.pbi_pgid))
    }

    func terminate() -> Bool {
        switch state {
        case .current: break
        case .gone: return true
        case .uncertain: return false
        }
        return Darwin.kill(processID, SIGKILL) == 0 || errno == ESRCH
    }

    private static func info(for processID: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard processID > 1,
              proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}

@MainActor
protocol ProjectRunProcessEngine: AnyObject {
    var terminalView: NSView { get }
    var onExit: ((Int32?) -> Void)? { get set }
    var ownedProcessIDs: Set<pid_t>? { get }
    var physicalMemoryBytes: UInt64? { get }

    func start(
        executable: String,
        arguments: [String],
        loginName: String,
        workingDirectory: String
    ) throws
    func clearTerminal()
    func signalProcessGroups(_ signal: Int32) -> Bool
}

protocol ProjectRunShellProviding {
    func defaultLoginShell() throws -> String
}

@MainActor
protocol ProjectRunScheduling {
    func schedule(after delay: Duration, _ action: @escaping () -> Void)
}

enum ProjectRunLaunchError: LocalizedError, Equatable {
    case defaultLoginShellUnavailable
    case processDidNotStart
    case processCouldNotBeContained
    case previousProcessesStillRunning
    case reviewedWorkingDirectoryChanged

    var errorDescription: String? {
        switch self {
        case .defaultLoginShellUnavailable: "Default Login Shell 不可用或不可执行"
        case .processDidNotStart: "PTY 进程启动失败"
        case .processCouldNotBeContained: "PTY 所有权建立失败，启动进程未能安全终止"
        case .previousProcessesStillRunning: "上一次运行仍有进程未退出"
        case .reviewedWorkingDirectoryChanged: "工作目录已变化，需要重新确认"
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

private func projectRunOwnershipMonitorHandler(
    userID: uid_t,
    deliver: @escaping @MainActor @Sendable ([ProjectRunProcessSnapshot]?) -> Void
) -> @Sendable () -> Void {
    {
        let snapshot = ProjectRunProcessSnapshotReader.read(userID: userID)
        Task { @MainActor in
            deliver(snapshot)
        }
    }
}

@MainActor
final class AdaptiveProjectRunTerminalView: LocalProcessTerminalView {
    private static let historyGrowthLines = TerminalOptions.default.scrollback
    private static let maximumHistoryLines = 10_000
    private var historyLines = TerminalOptions.default.scrollback
    private var estimatedOutputRows = 0
    private var currentOutputColumn = 0

    override func dataReceived(slice: ArraySlice<UInt8>) {
        growHistory(for: slice)
        super.dataReceived(slice: slice)
    }

    func resetHistory() {
        historyLines = Self.historyGrowthLines
        estimatedOutputRows = 0
        currentOutputColumn = 0
        terminal.changeHistorySize(historyLines)
    }

    private func growHistory(for bytes: ArraySlice<UInt8>) {
        let columns = max(terminal.cols, 1)
        // ponytail: raw bytes can overestimate ANSI/UTF-8 width; use SwiftTerm row callbacks if exposed.
        for byte in bytes {
            switch byte {
            case 0x0A:
                recordOutputRow()
                currentOutputColumn = 0
            case 0x0D:
                currentOutputColumn = 0
            case 0x08:
                currentOutputColumn = max(currentOutputColumn - 1, 0)
            default:
                currentOutputColumn += 1
                if currentOutputColumn >= columns {
                    recordOutputRow()
                    currentOutputColumn = 0
                }
            }
        }
        let targetLines = min(
            Self.maximumHistoryLines,
            max(
                Self.historyGrowthLines,
                ((estimatedOutputRows + Self.historyGrowthLines - 1) / Self.historyGrowthLines)
                    * Self.historyGrowthLines
            )
        )
        guard targetLines > historyLines else { return }
        historyLines = targetLines
        terminal.changeHistorySize(historyLines)
    }

    private func recordOutputRow() {
        estimatedOutputRows = min(estimatedOutputRows + 1, Self.maximumHistoryLines)
    }
}

@MainActor
final class SwiftTermProjectRunEngine: NSObject, ProjectRunProcessEngine, @preconcurrency LocalProcessTerminalViewDelegate {
    let terminal = AdaptiveProjectRunTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
    var terminalView: NSView { terminal }
    var onExit: ((Int32?) -> Void)?
    private(set) var ownedProcessIDs: Set<pid_t>?
    var physicalMemoryBytes: UInt64? {
        guard ownedProcessIDs != nil else { return nil }
        var processIDs: Set<pid_t> = []
        for witness in ownedGroupWitnesses.values.flatMap(\.values) {
            switch witness.state {
            case .current:
                processIDs.insert(witness.processID)
            case .gone:
                continue
            case .uncertain:
                return nil
            }
        }
        return ProjectRunPhysicalMemory.total(processIDs: processIDs)
    }
    private var processMonitor: DispatchSourceProcess?
    private var ownershipMonitor: DispatchSourceTimer?
    private var ownershipMonitorGeneration = UUID()
    private var monitoredPID: pid_t?
    private var trackedProcessGroups: Set<pid_t> = []
    private var ownershipToken: ProjectRunPTYOwnershipToken?
    private var uncontainedProcess: ProjectRunProcessIdentityToken?
    private var unresolvedProcessID: pid_t?
    private var ownedGroupWitnesses: [pid_t: [pid_t: ProjectRunProcessIdentityToken]] = [:]

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
        ownedProcessIDs = nil
        if let unresolvedProcessID {
            guard Darwin.kill(unresolvedProcessID, 0) != 0, errno == ESRCH else {
                throw ProjectRunLaunchError.previousProcessesStillRunning
            }
            self.unresolvedProcessID = nil
        }
        if let uncontainedProcess {
            _ = uncontainedProcess.terminate()
            guard case .gone = uncontainedProcess.state else {
                throw ProjectRunLaunchError.previousProcessesStillRunning
            }
            self.uncontainedProcess = nil
        }
        if let ownershipToken {
            guard let ownership = refreshOwnedProcessGroups(
                onTerminal: ownershipToken.terminalDevice
            ), ownership.groups.isEmpty, !ownership.isUncertain else {
                throw ProjectRunLaunchError.previousProcessesStillRunning
            }
            self.ownershipToken = nil
            trackedProcessGroups.removeAll()
            ownedGroupWitnesses.removeAll()
        }
        let previousPID = terminal.process.shellPid
        terminal.startProcess(
            executable: executable,
            args: arguments,
            execName: loginName,
            currentDirectory: workingDirectory
        )
        let pid = terminal.process.shellPid
        guard pid > 1, pid != previousPID || terminal.process.running else {
            throw ProjectRunLaunchError.processDidNotStart
        }
        let childProcessToken = ProjectRunProcessIdentityToken(processID: pid)
        guard let ownershipToken = ProjectRunPTYOwnershipToken(
            masterDescriptor: terminal.process.childfd
        ) else {
            guard let childProcessToken else {
                if Darwin.kill(pid, 0) != 0, errno == ESRCH {
                    throw ProjectRunLaunchError.processDidNotStart
                }
                unresolvedProcessID = pid
                throw ProjectRunLaunchError.processCouldNotBeContained
            }
            uncontainedProcess = childProcessToken
            _ = childProcessToken.terminate()
            throw ProjectRunLaunchError.processCouldNotBeContained
        }
        trackedProcessGroups = [pid]
        self.ownershipToken = ownershipToken
        _ = refreshOwnedProcessGroups(onTerminal: ownershipToken.terminalDevice)
        monitor(pid)
        monitorOwnership(ownershipToken)
    }

    func clearTerminal() {
        if terminal.terminal.isCurrentBufferAlternate {
            terminal.terminal.resetNormalBuffer()
        }
        terminal.feed(text: "\u{1B}[3J\u{1B}[2J\u{1B}[H")
        terminal.resetHistory()
    }

    func signalProcessGroups(_ signal: Int32) -> Bool {
        if let unresolvedProcessID {
            guard Darwin.kill(unresolvedProcessID, 0) != 0, errno == ESRCH else { return false }
            self.unresolvedProcessID = nil
            return true
        }
        if let uncontainedProcess {
            return uncontainedProcess.terminate()
        }
        let rootPID = terminal.process.shellPid
        if rootPID > 0 {
            trackedProcessGroups.formUnion(processGroups(rootedAt: rootPID))
        }
        guard let ownershipToken,
              let ownership = refreshOwnedProcessGroups(
                  onTerminal: ownershipToken.terminalDevice
              ) else {
            return false
        }
        let ownedProcessGroups = ownership.groups
        trackedProcessGroups.formUnion(ownedProcessGroups)
        let signaled = ProjectRunSignalTargets.signal(
            signal,
            requestedGroups: trackedProcessGroups,
            ownedGroups: ownedProcessGroups
        )
        return signaled && !ownership.isUncertain
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

    private func monitorOwnership(_ ownershipToken: ProjectRunPTYOwnershipToken) {
        ownershipMonitor?.cancel()
        let generation = UUID()
        ownershipMonitorGeneration = generation
        let terminalDevice = ownershipToken.terminalDevice
        let userID = getuid()
        let monitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        monitor.schedule(
            deadline: .now(),
            repeating: .milliseconds(250),
            leeway: .milliseconds(50)
        )
        monitor.setEventHandler(handler: projectRunOwnershipMonitorHandler(userID: userID) {
            [weak self] snapshot in
                guard let self,
                      self.ownershipMonitorGeneration == generation,
                      self.ownershipToken?.terminalDevice == terminalDevice,
                      let snapshot else { return }
                _ = self.applyOwnedProcessSnapshot(snapshot, terminalDevice: terminalDevice)
        })
        ownershipMonitor = monitor
        monitor.activate()
    }

    private func processGroups(rootedAt rootPID: pid_t) -> Set<pid_t> {
        var pending = [rootPID]
        var processes: Set<pid_t> = []
        while let process = pending.popLast() {
            guard processes.insert(process).inserted else { continue }
            let capacity = Int(proc_listchildpids(process, nil, 0))
            guard capacity > 0 else { continue }
            var children = [pid_t](
                repeating: 0,
                count: (capacity + MemoryLayout<pid_t>.size - 1) / MemoryLayout<pid_t>.size
            )
            let count = children.withUnsafeMutableBytes {
                proc_listchildpids(
                    process,
                    $0.baseAddress,
                    Int32($0.count * MemoryLayout<pid_t>.size)
                )
            }
            if count > 0 {
                pending.append(contentsOf: children.prefix(Int(count) / MemoryLayout<pid_t>.size))
            }
        }
        return Set(processes.compactMap { process in
            let group = getpgid(process)
            return group > 0 ? group : nil
        })
    }

    private func refreshOwnedProcessGroups(
        onTerminal terminalDevice: UInt32
    ) -> (groups: Set<pid_t>, isUncertain: Bool)? {
        guard let snapshot = ProjectRunProcessSnapshotReader.read(userID: getuid()) else { return nil }
        return applyOwnedProcessSnapshot(snapshot, terminalDevice: terminalDevice)
    }

    private func applyOwnedProcessSnapshot(
        _ snapshot: [ProjectRunProcessSnapshot],
        terminalDevice: UInt32
    ) -> (groups: Set<pid_t>, isUncertain: Bool) {
        let ownedProcesses = snapshot.map {
            ProjectRunOwnedProcess(
                userID: $0.userID,
                terminalDevice: $0.terminalDevice,
                processGroup: $0.processGroup
            )
        }
        let attachedGroups = ProjectRunProcessOwnership.processGroups(
            in: ownedProcesses,
            userID: getuid(),
            terminalDevice: terminalDevice
        )
        for process in snapshot {
            let group = process.processGroup
            guard attachedGroups.contains(group) else { continue }
            ownedGroupWitnesses[group, default: [:]][process.processID] = ProjectRunProcessIdentityToken(
                snapshot: process
            )
        }

        var groups: Set<pid_t> = []
        var isUncertain = false
        var validatedWitnesses: [pid_t: [pid_t: ProjectRunProcessIdentityToken]] = [:]
        for (ownedGroup, witnesses) in ownedGroupWitnesses {
            for (processID, witness) in witnesses {
                switch witness.state {
                case let .current(processGroup):
                    guard let group = ProjectRunProcessOwnership.revalidatedGroup(
                        witnessedGroup: ownedGroup,
                        currentGroup: processGroup
                    ) else { continue }
                    validatedWitnesses[group, default: [:]][processID] = witness
                    groups.insert(group)
                case .gone:
                    continue
                case .uncertain:
                    validatedWitnesses[ownedGroup, default: [:]][processID] = witness
                    isUncertain = true
                }
            }
        }
        ownedGroupWitnesses = validatedWitnesses
        ownedProcessIDs = isUncertain ? nil : Set(validatedWitnesses.values.flatMap { $0.keys })
        return (groups, isUncertain)
    }

    private func finish(pid: pid_t, rawWaitStatus: Int32?) {
        guard monitoredPID == pid else { return }
        monitoredPID = nil
        processMonitor?.cancel()
        processMonitor = nil
        ownershipMonitorGeneration = UUID()
        ownershipMonitor?.cancel()
        ownershipMonitor = nil
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
    @Published fileprivate(set) var currentExecution: ProjectRunExecution?
    @Published fileprivate(set) var lastSuccessfulCommand: String?
    @Published fileprivate(set) var startedAt: Date?
    @Published fileprivate(set) var failureMessage: String?
    @Published fileprivate(set) var failureAt: Date?

    var activeExecution: ProjectRunExecution? {
        state.isLive ? currentExecution : nil
    }

    var ownedProcessIDs: Set<pid_t>? { engine.ownedProcessIDs }
    var physicalMemoryBytes: UInt64? { engine.physicalMemoryBytes }

    fileprivate let engine: any ProjectRunProcessEngine
    fileprivate var pendingStopExitCode: Int32?
    fileprivate var pendingRestart: ProjectRunTrustRequest?
    fileprivate var stopRequestedByUser = false

    fileprivate init(configurationID: String, engine: any ProjectRunProcessEngine) {
        id = configurationID
        terminalView = engine.terminalView
        self.engine = engine
    }
}

struct ProjectRunWorkingDirectory {
    static func normalize(relativePath: String) throws -> String {
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let relativePath = trimmedPath.isEmpty ? "." : trimmedPath
        guard !NSString(string: relativePath).isAbsolutePath else {
            throw ProjectRunConfigurationError.workingDirectoryMustBeRelative
        }
        guard !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw ProjectRunConfigurationError.workingDirectoryOutsideProject
        }
        return relativePath
    }

    static func resolve(projectRoot: String, relativePath: String) throws -> (relativePath: String, path: String) {
        let storedRoot = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL
        let root = storedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard root.path == storedRoot.path else {
            throw ProjectRunConfigurationError.workingDirectoryOutsideProject
        }
        let relativePath = try normalize(relativePath: relativePath)
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
    @Published private(set) var pendingBatchTrustReview: ProjectRunBatchTrustReview?
    @Published private(set) var pendingBatchStopIntent: ProjectRunBatchStopIntent?

    private let projectsModel: ProjectsViewModel
    private let makeEngine: () -> any ProjectRunProcessEngine
    private let shellProvider: any ProjectRunShellProviding
    private let scheduler: any ProjectRunScheduling
    private let isProjectRunTrusted: (String) -> Bool
    private let trustProjectRunRoot: (String) -> Bool
    private var commandDrafts: [String: String] = [:]

    init(
        projectsModel: ProjectsViewModel,
        makeEngine: @escaping () -> any ProjectRunProcessEngine,
        shellProvider: any ProjectRunShellProviding,
        scheduler: any ProjectRunScheduling,
        isProjectRunTrusted: ((String) -> Bool)? = nil,
        trustProjectRunRoot: ((String) -> Bool)? = nil
    ) {
        self.projectsModel = projectsModel
        self.makeEngine = makeEngine
        self.shellProvider = shellProvider
        self.scheduler = scheduler
        self.isProjectRunTrusted = isProjectRunTrusted ?? projectsModel.isProjectRunTrusted
        self.trustProjectRunRoot = trustProjectRunRoot ?? projectsModel.trustProjectRunRoot
    }

    convenience init(projectsModel: ProjectsViewModel) {
        self.init(
            projectsModel: projectsModel,
            makeEngine: { SwiftTermProjectRunEngine() },
            shellProvider: LiveProjectRunShellProvider(),
            scheduler: MainProjectRunScheduler()
        )
    }

    func runConfigurations(projectID: String? = nil) -> [ProjectRunConfiguration] {
        projectsModel.runConfigurations(projectID: projectID).map { configuration in
            guard let command = commandDrafts[configuration.id] else { return configuration }
            var draft = configuration
            draft.command = command
            return draft
        }
    }

    func runSuggestions(projectID: String? = nil) -> [ProjectRunSuggestion] {
        projectsModel.runSuggestions(projectID: projectID)
    }

    var isRefreshingProjects: Bool {
        projectsModel.isRefreshingProjects
    }

    func refreshProjects() {
        projectsModel.refreshProjects()
        objectWillChange.send()
    }

    func isSuggestionSourceAvailable(_ configuration: ProjectRunConfiguration) -> Bool {
        projectsModel.isSuggestionSourceAvailable(configuration)
    }

    @discardableResult
    func adoptSuggestion(_ suggestion: ProjectRunSuggestion) -> ProjectRunConfiguration? {
        projectsModel.adoptSuggestion(suggestion)
    }

    @discardableResult
    func createRunConfiguration(
        projectID: String,
        name: String,
        command: String,
        workingDirectory: String,
        sourceIdentity: String? = nil
    ) -> ProjectRunConfiguration? {
        projectsModel.createRunConfiguration(
            projectID: projectID,
            name: name,
            command: command,
            workingDirectory: workingDirectory,
            sourceIdentity: sourceIdentity
        )
    }

    @discardableResult
    func updateRunConfiguration(
        _ configuration: ProjectRunConfiguration,
        name: String,
        command: String,
        workingDirectory: String
    ) -> Bool {
        guard let remembered = projectsModel.runConfigurations().first(where: { $0.id == configuration.id }),
              projectsModel.updateRunConfiguration(
                  remembered,
                  name: name,
                  command: command,
                  workingDirectory: workingDirectory,
                  rememberCommand: false
              ) else { return false }
        if command == remembered.command {
            commandDrafts.removeValue(forKey: configuration.id)
        } else {
            commandDrafts[configuration.id] = command
        }
        objectWillChange.send()
        return true
    }

    @discardableResult
    func setRunConfigurationEnabled(_ configuration: ProjectRunConfiguration, isEnabled: Bool) -> Bool {
        guard isEnabled || sessions[configuration.id]?.state.isLive != true,
              projectsModel.setRunConfigurationEnabled(configuration, isEnabled: isEnabled) else {
            return false
        }
        objectWillChange.send()
        return true
    }

    @discardableResult
    func deleteRunConfiguration(_ configuration: ProjectRunConfiguration) -> Bool {
        guard projectsModel.deleteRunConfiguration(configuration) else { return false }
        commandDrafts.removeValue(forKey: configuration.id)
        objectWillChange.send()
        return true
    }

    func refreshRequirements(machineSnapshot: MachineSnapshot?) {
        projectsModel.refreshRequirements(machineSnapshot: machineSnapshot)
        objectWillChange.send()
    }

    func hasCommandDraft(configurationID: String) -> Bool {
        commandDrafts[configurationID] != nil
    }

    func session(for configurationID: String) -> ProjectRunSession? {
        sessions[configurationID]
    }

    var sessionSummary: ProjectRunSessionSummary {
        sessions.values.reduce(into: ProjectRunSessionSummary(running: 0, stopped: 0, exceptional: 0)) { summary, session in
            switch session.state.summaryCategory {
            case .running:
                summary = ProjectRunSessionSummary(
                    running: summary.running + 1,
                    stopped: summary.stopped,
                    exceptional: summary.exceptional
                )
            case .stopped:
                summary = ProjectRunSessionSummary(
                    running: summary.running,
                    stopped: summary.stopped + 1,
                    exceptional: summary.exceptional
                )
            case .ignored:
                break
            case .exceptional:
                summary = ProjectRunSessionSummary(
                    running: summary.running,
                    stopped: summary.stopped,
                    exceptional: summary.exceptional + 1
                )
            }
        }
    }

    private func batchStopExecutionIDs(
        in scope: [ProjectRunConfiguration]
    ) -> [ProjectRunExecution.ID] {
        var includedExecutionIDs: Set<ProjectRunExecution.ID> = []
        return scope.compactMap { configuration in
            guard let session = sessions[configuration.id],
                  session.state != .stopping,
                  let executionID = session.activeExecution?.id,
                  includedExecutionIDs.insert(executionID).inserted else {
                return nil
            }
            return executionID
        }
    }

    func canStopBatch(in scope: [ProjectRunConfiguration]) -> Bool {
        !batchStopExecutionIDs(in: scope).isEmpty
    }

    func requestBatchStop(in scope: [ProjectRunConfiguration]) {
        let executionIDs = batchStopExecutionIDs(in: scope)
        pendingBatchStopIntent = executionIDs.isEmpty
            ? nil
            : ProjectRunBatchStopIntent(executionIDs: executionIDs)
    }

    func cancelBatchStop() {
        pendingBatchStopIntent = nil
    }

    func confirmBatchStop() {
        guard let intent = pendingBatchStopIntent else { return }
        pendingBatchStopIntent = nil
        for executionID in intent.executionIDs {
            stop(executionID: executionID)
        }
    }

    func batchStartCandidates(
        in scope: [ProjectRunConfiguration]
    ) -> [ProjectRunConfiguration] {
        let effectiveConfigurations = Dictionary(
            uniqueKeysWithValues: runConfigurations().map { ($0.id, $0) }
        )
        var includedConfigurationIDs: Set<String> = []
        return scope.compactMap { scopedConfiguration in
            guard includedConfigurationIDs.insert(scopedConfiguration.id).inserted,
                  let configuration = effectiveConfigurations[scopedConfiguration.id],
                  configuration.isEnabled,
                  sessions[configuration.id]?.activeExecution == nil,
                  let project = projectsModel.records.first(where: { $0.id == configuration.projectID }),
                  !project.availability.isUnavailable else {
                return nil
            }
            return configuration
        }
    }

    func canStartBatch(in scope: [ProjectRunConfiguration]) -> Bool {
        !batchStartCandidates(in: scope).isEmpty
    }

    func makeBatchStartIntent(
        in scope: [ProjectRunConfiguration]
    ) -> ProjectRunBatchIntent {
        let requests: [ProjectRunTrustRequest] = batchStartCandidates(in: scope).compactMap { configuration in
            guard let project = projectsModel.records.first(where: { $0.id == configuration.projectID }) else {
                return nil
            }
            do {
                let directory = try ProjectRunWorkingDirectory.resolve(
                    projectRoot: project.path,
                    relativePath: configuration.workingDirectory
                )
                return ProjectRunTrustRequest(
                    configuration: configuration,
                    projectRoot: project.path,
                    command: configuration.command,
                    workingDirectory: directory.path,
                    commandWasDraft: hasCommandDraft(configurationID: configuration.id)
                )
            } catch {
                let session = sessions[configuration.id] ?? makeSession(for: configuration.id)
                session.currentExecution = nil
                _ = reject(configurationID: configuration.id, error: error)
                return nil
            }
        }
        return ProjectRunBatchIntent(startRequests: requests)
    }

    func submitBatchStart(_ intent: ProjectRunBatchIntent) {
        for request in intent.startRequests {
            guard let currentConfiguration = projectsModel.runConfigurations().first(where: {
                $0.id == request.configuration.id
            }),
            currentConfiguration.isEnabled,
            currentConfiguration.projectID == request.configuration.projectID,
            let project = projectsModel.records.first(where: { $0.id == currentConfiguration.projectID }),
            project.path == request.projectRoot,
            project.availability == .available,
            isProjectRunTrusted(request.projectRoot) else {
                continue
            }
            _ = launch(request)
        }
    }

    func startBatch(in scope: [ProjectRunConfiguration]) {
        requestBatchStart(makeBatchStartIntent(in: scope))
    }

    func requestBatchStart(_ intent: ProjectRunBatchIntent) {
        guard !intent.startRequests.isEmpty else { return }
        let projectRootsRequiringTrust = Set(intent.startRequests.map(\.projectRoot).filter {
            !isProjectRunTrusted($0)
        }).sorted()
        guard !projectRootsRequiringTrust.isEmpty else {
            submitBatchStart(intent)
            return
        }
        pendingBatchTrustReview = ProjectRunBatchTrustReview(
            intent: intent,
            projectRootsRequiringTrust: projectRootsRequiringTrust
        )
    }

    func cancelBatchTrustReview() {
        pendingBatchTrustReview = nil
    }

    func confirmBatchTrustAndStart() {
        guard let review = pendingBatchTrustReview else { return }
        pendingBatchTrustReview = nil
        var launchableProjectRoots = Set(review.intent.startRequests.map(\.projectRoot).filter {
            isProjectRunTrusted($0)
        })
        for projectRoot in review.projectRootsRequiringTrust
        where isProjectRunTrusted(projectRoot) || trustProjectRunRoot(projectRoot) {
            launchableProjectRoots.insert(projectRoot)
        }
        submitBatchStart(ProjectRunBatchIntent(startRequests: review.intent.startRequests.filter {
            launchableProjectRoots.contains($0.projectRoot)
        }))
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
        guard isRunConfigurationEnabled(configuration) else { return .rejected("运行配置已禁用") }
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
                workingDirectory: directory.path,
                commandWasDraft: hasCommandDraft(configurationID: configuration.id)
            )
            guard projectsModel.isProjectRunTrusted(projectRoot) else { return .needsTrust(request) }
            return launch(request)
        } catch {
            let session = sessions[configuration.id] ?? makeSession(for: configuration.id)
            session.currentExecution = nil
            return reject(configurationID: configuration.id, error: error)
        }
    }

    func confirmTrustAndRun(_ request: ProjectRunTrustRequest) -> ProjectRunActionResult {
        guard isRunConfigurationEnabled(request.configuration) else { return .rejected("运行配置已禁用") }
        guard projectsModel.trustProjectRunRoot(request.projectRoot) else {
            return .rejected(projectsModel.operationError ?? "Project Trust 保存失败")
        }
        return launch(request)
    }

    func stop(executionID: ProjectRunExecution.ID) {
        guard let session = sessions.values.first(where: { $0.activeExecution?.id == executionID }),
              session.state != .stopping else { return }
        stopCurrentExecution(in: session)
    }

    func stop(configurationID: String) {
        guard let executionID = sessions[configurationID]?.activeExecution?.id else { return }
        stop(executionID: executionID)
    }

    private func stopCurrentExecution(in session: ProjectRunSession) {
        session.pendingRestart = nil
        if session.state == .restarting {
            session.stopRequestedByUser = true
            session.state = .stopping
            objectWillChange.send()
            return
        }
        beginStopping(session, restarting: false)
    }

    func restart(_ configuration: ProjectRunConfiguration, project: ProjectRecord) {
        switch project.availability {
        case .available:
            restart(configuration, projectRoot: project.path)
        case .unknown:
            failRestart(configurationID: configuration.id, message: "正在确认项目是否可用")
        case let .unavailable(reason):
            failRestart(configurationID: configuration.id, message: "项目不可用，不能执行：\(reason)")
        }
    }

    func restart(_ configuration: ProjectRunConfiguration, projectRoot: String) {
        guard let session = sessions[configuration.id], session.state.canRestart else { return }
        do {
            let directory = try ProjectRunWorkingDirectory.resolve(
                projectRoot: projectRoot,
                relativePath: configuration.workingDirectory
            )
            guard projectsModel.isProjectRunTrusted(projectRoot) else {
                failRestart(session, message: "Project Root 尚未信任")
                return
            }
            session.pendingRestart = ProjectRunTrustRequest(
                configuration: configuration,
                projectRoot: projectRoot,
                command: configuration.command,
                workingDirectory: directory.path,
                commandWasDraft: hasCommandDraft(configurationID: configuration.id)
            )
            session.failureMessage = nil
            session.failureAt = nil
            beginStopping(session, restarting: true)
        } catch {
            failRestart(session, message: error.localizedDescription)
        }
    }

    private func beginStopping(_ session: ProjectRunSession, restarting: Bool) {
        let isRetry = session.state.isStopping
        session.state = restarting ? .restarting : .stopping
        if !isRetry {
            session.pendingStopExitCode = nil
            session.stopRequestedByUser = !restarting
        }
        if !restarting {
            session.failureMessage = nil
            session.failureAt = nil
        }
        _ = session.engine.signalProcessGroups(SIGINT)
        objectWillChange.send()
        scheduler.schedule(after: .seconds(2)) { [weak self, weak session] in
            guard let self, let session, session.state.isStopping else { return }
            _ = session.engine.signalProcessGroups(SIGTERM)
            self.scheduler.schedule(after: .seconds(2)) { [weak self, weak session] in
                guard let self, let session, session.state.isStopping else { return }
                if session.engine.signalProcessGroups(SIGKILL) {
                    self.finishStopping(session)
                } else if session.state == .restarting {
                    self.failRestart(session, message: "上一次运行仍有进程未退出")
                } else {
                    self.failStop(session, message: "仍有进程未退出")
                }
                self.objectWillChange.send()
            }
        }
    }

    private func finishStopping(_ session: ProjectRunSession) {
        let exitCode = session.pendingStopExitCode ?? 137
        finishStoppingWhenProcessesExit(session, exitCode: exitCode, checksRemaining: 10)
    }

    private func finishStoppingWhenProcessesExit(
        _ session: ProjectRunSession,
        exitCode: Int32,
        checksRemaining: Int
    ) {
        guard session.state.isStopping else { return }
        if session.engine.signalProcessGroups(0), session.ownedProcessIDs?.isEmpty == true {
            let request = session.pendingRestart
            let stoppedByUser = session.stopRequestedByUser
            session.pendingRestart = nil
            session.pendingStopExitCode = nil
            session.stopRequestedByUser = false
            if request == nil && !stoppedByUser && exitCode != 0 {
                session.failureMessage = "命令以状态码 \(exitCode) 退出"
                session.failureAt = Date()
            } else {
                session.failureMessage = nil
                session.failureAt = nil
            }
            session.state = request == nil && stoppedByUser ? .stopped(exitCode) : .exited(exitCode)
            if let request { _ = launch(request) }
        } else if checksRemaining > 0 {
            scheduler.schedule(after: .milliseconds(100)) { [weak self, weak session] in
                guard let self, let session else { return }
                self.finishStoppingWhenProcessesExit(
                    session,
                    exitCode: exitCode,
                    checksRemaining: checksRemaining - 1
                )
            }
        } else if session.state == .restarting {
            failRestart(session, message: "上一次运行仍有进程未退出")
        } else {
            failStop(session, message: "仍有进程未退出")
        }
    }

    private func failRestart(configurationID: String, message: String) {
        guard let session = sessions[configurationID], session.state.canRestart else { return }
        failRestart(session, message: message)
    }

    private func failRestart(_ session: ProjectRunSession, message: String) {
        session.pendingRestart = nil
        session.failureMessage = "重启失败：\(message)"
        session.failureAt = Date()
        session.state = .restartFailed(message)
        objectWillChange.send()
    }

    private func failStop(_ session: ProjectRunSession, message: String) {
        session.failureMessage = "停止失败：\(message)"
        session.failureAt = Date()
        session.state = .stopFailed(message)
        objectWillChange.send()
    }

    func removeProjects(
        projectIDs: Set<String>
    ) -> ProjectRemovalSummary? {
        let configurationIDs = Set(
            projectsModel.runConfigurations()
                .filter { projectIDs.contains($0.projectID) }
                .map(\.id)
        )
        guard let summary = projectsModel.remove(projectIDs: projectIDs, afterPersist: {
            var succeeded = true
            for configurationID in configurationIDs {
                guard let session = sessions[configurationID], session.state.isLive else { continue }
                session.state = .stopping
                if session.engine.signalProcessGroups(SIGKILL) {
                    session.state = .exited(137)
                } else {
                    succeeded = false
                }
            }
            return succeeded
        }) else { return nil }
        for configurationID in configurationIDs {
            sessions.removeValue(forKey: configurationID)
            commandDrafts.removeValue(forKey: configurationID)
        }
        objectWillChange.send()
        return summary
    }

    func terminateAllForApplicationExit() -> Bool {
        var succeeded = true
        for session in sessions.values where session.state.isLive
            && !session.engine.signalProcessGroups(SIGKILL) {
            session.state = .stopping
            succeeded = false
        }
        guard succeeded else {
            objectWillChange.send()
            return false
        }
        sessions.removeAll()
        objectWillChange.send()
        return true
    }

    func closeTerminal(configurationID: String) {
        guard sessions[configurationID]?.state.isLive != true else { return }
        if sessions.removeValue(forKey: configurationID) != nil {
            objectWillChange.send()
        }
    }

    func clearTerminal(configurationID: String) {
        sessions[configurationID]?.engine.clearTerminal()
    }

    private func launch(_ request: ProjectRunTrustRequest) -> ProjectRunActionResult {
        guard isRunConfigurationEnabled(request.configuration) else { return .rejected("运行配置已禁用") }
        guard sessions[request.configuration.id]?.state.isLive != true else {
            return .rejected("该运行配置已有活动会话")
        }
        let session = sessions[request.configuration.id] ?? makeSession(for: request.configuration.id)
        session.currentExecution = ProjectRunExecution(
            configurationID: request.configuration.id,
            command: request.command,
            projectRoot: request.projectRoot,
            workingDirectory: request.workingDirectory
        )
        session.state = .starting
        objectWillChange.send()
        do {
            let directory = try ProjectRunWorkingDirectory.resolve(
                projectRoot: request.projectRoot,
                relativePath: request.configuration.workingDirectory
            )
            guard directory.path == request.workingDirectory else {
                throw ProjectRunLaunchError.reviewedWorkingDirectoryChanged
            }
            let shell = try shellProvider.defaultLoginShell()
            try session.engine.start(
                executable: shell,
                arguments: ["-i", "-c", request.command],
                loginName: "-\(URL(fileURLWithPath: shell).lastPathComponent)",
                workingDirectory: request.workingDirectory
            )
            session.lastSuccessfulCommand = request.command
            session.startedAt = Date()
            session.failureMessage = nil
            session.failureAt = nil
            session.state = .running
            if request.commandWasDraft,
               let currentConfiguration = projectsModel.runConfigurations().first(where: {
                   $0.id == request.configuration.id
               }) {
                let currentDraft = commandDrafts[request.configuration.id]
                if projectsModel.updateRunConfiguration(
                    currentConfiguration,
                    name: currentConfiguration.name,
                    command: request.command,
                    workingDirectory: currentConfiguration.workingDirectory
                ), currentDraft == request.command,
                   commandDrafts[request.configuration.id] == request.command {
                    commandDrafts.removeValue(forKey: request.configuration.id)
                }
            }
            objectWillChange.send()
            return .started
        } catch {
            return reject(configurationID: request.configuration.id, error: error)
        }
    }

    private func isRunConfigurationEnabled(_ configuration: ProjectRunConfiguration) -> Bool {
        projectsModel.runConfigurations().first { $0.id == configuration.id }?.isEnabled ?? configuration.isEnabled
    }

    private func makeSession(for configurationID: String) -> ProjectRunSession {
        let session = ProjectRunSession(configurationID: configurationID, engine: makeEngine())
        session.engine.onExit = { [weak self, weak session] exitCode in
            guard let self, let session else { return }
            if session.state.isStopping {
                session.pendingStopExitCode = exitCode
                if case .stopFailed = session.state {
                    session.state = .stopping
                    self.finishStopping(session)
                    self.objectWillChange.send()
                }
                return
            }
            if exitCode != 0 {
                session.failureMessage = "命令以状态码 \(exitCode ?? -1) 退出"
                session.failureAt = Date()
            }
            if session.engine.signalProcessGroups(SIGKILL) {
                session.state = .exited(exitCode ?? -1)
            } else {
                session.stopRequestedByUser = false
                session.state = .stopping
                session.pendingStopExitCode = exitCode
                self.finishStopping(session)
            }
            self.objectWillChange.send()
        }
        sessions[configurationID] = session
        return session
    }

    private func reject(configurationID: String, error: Error) -> ProjectRunActionResult {
        let message = error.localizedDescription
        let session = sessions[configurationID] ?? makeSession(for: configurationID)
        session.failureMessage = message
        session.failureAt = Date()
        if let launchError = error as? ProjectRunLaunchError,
           launchError == .previousProcessesStillRunning || launchError == .processCouldNotBeContained {
            session.state = .stopping
        } else {
            session.state = .launchFailed(message)
        }
        objectWillChange.send()
        return .rejected(message)
    }
}
