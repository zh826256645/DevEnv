import Foundation
import XCTest
@testable import DevEnv

final class OverviewAttentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testSameDirectoryRecordsShareRequirementRiskButKeepRecordNavigation() {
        let first = run(id: "first", projectID: "api-record", projectPath: "/tmp/active", state: .running)
        let second = run(id: "second", projectID: "worker-record", projectPath: "/tmp/active", state: .running)
        let requirements = analysis(requirements: [requirement("node", .unsatisfied)])
        let result = project(runs: [first, second], analyses: ["api-record": requirements, "worker-record": requirements])
        XCTAssertEqual(result.runs.count, 2)
        XCTAssertEqual(result.items.filter { $0.kind == .projectRequirement }.count, 2)
        XCTAssertEqual(result.items.first?.target, .project("api-record", capability: "node"))
        let missing = project(runs: [first, second])
        XCTAssertEqual(missing.items.filter { $0.kind == .projectRequirementsEvidence }.count, 2)
        let available = project(runs: [first, second], analyses: ["worker-record": requirements])
        XCTAssertFalse(available.items.contains { $0.kind == .projectRequirementsEvidence })
        XCTAssertEqual(available.items.first?.target, .project("worker-record", capability: "node"))
    }

    func testRunFailuresAreUniqueAndNormalStopsAreIgnored() {
        let failed = run(id: "failed", state: .exited(1), failure: "退出码 1", failureAt: now.addingTimeInterval(-10))
        let normal = run(id: "normal", state: .exited(0))
        let stopped = run(id: "stopped", state: .stopped(15))
        let result = project(runs: [failed, normal, stopped])

        XCTAssertEqual(result.runs.map(\.id), ["failed"])
        XCTAssertEqual(result.items.map(\.kind), [.runFailure])
        XCTAssertEqual(result.items.first?.id, "run-failure:failed")
    }

    func testRunEvidenceOnlyAppliesToRunningUnknownOwnership() {
        let unknown = run(id: "unknown", state: .running, ownedProcessIDs: nil)
        let starting = run(id: "starting", state: .starting, ownedProcessIDs: nil)
        let owned = run(id: "owned", state: .running, ownedProcessIDs: [42])
        let result = project(runs: [unknown, starting, owned])

        XCTAssertEqual(result.items.filter { $0.kind == .runEvidence }.map(\.id), ["run-evidence:unknown"])
    }

    func testFreshnessThresholdsAreStrictlyGreaterThan60SecondsAnd24Hours() {
        let snapshot = makeSnapshot(scannedAt: now.addingTimeInterval(-24 * 60 * 60))
        let atBoundary = project(snapshot: snapshot, dynamicRefreshedAt: now.addingTimeInterval(-60))
        XCTAssertTrue(atBoundary.items.isEmpty)

        let stale = project(
            snapshot: makeSnapshot(scannedAt: now.addingTimeInterval(-24 * 60 * 60 - 1)),
            dynamicRefreshedAt: now.addingTimeInterval(-61)
        )
        XCTAssertEqual(stale.items.filter { $0.kind == .refresh }.map(\.id), ["dynamic-status-stale", "environment-snapshot-stale"])
    }

    func testProjectRequirementsMissingStaleAndRefreshingSemantics() {
        let active = run(id: "run", projectID: "/tmp/active", state: .running, ownedProcessIDs: [1])
        let missing = project(runs: [active], refreshing: []).items
        XCTAssertEqual(missing.first?.kind, .projectRequirementsEvidence)

        let refreshing = project(runs: [active], refreshing: ["/tmp/active"]).items
        XCTAssertFalse(refreshing.contains { $0.kind == .projectRequirementsEvidence })

        let analysis = analysis(requirements: [])
        let stale = project(runs: [active], analyses: ["/tmp/active": analysis], stale: ["/tmp/active"]).items
        XCTAssertEqual(stale.first?.id, "project-requirements-stale:/tmp/active")

        let staleWhileRefreshing = project(runs: [active], analyses: ["/tmp/active": analysis], stale: ["/tmp/active"], refreshing: ["/tmp/active"]).items
        XCTAssertEqual(staleWhileRefreshing.first?.id, "project-requirements-stale:/tmp/active")
    }

    func testProjectRequirementSatisfactionAndDatabaseListening() {
        let requirements = [
            requirement("node", .unsatisfied),
            requirement("python", .declarationConflict),
            requirement("go", .undetermined),
            requirement("postgresql", .satisfied, matches: [match(listening: .notListening)]),
            requirement("mysql", .satisfied, matches: [match(listening: .unknown)]),
            requirement("redis", .satisfied, matches: [match(listening: .listening), match(listening: .notListening)])
        ]
        let active = run(id: "run", projectID: "/tmp/active", state: .running, ownedProcessIDs: [1])
        let items = project(runs: [active], analyses: ["/tmp/active": analysis(requirements: requirements)]).items

        let severities = Dictionary(uniqueKeysWithValues: items.filter { $0.kind == .projectRequirement }.map { ($0.id, $0.severity) })
        XCTAssertEqual(severities["project-requirement:/tmp/active:node"], .critical)
        XCTAssertEqual(severities["project-requirement:/tmp/active:python"], .critical)
        XCTAssertEqual(severities["project-requirement:/tmp/active:go"], .warning)
        XCTAssertEqual(severities["project-requirement:/tmp/active:postgresql"], .critical)
        XCTAssertEqual(severities["project-requirement:/tmp/active:mysql"], .warning)
        XCTAssertFalse(items.contains { $0.title.contains("redis") })
    }

    func testExposedPortsExcludeLoopbackAndDeduplicateBindings() {
        let binding = ListenerBinding(address: "0.0.0.0", port: 8080, family: .ipv4)
        let runInput = run(id: "run", state: .running, ownedProcessIDs: [42])
        let services = [
            LocalServiceSnapshot(processName: "app", pid: 42, bindings: [
                ListenerBinding(address: "127.0.0.1", port: 3000, family: .ipv4), binding, binding
            ])
        ]
        let result = project(snapshot: makeSnapshot(localServices: services), runs: [runInput])

        let exposure = try! XCTUnwrap(result.items.first { $0.kind == .exposedPort })
        XCTAssertEqual(exposure.detail, "监听地址：0.0.0.0:8080")
    }

    func testLowDiskWarningUses20GBThreshold() {
        let atBoundary = project(snapshot: makeSnapshot(diskFreeBytes: 20 * 1_024 * 1_024 * 1_024))
        XCTAssertFalse(atBoundary.items.contains { $0.kind == .disk })

        let low = project(snapshot: makeSnapshot(diskFreeBytes: 20 * 1_024 * 1_024 * 1_024 - 1))
        XCTAssertEqual(low.items.filter { $0.kind == .disk }.count, 1)
    }

    func testPathConflictIsSuppressedByRequirementRiskAndDeduplicatedPerProject() {
        let runtime = RuntimeSnapshot(id: "node", name: "Node.js", installations: [
            installation(id: "a", version: "18", effective: true),
            installation(id: "b", version: "20", effective: false)
        ])
        let requirement = requirement("node", .satisfied)
        let active = run(id: "run", projectID: "/tmp/active", state: .running, ownedProcessIDs: [1])
        let result = project(
            snapshot: makeSnapshot(runtimes: [runtime]),
            runs: [active],
            analyses: ["/tmp/active": analysis(requirements: [requirement, requirement])]
        )
        XCTAssertEqual(result.items.filter { $0.kind == .pathConflict }.map(\.id), ["path-conflict:/tmp/active:node"])
    }

    func testItemsSortByRiskThenNewestWithinKindAndUntimedLast() {
        let newer = run(id: "new", state: .exited(1), failure: "new", failureAt: now.addingTimeInterval(-1))
        let older = run(id: "old", state: .exited(1), failure: "old", failureAt: now.addingTimeInterval(-10))
        let result = project(runs: [older, newer], scanError: "scan")
        XCTAssertEqual(result.items.map(\.id), ["run-failure:new", "run-failure:old", "environment-scan-failed"])
    }

    private func project(
        snapshot: MachineSnapshot? = nil,
        runs: [OverviewAttentionRunInput] = [],
        analyses: [String: ProjectRequirementsAnalysis] = [:],
        stale: Set<String> = [],
        refreshing: Set<String> = [],
        scanError: String? = nil,
        dynamicRefreshedAt: Date? = nil
    ) -> OverviewAttentionResult {
        OverviewAttention.project(OverviewAttentionInput(
            snapshot: snapshot ?? makeSnapshot(), runs: runs, analyses: analyses,
            staleProjectIDs: stale, refreshingProjectIDs: refreshing,
            scanError: scanError, dynamicRefreshError: nil,
            dynamicStatusRefreshedAt: dynamicRefreshedAt
        ), now: now)
    }

    private func run(
        id: String,
        projectID: String = "/tmp/project",
        projectPath: String? = nil,
        state: ProjectRunSessionState,
        ownedProcessIDs: Set<Int32>? = [],
        failure: String? = nil,
        failureAt: Date? = nil
    ) -> OverviewAttentionRunInput {
        let project = ProjectRecord(id: projectID, path: projectPath ?? projectID, discoveredAt: now)
        return OverviewAttentionRunInput(
            configuration: ProjectRunConfiguration(id: id, projectID: projectID, name: id, command: "run", workingDirectory: projectID),
            project: project, state: state, lastSuccessfulCommand: nil, startedAt: now.addingTimeInterval(-120),
            failureMessage: failure, failureAt: failureAt, ownedProcessIDs: ownedProcessIDs,
            physicalMemoryBytes: nil, repositoryState: .nonGit
        )
    }

    private func analysis(requirements: [ProjectCapabilityRequirement]) -> ProjectRequirementsAnalysis {
        ProjectRequirementsAnalysis(
            rootPath: "/tmp/active",
            components: [ProjectComponent(rootPath: "/tmp/active", relativePath: ".", manifestNames: [], requirements: [], notices: [])],
            requirements: requirements
        )
    }

    private func requirement(_ capability: String, _ satisfaction: ProjectRequirementSatisfactionState, matches: [ProjectRequirementMatch] = []) -> ProjectCapabilityRequirement {
        ProjectCapabilityRequirement(capability: capability, expression: ">= 1", declarations: [], satisfaction: satisfaction, matches: matches, evidence: [])
    }

    private func match(listening: DatabaseListeningState) -> ProjectRequirementMatch {
        ProjectRequirementMatch(version: "1", path: "/opt/db", listeningState: listening)
    }

    private func installation(id: String, version: String, effective: Bool) -> RuntimeInstallation {
        RuntimeInstallation(id: id, executable: "/opt/node", actualExecutable: nil, version: version, state: .discovered, error: nil, isEffective: effective, isInPath: true, sources: [.path])
    }

    private func makeSnapshot(
        scannedAt: Date? = nil,
        localServices: [LocalServiceSnapshot] = [],
        runtimes: [RuntimeSnapshot] = [],
        diskFreeBytes: UInt64? = nil
    ) -> MachineSnapshot {
        MachineSnapshot(
            schemaVersion: MachineSnapshot.currentSchemaVersion,
            scannedAt: scannedAt ?? Date(timeIntervalSince1970: 2_000_000_000),
            system: SystemSnapshot(macOSVersion: "15", build: nil, architecture: "arm64", hostName: "test", memoryBytes: nil, diskTotalBytes: nil, diskFreeBytes: diskFreeBytes),
            localServices: localServices,
            machineToolSearchPath: MachineToolSearchPathSnapshot(entries: [], source: .appProcessFallback),
            runtimes: runtimes,
            databaseInstallationOverviews: [], homebrew: HomebrewSnapshot(executable: nil, version: nil, available: false, error: nil),
            packageManagers: [], terminalApplications: [], shellInstallations: [],
            gitCLI: GitCLISnapshot(executable: nil, version: nil, state: .unavailable), gitLFS: nil,
            userGitConfiguration: nil, gitSigningConfiguration: nil, gitCredentialHelpers: nil,
            githubAuthenticationConfiguration: GitHubAuthenticationConfigurationSnapshot(cliState: .unavailable, gitProtocol: nil, localConfigurationExists: false, ghTokenExists: false, githubTokenExists: false), issues: []
        )
    }
}
