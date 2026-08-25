import XCTest
@testable import DevEnv

final class ProjectRecordsTests: XCTestCase {
    func testBatchDiscoveryFindsProjectRootsAndSkipsExcludedTreesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let gitProject = root.appendingPathComponent("git-project")
        let nestedGitProject = gitProject.appendingPathComponent("vendor-source")
        let manifestProject = root.appendingPathComponent("manifest-project")
        let nestedManifestProject = manifestProject.appendingPathComponent("packages/child")
        let hiddenProject = root.appendingPathComponent(".hidden-project")
        let dependencyProject = root.appendingPathComponent("node_modules/dependency")
        let externalProject = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: externalProject) }

        for directory in [gitProject, nestedGitProject, manifestProject, nestedManifestProject, hiddenProject,
                          dependencyProject, externalProject] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: gitProject.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: nestedGitProject.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        for file in [
            gitProject.appendingPathComponent("package.json"),
            gitProject.appendingPathComponent("packages/absorbed/Cargo.toml"),
            manifestProject.appendingPathComponent("pyproject.toml"),
            nestedManifestProject.appendingPathComponent("package.json"),
            hiddenProject.appendingPathComponent("go.mod"),
            dependencyProject.appendingPathComponent("Cargo.toml"),
            externalProject.appendingPathComponent("Gemfile"),
        ] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-project"),
            withDestinationURL: externalProject
        )

        let result = ProjectDiscovery().discover(searchRoots: [root], ignoredPaths: [])

        XCTAssertEqual(result.projectPaths.sorted(), [
            gitProject.resolvingSymlinksInPath().standardizedFileURL.path,
            nestedGitProject.resolvingSymlinksInPath().standardizedFileURL.path,
            manifestProject.resolvingSymlinksInPath().standardizedFileURL.path,
            nestedManifestProject.resolvingSymlinksInPath().standardizedFileURL.path,
        ].sorted())
    }

    func testRecordLifecycleMergesIncrementallyAndOnlyClearsDisplayedNewProjects() {
        let firstDiscovery = Date(timeIntervalSince1970: 100)
        let laterDiscovery = Date(timeIntervalSince1970: 200)
        var document = ProjectRecordDocument()

        document.mergeDiscovered(["/Projects/alpha", "/Projects/beta"], at: firstDiscovery)
        document.mergeDiscovered(["/Projects/alpha", "/Projects/gamma"], at: laterDiscovery)
        document.clearNew(displayedProjectIDs: ["/Projects/alpha", "/Projects/beta"])

        XCTAssertEqual(document.records.map(\.path), ["/Projects/alpha", "/Projects/beta", "/Projects/gamma"])
        XCTAssertEqual(document.records[0].firstDiscoveredAt, firstDiscovery)
        XCTAssertEqual(document.records[0].lastDiscoveredAt, laterDiscovery)
        XCTAssertFalse(document.records[0].isNew)
        XCTAssertFalse(document.records[1].isNew)
        XCTAssertTrue(document.records[2].isNew)

        document.remove(projectID: "/Projects/beta", at: laterDiscovery)
        XCTAssertFalse(document.records.contains { $0.id == "/Projects/beta" })
        XCTAssertEqual(document.ignoredProjects.map(\.path), ["/Projects/beta"])
        XCTAssertEqual(document.ignoredProjects.first?.boundary, .manifest)

        document.mergeDiscovered(["/Projects/beta"], at: laterDiscovery)
        XCTAssertFalse(document.records.contains { $0.id == "/Projects/beta" })
        document.restore(path: "/Projects/beta", at: laterDiscovery)
        XCTAssertTrue(document.records.first { $0.id == "/Projects/beta" }?.isNew == true)
        XCTAssertEqual(document.records.first { $0.id == "/Projects/beta" }?.boundary, .manifest)
        XCTAssertTrue(document.ignoredProjects.isEmpty)
    }

    func testProjectRecordStoreRoundTripsAndRecreatesCorruptStoreWithBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("project-records.json")
        let store = ProjectRecordStore(fileURL: fileURL)
        let discoveredAt = Date(timeIntervalSince1970: 123)
        var document = ProjectRecordDocument()
        document.mergeDiscovered(["/Projects/alpha"], at: discoveredAt)

        try store.save(document)
        let restored = try store.load()

        XCTAssertEqual(restored.records.first?.path, "/Projects/alpha")
        XCTAssertEqual(try XCTUnwrap(restored.records.first).firstDiscoveredAt.timeIntervalSince1970, 123, accuracy: 0.001)
        XCTAssertEqual(restored.records.first?.boundary, .manifest)
        XCTAssertEqual(restored.records.first?.availability, .unknown)

        let corruptData = Data("not json".utf8)
        try corruptData.write(to: fileURL, options: .atomic)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptData)

        let backupURL = try XCTUnwrap(store.recreatePreservingBackup())
        XCTAssertEqual(try Data(contentsOf: backupURL), corruptData)
        XCTAssertTrue(try store.load().records.isEmpty)
    }

    func testProjectRecordStoreRejectsIncompatibleSchemaWithoutOverwritingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("project-records.json")
        let incompatible = Data("{\"schemaVersion\":99,\"records\":[],\"ignoredProjects\":[]}".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try incompatible.write(to: fileURL)
        let store = ProjectRecordStore(fileURL: fileURL)

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: fileURL), incompatible)
    }

    func testIgnoredProjectIsAnExclusionBoundaryAndDirectAddResolvesItsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ignored = root.appendingPathComponent("ignored")
        let child = ignored.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data().write(to: ignored.appendingPathComponent("package.json"))
        try Data().write(to: child.appendingPathComponent("Cargo.toml"))
        let symlink = root.appendingPathComponent("direct-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: ignored)
        let discovery = ProjectDiscovery()
        let ignoredPath = discovery.canonicalPath(ignored)

        let batch = discovery.discover(searchRoots: [root], ignoredPaths: [ignoredPath])

        XCTAssertTrue(batch.projectPaths.isEmpty)
        XCTAssertEqual(discovery.directProjectPaths([symlink]), [ignoredPath])
    }

    func testDirectBoundariesCollapseManifestChildrenButKeepGitAndExplicitChildren() {
        let parent = "/Projects/parent"
        let manifestChild = "\(parent)/packages/manifest-child"
        let gitChild = "\(parent)/vendor/git-child"
        var document = ProjectRecordDocument()
        document.mergeDiscovered(
            [manifestChild, gitChild],
            gitProjectPaths: [gitChild],
            at: Date(timeIntervalSince1970: 1)
        )

        document.addDirect([parent], at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(document.records.map(\.path), [parent, gitChild])
        XCTAssertEqual(document.records.first { $0.path == parent }?.boundary, .explicit)
        XCTAssertEqual(document.records.first { $0.path == gitChild }?.boundary, .git)

        document.addDirect([manifestChild], at: Date(timeIntervalSince1970: 3))

        XCTAssertEqual(document.records.map(\.path), [parent, manifestChild, gitChild])
        XCTAssertEqual(document.records.first { $0.path == manifestChild }?.boundary, .explicit)
    }

    func testIgnoredProjectRestoresItsOriginalBoundary() {
        var document = ProjectRecordDocument()
        document.addDirect(["/Projects/explicit"], at: Date(timeIntervalSince1970: 1))
        document.remove(projectID: "/Projects/explicit", at: Date(timeIntervalSince1970: 2))

        document.restore(path: "/Projects/explicit", at: Date(timeIntervalSince1970: 3))

        XCTAssertEqual(document.records.first?.boundary, .explicit)
    }

    func testBatchDiscoveryUsesContainingGitRootAndHonorsExplicitBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let nestedSearchRoot = root.appendingPathComponent("sources/app")
        try FileManager.default.createDirectory(at: nestedSearchRoot, withIntermediateDirectories: true)
        try Data().write(to: nestedSearchRoot.appendingPathComponent("package.json"))
        let discovery = ProjectDiscovery()
        let rootPath = discovery.canonicalPath(root)

        let gitResult = discovery.discover(searchRoots: [nestedSearchRoot], ignoredPaths: [])

        XCTAssertEqual(gitResult.projectPaths, [rootPath])
        XCTAssertEqual(gitResult.gitProjectPaths, [rootPath])

        let explicitResult = discovery.discover(
            searchRoots: [nestedSearchRoot],
            ignoredPaths: [],
            explicitBoundaryPaths: [discovery.canonicalPath(nestedSearchRoot)]
        )

        XCTAssertTrue(explicitResult.projectPaths.isEmpty)
    }

    func testInvalidSearchRootsProduceTraversalErrors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("not-a-directory")
        let missing = directory.appendingPathComponent("missing")
        try Data().write(to: file)

        let result = ProjectDiscovery().discover(searchRoots: [file, missing], ignoredPaths: [])

        XCTAssertEqual(result.projectPaths, [])
        XCTAssertTrue(result.errors.contains { $0.contains("不是目录") })
        XCTAssertTrue(result.errors.contains { $0.contains("目录不存在") })
    }

    func testCancellationKeepsDiscoveriesCompletedBeforeTheCancelledSearchRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        for directory in [first, second] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(".git"),
                withIntermediateDirectories: true
            )
        }
        let discovery = ProjectDiscovery()
        let firstPath = discovery.canonicalPath(first)
        let secondPath = discovery.canonicalPath(second)

        let result = discovery.discover(
            searchRoots: [first, second],
            ignoredPaths: [],
            isCancelled: { path, _ in path == secondPath }
        )

        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.projectPaths, [firstPath])
    }

    func testUnavailableProjectRecordIsRetainedAndMovedPathHasNewIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = root.appendingPathComponent("old-name")
        let newURL = root.appendingPathComponent("new-name")
        try FileManager.default.createDirectory(at: oldURL, withIntermediateDirectories: true)
        let discovery = ProjectDiscovery()
        let oldPath = discovery.canonicalPath(oldURL)
        var document = ProjectRecordDocument()
        document.mergeDiscovered([oldPath], at: Date(timeIntervalSince1970: 1))

        try FileManager.default.moveItem(at: oldURL, to: newURL)
        document.records[0].availability = discovery.availability(of: oldPath)
        document.mergeDiscovered(discovery.directProjectPaths([newURL]), at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(document.records.count, 2)
        XCTAssertEqual(document.records.first { $0.path == oldPath }?.availability, .unavailable("项目根目录不存在"))
        XCTAssertTrue(document.records.first { $0.path != oldPath }?.isNew == true)
    }

    func testRecoveredUnavailableProjectDoesNotBecomeNewAgain() {
        var document = ProjectRecordDocument()
        document.mergeDiscovered(["/Projects/alpha"], at: Date(timeIntervalSince1970: 1))
        document.clearNew(displayedProjectIDs: ["/Projects/alpha"])
        document.records[0].availability = .unavailable("项目根目录不存在")

        document.records[0].availability = .available

        XCTAssertFalse(document.records[0].isNew)
    }

    @MainActor
    func testDirectAddRefreshesAvailabilityForAllRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existingURL = directory.appendingPathComponent("existing")
        let addedURL = directory.appendingPathComponent("added")
        try FileManager.default.createDirectory(at: existingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: addedURL, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("project-records.json")
        let store = ProjectRecordStore(fileURL: fileURL)
        let discovery = ProjectDiscovery()
        var document = ProjectRecordDocument()
        document.mergeDiscovered(discovery.directProjectPaths([existingURL]))
        try store.save(document)
        let model = ProjectsViewModel(store: store)

        model.addDirect([addedURL])
        for _ in 0 ..< 100 where model.records.contains(where: { $0.availability == .unknown }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.records.map(\.availability), [.available, .available])
    }

    @MainActor
    func testCorruptStorePausesViewModelMutationsUntilConfirmedRecreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("project-records.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptData = Data("broken".utf8)
        try corruptData.write(to: fileURL)
        let projectURL = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let model = ProjectsViewModel(store: ProjectRecordStore(fileURL: fileURL))

        model.addDirect([projectURL])

        XCTAssertTrue(model.mutationsArePaused)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptData)

        model.recreateStore()
        model.addDirect([projectURL])
        XCTAssertFalse(model.mutationsArePaused)
        XCTAssertEqual(model.records.count, 1)
    }
}
