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
        XCTAssertEqual(analysis.components[1].requirements.first?.matches.first?.path, python.path)
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
    }

    func testMachineSnapshotAbsenceUnknownVersionsAndUnusableKnownVersionsUseDistinctStates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"engines\":{\"node\":\">=20\"}}".utf8).write(to: root.appendingPathComponent("package.json"))

        XCTAssertEqual(ProjectRequirementsScanner().scan(projectRoot: root).summary, .undetermined)

        let unknown = runtimeInstallation(path: "/broken/node", version: nil, state: .failed)
        XCTAssertEqual(
            ProjectRequirementsScanner().scan(projectRoot: root, machineSnapshot: snapshot(node: [unknown])).summary,
            .undetermined
        )

        let unusable = runtimeInstallation(path: "/missing/node", version: "22.0.0", state: .unavailable)
        XCTAssertEqual(
            ProjectRequirementsScanner().scan(projectRoot: root, machineSnapshot: snapshot(node: [unusable])).summary,
            .unsatisfied
        )
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
        XCTAssertEqual(analysis.components.first { $0.relativePath == "broken" }?.summary, .unavailable)
        XCTAssertEqual(analysis.summary, .undetermined)
        XCTAssertEqual(analysis.notices.first?.message, "清单不可读或超过 4 MiB")
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
        python: [RuntimeInstallation]? = nil
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
            ].map { runtime in
                if runtime.id == "node", let node { return RuntimeSnapshot(id: runtime.id, name: runtime.name, installations: node) }
                if runtime.id == "python", let python { return RuntimeSnapshot(id: runtime.id, name: runtime.name, installations: python) }
                return runtime
            },
            databaseInstallationOverviews: [],
            homebrew: HomebrewSnapshot(executable: nil, version: nil, available: false, error: nil),
            terminalApplications: [],
            shellInstallations: [],
            gitCLI: GitCLISnapshot(executable: nil, version: nil, state: .unavailable),
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
