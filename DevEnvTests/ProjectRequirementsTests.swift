import Foundation
import XCTest
@testable import DevEnv

final class ProjectRequirementsTests: XCTestCase {
    func testScansComponentsAndUsesComponentVenvAsPythonEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = root.appendingPathComponent("services/api")
        let python = api.appendingPathComponent(".venv/bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {"name":"web","engines":{"node":">=20 <23"},"packageManager":"pnpm@9.0.0","os":["darwin"],"cpu":["arm64"]}
        """.utf8).write(to: root.appendingPathComponent("package.json"))
        try Data("""
        [project]
        requires-python = ">=3.11,<3.12"

        [project.dependencies]
        ignored = "99"
        """.utf8).write(to: api.appendingPathComponent("pyproject.toml"))
        try Data("version = 3.11.9\n".utf8).write(to: api.appendingPathComponent(".venv/pyvenv.cfg"))
        try Data().write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let analysis = ProjectRequirementsScanner().scan(projectRoot: root, machineSnapshot: snapshot(python: []))

        XCTAssertEqual(analysis.components.map(\.relativePath), [".", "services/api"])
        XCTAssertEqual(analysis.components[0].title, ".")
        XCTAssertEqual(analysis.components[0].manifestName, "web")
        XCTAssertEqual(analysis.components[0].requirements.first { $0.capability == "node" }?.satisfaction, .satisfied)
        XCTAssertEqual(analysis.components[1].summary, .satisfied)
        XCTAssertEqual(analysis.components[1].requirements.map(\.field), ["project.requires-python"])
        let localMatch = try XCTUnwrap(analysis.components[1].requirements.first?.matches.first)
        XCTAssertEqual(localMatch.path, python.path)
        XCTAssertEqual(localMatch.source, "Virtual Environment")
        XCTAssertFalse(localMatch.isEffective)
    }

    func testConflictingPythonDeclarationsAndBrokenManifestAreIsolated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("3.11\n".utf8).write(to: root.appendingPathComponent(".python-version"))
        try Data("[project]\nrequires-python = \">=3.12\"\n".utf8).write(to: root.appendingPathComponent("pyproject.toml"))
        try Data("{".utf8).write(to: broken.appendingPathComponent("package.json"))

        let analysis = ProjectRequirementsScanner().scan(projectRoot: root, machineSnapshot: snapshot())

        XCTAssertEqual(analysis.components.first { $0.relativePath == "." }?.summary, .declarationConflict)
        XCTAssertEqual(analysis.summary, .declarationConflict)
        XCTAssertEqual(analysis.notices.first?.relativePath, "broken/package.json")
        XCTAssertTrue(analysis.components[0].requirements[0].evidence.contains { $0.contains(".python-version") })
    }

    func testMachineSnapshotAbsenceUnknownVersionsAndUnusableKnownVersionsUseDistinctStates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"engines\":{\"node\":\">=20\"}}".utf8).write(to: root.appendingPathComponent("package.json"))

        XCTAssertEqual(ProjectRequirementsScanner().scan(projectRoot: root).summary, .undetermined)

        let unknown = runtimeInstallation(path: "/broken/node", version: nil, state: .failed)
        let unknownAnalysis = ProjectRequirementsScanner().scan(
            projectRoot: root,
            machineSnapshot: snapshot(node: [unknown])
        )
        XCTAssertEqual(unknownAnalysis.summary, .undetermined)
        XCTAssertTrue(unknownAnalysis.components[0].requirements[0].evidence.contains { $0.contains("/broken/node") })

        let unusable = runtimeInstallation(path: "/missing/node", version: "22.0.0", state: .unavailable)
        let unusableAnalysis = ProjectRequirementsScanner().scan(
            projectRoot: root,
            machineSnapshot: snapshot(node: [unusable])
        )
        XCTAssertEqual(unusableAnalysis.summary, .unsatisfied)
        XCTAssertTrue(unusableAnalysis.components[0].requirements[0].evidence.contains { $0.contains("/missing/node") })
    }

    func testAlternativeLinesMultipleInstallationsAndEffectiveRuntimeDoNotLeakAcrossComponents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("18\n22\n".utf8).write(to: root.appendingPathComponent(".nvmrc"))
        try Data("{\"engines\":{\"node\":\"18.x\"}}".utf8).write(to: old.appendingPathComponent("package.json"))
        let effective = runtimeInstallation(path: "/effective/node", version: "20.0.0", isEffective: true)
        let node18 = runtimeInstallation(path: "/node18/node", version: "18.19.0")
        let node22 = runtimeInstallation(path: "/node22/node", version: "22.1.0")

        let analysis = ProjectRequirementsScanner().scan(
            projectRoot: root,
            machineSnapshot: snapshot(node: [effective, node18, node22])
        )

        XCTAssertEqual(analysis.components.map(\.summary), [.satisfied, .satisfied])
        XCTAssertEqual(analysis.components[0].requirements.first?.matches.map(\.version), ["18.19.0", "22.1.0"])
        XCTAssertEqual(analysis.components[1].requirements.first?.matches.map(\.path), ["/node18/node"])
    }

    func testUnreadableVenvVersionAndOversizedManifestDoNotHideOtherComponents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = root.appendingPathComponent("api")
        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: api.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("[project]\nrequires-python = \">=3.11\"\n".utf8).write(to: api.appendingPathComponent("pyproject.toml"))
        try Data().write(to: api.appendingPathComponent(".venv/pyvenv.cfg"))
        try Data().write(to: api.appendingPathComponent(".venv/bin/python"))
        try Data(repeating: 0x20, count: ProjectRequirementsScanner.maxManifestBytes + 1)
            .write(to: broken.appendingPathComponent("package.json"))

        let analysis = ProjectRequirementsScanner().scan(projectRoot: root, machineSnapshot: snapshot(python: []))

        XCTAssertEqual(analysis.components.first { $0.relativePath == "api" }?.summary, .undetermined)
        XCTAssertEqual(analysis.components.first { $0.relativePath == "broken" }?.summary, .undetermined)
        XCTAssertEqual(analysis.summary, .undetermined)
        XCTAssertEqual(analysis.notices.first?.message, "清单不可读或超过 4 MiB")
    }

    func testReadsGoAndRustRequirementsAndUsesMinimumVersionSemantics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rust = root.appendingPathComponent("rust")
        try FileManager.default.createDirectory(at: rust, withIntermediateDirectories: true)
        try Data("go 1.22\ntoolchain go1.23.1\n".utf8).write(to: root.appendingPathComponent("go.mod"))
        try Data("go 1.21 // minimum\ntoolchain go1.23.1\n".utf8).write(to: root.appendingPathComponent("go.work"))
        try Data("1.23\n".utf8).write(to: root.appendingPathComponent(".go-version"))
        try Data("""
        [package]
        name = "example"
        rust-version = "1.80"
        """.utf8).write(to: rust.appendingPathComponent("Cargo.toml"))
        try Data("""
        [toolchain]
        channel = "1.81.0"
        """.utf8).write(to: rust.appendingPathComponent("rust-toolchain.toml"))
        try Data("1.81.0 # pinned\n".utf8).write(to: rust.appendingPathComponent("rust-toolchain"))

        let analysis = ProjectRequirementsScanner().scan(
            projectRoot: root,
            machineSnapshot: snapshot(go: [runtimeInstallation(path: "/opt/go", version: "1.23.4")],
                                      rust: [runtimeInstallation(path: "/opt/rustc", version: "1.81.0")])
        )

        XCTAssertEqual(analysis.components.map(\.relativePath), [".", "rust"])
        XCTAssertEqual(Set(analysis.components[0].requirements.map(\.relativePath)), [".go-version", "go.mod", "go.work"])
        XCTAssertTrue(analysis.components.flatMap(\.requirements).allSatisfy { $0.satisfaction == .satisfied })
    }

    func testReadsJavaRubyAndLuaStaticRequirementsAndRejectsDynamicGradle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let maven = root.appendingPathComponent("maven")
        let gradle = root.appendingPathComponent("gradle")
        let dynamic = root.appendingPathComponent("dynamic")
        let ruby = root.appendingPathComponent("ruby")
        let jruby = root.appendingPathComponent("jruby")
        let lua = root.appendingPathComponent("lua")
        let parented = root.appendingPathComponent("parented")
        for directory in [maven, gradle, dynamic, ruby, jruby, lua, parented] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("""
        <project><properties><java.version>17</java.version><maven.compiler.release>21</maven.compiler.release><maven.compiler.source>17</maven.compiler.source></properties>
        <build><plugins>
        <plugin><artifactId>maven-compiler-plugin</artifactId><configuration><release>21</release><source>17</source></configuration></plugin>
        <plugin><artifactId>unrelated-plugin</artifactId><configuration><release>99</release></configuration></plugin>
        <plugin><configuration><rules><requireJavaVersion><version>(17,22]</version></requireJavaVersion></rules></configuration></plugin>
        </plugins></build></project>
        """.utf8).write(to: maven.appendingPathComponent("pom.xml"))
        try Data("java { toolchain { languageVersion = JavaLanguageVersion.of(21) } }\nsourceCompatibility JavaVersion.VERSION_17\ntargetCompatibility JavaVersion.VERSION_17\n".utf8)
            .write(to: gradle.appendingPathComponent("build.gradle.kts"))
        try Data("21\n".utf8).write(to: gradle.appendingPathComponent(".java-version"))
        try Data("let note = \"JavaLanguageVersion.of(99)\" // sourceCompatibility = 99\njava { toolchain { languageVersion = JavaLanguageVersion.of(project.property(\"java\")) } }\n".utf8)
            .write(to: dynamic.appendingPathComponent("build.gradle.kts"))
        try Data("ruby \">= 3.2\"\n".utf8).write(to: ruby.appendingPathComponent("Gemfile"))
        try Data("spec.required_ruby_version = \">= 3.1\"\n".utf8).write(to: ruby.appendingPathComponent("example.gemspec"))
        try Data("3.3\n".utf8).write(to: ruby.appendingPathComponent(".ruby-version"))
        try Data("ruby \"3.3\",\n  engine: \"jruby\",\n  engine_version: \"9.4.5.0\"\n".utf8)
            .write(to: jruby.appendingPathComponent("Gemfile"))
        try Data("description = \"lua >= 9\"\ndependencies = {\n  -- \"lua >= 9\",\n  \"lua >= 5.3\"\n}\n".utf8)
            .write(to: lua.appendingPathComponent("example.rockspec"))
        try Data("5.4\n".utf8).write(to: lua.appendingPathComponent(".lua-version"))
        try Data("<project><parent><groupId>example</groupId><artifactId>parent</artifactId><version>1</version></parent><properties><java.version>21</java.version></properties></project>".utf8)
            .write(to: parented.appendingPathComponent("pom.xml"))

        let analysis = ProjectRequirementsScanner().scan(
            projectRoot: root,
            machineSnapshot: snapshot(
                java: [runtimeInstallation(path: "/opt/java", version: "21.0.5")],
                ruby: [runtimeInstallation(path: "/opt/ruby", version: "3.3.4")],
                lua: [runtimeInstallation(path: "/opt/lua", version: "5.4.6")]
            )
        )

        XCTAssertEqual(analysis.components.first { $0.relativePath == "maven" }?.summary, .satisfied)
        XCTAssertEqual(analysis.components.first { $0.relativePath == "gradle" }?.summary, .satisfied)
        XCTAssertEqual(analysis.components.first { $0.relativePath == "gradle" }?.requirements.count, 3)
        XCTAssertEqual(analysis.components.first { $0.relativePath == "dynamic" }?.summary, .undetermined)
        XCTAssertEqual(analysis.components.first { $0.relativePath == "ruby" }?.requirements.count, 3)
        XCTAssertEqual(analysis.components.first { $0.relativePath == "ruby" }?.summary, .satisfied)
        XCTAssertEqual(analysis.components.first { $0.relativePath == "jruby" }?.summary, .undetermined)
        XCTAssertEqual(analysis.components.first { $0.relativePath == "lua" }?.requirements.count, 2)
        XCTAssertEqual(analysis.components.first { $0.relativePath == "lua" }?.summary, .satisfied)
        XCTAssertEqual(analysis.components.first { $0.relativePath == "parented" }?.summary, .undetermined)
    }

    func testReadsUniversalToolFilesGitSystemAndComposeWithoutPromotingVersionOnlyDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mise = root.appendingPathComponent("mise")
        let compose = root.appendingPathComponent("compose")
        let orphan = root.appendingPathComponent("orphan")
        for directory in [mise, compose, orphan] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("""
        {"os":["darwin","!linux"],"cpu":["arm64","!x64"]}
        """.utf8).write(to: root.appendingPathComponent("package.json"))
        try Data("""
        nodejs 22.1.0 20.0.0
        golang 1.23.1
        git 2.49
        unknown-tool 1.2.3
        java temurin-21.0.2
        python pypy3.10-7.3.15
        ruby jruby-9.4.5.0
        """.utf8).write(to: root.appendingPathComponent(".tool-versions"))
        try Data("[package]\nname = \"mise\"\nrust-version = \"1.80\"\n".utf8)
            .write(to: mise.appendingPathComponent("Cargo.toml"))
        try Data("""
        [tools]
        rust = ["1.81", "1.80"]
        ruby = "3.3"
        lua = ["5.4"] # "9.9" is a comment
        terraform = "1.9"
        node = { version = "22" }
        python = ["3.12", env("PYTHON_VERSION")]
        [env]
        JAVA_HOME = "/ignored"
        """.utf8).write(to: mise.appendingPathComponent("mise.toml"))
        try Data("[tools]\nnode = \"99\"\n".utf8).write(to: mise.appendingPathComponent("mise.local.toml"))
        try Data("services:\n  db:\n    image: postgres:17\n".utf8).write(to: compose.appendingPathComponent("compose.yaml"))
        try Data("services: {}\n".utf8).write(to: compose.appendingPathComponent("docker-compose.yml"))
        try Data("21\n".utf8).write(to: orphan.appendingPathComponent(".java-version"))

        let analysis = ProjectRequirementsScanner().scan(
            projectRoot: root,
            machineSnapshot: snapshot(
                go: [runtimeInstallation(path: "/opt/go", version: "1.23.1")],
                rust: [runtimeInstallation(path: "/opt/rust", version: "1.81.2")],
                ruby: [runtimeInstallation(path: "/opt/ruby", version: "3.3.4")],
                lua: [runtimeInstallation(path: "/opt/lua", version: "5.4.6")],
                gitVersion: "2.49.0 (Apple Git-154)"
            )
        )

        XCTAssertFalse(analysis.components.contains { $0.relativePath == "orphan" })
        let rootRequirements = try XCTUnwrap(analysis.components.first { $0.relativePath == "." }).requirements
        XCTAssertEqual(rootRequirements.first { $0.field == ".tool-versions.nodejs" }?.satisfaction, .satisfied)
        XCTAssertEqual(rootRequirements.first { $0.field == ".tool-versions.golang" }?.capability, "go")
        XCTAssertEqual(rootRequirements.first { $0.field == ".tool-versions.git" }?.satisfaction, .satisfied)
        XCTAssertEqual(rootRequirements.first { $0.field == ".tool-versions.unknown-tool" }?.satisfaction, .undetermined)
        XCTAssertEqual(rootRequirements.first { $0.field == ".tool-versions.java" }?.satisfaction, .undetermined)
        XCTAssertEqual(rootRequirements.first { $0.field == ".tool-versions.python" }?.satisfaction, .undetermined)
        XCTAssertEqual(rootRequirements.first { $0.field == ".tool-versions.ruby" }?.satisfaction, .undetermined)
        XCTAssertEqual(rootRequirements.first { $0.capability == "os" }?.satisfaction, .satisfied)
        XCTAssertEqual(rootRequirements.first { $0.capability == "cpu" }?.satisfaction, .satisfied)
        XCTAssertEqual(analysis.components.first { $0.relativePath == "mise" }?.summary, .undetermined)
        let miseRequirements = try XCTUnwrap(analysis.components.first { $0.relativePath == "mise" }).requirements
        XCTAssertEqual(miseRequirements.first { $0.capability == "lua" }?.expression, "5.4")
        XCTAssertFalse(miseRequirements.contains { $0.capability == "node" || $0.capability == "python" })
        XCTAssertEqual(analysis.components.first { $0.relativePath == "compose" }?.requirements.first?.capability, "docker-compose")
        XCTAssertEqual(analysis.components.first { $0.relativePath == "compose" }?.requirements.count, 1)
        XCTAssertEqual(analysis.components.first { $0.relativePath == "compose" }?.summary, .undetermined)

        let missingGitRoot = root.appendingPathComponent("missing-git")
        try FileManager.default.createDirectory(at: missingGitRoot, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: missingGitRoot.appendingPathComponent("package.json"))
        try Data("git 2.49\n".utf8).write(to: missingGitRoot.appendingPathComponent(".tool-versions"))
        let missingGit = ProjectRequirementsScanner().scan(projectRoot: missingGitRoot, machineSnapshot: snapshot())
        XCTAssertEqual(missingGit.components[0].requirements.first?.satisfaction, .unsatisfied)
    }

    func testDynamicCodeVariablesAndToolRefsAreUndetermined() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ruby = root.appendingPathComponent("ruby")
        let lua = root.appendingPathComponent("lua")
        let rust = root.appendingPathComponent("rust")
        for directory in [ruby, lua, rust] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("ruby ENV.fetch(\"RUBY_VERSION\")\n".utf8).write(to: ruby.appendingPathComponent("Gemfile"))
        try Data("dependencies = { \"lua \" .. LUA_VERSION }\n".utf8).write(to: lua.appendingPathComponent("example.rockspec"))
        try Data("[package]\nname = \"example\"\nrust-version = workspace_version\n".utf8)
            .write(to: rust.appendingPathComponent("Cargo.toml"))
        try Data("[toolchain]\nchannel = channel_name\n".utf8)
            .write(to: rust.appendingPathComponent("rust-toolchain.toml"))
        try Data("nodejs ref:main\n".utf8).write(to: root.appendingPathComponent(".tool-versions"))

        let analysis = ProjectRequirementsScanner().scan(projectRoot: root, machineSnapshot: snapshot())

        XCTAssertEqual(analysis.components.map(\.summary), [.undetermined, .undetermined, .undetermined, .undetermined])
        XCTAssertEqual(analysis.components.first { $0.relativePath == "rust" }?.requirements.count, 2)
    }

    @MainActor
    func testDirectAddImmediatelyBuildsRequirementsAnalysis() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"engines\":{\"node\":\"22\"}}".utf8).write(to: root.appendingPathComponent("package.json"))
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let model = ProjectsViewModel(store: ProjectRecordStore(fileURL: storeURL))
        model.refreshRequirements(machineSnapshot: snapshot())

        model.addDirect([root])
        for _ in 0 ..< 100 where model.analyses[root.path] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.analyses[root.path]?.summary, .satisfied)
    }

    @MainActor
    func testParentAnalysisExcludesKnownAndIgnoredNestedProjectRoots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("parent")
        let child = parent.appendingPathComponent("packages/child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("{\"engines\":{\"node\":\">=20\"}}".utf8)
            .write(to: parent.appendingPathComponent("package.json"))
        try Data("{\"engines\":{\"node\":\"18\"}}".utf8)
            .write(to: child.appendingPathComponent("package.json"))
        let model = ProjectsViewModel(
            store: ProjectRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        )

        model.addDirect([parent, child])
        for _ in 0 ..< 100 where model.isRefreshingProjects {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.analyses[parent.path]?.components.map(\.relativePath), ["."])
        XCTAssertEqual(model.analyses[child.path]?.components.map(\.relativePath), ["."])

        model.remove(try XCTUnwrap(model.records.first { $0.path == child.path }))
        model.refreshProjects()
        for _ in 0 ..< 100 where model.isRefreshingProjects {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.analyses[parent.path]?.components.map(\.relativePath), ["."])
    }

    func testMachineSnapshotRecalculationDoesNotRereadProjectFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent("package.json")
        try Data("{\"engines\":{\"node\":\"22\"}}".utf8).write(to: manifest)
        let scanner = ProjectRequirementsScanner()
        let initial = scanner.scan(projectRoot: root, machineSnapshot: snapshot(node: []))

        try FileManager.default.removeItem(at: manifest)
        let recalculated = scanner.recalculate(initial, machineSnapshot: snapshot())

        XCTAssertEqual(recalculated.components.first?.requirements.first?.expression, "22")
        XCTAssertEqual(recalculated.summary, .satisfied)
        XCTAssertEqual(scanner.scan(projectRoot: root, machineSnapshot: snapshot()).summary, .undeclared)
    }

    private func runtimeInstallation(
        path: String,
        version: String?,
        state: RuntimeState = .discovered,
        isEffective: Bool = false
    ) -> RuntimeInstallation {
        RuntimeInstallation(
            id: path, executable: path, actualExecutable: nil, version: version,
            state: state, error: state == .discovered ? nil : "unavailable",
            isEffective: isEffective, isInPath: isEffective, sources: [.path]
        )
    }

    private func snapshot(
        node: [RuntimeInstallation]? = nil,
        python: [RuntimeInstallation]? = nil,
        go: [RuntimeInstallation] = [],
        java: [RuntimeInstallation] = [],
        rust: [RuntimeInstallation] = [],
        ruby: [RuntimeInstallation] = [],
        lua: [RuntimeInstallation] = [],
        gitVersion: String? = nil
    ) -> MachineSnapshot {
        MachineSnapshot(
            schemaVersion: MachineSnapshot.currentSchemaVersion,
            scannedAt: Date(),
            system: SystemSnapshot(
                macOSVersion: "15.0", build: nil, architecture: "arm64", hostName: "test",
                memoryBytes: nil, diskTotalBytes: nil, diskFreeBytes: nil
            ),
            localServices: [],
            path: [],
            runtimes: [
                RuntimeSnapshot(id: "node", name: "Node.js", installations: [
                    runtimeInstallation(path: "/opt/node", version: "22.1.0"),
                ]),
                RuntimeSnapshot(id: "python", name: "Python", installations: [
                    runtimeInstallation(path: "/opt/python", version: "3.12.1"),
                ]),
                RuntimeSnapshot(id: "go", name: "Go", installations: go),
                RuntimeSnapshot(id: "java", name: "Java", installations: java),
                RuntimeSnapshot(id: "rust", name: "Rust", installations: rust),
                RuntimeSnapshot(id: "ruby", name: "Ruby", installations: ruby),
                RuntimeSnapshot(id: "lua", name: "Lua", installations: lua),
            ].map { runtime in
                if runtime.id == "node", let node { return RuntimeSnapshot(id: runtime.id, name: runtime.name, installations: node) }
                if runtime.id == "python", let python { return RuntimeSnapshot(id: runtime.id, name: runtime.name, installations: python) }
                return runtime
            },
            databaseInstallationOverviews: [],
            homebrew: HomebrewSnapshot(executable: nil, version: nil, available: false, error: nil),
            terminalApplications: [],
            shellInstallations: [],
            gitCLI: GitCLISnapshot(
                executable: gitVersion == nil ? nil : "/usr/bin/git",
                version: gitVersion,
                state: gitVersion == nil ? .unavailable : .available
            ),
            gitLFS: nil,
            userGitConfiguration: nil,
            gitSigningConfiguration: nil,
            gitCredentialHelpers: nil,
            githubAuthenticationConfiguration: GitHubAuthenticationConfigurationSnapshot(
                cliState: .unavailable, gitProtocol: nil, localConfigurationExists: false,
                ghTokenExists: false, githubTokenExists: false
            ),
            issues: []
        )
    }
}
