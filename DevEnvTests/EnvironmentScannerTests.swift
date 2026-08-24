import Foundation
import XCTest
@testable import DevEnv

final class EnvironmentScannerTests: XCTestCase {
    func testGitCLIUsesFirstExecutableInPath() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["tools/../first/bin", "/second/bin"],
            executables: ["/first/bin/git", "/second/bin/git"],
            commandOutputs: [
                "/first/bin/git --version": "git version 2.49.0 (Apple Git-154)\n",
                "/second/bin/git --version": "git version 2.50.0\n",
            ]
        )).scan().snapshot

        XCTAssertEqual(snapshot.gitCLI.state, .available)
        XCTAssertEqual(snapshot.gitCLI.version, "2.49.0 (Apple Git-154)")
        XCTAssertEqual(snapshot.gitCLI.executable, "/first/bin/git")
        XCTAssertFalse(snapshot.issues.contains { $0.hasPrefix("Git CLI：") })
    }

    func testGitCLIMissingIsNeutral() {
        let snapshot = EnvironmentScanner(machine: StubMachine(path: ["/bin"])).scan().snapshot

        XCTAssertEqual(snapshot.gitCLI.state, .unavailable)
        XCTAssertNil(snapshot.gitCLI.version)
        XCTAssertNil(snapshot.gitCLI.executable)
        XCTAssertFalse(snapshot.issues.contains { $0.hasPrefix("Git CLI：") })
    }

    func testGitCLIFailuresProduceOneIsolatedNotice() {
        let cases: [(output: String, status: Int32, timedOut: Bool, notice: String)] = [
            ("fatal\n", 1, false, "Git CLI：版本读取失败"),
            ("not a git version\n", 0, false, "Git CLI：版本读取失败"),
            ("", 0, true, "Git CLI：命令超时"),
        ]

        for testCase in cases {
            let command = "/bin/git --version"
            let result = EnvironmentScanner(machine: StubMachine(
                path: ["/bin", "/opt/homebrew/bin"],
                executables: ["/bin/git", "/bin/node", "/opt/homebrew/bin/brew"],
                commandOutputs: [
                    command: testCase.output,
                    "/bin/node --version": "v22.0.0\n",
                    "/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n",
                ],
                commandStatuses: [command: testCase.status],
                commandTimeouts: testCase.timedOut ? [command] : []
            )).scan()

            XCTAssertEqual(result.snapshot.gitCLI.state, .failed)
            XCTAssertEqual(result.snapshot.gitCLI.executable, "/bin/git")
            XCTAssertNil(result.snapshot.gitCLI.version)
            XCTAssertEqual(result.snapshot.issues.filter { $0.hasPrefix("Git CLI：") }, [testCase.notice])
            XCTAssertEqual(result.snapshot.path, ["/bin", "/opt/homebrew/bin"])
            XCTAssertEqual(result.snapshot.runtimes.first { $0.id == "node" }?.installations.first?.version, "22.0.0")
            XCTAssertTrue(result.snapshot.homebrew.available)
            XCTAssertTrue(result.canPersist)
        }
    }

    func testGitLFSReportsAvailableMissingAndFailedWithoutRepositoryScan() {
        let available = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/bin/git", "/bin/git-lfs"],
            commandOutputs: [
                "/bin/git --version": "git version 2.49.0\n",
                "/bin/git-lfs version": "git-lfs/3.7.0 (GitHub; darwin arm64)\n",
            ]
        )).scan().snapshot
        let missing = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/bin/git"],
            commandOutputs: ["/bin/git --version": "git version 2.49.0\n"]
        )).scan().snapshot
        let failed = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/bin/git", "/bin/git-lfs"],
            commandOutputs: ["/bin/git --version": "git version 2.49.0\n"],
            commandTimeouts: ["/bin/git-lfs version"]
        )).scan().snapshot

        XCTAssertEqual(available.gitLFS?.state, .available)
        XCTAssertEqual(available.gitLFS?.version, "3.7.0")
        XCTAssertEqual(missing.gitLFS?.state, .unavailable)
        XCTAssertFalse(missing.issues.contains { $0.hasPrefix("Git LFS：") })
        XCTAssertEqual(failed.gitLFS?.state, .failed)
        XCTAssertEqual(failed.issues.filter { $0.hasPrefix("Git LFS：") }, ["Git LFS：命令超时"])
    }

    func testGitHubAuthenticationKeepsOnlyLocalSourceFactsWithoutGit() throws {
        let ghToken = "recognizable-gh-token-19"
        let githubToken = "recognizable-github-token-19"
        let localAccount = "recognizable-account-19"
        let localToken = "recognizable-local-token-19"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: [
                "GH_CONFIG_DIR": "/Users/test/custom-gh",
                "GH_TOKEN": ghToken,
                "GITHUB_TOKEN": githubToken,
            ],
            executables: ["/bin/gh"],
            commandOutputs: [
                "/bin/gh config get git_protocol --host github.com": "ssh\n",
            ],
            fileContents: [
                "/Users/test/custom-gh/hosts.yml": "github.com:\n  user: \(localAccount)\n  oauth_token: \(localToken)\n",
            ]
        )).scan().snapshot

        XCTAssertEqual(snapshot.gitCLI.state, .unavailable)
        XCTAssertEqual(snapshot.githubAuthenticationConfiguration.cliState, .available)
        XCTAssertEqual(snapshot.githubAuthenticationConfiguration.gitProtocol, "ssh")
        XCTAssertTrue(snapshot.githubAuthenticationConfiguration.localConfigurationExists)
        XCTAssertTrue(snapshot.githubAuthenticationConfiguration.ghTokenExists)
        XCTAssertTrue(snapshot.githubAuthenticationConfiguration.githubTokenExists)

        let json = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        XCTAssertFalse(json.contains(ghToken))
        XCTAssertFalse(json.contains(githubToken))
        XCTAssertFalse(json.contains(localAccount))
        XCTAssertFalse(json.contains(localToken))
    }

    func testGitHubAuthenticationUsesStandardConfigurationDirectoryPriority() {
        let customDirectoryWins = EnvironmentScanner(machine: StubMachine(
            path: [],
            environment: [
                "GH_CONFIG_DIR": "/custom/gh",
                "XDG_CONFIG_HOME": "/xdg",
                "HOME": "/Users/test",
            ],
            existingFiles: ["/xdg/gh/hosts.yml", "/Users/test/.config/gh/hosts.yml"]
        )).scan().snapshot
        let xdgFallback = EnvironmentScanner(machine: StubMachine(
            path: [],
            environment: ["GH_CONFIG_DIR": "", "XDG_CONFIG_HOME": "/xdg", "HOME": "/Users/test"],
            existingFiles: ["/xdg/gh/hosts.yml"]
        )).scan().snapshot
        let homeFallback = EnvironmentScanner(machine: StubMachine(
            path: [],
            environment: ["HOME": "/Users/test"],
            existingFiles: ["/Users/test/.config/gh/hosts.yml"]
        )).scan().snapshot

        XCTAssertFalse(customDirectoryWins.githubAuthenticationConfiguration.localConfigurationExists)
        XCTAssertTrue(xdgFallback.githubAuthenticationConfiguration.localConfigurationExists)
        XCTAssertTrue(homeFallback.githubAuthenticationConfiguration.localConfigurationExists)
    }

    func testGitHubCLIConfigurationMissingAndFailuresStayIsolated() {
        let command = "/bin/gh config get git_protocol --host github.com"
        let missingCLI = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["GH_TOKEN": "configured"]
        )).scan()
        let missingConfiguration = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/bin/gh"],
            commandOutputs: [command: "https\n"]
        )).scan()
        let failed = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["GH_CONFIG_DIR": "/custom/gh", "GITHUB_TOKEN": "configured"],
            executables: ["/bin/gh"],
            commandOutputs: [command: "ssh\n"],
            commandStatuses: [command: 2],
            existingFiles: ["/custom/gh/hosts.yml"]
        )).scan()
        let timedOut = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["GH_CONFIG_DIR": "/custom/gh"],
            executables: ["/bin/gh"],
            commandOutputs: [command: "https\n"],
            commandTimeouts: [command],
            existingFiles: ["/custom/gh/hosts.yml"]
        )).scan()

        XCTAssertEqual(missingCLI.snapshot.githubAuthenticationConfiguration.cliState, .unavailable)
        XCTAssertTrue(missingCLI.snapshot.githubAuthenticationConfiguration.ghTokenExists)
        XCTAssertFalse(missingCLI.snapshot.issues.contains { $0.hasPrefix("GitHub CLI Configuration：") })
        XCTAssertEqual(missingConfiguration.snapshot.githubAuthenticationConfiguration.cliState, .available)
        XCTAssertNil(missingConfiguration.snapshot.githubAuthenticationConfiguration.gitProtocol)
        XCTAssertEqual(failed.snapshot.githubAuthenticationConfiguration.cliState, .failed)
        XCTAssertNil(failed.snapshot.githubAuthenticationConfiguration.gitProtocol)
        XCTAssertTrue(failed.snapshot.githubAuthenticationConfiguration.githubTokenExists)
        XCTAssertEqual(failed.snapshot.issues.filter { $0.hasPrefix("GitHub CLI Configuration：") }, ["GitHub CLI Configuration：读取失败"])
        XCTAssertEqual(timedOut.snapshot.githubAuthenticationConfiguration.cliState, .failed)
        XCTAssertNil(timedOut.snapshot.githubAuthenticationConfiguration.gitProtocol)
        XCTAssertTrue(timedOut.snapshot.githubAuthenticationConfiguration.localConfigurationExists)
        XCTAssertEqual(timedOut.snapshot.issues.filter { $0.hasPrefix("GitHub CLI Configuration：") }, ["GitHub CLI Configuration：命令超时"])
        XCTAssertTrue(failed.canPersist)
        XCTAssertTrue(timedOut.canPersist)
    }

    func testSigningAndCredentialHelpersKeepOnlyWhitelistedRedactedFacts() throws {
        let sensitive = "recognizable-secret-18"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test"],
            executables: ["/bin/git"],
            commandOutputs: [
                "/bin/git --version": "git version 2.49.0\n",
                "/bin/git config --global --get gpg.format": "ssh\n",
                "/bin/git config --global --get user.signingKey": "test@example.com\n",
                "/bin/git config --global --get commit.gpgSign": "true\n",
                "/bin/git config --global --get tag.gpgSign": "false\n",
                "/bin/git config --global --null --get-all credential.helper":
                    "\0osxkeychain --token \(sensitive)\0store --file=/tmp/\(sensitive)\0!echo \(sensitive)\0\"/opt/helpers/git-credential-company\" --secret \(sensitive)\0",
            ]
        )).scan().snapshot

        XCTAssertEqual(snapshot.gitSigningConfiguration?.format, "ssh")
        XCTAssertEqual(snapshot.gitSigningConfiguration?.signingKey, "test@example.com")
        XCTAssertEqual(snapshot.gitSigningConfiguration?.commitSigning, "true")
        XCTAssertEqual(snapshot.gitSigningConfiguration?.tagSigning, "false")
        XCTAssertEqual(snapshot.gitCredentialHelpers, ["清空 helper chain", "osxkeychain", "store", "自定义命令", "company"])
        XCTAssertFalse(String(data: try JSONEncoder().encode(snapshot), encoding: .utf8)!.contains(sensitive))
    }

    func testSigningAndCredentialHelperFailuresAreIsolated() {
        let helperCommand = "/bin/git config --global --null --get-all credential.helper"
        let signingFailure = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test"],
            executables: ["/bin/git"],
            commandOutputs: [
                "/bin/git --version": "git version 2.49.0\n",
                helperCommand: "osxkeychain\0",
            ],
            commandStatuses: ["/bin/git config --global --get gpg.format": 2]
        )).scan()
        let helperFailure = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test"],
            executables: ["/bin/git"],
            commandOutputs: [
                "/bin/git --version": "git version 2.49.0\n",
                "/bin/git config --global --get gpg.format": "openpgp\n",
            ],
            commandStatuses: [helperCommand: 2]
        )).scan()

        XCTAssertNil(signingFailure.snapshot.gitSigningConfiguration)
        XCTAssertEqual(signingFailure.snapshot.gitCredentialHelpers, ["osxkeychain"])
        XCTAssertNotNil(signingFailure.snapshot.userGitConfiguration)
        XCTAssertEqual(signingFailure.snapshot.issues.filter { $0.hasPrefix("Git Signing Configuration：") }, ["Git Signing Configuration：读取失败"])
        XCTAssertTrue(signingFailure.canPersist)

        XCTAssertEqual(helperFailure.snapshot.gitSigningConfiguration?.format, "openpgp")
        XCTAssertNil(helperFailure.snapshot.gitCredentialHelpers)
        XCTAssertNotNil(helperFailure.snapshot.userGitConfiguration)
        XCTAssertEqual(helperFailure.snapshot.issues.filter { $0.hasPrefix("Git Credential Helpers：") }, ["Git Credential Helpers：读取失败"])
        XCTAssertTrue(helperFailure.canPersist)
    }

    func testUserGitConfigurationUsesExplicitExcludesFile() throws {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test"],
            executables: ["/bin/git"],
            commandOutputs: [
                "/bin/git --version": "git version 2.49.0\n",
                "/bin/git config --global --get user.name": "Test User\n",
                "/bin/git config --global --get user.email": "test@example.com\n",
                "/bin/git config --global --get init.defaultBranch": "main\n",
                "/bin/git config --global --path --get core.excludesFile": "/Users/test/notes/../.gitignore\n",
            ],
            existingFiles: ["/Users/test/.gitignore"]
        )).scan().snapshot

        let configuration = try XCTUnwrap(snapshot.userGitConfiguration)
        XCTAssertEqual(configuration.defaultIdentity.name, "Test User")
        XCTAssertEqual(configuration.defaultIdentity.email, "test@example.com")
        XCTAssertEqual(configuration.defaultBranch, "main")
        XCTAssertEqual(configuration.excludesFile.path, "/Users/test/.gitignore")
        XCTAssertEqual(configuration.excludesFile.source, .explicitConfiguration)
        XCTAssertTrue(configuration.excludesFile.exists)
        XCTAssertFalse(snapshot.issues.contains { $0.hasPrefix("User Git Configuration：") })
    }

    func testUserGitConfigurationUsesNeutralDefaultExcludesFilesWhenConfigurationIsMissing() throws {
        let configCommands = [
            "/bin/git config --global --get user.name",
            "/bin/git config --global --get user.email",
            "/bin/git config --global --get init.defaultBranch",
            "/bin/git config --global --path --get core.excludesFile",
        ]
        let cases: [(environment: [String: String], path: String, exists: Bool)] = [
            (["HOME": "/Users/test", "XDG_CONFIG_HOME": "/Users/test/xdg"], "/Users/test/xdg/git/ignore", true),
            (["HOME": "/Users/test", "XDG_CONFIG_HOME": ""], "/Users/test/.config/git/ignore", false),
        ]

        for testCase in cases {
            let snapshot = EnvironmentScanner(machine: StubMachine(
                path: ["/bin"],
                environment: testCase.environment,
                executables: ["/bin/git"],
                commandOutputs: ["/bin/git --version": "git version 2.49.0\n"],
                commandStatuses: Dictionary(uniqueKeysWithValues: configCommands.map { ($0, 1) }),
                existingFiles: testCase.exists ? [testCase.path] : []
            )).scan().snapshot

            let configuration = try XCTUnwrap(snapshot.userGitConfiguration)
            XCTAssertNil(configuration.defaultIdentity.name)
            XCTAssertNil(configuration.defaultIdentity.email)
            XCTAssertNil(configuration.defaultBranch)
            XCTAssertEqual(configuration.excludesFile.path, testCase.path)
            XCTAssertEqual(configuration.excludesFile.source, .gitDefault)
            XCTAssertEqual(configuration.excludesFile.exists, testCase.exists)
            XCTAssertFalse(snapshot.issues.contains { $0.hasPrefix("User Git Configuration：") })
        }
    }

    func testUserGitConfigurationFailuresProduceOneIsolatedNotice() {
        let cases: [(status: Int32, timedOut: Bool, notice: String)] = [
            (2, false, "User Git Configuration：读取失败"),
            (0, true, "User Git Configuration：命令超时"),
        ]

        for testCase in cases {
            let command = "/bin/git config --global --get user.name"
            let result = EnvironmentScanner(machine: StubMachine(
                path: ["/bin"],
                environment: ["HOME": "/Users/test"],
                executables: ["/bin/git", "/bin/node"],
                commandOutputs: [
                    "/bin/git --version": "git version 2.49.0\n",
                    "/bin/node --version": "v22.0.0\n",
                ],
                commandStatuses: [command: testCase.status],
                commandTimeouts: testCase.timedOut ? [command] : []
            )).scan()

            XCTAssertNil(result.snapshot.userGitConfiguration)
            XCTAssertEqual(result.snapshot.gitCLI.state, .available)
            XCTAssertEqual(result.snapshot.runtimes.first { $0.id == "node" }?.installations.first?.version, "22.0.0")
            XCTAssertEqual(
                result.snapshot.issues.filter { $0.hasPrefix("User Git Configuration：") },
                [testCase.notice]
            )
            XCTAssertTrue(result.canPersist)
        }
    }

    func testUserGitConfigurationIsSkippedWhenGitCLIIsUnavailable() {
        let configCommand = "/bin/git config --global --get user.name"
        let unavailable = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            commandStatuses: [configCommand: 2]
        )).scan().snapshot
        let failed = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/bin/git"],
            commandStatuses: [
                "/bin/git --version": 2,
                configCommand: 2,
            ]
        )).scan().snapshot

        XCTAssertNil(unavailable.userGitConfiguration)
        XCTAssertNil(failed.userGitConfiguration)
        XCTAssertNil(unavailable.gitLFS)
        XCTAssertNil(failed.gitLFS)
        XCTAssertNil(unavailable.gitSigningConfiguration)
        XCTAssertNil(failed.gitSigningConfiguration)
        XCTAssertNil(unavailable.gitCredentialHelpers)
        XCTAssertNil(failed.gitCredentialHelpers)
        XCTAssertFalse(unavailable.issues.contains { $0.hasPrefix("User Git Configuration：") })
        XCTAssertFalse(failed.issues.contains { $0.hasPrefix("User Git Configuration：") })
    }

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

        XCTAssertEqual(snapshot.schemaVersion, 11)
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
        XCTAssertTrue(node.installations.allSatisfy { $0.sources == [.path] })
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
            "/opt/homebrew/Cellar/python@3.13/3.13.4/bin/python3.13",
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
        XCTAssertEqual(snapshot.runtimes.first { $0.id == "node" }?.installations.first?.sources, [.homebrew])
        XCTAssertEqual(
            snapshot.runtimes.first { $0.id == "python" }?.installations.first?.executable,
            "/opt/homebrew/Cellar/python@3.13/3.13.4/bin/python3.13"
        )
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
        XCTAssertEqual(snapshot.runtimes.first { $0.id == "node" }?.installations.first?.sources, [.homebrew, .mise])
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
        XCTAssertEqual(python.installations.map(\.sources), [[.uv, .pyenv], [.uv], [.pyenv]])
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

    func testRustupDiscoversToolchainsAndMergesPathDuplicate() {
        let rustupRoot = "/custom/rustup"
        let stableRustc = "\(rustupRoot)/toolchains/stable-aarch64-apple-darwin/bin/rustc"
        let oldRustc = "\(rustupRoot)/toolchains/1.82.0-aarch64-apple-darwin/bin/rustc"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/custom/bin"],
            environment: ["HOME": "/Users/test", "RUSTUP_HOME": rustupRoot],
            executables: [
                "/custom/bin/rustc", "/custom/bin/rustup", stableRustc, oldRustc,
            ],
            resolvedPaths: ["/custom/bin/rustc": stableRustc],
            commandOutputs: [
                "/custom/bin/rustc --version": "rustc 1.85.0 (abc)\n",
                "/custom/bin/rustup toolchain list": "stable-aarch64-apple-darwin (default)\n1.82.0-aarch64-apple-darwin\n",
            ]
        )).scan().snapshot

        let rust = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "rust" })
        XCTAssertEqual(rust.installations.map(\.version), ["1.85.0", "1.82.0-aarch64-apple-darwin"])
        XCTAssertEqual(rust.installations.map(\.executable), ["/custom/bin/rustc", oldRustc])
        XCTAssertEqual(rust.installations.map(\.isInPath), [true, false])
        XCTAssertTrue(rust.installations.first?.isEffective == true)
        XCTAssertFalse(rust.hasPathVersionConflict)
    }

    func testRustupRetainsUnavailableToolchain() {
        let root = "/Users/test/.rustup"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test"],
            executables: ["/Users/test/.cargo/bin/rustup"],
            commandOutputs: [
                "/Users/test/.cargo/bin/rustup toolchain list": "1.82.0-aarch64-apple-darwin\n",
            ]
        )).scan().snapshot

        let rust = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "rust" })
        XCTAssertEqual(rust.installations.first?.version, "1.82.0-aarch64-apple-darwin")
        XCTAssertEqual(rust.installations.first?.executable, "\(root)/toolchains/1.82.0-aarch64-apple-darwin/bin/rustc")
        XCTAssertEqual(rust.installations.first?.state, .failed)
        XCTAssertTrue(snapshot.issues.contains("Rust：可执行文件不可用（\(root)/toolchains/1.82.0-aarch64-apple-darwin/bin/rustc）"))
    }

    func testRustupFailureKeepsPathResults() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test"],
            executables: ["/bin/rustc", "/bin/rustup"],
            commandOutputs: ["/bin/rustc --version": "rustc 1.85.0 (abc)\n"],
            commandTimeouts: ["/bin/rustup toolchain list"]
        )).scan().snapshot

        XCTAssertEqual(snapshot.runtimes.first { $0.id == "rust" }?.installations.first?.version, "1.85.0")
        XCTAssertTrue(snapshot.issues.contains("rustup Rust Runtime Provider：命令超时"))
    }

    func testRustupUnparseableOutputIsIsolated() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test"],
            executables: ["/bin/rustc", "/bin/rustup"],
            commandOutputs: [
                "/bin/rustc --version": "rustc 1.85.0 (abc)\n",
                "/bin/rustup toolchain list": "",
            ]
        )).scan().snapshot

        XCTAssertEqual(snapshot.runtimes.first { $0.id == "rust" }?.installations.first?.version, "1.85.0")
        XCTAssertTrue(snapshot.issues.contains("rustup Rust Runtime Provider：输出解析失败"))
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
        XCTAssertEqual(node.installations.map(\.sources), [[.nvm], [.nvm]])
    }

    func testManagerShimKeepsItsOwnPathAndSource() {
        let root = "/custom/pyenv"
        let shim = "\(root)/shims/python3"
        let installed = "\(root)/versions/3.12.1/bin/python3"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["\(root)/shims", "/custom/bin"],
            environment: ["PYENV_ROOT": root],
            executables: [shim, "/custom/bin/pyenv", installed],
            commandOutputs: [
                "\(shim) --version": "Python 3.12.1\n",
                "/custom/bin/pyenv versions --bare": "3.12.1\n",
            ]
        )).scan().snapshot

        let python = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "python" })
        XCTAssertEqual(python.installations.map(\.executable), [shim, installed])
        XCTAssertEqual(python.installations.map(\.sources), [[.pyenv], [.pyenv]])
        XCTAssertEqual(python.installations.map(\.isInPath), [true, false])
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

    func testRbenvDiscoversVersionsFromDefaultRoot() {
        let root = "/Users/test/.rbenv"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test"],
            executables: [
                "/opt/homebrew/bin/rbenv",
                "\(root)/versions/3.3.4/bin/ruby",
                "\(root)/versions/3.2.2/bin/ruby",
            ],
            commandOutputs: [
                "/opt/homebrew/bin/rbenv versions --bare": "3.3.4\n3.2.2\nsystem\n",
            ]
        )).scan().snapshot

        let ruby = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "ruby" })
        XCTAssertEqual(ruby.installations.map(\.version), ["3.3.4", "3.2.2"])
        XCTAssertEqual(ruby.installations.map(\.executable), [
            "\(root)/versions/3.3.4/bin/ruby",
            "\(root)/versions/3.2.2/bin/ruby",
        ])
        XCTAssertTrue(ruby.installations.allSatisfy { $0.state == .discovered && !$0.isInPath })
    }

    func testRbenvUsesInheritedRootAndMergesPathHomebrewAndMise() {
        let root = "/custom/rbenv"
        let rubyPath = "/custom/bin/ruby"
        let rbenvRuby = "\(root)/versions/3.3.4/bin/ruby"
        let brewRuby = "/opt/homebrew/Cellar/ruby/3.3.4/bin/ruby"
        let miseRuby = "/custom/mise/installs/ruby/3.3.4/bin/ruby"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/custom/bin"],
            environment: ["HOME": "/Users/test", "RBENV_ROOT": root],
            executables: [
                rubyPath, "/custom/bin/rbenv", "/custom/bin/mise", "/opt/homebrew/bin/brew",
                rbenvRuby, brewRuby, miseRuby,
                "\(root)/versions/3.2.2/bin/ruby",
            ],
            resolvedPaths: [
                rubyPath: rbenvRuby,
                brewRuby: rbenvRuby,
                miseRuby: rbenvRuby,
            ],
            commandOutputs: [
                "\(rubyPath) --version": "ruby 3.3.4 (revision)\n",
                "/custom/bin/rbenv versions --bare": "3.3.4\n3.2.2\n",
                "/custom/bin/mise ls --installed --json": "{\"ruby\":[{\"version\":\"3.3.4\",\"install_path\":\"/custom/mise/installs/ruby/3.3.4\"}]}\n",
                "/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n",
                "/opt/homebrew/bin/brew list --formula --versions": "ruby 3.3.4\n",
                "/opt/homebrew/bin/brew --cellar": "/opt/homebrew/Cellar\n",
            ]
        )).scan().snapshot

        let ruby = try! XCTUnwrap(snapshot.runtimes.first { $0.id == "ruby" })
        XCTAssertEqual(ruby.installations.map(\.version), ["3.3.4", "3.2.2"])
        XCTAssertEqual(ruby.installations.map(\.executable), [rubyPath, "\(root)/versions/3.2.2/bin/ruby"])
        XCTAssertEqual(ruby.installations.map(\.isInPath), [true, false])
        XCTAssertFalse(ruby.hasPathVersionConflict)
    }

    func testRbenvFailureKeepsRubyPathResultIsolated() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test"],
            executables: ["/bin/ruby", "/opt/homebrew/bin/rbenv"],
            commandOutputs: ["/bin/ruby --version": "ruby 3.3.4 (revision)\n"],
            commandTimeouts: ["/opt/homebrew/bin/rbenv versions --bare"]
        )).scan().snapshot

        XCTAssertEqual(snapshot.runtimes.first { $0.id == "ruby" }?.installations.first?.version, "3.3.4")
        XCTAssertTrue(snapshot.issues.contains("rbenv Ruby Runtime Provider：命令超时"))
        XCTAssertFalse(snapshot.issues.contains { $0.hasPrefix("Ruby：") })
    }

    func testDiscoversMongoDBAndRedisFromPathInDatabaseDisplayOrder() throws {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/bin/mongod", "/bin/redis-server"],
            commandOutputs: [
                "/bin/mongod --version": "db version v8.0.12\nBuild Info: {}\n",
                "/bin/redis-server --version": "Redis server v=8.2.1 sha=00000000:0 malloc=libc bits=64 build=0\n",
            ]
        )).scan().snapshot

        XCTAssertEqual(snapshot.databaseInstallationOverviews.map(\.id), [
            "postgresql", "mysql", "mariadb", "mongodb", "redis",
        ])
        XCTAssertEqual(snapshot.databaseInstallationOverviews.map(\.name), [
            "PostgreSQL", "MySQL", "MariaDB", "MongoDB", "Redis",
        ])
        XCTAssertEqual(snapshot.databaseInstallationOverviews.map(\.discoveryState), [
            .notFound, .notFound, .notFound, .discovered, .discovered,
        ])
        XCTAssertEqual(snapshot.databaseInstallationOverviews.map(\.listeningState), [
            .notListening, .notListening, .notListening, .notListening, .notListening,
        ])
        XCTAssertEqual(snapshot.databaseInstallationOverviews.map { $0.installations.count }, [0, 0, 0, 1, 1])
        XCTAssertEqual(snapshot.databaseInstallationOverviews.map(\.listeningCount), [0, 0, 0, 0, 0])
        XCTAssertEqual(snapshot.databaseInstallationOverviews[3].installations.first?.version, "8.0.12")
        XCTAssertEqual(snapshot.databaseInstallationOverviews[4].installations.first?.version, "8.2.1")
    }

    func testMongoDBAndRedisDeduplicateProvidersAndMatchExactListeningVersions() throws {
        let mongodb8 = "/opt/mongodb/8/bin/mongod"
        let mongodb7 = "/opt/homebrew/Cellar/mongodb-community@7.0/7.0.22/bin/mongod"
        let redis8 = "/opt/redis/8/bin/redis-server"
        let redis7 = "/opt/homebrew/Cellar/redis@7.2/7.2.10/bin/redis-server"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/usr/local/bin"],
            executables: [
                "/usr/local/bin/mongod",
                "/usr/local/bin/redis-server",
                "/opt/homebrew/bin/brew",
                "/opt/homebrew/Cellar/mongodb-community/8.0.12/bin/mongod",
                mongodb7,
                "/opt/homebrew/Cellar/redis/8.2.1/bin/redis-server",
                redis7,
            ],
            resolvedPaths: [
                "/usr/local/bin/mongod": mongodb8,
                "/opt/homebrew/Cellar/mongodb-community/8.0.12/bin/mongod": mongodb8,
                "/usr/local/bin/redis-server": redis8,
                "/opt/homebrew/Cellar/redis/8.2.1/bin/redis-server": redis8,
            ],
            commandOutputs: [
                "/usr/local/bin/mongod --version": "db version v8.0.12\nBuild Info: {}\n",
                "/usr/local/bin/redis-server --version": "Redis server v=8.2.1 sha=00000000:0 malloc=libc bits=64 build=0\n",
                "/opt/homebrew/bin/brew --version": "Homebrew 4.6.0\n",
                "/opt/homebrew/bin/brew list --formula --versions": "mongodb-community 8.0.12\nmongodb-community@7.0 7.0.22\nredis 8.2.1\nredis@7.2 7.2.10\n",
                "/opt/homebrew/bin/brew --cellar": "/opt/homebrew/Cellar\n",
                "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn": "p42\ncmongod\nf7\ntIPv4\nn127.0.0.1:27017\np43\ncredis-server\nf8\ntIPv4\nn127.0.0.1:6379\np44\nccom.docker.backend\nf9\ntIPv4\nn127.0.0.1:65000\n",
            ],
            processExecutablePaths: [
                42: mongodb8,
                43: redis7,
                44: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
            ]
        )).scan().snapshot

        let mongodb = try XCTUnwrap(snapshot.databaseInstallationOverviews.first { $0.id == "mongodb" })
        XCTAssertEqual(mongodb.installations.map(\.id), [mongodb8, mongodb7])
        XCTAssertEqual(mongodb.installations.map(\.listeningState), [.listening, .notListening])
        XCTAssertEqual(mongodb.installations[0].sources, [.path, .homebrew, .localService])
        XCTAssertEqual(mongodb.listeningState, .listening)
        XCTAssertEqual(mongodb.listeningCount, 1)

        let redis = try XCTUnwrap(snapshot.databaseInstallationOverviews.first { $0.id == "redis" })
        XCTAssertEqual(redis.installations.map(\.id), [redis8, redis7])
        XCTAssertEqual(redis.installations.map(\.listeningState), [.notListening, .listening])
        XCTAssertEqual(redis.installations[1].sources, [.homebrew, .localService])
        XCTAssertEqual(redis.listeningState, .listening)
        XCTAssertEqual(redis.listeningCount, 1)
        XCTAssertEqual(snapshot.localServices.map(\.processName), ["redis-server", "mongod", "com.docker.backend"])
    }

    func testMongoDBAndRedisFailuresUseUnknownStatesWithoutCrossContamination() throws {
        let mongod = "/Applications/MongoDB/bin/mongod"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            commandOutputs: [
                "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn": "p42\ncmongod\nf7\ntIPv4\nn127.0.0.1:27017\np43\ncredis-server\nf8\ntIPv4\nn127.0.0.1:6379\n",
            ],
            commandStatuses: ["\(mongod) --version": -1],
            processExecutablePaths: [42: mongod],
            processExecutableFailures: [43]
        )).scan().snapshot

        let mongodb = try XCTUnwrap(snapshot.databaseInstallationOverviews.first { $0.id == "mongodb" })
        XCTAssertEqual(mongodb.discoveryState, .discovered)
        XCTAssertEqual(mongodb.listeningState, .listening)
        XCTAssertEqual(mongodb.installations.first?.error, "版本读取失败")
        XCTAssertTrue(snapshot.issues.contains("MongoDB：版本读取失败（\(mongod)）"))

        let redis = try XCTUnwrap(snapshot.databaseInstallationOverviews.first { $0.id == "redis" })
        XCTAssertEqual(redis.discoveryState, .unknown)
        XCTAssertEqual(redis.listeningState, .unknown)
        XCTAssertTrue(redis.installations.isEmpty)
        XCTAssertTrue(snapshot.issues.contains("Redis：进程路径读取失败（PID 43）"))
    }

    func testMongoDBAndRedisHomebrewFailureUsesUnknownStates() throws {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/opt/homebrew/bin/brew"],
            commandOutputs: ["/opt/homebrew/bin/brew --version": "Homebrew 4.6.0\n"],
            commandTimeouts: ["/opt/homebrew/bin/brew list --formula --versions"]
        )).scan().snapshot

        for name in ["MongoDB", "Redis"] {
            let database = try XCTUnwrap(snapshot.databaseInstallationOverviews.first { $0.name == name })
            XCTAssertEqual(database.discoveryState, .unknown)
            XCTAssertEqual(database.listeningState, .unknown)
            XCTAssertTrue(database.installations.isEmpty)
            XCTAssertTrue(snapshot.issues.contains("\(name) Database Provider：Homebrew 命令超时"))
        }
    }

    func testDiscoversMySQLAndMariaDBFromPathInDatabaseDisplayOrder() throws {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/bin/mysqld", "/bin/mariadbd"],
            commandOutputs: [
                "/bin/mysqld --version": "/bin/mysqld  Ver 8.4.3 for macos14.7 on arm64 (MySQL Community Server - GPL)\n",
                "/bin/mariadbd --version": "/bin/mariadbd  Ver 15.1 Distrib 11.4.5-MariaDB for osx10.19 on arm64 (Homebrew)\n",
            ]
        )).scan().snapshot

        XCTAssertEqual(snapshot.databaseInstallationOverviews.map(\.id), [
            "postgresql", "mysql", "mariadb", "mongodb", "redis",
        ])
        XCTAssertEqual(snapshot.databaseInstallationOverviews.map(\.name), [
            "PostgreSQL", "MySQL", "MariaDB", "MongoDB", "Redis",
        ])
        XCTAssertEqual(snapshot.databaseInstallationOverviews[1].installations.first?.version, "8.4.3")
        XCTAssertEqual(snapshot.databaseInstallationOverviews[2].installations.first?.version, "11.4.5")
    }

    func testMySQLAndMariaDBDeduplicateProvidersAndMatchExactListeningVersions() throws {
        let mysql84 = "/opt/mysql/8.4/bin/mysqld"
        let mysql80 = "/opt/homebrew/Cellar/mysql@8.0/8.0.40/bin/mysqld"
        let mariadb114 = "/opt/homebrew/Cellar/mariadb/11.4.5/bin/mariadbd"
        let mariadb1011 = "/opt/homebrew/Cellar/mariadb@10.11/10.11.10/bin/mariadbd"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/usr/local/bin"],
            executables: [
                "/usr/local/bin/mysqld",
                "/opt/homebrew/bin/brew",
                "/opt/homebrew/Cellar/mysql/8.4.3/bin/mysqld",
                mysql80,
                mariadb114,
                mariadb1011,
            ],
            resolvedPaths: [
                "/usr/local/bin/mysqld": mysql84,
                "/opt/homebrew/Cellar/mysql/8.4.3/bin/mysqld": mysql84,
            ],
            commandOutputs: [
                "/usr/local/bin/mysqld --version": "mysqld Ver 8.4.3 for macos (MySQL Community Server - GPL)\n",
                "/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n",
                "/opt/homebrew/bin/brew list --formula --versions": "mysql 8.4.3\nmysql@8.0 8.0.40\nmariadb 11.4.5\nmariadb@10.11 10.11.10\n",
                "/opt/homebrew/bin/brew --cellar": "/opt/homebrew/Cellar\n",
                "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn": "p42\ncmysqld\nf7\ntIPv4\nn127.0.0.1:3306\np43\ncmariadbd\nf8\ntIPv4\nn127.0.0.1:3307\n",
            ],
            processExecutablePaths: [42: mysql84, 43: mariadb1011]
        )).scan().snapshot

        let mysql = try XCTUnwrap(snapshot.databaseInstallationOverviews.first { $0.id == "mysql" })
        XCTAssertEqual(mysql.installations.map(\.id), [mysql84, mysql80])
        XCTAssertEqual(mysql.installations.map(\.version), ["8.4.3", "8.0.40"])
        XCTAssertEqual(mysql.installations.map(\.listeningState), [.listening, .notListening])
        XCTAssertEqual(mysql.installations[0].executable, "/usr/local/bin/mysqld")
        XCTAssertEqual(mysql.installations[0].actualExecutable, mysql84)
        XCTAssertEqual(mysql.installations[0].sources, [.path, .homebrew, .localService])

        let mariadb = try XCTUnwrap(snapshot.databaseInstallationOverviews.first { $0.id == "mariadb" })
        XCTAssertEqual(mariadb.installations.map(\.id), [mariadb114, mariadb1011])
        XCTAssertEqual(mariadb.installations.map(\.listeningState), [.notListening, .listening])
        XCTAssertEqual(mariadb.installations[1].sources, [.homebrew, .localService])
        XCTAssertEqual(snapshot.localServices.map(\.processName), ["mysqld", "mariadbd"])
    }

    func testMySQLAndMariaDBProviderFailureUsesUnknownStates() throws {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/opt/homebrew/bin/brew"],
            commandOutputs: ["/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n"],
            commandTimeouts: ["/opt/homebrew/bin/brew list --formula --versions"]
        )).scan().snapshot

        for id in ["mysql", "mariadb"] {
            let database = try XCTUnwrap(snapshot.databaseInstallationOverviews.first { $0.id == id })
            XCTAssertEqual(database.discoveryState, .unknown)
            XCTAssertEqual(database.listeningState, .unknown)
            XCTAssertTrue(database.installations.isEmpty)
        }
        XCTAssertTrue(snapshot.issues.contains("MySQL Database Provider：Homebrew 命令超时"))
        XCTAssertTrue(snapshot.issues.contains("MariaDB Database Provider：Homebrew 命令超时"))
    }

    func testAmbiguousLocalServiceMysqldStaysUnclassifiedAndProducesNotice() throws {
        let mysqld = "/opt/mysql/bin/mysqld"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            commandOutputs: [
                "\(mysqld) --version": "\(mysqld) Ver 8.0.0 for macos on arm64\n",
                "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn": "p42\ncmysqld\nf7\ntIPv4\nn127.0.0.1:3306\n",
            ],
            processExecutablePaths: [42: mysqld]
        )).scan().snapshot

        XCTAssertEqual(snapshot.localServices.map(\.processName), ["mysqld"])
        XCTAssertTrue(snapshot.databaseInstallationOverviews
            .filter { $0.id == "mysql" || $0.id == "mariadb" }
            .allSatisfy { $0.installations.isEmpty && $0.discoveryState == .unknown })
        XCTAssertTrue(snapshot.issues.contains("MySQL/MariaDB：无法分类 mysqld（\(mysqld)）"))

        let descriptor = localServiceDescriptor(for: "mysqld")
        XCTAssertEqual(descriptor.displayName, "mysqld")
        XCTAssertNil(descriptor.assetName)
    }

    func testLocalServiceOnlyMySQLAndMariaDBKeepKnownTypeWhenVersionFails() throws {
        let mysqld = "/usr/local/mysql/bin/mysqld"
        let mariadbd = "/Applications/MariaDB/bin/mariadbd"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            commandOutputs: [
                "\(mysqld) --version": "mysqld Ver 8.4.3 for macos (MySQL Community Server - GPL)\n",
                "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn": "p42\ncmysqld\nf7\ntIPv4\nn127.0.0.1:3306\np43\ncmariadbd\nf8\ntIPv4\nn127.0.0.1:3307\n",
            ],
            commandStatuses: ["\(mariadbd) --version": -1],
            processExecutablePaths: [42: mysqld, 43: mariadbd]
        )).scan().snapshot

        let mysql = try XCTUnwrap(snapshot.databaseInstallationOverviews.first { $0.id == "mysql" })
        XCTAssertEqual(mysql.installations.first?.version, "8.4.3")
        XCTAssertEqual(mysql.installations.first?.sources, [.localService])
        XCTAssertEqual(mysql.listeningState, .listening)

        let mariadb = try XCTUnwrap(snapshot.databaseInstallationOverviews.first { $0.id == "mariadb" })
        XCTAssertNil(mariadb.installations.first?.version)
        XCTAssertEqual(mariadb.installations.first?.error, "版本读取失败")
        XCTAssertEqual(mariadb.listeningState, .listening)
        XCTAssertTrue(snapshot.issues.contains("MariaDB：版本读取失败（\(mariadbd)）"))
    }

    func testMariaDBProcessPathFailureDoesNotChangeMySQLListeningState() throws {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/bin/mysqld"],
            commandOutputs: [
                "/bin/mysqld --version": "mysqld Ver 8.4.3 for macos (MySQL Community Server - GPL)\n",
                "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn": "p43\ncmariadbd\nf8\ntIPv4\nn127.0.0.1:3307\n",
            ],
            processExecutableFailures: [43]
        )).scan().snapshot

        let mysql = try XCTUnwrap(snapshot.databaseInstallationOverviews.first { $0.id == "mysql" })
        XCTAssertEqual(mysql.discoveryState, .discovered)
        XCTAssertEqual(mysql.listeningState, .notListening)
        XCTAssertEqual(mysql.installations.first?.listeningState, .notListening)

        let mariadb = try XCTUnwrap(snapshot.databaseInstallationOverviews.first { $0.id == "mariadb" })
        XCTAssertEqual(mariadb.discoveryState, .unknown)
        XCTAssertEqual(mariadb.listeningState, .unknown)
        XCTAssertTrue(snapshot.issues.contains("MariaDB：进程路径读取失败（PID 43）"))
    }

    func testPostgreSQLDeduplicatesThreeSourcesAndMatchesOnlyTheExactListeningVersion() throws {
        let postgres16 = "/opt/postgresql/16/bin/postgres"
        let postgres15 = "/opt/homebrew/Cellar/postgresql@15/15.8/bin/postgres"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/usr/local/bin"],
            executables: [
                "/usr/local/bin/postgres",
                "/opt/homebrew/bin/brew",
                "/opt/homebrew/Cellar/postgresql@16/16.3/bin/postgres",
                postgres15,
            ],
            resolvedPaths: [
                "/usr/local/bin/postgres": postgres16,
                "/opt/homebrew/Cellar/postgresql@16/16.3/bin/postgres": postgres16,
            ],
            commandOutputs: [
                "/usr/local/bin/postgres --version": "postgres (PostgreSQL) 16.3\n",
                "/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n",
                "/opt/homebrew/bin/brew list --formula --versions": "postgresql@15 15.8\npostgresql@16 16.3\n",
                "/opt/homebrew/bin/brew --cellar": "/opt/homebrew/Cellar\n",
                "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn": "p42\ncpostgres\nf7\ntIPv4\nn127.0.0.1:5432\n",
            ],
            processExecutablePaths: [42: postgres16]
        )).scan().snapshot

        let postgres = try XCTUnwrap(snapshot.databaseInstallationOverviews.first { $0.id == "postgresql" })
        XCTAssertEqual(postgres.discoveryState, .discovered)
        XCTAssertEqual(postgres.listeningState, .listening)
        XCTAssertEqual(postgres.installations.map(\.id), [postgres16, postgres15])
        XCTAssertEqual(postgres.installations.map(\.version), ["16.3", "15.8"])
        XCTAssertEqual(postgres.installations.map(\.listeningState), [.listening, .notListening])
        XCTAssertEqual(postgres.installations[0].executable, "/usr/local/bin/postgres")
        XCTAssertEqual(postgres.installations[0].actualExecutable, postgres16)
        XCTAssertEqual(postgres.installations[0].sources, [.path, .homebrew, .localService])
        XCTAssertEqual(snapshot.localServices.first?.processName, "postgres")
    }

    func testPostgreSQLProviderFailuresPreserveResultsAndUseUnknownWhenNothingWasFound() throws {
        let postgres = "/bin/postgres"
        let lsof = "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn"
        let brewList = "/opt/homebrew/bin/brew list --formula --versions"
        let withPathResult = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: [postgres, "/opt/homebrew/bin/brew"],
            commandOutputs: [
                "\(postgres) --version": "postgres (PostgreSQL) 17.1\n",
                "/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n",
            ],
            commandTimeouts: [brewList]
        )).scan().snapshot

        let discovered = try XCTUnwrap(withPathResult.databaseInstallationOverviews.first)
        XCTAssertEqual(discovered.discoveryState, .discovered)
        XCTAssertEqual(discovered.listeningState, .unknown)
        XCTAssertEqual(discovered.installations.first?.listeningState, .notListening)
        XCTAssertTrue(withPathResult.issues.contains("PostgreSQL Database Provider：Homebrew 命令超时"))

        let withoutResults = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/opt/homebrew/bin/brew"],
            commandOutputs: ["/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n"],
            commandStatuses: [lsof: -1],
            commandTimeouts: [brewList]
        )).scan().snapshot

        XCTAssertEqual(withoutResults.databaseInstallationOverviews.first?.discoveryState, .unknown)
        XCTAssertEqual(withoutResults.databaseInstallationOverviews.first?.listeningState, .unknown)
        XCTAssertTrue(withoutResults.databaseInstallationOverviews.first?.installations.isEmpty == true)
    }

    func testPostgreSQLVersionFailureKeepsExactListeningState() throws {
        let postgres = "/bin/postgres"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: [postgres],
            commandOutputs: [
                "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn": "p42\ncpostgres\nf7\ntIPv4\nn127.0.0.1:5432\n",
            ],
            commandStatuses: ["\(postgres) --version": -1],
            processExecutablePaths: [42: postgres]
        )).scan().snapshot

        let database = try XCTUnwrap(snapshot.databaseInstallationOverviews.first)
        let installation = try XCTUnwrap(database.installations.first)
        XCTAssertEqual(database.discoveryState, .discovered)
        XCTAssertEqual(database.listeningState, .listening)
        XCTAssertNil(installation.version)
        XCTAssertEqual(installation.error, "版本读取失败")
        XCTAssertEqual(installation.listeningState, .listening)
        XCTAssertTrue(snapshot.issues.contains("PostgreSQL：版本读取失败（/bin/postgres）"))
    }

    func testPostgreSQLRelevantProcessPathFailureMakesListeningUnknown() throws {
        let postgres = "/bin/postgres"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: [postgres],
            commandOutputs: [
                "\(postgres) --version": "postgres (PostgreSQL) 17.1\n",
                "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn": "p42\ncpostgres\nf7\ntIPv4\nn127.0.0.1:5432\n",
            ],
            processExecutableFailures: [42]
        )).scan().snapshot

        let database = try XCTUnwrap(snapshot.databaseInstallationOverviews.first)
        XCTAssertEqual(database.discoveryState, .discovered)
        XCTAssertEqual(database.listeningState, .unknown)
        XCTAssertEqual(database.installations.first?.listeningState, .unknown)
        XCTAssertTrue(snapshot.issues.contains("PostgreSQL：进程路径读取失败（PID 42）"))
    }

    func testHomebrewPostgreSQLWithoutListenerIsNeutral() throws {
        let postgres = "/opt/homebrew/Cellar/postgresql/17.2/bin/postgres"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/opt/homebrew/bin/brew", postgres],
            commandOutputs: [
                "/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n",
                "/opt/homebrew/bin/brew list --formula --versions": "postgresql 17.2\n",
                "/opt/homebrew/bin/brew --cellar": "/opt/homebrew/Cellar\n",
            ]
        )).scan().snapshot

        let database = try XCTUnwrap(snapshot.databaseInstallationOverviews.first)
        XCTAssertEqual(database.discoveryState, .discovered)
        XCTAssertEqual(database.listeningState, .notListening)
        XCTAssertEqual(database.installations.first?.listeningState, .notListening)
        XCTAssertFalse(snapshot.issues.contains { $0.hasPrefix("PostgreSQL") })
    }

    func testUnrelatedHomebrewCellarFailureDoesNotMakePostgreSQLDiscoveryUnknown() throws {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/opt/homebrew/bin/brew"],
            commandOutputs: [
                "/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n",
                "/opt/homebrew/bin/brew list --formula --versions": "node 22.0.0\n",
            ],
            commandTimeouts: ["/opt/homebrew/bin/brew --cellar"]
        )).scan().snapshot

        XCTAssertEqual(snapshot.databaseInstallationOverviews.first?.discoveryState, .notFound)
        XCTAssertFalse(snapshot.issues.contains { $0.hasPrefix("PostgreSQL") })
    }

    func testPostgreSQLLocalServiceOnlyAggregatesMultipleListenersIntoOneInstallation() throws {
        let postgres = "/Applications/Postgres.app/Contents/Versions/17/bin/postgres"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            commandOutputs: [
                "\(postgres) --version": "postgres (PostgreSQL) 17.2\n",
                "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn": "p10\ncpostgres\nf7\ntIPv4\nn127.0.0.1:5432\np11\ncpostgres\nf8\ntIPv6\nn[::1]:5433\n",
            ],
            processExecutablePaths: [10: postgres, 11: postgres]
        )).scan().snapshot

        let database = try XCTUnwrap(snapshot.databaseInstallationOverviews.first)
        XCTAssertEqual(database.installations.count, 1)
        XCTAssertEqual(database.listeningCount, 1)
        XCTAssertEqual(database.installations.first?.version, "17.2")
        XCTAssertEqual(database.installations.first?.sources, [.localService])
        XCTAssertEqual(snapshot.localServices.count, 2)
    }

    func testAggregatesAndSortsVisibleTCPListeners() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            commandOutputs: [
                "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn": """
                p20
                cZed
                f10
                tIPv6
                n[::1]:8080
                p10
                cAlpha
                f11
                tIPv6
                n[::1]:3000
                f12
                tIPv4
                n127.0.0.1:3000
                f13
                tIPv4
                n127.0.0.1:3000
                f14
                tIPv4
                n*:4000
                p30
                cBeta
                f15
                tIPv4
                n*:3000
                """,
            ]
        )).scan().snapshot

        XCTAssertEqual(snapshot.localServices.map(\.processName), ["Alpha", "Beta", "Zed"])
        XCTAssertEqual(snapshot.localServices.map(\.pid), [10, 30, 20])
        XCTAssertEqual(snapshot.localServices[0].bindings, [
            ListenerBinding(address: "127.0.0.1", port: 3000, family: .ipv4),
            ListenerBinding(address: "::1", port: 3000, family: .ipv6),
            ListenerBinding(address: "*", port: 4000, family: .ipv4),
        ])
        XCTAssertEqual(snapshot.localServices[1].bindings, [
            ListenerBinding(address: "*", port: 3000, family: .ipv4),
        ])
    }

    func testClassifiesListenerExposureFromBindingAddress() {
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            commandOutputs: [
                "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn": """
                p10
                cServer
                f10
                tIPv4
                n127.0.0.2:3000
                f11
                tIPv6
                n[::1]:3001
                f12
                tIPv4
                n*:3002
                f13
                tIPv4
                n192.168.1.10:3003
                """,
            ]
        )).scan().snapshot

        XCTAssertEqual(snapshot.localServices[0].bindings.map(\.isLoopback), [true, true, false, false])
    }

    func testListenerCommandFailureIsReportedAsScanNotice() {
        let command = "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn"
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            commandStatuses: [command: -1]
        )).scan().snapshot

        XCTAssertTrue(snapshot.localServices.isEmpty)
        XCTAssertTrue(snapshot.issues.contains("本地服务：读取失败"))
    }

    func testListenerTimeoutKeepsPartialSnapshotAndProducesOneNotice() {
        let command = "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn"
        let result = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            executables: ["/bin/node", "/opt/homebrew/bin/brew"],
            commandOutputs: [
                "/bin/node --version": "v22.0.0\n",
                "/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n",
            ],
            commandTimeouts: [command]
        )).scan()

        XCTAssertTrue(result.snapshot.localServices.isEmpty)
        XCTAssertEqual(result.snapshot.localServiceScanNotice, "本地服务：命令超时")
        XCTAssertEqual(result.snapshot.issues.filter { $0.hasPrefix("本地服务：") }, ["本地服务：命令超时"])
        XCTAssertEqual(result.snapshot.path, ["/bin"])
        XCTAssertEqual(result.snapshot.runtimes.first { $0.id == "node" }?.installations.first?.version, "22.0.0")
        XCTAssertTrue(result.snapshot.homebrew.available)
        XCTAssertTrue(result.canPersist)
    }

    func testGroupsListenerRowsOnlyWhenProcessNameAndBindingsMatch() {
        let sharedBinding = ListenerBinding(address: "127.0.0.1", port: 8000, family: .ipv4)
        let groups = groupLocalServicesForDisplay([
            LocalServiceSnapshot(processName: "python3.13", pid: 42, bindings: [sharedBinding]),
            LocalServiceSnapshot(processName: "python3.13", pid: 10, bindings: [sharedBinding]),
            LocalServiceSnapshot(
                processName: "python3.13",
                pid: 30,
                bindings: [ListenerBinding(address: "127.0.0.1", port: 8001, family: .ipv4)]
            ),
            LocalServiceSnapshot(processName: "node", pid: 20, bindings: [sharedBinding]),
        ])

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].processName, "python3.13")
        XCTAssertEqual(groups[0].pids, [10, 42])
        XCTAssertEqual(groups[1].pids, [30])
        XCTAssertEqual(groups[2].processName, "node")
    }

    func testBuildsOneExposureNotificationPerDisplayedLocalServiceGroup() {
        let localBinding = ListenerBinding(address: "127.0.0.1", port: 8000, family: .ipv4)
        let exposedBinding = ListenerBinding(address: "*", port: 8001, family: .ipv4)

        XCTAssertEqual(localServiceNotifications([
            LocalServiceSnapshot(processName: "Server", pid: 10, bindings: [localBinding, exposedBinding]),
            LocalServiceSnapshot(processName: "Server", pid: 20, bindings: [localBinding, exposedBinding]),
            LocalServiceSnapshot(processName: "Server", pid: 40, bindings: [
                ListenerBinding(address: "*", port: 8002, family: .ipv4),
            ]),
            LocalServiceSnapshot(processName: "Local", pid: 30, bindings: [localBinding]),
        ]), [
            "Server：1 个监听项可能可被局域网访问",
            "Server：1 个监听项可能可被局域网访问",
        ])
    }

    func testDescribesCommonLocalServiceProcesses() {
        let expectedDescriptors: [(String, String, String?)] = [
            ("python3.13", "Python", "RuntimePythonLogo"),
            ("node", "Node.js", "RuntimeNodeLogo"),
            ("postgres", "PostgreSQL", "ServicePostgreSQLLogo"),
            ("mongod", "MongoDB", "ServiceMongoDBLogo"),
            ("mysqld", "mysqld", nil),
            ("mariadbd", "MariaDB", "ServiceMariaDBLogo"),
            ("redis-server", "Redis", "ServiceRedisLogo"),
            ("adb", "Android Debug Bridge", nil),
            ("rapportd", "Apple 设备互联", nil),
            ("ControlCenter", "控制中心", nil),
            ("WeChat", "微信", nil),
            ("Sparkle", "Sparkle", nil),
        ]

        for (processName, expectedName, expectedAssetName) in expectedDescriptors {
            let descriptor = localServiceDescriptor(for: processName)
            XCTAssertEqual(descriptor.displayName, expectedName)
            XCTAssertEqual(descriptor.assetName, expectedAssetName)
        }
    }

    func testCrossProviderScanIsStableDeduplicatedAndPersistable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(fileURL: directory.appendingPathComponent("machine-snapshot.json"))
        let miseNode = "/custom/mise/installs/node/22.0.0/bin/node"
        let nvmNode = "/Users/test/.nvm/versions/node/v20.0.0/bin/node"
        let misePython313 = "/custom/mise/installs/python/3.13.1/bin/python3"
        let misePython311 = "/custom/mise/installs/python/3.11.9/bin/python3"
        let pyenvPython311 = "/custom/pyenv/versions/3.11.9/bin/python3"
        let unavailablePython = "/custom/pyenv/versions/3.9.20/bin/python3"
        let brewPython312 = "/opt/homebrew/Cellar/python/3.12.2/bin/python3"
        let brewPython313 = "/opt/homebrew/Cellar/python/3.13.1/bin/python3"
        let result = EnvironmentScanner(machine: StubMachine(
            path: ["/effective", "/older"],
            environment: ["HOME": "/Users/test", "PYENV_ROOT": "/custom/pyenv"],
            executables: [
                "/effective/python3", "/older/python3", "/opt/homebrew/bin/brew", "/Users/test/.local/bin/mise",
                "/custom/pyenv/bin/pyenv", "/Users/test/.cargo/bin/rustup", misePython313, misePython311,
                pyenvPython311, brewPython312, brewPython313, miseNode, nvmNode,
            ],
            resolvedPaths: [
                "/effective/python3": "/real/python-3.12",
                brewPython312: "/real/python-3.12",
                misePython313: "/real/python-3.13",
                brewPython313: "/real/python-3.13",
            ],
            commandOutputs: [
                "/effective/python3 --version": "Python 3.12.2\n",
                "/older/python3 --version": "Python 3.10.14\n",
                "/opt/homebrew/bin/brew --version": "Homebrew 4.5.0\n",
                "/opt/homebrew/bin/brew list --formula --versions": "python 3.12.2 3.13.1\n",
                "/opt/homebrew/bin/brew --cellar": "/opt/homebrew/Cellar\n",
                "/Users/test/.local/bin/mise ls --installed --json": """
                {"node":[{"version":"22.0.0","install_path":"/custom/mise/installs/node/22.0.0"}],"python":[
                  {"version":"3.13.1","install_path":"/custom/mise/installs/python/3.13.1"},
                  {"version":"3.11.9","install_path":"/custom/mise/installs/python/3.11.9"}
                ]}
                """,
                "/custom/pyenv/bin/pyenv versions --bare": "3.11.9\n3.9.20\n",
            ],
            commandTimeouts: ["/Users/test/.cargo/bin/rustup toolchain list"],
            directoryContents: ["/Users/test/.nvm/versions/node": ["v20.0.0"]]
        )).scan()
        let node = try XCTUnwrap(result.snapshot.runtimes.first { $0.id == "node" })
        let python = try XCTUnwrap(result.snapshot.runtimes.first { $0.id == "python" })

        XCTAssertTrue(result.canPersist)
        XCTAssertEqual(node.installations.map(\.version), ["22.0.0", "20.0.0"])
        XCTAssertFalse(node.hasPathVersionConflict)
        XCTAssertEqual(python.installations.map(\.executable), [
            "/effective/python3", "/older/python3", misePython313, misePython311, pyenvPython311, unavailablePython,
        ])
        XCTAssertEqual(python.installations.map(\.version), ["3.12.2", "3.10.14", "3.13.1", "3.11.9", "3.11.9", "3.9.20"])
        XCTAssertEqual(python.installations.map(\.isInPath), [true, true, false, false, false, false])
        XCTAssertTrue(python.installations.first?.isEffective == true)
        XCTAssertTrue(python.hasPathVersionConflict)
        XCTAssertEqual(python.installations.filter { $0.version == "3.13.1" }.count, 1)
        XCTAssertEqual(python.installations.last?.state, .failed)
        XCTAssertEqual(python.installations.last?.error, "可执行文件不可用")
        XCTAssertEqual(result.snapshot.issues.filter { $0 == "rustup Rust Runtime Provider：命令超时" }.count, 1)
        XCTAssertFalse(result.snapshot.issues.contains { $0.contains("PATH 版本冲突") })

        try store.save(result.snapshot)
        let restored = try XCTUnwrap(store.load())
        var restoredJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any]
        )
        var scannedJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.snapshot)) as? [String: Any]
        )
        restoredJSON.removeValue(forKey: "scannedAt")
        scannedJSON.removeValue(forKey: "scannedAt")
        XCTAssertEqual(restoredJSON as NSDictionary, scannedJSON as NSDictionary)
        XCTAssertEqual(restored.scannedAt.timeIntervalSince1970, result.snapshot.scannedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(restored.runtimes.first { $0.id == "python" }?.hasPathVersionConflict == true)
    }

    func testV11SnapshotRoundTripsFiveDatabasesAndV10IsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("machine-snapshot.json")
        let store = SnapshotStore(fileURL: fileURL)
        let snapshot = EnvironmentScanner(machine: StubMachine(
            path: ["/bin"],
            environment: ["HOME": "/Users/test", "GH_TOKEN": "recognizable-token-19"],
            executables: ["/bin/git", "/bin/git-lfs", "/bin/gh", "/bin/node"],
            commandOutputs: [
                "/bin/git --version": "git version 2.49.0 (Apple Git-154)\n",
                "/bin/git-lfs version": "git-lfs/3.7.0 (GitHub; darwin arm64)\n",
                "/bin/git config --global --get user.name": "Test User\n",
                "/bin/git config --global --get user.email": "test@example.com\n",
                "/bin/git config --global --get init.defaultBranch": "main\n",
                "/bin/git config --global --path --get core.excludesFile": "/Users/test/.gitignore\n",
                "/bin/git config --global --get gpg.format": "ssh\n",
                "/bin/git config --global --get user.signingKey": "test@example.com\n",
                "/bin/git config --global --get commit.gpgSign": "true\n",
                "/bin/git config --global --null --get-all credential.helper": "osxkeychain\0store --file=/tmp/credentials\0",
                "/bin/gh config get git_protocol --host github.com": "https\n",
                "/bin/node": "v22.0.0\n",
                "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn": "p42\ncnode\nf7\ntIPv4\nn127.0.0.1:3000\n",
            ],
            existingFiles: ["/Users/test/.config/gh/hosts.yml", "/Users/test/.gitignore"]
        )).scan().snapshot

        try store.save(snapshot)
        XCTAssertEqual(store.load()?.schemaVersion, 11)
        XCTAssertEqual(store.load()?.gitCLI.version, "2.49.0 (Apple Git-154)")
        XCTAssertEqual(store.load()?.gitCLI.executable, "/bin/git")
        XCTAssertEqual(store.load()?.userGitConfiguration?.defaultIdentity.email, "test@example.com")
        XCTAssertEqual(store.load()?.userGitConfiguration?.defaultBranch, "main")
        XCTAssertEqual(store.load()?.userGitConfiguration?.excludesFile.path, "/Users/test/.gitignore")
        XCTAssertTrue(store.load()?.userGitConfiguration?.excludesFile.exists == true)
        XCTAssertEqual(store.load()?.gitLFS?.version, "3.7.0")
        XCTAssertEqual(store.load()?.gitSigningConfiguration?.format, "ssh")
        XCTAssertEqual(store.load()?.gitCredentialHelpers, ["osxkeychain", "store"])
        XCTAssertEqual(store.load()?.githubAuthenticationConfiguration.cliState, .available)
        XCTAssertEqual(store.load()?.githubAuthenticationConfiguration.gitProtocol, "https")
        XCTAssertTrue(store.load()?.githubAuthenticationConfiguration.localConfigurationExists == true)
        XCTAssertTrue(store.load()?.githubAuthenticationConfiguration.ghTokenExists == true)
        XCTAssertEqual(store.load()?.localServices.first?.bindings.first?.port, 3000)
        XCTAssertEqual(store.load()?.runtimes.first { $0.id == "node" }?.installations.first?.sources, [.system])
        XCTAssertEqual(store.load()?.databaseInstallationOverviews.map(\.id), [
            "postgresql", "mysql", "mariadb", "mongodb", "redis",
        ])
        XCTAssertEqual(store.load()?.databaseInstallationOverviews.first?.discoveryState, .notFound)

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

        json["schemaVersion"] = 10
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
    let existingFiles: Set<String>
    let processExecutablePaths: [Int32: String]
    let processExecutableFailures: Set<Int32>

    init(
        path: [String],
        environment: [String: String] = [:],
        executables: Set<String> = [],
        resolvedPaths: [String: String] = [:],
        commandOutputs: [String: String] = [:],
        commandStatuses: [String: Int32] = [:],
        commandTimeouts: Set<String> = [],
        directoryContents: [String: [String]] = [:],
        directoryFailures: Set<String> = [],
        existingFiles: Set<String> = [],
        fileContents: [String: String] = [:],
        processExecutablePaths: [Int32: String] = [:],
        processExecutableFailures: Set<Int32> = []
    ) {
        self.environment = environment.merging(["PATH": path.joined(separator: ":")]) { _, path in path }
        self.executables = executables
        self.resolvedPaths = resolvedPaths
        self.commandOutputs = commandOutputs
        self.commandStatuses = commandStatuses
        self.commandTimeouts = commandTimeouts
        self.directoryContents = directoryContents
        self.directoryFailures = directoryFailures
        self.existingFiles = existingFiles.union(fileContents.keys)
        self.processExecutablePaths = processExecutablePaths
        self.processExecutableFailures = processExecutableFailures
    }

    func diskSpace() -> DiskSpace { DiskSpace(totalBytes: 1, freeBytes: 1) }

    func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }

    func fileExists(atPath path: String) -> Bool { existingFiles.contains(path) }

    func directoryEntries(atPath path: String) throws -> [String] {
        if directoryFailures.contains(path) { throw CocoaError(.fileReadNoPermission) }
        guard let entries = directoryContents[path] else { throw CocoaError(.fileReadNoSuchFile) }
        return entries
    }

    func resolvingSymlinksInPath(_ path: String) -> String { resolvedPaths[path, default: path] }

    func executablePath(forPID pid: Int32) throws -> String {
        if processExecutableFailures.contains(pid) { throw CocoaError(.fileReadNoPermission) }
        guard let path = processExecutablePaths[pid] else { throw CocoaError(.fileNoSuchFile) }
        return path
    }

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
