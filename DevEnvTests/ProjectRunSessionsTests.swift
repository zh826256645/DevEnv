import AppKit
import Darwin
import XCTest
@testable import DevEnv

@MainActor
final class ProjectRunSessionsTests: XCTestCase {
    func testFirstRunRequiresPersistentProjectTrustBeforeLaunching() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        let workingDirectory = projectRoot.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let defaultsName = "ProjectRunSessionsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            engineFactory: factory,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            defaults: defaults,
            scheduler: FakeProjectRunScheduler()
        )
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: projectRoot.path,
            name: "开发服务器",
            command: "printf '\u{1b}[31mred\u{1b}[0m\\n'",
            workingDirectory: "scripts"
        )

        let request: ProjectRunTrustRequest
        switch coordinator.run(configuration, projectRoot: projectRoot.path) {
        case let .needsTrust(pendingRequest):
            request = pendingRequest
        default:
            return XCTFail("首次运行必须先请求 Project Trust")
        }

        XCTAssertEqual(request.command, configuration.command)
        XCTAssertEqual(request.workingDirectory, workingDirectory.path)
        XCTAssertTrue(factory.engines.isEmpty)
        XCTAssertEqual(coordinator.confirmTrustAndRun(request), .started)
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.launches, [
            .init(
                executable: "/bin/zsh",
                arguments: ["-i", "-c", configuration.command],
                loginName: "-zsh",
                workingDirectory: workingDirectory.path
            ),
        ])
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .running)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.lastSuccessfulCommand, configuration.command)

        let relaunchedFactory = FakeProjectRunEngineFactory()
        let relaunchedCoordinator = ProjectRunCoordinator(
            engineFactory: relaunchedFactory,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            defaults: defaults,
            scheduler: FakeProjectRunScheduler()
        )
        XCTAssertEqual(relaunchedCoordinator.run(configuration, projectRoot: projectRoot.path), .started)
        XCTAssertEqual(relaunchedFactory.engines.count, 1)
    }

    func testStopEscalatesTheProcessGroupAndApplicationExitKillsLiveSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let defaultsName = "ProjectRunSessionsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let factory = FakeProjectRunEngineFactory()
        let scheduler = FakeProjectRunScheduler()
        let coordinator = ProjectRunCoordinator(
            engineFactory: factory,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            defaults: defaults,
            scheduler: scheduler
        )
        let first = ProjectRunConfiguration(
            id: "first",
            projectID: projectRoot.path,
            name: "服务",
            command: "sleep 30",
            workingDirectory: "."
        )
        let second = ProjectRunConfiguration(
            id: "second",
            projectID: projectRoot.path,
            name: "工作进程",
            command: "sleep 30 & wait",
            workingDirectory: "."
        )
        guard case let .needsTrust(request) = coordinator.run(first, projectRoot: projectRoot.path) else {
            return XCTFail("首次运行必须请求信任")
        }
        XCTAssertEqual(coordinator.confirmTrustAndRun(request), .started)
        XCTAssertEqual(coordinator.run(first, projectRoot: projectRoot.path), .rejected("该运行配置已有活动会话"))

        coordinator.stop(configurationID: first.id)

        let firstEngine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(coordinator.session(for: first.id)?.state, .stopping)
        XCTAssertEqual(firstEngine.signals, [SIGINT])
        firstEngine.finish(exitCode: 130)
        XCTAssertEqual(coordinator.session(for: first.id)?.state, .stopping)
        scheduler.runNext()
        XCTAssertEqual(firstEngine.signals, [SIGINT, SIGTERM])
        scheduler.runNext()
        XCTAssertEqual(firstEngine.signals, [SIGINT, SIGTERM, SIGKILL])
        XCTAssertEqual(coordinator.session(for: first.id)?.state, .exited(130))

        XCTAssertEqual(coordinator.run(second, projectRoot: projectRoot.path), .started)
        let secondEngine = try XCTUnwrap(factory.engines.last)
        coordinator.terminateAllForApplicationExit()
        XCTAssertEqual(secondEngine.signals, [SIGKILL])
    }

    func testRerunRevalidatesPathAndShellWithoutDiscardingTheTerminal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        let workingDirectory = projectRoot.appendingPathComponent("scripts")
        let outside = directory.appendingPathComponent("outside")
        for item in [workingDirectory, outside] {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        }
        let defaultsName = "ProjectRunSessionsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let factory = FakeProjectRunEngineFactory()
        let shellProvider = FakeProjectRunShellProvider(path: "/bin/zsh")
        let coordinator = ProjectRunCoordinator(
            engineFactory: factory,
            shellProvider: shellProvider,
            defaults: defaults,
            scheduler: FakeProjectRunScheduler()
        )
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: projectRoot.path,
            name: "测试",
            command: "exit 7",
            workingDirectory: "scripts"
        )
        guard case let .needsTrust(request) = coordinator.run(configuration, projectRoot: projectRoot.path) else {
            return XCTFail("首次运行必须请求信任")
        }
        XCTAssertEqual(coordinator.confirmTrustAndRun(request), .started)
        let engine = try XCTUnwrap(factory.engines.first)
        let retainedTerminal = engine.terminalView
        engine.finish(exitCode: 7)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .exited(7))

        var rerun = configuration
        rerun.command = "exit 0"
        XCTAssertEqual(coordinator.run(rerun, projectRoot: projectRoot.path), .started)
        XCTAssertTrue(coordinator.session(for: configuration.id)?.terminalView === retainedTerminal)
        engine.finish(exitCode: 0)

        try FileManager.default.removeItem(at: workingDirectory)
        try FileManager.default.createSymbolicLink(at: workingDirectory, withDestinationURL: outside)
        guard case .rejected = coordinator.run(rerun, projectRoot: projectRoot.path) else {
            return XCTFail("符号链接逃逸必须拒绝")
        }
        XCTAssertEqual(engine.launches.count, 2)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.lastSuccessfulCommand, "exit 0")

        try FileManager.default.removeItem(at: workingDirectory)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: false)
        shellProvider.error = FakeProjectRunError.unavailableShell
        guard case .rejected = coordinator.run(rerun, projectRoot: projectRoot.path) else {
            return XCTFail("Default Login Shell 不可用时必须拒绝")
        }
        XCTAssertEqual(engine.launches.count, 2)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.lastSuccessfulCommand, "exit 0")

        coordinator.closeTerminal(configurationID: configuration.id)
        XCTAssertNil(coordinator.session(for: configuration.id))
        shellProvider.error = nil
        XCTAssertEqual(coordinator.run(rerun, projectRoot: projectRoot.path), .started)
        XCTAssertEqual(factory.engines.count, 2)
        XCTAssertFalse(coordinator.session(for: configuration.id)?.terminalView === retainedTerminal)
    }

    func testRealSwiftTermAcceptanceCoversANSIInputResizeInterruptAndExitCode() async throws {
        let engine = SwiftTermProjectRunEngine()
        engine.terminal.frame = NSRect(x: 0, y: 0, width: 900, height: 360)
        let exited = expectation(description: "真实 SwiftTerm 会话退出")
        var exitCode: Int32?
        engine.onExit = { code in
            exitCode = code
            exited.fulfill()
        }
        let command = #"printf '\033[31mANSI\033[0m\n'; read value; printf 'INPUT:%s\n' "$value"; /bin/sh -c 'trap "exit 7" INT; printf "READY\n"; while :; do :; done'"#
        func output() -> String {
            String(
                data: engine.terminal.terminal.getBufferAsData(kind: .normal),
                encoding: .utf8
            ) ?? ""
        }

        try engine.start(
            executable: "/bin/zsh",
            arguments: ["-i", "-c", command],
            loginName: "-zsh",
            workingDirectory: FileManager.default.temporaryDirectory.path
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !output().contains("ANSI"), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let input = Array("hello\n".utf8)
        engine.terminal.process.send(data: input[...])
        engine.terminal.setFrameSize(NSSize(width: 720, height: 300))
        while !output().contains("READY"), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(output().contains("READY"))
        let interrupt: [UInt8] = [0x03]
        engine.terminal.process.send(data: interrupt[...])

        await fulfillment(of: [exited], timeout: 5)
        let renderedOutput = output()
        XCTAssertEqual(exitCode, 7, renderedOutput)
        XCTAssertTrue(renderedOutput.contains("ANSI"))
        XCTAssertTrue(renderedOutput.contains("INPUT:hello"))
    }

    func testRealEngineStopEscalationKillsBackgroundProcessGroupsAfterShellExit() async throws {
        let engine = SwiftTermProjectRunEngine()
        engine.terminal.frame = NSRect(x: 0, y: 0, width: 900, height: 360)
        let exited = expectation(description: "真实 SwiftTerm 会话退出")
        engine.onExit = { _ in exited.fulfill() }
        func output() -> String {
            String(
                data: engine.terminal.terminal.getBufferAsData(kind: .normal),
                encoding: .utf8
            ) ?? ""
        }

        try engine.start(
            executable: "/bin/zsh",
            arguments: [
                "-f",
                "-i",
                "-c",
                #"/bin/sh -c 'trap "" INT TERM HUP; while :; do :; done' & printf 'CHILD:%s\n' "$!"; trap 'kill -KILL $$' INT; while :; do :; done"#,
            ],
            loginName: "-zsh",
            workingDirectory: FileManager.default.temporaryDirectory.path
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !output().contains("CHILD:"), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let renderedOutput = output()
        let childRange = try XCTUnwrap(
            renderedOutput.range(of: #"CHILD:\d+"#, options: .regularExpression)
        )
        let childPID = try XCTUnwrap(pid_t(renderedOutput[childRange].dropFirst("CHILD:".count)))
        var childNeedsCleanup = true
        defer { if childNeedsCleanup { Darwin.kill(childPID, SIGKILL) } }

        engine.signalProcessGroups(SIGINT)

        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(Darwin.kill(childPID, 0), 0, "子进程未忽略 SIGINT")
        engine.signalProcessGroups(SIGTERM)
        XCTAssertEqual(Darwin.kill(childPID, 0), 0, "子进程未忽略 SIGTERM")
        engine.signalProcessGroups(SIGKILL)
        let cleanupDeadline = clock.now.advanced(by: .seconds(2))
        while Darwin.kill(childPID, 0) == 0, clock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        childNeedsCleanup = Darwin.kill(childPID, 0) == 0
        XCTAssertFalse(childNeedsCleanup, "后台子进程仍然存活：\(childPID)")
    }
}

@MainActor
private final class FakeProjectRunEngineFactory: ProjectRunEngineFactory {
    private(set) var engines: [FakeProjectRunEngine] = []

    func makeEngine() -> any ProjectRunProcessEngine {
        let engine = FakeProjectRunEngine()
        engines.append(engine)
        return engine
    }
}

@MainActor
private final class FakeProjectRunEngine: ProjectRunProcessEngine {
    struct Launch: Equatable {
        let executable: String
        let arguments: [String]
        let loginName: String
        let workingDirectory: String
    }

    let terminalView = NSView()
    var onExit: ((Int32?) -> Void)?
    private(set) var launches: [Launch] = []
    private(set) var signals: [Int32] = []

    func start(
        executable: String,
        arguments: [String],
        loginName: String,
        workingDirectory: String
    ) throws {
        launches.append(.init(
            executable: executable,
            arguments: arguments,
            loginName: loginName,
            workingDirectory: workingDirectory
        ))
    }

    func signalProcessGroups(_ signal: Int32) {
        signals.append(signal)
    }

    func finish(exitCode: Int32?) {
        onExit?(exitCode)
    }
}

private enum FakeProjectRunError: LocalizedError {
    case unavailableShell

    var errorDescription: String? { "Default Login Shell 不可用" }
}

private final class FakeProjectRunShellProvider: ProjectRunShellProviding {
    let path: String
    var error: Error?

    init(path: String) {
        self.path = path
    }

    func defaultLoginShell() throws -> String {
        if let error { throw error }
        return path
    }
}

@MainActor
private final class FakeProjectRunScheduler: ProjectRunScheduling {
    private(set) var actions: [() -> Void] = []

    func schedule(after _: Duration, _ action: @escaping () -> Void) {
        actions.append(action)
    }

    func runNext() {
        actions.removeFirst()()
    }
}
