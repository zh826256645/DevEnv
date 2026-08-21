import Foundation
import XCTest
@testable import DevEnv

final class EnvironmentScannerTests: XCTestCase {
    func testDiscoversEveryRuntimeInPathOrder() {
        let names = ["node", "python3", "go", "java", "rustc", "ruby", "lua"]
        let path = ["/first/bin", "/second/bin"]
        let executables = Set(path.flatMap { directory in names.map { "\(directory)/\($0)" } })
        let versions = Dictionary(uniqueKeysWithValues: executables.map { executable in
            (executable, executable.hasPrefix("/first") ? "1.0\n" : "2.0\n")
        })

        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: path,
            executables: executables,
            commandOutputs: versions
        )).scan().snapshot

        XCTAssertEqual(snapshot.schemaVersion, 2)
        XCTAssertEqual(snapshot.runtimes.count, 7)
        for runtime in snapshot.runtimes {
            XCTAssertEqual(runtime.installations.map(\.version), ["1.0", "2.0"])
            XCTAssertEqual(runtime.installations.map(\.isEffective), [true, false])
            XCTAssertTrue(runtime.hasPathVersionConflict)
        }
    }

    func testDeduplicatesSymlinksAndRetainsInvocationAndActualPaths() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/first/bin", "/alias/bin", "/other/bin"],
            executables: ["/first/bin/node", "/alias/bin/node", "/other/bin/node"],
            resolvedPaths: [
                "/first/bin/node": "/runtimes/node-22/bin/node",
                "/alias/bin/node": "/runtimes/node-22/bin/node",
            ],
            commandOutputs: [
                "/first/bin/node": "v22.1.0\n",
                "/other/bin/node": "v20.2.0\n",
            ]
        )).scan().snapshot

        let node = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "node" })
        XCTAssertEqual(node.installations.map(\.executable), ["/first/bin/node", "/other/bin/node"])
        XCTAssertEqual(node.installations.first?.actualExecutable, "/runtimes/node-22/bin/node")
        XCTAssertNil(node.installations.last?.actualExecutable)
    }

    func testFailedFirstMatchStaysEffectiveAndUnknownVersionsDoNotConflict() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/broken/bin", "/one/bin", "/same/bin"],
            executables: ["/broken/bin/python3", "/one/bin/python3", "/same/bin/python3"],
            commandOutputs: [
                "/broken/bin/python3": "error\n",
                "/one/bin/python3": "Python 3.12.1\n",
                "/same/bin/python3": "Python 3.12.1\n",
            ],
            commandStatuses: ["/broken/bin/python3": 1],
            commandTimeouts: ["/broken/bin/python3"]
        )).scan().snapshot

        let python = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "python" })
        XCTAssertTrue(python.installations[0].isEffective)
        XCTAssertEqual(python.installations[0].state, .failed)
        XCTAssertEqual(python.installations[0].error, "版本读取失败")
        XCTAssertFalse(python.hasPathVersionConflict)
        XCTAssertTrue(snapshot.issues.contains("Python：版本读取失败（/broken/bin/python3）"))
    }

    func testRubyAndLuaConflictUsesOnlyTheVersionNumber() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/first/bin", "/second/bin"],
            executables: [
                "/first/bin/ruby", "/second/bin/ruby",
                "/first/bin/lua", "/second/bin/lua",
            ],
            commandOutputs: [
                "/first/bin/ruby": "ruby 3.3.0 (revision one)\n",
                "/second/bin/ruby": "ruby 3.3.0 (revision two)\n",
                "/first/bin/lua": "Lua 5.4.6 Copyright one\n",
                "/second/bin/lua": "Lua 5.4.6 Copyright two\n",
            ]
        )).scan().snapshot

        for id in ["ruby", "lua"] {
            let runtime = try! XCTUnwrap(snapshot.runtimes.first { $0.id == id })
            XCTAssertFalse(runtime.hasPathVersionConflict)
            XCTAssertEqual(Set(runtime.installations.compactMap(\.version)).count, 1)
        }
    }

    func testV2SnapshotRoundTripsAndV1IsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("machine-snapshot.json")
        let store = SnapshotStore(fileURL: fileURL)
        let snapshot = EnvironmentScanner(machine: StubMachine(path: [])).scan().snapshot

        try store.save(snapshot)
        XCTAssertEqual(store.load()?.schemaVersion, 2)

        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        json["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: json).write(to: fileURL, options: .atomic)
        XCTAssertNil(store.load())
    }
}

private struct StubMachine: MachineAccess {
    let environment: [String: String]
    let hostName = "test-host"
    let currentDirectoryPath = "/"
    let executables: Set<String>
    let resolvedPaths: [String: String]
    let commandOutputs: [String: String]
    let commandStatuses: [String: Int32]
    let commandTimeouts: Set<String>

    init(
        path: [String],
        executables: Set<String> = [],
        resolvedPaths: [String: String] = [:],
        commandOutputs: [String: String] = [:],
        commandStatuses: [String: Int32] = [:],
        commandTimeouts: Set<String> = []
    ) {
        environment = ["PATH": path.joined(separator: ":")]
        self.executables = executables
        self.resolvedPaths = resolvedPaths
        self.commandOutputs = commandOutputs
        self.commandStatuses = commandStatuses
        self.commandTimeouts = commandTimeouts
    }

    func diskSpace() -> DiskSpace { DiskSpace(totalBytes: 1, freeBytes: 1) }

    func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }

    func resolvingSymlinksInPath(_ path: String) -> String { resolvedPaths[path, default: path] }

    func command(executable: String, arguments: [String]) -> MachineCommandResult {
        switch executable {
        case "/usr/bin/sw_vers":
            return MachineCommandResult(output: arguments == ["-productVersion"] ? "15.0\n" : "24A1\n", status: 0, timedOut: false)
        case "/usr/bin/uname":
            return MachineCommandResult(output: "arm64\n", status: 0, timedOut: false)
        case "/usr/sbin/sysctl":
            return MachineCommandResult(output: "1024\n", status: 0, timedOut: false)
        default:
            return MachineCommandResult(
                output: commandOutputs[executable, default: ""],
                status: commandStatuses[executable, default: 0],
                timedOut: commandTimeouts.contains(executable)
            )
        }
    }
}
