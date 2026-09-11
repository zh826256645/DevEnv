import AppKit
import Darwin
import SwiftTerm
import SwiftUI
import XCTest
@testable import DevEnv

@MainActor
final class ProjectRunSessionsTests: XCTestCase {
    func testWorkspaceRunFiltersPreserveLifecycleAndSearchProjectNames() {
        var configuration = ProjectRunConfiguration(name: "Web 前端", command: "npm run dev", workingDirectory: "")
        let cases: [(ProjectRunSessionState, Set<RunListStatusFilter>)] = [
            (.inactive, [.all, .inactive]),
            (.starting, [.all, .active]),
            (.running, [.all, .active]),
            (.stopping, [.all, .active]),
            (.restarting, [.all, .active]),
            (.stopFailed("busy"), [.all, .active, .failed]),
            (.restartFailed("busy"), [.all, .active, .failed]),
            (.stopped(0), [.all, .ended]),
            (.exited(0), [.all, .ended]),
            (.exited(1), [.all, .failed]),
            (.launchFailed("missing directory"), [.all, .failed]),
        ]
        for (state, expected) in cases {
            for filter in RunListStatusFilter.allCases {
                XCTAssertEqual(filter.includes(configuration, state: state, searchText: "", projectTitle: "收付宝"), expected.contains(filter))
            }
        }
        for query in [" web ", "NPM", "收付宝", "  "] {
            XCTAssertTrue(RunListStatusFilter.all.includes(configuration, state: .inactive, searchText: query, projectTitle: "收付宝"))
        }
        XCTAssertFalse(RunListStatusFilter.all.includes(configuration, state: .inactive, searchText: "不存在", projectTitle: "收付宝"))
        configuration.isEnabled = false
        for filter in RunListStatusFilter.allCases {
            XCTAssertEqual(filter.includes(configuration, state: .exited(1), searchText: "", projectTitle: "收付宝"), filter == .all || filter == .disabled)
        }
    }

    func testAddingParentPreservesChildRunsAndDetachedDirectoriesAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("parent")
        let child = parent.appendingPathComponent("child")
        let scripts = child.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let manifest = child.appendingPathComponent("package.json")
        try Data("{}".utf8).write(to: manifest)
        let fixture = try ProjectRunTestFixture(directory: directory, configurations: [], projectRoots: [child])
        let coordinator = fixture.coordinator
        let cases = [("", child.path), ("scripts", scripts.path), ("..", parent.path), (directory.path, directory.path)]
        let configurations = try cases.enumerated().map { index, entry in
            try XCTUnwrap(coordinator.createRunConfiguration(
                projectID: child.path, name: "运行 \(index)", command: "pwd", workingDirectory: entry.0,
                sourceIdentity: "source-\(index)", sourceProjectID: child.path
            ))
        }
        XCTAssertEqual(coordinator.run(configurations[0]), .started)
        let execution = try XCTUnwrap(coordinator.session(for: configurations[0].id)?.activeExecution)

        let before = fixture.projectsModel.document
        let recordsFile = directory.appendingPathComponent("records.json")
        try FileManager.default.removeItem(at: recordsFile)
        try FileManager.default.createDirectory(at: recordsFile, withIntermediateDirectories: false)
        fixture.projectsModel.addDirect([parent])
        XCTAssertEqual(fixture.projectsModel.document, before)
        XCTAssertNotNil(fixture.projectsModel.operationError)
        try FileManager.default.removeItem(at: recordsFile)
        try fixture.store.save(before)

        fixture.projectsModel.addDirect([parent])
        XCTAssertFalse(fixture.projectsModel.records.contains { $0.id == child.path })
        XCTAssertTrue(fixture.projectsModel.ignoredProjects.isEmpty)
        XCTAssertEqual(coordinator.session(for: configurations[0].id)?.activeExecution, execution)
        let reloaded = ProjectsViewModel(store: fixture.store)
        let factory = FakeProjectRunEngineFactory()
        let restoredCoordinator = ProjectRunCoordinator(
            projectsModel: reloaded, makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"), scheduler: FakeProjectRunScheduler()
        )
        for (configuration, entry) in zip(configurations, cases) {
            var retained = try XCTUnwrap(restoredCoordinator.runConfigurations().first { $0.id == configuration.id })
            XCTAssertEqual(retained.deletedProjectTitle, "child")
            XCTAssertEqual(retained.deletedProjectPath, child.path)
            XCTAssertEqual(retained.workingDirectory, entry.1)
            XCTAssertEqual(retained.sourceIdentity, configuration.sourceIdentity)
            XCTAssertEqual(retained.sourceProjectID, configuration.sourceProjectID)
            XCTAssertEqual(restoredCoordinator.run(retained), .rejected(ProjectRunConfigurationError.projectNotFound.localizedDescription))
            retained.projectID = nil
            XCTAssertTrue(restoredCoordinator.updateRunConfiguration(
                retained, name: retained.name, command: retained.command, workingDirectory: retained.workingDirectory
            ))
            let detached = try XCTUnwrap(restoredCoordinator.runConfigurations().first { $0.id == configuration.id })
            XCTAssertEqual(restoredCoordinator.run(detached), .started)
            XCTAssertEqual(restoredCoordinator.session(for: detached.id)?.activeExecution?.workingDirectory, entry.1)
            XCTAssertEqual(factory.engines.last?.launches.last?.workingDirectory, entry.1)
        }
        XCTAssertEqual(try Data(contentsOf: manifest), Data("{}".utf8))
    }

    func testProjectRemovalCannotInterruptAnAlreadyStoppingConfigurationDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ProjectRunTestFixture(directory: directory, configurations: [], projectRoots: [directory])
        let coordinator = fixture.coordinator
        let configuration = try XCTUnwrap(coordinator.createRunConfiguration(
            projectID: directory.path, name: "删除", command: "pwd", workingDirectory: ""
        ))
        XCTAssertEqual(coordinator.run(configuration), .started)
        coordinator.stop(configurationID: configuration.id)
        coordinator.requestDeletion(configurationID: configuration.id)
        coordinator.confirmDeletion()
        XCTAssertNil(coordinator.removeProjects(projectIDs: [directory.path]))
        fixture.scheduler.runNext()
        fixture.scheduler.runNext()
        XCTAssertNil(coordinator.activeDeletion)
        XCTAssertTrue(coordinator.runConfigurations().isEmpty)
        XCTAssertEqual(fixture.projectsModel.records.count, 1)
    }

    func testDeletionSaveFailureRetainsRecordsAndCanRetryWithoutRestartingProcesses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ProjectRunTestFixture(directory: directory, configurations: [], projectRoots: [directory])
        let coordinator = fixture.coordinator
        let configuration = try XCTUnwrap(coordinator.createRunConfiguration(name: "保存失败", command: "pwd", workingDirectory: ""))
        XCTAssertEqual(coordinator.run(configuration), .started)
        let before = fixture.projectsModel.document
        let records = directory.appendingPathComponent("records.json")
        try FileManager.default.removeItem(at: records)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false)
        coordinator.requestDeletion(workspaceID: Workspace.defaultWorkspace.id)
        coordinator.confirmDeletion()
        fixture.scheduler.runNext()
        fixture.scheduler.runNext()
        XCTAssertEqual(fixture.projectsModel.document, before)
        XCTAssertNotNil(coordinator.deletionError)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .stopped(137))
        try FileManager.default.removeItem(at: records)
        coordinator.requestDeletion(workspaceID: Workspace.defaultWorkspace.id)
        coordinator.confirmDeletion()
        XCTAssertNil(coordinator.deletionError)
        XCTAssertTrue(try fixture.store.load().workspaces.isEmpty)
        XCTAssertEqual(fixture.factory.engines[0].launches.count, 1)
    }

    func testDeletionRejectsReplacementExecutionAndCancelsPendingRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ProjectRunTestFixture(directory: directory, configurations: [], projectRoots: [])
        let coordinator = fixture.coordinator
        let configuration = try XCTUnwrap(coordinator.createRunConfiguration(name: "替代执行", command: "pwd", workingDirectory: ""))
        XCTAssertEqual(coordinator.run(configuration), .started)
        coordinator.requestDeletion(configurationID: configuration.id)
        coordinator.restart(configuration)
        fixture.scheduler.runNext()
        fixture.scheduler.runNext()
        fixture.factory.engines[0].ownedProcessIDs = [42]
        coordinator.confirmDeletion()
        XCTAssertNotNil(coordinator.deletionError)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .running)
        coordinator.restart(configuration)
        coordinator.requestDeletion(configurationID: configuration.id)
        coordinator.confirmDeletion()
        XCTAssertEqual(coordinator.run(configuration), .rejected("正在删除运行配置"))
        coordinator.restart(configuration)
        fixture.scheduler.runNext()
        fixture.scheduler.runNext()
        XCTAssertTrue(coordinator.runConfigurations().isEmpty)
        XCTAssertNil(coordinator.session(for: configuration.id))
        XCTAssertEqual(fixture.factory.engines[0].launches.count, 2)
    }

    func testWorkspaceDeletionFailureKeepsAllRecordsAndOtherWorkspaceRunThenRetries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ProjectRunTestFixture(directory: directory, configurations: [], projectRoots: [directory])
        let coordinator = fixture.coordinator
        let first = try XCTUnwrap(coordinator.createRunConfiguration(name: "一", command: "pwd", workingDirectory: directory.path))
        let second = try XCTUnwrap(coordinator.createRunConfiguration(name: "二", command: "pwd", workingDirectory: directory.path))
        let otherWorkspace = try XCTUnwrap(fixture.projectsModel.createWorkspace(name: "其他"))
        let other = try XCTUnwrap(coordinator.createRunConfiguration(name: "其他", command: "pwd", workingDirectory: directory.path))
        for configuration in [first, second, other] { XCTAssertEqual(coordinator.run(configuration), .started) }
        fixture.factory.engines[1].signalSucceeds = false
        coordinator.requestDeletion(workspaceID: Workspace.defaultWorkspace.id)
        coordinator.confirmDeletion()
        for _ in 0 ..< 4 { fixture.scheduler.runNext() }
        XCTAssertNotNil(coordinator.deletionError)
        XCTAssertNil(coordinator.activeDeletion)
        XCTAssertEqual(coordinator.runConfigurations().count, 3)
        XCTAssertEqual(fixture.projectsModel.document.workspaces.count, 2)
        XCTAssertTrue(coordinator.session(for: second.id)?.state.isLive == true)
        XCTAssertTrue(fixture.factory.engines[2].signals.isEmpty)
        fixture.factory.engines[1].signalSucceeds = true
        coordinator.requestDeletion(workspaceID: Workspace.defaultWorkspace.id)
        coordinator.confirmDeletion()
        for _ in 0 ..< 8 where coordinator.activeDeletion != nil { fixture.scheduler.runNext() }
        XCTAssertNil(coordinator.deletionError)
        XCTAssertEqual(coordinator.runConfigurations(), [other])
        XCTAssertEqual(fixture.projectsModel.document.workspaces, [otherWorkspace])
        XCTAssertEqual(coordinator.session(for: other.id)?.state, .running)
        XCTAssertTrue(fixture.factory.engines[2].signals.isEmpty)
        XCTAssertEqual(try fixture.store.load(), fixture.projectsModel.document)
    }

    func testDeletingLastWorkspacePreservesFilesAndRejectsStaleStarts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ProjectRunTestFixture(directory: directory, configurations: [], projectRoots: [directory])
        let file = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        let coordinator = fixture.coordinator
        let configuration = try XCTUnwrap(coordinator.createRunConfiguration(name: "待删除", command: "pwd", workingDirectory: ""))
        let start = coordinator.makeBatchStartIntent(in: [configuration])
        coordinator.requestDeletion(workspaceID: Workspace.defaultWorkspace.id)
        coordinator.confirmDeletion()
        XCTAssertTrue(fixture.projectsModel.document.workspaces.isEmpty)
        XCTAssertTrue(fixture.projectsModel.records.isEmpty)
        XCTAssertEqual(try fixture.store.load().selectedWorkspaceID, "")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
        coordinator.submitBatchStart(start)
        XCTAssertNil(coordinator.session(for: configuration.id))
        XCTAssertNil(coordinator.createRunConfiguration(name: "无工作区", command: "pwd", workingDirectory: ""))
        fixture.projectsModel.addDirect([directory])
        XCTAssertTrue(fixture.projectsModel.records.isEmpty)
        XCTAssertNotNil(fixture.projectsModel.createWorkspace(name: "重新开始"))
        XCTAssertNotNil(coordinator.createRunConfiguration(name: "新配置", command: "pwd", workingDirectory: ""))
        XCTAssertEqual(try fixture.store.load(), fixture.projectsModel.document)
    }

    func testDeletionWaitsForSafeStopAndCancelDoesNothing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ProjectRunTestFixture(directory: directory, configurations: [], projectRoots: [])
        let coordinator = fixture.coordinator
        let configuration = try XCTUnwrap(coordinator.createRunConfiguration(name: "删除", command: "pwd", workingDirectory: ""))
        let sibling = try XCTUnwrap(coordinator.createRunConfiguration(name: "保留", command: "pwd", workingDirectory: ""))
        XCTAssertEqual(coordinator.run(configuration), .started)
        XCTAssertEqual(coordinator.run(sibling), .started)
        coordinator.requestDeletion(configurationID: configuration.id)
        coordinator.cancelDeletion()
        XCTAssertTrue(fixture.factory.engines[0].signals.isEmpty)
        XCTAssertEqual(Set(coordinator.runConfigurations().map(\.id)), [configuration.id, sibling.id])
        coordinator.requestDeletion(configurationID: configuration.id)
        coordinator.confirmDeletion()
        XCTAssertEqual(Set(coordinator.runConfigurations().map(\.id)), [configuration.id, sibling.id])
        fixture.scheduler.runNext()
        fixture.scheduler.runNext()
        XCTAssertEqual(coordinator.runConfigurations(), [sibling])
        XCTAssertNil(coordinator.session(for: configuration.id))
        XCTAssertEqual(try fixture.store.load().runConfigurations, [sibling])
        XCTAssertEqual(coordinator.session(for: sibling.id)?.state, .running)
        XCTAssertTrue(fixture.factory.engines[1].signals.isEmpty)
    }

    func testDetachingProjectPreservesDefaultAndRelativeWorkingDirectories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let fixture = try ProjectRunTestFixture(directory: directory, configurations: [], projectRoots: [projectRoot])
        let coordinator = fixture.coordinator
        for (path, expected) in [("", projectRoot.path), ("..", directory.path)] {
            var configuration = try XCTUnwrap(coordinator.createRunConfiguration(projectID: projectRoot.path, name: "解除关联", command: "pwd", workingDirectory: path))
            configuration.projectID = nil
            XCTAssertTrue(coordinator.updateRunConfiguration(configuration, name: configuration.name, command: configuration.command, workingDirectory: path))
            let saved = try XCTUnwrap(coordinator.runConfigurations().first { $0.id == configuration.id })
            XCTAssertNil(saved.projectID)
            XCTAssertEqual(saved.workingDirectory, expected)
            XCTAssertEqual(coordinator.run(saved), .started)
            XCTAssertEqual(coordinator.session(for: saved.id)?.activeExecution?.workingDirectory, expected)
        }
    }

    func testLiveStaleAssociationCanBeEditedDetachedAndRelinkedWithoutChangingExecution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try ProjectRunTestFixture(directory: directory, configurations: [], projectRoots: [root])
        let model = fixture.projectsModel
        let coordinator = fixture.coordinator
        XCTAssertTrue(model.renameProject(root.path, title: "旧 API"))
        let run = try XCTUnwrap(coordinator.createRunConfiguration(
            projectID: root.path, name: "API", command: "sleep 30", workingDirectory: "",
            sourceIdentity: "package.json#scripts.dev"
        ))
        XCTAssertEqual(coordinator.run(run), .started)
        let session = try XCTUnwrap(coordinator.session(for: run.id))
        let execution = session.activeExecution
        XCTAssertNotNil(coordinator.removeProjects(projectIDs: [root.path]))
        var stale = try XCTUnwrap(fixture.store.load().runConfigurations.first)
        XCTAssertEqual(stale.missingProjectTitle, "旧 API（已失效）")
        XCTAssertEqual(stale.deletedProjectPath, root.path)
        XCTAssertTrue(coordinator.updateRunConfiguration(stale, name: "编辑后", command: "pwd", workingDirectory: ".."))
        stale = try XCTUnwrap(coordinator.runConfigurations().first)
        XCTAssertEqual(stale.deletedProjectTitle, "旧 API")
        var forged = stale
        forged.projectID = "不存在的新关联"
        XCTAssertFalse(coordinator.updateRunConfiguration(forged, name: forged.name, command: forged.command, workingDirectory: ""))
        stale.projectID = nil
        XCTAssertTrue(coordinator.updateRunConfiguration(stale, name: stale.name, command: stale.command, workingDirectory: stale.workingDirectory))
        var detached = try XCTUnwrap(coordinator.runConfigurations().first)
        XCTAssertNil(detached.deletedProjectTitle)
        XCTAssertNil(detached.deletedProjectPath)
        XCTAssertEqual(detached.workingDirectory, directory.path)
        model.addDirect([root])
        let replacement = try XCTUnwrap(model.records.first)
        XCTAssertNotEqual(replacement.id, run.projectID)
        detached.projectID = replacement.id
        XCTAssertTrue(coordinator.updateRunConfiguration(detached, name: detached.name, command: detached.command, workingDirectory: ""))
        XCTAssertEqual(session.activeExecution, execution)
        XCTAssertEqual(session.state, .running)
        XCTAssertTrue(fixture.factory.engines[0].signals.isEmpty)
        XCTAssertEqual(try fixture.store.load().runConfigurations.first?.sourceProjectID, run.sourceProjectID)
    }

    func testDetachingConfigurationKeepsItsOriginalSuggestionSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"packageManager":"npm@10","scripts":{"dev":"serve"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        let fixture = try ProjectRunTestFixture(directory: root, configurations: [], projectRoots: [root])
        fixture.projectsModel.refreshProjects()
        for _ in 0 ..< 100 where fixture.projectsModel.isRefreshingProjects {
            try await Task.sleep(for: .milliseconds(10))
        }
        let coordinator = fixture.coordinator
        let suggestion = try XCTUnwrap(coordinator.runSuggestions().first)
        var configuration = try XCTUnwrap(coordinator.adoptSuggestion(suggestion))
        configuration.projectID = nil
        XCTAssertTrue(coordinator.updateRunConfiguration(configuration, name: configuration.name, command: configuration.command, workingDirectory: root.path))
        let detached = try XCTUnwrap(coordinator.runConfigurations().first)
        XCTAssertTrue(coordinator.isSuggestionSourceAvailable(detached))
        XCTAssertTrue(coordinator.runSuggestions().isEmpty)
        XCTAssertEqual(try fixture.store.load().runConfigurations.first, detached)
    }

    func testIndependentConfigurationPersistsAndUsesFreshDefaultDirectoryOnEachExecution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ProjectRunTestFixture(directory: directory, configurations: [], projectRoots: [])
        let coordinator = fixture.coordinator
        let configuration = try XCTUnwrap(coordinator.createRunConfiguration(
            name: "独立运行", command: "  printf hello\n", workingDirectory: ""
        ))
        XCTAssertNil(configuration.projectID)
        XCTAssertEqual(try fixture.store.load().runConfigurations, [configuration])
        XCTAssertEqual(coordinator.run(configuration), .started)
        let session = try XCTUnwrap(coordinator.session(for: configuration.id))
        let first = try XCTUnwrap(session.activeExecution)
        XCTAssertNil(first.projectRoot)
        XCTAssertEqual(first.command, "  printf hello\n")
        XCTAssertEqual(first.workingDirectory, FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(coordinator.run(configuration), .rejected("该运行配置已有活动会话"))
        XCTAssertFalse(coordinator.setRunConfigurationEnabled(configuration, isEnabled: false))
        coordinator.restart(configuration)
        fixture.scheduler.runNext()
        fixture.scheduler.runNext()
        XCTAssertEqual(session.state, .running)
        XCTAssertNotEqual(session.activeExecution?.id, first.id)
        XCTAssertEqual(session.activeExecution?.workingDirectory, first.workingDirectory)
        coordinator.stop(configurationID: configuration.id)
        fixture.scheduler.runNext()
        fixture.scheduler.runNext()
        XCTAssertFalse(session.state.isLive)
        XCTAssertTrue(coordinator.setRunConfigurationEnabled(configuration, isEnabled: false))
        XCTAssertEqual(coordinator.run(configuration), .rejected("运行配置已禁用"))
        XCTAssertNotNil(session.terminalView)
    }

    func testOptionalAssociationValidatesWorkspaceAndPreservesSourceAndDirectoryIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let fixture = try ProjectRunTestFixture(directory: directory, configurations: [], projectRoots: [projectRoot])
        let model = fixture.projectsModel
        let coordinator = fixture.coordinator
        let configuration = try XCTUnwrap(coordinator.createRunConfiguration(
            name: "来源配置", command: "pwd", workingDirectory: "", sourceIdentity: "package.json#scripts.dev"
        ))
        var linked = configuration
        linked.projectID = projectRoot.path
        XCTAssertTrue(coordinator.updateRunConfiguration(linked, name: linked.name, command: linked.command, workingDirectory: ""))
        linked = try XCTUnwrap(coordinator.runConfigurations().first)
        XCTAssertEqual(linked.sourceIdentity, configuration.sourceIdentity)
        XCTAssertEqual(coordinator.run(linked), .started)
        XCTAssertEqual(coordinator.session(for: linked.id)?.activeExecution?.workingDirectory, projectRoot.path)
        fixture.factory.engines[0].finish(exitCode: 0)
        XCTAssertTrue(coordinator.updateRunConfiguration(linked, name: linked.name, command: linked.command, workingDirectory: ".."))
        let relative = try XCTUnwrap(coordinator.runConfigurations().first)
        XCTAssertEqual(coordinator.run(relative), .started)
        XCTAssertEqual(coordinator.session(for: linked.id)?.activeExecution?.workingDirectory, directory.path)
        fixture.factory.engines[0].finish(exitCode: 0)
        _ = try XCTUnwrap(model.createWorkspace(name: "其他工作区"))
        XCTAssertNil(coordinator.createRunConfiguration(projectID: projectRoot.path, name: "越界", command: "pwd", workingDirectory: ""))
        let independent = try XCTUnwrap(coordinator.createRunConfiguration(name: "独立", command: "pwd", workingDirectory: ""))
        var forged = independent
        forged.projectID = projectRoot.path
        XCTAssertFalse(coordinator.updateRunConfiguration(forged, name: forged.name, command: forged.command, workingDirectory: ""))
        guard case .rejected = coordinator.run(forged) else { return XCTFail("拒绝跨工作区项目关联") }
        XCTAssertEqual(try fixture.store.load().runConfigurations.first { $0.id == independent.id }, independent)
    }

    func testIndependentMissingDirectoryFailsWithoutFallbackAndFailedSavePreservesRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ProjectRunTestFixture(directory: directory, configurations: [], projectRoots: [])
        let coordinator = fixture.coordinator
        let missing = directory.appendingPathComponent("missing").path
        let configuration = try XCTUnwrap(coordinator.createRunConfiguration(name: "缺失", command: "pwd", workingDirectory: missing))
        guard case .rejected = coordinator.run(configuration) else { return XCTFail("缺失目录不能回退") }
        XCTAssertTrue(fixture.factory.engines.flatMap(\.launches).isEmpty)
        XCTAssertNil(coordinator.session(for: configuration.id)?.activeExecution)
        XCTAssertNil(coordinator.createRunConfiguration(name: "无项目相对目录", command: "pwd", workingDirectory: "."))
        let stored = try fixture.store.load()
        let recordsFile = directory.appendingPathComponent("records.json")
        try FileManager.default.removeItem(at: recordsFile)
        try FileManager.default.createDirectory(at: recordsFile, withIntermediateDirectories: false)
        XCTAssertNil(coordinator.createRunConfiguration(name: "不能保存", command: "pwd", workingDirectory: ""))
        XCTAssertEqual(coordinator.runConfigurations(), stored.runConfigurations)
        XCTAssertFalse(coordinator.updateRunConfiguration(configuration, name: "不能保存", command: "new", workingDirectory: ""))
        XCTAssertEqual(coordinator.runConfigurations(), stored.runConfigurations)
    }

    func testCoordinatorAcceptsAbsoluteWorkingDirectoryWithoutTrust() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = ProjectsViewModel(store: ProjectRecordStore(fileURL: root.appendingPathComponent("records.json")))
        model.addDirect([root])
        for _ in 0 ..< 100 where model.isRefreshingProjects { try await Task.sleep(for: .milliseconds(10)) }
        let project = try XCTUnwrap(model.records.first)
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: model, makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"), scheduler: FakeProjectRunScheduler()
        )
        let configuration = try XCTUnwrap(coordinator.createRunConfiguration(
            projectID: project.id, name: "Absolute", command: "pwd", workingDirectory: "/"
        ))
        XCTAssertEqual(coordinator.run(configuration, project: project), .started)
        XCTAssertEqual(factory.engines.first?.launches.first?.workingDirectory, "/")
    }

    func testWorkspaceSwitchAndRenameKeepExecutionsDraftsAndWindowSessionsAlive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = ProjectsViewModel(store: ProjectRecordStore(fileURL: root.appendingPathComponent("records.json")))
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: model, makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"), scheduler: FakeProjectRunScheduler()
        )
        model.addDirect([root])
        let firstProject = try XCTUnwrap(model.workspaceRecords.first)
        let first = try XCTUnwrap(coordinator.createRunConfiguration(projectID: firstProject.id, name: "服务", command: "sleep 30", workingDirectory: "."))
        XCTAssertEqual(coordinator.run(first, projectRoot: root.path), .started)
        let session = try XCTUnwrap(coordinator.session(for: first.id))
        let executionID = try XCTUnwrap(session.activeExecution?.id)
        let secondWorkspace = try XCTUnwrap(model.createWorkspace(name: "其他"))
        model.addDirect([root])
        let secondProject = try XCTUnwrap(model.workspaceRecords.first)
        let second = try XCTUnwrap(coordinator.createRunConfiguration(projectID: secondProject.id, name: "服务", command: "sleep 60", workingDirectory: "."))
        XCTAssertTrue(model.renameWorkspace(secondWorkspace.id, name: "后台服务"))
        XCTAssertEqual(coordinator.runConfigurations(workspaceID: secondWorkspace.id), [second])
        XCTAssertEqual(Set(coordinator.runConfigurations().map(\.id)), [first.id, second.id])
        XCTAssertEqual(coordinator.makeBatchStartIntent(in: coordinator.runConfigurations(workspaceID: secondWorkspace.id)).startRequests.map(\.configuration.id), [second.id])
        XCTAssertEqual(coordinator.run(second, projectRoot: root.path), .started)
        XCTAssertTrue(model.selectWorkspace(first.workspaceID))
        _ = ContentView(projectsModel: model, runCoordinator: coordinator)
        _ = ContentView(projectsModel: model, runCoordinator: coordinator)
        XCTAssertTrue(coordinator.session(for: first.id) === session)
        XCTAssertEqual(session.activeExecution?.id, executionID)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(coordinator.session(for: second.id)?.state, .running)
        XCTAssertTrue(factory.engines.allSatisfy { $0.signals.isEmpty })
        XCTAssertEqual(factory.engines.count, 2)
    }

    @MainActor
    func testWorkspaceBatchScopeKeepsIndependentRunsInTheirWorkspace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ProjectsViewModel(
            store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        )
        let first = try XCTUnwrap(model.createRunConfiguration(
            name: "API", command: "first", workingDirectory: directory.path
        ))
        let secondWorkspace = try XCTUnwrap(model.createWorkspace(name: "后台服务"))
        XCTAssertTrue(model.selectWorkspace(secondWorkspace.id))
        let second = try XCTUnwrap(model.createRunConfiguration(
            name: "API", command: "second", workingDirectory: directory.path
        ))
        let coordinator = ProjectRunCoordinator(
            projectsModel: model,
            makeEngine: { FakeProjectRunEngine() },
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        XCTAssertEqual(coordinator.runConfigurations(workspaceID: first.workspaceID).map(\.id), [first.id])
        XCTAssertEqual(coordinator.runConfigurations(workspaceID: second.workspaceID).map(\.id), [second.id])
        XCTAssertEqual(
            coordinator.makeBatchStartIntent(in: coordinator.runConfigurations(workspaceID: second.workspaceID))
                .startRequests.map(\.configuration.id),
            [second.id]
        )
    }

    func testSameDirectoryRecordRemovalKeepsSiblingExecutionAndConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = ProjectsViewModel(store: ProjectRecordStore(fileURL: root.appendingPathComponent("records.json")))
        model.addDirect([root])
        let first = try XCTUnwrap(model.records.first)
        model.addDirect([root])
        let second = try XCTUnwrap(model.records.first { $0.id != first.id })
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: model,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        let firstRun = try XCTUnwrap(coordinator.createRunConfiguration(
            projectID: first.id, name: "API", command: "sleep 30", workingDirectory: "."
        ))
        let secondRun = try XCTUnwrap(coordinator.createRunConfiguration(
            projectID: second.id, name: "Worker", command: "sleep 60", workingDirectory: "."
        ))
        XCTAssertEqual(coordinator.run(firstRun, projectRoot: first.path), .started)
        XCTAssertEqual(coordinator.run(secondRun, projectRoot: second.path), .started)
        let execution = try XCTUnwrap(coordinator.session(for: secondRun.id)?.activeExecution)
        XCTAssertEqual(execution.workingDirectory, second.path)
        XCTAssertTrue(model.renameProject(second.id, title: "Renamed worker"))
        XCTAssertEqual(coordinator.runConfigurations(projectID: second.id), [secondRun])
        XCTAssertNotNil(coordinator.removeProjects(projectIDs: [first.id]))
        XCTAssertEqual(coordinator.session(for: firstRun.id)?.state, .running)
        XCTAssertEqual(coordinator.session(for: secondRun.id)?.activeExecution?.id, execution.id)
        XCTAssertEqual(coordinator.session(for: secondRun.id)?.state, .running)
        XCTAssertEqual(Set(coordinator.runConfigurations().map(\.id)), [firstRun.id, secondRun.id])
        XCTAssertTrue(factory.engines[0].signals.isEmpty)
        XCTAssertTrue(factory.engines[1].signals.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testRunSessionSummaryClassifiesLifecycleAndExitStates() {
        XCTAssertEqual(ProjectRunSessionState.starting.summaryCategory, .running)
        XCTAssertEqual(ProjectRunSessionState.stopping.summaryCategory, .running)
        XCTAssertEqual(ProjectRunSessionState.restarting.summaryCategory, .running)
        XCTAssertEqual(ProjectRunSessionState.stopped(137).summaryCategory, .stopped)
        XCTAssertEqual(ProjectRunSessionState.exited(0).summaryCategory, .stopped)
        XCTAssertEqual(ProjectRunSessionState.exited(2).summaryCategory, .exceptional)
        XCTAssertEqual(ProjectRunSessionState.stopFailed("仍有进程").summaryCategory, .exceptional)
        XCTAssertEqual(ProjectRunSessionState.restartFailed("仍有进程").summaryCategory, .exceptional)
        XCTAssertEqual(ProjectRunSessionState.launchFailed("启动失败").summaryCategory, .exceptional)
        XCTAssertEqual(ProjectRunSessionState.inactive.summaryCategory, .ignored)
    }

    @MainActor
    func testStatusBarMenuKeepsControlsVisibleWithoutSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectsModel = ProjectsViewModel(
            store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        )
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: { FakeProjectRunEngine() },
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        let appDelegate = DevEnvAppDelegate(projectsModel: projectsModel, runCoordinator: coordinator)
        appDelegate.rebuildStatusMenu()

        XCTAssertEqual(
            appDelegate.statusMenu.items.map(\.title),
            ["打开面板", "", "全部工作区启动", "全部工作区停止", "", "0 运行 · 0 停止 · 0 异常", "没有活动会话", "", "退出"]
        )
        XCTAssertFalse(appDelegate.statusMenu.item(withTitle: "全部工作区启动")?.isEnabled ?? true)
        XCTAssertFalse(appDelegate.statusMenu.item(withTitle: "全部工作区停止")?.isEnabled ?? true)
    }

    func testStatusBarGlobalStartSubmitsAllProjectsToSharedFrozenIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstRoot = directory.appendingPathComponent("first")
        let secondRoot = directory.appendingPathComponent("second")
        let secondWorkingDirectory = secondRoot.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondWorkingDirectory, withIntermediateDirectories: true)
        let first = ProjectRunConfiguration(
            id: "first",
            projectID: firstRoot.path,
            name: "First",
            command: "swift run",
            workingDirectory: "."
        )
        let second = ProjectRunConfiguration(
            id: "second",
            projectID: secondRoot.path,
            name: "Second",
            command: "pnpm run dev",
            workingDirectory: "app"
        )
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument(runConfigurations: [first, second])
        document.records = [firstRoot.path, secondRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        projectsModel.refreshProjects()
        for _ in 0 ..< 100 where projectsModel.isRefreshingProjects { try await Task.sleep(for: .milliseconds(10)) }
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        var handoffCount = 0
        let appDelegate = DevEnvAppDelegate(
            projectsModel: projectsModel,
            runCoordinator: coordinator,
            statusBarRunPageHandoff: {
                handoffCount += 1
                XCTAssertTrue(coordinator.updateRunConfiguration(
                    first,
                    name: first.name,
                    command: "changed during handoff",
                    workingDirectory: first.workingDirectory
                ))
            }
        )
        appDelegate.rebuildStatusMenu()
        let startItem = try XCTUnwrap(appDelegate.statusMenu.item(withTitle: "全部工作区启动"))

        XCTAssertTrue(startItem.isEnabled)
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(startItem.action),
            to: startItem.target,
            from: startItem
        ))

        XCTAssertEqual(handoffCount, 1)
        XCTAssertEqual(factory.engines.flatMap(\.launches).map(\.workingDirectory), [firstRoot.path, secondWorkingDirectory.path])
    }

    @MainActor
    func testStatusBarNamesAndStartsIndependentRunsAcrossAllWorkspaces() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectsModel = ProjectsViewModel(
            store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        )
        let first = try XCTUnwrap(projectsModel.createRunConfiguration(
            name: "API", command: "first", workingDirectory: directory.path
        ))
        let secondWorkspace = try XCTUnwrap(projectsModel.createWorkspace(name: "后台服务"))
        XCTAssertTrue(projectsModel.selectWorkspace(secondWorkspace.id))
        let second = try XCTUnwrap(projectsModel.createRunConfiguration(
            name: "API", command: "second", workingDirectory: directory.path
        ))
        XCTAssertEqual(first.workspaceID, Workspace.defaultWorkspace.id)
        XCTAssertEqual(second.workspaceID, secondWorkspace.id)
        XCTAssertNil(first.projectID)
        XCTAssertNil(second.projectID)
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        let appDelegate = DevEnvAppDelegate(projectsModel: projectsModel, runCoordinator: coordinator)

        appDelegate.rebuildStatusMenu()
        let startItem = try XCTUnwrap(appDelegate.statusMenu.item(withTitle: "全部工作区启动"))
        XCTAssertTrue(startItem.isEnabled)
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(startItem.action),
            to: startItem.target,
            from: startItem
        ))
        appDelegate.rebuildStatusMenu()

        XCTAssertEqual(factory.engines.flatMap(\.launches).map(\.arguments), [["-i", "-c", "first"], ["-i", "-c", "second"]])
        XCTAssertTrue(appDelegate.statusMenu.items.contains { $0.title == "后台服务 · API" })
        XCTAssertTrue(appDelegate.statusMenu.items.contains { $0.title == "默认工作区 · API" })
    }

    func testStatusBarTrustedGlobalStartIsImmediateAndRetainsSharedSessions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let configuration = ProjectRunConfiguration(
            id: "trusted",
            projectID: projectRoot.path,
            name: "Trusted",
            command: "swift run",
            workingDirectory: "."
        )
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument(runConfigurations: [configuration])
        document.records = [projectRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        projectsModel.refreshProjects()
        for _ in 0 ..< 100 where projectsModel.records.contains(where: { $0.availability == .unknown }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        var handoffCount = 0
        let appDelegate = DevEnvAppDelegate(
            projectsModel: projectsModel,
            runCoordinator: coordinator,
            statusBarRunPageHandoff: { handoffCount += 1 }
        )
        appDelegate.rebuildStatusMenu()
        let startItem = try XCTUnwrap(appDelegate.statusMenu.item(withTitle: "全部工作区启动"))

        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(startItem.action),
            to: startItem.target,
            from: startItem
        ))

        let session = try XCTUnwrap(coordinator.session(for: configuration.id))
        let executionID = try XCTUnwrap(session.activeExecution?.id)
        XCTAssertEqual(handoffCount, 1)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(coordinator.sessionSummary, ProjectRunSessionSummary(running: 1, stopped: 0, exceptional: 0))
        _ = ContentView(projectsModel: projectsModel, runCoordinator: coordinator)
        _ = ContentView(projectsModel: projectsModel, runCoordinator: coordinator)
        XCTAssertTrue(coordinator.session(for: configuration.id) === session)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.activeExecution?.id, executionID)
    }

    func testStatusBarGlobalStopFreezesEveryCurrentExecution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstRoot = directory.appendingPathComponent("first")
        let secondRoot = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let first = ProjectRunConfiguration(
            id: "first",
            projectID: firstRoot.path,
            name: "First",
            command: "sleep 30",
            workingDirectory: "."
        )
        let second = ProjectRunConfiguration(
            id: "second",
            projectID: secondRoot.path,
            name: "Second",
            command: "sleep 30",
            workingDirectory: "."
        )
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument(runConfigurations: [first, second])
        document.records = [firstRoot.path, secondRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        XCTAssertEqual(coordinator.run(first, projectRoot: firstRoot.path), .started)
        XCTAssertEqual(coordinator.run(second, projectRoot: secondRoot.path), .started)
        let executionIDs = try [first, second].map {
            try XCTUnwrap(coordinator.session(for: $0.id)?.activeExecution?.id)
        }
        var handoffCount = 0
        let appDelegate = DevEnvAppDelegate(
            projectsModel: projectsModel,
            runCoordinator: coordinator,
            statusBarRunPageHandoff: {
                handoffCount += 1
                factory.engines[0].finish(exitCode: 0)
                XCTAssertEqual(coordinator.run(first, projectRoot: firstRoot.path), .started)
            }
        )
        appDelegate.rebuildStatusMenu()
        let stopItem = try XCTUnwrap(appDelegate.statusMenu.item(withTitle: "全部工作区停止"))

        XCTAssertFalse(appDelegate.statusMenu.item(withTitle: "全部工作区启动")?.isEnabled ?? true)
        XCTAssertTrue(stopItem.isEnabled)
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(stopItem.action),
            to: stopItem.target,
            from: stopItem
        ))

        let replacementExecutionID = try XCTUnwrap(coordinator.session(for: first.id)?.activeExecution?.id)
        XCTAssertEqual(handoffCount, 1)
        XCTAssertNotEqual(replacementExecutionID, executionIDs[0])
        XCTAssertEqual(coordinator.pendingBatchStopIntent?.executionIDs, executionIDs)
        XCTAssertEqual(factory.engines.map(\.signals), [[SIGKILL], []])
        coordinator.confirmBatchStop()
        XCTAssertEqual(factory.engines.map(\.signals), [[SIGKILL], [SIGINT]])
        XCTAssertEqual(coordinator.session(for: first.id)?.activeExecution?.id, replacementExecutionID)
        XCTAssertEqual(coordinator.session(for: first.id)?.state, .running)
        appDelegate.rebuildStatusMenu()
        XCTAssertTrue(appDelegate.statusMenu.item(withTitle: "全部工作区停止")?.isEnabled ?? false)
    }

    func testStatusBarMenuRebuildsWhenProjectConfigurationsChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument()
        document.records = [projectRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: { FakeProjectRunEngine() },
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        let appDelegate = DevEnvAppDelegate(projectsModel: projectsModel, runCoordinator: coordinator)
        appDelegate.rebuildStatusMenu()
        XCTAssertFalse(appDelegate.statusMenu.item(withTitle: "全部工作区启动")?.isEnabled ?? true)

        XCTAssertNotNil(coordinator.createRunConfiguration(
            projectID: projectRoot.path,
            name: "Dev",
            command: "swift run",
            workingDirectory: "."
        ))
        for _ in 0 ..< 3 { await Task.yield() }

        XCTAssertTrue(appDelegate.statusMenu.item(withTitle: "全部工作区启动")?.isEnabled ?? false)
    }

    func testReopenedMainWindowUsesFullSizeHiddenTitleBar() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        DevEnvAppDelegate.configureMainWindow(window)

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
    }

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

    func testOverviewAdaptsTableRowsWithoutMaximum() {
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 322, itemCount: 4), 2)
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 345, itemCount: 4), 2)
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 346, itemCount: 4), 3)
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 377, itemCount: 4), 3)
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 378, itemCount: 4), 4)
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 434, itemCount: 5), 4)
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 446, itemCount: 5), 5)
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 550, itemCount: 7), 6)
        XCTAssertEqual(overviewVisibleRunLimit(cardHeight: 582, itemCount: 7), 7)
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
        let factory = FakeProjectRunEngineFactory()
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
        let projectsModel = try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [first, sameProject, second, inactive])
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        for configuration in [first, second] {
            XCTAssertEqual(coordinator.run(
                configuration,
                projectRoot: configuration.projectID
            ), .started)
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

    func testUnavailableProjectRecordsRejectedStartWithoutLaunchingProcess() throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let factory = FakeProjectRunEngineFactory()
        var project = ProjectRecord(path: "/Volumes/Missing/project", discoveredAt: Date())
        project.availability = .unavailable("项目根目录不存在")
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: project.id,
            name: "开发服务器",
            command: "npm run dev",
            workingDirectory: "."
        )
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: storageDirectory.appendingPathComponent("records.json")), configurations: [configuration]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        XCTAssertEqual(
            coordinator.run(configuration, project: project),
            .rejected("项目不可用，不能执行：项目根目录不存在")
        )
        let session = try XCTUnwrap(coordinator.session(for: configuration.id))
        XCTAssertEqual(session.state, .launchFailed("项目不可用，不能执行：项目根目录不存在"))
        XCTAssertEqual(session.currentExecution?.id, session.failureExecution?.id)
        XCTAssertNil(session.failureExecution?.workingDirectory)
        XCTAssertEqual(factory.engines.count, 1)
        XCTAssertTrue(factory.engines[0].launches.isEmpty)
    }

    func testUnknownProjectRecordsRejectedStartForTheRunPage() throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let factory = FakeProjectRunEngineFactory()
        let project = ProjectRecord(path: storageDirectory.appendingPathComponent("project").path, discoveredAt: Date())
        let configuration = ProjectRunConfiguration(
            id: "unknown-run",
            projectID: project.id,
            name: "Unknown Run",
            command: "npm run dev",
            workingDirectory: "."
        )
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: storageDirectory.appendingPathComponent("records.json")), configurations: [configuration]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        XCTAssertEqual(
            coordinator.run(configuration, project: project),
            .rejected("正在确认项目是否可用")
        )
        let session = try XCTUnwrap(coordinator.session(for: configuration.id))
        XCTAssertEqual(session.state, .launchFailed("正在确认项目是否可用"))
        XCTAssertEqual(session.currentExecution?.id, session.failureExecution?.id)
        XCTAssertNil(session.failureExecution?.workingDirectory)
        XCTAssertEqual(factory.engines.count, 1)
        XCTAssertTrue(factory.engines[0].launches.isEmpty)
    }

    func testDisabledConfigurationCannotStartDirectlyOrFromFrozenIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument()
        document.records = [projectRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        let configuration = try XCTUnwrap(projectsModel.createRunConfiguration(
            projectID: projectRoot.path,
            name: "开发服务器",
            command: "npm run dev",
            workingDirectory: "."
        ))
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        let intent = coordinator.makeBatchStartIntent(in: [configuration])
        XCTAssertTrue(projectsModel.setRunConfigurationEnabled(configuration, isEnabled: false))
        let disabled = try XCTUnwrap(projectsModel.runConfigurations().first)

        XCTAssertFalse(coordinator.canStartBatch(in: coordinator.runConfigurations()))
        XCTAssertEqual(coordinator.run(disabled, projectRoot: projectRoot.path), .rejected("运行配置已禁用"))
        coordinator.submitBatchStart(intent)
        XCTAssertTrue(factory.engines.flatMap(\.launches).isEmpty)
    }

    func testBatchStartImmediatelyLaunchesEveryEligibleConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trustedRoot = directory.appendingPathComponent("trusted")
        let untrustedRoot = directory.appendingPathComponent("untrusted")
        let untrustedWorkingDirectory = untrustedRoot.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: trustedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: untrustedWorkingDirectory, withIntermediateDirectories: true)
        let trusted = ProjectRunConfiguration(
            id: "trusted",
            projectID: trustedRoot.path,
            name: "Trusted API",
            command: "swift run api --port 8080",
            workingDirectory: "."
        )
        let untrusted = ProjectRunConfiguration(
            id: "untrusted",
            projectID: untrustedRoot.path,
            name: "Untrusted Web",
            command: "pnpm run dev -- --host 127.0.0.1",
            workingDirectory: "app"
        )
        let fixture = try ProjectRunTestFixture(
            directory: directory,
            configurations: [trusted, untrusted],
            projectRoots: [trustedRoot, untrustedRoot]
        )

        fixture.projectsModel.refreshProjects()
        for _ in 0 ..< 100 where fixture.projectsModel.records.contains(where: { $0.availability == .unknown }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        fixture.coordinator.startBatch(in: [trusted, untrusted])

        XCTAssertEqual(fixture.coordinator.session(for: trusted.id)?.state, .running)
        XCTAssertEqual(fixture.coordinator.session(for: untrusted.id)?.state, .running)
        XCTAssertEqual(fixture.factory.engines.flatMap(\.launches).map(\.workingDirectory), [trustedRoot.path, untrustedWorkingDirectory.path])
    }

    func testBatchStartIntentUsesOnlySuppliedEligibleScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let includedRoot = directory.appendingPathComponent("included")
        let outsideRoot = directory.appendingPathComponent("outside")
        let activeRoot = directory.appendingPathComponent("active")
        let missingRoot = directory.appendingPathComponent("missing")
        for root in [includedRoot, outsideRoot, activeRoot] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let included = ProjectRunConfiguration(
            id: "included",
            projectID: includedRoot.path,
            name: "Included",
            command: "run included",
            workingDirectory: "."
        )
        let outside = ProjectRunConfiguration(
            id: "outside",
            projectID: outsideRoot.path,
            name: "Outside",
            command: "run outside",
            workingDirectory: "."
        )
        let disabled = ProjectRunConfiguration(
            id: "disabled",
            projectID: includedRoot.path,
            name: "Disabled",
            command: "run disabled",
            workingDirectory: ".",
            isEnabled: false
        )
        let active = ProjectRunConfiguration(
            id: "active",
            projectID: activeRoot.path,
            name: "Active",
            command: "run active",
            workingDirectory: "."
        )
        let unavailable = ProjectRunConfiguration(
            id: "unavailable",
            projectID: missingRoot.path,
            name: "Unavailable",
            command: "run unavailable",
            workingDirectory: "."
        )
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument(runConfigurations: [
            included, outside, disabled, active, unavailable,
        ])
        document.records = [includedRoot.path, outsideRoot.path, activeRoot.path, missingRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        projectsModel.refreshProjects()
        for _ in 0 ..< 100 where projectsModel.records.contains(where: { $0.availability == .unknown }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            projectsModel.records.first { $0.id == missingRoot.path }?.availability,
            .unavailable("项目根目录不存在")
        )
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        XCTAssertEqual(coordinator.run(active, projectRoot: activeRoot.path), .started)

        let scope = [included, disabled, active, unavailable]
        XCTAssertEqual(coordinator.batchStartCandidates(in: scope).map(\.id), [included.id])
        XCTAssertTrue(coordinator.canStartBatch(in: scope))
        XCTAssertFalse(coordinator.canStartBatch(in: [disabled, active, unavailable]))

        let intent = coordinator.makeBatchStartIntent(in: scope)
        XCTAssertEqual(intent.startRequests, [
            ProjectRunFrozenStartRequest(
                configuration: included,
                projectRoot: includedRoot.path,
                command: included.command,
                workingDirectory: includedRoot.path
            ),
        ])
        coordinator.submitBatchStart(intent)
        XCTAssertEqual(coordinator.session(for: included.id)?.state, .running)
        XCTAssertNil(coordinator.session(for: outside.id))
    }

    func testBatchStopRequestFreezesOnlyTargetableExecutionIDsInSuppliedScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let includedRoot = directory.appendingPathComponent("included")
        let outsideRoot = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: includedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let included = ProjectRunConfiguration(
            id: "included",
            projectID: includedRoot.path,
            name: "Included",
            command: "run included",
            workingDirectory: "."
        )
        let outside = ProjectRunConfiguration(
            id: "outside",
            projectID: outsideRoot.path,
            name: "Outside",
            command: "run outside",
            workingDirectory: "."
        )
        let inactive = ProjectRunConfiguration(
            id: "inactive",
            projectID: includedRoot.path,
            name: "Inactive",
            command: "run inactive",
            workingDirectory: "."
        )
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument(runConfigurations: [included, outside, inactive])
        document.records = [includedRoot.path, outsideRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        XCTAssertEqual(coordinator.run(included, projectRoot: includedRoot.path), .started)
        XCTAssertEqual(coordinator.run(outside, projectRoot: outsideRoot.path), .started)
        let includedExecutionID = try XCTUnwrap(coordinator.session(for: included.id)?.activeExecution?.id)
        let outsideExecutionID = try XCTUnwrap(coordinator.session(for: outside.id)?.activeExecution?.id)

        XCTAssertTrue(coordinator.canStopBatch(in: [inactive, included, included]))
        coordinator.requestBatchStop(in: [inactive, included, included])

        XCTAssertEqual(coordinator.pendingBatchStopIntent?.executionIDs, [includedExecutionID])
        XCTAssertFalse(coordinator.pendingBatchStopIntent?.executionIDs.contains(outsideExecutionID) ?? true)
        coordinator.confirmBatchStop()
        XCTAssertEqual(factory.engines[0].signals, [SIGINT])
        XCTAssertTrue(factory.engines[1].signals.isEmpty)
        XCTAssertEqual(coordinator.session(for: outside.id)?.state, .running)
    }

    func testBatchStopIntentIncludesAnExecutionAlreadyStoppingWithoutResendingSignals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ProjectRunConfiguration(
            id: "stopping",
            projectID: directory.path,
            name: "Stopping",
            command: "sleep 30",
            workingDirectory: "."
        )
        let fixture = try ProjectRunTestFixture(
            directory: directory,
            configurations: [configuration],
            projectRoots: [directory]
        )
        XCTAssertEqual(fixture.coordinator.run(configuration, projectRoot: directory.path), .started)
        let executionID = try XCTUnwrap(fixture.coordinator.session(for: configuration.id)?.activeExecution?.id)
        fixture.coordinator.stop(executionID: executionID)
        XCTAssertEqual(fixture.coordinator.session(for: configuration.id)?.state, .stopping)
        XCTAssertEqual(fixture.factory.engines[0].signals, [SIGINT])

        XCTAssertTrue(fixture.coordinator.canStopBatch(in: [configuration]))
        fixture.coordinator.requestBatchStop(in: [configuration])
        XCTAssertEqual(fixture.coordinator.pendingBatchStopIntent?.executionIDs, [executionID])

        fixture.coordinator.confirmBatchStop()

        XCTAssertEqual(fixture.factory.engines[0].signals, [SIGINT])
        XCTAssertEqual(fixture.coordinator.session(for: configuration.id)?.state, .stopping)
    }

    func testCancellingBatchStopDiscardsIntentWithoutSendingSignals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ProjectRunConfiguration(
            id: "cancelled-stop",
            projectID: directory.path,
            name: "Cancelled Stop",
            command: "sleep 30",
            workingDirectory: "."
        )
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [configuration]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        XCTAssertEqual(coordinator.run(configuration, projectRoot: directory.path), .started)
        coordinator.requestBatchStop(in: [configuration])
        XCTAssertNotNil(coordinator.pendingBatchStopIntent)

        coordinator.cancelBatchStop()

        XCTAssertNil(coordinator.pendingBatchStopIntent)
        XCTAssertTrue(factory.engines[0].signals.isEmpty)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .running)
    }

    func testConfirmingBatchStopSkipsEndedAndReplacementExecutions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ended = ProjectRunConfiguration(
            id: "ended",
            projectID: directory.path,
            name: "Ended",
            command: "run ended",
            workingDirectory: "."
        )
        let replaced = ProjectRunConfiguration(
            id: "replaced",
            projectID: directory.path,
            name: "Replaced",
            command: "run replaced",
            workingDirectory: "."
        )
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [ended, replaced]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        XCTAssertEqual(coordinator.run(ended, projectRoot: directory.path), .started)
        XCTAssertEqual(coordinator.run(replaced, projectRoot: directory.path), .started)
        let endedExecutionID = try XCTUnwrap(coordinator.session(for: ended.id)?.activeExecution?.id)
        let replacedExecutionID = try XCTUnwrap(coordinator.session(for: replaced.id)?.activeExecution?.id)
        coordinator.requestBatchStop(in: [ended, replaced])
        XCTAssertEqual(
            coordinator.pendingBatchStopIntent?.executionIDs,
            [endedExecutionID, replacedExecutionID]
        )

        factory.engines[0].finish(exitCode: 0)
        factory.engines[1].finish(exitCode: 0)
        XCTAssertEqual(coordinator.run(replaced, projectRoot: directory.path), .started)
        let replacementExecutionID = try XCTUnwrap(coordinator.session(for: replaced.id)?.activeExecution?.id)
        XCTAssertNotEqual(replacementExecutionID, replacedExecutionID)
        let signalCountsBeforeConfirmation = factory.engines.map { $0.signals.count }

        coordinator.confirmBatchStop()

        XCTAssertNil(coordinator.pendingBatchStopIntent)
        XCTAssertEqual(factory.engines.map { $0.signals.count }, signalCountsBeforeConfirmation)
        XCTAssertEqual(coordinator.session(for: ended.id)?.state, .exited(0))
        XCTAssertNil(coordinator.session(for: ended.id)?.failureMessage)
        XCTAssertEqual(coordinator.session(for: replaced.id)?.state, .running)
        XCTAssertEqual(coordinator.session(for: replaced.id)?.activeExecution?.id, replacementExecutionID)
    }

    func testConfirmingBatchStopCancelsPendingRestartWithoutLaunchingReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ProjectRunConfiguration(
            id: "restarting",
            projectID: directory.path,
            name: "Restarting",
            command: "sleep 30",
            workingDirectory: "."
        )
        let factory = FakeProjectRunEngineFactory()
        let scheduler = FakeProjectRunScheduler()
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [configuration]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: scheduler
        )

        XCTAssertEqual(coordinator.run(configuration, projectRoot: directory.path), .started)
        coordinator.restart(configuration, projectRoot: directory.path)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .restarting)
        XCTAssertTrue(coordinator.canStopBatch(in: [configuration]))
        XCTAssertEqual(factory.engines[0].signals, [SIGINT])

        coordinator.requestBatchStop(in: [configuration])
        coordinator.confirmBatchStop()

        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .stopping)
        XCTAssertEqual(factory.engines[0].signals, [SIGINT])
        XCTAssertTrue(coordinator.canStopBatch(in: [configuration]))
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .stopped(137))
        XCTAssertNil(coordinator.session(for: configuration.id)?.activeExecution)
        XCTAssertEqual(factory.engines[0].launches.count, 1)
    }

    func testBatchStopContinuesAfterIndependentStopFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = ProjectRunConfiguration(
            id: "first-stop",
            projectID: directory.path,
            name: "First",
            command: "run first",
            workingDirectory: "."
        )
        let second = ProjectRunConfiguration(
            id: "second-stop",
            projectID: directory.path,
            name: "Second",
            command: "run second",
            workingDirectory: "."
        )
        let factory = FakeProjectRunEngineFactory()
        let scheduler = FakeProjectRunScheduler()
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [first, second]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: scheduler
        )

        XCTAssertEqual(coordinator.run(first, projectRoot: directory.path), .started)
        XCTAssertEqual(coordinator.run(second, projectRoot: directory.path), .started)
        factory.engines[0].signalSucceeds = false

        coordinator.requestBatchStop(in: [first, second])
        coordinator.confirmBatchStop()

        XCTAssertEqual(factory.engines[0].signals, [SIGINT])
        XCTAssertEqual(factory.engines[1].signals, [SIGINT])
        scheduler.runNext()
        scheduler.runNext()
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(
            coordinator.session(for: first.id)?.state,
            .stopFailed("仍有进程未退出")
        )
        XCTAssertEqual(
            coordinator.session(for: first.id)?.failureMessage,
            "停止失败：仍有进程未退出"
        )
        XCTAssertTrue(coordinator.canStopBatch(in: [first]))
        XCTAssertEqual(coordinator.session(for: second.id)?.state, .stopped(137))
        XCTAssertNil(coordinator.session(for: second.id)?.failureMessage)
        XCTAssertEqual(factory.engines[0].signals, [SIGINT, SIGTERM, SIGKILL])
        XCTAssertEqual(factory.engines[1].signals, [SIGINT, SIGTERM, SIGKILL, 0])
    }

    func testBatchStartCandidateSelectionTracksActiveExecutionLifecycleStates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        func configuration(_ id: String) -> ProjectRunConfiguration {
            ProjectRunConfiguration(
                id: id,
                projectID: projectRoot.path,
                name: id,
                command: "run \(id)",
                workingDirectory: "."
            )
        }
        let inactive = configuration("inactive")
        let stopped = configuration("stopped")
        let exited = configuration("exited")
        let launchFailed = configuration("launch-failed")
        let running = configuration("running")
        let stopFailed = configuration("stop-failed")
        let restartFailed = configuration("restart-failed")
        let restarting = configuration("restarting")
        let configurations = [
            inactive, stopped, exited, launchFailed, running, stopFailed, restartFailed, restarting,
        ]
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument(runConfigurations: configurations)
        document.records = [projectRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        let factory = FakeProjectRunEngineFactory()
        factory.startErrors = [nil, nil, FakeProjectRunError.launchFailed, nil, nil, nil, nil]
        let scheduler = FakeProjectRunScheduler()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: scheduler
        )

        XCTAssertEqual(coordinator.run(stopped, projectRoot: projectRoot.path), .started)
        coordinator.stop(configurationID: stopped.id)
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(coordinator.session(for: stopped.id)?.state, .stopped(137))

        XCTAssertEqual(coordinator.run(exited, projectRoot: projectRoot.path), .started)
        factory.engines[1].finish(exitCode: 0)
        XCTAssertEqual(coordinator.session(for: exited.id)?.state, .exited(0))

        XCTAssertEqual(
            coordinator.run(launchFailed, projectRoot: projectRoot.path),
            .rejected(FakeProjectRunError.launchFailed.localizedDescription)
        )
        XCTAssertEqual(
            coordinator.session(for: launchFailed.id)?.state,
            .launchFailed(FakeProjectRunError.launchFailed.localizedDescription)
        )

        XCTAssertEqual(coordinator.run(running, projectRoot: projectRoot.path), .started)

        XCTAssertEqual(coordinator.run(stopFailed, projectRoot: projectRoot.path), .started)
        factory.engines[4].signalSucceeds = false
        coordinator.stop(configurationID: stopFailed.id)
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(
            coordinator.session(for: stopFailed.id)?.state,
            .stopFailed("仍有进程未退出")
        )

        XCTAssertEqual(coordinator.run(restartFailed, projectRoot: projectRoot.path), .started)
        factory.engines[5].signalSucceeds = false
        coordinator.restart(restartFailed, projectRoot: projectRoot.path)
        for _ in 0..<10 where coordinator.session(for: restartFailed.id)?.state == .restarting {
            scheduler.runNext()
        }
        XCTAssertEqual(
            coordinator.session(for: restartFailed.id)?.state,
            .restartFailed("上一次运行仍有进程未退出")
        )

        XCTAssertEqual(coordinator.run(restarting, projectRoot: projectRoot.path), .started)
        coordinator.restart(restarting, projectRoot: projectRoot.path)
        XCTAssertEqual(coordinator.session(for: restarting.id)?.state, .restarting)

        XCTAssertEqual(
            coordinator.batchStartCandidates(in: configurations).map(\.id),
            [inactive.id, stopped.id, exited.id, launchFailed.id]
        )
        XCTAssertFalse(coordinator.canStartBatch(in: [running, stopFailed, restartFailed, restarting]))
    }

    func testBatchStartKeepsUnknownAvailabilityAsCandidateAndRecordsItsRejection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let configuration = ProjectRunConfiguration(
            id: "unknown",
            projectID: projectRoot.path,
            name: "Unknown",
            command: "run unknown",
            workingDirectory: "."
        )
        let fixture = try ProjectRunTestFixture(
            directory: directory,
            configurations: [configuration],
            projectRoots: [projectRoot]
        )
        XCTAssertEqual(fixture.projectsModel.records.first?.availability, .unknown)

        XCTAssertEqual(fixture.coordinator.batchStartCandidates(in: [configuration]).map(\.id), [configuration.id])
        let intent = fixture.coordinator.makeBatchStartIntent(in: [configuration])
        XCTAssertEqual(intent.startRequests.map(\.configuration.id), [configuration.id])

        fixture.coordinator.submitBatchStart(intent)

        let session = try XCTUnwrap(fixture.coordinator.session(for: configuration.id))
        XCTAssertEqual(session.state, .launchFailed("正在确认项目是否可用"))
        XCTAssertEqual(session.currentExecution?.id, session.failureExecution?.id)
        XCTAssertEqual(session.failureExecution?.command, configuration.command)
        XCTAssertEqual(fixture.factory.engines.count, 1)
        XCTAssertTrue(fixture.factory.engines[0].launches.isEmpty)
    }

    func testBatchStartRecordsPreflightFailureAndStartsValidSiblingsIndependently() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let valid = ProjectRunConfiguration(
            id: "valid",
            projectID: projectRoot.path,
            name: "Valid",
            command: "run valid",
            workingDirectory: "."
        )
        let invalid = ProjectRunConfiguration(
            id: "invalid",
            projectID: projectRoot.path,
            name: "Invalid",
            command: "run invalid",
            workingDirectory: "missing"
        )
        let fixture = try ProjectRunTestFixture(
            directory: directory,
            configurations: [valid, invalid],
            projectRoots: [projectRoot]
        )
        fixture.projectsModel.refreshProjects()
        for _ in 0 ..< 100 where fixture.projectsModel.records.contains(where: { $0.availability == .unknown }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        let intent = fixture.coordinator.makeBatchStartIntent(in: [invalid, valid])
        XCTAssertEqual(intent.startRequests.map(\.configuration.id), [valid.id])
        let failedSession = try XCTUnwrap(fixture.coordinator.session(for: invalid.id))
        XCTAssertEqual(
            failedSession.state,
            .launchFailed(ProjectRunConfigurationError.workingDirectoryMissing.localizedDescription)
        )
        XCTAssertEqual(failedSession.currentExecution?.id, failedSession.failureExecution?.id)
        XCTAssertNil(failedSession.failureExecution?.workingDirectory)
        let firstFailureExecutionID = try XCTUnwrap(failedSession.failureExecution?.id)
        _ = fixture.coordinator.makeBatchStartIntent(in: [invalid])
        XCTAssertNotEqual(failedSession.failureExecution?.id, firstFailureExecutionID)

        fixture.coordinator.submitBatchStart(intent)

        XCTAssertEqual(fixture.coordinator.session(for: valid.id)?.state, .running)
        XCTAssertEqual(fixture.factory.engines.last?.launches.first?.arguments, ["-i", "-c", valid.command])
        let validExecutionID = fixture.coordinator.session(for: valid.id)?.currentExecution?.id
        fixture.coordinator.submitBatchStart(intent)
        XCTAssertEqual(fixture.coordinator.session(for: valid.id)?.currentExecution?.id, validExecutionID)
        XCTAssertEqual(fixture.factory.engines.last?.launches.count, 1)
    }

    func testBatchStartFreezesDraftAndDirectoryWhileRejectingDisabledStateDrift() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        let firstDirectory = projectRoot.appendingPathComponent("first")
        let secondDirectory = projectRoot.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let drafted = ProjectRunConfiguration(
            id: "drafted",
            projectID: projectRoot.path,
            name: "Drafted",
            command: "run saved",
            workingDirectory: "first"
        )
        let disabledAfterReview = ProjectRunConfiguration(
            id: "disabled-after-review",
            projectID: projectRoot.path,
            name: "Disabled after review",
            command: "run disabled",
            workingDirectory: "."
        )
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument(runConfigurations: [drafted, disabledAfterReview])
        document.records = [projectRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        projectsModel.refreshProjects()
        for _ in 0 ..< 100 where projectsModel.records.contains(where: { $0.availability == .unknown }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        let draftCommand = "  run frozen\n"
        XCTAssertTrue(coordinator.updateRunConfiguration(
            drafted,
            name: drafted.name,
            command: draftCommand,
            workingDirectory: drafted.workingDirectory
        ))

        let intent = coordinator.makeBatchStartIntent(in: coordinator.runConfigurations())
        let draftedRequest = try XCTUnwrap(intent.startRequests.first {
            $0.configuration.id == drafted.id
        })
        XCTAssertEqual(draftedRequest.command, draftCommand)
        XCTAssertEqual(draftedRequest.workingDirectory, firstDirectory.path)

        let effectiveDrafted = try XCTUnwrap(coordinator.runConfigurations().first { $0.id == drafted.id })
        let newerDraft = "run newer"
        XCTAssertTrue(coordinator.updateRunConfiguration(
            effectiveDrafted,
            name: effectiveDrafted.name,
            command: newerDraft,
            workingDirectory: "second"
        ))
        XCTAssertTrue(coordinator.setRunConfigurationEnabled(disabledAfterReview, isEnabled: false))

        coordinator.submitBatchStart(intent)

        let launch = try XCTUnwrap(factory.engines.flatMap(\.launches).first)
        XCTAssertEqual(launch.arguments, ["-i", "-c", draftCommand])
        XCTAssertEqual(launch.workingDirectory, firstDirectory.path)
        XCTAssertEqual(coordinator.session(for: drafted.id)?.currentExecution?.command, draftCommand)
        let disabledSession = try XCTUnwrap(coordinator.session(for: disabledAfterReview.id))
        XCTAssertEqual(disabledSession.state, .launchFailed("运行配置已禁用"))
        XCTAssertEqual(disabledSession.currentExecution?.id, disabledSession.failureExecution?.id)
        let savedDrafted = try XCTUnwrap(try store.load().runConfigurations.first { $0.id == drafted.id })
        XCTAssertEqual(savedDrafted.command, draftCommand)
        XCTAssertEqual(savedDrafted.workingDirectory, "second")
        XCTAssertTrue(coordinator.hasCommandDraft(configurationID: drafted.id))
        XCTAssertEqual(
            coordinator.runConfigurations().first { $0.id == drafted.id }?.command,
            newerDraft
        )
    }

    func testBatchStartRecordsActiveExecutionConflictWithoutReplacingTheRunningExecution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let configuration = ProjectRunConfiguration(
            id: "conflict",
            projectID: projectRoot.path,
            name: "Conflict",
            command: "run conflict",
            workingDirectory: "."
        )
        let fixture = try ProjectRunTestFixture(
            directory: directory,
            configurations: [configuration],
            projectRoots: [projectRoot]
        )
        fixture.projectsModel.refreshProjects()
        for _ in 0 ..< 100 where fixture.projectsModel.records.contains(where: { $0.availability == .unknown }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let intent = fixture.coordinator.makeBatchStartIntent(in: [configuration])
        XCTAssertEqual(fixture.coordinator.run(configuration, projectRoot: projectRoot.path), .started)
        let runningExecutionID = try XCTUnwrap(
            fixture.coordinator.session(for: configuration.id)?.activeExecution?.id
        )

        fixture.coordinator.submitBatchStart(intent)

        let session = try XCTUnwrap(fixture.coordinator.session(for: configuration.id))
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.activeExecution?.id, runningExecutionID)
        XCTAssertEqual(session.currentExecution?.id, runningExecutionID)
        XCTAssertNotEqual(session.failureExecution?.id, runningExecutionID)
        XCTAssertEqual(session.failureMessage, "该运行配置已有活动会话")
        XCTAssertEqual(fixture.factory.engines[0].launches.count, 1)
    }

    func testBatchStartRejectsChangedWorkingDirectoryWithoutBlockingSibling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        let firstTarget = projectRoot.appendingPathComponent("first")
        let secondTarget = projectRoot.appendingPathComponent("second")
        let current = projectRoot.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: firstTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: firstTarget)
        let changed = ProjectRunConfiguration(
            id: "changed",
            projectID: projectRoot.path,
            name: "Changed",
            command: "run changed",
            workingDirectory: "current"
        )
        let sibling = ProjectRunConfiguration(
            id: "sibling",
            projectID: projectRoot.path,
            name: "Sibling",
            command: "run sibling",
            workingDirectory: "."
        )
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument(runConfigurations: [changed, sibling])
        document.records = [projectRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        projectsModel.refreshProjects()
        for _ in 0 ..< 100 where projectsModel.records.contains(where: { $0.availability == .unknown }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        let intent = coordinator.makeBatchStartIntent(in: [changed, sibling])
        XCTAssertEqual(intent.startRequests.first?.workingDirectory, firstTarget.path)
        try FileManager.default.removeItem(at: current)
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: secondTarget)

        coordinator.submitBatchStart(intent)

        XCTAssertEqual(
            coordinator.session(for: changed.id)?.state,
            .launchFailed(ProjectRunLaunchError.reviewedWorkingDirectoryChanged.localizedDescription)
        )
        XCTAssertEqual(coordinator.session(for: changed.id)?.currentExecution?.workingDirectory, firstTarget.path)
        XCTAssertEqual(coordinator.session(for: sibling.id)?.state, .running)
        XCTAssertEqual(factory.engines.last?.launches.first?.arguments, ["-i", "-c", sibling.command])
    }

    func testBatchStartRejectsRemovedProjectRootWithoutBlockingSibling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let removedRoot = directory.appendingPathComponent("removed")
        let survivingRoot = directory.appendingPathComponent("surviving")
        try FileManager.default.createDirectory(at: removedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: survivingRoot, withIntermediateDirectories: true)
        let removed = ProjectRunConfiguration(
            id: "removed",
            projectID: removedRoot.path,
            name: "Removed",
            command: "run removed",
            workingDirectory: "."
        )
        let surviving = ProjectRunConfiguration(
            id: "surviving",
            projectID: survivingRoot.path,
            name: "Surviving",
            command: "run surviving",
            workingDirectory: "."
        )
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument(runConfigurations: [removed, surviving])
        document.records = [removedRoot.path, survivingRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        projectsModel.refreshProjects()
        for _ in 0 ..< 100 where projectsModel.records.contains(where: { $0.availability == .unknown }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        let intent = coordinator.makeBatchStartIntent(in: [removed, surviving])
        XCTAssertNotNil(coordinator.removeProjects(projectIDs: [removedRoot.path]))

        coordinator.submitBatchStart(intent)

        let removedSession = try XCTUnwrap(coordinator.session(for: removed.id))
        XCTAssertEqual(removedSession.state, .launchFailed("所属项目记录不存在"))
        XCTAssertEqual(removedSession.currentExecution?.id, removedSession.failureExecution?.id)
        XCTAssertEqual(coordinator.session(for: surviving.id)?.state, .running)
        XCTAssertEqual(factory.engines.count, 2)
        XCTAssertTrue(factory.engines[0].launches.isEmpty)
        XCTAssertEqual(factory.engines[1].launches.first?.arguments, ["-i", "-c", surviving.command])
    }

    func testBatchStartPersistsSuccessfulDraftsWithoutBlockingOnSiblingLaunchFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let failed = ProjectRunConfiguration(
            id: "failed",
            projectID: projectRoot.path,
            name: "Failed",
            command: "run saved failed",
            workingDirectory: "."
        )
        let successful = ProjectRunConfiguration(
            id: "successful",
            projectID: projectRoot.path,
            name: "Successful",
            command: "run saved successful",
            workingDirectory: "."
        )
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument(runConfigurations: [failed, successful])
        document.records = [projectRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        projectsModel.refreshProjects()
        for _ in 0 ..< 100 where projectsModel.records.contains(where: { $0.availability == .unknown }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let factory = FakeProjectRunEngineFactory()
        factory.startErrors = [FakeProjectRunError.launchFailed, nil]
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        let failedDraft = "run draft failed"
        let successfulDraft = "run draft successful"
        XCTAssertTrue(coordinator.updateRunConfiguration(
            failed,
            name: failed.name,
            command: failedDraft,
            workingDirectory: failed.workingDirectory
        ))
        XCTAssertTrue(coordinator.updateRunConfiguration(
            successful,
            name: successful.name,
            command: successfulDraft,
            workingDirectory: successful.workingDirectory
        ))

        coordinator.startBatch(in: coordinator.runConfigurations())

        XCTAssertEqual(
            coordinator.session(for: failed.id)?.state,
            .launchFailed(FakeProjectRunError.launchFailed.localizedDescription)
        )
        XCTAssertEqual(coordinator.session(for: successful.id)?.state, .running)
        XCTAssertEqual(factory.engines.count, 2)
        XCTAssertTrue(coordinator.hasCommandDraft(configurationID: failed.id))
        XCTAssertFalse(coordinator.hasCommandDraft(configurationID: successful.id))
        let savedConfigurations = try store.load().runConfigurations
        XCTAssertEqual(savedConfigurations.first { $0.id == failed.id }?.command, failed.command)
        XCTAssertEqual(savedConfigurations.first { $0.id == successful.id }?.command, successfulDraft)
    }

    func testActiveConfigurationMustStopBeforeDisabling() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument()
        document.records = [projectRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        let configuration = try XCTUnwrap(projectsModel.createRunConfiguration(
            projectID: projectRoot.path,
            name: "开发服务器",
            command: "npm run dev",
            workingDirectory: "."
        ))
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: { FakeProjectRunEngine() },
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        XCTAssertEqual(coordinator.run(configuration, projectRoot: projectRoot.path), .started)

        XCTAssertFalse(coordinator.setRunConfigurationEnabled(configuration, isEnabled: false))
        XCTAssertTrue(try XCTUnwrap(projectsModel.runConfigurations().first).isEnabled)
    }

    func testSessionKeepsLaunchFactsAndOnlyRecordsUnexpectedFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let factory = FakeProjectRunEngineFactory()
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: directory.path,
            name: "开发服务器",
            command: "npm run dev",
            workingDirectory: "."
        )
        let projectsModel = try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [configuration])
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        XCTAssertEqual(coordinator.run(configuration, projectRoot: directory.path), .started)
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

    func testSuccessiveStartsCreateDistinctExecutionsWhileReusingSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let factory = FakeProjectRunEngineFactory()
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: directory.path,
            name: "开发服务器",
            command: "npm run dev",
            workingDirectory: "."
        )
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [configuration]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        XCTAssertEqual(coordinator.run(configuration, projectRoot: directory.path), .started)
        let session = try XCTUnwrap(coordinator.session(for: configuration.id))
        let terminal = session.terminalView
        let firstExecution = try XCTUnwrap(session.currentExecution)
        XCTAssertEqual(firstExecution.configurationID, configuration.id)
        XCTAssertEqual(firstExecution.command, configuration.command)
        XCTAssertEqual(firstExecution.projectRoot, directory.path)
        XCTAssertEqual(firstExecution.workingDirectory, directory.path)
        XCTAssertEqual(session.activeExecution?.id, firstExecution.id)

        factory.engines[0].finish(exitCode: 0)
        XCTAssertNil(session.activeExecution)
        XCTAssertEqual(coordinator.run(configuration, projectRoot: directory.path), .started)

        let secondExecution = try XCTUnwrap(session.currentExecution)
        XCTAssertNotEqual(secondExecution.id, firstExecution.id)
        XCTAssertEqual(session.activeExecution?.id, secondExecution.id)
        XCTAssertTrue(coordinator.session(for: configuration.id) === session)
        XCTAssertTrue(session.terminalView === terminal)
        XCTAssertEqual(factory.engines.count, 1)
        XCTAssertEqual(factory.engines[0].launches.count, 2)
    }

    func testLaunchFailureHasItsOwnExecutionIdentityBeforeRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let factory = FakeProjectRunEngineFactory()
        factory.startError = FakeProjectRunError.launchFailed
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: directory.path,
            name: "开发服务器",
            command: "npm run dev",
            workingDirectory: "."
        )
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [configuration]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        XCTAssertEqual(
            coordinator.run(configuration, projectRoot: directory.path),
            .rejected(FakeProjectRunError.launchFailed.localizedDescription)
        )
        let session = try XCTUnwrap(coordinator.session(for: configuration.id))
        let failedExecution = try XCTUnwrap(session.currentExecution)
        XCTAssertEqual(session.state, .launchFailed(FakeProjectRunError.launchFailed.localizedDescription))
        XCTAssertNil(session.activeExecution)

        factory.engines[0].startError = nil
        XCTAssertEqual(coordinator.run(configuration, projectRoot: directory.path), .started)

        let retryExecution = try XCTUnwrap(session.currentExecution)
        XCTAssertNotEqual(retryExecution.id, failedExecution.id)
        XCTAssertEqual(session.activeExecution?.id, retryExecution.id)
        XCTAssertEqual(factory.engines[0].launches.count, 1)
    }

    func testRestartPreflightFailureHasDistinctExecutionIdentityWithoutReplacingActiveExecution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        let workingDirectory = projectRoot.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let configuration = ProjectRunConfiguration(
            id: "restart-preflight",
            projectID: projectRoot.path,
            name: "Restart Preflight",
            command: "run restart",
            workingDirectory: "app"
        )
        let fixture = try ProjectRunTestFixture(
            directory: directory,
            configurations: [configuration],
            projectRoots: [projectRoot]
        )
        XCTAssertEqual(fixture.coordinator.run(configuration, projectRoot: projectRoot.path), .started)
        let session = try XCTUnwrap(fixture.coordinator.session(for: configuration.id))
        let activeExecutionID = try XCTUnwrap(session.activeExecution?.id)
        try FileManager.default.removeItem(at: workingDirectory)

        fixture.coordinator.restart(configuration, projectRoot: projectRoot.path)

        XCTAssertEqual(
            session.state,
            .restartFailed(ProjectRunConfigurationError.workingDirectoryMissing.localizedDescription)
        )
        XCTAssertEqual(session.activeExecution?.id, activeExecutionID)
        XCTAssertEqual(session.currentExecution?.id, activeExecutionID)
        XCTAssertNotEqual(session.failureExecution?.id, activeExecutionID)
        XCTAssertNil(session.failureExecution?.workingDirectory)
        XCTAssertEqual(fixture.factory.engines[0].launches.count, 1)
        XCTAssertTrue(fixture.factory.engines[0].signals.isEmpty)
    }

    func testLaunchRejectsAWorkingDirectoryChangedAfterFreezing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        let firstTarget = projectRoot.appendingPathComponent("first")
        let secondTarget = projectRoot.appendingPathComponent("second")
        let workingDirectory = projectRoot.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: firstTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workingDirectory, withDestinationURL: firstTarget)
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: projectRoot.path,
            name: "开发服务器",
            command: "npm run dev",
            workingDirectory: "current"
        )

        let fixture = try ProjectRunTestFixture(directory: directory, configurations: [configuration], projectRoots: [projectRoot])
        let factory = fixture.factory
        fixture.projectsModel.refreshProjects()
        for _ in 0 ..< 100 where fixture.projectsModel.isRefreshingProjects { try await Task.sleep(for: .milliseconds(10)) }
        let coordinator = fixture.coordinator
        let intent = coordinator.makeBatchStartIntent(in: [configuration])
        let request = try XCTUnwrap(intent.startRequests.first)
        XCTAssertEqual(request.workingDirectory, firstTarget.path)
        try FileManager.default.removeItem(at: workingDirectory)
        try FileManager.default.createSymbolicLink(at: workingDirectory, withDestinationURL: secondTarget)

        coordinator.submitBatchStart(intent)
        let session = try XCTUnwrap(coordinator.session(for: configuration.id))
        XCTAssertEqual(session.currentExecution?.workingDirectory, firstTarget.path)
        XCTAssertEqual(
            session.state,
            .launchFailed(ProjectRunLaunchError.reviewedWorkingDirectoryChanged.localizedDescription)
        )
        XCTAssertNil(session.activeExecution)
        XCTAssertEqual(factory.engines.first?.launches.count, 0)
    }

    func testExecutionAwareStopIgnoresEndedAndReplacedExecutions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let factory = FakeProjectRunEngineFactory()
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: directory.path,
            name: "开发服务器",
            command: "npm run dev",
            workingDirectory: "."
        )
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [configuration]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        XCTAssertEqual(coordinator.run(configuration, projectRoot: directory.path), .started)
        let session = try XCTUnwrap(coordinator.session(for: configuration.id))
        let firstExecutionID = try XCTUnwrap(session.currentExecution?.id)
        let engine = try XCTUnwrap(factory.engines.first)

        engine.finish(exitCode: 0)
        let endedSignalCount = engine.signals.count
        coordinator.stop(executionID: firstExecutionID)
        XCTAssertEqual(engine.signals.count, endedSignalCount)
        XCTAssertEqual(session.state, .exited(0))

        XCTAssertEqual(coordinator.run(configuration, projectRoot: directory.path), .started)
        let replacementExecutionID = try XCTUnwrap(session.currentExecution?.id)
        XCTAssertNotEqual(replacementExecutionID, firstExecutionID)
        let replacementSignalCount = engine.signals.count

        coordinator.stop(executionID: firstExecutionID)
        XCTAssertEqual(engine.signals.count, replacementSignalCount)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.activeExecution?.id, replacementExecutionID)

        coordinator.stop(executionID: replacementExecutionID)
        XCTAssertEqual(engine.signals.last, SIGINT)
        XCTAssertEqual(session.state, .stopping)
    }

    func testRemovingProjectRecordPreservesSessionsAndRequiresExplicitDetachmentAfterReload() throws {
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
        document.records = [firstRoot.path, secondRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
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
            XCTAssertEqual(coordinator.run(
                configuration,
                projectRoot: configuration.projectID
            ), .started)
        }
        factory.engines[0].signalSucceeds = false

        let session = try XCTUnwrap(coordinator.session(for: first.id))
        let executionID = session.activeExecution?.id
        let summary = coordinator.removeProjects(projectIDs: [firstRoot.path])

        XCTAssertEqual(summary, ProjectRemovalSummary(projectCount: 1, ignoredProjectCount: 0))
        XCTAssertTrue(factory.engines[0].signals.isEmpty)
        XCTAssertTrue(factory.engines[1].signals.isEmpty)
        XCTAssertTrue(coordinator.session(for: first.id) === session)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.activeExecution?.id, executionID)
        XCTAssertNotNil(coordinator.session(for: second.id))
        XCTAssertEqual(Set(projectsModel.runConfigurations().map(\.id)), [first.id, second.id])
        XCTAssertEqual(Set(try store.load().runConfigurations.map(\.id)), [first.id, second.id])

        let stale = try XCTUnwrap(coordinator.runConfigurations().first { $0.id == first.id })
        XCTAssertTrue(coordinator.updateRunConfiguration(
            stale, name: "已删除项目的服务", command: "pwd", workingDirectory: stale.workingDirectory
        ))
        XCTAssertEqual(session.activeExecution?.id, executionID)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.activeExecution?.command, first.command)
        XCTAssertEqual(try store.load().runConfigurations.first { $0.id == first.id }?.name, "已删除项目的服务")

        let reloadedModel = ProjectsViewModel(store: store)
        let relaunchedCoordinator = ProjectRunCoordinator(
            projectsModel: reloadedModel,
            makeEngine: FakeProjectRunEngineFactory().makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        var retained = try XCTUnwrap(relaunchedCoordinator.runConfigurations().first { $0.id == first.id })
        XCTAssertEqual(retained.projectID, first.projectID)
        guard case .rejected = relaunchedCoordinator.run(retained) else { return XCTFail("失效关联不能启动") }
        reloadedModel.addDirect([firstRoot])
        guard case .rejected = relaunchedCoordinator.run(retained) else { return XCTFail("同目录新记录不能恢复旧关联") }
        retained.projectID = nil
        XCTAssertTrue(reloadedModel.updateRunConfiguration(
            retained, name: retained.name, command: retained.command, workingDirectory: retained.workingDirectory
        ))
        let detached = try XCTUnwrap(reloadedModel.runConfigurations().first { $0.id == first.id })
        XCTAssertEqual(detached.workingDirectory, firstRoot.path)
        XCTAssertEqual(relaunchedCoordinator.run(detached), .started)
        XCTAssertEqual(relaunchedCoordinator.session(for: first.id)?.activeExecution?.workingDirectory, firstRoot.path)
        XCTAssertEqual(relaunchedCoordinator.run(second, projectRoot: secondRoot.path), .started)
    }

    func testFailedProjectRemovalPreservesSessionsConfigurations() throws {
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
        document.records = [projectRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
        try store.save(document)
        let projectsModel = ProjectsViewModel(store: store)
        let factory = FakeProjectRunEngineFactory()
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )
        XCTAssertEqual(coordinator.run(
            configuration,
            projectRoot: projectRoot.path
        ), .started)
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

    func testFirstRunLaunchesImmediatelyAndCanRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        let workingDirectory = projectRoot.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        let factory = FakeProjectRunEngineFactory()
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: projectRoot.path,
            name: "开发服务器",
            command: "printf '\u{1b}[31mred\u{1b}[0m\\n'",
            workingDirectory: "scripts"
        )
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: store, configurations: [configuration]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        XCTAssertEqual(coordinator.run(configuration, projectRoot: projectRoot.path), .started)
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

    func testCoordinatorCommitsAnEditedCommandOnlyAfterLaunch() throws {
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
        document.records = [projectRoot.path].map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) }
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
        guard case .rejected = coordinator.run(staged, projectRoot: projectRoot.path) else {
            return XCTFail("启动失败必须保留 launch draft")
        }
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
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [first, second]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: scheduler
        )

        XCTAssertEqual(coordinator.run(first, projectRoot: projectRoot.path), .started)
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

    func testRestartWaitsForCleanupCanBeCancelledAndDoesNotLaunchWhenProcessesRemain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let factory = FakeProjectRunEngineFactory()
        let scheduler = FakeProjectRunScheduler()
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: directory.path,
            name: "服务",
            command: "sleep 30",
            workingDirectory: "."
        )
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [configuration]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: scheduler
        )

        XCTAssertEqual(coordinator.run(configuration, projectRoot: directory.path), .started)
        let session = try XCTUnwrap(coordinator.session(for: configuration.id))
        let firstExecutionID = try XCTUnwrap(session.currentExecution?.id)
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
        XCTAssertEqual(session.activeExecution?.id, firstExecutionID)

        engine.signalSucceeds = true
        coordinator.restart(configuration, projectRoot: directory.path)
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .running)
        XCTAssertEqual(engine.launches.count, 2)
        let restartedExecutionID = try XCTUnwrap(session.currentExecution?.id)
        XCTAssertNotEqual(restartedExecutionID, firstExecutionID)
        XCTAssertEqual(session.activeExecution?.id, restartedExecutionID)
        XCTAssertTrue(coordinator.session(for: configuration.id)?.terminalView === terminal)

        coordinator.restart(configuration, projectRoot: directory.path)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .restarting)
        coordinator.stop(configurationID: configuration.id)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .stopping)
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .stopped(137))
        XCTAssertNil(session.activeExecution)
        XCTAssertEqual(session.currentExecution?.id, restartedExecutionID)
        XCTAssertEqual(engine.launches.count, 2)
    }

    func testStopFailureRemainsActiveAndNeedsAttention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let factory = FakeProjectRunEngineFactory()
        let scheduler = FakeProjectRunScheduler()
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: directory.path,
            name: "服务",
            command: "sleep 30",
            workingDirectory: "."
        )
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [configuration]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: scheduler
        )

        XCTAssertEqual(coordinator.run(
            configuration,
            projectRoot: directory.path
        ), .started)
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
        // The shell exit notification may already have arrived before the timeout.
        XCTAssertFalse(scheduler.actions.isEmpty, "停止失败后必须继续只读复查")
        if !scheduler.actions.isEmpty { scheduler.runNext() }

        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .stopped(137))
        XCTAssertNil(coordinator.session(for: configuration.id)?.failureMessage)
    }

    func testUnexpectedExitCleanupFailureConvergesAndKeepsExitSemantics() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let factory = FakeProjectRunEngineFactory()
        let scheduler = FakeProjectRunScheduler()
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: directory.path,
            name: "服务",
            command: "exit 2",
            workingDirectory: "."
        )
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [configuration]),
            makeEngine: factory.makeEngine,
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: scheduler
        )

        XCTAssertEqual(coordinator.run(
            configuration,
            projectRoot: directory.path
        ), .started)
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
        let configuration = ProjectRunConfiguration(
            id: "run",
            projectID: projectRoot.path,
            name: "测试",
            command: "exit 7",
            workingDirectory: "scripts"
        )
        let coordinator = ProjectRunCoordinator(
            projectsModel: try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [configuration]),
            makeEngine: factory.makeEngine,
            shellProvider: shellProvider,
            scheduler: FakeProjectRunScheduler()
        )

        XCTAssertEqual(coordinator.run(configuration, projectRoot: projectRoot.path), .started)
        let session = try XCTUnwrap(coordinator.session(for: configuration.id))
        let engine = try XCTUnwrap(factory.engines.first)
        let retainedTerminal = engine.terminalView
        engine.finish(exitCode: 7)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.state, .exited(7))

        var rerun = configuration
        rerun.command = "exit 0"
        XCTAssertEqual(coordinator.run(rerun, projectRoot: projectRoot.path), .started)
        XCTAssertTrue(coordinator.session(for: configuration.id)?.terminalView === retainedTerminal)
        engine.finish(exitCode: 0)
        let successfulExecutionID = try XCTUnwrap(session.currentExecution?.id)

        try FileManager.default.removeItem(at: workingDirectory)
        try FileManager.default.createSymbolicLink(at: workingDirectory, withDestinationURL: outside.appendingPathComponent("missing"))
        guard case .rejected = coordinator.run(rerun, projectRoot: projectRoot.path) else {
            return XCTFail("失效符号链接必须拒绝")
        }
        XCTAssertEqual(engine.launches.count, 2)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.lastSuccessfulCommand, "exit 0")
        let preflightFailureExecution = try XCTUnwrap(session.currentExecution)
        XCTAssertNotEqual(preflightFailureExecution.id, successfulExecutionID)
        XCTAssertEqual(preflightFailureExecution.id, session.failureExecution?.id)
        XCTAssertNil(preflightFailureExecution.workingDirectory)
        XCTAssertNil(session.activeExecution)

        try FileManager.default.removeItem(at: workingDirectory)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: false)
        shellProvider.error = FakeProjectRunError.unavailableShell
        guard case .rejected = coordinator.run(rerun, projectRoot: projectRoot.path) else {
            return XCTFail("Default Login Shell 不可用时必须拒绝")
        }
        XCTAssertEqual(engine.launches.count, 2)
        XCTAssertEqual(coordinator.session(for: configuration.id)?.lastSuccessfulCommand, "exit 0")
        let shellFailureExecution = try XCTUnwrap(session.currentExecution)
        XCTAssertNotEqual(shellFailureExecution.id, successfulExecutionID)
        XCTAssertEqual(shellFailureExecution.workingDirectory, workingDirectory.path)
        XCTAssertNil(session.activeExecution)

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
        window.setContentSize(NSSize(width: 392, height: 280))
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
        XCTAssertLessThanOrEqual(engine.terminal.bounds.width, 392)
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
        let projectsModel = try storedRunModel(store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")), configurations: [first, second, background])
        let coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: { SwiftTermProjectRunEngine() },
            shellProvider: FakeProjectRunShellProvider(path: "/bin/zsh"),
            scheduler: FakeProjectRunScheduler()
        )

        for configuration in [first, second] {
            XCTAssertEqual(coordinator.run(
                configuration,
                projectRoot: configuration.projectID
            ), .started)
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

    func testRealEngineDoesNotFinishBeforeChildExitsAndReapsIt() async throws {
        let engine = SwiftTermProjectRunEngine()
        var exits: [Int32?] = []
        engine.onExit = { exits.append($0) }
        try engine.start(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 1; exit 7"],
            loginName: "sh",
            workingDirectory: FileManager.default.temporaryDirectory.path
        )
        let pid = engine.terminal.process.shellPid
        defer { _ = engine.signalProcessGroups(SIGKILL) }

        engine.processTerminated(source: engine.terminal, exitCode: nil)
        XCTAssertTrue(exits.isEmpty, "终端通知不等于子进程已经退出")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while exits.isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(exits.count, 1)
        XCTAssertEqual(exits.first ?? nil, 7)
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "子进程必须回收，不能留下僵尸")
        XCTAssertTrue(engine.signalProcessGroups(0))
        XCTAssertEqual(engine.ownedProcessIDs, [])
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
private func storedRunModel(store: ProjectRecordStore, configurations: [ProjectRunConfiguration]) throws -> ProjectsViewModel {
    let roots = Set(configurations.compactMap(\.projectID))
    let document = ProjectRecordDocument(
        records: roots.sorted().map { ProjectRecord(id: $0, path: $0, discoveredAt: Date()) },
        runConfigurations: configurations
    )
    try store.save(document)
    return ProjectsViewModel(store: store)
}

@MainActor
private struct ProjectRunTestFixture {
    let store: ProjectRecordStore
    let projectsModel: ProjectsViewModel
    let factory: FakeProjectRunEngineFactory
    let scheduler: FakeProjectRunScheduler
    let coordinator: ProjectRunCoordinator

    init(
        directory: URL,
        configurations: [ProjectRunConfiguration],
        projectRoots: [URL],
        shellProvider: FakeProjectRunShellProvider = FakeProjectRunShellProvider(path: "/bin/zsh")
    ) throws {
        store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument(runConfigurations: configurations)
        document.records = projectRoots.map { ProjectRecord(id: $0.path, path: $0.path, discoveredAt: Date()) }
        try store.save(document)
        projectsModel = ProjectsViewModel(store: store)
        factory = FakeProjectRunEngineFactory()
        scheduler = FakeProjectRunScheduler()
        coordinator = ProjectRunCoordinator(
            projectsModel: projectsModel,
            makeEngine: factory.makeEngine,
            shellProvider: shellProvider,
            scheduler: scheduler
        )
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
        .frame(minWidth: 392, minHeight: 280)
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
    var startErrors: [Error?] = []

    func makeEngine() -> any ProjectRunProcessEngine {
        let engine = FakeProjectRunEngine()
        engine.startError = startErrors.isEmpty ? startError : startErrors.removeFirst()
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
