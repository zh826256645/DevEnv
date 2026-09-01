import AppKit
import Darwin
import SwiftTerm
import SwiftUI
import XCTest
@testable import DevEnv

@MainActor
final class ProjectRunSessionsTests: XCTestCase {
    func testPhysicalMemoryReadsCurrentProcess() throws {
        XCTAssertGreaterThan(
            try XCTUnwrap(ProjectRunPhysicalMemory.total(processIDs: [getpid()])),
            0
        )
    }

    func testPhysicalMemoryTotalsOwnedProcessesAndRejectsIncompleteSamples() {
        let footprints: [pid_t: UInt64] = [11: 40, 12: 60]

        XCTAssertEqual(
            ProjectRunPhysicalMemory.total(processIDs: [11, 12]) { footprints[$0] },
            100
        )
        XCTAssertNil(ProjectRunPhysicalMemory.total(processIDs: [11, 13]) { footprints[$0] })
        XCTAssertNil(ProjectRunPhysicalMemory.total(processIDs: [11, 12]) {
            $0 == 11 ? UInt64.max : 1
        })
    }

    func testOverviewAdaptsRunRowsBetweenTwoAndFour() {
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 322, itemCount: 4), 2)
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 351, itemCount: 4), 2)
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 352, itemCount: 4), 3)
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 404, itemCount: 4), 4)
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 440, itemCount: 5), 4)
    }

    func testOverviewShowsFourthAttentionWhenItFits() {
        XCTAssertEqual(overviewVisibleAttentionLimit(cardHeight: 283, itemCount: 4), 3)
        XCTAssertEqual(overviewVisibleAttentionLimit(cardHeight: 284, itemCount: 4), 4)
        XCTAssertEqual(overviewVisibleAttentionLimit(cardHeight: 319, itemCount: 5), 3)
        XCTAssertEqual(overviewVisibleAttentionLimit(cardHeight: 320, itemCount: 5), 4)
    }

    func testListenerBindingTextPreservesAddressFamily() {
        XCTAssertEqual(
            listenerBindingText(ListenerBinding(address: "*", port: 3070, family: .ipv4)),
            "0.0.0.0:3070"
        )
        XCTAssertEqual(
            listenerBindingText(ListenerBinding(address: "*", port: 3071, family: .ipv6)),
            "[::]:3071"
        )
    }

    func testSignalTargetsRejectUnsafeAndUnownedProcessGroups() {
        let ownedGroups = ProjectRunProcessOwnership.processGroups(
            in: [
                ProjectRunOwnedProcess(userID: 501, terminalDevice: 7, processGroup: 1),
                ProjectRunOwnedProcess(userID: 501, terminalDevice: 7, processGroup: 900),
                ProjectRunOwnedProcess(userID: 502, terminalDevice: 7, processGroup: 901),
                ProjectRunOwnedProcess(userID: 501, terminalDevice: 8, processGroup: 902),
                ProjectRunOwnedProcess(userID: 501, terminalDevice: 7, processGroup: 903),
            ],
            userID: 501,
            terminalDevice: 7
        )
        var sentGroups: [pid_t] = []
        var sentSignals: [Int32] = []

        let succeeded = ProjectRunSignalTargets.signal(
            SIGTERM,
            requestedGroups: [-5, 0, 1, 2, 900, 901, 902, 903],
            ownedGroups: ownedGroups.union([-5, 0, 1]),
            currentProcessGroup: { 900 },
            send: { group, signal in
                sentGroups.append(group)
                sentSignals.append(signal)
                return true
            }
        )

        XCTAssertEqual(ownedGroups, [900, 903])
        XCTAssertEqual(
            ProjectRunProcessOwnership.revalidatedGroup(witnessedGroup: 903, currentGroup: 903),
            903
        )
        XCTAssertNil(
            ProjectRunProcessOwnership.revalidatedGroup(witnessedGroup: 903, currentGroup: 904)
        )
        XCTAssertNil(
            ProjectRunProcessOwnership.revalidatedGroup(witnessedGroup: 1, currentGroup: 1)
        )
        XCTAssertTrue(succeeded)
        XCTAssertEqual(sentGroups, [903])
        XCTAssertEqual(sentSignals, [SIGTERM])
        XCTAssertNil(ProjectRunPTYOwnershipToken(masterDescriptor: -1))
    }

    func testConcurrentConfigurationsAreActiveFirstAndSurviveWindowRecreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstRoot = directory.appendingPathComponent("first")
        let secondRoot = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let projectsModel = ProjectsViewModel(
            store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        )
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        let first = ProjectRunConfiguration(
            id: "first",
            projectID: firstRoot.path,
            name: "前端",
            command: "npm run dev",
            workingDirectory: "."
        )
        let sameProject = ProjectRunConfiguration(
            id: "same-project",
            projectID: firstRoot.path,
            name: "测试",
            command: "npm test",
            workingDirectory: "."
        )
        let second = ProjectRunConfiguration(
            id: "second",
            projectID: secondRoot.path,
            name: "后端",
            command: "swift run",
            workingDirectory: "."
        )
        let inactive = ProjectRunConfiguration(
            id: "inactive",
            projectID: secondRoot.path,
            name: "未启动",
            command: "swift test",
            workingDirectory: "."
        )

        for configuration in [first, second] {
            guard case let .needsTrust(request) = coordinator.run(
                configuration,
                projectRoot: configuration.projectID
            ) else {
                return XCTFail("首次运行必须请求信任")
            }
            XCTAssertEqual(coordinator.confirmTrustAndRun(request), .started)
        }
        XCTAssertEqual(coordinator.run(sameProject, projectRoot: firstRoot.path), .started)
        let firstSession = try XCTUnwrap(coordinator.session(for: first.id))

        _ = ContentView(projectsModel: projectsModel, runCoordinator: coordinator)
        _ = ContentView(projectsModel: projectsModel, runCoordinator: coordinator)

        XCTAssertEqual(factory.engines.count, 3)
        XCTAssertTrue(coordinator.session(for: first.id) === firstSession)
        XCTAssertEqual(
            coordinator.activeConfigurationsFirst([inactive, second, sameProject, first]).map(\.id),
            [second.id, sameProject.id, first.id, inactive.id]
        )
    }

    func testUnavailableProjectCannotCreateAProcessEngine() throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: ProjectsViewModel(
                store: ProjectRecordStore(fileURL: storageDirectory.appendingPathComponent("records.json"))
            ),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        var project = ProjectRecord(path: "/Volumes/Missing/project", discoveredAt: Date())
        project.availability = .unavailable("项目根目录不存在")
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: project.id,
            name: "开发服务器",
            command: "npm run dev",
            workingDirectory: "."
        )

        XCTAssertEqual(
            coordinator.run(configuration, project: project),
            .rejected("项目不可用，不能执行：项目根目录不存在")
        )
        XCTAssertTrue(factory.engines.isEmpty)
        XCTAssertNil(coordinator.session(for: configuration.id))
    }

    func testSessionKeepsLaunchFactsAndOnlyRecordsUnexpectedFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let projectsModel = ProjectsViewModel(
            store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        )
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: directory.path,
            name: "开发服务器",
            command: "npm run dev",
            workingDirectory: "."
        )

        guard case let .needsTrust(request) = coordinator.run(configuration, projectRoot: directory.path) else {
            return XCTFail("首次运行必须请求信任")
        }
        XCTAssertEqual(coordinator.confirmTrustAndRun(request), .started)
        let firstSession = try XCTUnwrap(coordinator.session(for: configuration.id))
        XCTAssertEqual(firstSession.lastSuccessfulCommand, configuration.command)
        XCTAssertNotNil(firstSession.startedAt)
        XCTAssertEqual(firstSession.ownedProcessIDs, [42])

        factory.engines[0].finish(exitCode: 2)
        XCTAssertEqual(firstSession.failureMessage, "命令以状态码 2 退出")
        XCTAssertNotNil(firstSession.failureAt)

        XCTAssertEqual(coordinator.run(configuration, projectRoot: directory.path), .started)
        XCTAssertNil(firstSession.failureMessage)
        coordinator.stop(configurationID: configuration.id)
        factory.engines[0].finish(exitCode: 130)
        XCTAssertNil(firstSession.failureMessage)
    }

    func testRemovingProjectRecordCommitsStoreBeforeCleaningSessionsAndTrust() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstRoot = directory.appendingPathComponent("first")
        let secondRoot = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let first = ProjectRunConfiguration(
            id: "first",
            projectID: firstRoot.path,
            name: "前端",
            command: "sleep 30",
            workingDirectory: "."
        )
        let second = ProjectRunConfiguration(
            id: "second",
            projectID: secondRoot.path,
            name: "后端",
            command: "sleep 30",
            workingDirectory: "."
        )
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument(runConfigurations: [first, second])
        document.addDirect([firstRoot.path, secondRoot.path])
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        for configuration in [first, second] {
            guard case let .needsTrust(request) = coordinator.run(
                configuration,
                projectRoot: configuration.projectID
            ) else {
                return XCTFail("首次运行必须请求信任")
            }
            XCTAssertEqual(coordinator.confirmTrustAndRun(request), .started)
        }
        factory.engines[0].signalSucceeds = false

        XCTAssertNil(coordinator.removeProjects(projectIDs: [firstRoot.path]))
        XCTAssertEqual(factory.engines[0].signals, [SIGKILL])
        XCTAssertEqual(coordinator.session(for: first.id)?.state, .stopping)
        XCTAssertEqual(Set(projectsModel.runConfigurations().map(\.id)), [first.id, second.id])
        XCTAssertEqual(Set(try store.load().runConfigurations.map(\.id)), [first.id, second.id])
        factory.engines[0].signalSucceeds = true

        let summary = coordinator.removeProjects(projectIDs: [firstRoot.path])

        XCTAssertEqual(summary, ProjectRemovalSummary(projectCount: 1, ignoredProjectCount: 0))
        XCTAssertEqual(factory.engines[0].signals, [SIGKILL, SIGKILL])
        XCTAssertTrue(factory.engines[1].signals.isEmpty)
        XCTAssertNil(coordinator.session(for: first.id))
        XCTAssertNotNil(coordinator.session(for: second.id))
        XCTAssertEqual(projectsModel.runConfigurations().map(\.id), [second.id])
        XCTAssertEqual(try store.load().runConfigurations.map(\.id), [second.id])

        let relaunchedCoordinator = ProjectRunCoordinator(
            projectsModel: ProjectsViewModel(store: store),
            makeEngine: FakeProjectRunEngineFactory().makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        guard case .needsTrust = relaunchedCoordinator.run(first, projectRoot: firstRoot.path) else {
            return XCTFail("移除 Project Record 必须删除 Project Trust")
        }
        XCTAssertEqual(relaunchedCoordinator.run(second, projectRoot: secondRoot.path), .started)
    }

    func testFailedProjectRemovalPreservesSessionsConfigurationsAndTrust() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        let storageDirectory = directory.appendingPathComponent("storage")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: projectRoot.path,
            name: "服务",
            command: "sleep 30",
            workingDirectory: "."
        )
        let store = ProjectRecordStore(fileURL: storageDirectory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument(runConfigurations: [configuration])
        document.addDirect([projectRoot.path])
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        guard case let .needsTrust(request) = coordinator.run(
            configuration,
            projectRoot: projectRoot.path
        ) else {
            return XCTFail("首次运行必须请求信任")
        }
        XCTAssertEqual(coordinator.confirmTrustAndRun(request), .started)
        try FileManager.default.removeItem(at: storageDirectory)
        try Data().write(to: storageDirectory)

        XCTAssertNil(coordinator.removeProjects(projectIDs: [projectRoot.path]))
        XCTAssertTrue(factory.engines[0].signals.isEmpty)
        XCTAssertNotNil(coordinator.session(for: configuration.id))
        XCTAssertEqual(projectsModel.runConfigurations(), [configuration])

        let relaunchedCoordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: FakeProjectRunEngineFactory().makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        XCTAssertEqual(
            relaunchedCoordinator.run(configuration, projectRoot: projectRoot.path),
            .started
        )
    }

    func testFirstRunRequiresPersistentProjectTrustBeforeLaunching() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        let workingDirectory = projectRoot.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        let projectsModel = ProjectsViewModel(store: store)
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
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
            projectsModel: ProjectsViewModel(store: store),
            makeEngine: relaunchedFactory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        XCTAssertEqual(relaunchedCoordinator.run(configuration, projectRoot: projectRoot.path), .started)
        XCTAssertEqual(relaunchedFactory.engines.count, 1)
    }

    func testCoordinatorPersistsTrustAndCommitsAnEditedCommandOnlyAfterLaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: projectRoot.path,
            name: "服务",
            command: "printf old",
            workingDirectory: "."
        )
        var document = ProjectRecordDocument(runConfigurations: [configuration])
        document.addDirect([projectRoot.path])
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        let factory = FakeProjectRunEngineFactory()
        factory.startError = FakeProjectRunError.launchFailed
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        let draft = "  printf new\n"

        XCTAssertTrue(coordinator.updateRunConfiguration(
            configuration,
            name: configuration.name,
            command: draft,
            workingDirectory: configuration.workingDirectory
        ))
        let staged = try XCTUnwrap(coordinator.runConfigurations().first)
        XCTAssertEqual(staged.command, draft)
        XCTAssertEqual(try store.load().runConfigurations.first?.command, configuration.command)
        guard case let .needsTrust(request) = coordinator.run(staged, projectRoot: projectRoot.path) else {
            return XCTFail("首次运行必须请求信任")
        }
        XCTAssertEqual(request.command, draft)
        guard case .rejected = coordinator.confirmTrustAndRun(request) else {
            return XCTFail("启动失败必须保留 launch draft")
        }
        XCTAssertEqual(try store.load().trustedProjectRoots, [projectRoot.path])
        XCTAssertEqual(try store.load().runConfigurations.first?.command, configuration.command)

        factory.engines[0].startError = nil
        XCTAssertEqual(coordinator.run(staged, projectRoot: projectRoot.path), .started)
        XCTAssertEqual(try store.load().runConfigurations.first?.command, draft)
        XCTAssertEqual(coordinator.runConfigurations().first?.command, draft)
    }

    func testStopEscalatesTheProcessGroupAndApplicationExitKillsLiveSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let factory = FakeProjectRunEngineFactory()
        let scheduler = FakeProjectRunScheduler()
        let coordinator = ProjectRunCoordinator(
            projectsModel: ProjectsViewModel(
                store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
            ),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
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
        firstEngine.clearsOwnedProcessesOnKill = false
        XCTAssertEqual(coordinator.session(for: first.id)?.state, .stopping)
        XCTAssertEqual(firstEngine.signals, [SIGINT])
        firstEngine.finish(exitCode: 130)
        XCTAssertEqual(coordinator.session(for: first.id)?.state, .stopping)
        scheduler.runNext()
        XCTAssertEqual(firstEngine.signals, [SIGINT, SIGTERM])
        scheduler.runNext()
        XCTAssertEqual(firstEngine.signals, [SIGINT, SIGTERM, SIGKILL, 0])
        XCTAssertEqual(coordinator.session(for: first.id)?.state, .stopping)
        firstEngine.ownedProcessIDs = []
        scheduler.runNext()
        XCTAssertEqual(coordinator.session(for: first.id)?.state, .stopped(130))
        XCTAssertNil(coordinator.session(for: first.id)?.failureMessage)

        XCTAssertEqual(coordinator.run(second, projectRoot: projectRoot.path), .started)
        let secondEngine = try XCTUnwrap(factory.engines.last)
        secondEngine.signalSucceeds = false
        XCTAssertFalse(coordinator.terminateAllForApplicationExit())
        XCTAssertEqual(coordinator.session(for: second.id)?.state, .stopping)
        XCTAssertEqual(firstEngine.signals, [SIGINT, SIGTERM, SIGKILL, 0, 0])
        XCTAssertFalse(coordinator.sessions.isEmpty)
        secondEngine.signalSucceeds = true
        XCTAssertTrue(coordinator.terminateAllForApplicationExit())
        XCTAssertEqual(secondEngine.signals, [SIGKILL, SIGKILL])
        XCTAssertTrue(coordinator.sessions.isEmpty)
    }

    func testRestartWaitsForCleanupAndDoesNotLaunchWhenProcessesRemain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let factory = FakeProjectRunEngineFactory()
        let scheduler = FakeProjectRunScheduler()
        let coordinator = ProjectRunCoordinator(
            projectsModel: ProjectsViewModel(
                store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
            ),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: scheduler
        )
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: directory.path,
            name: "服务",
            command: "sleep 30",
            workingDirectory: "."
        )
        guard case let .needsTrust(request) = coordinator.run(configuration, projectRoot: directory.path) else {
            return XCTFail("首次运行必须请求信任")
        }
        XCTAssertEqual(coordinator.confirmTrustAndRun(request), .started)
        let engine = try XCTUnwrap(factory.engines.first)
        let terminal = engine.terminalView

        engine.signalSucceeds = false
        coordinator.restart(configuration, projectRoot: directory.path)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .restarting)
        XCTAssertEqual(engine.launches.count, 1)
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(
            coordinator.session(for: configuration.id)?.state,
            .restartFailed("上一次运行仍有进程未退出")
        )
        XCTAssertEqual(engine.launches.count, 1)

        engine.signalSucceeds = true
        coordinator.restart(configuration, projectRoot: directory.path)
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .running)
        XCTAssertEqual(engine.launches.count, 2)
        XCTAssertTrue(coordinator.session(for: configuration.id)?.terminalView === terminal)
    }

    func testStopFailureRemainsActiveAndNeedsAttention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let factory = FakeProjectRunEngineFactory()
        let scheduler = FakeProjectRunScheduler()
        let coordinator = ProjectRunCoordinator(
            projectsModel: ProjectsViewModel(
                store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
            ),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: scheduler
        )
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: directory.path,
            name: "服务",
            command: "sleep 30",
            workingDirectory: "."
        )
        guard case let .needsTrust(request) = coordinator.run(
            configuration,
            projectRoot: directory.path
        ) else {
            return XCTFail("首次运行必须请求信任")
        }
        XCTAssertEqual(coordinator.confirmTrustAndRun(request), .started)
        let engine = try XCTUnwrap(factory.engines.first)
        engine.signalSucceeds = false

        coordinator.stop(configurationID: configuration.id)
        scheduler.runNext()
        scheduler.runNext()

        XCTAssertEqual(
            coordinator.session(for: configuration.id)?.state,
            .stopFailed("仍有进程未退出")
        )
        XCTAssertEqual(
            coordinator.session(for: configuration.id)?.failureMessage,
            "停止失败：仍有进程未退出"
        )
        XCTAssertTrue(coordinator.session(for: configuration.id)?.state.isLive == true)

        engine.signalSucceeds = true
        engine.ownedProcessIDs = []
        engine.finish(exitCode: 130)

        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .stopped(130))
        XCTAssertNil(coordinator.session(for: configuration.id)?.failureMessage)
    }

    func testUnexpectedExitCleanupFailureConvergesAndKeepsExitSemantics() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let factory = FakeProjectRunEngineFactory()
        let scheduler = FakeProjectRunScheduler()
        let coordinator = ProjectRunCoordinator(
            projectsModel: ProjectsViewModel(
                store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
            ),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: scheduler
        )
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: directory.path,
            name: "服务",
            command: "exit 2",
            workingDirectory: "."
        )
        guard case let .needsTrust(request) = coordinator.run(
            configuration,
            projectRoot: directory.path
        ) else {
            return XCTFail("首次运行必须请求信任")
        }
        XCTAssertEqual(coordinator.confirmTrustAndRun(request), .started)
        let engine = try XCTUnwrap(factory.engines.first)
        engine.signalSucceeds = false

        engine.finish(exitCode: 2)
        for _ in 0..<10 { scheduler.runNext() }

        XCTAssertEqual(
            coordinator.session(for: configuration.id)?.state,
            .stopFailed("仍有进程未退出")
        )

        engine.signalSucceeds = true
        engine.ownedProcessIDs = []
        engine.finish(exitCode: 2)

        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .exited(2))
        XCTAssertEqual(
            coordinator.session(for: configuration.id)?.failureMessage,
            "命令以状态码 2 退出"
        )
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
        let factory = FakeProjectRunEngineFactory()
        let shellProvider = FakeProjectRunShellProvider(path: "/bin/zsh")
        let coordinator = ProjectRunCoordinator(
            projectsModel: ProjectsViewModel(
                store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
            ),
            makeEngine: factory.makeEngine,
            shellProvider: shellProvider,
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

    func testClearingTerminalRemovesVisibleContentAndScrollback() {
        let engine = SwiftTermProjectRunEngine()
        engine.terminal.feed(text: (1...100).map { "HISTORY:\($0)\n" }.joined())
        engine.terminal.feed(text: "\u{1B}[?1049hALTERNATE")

        engine.clearTerminal()

        for kind in [Terminal.BufferKind.normal, .alt] {
            let output = String(
                data: engine.terminal.terminal.getBufferAsData(kind: kind),
                encoding: .utf8
            ) ?? ""
            XCTAssertFalse(output.contains("HISTORY:"))
            XCTAssertFalse(output.contains("ALTERNATE"))
        }
    }

    func testRealSwiftTermRetainsHistoryWhenExpandedTerminalReturnsToDetailSize() async throws {
        let engine = SwiftTermProjectRunEngine()
        let exited = expectation(description: "终端退出")
        engine.onExit = { _ in exited.fulfill() }
        func terminalOutput() -> String {
            String(
                data: engine.terminal.terminal.getBufferAsData(kind: .normal),
                encoding: .utf8
            ) ?? ""
        }
        let model = ExpandedTerminalHarnessModel()
        let host = NSHostingController(rootView: ExpandedTerminalHarness(
            model: model,
            terminalView: engine.terminal
        ))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 280))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        try engine.start(
            executable: "/bin/zsh",
            arguments: ["-f", "-c", "for i in {1..1500}; do printf 'HISTORY:%05d\\n' $i; done; sleep 30"],
            loginName: "-zsh",
            workingDirectory: FileManager.default.temporaryDirectory.path
        )
        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: .seconds(5))
        while !terminalOutput().contains("HISTORY:01500"), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(terminalOutput().contains("HISTORY:00001"), "after detail mounting")
        XCTAssertTrue(terminalOutput().contains("HISTORY:01500"), "after detail mounting")

        model.isExpanded = true
        deadline = clock.now.advanced(by: .seconds(2))
        while engine.terminal.window === window, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(engine.terminal.window)
        XCTAssertTrue(terminalOutput().contains("HISTORY:00001"), "after expanding")
        XCTAssertTrue(terminalOutput().contains("HISTORY:01500"), "after expanding")

        model.isExpanded = false
        deadline = clock.now.advanced(by: .seconds(2))
        while engine.terminal.window !== window, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let output = terminalOutput()
        XCTAssertTrue(engine.terminal.window === window)
        XCTAssertNotNil(engine.terminal.superview)
        XCTAssertTrue(output.contains("HISTORY:00001"))
        XCTAssertTrue(output.contains("HISTORY:01500"))
        XCTAssertTrue(engine.signalProcessGroups(SIGKILL))
        await fulfillment(of: [exited], timeout: 5)
    }

    func testRealSwiftTermGrowsHistoryToTenThousandLineLimit() async throws {
        let engine = SwiftTermProjectRunEngine()
        engine.terminal.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        let exited = expectation(description: "日志输出完成")
        engine.onExit = { _ in exited.fulfill() }

        try engine.start(
            executable: "/bin/zsh",
            arguments: [
                "-f",
                "-c",
                "for i in {1..5000}; do printf 'LINE:%05d\\n' $i; done; read; "
                    + "for i in {5001..11000}; do printf 'LINE:%05d\\n' $i; done; sleep 30",
            ],
            loginName: "-zsh",
            workingDirectory: FileManager.default.temporaryDirectory.path
        )

        func terminalOutput() -> String {
            String(
                data: engine.terminal.terminal.getBufferAsData(kind: .normal),
                encoding: .utf8
            ) ?? ""
        }
        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: .seconds(5))
        while !terminalOutput().contains("LINE:05000"), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        var output = terminalOutput()
        XCTAssertEqual(engine.terminal.terminal.options.scrollback, 5_000)
        XCTAssertTrue(output.contains("LINE:00001"))
        XCTAssertTrue(output.contains("LINE:05000"))

        engine.terminal.process.send(data: [0x0A][...])
        deadline = clock.now.advanced(by: .seconds(5))
        while !terminalOutput().contains("LINE:11000"), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        output = terminalOutput()
        XCTAssertEqual(engine.terminal.terminal.options.scrollback, 10_000)
        XCTAssertFalse(output.contains("LINE:00001"))
        XCTAssertTrue(output.contains("LINE:11000"))

        engine.clearTerminal()
        XCTAssertEqual(engine.terminal.terminal.options.scrollback, TerminalOptions.default.scrollback)
        XCTAssertTrue(engine.signalProcessGroups(SIGKILL))
        await fulfillment(of: [exited], timeout: 5)
    }

    func testRealConcurrentSessionsRetainLongOutputAcrossWindowRecreationAndExitCleanly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstRoot = directory.appendingPathComponent("first")
        let secondRoot = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let projectsModel = ProjectsViewModel(
            store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        )
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: { SwiftTermProjectRunEngine() },
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        let first = ProjectRunConfiguration(
            id: "first",
            projectID: firstRoot.path,
            name: "长输出",
            command: "for i in {1..1500}; do printf 'FIRST:%s\\n' \"$i\"; done; sleep 30",
            workingDirectory: "."
        )
        let second = ProjectRunConfiguration(
            id: "second",
            projectID: secondRoot.path,
            name: "并发服务",
            command: "printf 'SECOND\\n'; sleep 30",
            workingDirectory: "."
        )
        let background = ProjectRunConfiguration(
            id: "background",
            projectID: firstRoot.path,
            name: "后台进程",
            command: #"/bin/sh -c 'trap "" HUP INT TERM; while :; do sleep 1; done' & child=$!; disown; printf 'BACKGROUND:%s\n' "$child"; sleep 1"#,
            workingDirectory: "."
        )
        for configuration in [first, second] {
            guard case let .needsTrust(request) = coordinator.run(
                configuration,
                projectRoot: configuration.projectID
            ) else {
                return XCTFail("首次运行必须请求信任")
            }
            XCTAssertEqual(coordinator.confirmTrustAndRun(request), .started)
        }
        XCTAssertEqual(coordinator.run(background, projectRoot: firstRoot.path), .started)
        let firstSession = try XCTUnwrap(coordinator.session(for: first.id))
        let secondSession = try XCTUnwrap(coordinator.session(for: second.id))
        let backgroundSession = try XCTUnwrap(coordinator.session(for: background.id))
        let firstTerminal = try XCTUnwrap(firstSession.terminalView as? LocalProcessTerminalView)
        let secondTerminal = try XCTUnwrap(secondSession.terminalView as? LocalProcessTerminalView)
        let backgroundTerminal = try XCTUnwrap(backgroundSession.terminalView as? LocalProcessTerminalView)
        func output(_ terminal: LocalProcessTerminalView) -> String {
            String(data: terminal.terminal.getBufferAsData(kind: .normal), encoding: .utf8) ?? ""
        }
        let clock = ContinuousClock()
        let outputDeadline = clock.now.advanced(by: .seconds(5))
        while (!output(firstTerminal).contains("FIRST:1500")
            || !output(secondTerminal).contains("SECOND")
            || !output(backgroundTerminal).contains("BACKGROUND:")),
              clock.now < outputDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        let firstHost = NSHostingController(rootView: AnyView(
            ProjectTerminalView(terminalView: firstTerminal).id(first.id)
        ))
        let firstWindow = NSWindow(contentViewController: firstHost)
        firstWindow.isReleasedWhenClosed = false
        firstWindow.setContentSize(NSSize(width: 900, height: 500))
        firstWindow.makeKeyAndOrderFront(nil)
        firstWindow.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(firstTerminal.window === firstWindow)

        firstWindow.close()
        let reopenedHost = NSHostingController(rootView: AnyView(
            ProjectTerminalView(terminalView: secondTerminal).id(second.id)
        ))
        let reopenedWindow = NSWindow(contentViewController: reopenedHost)
        reopenedWindow.isReleasedWhenClosed = false
        reopenedWindow.setContentSize(NSSize(width: 900, height: 500))
        reopenedWindow.makeKeyAndOrderFront(nil)
        reopenedWindow.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(secondTerminal.window === reopenedWindow)

        reopenedHost.rootView = AnyView(ProjectTerminalView(terminalView: firstTerminal).id(first.id))
        reopenedWindow.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(firstTerminal.window === reopenedWindow)

        XCTAssertTrue(output(firstTerminal).contains("FIRST:1500"))
        XCTAssertTrue(output(secondTerminal).contains("SECOND"))
        XCTAssertTrue(coordinator.session(for: first.id) === firstSession)
        XCTAssertTrue(coordinator.session(for: second.id) === secondSession)
        let processIDs = [firstTerminal.process.shellPid, secondTerminal.process.shellPid]
        let backgroundOutput = output(backgroundTerminal)
        let backgroundRange = try XCTUnwrap(
            backgroundOutput.range(of: #"BACKGROUND:\d+"#, options: .regularExpression)
        )
        let backgroundPID = try XCTUnwrap(
            pid_t(backgroundOutput[backgroundRange].dropFirst("BACKGROUND:".count))
        )
        var backgroundNeedsCleanup = true
        defer { if backgroundNeedsCleanup { Darwin.kill(backgroundPID, SIGKILL) } }
        let backgroundExitDeadline = clock.now.advanced(by: .seconds(5))
        while backgroundSession.state.isLive, clock.now < backgroundExitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        while Darwin.kill(backgroundPID, 0) == 0, clock.now < backgroundExitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        backgroundNeedsCleanup = Darwin.kill(backgroundPID, 0) == 0
        XCTAssertFalse(backgroundNeedsCleanup, "根 Shell 退出时必须清理同一会话的后台进程")

        let appDelegate = DevEnvAppDelegate(
            projectsModel: projectsModel,
            runCoordinator: coordinator
        )
        XCTAssertEqual(appDelegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        let exitDeadline = clock.now.advanced(by: .seconds(2))
        while processIDs.contains(where: { Darwin.kill($0, 0) == 0 }), clock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        reopenedWindow.close()
        XCTAssertTrue(coordinator.sessions.isEmpty)
        XCTAssertTrue(processIDs.allSatisfy { Darwin.kill($0, 0) != 0 })
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
                #"/bin/sh -c 'trap "" INT TERM HUP; printf "CHILD_READY\n"; while :; do :; done' & printf 'CHILD:%s\n' "$!"; trap 'kill -KILL $$' INT; while :; do :; done"#,
            ],
            loginName: "-zsh",
            workingDirectory: FileManager.default.temporaryDirectory.path
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while (!output().contains("CHILD:") || !output().contains("CHILD_READY")),
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let renderedOutput = output()
        let childRange = try XCTUnwrap(
            renderedOutput.range(of: #"CHILD:\d+"#, options: .regularExpression)
        )
        let childPID = try XCTUnwrap(pid_t(renderedOutput[childRange].dropFirst("CHILD:".count)))
        var childNeedsCleanup = true
        defer { if childNeedsCleanup { Darwin.kill(childPID, SIGKILL) } }
        func isRunning(_ processID: pid_t) -> Bool {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size
                && info.pbi_status != SZOMB
        }

        _ = engine.signalProcessGroups(SIGINT)

        await fulfillment(of: [exited], timeout: 5)
        XCTAssertTrue(isRunning(childPID), "子进程未忽略 SIGINT")
        _ = engine.signalProcessGroups(SIGTERM)
        XCTAssertTrue(isRunning(childPID), "子进程未忽略 SIGTERM")
        _ = engine.signalProcessGroups(SIGKILL)
        let cleanupDeadline = clock.now.advanced(by: .seconds(2))
        while isRunning(childPID), clock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        childNeedsCleanup = isRunning(childPID)
        XCTAssertFalse(childNeedsCleanup, "后台子进程仍然存活：\(childPID)")
    }
}

@MainActor
private final class ExpandedTerminalHarnessModel: ObservableObject {
    @Published var isExpanded = false
}

private struct ExpandedTerminalHarness: View {
    @ObservedObject var model: ExpandedTerminalHarnessModel
    let terminalView: NSView

    var body: some View {
        Group {
            if !model.isExpanded {
                ProjectTerminalView(terminalView: terminalView)
            }
        }
        .frame(minWidth: 640, minHeight: 280)
        .sheet(isPresented: $model.isExpanded) {
            ProjectTerminalView(terminalView: terminalView)
                .frame(minWidth: 900, minHeight: 500)
        }
    }
}

@MainActor
private final class FakeProjectRunEngineFactory {
    private(set) var engines: [FakeProjectRunEngine] = []
    var startError: Error?

    func makeEngine() -> any ProjectRunProcessEngine {
        let engine = FakeProjectRunEngine()
        engine.startError = startError
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
    var ownedProcessIDs: Set<pid_t>? = [42]
    var physicalMemoryBytes: UInt64? = 128 * 1_024 * 1_024
    private(set) var launches: [Launch] = []
    private(set) var signals: [Int32] = []
    var signalSucceeds = true
    var clearsOwnedProcessesOnKill = true
    var startError: Error?

    func clearTerminal() {}

    func start(
        executable: String,
        arguments: [String],
        loginName: String,
        workingDirectory: String
    ) throws {
        if let startError { throw startError }
        launches.append(.init(
            executable: executable,
            arguments: arguments,
            loginName: loginName,
            workingDirectory: workingDirectory
        ))
    }

    func signalProcessGroups(_ signal: Int32) -> Bool {
        signals.append(signal)
        if signal == SIGKILL, signalSucceeds, clearsOwnedProcessesOnKill {
            ownedProcessIDs = []
        }
        return signalSucceeds
    }

    func finish(exitCode: Int32?) {
        onExit?(exitCode)
    }
}

private enum FakeProjectRunError: LocalizedError {
    case unavailableShell
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .unavailableShell: "Default Login Shell 不可用"
        case .launchFailed: "PTY 启动失败"
        }
    }
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
