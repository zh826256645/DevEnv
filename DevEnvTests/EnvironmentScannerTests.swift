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

    func testHomebrewDiscoversAllRuntimeTypesAndMergesPathDuplicate() {
        let executables = Set([
            "/custom/bin/brew",
            "/custom/bin/node",
            "/opt/homebrew/Cellar/python@3.13/3.13.4/bin/python3",
            "/opt/homebrew/Cellar/go/1.23.1/bin/go",
            "/opt/homebrew/Cellar/openjdk/23.0.1/bin/java",
            "/opt/homebrew/Cellar/rust/1.80.0/bin/rustc",
            "/opt/homebrew/Cellar/ruby/3.3.4/bin/ruby",
            "/opt/homebrew/Cellar/lua/5.4.6/bin/lua",
        ])
        let outputs = [
            "/custom/bin/brew --version": "Homebrew 4.5.0\n",
            "/custom/bin/brew list --formula --versions": "node 22.3.0\npython@3.13 3.13.4\ngo 1.23.1\nopenjdk 23.0.1\nrust 1.80.0\nruby 3.3.4\nlua 5.4.6\n",
            "/custom/bin/brew --cellar": "/opt/homebrew/Cellar\n",
            "/custom/bin/node --version": "v22.3.0\n",
        ]
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/custom/bin"],
            executables: executables,
            resolvedPaths: ["/custom/bin/node": "/opt/homebrew/Cellar/node/22.3.0/bin/node"],
            commandOutputs: outputs
        )).scan().snapshot

        XCTAssertEqual(snapshot.homebrew.executable, "/custom/bin/brew")
        XCTAssertTrue(snapshot.homebrew.available)
        XCTAssertEqual(snapshot.homebrew.version, "4.5.0")
        XCTAssertEqual(snapshot.runtimes.flatMap { $0.installations }.count, 7)
        XCTAssertEqual(snapshot.runtimes.first { $0.id == "node" }?.installations.count, 1)
        XCTAssertEqual(snapshot.runtimes.first { $0.id == "node" }?.installations.first?.version, "22.3.0")
        XCTAssertTrue(snapshot.runtimes.allSatisfy { $0.installations.count == 1 })
    }

    func testHomebrewOnlyInstallationsSortByVersionAndMissingExecutableStaysVisible() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: [
                "/opt/homebrew/bin/brew",
                "/opt/homebrew/Cellar/node/18.20.4/bin/node",
                "/opt/homebrew/Cellar/node@20/20.15.1/bin/node",
            ],
            commandOutputs: [
                "/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n",
                "/opt/homebrew/bin/brew list --formula --versions": "node 18.20.4\nnode@20 20.15.1\nruby 3.3.4\n",
                "/opt/homebrew/bin/brew --cellar": "/opt/homebrew/Cellar\n",
            ]
        )).scan().snapshot

        let node = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "node" })
        XCTAssertEqual(node.installations.map(\.version), ["20.15.1", "18.20.4"])
        XCTAssertEqual(node.installations.map(\.executable), [
            "/opt/homebrew/Cellar/node@20/20.15.1/bin/node",
            "/opt/homebrew/Cellar/node/18.20.4/bin/node",
        ])
        XCTAssertFalse(node.hasPathVersionConflict)
        let ruby = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "ruby" })
        XCTAssertEqual(ruby.installations.first?.version, "3.3.4")
        XCTAssertEqual(ruby.installations.first?.state, .failed)
        XCTAssertEqual(ruby.installations.first?.error, "可执行文件不可用")
        XCTAssertTrue(snapshot.issues.contains("Ruby：可执行文件不可用（/opt/homebrew/Cellar/ruby/3.3.4/bin/ruby）"))
    }

    func testHomebrewProviderFailureKeepsAvailabilityAndPathResults() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin", "/opt/homebrew/bin"],
            executables: ["/opt/homebrew/bin/brew", "/bin/node"],
            commandOutputs: [
                "/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n",
                "/bin/node --version": "v22.0.0\n",
            ],
            commandTimeouts: ["/opt/homebrew/bin/brew list --formula --versions"]
        )).scan().snapshot

        XCTAssertTrue(snapshot.homebrew.available)
        XCTAssertEqual(snapshot.runtimes.first { $0.id == "node" }?.installations.first?.version, "22.0.0")
        XCTAssertTrue(snapshot.issues.contains("Homebrew Runtime Provider：命令超时"))
    }

    func testMiseDiscoversAllRuntimeTypesFromStandardLocationAndDeduplicatesSources() {
        let miseRoot = "/custom/mise/installs"
        let miseExecutables = [
            "\(miseRoot)/node/22.3.0/bin/node",
            "\(miseRoot)/python/3.13.4/bin/python3",
            "\(miseRoot)/go/1.23.1/bin/go",
            "\(miseRoot)/java/23.0.1/bin/java",
            "\(miseRoot)/rust/1.80.0/bin/rustc",
            "\(miseRoot)/ruby/3.3.4/bin/ruby",
            "\(miseRoot)/lua/5.4.6/bin/lua",
        ]
        let homebrewNode = "/opt/homebrew/Cellar/node/22.3.0/bin/node"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/custom/bin"],
            environment: ["HOME": "/Users/test", "MISE_DATA_DIR": "/custom/mise"],
            executables: Set(miseExecutables + [
                "/Users/test/.local/bin/mise",
                "/opt/homebrew/bin/brew",
                "/custom/bin/node",
                homebrewNode,
            ]),
            resolvedPaths: [
                "/custom/bin/node": "/real/node",
                homebrewNode: "/real/node",
                "\(miseRoot)/node/22.3.0/bin/node": "/real/node",
            ],
            commandOutputs: [
                "/custom/bin/node --version": "v22.3.0\n",
                "/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n",
                "/opt/homebrew/bin/brew list --formula --versions": "node 22.3.0\n",
                "/opt/homebrew/bin/brew --cellar": "/opt/homebrew/Cellar\n",
                "/Users/test/.local/bin/mise ls --installed --json": """
                {
                  "node": [{"version":"22.3.0","install_path":"/custom/mise/installs/node/22.3.0"}],
                  "python": [{"version":"3.13.4","install_path":"/custom/mise/installs/python/3.13.4"}],
                  "go": [{"version":"1.23.1","install_path":"/custom/mise/installs/go/1.23.1"}],
                  "java": [{"version":"23.0.1","install_path":"/custom/mise/installs/java/23.0.1"}],
                  "rust": [{"version":"1.80.0","install_path":"/custom/mise/installs/rust/1.80.0"}],
                  "ruby": [{"version":"3.3.4","install_path":"/custom/mise/installs/ruby/3.3.4"}],
                  "lua": [{"version":"5.4.6","install_path":"/custom/mise/installs/lua/5.4.6"}]
                }
                """,
            ]
        )).scan().snapshot

        XCTAssertEqual(snapshot.runtimes.flatMap(\.installations).count, 7)
        XCTAssertTrue(snapshot.runtimes.allSatisfy { $0.installations.count == 1 })
        XCTAssertTrue(snapshot.runtimes.allSatisfy { $0.installations.first?.state == .discovered })
        XCTAssertEqual(snapshot.runtimes.first { $0.id == "node" }?.installations.first?.executable, "/custom/bin/node")
        XCTAssertEqual(snapshot.runtimes.first { $0.id == "python" }?.installations.first?.executable,
                       "/custom/mise/installs/python/3.13.4/bin/python3")
        XCTAssertTrue(snapshot.runtimes.filter { $0.id != "node" }.allSatisfy {
            $0.installations.first?.isInPath == false
        })
    }

    func testMiseFailureKeepsPathResults() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin", "/custom/bin"],
            executables: ["/custom/bin/mise", "/bin/node"],
            commandOutputs: ["/bin/node --version": "v22.0.0\n"],
            commandTimeouts: ["/custom/bin/mise ls --installed --json"]
        )).scan().snapshot

        XCTAssertEqual(snapshot.runtimes.first { $0.id == "node" }?.installations.first?.version, "22.0.0")
        XCTAssertTrue(snapshot.issues.contains("mise Runtime Provider：命令超时"))
    }

    func testUVAndPyenvDiscoverPythonInstallationsAndMergeDuplicate() {
        let uvPython = "/Users/test/.local/share/uv/python/cpython-3.13.2/bin/python3"
        let pyenvPython = "/custom/pyenv/versions/3.11.9/bin/python3"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/custom/bin"],
            environment: ["HOME": "/Users/test", "PYENV_ROOT": "/custom/pyenv"],
            executables: [
                "/custom/bin/python3", "/custom/bin/uv", "/custom/bin/pyenv",
                uvPython, pyenvPython, "/custom/pyenv/versions/3.13.2/bin/python3",
            ],
            resolvedPaths: [
                "/custom/bin/python3": uvPython,
                "/custom/pyenv/versions/3.13.2/bin/python3": uvPython,
            ],
            commandOutputs: [
                "/custom/bin/python3 --version": "Python 3.13.2\n",
                "/custom/bin/uv python list --only-installed --output-format json": """
                [{"version":"3.12.1","path":"/Users/test/.local/share/uv/python/cpython-3.12.1/bin/python3"},{"version":"3.13.2","path":"\(uvPython)"}]
                """,
                "/custom/bin/pyenv versions --bare": "3.11.9\n3.13.2\n",
            ]
        )).scan().snapshot

        let python = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "python" })
        XCTAssertEqual(python.installations.map(\.version), ["3.13.2", "3.12.1", "3.11.9"])
        XCTAssertEqual(python.installations.map(\.executable), [
            "/custom/bin/python3",
            "/Users/test/.local/share/uv/python/cpython-3.12.1/bin/python3",
            pyenvPython,
        ])
        XCTAssertEqual(python.installations.map(\.isInPath), [true, false, false])
        XCTAssertFalse(python.hasPathVersionConflict)
    }

    func testPythonProviderFailuresAreIsolatedFromPathResults() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin", "/custom/bin"],
            environment: ["HOME": "/Users/test", "PYENV_ROOT": "/custom/pyenv"],
            executables: ["/bin/python3", "/custom/bin/uv", "/custom/bin/pyenv"],
            commandOutputs: ["/bin/python3 --version": "Python 3.12.0\n"],
            commandStatuses: ["/custom/bin/pyenv versions --bare": 1],
            commandTimeouts: ["/custom/bin/uv python list --only-installed --output-format json"]
        )).scan().snapshot

        XCTAssertEqual(snapshot.runtimes.first { $0.id == "python" }?.installations.first?.version, "3.12.0")
        XCTAssertTrue(snapshot.issues.contains("uv Python Runtime Provider：命令超时"))
        XCTAssertTrue(snapshot.issues.contains("pyenv Python Runtime Provider：读取失败"))
    }

    func testPythonProvidersRetainUnavailableInstallationsAndSortStable() {
        let uvPython = "/Users/test/.local/share/uv/python/cpython-3.13.2/bin/python3"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test"],
            executables: ["/Users/test/.local/bin/uv", "/Users/test/.pyenv/bin/pyenv"],
            commandOutputs: [
                "/Users/test/.local/bin/uv python list --only-installed --output-format json": "[{\"version\":\"3.13.2\",\"path\":\"\(uvPython)\"}]",
                "/Users/test/.pyenv/bin/pyenv versions --bare": "3.10.1\n3.11.9\n",
            ]
        )).scan().snapshot

        let python = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "python" })
        XCTAssertEqual(python.installations.map(\.version), ["3.13.2", "3.11.9", "3.10.1"])
        XCTAssertTrue(python.installations.allSatisfy { $0.state == .failed && $0.error == "可执行文件不可用" })
        XCTAssertTrue(snapshot.issues.contains("Python：可执行文件不可用（\(uvPython)）"))
        XCTAssertTrue(snapshot.issues.contains("Python：可执行文件不可用（/Users/test/.pyenv/versions/3.11.9/bin/python3）"))
    }

    func testJavaHomeDiscoversRegisteredJDKsAndMergesDuplicates() {
        let jdk17 = "/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home"
        let jdk21 = "/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home"
        let miseJDK = "/Users/test/.local/share/mise/installs/java/21.0.2"
        let brewJDK = "/opt/homebrew/Cellar/openjdk/21.0.2"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/custom/bin"],
            environment: ["HOME": "/Users/test"],
            executables: [
                "/custom/bin/java", "/usr/libexec/java_home", "\(jdk17)/bin/java", "\(jdk21)/bin/java", "\(miseJDK)/bin/java",
                "/Users/test/.local/bin/mise", "/opt/homebrew/bin/brew", "\(brewJDK)/bin/java",
            ],
            resolvedPaths: [
                "/custom/bin/java": jdk21 + "/bin/java",
                "\(miseJDK)/bin/java": jdk21 + "/bin/java",
                "\(brewJDK)/bin/java": jdk21 + "/bin/java",
            ],
            commandOutputs: [
                "/custom/bin/java -version": "openjdk version \"21.0.2\"\n",
                "/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n",
                "/opt/homebrew/bin/brew list --formula --versions": "openjdk 21.0.2\n",
                "/opt/homebrew/bin/brew --cellar": "/opt/homebrew/Cellar\n",
                "/usr/libexec/java_home -V": """
                Matching Java Virtual Machines (2):
                    21.0.2 (arm64) \"Oracle Corporation\" - \"Java SE 21.0.2\" \(jdk21)
                    17.0.10 (arm64) \"Eclipse Adoptium\" - \"Eclipse Temurin 17.0.10\" \(jdk17)
                """,
                "/Users/test/.local/bin/mise ls --installed --json": """
                {"java":[{"version":"21.0.2","install_path":"\(miseJDK)"}]}
                """,
            ]
        )).scan().snapshot

        let java = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "java" })
        XCTAssertEqual(java.installations.map(\.version), ["21.0.2", "17.0.10"])
        XCTAssertEqual(java.installations.map(\.executable), [
            "/custom/bin/java",
            "\(jdk17)/bin/java",
        ])
        XCTAssertEqual(java.installations.map(\.isInPath), [true, false])
        XCTAssertFalse(java.hasPathVersionConflict)
    }

    func testJavaHomeRetainsUnavailableRegisteredJDK() {
        let jdk = "/Library/Java/JavaVirtualMachines/missing.jdk/Contents/Home"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/usr/libexec/java_home"],
            commandOutputs: [
                "/usr/libexec/java_home -V": "    17.0.10 (arm64) \"Vendor\" - \"JDK 17\" \(jdk)\n",
            ]
        )).scan().snapshot

        let java = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "java" })
        XCTAssertEqual(java.installations.first?.version, "17.0.10")
        XCTAssertEqual(java.installations.first?.executable, "\(jdk)/bin/java")
        XCTAssertEqual(java.installations.first?.state, .failed)
        XCTAssertEqual(java.installations.first?.error, "可执行文件不可用")
        XCTAssertTrue(snapshot.issues.contains("Java：可执行文件不可用（\(jdk)/bin/java）"))
    }

    func testJavaHomeProviderFailuresAreIsolatedFromPathResults() {
        let timedOut = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/bin/java", "/usr/libexec/java_home"],
            commandOutputs: ["/bin/java -version": "openjdk version \"21.0.2\"\n"],
            commandTimeouts: ["/usr/libexec/java_home -V"]
        )).scan().snapshot
        XCTAssertEqual(timedOut.runtimes.first { $0.id == "java" }?.installations.first?.version, "21.0.2")
        XCTAssertTrue(timedOut.issues.contains("java_home Java Runtime Provider：命令超时"))

        let unparsable = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/bin/java", "/usr/libexec/java_home"],
            commandOutputs: [
                "/bin/java -version": "openjdk version \"21.0.2\"\n",
                "/usr/libexec/java_home -V": "garbage /tmp/jdk\n",
            ]
        )).scan().snapshot
        XCTAssertEqual(unparsable.runtimes.first { $0.id == "java" }?.installations.first?.version, "21.0.2")
        XCTAssertTrue(unparsable.issues.contains("java_home Java Runtime Provider：输出解析失败"))
    }

    func testNVMUsesInheritedRootAndMergesPathDuplicate() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/custom/bin"],
            environment: ["HOME": "/Users/test", "NVM_DIR": "/opt/nvm"],
            executables: [
                "/custom/bin/node",
                "/opt/nvm/versions/node/v22.3.0/bin/node",
                "/opt/nvm/versions/node/v20.15.1/bin/node",
                "/Users/test/.nvm/versions/node/v18.20.4/bin/node",
            ],
            resolvedPaths: [
                "/custom/bin/node": "/opt/nvm/versions/node/v22.3.0/bin/node",
            ],
            commandOutputs: ["/custom/bin/node --version": "v22.3.0\n"],
            directoryContents: [
                "/opt/nvm/versions/node": ["v22.3.0", "v20.15.1", "aliases"],
                "/Users/test/.nvm/versions/node": ["v18.20.4"],
            ]
        )).scan().snapshot

        let node = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "node" })
        XCTAssertEqual(node.installations.map(\.version), ["22.3.0", "20.15.1"])
        XCTAssertEqual(node.installations.map(\.executable), [
            "/custom/bin/node",
            "/opt/nvm/versions/node/v20.15.1/bin/node",
        ])
        XCTAssertEqual(node.installations.map(\.isInPath), [true, false])
        XCTAssertEqual(node.installations.first?.actualExecutable, "/opt/nvm/versions/node/v22.3.0/bin/node")
    }

    func testNVMRetainsUnavailableInstallationWithoutRunningNode() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test"],
            directoryContents: ["/Users/test/.nvm/versions/node": ["v18.20.4"]]
        )).scan().snapshot

        let node = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "node" })
        XCTAssertEqual(node.installations.first?.version, "18.20.4")
        XCTAssertEqual(node.installations.first?.state, .failed)
        XCTAssertEqual(node.installations.first?.error, "可执行文件不可用")
        XCTAssertTrue(snapshot.issues.contains("Node.js：可执行文件不可用（/Users/test/.nvm/versions/node/v18.20.4/bin/node）"))
    }

    func testNVMReadFailureKeepsPathResults() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["NVM_DIR": "/locked/nvm"],
            executables: ["/bin/node"],
            commandOutputs: ["/bin/node --version": "v22.0.0\n"],
            directoryFailures: ["/locked/nvm/versions/node"]
        )).scan().snapshot

        XCTAssertEqual(snapshot.runtimes.first { $0.id == "node" }?.installations.first?.version, "22.0.0")
        XCTAssertTrue(snapshot.issues.contains("nvm Runtime Provider：读取失败（/locked/nvm/versions/node）"))
    }

    func testMissingNVMDirectoryIsNotAProviderFailure() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test"]
        )).scan().snapshot

        XCTAssertFalse(snapshot.issues.contains { $0.hasPrefix("nvm Runtime Provider：") })
    }

    func testNVMDirectoryIgnoresMalformedVersionEntries() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test"],
            executables: ["/Users/test/.nvm/versions/node/v20.15.1/bin/node"],
            directoryContents: [
                "/Users/test/.nvm/versions/node": ["v20.15.1", "v20-cache", "v1.tmp", "aliases"],
            ]
        )).scan().snapshot

        let node = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "node" })
        XCTAssertEqual(node.installations.map(\.version), ["20.15.1"])
        XCTAssertFalse(snapshot.issues.contains { $0.contains("v20-cache") || $0.contains("v1.tmp") })
    }

    func testV2SnapshotRoundTripsAndV1IsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("machine-snapshot.json")
        let store = SnapshotStore(fileURL: fileURL)
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/bin/node"],
            commandOutputs: ["/bin/node": "v22.0.0\n"]
        )).scan().snapshot

        try store.save(snapshot)
        XCTAssertEqual(store.load()?.schemaVersion, 2)

        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var runtimes = try XCTUnwrap(json["runtimes"] as? [[String: Any]])
        for runtimeIndex in runtimes.indices {
            var installations = try XCTUnwrap(runtimes[runtimeIndex]["installations"] as? [[String: Any]])
            for installationIndex in installations.indices {
                installations[installationIndex].removeValue(forKey: "isInPath")
            }
            runtimes[runtimeIndex]["installations"] = installations
        }
        json["runtimes"] = runtimes
        try JSONSerialization.data(withJSONObject: json).write(to: fileURL, options: .atomic)
        XCTAssertTrue(store.load()?.runtimes.flatMap(\.installations).allSatisfy(\.isInPath) == true)

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
    let directoryContents: [String: [String]]
    let directoryFailures: Set<String>

    init(
        path: [String],
        environment: [String: String] = [:],
        executables: Set<String> = [],
        resolvedPaths: [String: String] = [:],
        commandOutputs: [String: String] = [:],
        commandStatuses: [String: Int32] = [:],
        commandTimeouts: Set<String> = [],
        directoryContents: [String: [String]] = [:],
        directoryFailures: Set<String> = []
    ) {
        self.environment = environment.merging(["PATH": path.joined(separator: ":")]) { _, path in path }
        self.executables = executables
        self.resolvedPaths = resolvedPaths
        self.commandOutputs = commandOutputs
        self.commandStatuses = commandStatuses
        self.commandTimeouts = commandTimeouts
        self.directoryContents = directoryContents
        self.directoryFailures = directoryFailures
    }

    func diskSpace() -> DiskSpace { DiskSpace(totalBytes: 1, freeBytes: 1) }

    func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }

    func directoryEntries(atPath path: String) throws -> [String] {
        if directoryFailures.contains(path) { throw CocoaError(.fileReadNoPermission) }
        guard let entries = directoryContents[path] else { throw CocoaError(.fileReadNoSuchFile) }
        return entries
    }

    func resolvingSymlinksInPath(_ path: String) -> String { resolvedPaths[path, default: path] }

    func command(executable: String, arguments: [String]) -> MachineCommandResult {
        let key = ([executable] + arguments).joined(separator: " ")
        switch executable {
        case "/usr/bin/sw_vers":
            return MachineCommandResult(output: arguments == ["-productVersion"] ? "15.0\n" : "24A1\n", status: 0, timedOut: false)
        case "/usr/bin/uname":
            return MachineCommandResult(output: "arm64\n", status: 0, timedOut: false)
        case "/usr/sbin/sysctl":
            return MachineCommandResult(output: "1024\n", status: 0, timedOut: false)
        default:
            return MachineCommandResult(
                output: commandOutputs[key, default: commandOutputs[executable, default: ""]],
                status: commandStatuses[key, default: commandStatuses[executable, default: 0]],
                timedOut: commandTimeouts.contains(key) || commandTimeouts.contains(executable)
            )
        }
    }
}
