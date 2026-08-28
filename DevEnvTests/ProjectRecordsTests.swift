import XCTest
@testable import DevEnv

final class ProjectRecordsTests: XCTestCase {
    @MainActor
    func testPythonAndCargoRunSuggestionsStayStaticAndFollowProjectBoundaries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("project")
        let python = project.appendingPathComponent("services/api")
        let cargo = project.appendingPathComponent("tools/runner")
        let ambiguous = project.appendingPathComponent("services/ambiguous")
        let inline = project.appendingPathComponent("services/inline")
        let dotted = project.appendingPathComponent("services/dotted")
        let duplicate = project.appendingPathComponent("services/duplicate")
        let implicit = project.appendingPathComponent("tools/implicit/src")
        let nested = project.appendingPathComponent("nested/project")
        for item in [python, cargo, ambiguous, inline, dotted, duplicate, implicit, nested] {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        }
        try Data("""
        [project]
        name = "api"
        [project.scripts] # statically declared commands
        "serve-api" = "api.main:run"
        variable = "${MODULE}:run"
        [tool.uv]
        required-version = ">=0.8"
        """.utf8).write(to: python.appendingPathComponent("pyproject.toml"))
        try Data().write(to: python.appendingPathComponent("uv.lock"))
        try Data("""
        [[bin]]
        name = "server"
        path = "src/server.rs"
        [[bin]]
        name = "worker"
        path = "src/worker.rs"
        [[bin]]
        name = "gated"
        required-features = ["server"]
        """.utf8).write(to: cargo.appendingPathComponent("Cargo.toml"))
        try Data("""
        [project]
        dynamic = ["scripts"]
        [project.scripts]
        serve = "ambiguous:run"
        """.utf8).write(to: ambiguous.appendingPathComponent("pyproject.toml"))
        try Data().write(to: ambiguous.appendingPathComponent("uv.lock"))
        try Data("""
        [project]
        scripts = { inline = "inline:run" }
        [tool.uv]
        required-version = ">=0.8"
        """.utf8).write(to: inline.appendingPathComponent("pyproject.toml"))
        try Data().write(to: inline.appendingPathComponent("uv.lock"))
        try Data("""
        project.scripts.dotted = "dotted:run"
        [tool.uv]
        required-version = ">=0.8"
        """.utf8).write(to: dotted.appendingPathComponent("pyproject.toml"))
        try Data().write(to: dotted.appendingPathComponent("uv.lock"))
        try Data("""
        [project]
        scripts.same = "duplicate:first"
        scripts.same = "duplicate:second"
        scripts.other = "duplicate:other"
        scripts = { inline = "duplicate:inline" }
        [tool.uv]
        required-version = ">=0.8"
        """.utf8).write(to: duplicate.appendingPathComponent("pyproject.toml"))
        try Data().write(to: duplicate.appendingPathComponent("uv.lock"))
        try Data("[package]\nname = \"implicit\"\n".utf8)
            .write(to: implicit.deletingLastPathComponent().appendingPathComponent("Cargo.toml"))
        try Data().write(to: implicit.appendingPathComponent("main.rs"))
        try Data("""
        [project.scripts]
        hidden = "nested:run"
        [tool.uv]
        required-version = ">=0.8"
        """.utf8).write(to: nested.appendingPathComponent("pyproject.toml"))
        try Data().write(to: nested.appendingPathComponent("uv.lock"))

        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        let model = ProjectsViewModel(store: store)
        model.addDirect([project])
        model.addDirect([nested])
        for _ in 0 ..< 100 where model.isRefreshingProjects {
            try await Task.sleep(for: .milliseconds(10))
        }

        let suggestions = model.runSuggestions(projectID: project.path)
        XCTAssertEqual(Set(suggestions.map(\.command)), [
            "uv run serve-api", "uv run inline", "uv run dotted",
            "cargo run --bin gated --features server",
            "cargo run --bin server", "cargo run --bin worker",
        ])
        XCTAssertEqual(Set(suggestions.map(\.workingDirectory)), [
            "services/api", "services/dotted", "services/inline", "tools/runner",
        ])
        XCTAssertFalse(suggestions.contains { $0.command.contains("variable") || $0.command.contains("implicit") })
        XCTAssertTrue(model.runSuggestions(projectID: directory.appendingPathComponent("missing").path).isEmpty)
        let firstIDs = suggestions.map(\.id)

        model.refreshProjects()
        for _ in 0 ..< 100 where model.isRefreshingProjects {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.runSuggestions(projectID: project.path).map(\.id), firstIDs)

        let pythonSuggestion = try XCTUnwrap(model.runSuggestions(projectID: project.path).first {
            $0.command == "uv run serve-api"
        })
        let adopted = try XCTUnwrap(model.adoptSuggestion(pythonSuggestion))
        XCTAssertFalse(model.runSuggestions(projectID: project.path).contains {
            $0.sourceIdentity == adopted.sourceIdentity
        })
        XCTAssertTrue(model.updateRunConfiguration(
            adopted,
            name: "API",
            command: "uv run serve-api --reload",
            workingDirectory: adopted.workingDirectory
        ))
        try FileManager.default.removeItem(at: python.appendingPathComponent("pyproject.toml"))
        model.refreshProjects()
        for _ in 0 ..< 100 where model.isRefreshingProjects {
            try await Task.sleep(for: .milliseconds(10))
        }

        let saved = try XCTUnwrap(model.runConfigurations(projectID: project.path).first)
        XCTAssertEqual(saved.command, "uv run serve-api --reload")
        XCTAssertFalse(model.isSuggestionSourceAvailable(saved))
    }

    func testRunSuggestionsFilterNodeScriptsAndAddOneComposePerComponent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"name":"demo","packageManager":"pnpm@9","scripts":{"dev":"vite","start:web":"vite","build":"x","test":"x","predev":"x"}}"#.utf8)
            .write(to: root.appendingPathComponent("package.json"))
        try Data("services:\n  web:\n    image: nginx\n".utf8).write(to: root.appendingPathComponent("compose.yaml"))

        let analysis = ProjectRequirementsScanner().scan(projectRoot: root)
        let suggestions = ProjectRunSuggestionScanner().scan(projectRoot: root.path, analysis: analysis)

        XCTAssertEqual(suggestions.map(\.command), ["docker compose up", "pnpm run dev", "pnpm run start:web"])
        XCTAssertEqual(Set(suggestions.map(\.workingDirectory)), ["."])
        XCTAssertEqual(Set(suggestions.map(\.sourceIdentity)), [
            "compose.yaml#compose", "package.json#scripts.dev", "package.json#scripts.start:web"
        ])
    }

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

    func testComposeYamlVariantsArePrimaryManifests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let compose = root.appendingPathComponent("compose")
        let dockerCompose = root.appendingPathComponent("docker-compose")
        for (directory, name) in [(compose, "compose.yaml"), (dockerCompose, "docker-compose.yaml")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent(name))
        }

        let result = ProjectDiscovery().discover(searchRoots: [root], ignoredPaths: [])

        XCTAssertEqual(result.projectPaths.sorted(), [compose, dockerCompose].map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
        }.sorted())
    }

    func testRequirementsInIsAPrimaryManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("python-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("redis\n".utf8).write(to: project.appendingPathComponent("requirements.in"))

        let result = ProjectDiscovery().discover(searchRoots: [root], ignoredPaths: [])

        XCTAssertEqual(result.projectPaths, [project.resolvingSymlinksInPath().standardizedFileURL.path])
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

    func testBatchRemovalMovesProjectsAndClearsIgnoredProjects() {
        let date = Date(timeIntervalSince1970: 200)
        var document = ProjectRecordDocument()
        document.mergeDiscovered(["/Projects/alpha", "/Projects/beta"])
        document.remove(projectID: "/Projects/beta")

        let summary = document.remove(
            projectIDs: ["/Projects/alpha", "/Projects/beta"],
            at: date
        )

        XCTAssertEqual(summary, ProjectRemovalSummary(projectCount: 1, ignoredProjectCount: 1))
        XCTAssertTrue(document.records.isEmpty)
        XCTAssertEqual(document.ignoredProjects.map(\.path), ["/Projects/alpha"])
        XCTAssertEqual(document.ignoredProjects.first?.ignoredAt, date)
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

    func testProjectRecordStoreRejectsIncompatibleOrIncompleteSchemaWithoutOverwritingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("project-records.json")
        let incompatible = Data("{\"schemaVersion\":99,\"records\":[],\"ignoredProjects\":[]}".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try incompatible.write(to: fileURL)
        let store = ProjectRecordStore(fileURL: fileURL)

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: fileURL), incompatible)

        let incomplete = Data("{\"schemaVersion\":2,\"records\":[],\"ignoredProjects\":[]}".utf8)
        try incomplete.write(to: fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: fileURL), incomplete)
    }

    func testVersionOneStoreMigratesWithoutLosingProjectRecordsOrIgnoredProjects() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("project-records.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"""
        {
          "schemaVersion": 1,
          "records": [{
            "path": "/Projects/alpha",
            "firstDiscoveredAt": "1970-01-01T00:01:40Z",
            "lastDiscoveredAt": "1970-01-01T00:01:40Z",
            "isNew": false,
            "boundary": "git"
          }],
          "ignoredProjects": [{
            "path": "/Projects/beta",
            "ignoredAt": "1970-01-01T00:03:20Z",
            "boundary": "manifest"
          }]
        }
        """#.utf8).write(to: fileURL)

        let document = try ProjectRecordStore(fileURL: fileURL).load()

        XCTAssertEqual(document.schemaVersion, ProjectRecordDocument.currentSchemaVersion)
        XCTAssertEqual(document.records.map(\.path), ["/Projects/alpha"])
        XCTAssertEqual(document.ignoredProjects.map(\.path), ["/Projects/beta"])
        XCTAssertTrue(document.runConfigurations.isEmpty)
    }

    @MainActor
    func testPublicRunConfigurationOperationsPersistFilterAndRollBackFailedSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let alpha = directory.appendingPathComponent("alpha")
        let beta = directory.appendingPathComponent("beta")
        let alphaScripts = alpha.appendingPathComponent("scripts")
        for project in [alphaScripts, beta] {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
        let storageDirectory = directory.appendingPathComponent("storage")
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let fileURL = storageDirectory.appendingPathComponent("records.json")
        var document = ProjectRecordDocument()
        document.addDirect([alpha.path, beta.path])
        let store = ProjectRecordStore(fileURL: fileURL)
        try store.save(document)
        let model = ProjectsViewModel(store: store)

        let alphaRun = try XCTUnwrap(model.createRunConfiguration(
            projectID: alpha.path,
            name: "开发服务器",
            command: "npm run dev",
            workingDirectory: "scripts",
            sourceIdentity: "package.json#scripts.dev"
        ))
        let betaRun = try XCTUnwrap(model.createRunConfiguration(
            projectID: beta.path,
            name: "测试",
            command: "swift test",
            workingDirectory: "."
        ))

        XCTAssertEqual(model.runConfigurations(projectID: alpha.path).map(\.id), [alphaRun.id])
        XCTAssertEqual(model.runConfigurations().map(\.id), [alphaRun.id, betaRun.id])
        XCTAssertTrue(model.updateRunConfiguration(
            alphaRun,
            name: "开发",
            command: "npm run start",
            workingDirectory: "scripts"
        ))
        let updated = try XCTUnwrap(model.runConfigurations(projectID: alpha.path).first)
        XCTAssertEqual(updated.id, alphaRun.id)
        XCTAssertEqual(updated.name, "开发")
        XCTAssertEqual(updated.sourceIdentity, "package.json#scripts.dev")

        try FileManager.default.removeItem(at: alpha)
        XCTAssertTrue(model.updateRunConfiguration(
            updated,
            name: "开发（磁盘未挂载）",
            command: "npm run start -- --offline",
            workingDirectory: updated.workingDirectory
        ))
        let unavailableUpdated = try XCTUnwrap(model.runConfigurations(projectID: alpha.path).first)
        XCTAssertTrue(model.deleteRunConfiguration(betaRun))
        XCTAssertEqual(try store.load().runConfigurations, [unavailableUpdated])

        try FileManager.default.createDirectory(at: alphaScripts, withIntermediateDirectories: true)
        let previousConfigurations = model.runConfigurations()
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.removeItem(at: storageDirectory)
        try Data().write(to: storageDirectory)

        XCTAssertNil(model.createRunConfiguration(
            projectID: alpha.path,
            name: "不会保存",
            command: "false",
            workingDirectory: "."
        ))
        XCTAssertEqual(model.runConfigurations(), previousConfigurations)
        XCTAssertNotNil(model.operationError)
    }

    @MainActor
    func testRunConfigurationWorkingDirectoryCannotEscapeProjectRoot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("project")
        let child = project.appendingPathComponent("Sources")
        let outside = directory.appendingPathComponent("outside")
        for item in [child, outside] {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        }
        try Data().write(to: project.appendingPathComponent("README.md"))
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("inside-link"),
            withDestinationURL: child
        )
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("escape-link"),
            withDestinationURL: outside
        )
        var document = ProjectRecordDocument()
        document.addDirect([project.path])
        try ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json")).save(document)
        let loadedModel = ProjectsViewModel(
            store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        )

        let rootRun = try XCTUnwrap(loadedModel.createRunConfiguration(
            projectID: project.path,
            name: "根目录",
            command: "true",
            workingDirectory: ""
        ))
        let childRun = try XCTUnwrap(loadedModel.createRunConfiguration(
            projectID: project.path,
            name: "子目录",
            command: "true",
            workingDirectory: "inside-link"
        ))

        XCTAssertEqual(rootRun.workingDirectory, ".")
        XCTAssertEqual(childRun.workingDirectory, "Sources")
        try FileManager.default.removeItem(at: project.appendingPathComponent("inside-link"))
        try FileManager.default.removeItem(at: child)
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
        XCTAssertFalse(loadedModel.updateRunConfiguration(
            childRun,
            name: "不能保留逃逸目录",
            command: "true",
            workingDirectory: childRun.workingDirectory
        ))
        for invalidPath in [
            outside.path,
            "../outside",
            "Sources/../Sources",
            "missing",
            "README.md",
            "escape-link",
        ] {
            XCTAssertNil(loadedModel.createRunConfiguration(
                projectID: project.path,
                name: invalidPath,
                command: "true",
                workingDirectory: invalidPath
            ))
        }
        XCTAssertEqual(loadedModel.runConfigurations().count, 2)
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

    func testExplicitBoundaryStillDetectsGitRepositoryAndCurrentBranch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try Data("ref: refs/heads/feature/current\n".utf8)
            .write(to: root.appendingPathComponent(".git/HEAD"))
        var document = ProjectRecordDocument()
        document.addDirect([root.path])
        let project = try XCTUnwrap(document.records.first)

        XCTAssertEqual(project.boundary, .explicit)
        XCTAssertTrue(ProjectDiscovery().isGitRepository(project.path))
        XCTAssertEqual(ProjectDiscovery().currentGitBranch(project.path), "feature/current")
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

    @MainActor
    func testFailedBatchRemovalSaveRollsBackDocument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("records.json")
        let store = ProjectRecordStore(fileURL: fileURL)
        var document = ProjectRecordDocument()
        document.mergeDiscovered(["/Projects/alpha", "/Projects/beta"])
        document.remove(projectID: "/Projects/beta")
        try store.save(document)
        let model = ProjectsViewModel(store: store)
        let previousDocument = model.document
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)

        let result = model.remove(projectIDs: ["/Projects/alpha", "/Projects/beta"])

        XCTAssertNil(result)
        XCTAssertEqual(model.document, previousDocument)
        XCTAssertNotNil(model.operationError)
    }

    @MainActor
    func testProjectSearchMatchesTitleAndPathWithoutChangingListOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let alpha = directory.appendingPathComponent("Alpha")
        let beta = directory.appendingPathComponent("nested/beta")
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        let store = ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        var document = ProjectRecordDocument()
        document.addDirect([beta.path, alpha.path])
        document.clearNew(displayedProjectIDs: Set(document.records.map(\.id)))
        try store.save(document)
        let model = ProjectsViewModel(store: store)

        model.enterProjects()
        for _ in 0 ..< 100 where model.isRefreshingProjects {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.records(matching: "ALP").map(\.title), ["Alpha"])
        XCTAssertEqual(model.records(matching: "nested").map(\.title), ["beta"])
        XCTAssertEqual(model.records(matching: "").map(\.title), ["Alpha", "beta"])
    }

    @MainActor
    func testUnavailableRefreshKeepsLastAnalysisAndMarksItStale() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{\"engines\":{\"node\":\">=22\"}}".utf8)
            .write(to: project.appendingPathComponent("package.json"))
        let model = ProjectsViewModel(
            store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        )
        model.addDirect([project])
        for _ in 0 ..< 100 where model.isRefreshingProjects {
            try await Task.sleep(for: .milliseconds(10))
        }
        let previous = try XCTUnwrap(model.analyses[project.path])

        try FileManager.default.removeItem(at: project)
        model.refreshProjects()
        for _ in 0 ..< 100 where model.isRefreshingProjects {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.analyses[project.path], previous)
        XCTAssertTrue(model.staleProjectIDs.contains(project.path))
        XCTAssertEqual(model.summary(for: try XCTUnwrap(model.records.first)), .unavailable)
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testRemovingRecordWhileItRefreshesCannotRestoreTransientAnalysis() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{\"engines\":{\"node\":\"22\"}}".utf8)
            .write(to: project.appendingPathComponent("package.json"))
        let model = ProjectsViewModel(
            store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        )

        model.addDirect([project])
        model.remove(try XCTUnwrap(model.records.first))
        for _ in 0 ..< 100 where model.isRefreshingProjects {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNil(model.analyses[project.path])
        XCTAssertTrue(model.records.isEmpty)
    }

    @MainActor
    func testFailedManifestRefreshKeepsLastSuccessfulAnalysisAndPublishesNotice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let manifest = project.appendingPathComponent("package.json")
        try Data("{\"engines\":{\"node\":\"22\"}}".utf8).write(to: manifest)
        let model = ProjectsViewModel(
            store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        )
        model.addDirect([project])
        for _ in 0 ..< 100 where model.isRefreshingProjects {
            try await Task.sleep(for: .milliseconds(10))
        }
        let previous = try XCTUnwrap(model.analyses[project.path])

        try Data("{".utf8).write(to: manifest)
        model.refreshProjects()
        for _ in 0 ..< 100 where model.isRefreshingProjects {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.analyses[project.path], previous)
        XCTAssertTrue(model.staleProjectIDs.contains(project.path))
        XCTAssertEqual(model.projectNotices[project.path]?.first?.message, "package.json 格式无效")
    }
}
