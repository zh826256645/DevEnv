import Foundation
import XCTest
@testable import DevEnv

final class ProjectRequirementsTests: XCTestCase {
    func testGroupsRequirementsAcrossComponentsAndUsesLowestDatabaseVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = root.appendingPathComponent("backend")
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        try Data("postgres 15 16\n".utf8).write(to: root.appendingPathComponent(".tool-versions"))
        try Data("services:\n  old-db:\n    image: postgres:15\n  new-db:\n    image: postgres:16\n".utf8)
            .write(to: root.appendingPathComponent("compose.yaml"))
        try Data("3.13\n".utf8).write(to: backend.appendingPathComponent(".python-version"))
        try Data("""
        [project]
        requires-python = ">=3.13"
        dependencies = ["psycopg[binary]"]
        """.utf8).write(to: backend.appendingPathComponent("pyproject.toml"))

        let analysis = ProjectRequirementsScanner().scan(
            projectRoot: root,
            machineSnapshot: snapshot(
                python: [runtimeInstallation(path: "/opt/python", version: "3.13.4")],
                databases: [
                    databaseOverview(
                        id: "postgresql",
                        installations: [databaseInstallation(path: "/opt/postgres", version: "15.9")]
                    ),
                ]
            )
        )

        XCTAssertEqual(analysis.requirements.count, 3)
        let python = try XCTUnwrap(analysis.requirements.first { $0.capability == "python" })
        XCTAssertEqual(python.expression, "3.13")
        XCTAssertEqual(python.declarations.count, 2)
        XCTAssertEqual(python.satisfaction, .satisfied)

        let postgresql = try XCTUnwrap(analysis.requirements.first { $0.capability == "postgresql" })
        XCTAssertEqual(postgresql.expression, ">=15")
        XCTAssertEqual(postgresql.declarations.map(\.expression), ["15 || 16", "15", "16", "*"])
        XCTAssertEqual(postgresql.satisfaction, .satisfied)
        XCTAssertEqual(postgresql.matches.map(\.version), ["15.9"])
    }

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

    func testExplicitPackageManagerSelectionOverridesOtherToolSignalsAndMatchesMachineSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("""
        {
          "name": "web",
          "packageManager": "pnpm@9.12.2+sha512.integrity",
          "devEngines": {"packageManager": {"name": "pnpm", "version": ">=9.10 <10"}},
          "engines": {"pnpm": ">=9 <10", "npm": ">=11"}
        }
        """.utf8).write(to: root.appendingPathComponent("package.json"))
        try Data().write(to: root.appendingPathComponent("package-lock.json"))
        try Data().write(to: root.appendingPathComponent("pnpm-lock.yaml"))

        let analysis = ProjectRequirementsScanner().scan(
            projectRoot: root,
            machineSnapshot: snapshot(packageManagers: [
                packageManager(id: "pnpm", version: "9.12.2"),
                packageManager(id: "npm", version: "11.5.2"),
            ])
        )

        let requirement = try XCTUnwrap(analysis.requirements.first { $0.capability == "pnpm" })
        XCTAssertEqual(analysis.requirements.map(\.capability), ["pnpm"])
        XCTAssertEqual(requirement.declarations.map(\.field), [
            "engines.pnpm", "packageManager", "devEngines.packageManager.version", "pnpm-lock.yaml",
        ])
        XCTAssertEqual(requirement.declarations.map(\.expression), [">=9 <10", "9.12.2", ">=9.10 <10", "*"])
        XCTAssertEqual(requirement.satisfaction, .satisfied)
        XCTAssertEqual(requirement.matches.map(\.path), ["/tools/pnpm"])
        XCTAssertEqual(analysis.notices.map(\.message), ["已按 pnpm 声明忽略其他包管理器线索：npm"])
    }

    func testLockFilesAndUVRequirementsUsePackageManagerAvailabilityWithoutInventingComponents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["api", "uv-explicit", "web", "broken", "ambiguous", "mixed", "orphan"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path),
                withIntermediateDirectories: true
            )
        }
        try Data("[project]\nname = \"api\"\n[tool.uv]\nrequired-version = \">=0.8 <0.9\"\n".utf8)
            .write(to: root.appendingPathComponent("api/pyproject.toml"))
        try Data().write(to: root.appendingPathComponent("api/uv.lock"))
        try Data("[project]\nname = \"tool\"\n[tool.uv]\nrequired-version = \">=0.8 <0.9\"\n".utf8)
            .write(to: root.appendingPathComponent("uv-explicit/pyproject.toml"))
        try Data("{\"name\":\"web\"}".utf8).write(to: root.appendingPathComponent("web/package.json"))
        try Data().write(to: root.appendingPathComponent("web/yarn.lock"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("broken/package.json"))
        try Data().write(to: root.appendingPathComponent("broken/bun.lock"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("ambiguous/package.json"))
        try Data().write(to: root.appendingPathComponent("ambiguous/package-lock.json"))
        try Data().write(to: root.appendingPathComponent("ambiguous/pnpm-lock.yaml"))
        try Data("{\"engines\":{\"npm\":\">=11\"}}".utf8)
            .write(to: root.appendingPathComponent("mixed/package.json"))
        try Data().write(to: root.appendingPathComponent("mixed/pnpm-lock.yaml"))
        try Data().write(to: root.appendingPathComponent("orphan/yarn.lock"))

        let analysis = ProjectRequirementsScanner().scan(
            projectRoot: root,
            machineSnapshot: snapshot(packageManagers: [
                packageManager(id: "uv", version: "0.8.14"),
                packageManager(id: "yarn", version: nil, state: .configured),
                packageManager(id: "bun", version: nil, state: .failed),
            ])
        )

        XCTAssertEqual(analysis.components.map(\.relativePath), ["ambiguous", "api", "broken", "mixed", "uv-explicit", "web"])
        XCTAssertEqual(analysis.components.first { $0.relativePath == "api" }?.requirements.map(\.field), [
            "tool.uv.required-version", "uv.lock",
        ])
        XCTAssertEqual(analysis.requirements.first { $0.capability == "uv" }?.satisfaction, .satisfied)
        XCTAssertEqual(
            analysis.components.first { $0.relativePath == "uv-explicit" }?.requirements.map(\.field),
            ["tool.uv.required-version"]
        )
        XCTAssertEqual(analysis.requirements.first { $0.capability == "yarn" }?.satisfaction, .satisfied)
        XCTAssertEqual(analysis.requirements.first { $0.capability == "yarn" }?.matches.first?.version, "版本无法判断")
        XCTAssertEqual(analysis.requirements.first { $0.capability == "bun" }?.satisfaction, .undetermined)
        XCTAssertFalse(analysis.requirements.contains { $0.capability == "npm" || $0.capability == "pnpm" })
        XCTAssertTrue(analysis.notices.contains {
            $0.relativePath == "ambiguous"
                && $0.message == "包管理器线索互相矛盾，无法判断：npm、pnpm"
        })
        XCTAssertTrue(analysis.notices.contains {
            $0.relativePath == "mixed"
                && $0.message == "包管理器线索互相矛盾，无法判断：npm、pnpm"
        })
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

        let analysis = ProjectRequirementsScanner().scan(
            projectRoot: root,
            machineSnapshot: snapshot(python: [runtimeInstallation(path: "/opt/python", version: "3.11.9")])
        )

        XCTAssertEqual(analysis.components.first { $0.relativePath == "api" }?.summary, .satisfied)
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
        XCTAssertEqual(analysis.components.first { $0.relativePath == "compose" }?.requirements.count, 2)
        XCTAssertEqual(analysis.components.first { $0.relativePath == "compose" }?.requirements.last?.capability, "postgresql")
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

    func testRequirementsInDatabaseRequirementRecalculatesFromMachineSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent("requirements.in")
        try Data("redis==5.0.0\n".utf8).write(to: manifest)
        let scanner = ProjectRequirementsScanner()

        let missing = scanner.scan(
            projectRoot: root,
            machineSnapshot: snapshot(databases: [databaseOverview(id: "redis", state: .notFound)])
        )

        let requirement = try XCTUnwrap(missing.components.first?.requirements.first)
        XCTAssertEqual(requirement.capability, "redis")
        XCTAssertEqual(requirement.expression, "*")
        XCTAssertEqual(requirement.field, "dependency.redis")
        XCTAssertEqual(requirement.satisfaction, .unsatisfied)

        try FileManager.default.removeItem(at: manifest)
        let recalculated = scanner.recalculate(
            missing,
            machineSnapshot: snapshot(databases: [databaseOverview(
                id: "redis",
                installations: [databaseInstallation(path: "/opt/redis-server", version: "7.4.1")]
            )])
        )

        XCTAssertEqual(recalculated.summary, .satisfied)
        XCTAssertEqual(recalculated.components.first?.requirements.first?.matches.first?.path, "/opt/redis-server")
        XCTAssertEqual(scanner.scan(projectRoot: root, machineSnapshot: snapshot()).summary, .undeclared)
    }

    func testDirectDatabaseDependenciesAcrossSupportedLanguagesUseExactUnconditionalPackages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifests: [(String, String, String)] = [
            ("node", "package.json", #"{"dependencies":{"pg":"8","redis-tool":"1"},"devDependencies":{"mongoose":"9"},"optionalDependencies":{"redis":"5"},"peerDependencies":{"mysql2":"3"}}"#),
            ("python", "pyproject.toml", """
            [project]
            dependencies = [
                "psycopg[binary]>=3",
                "motor",
                "SQLAlchemy",
            ]
            [project.optional-dependencies]
            cache = ["redis"]
            [tool.poetry.dependencies]
            python = ">=3.12"
            pymysql = "1"
            conditional = { version = "1", markers = "sys_platform == 'linux'" }
            [tool.poetry.group.test.dependencies]
            redis = "5"
            [tool.poetry.dev-dependencies]
            mongoengine = "1"
            """),
            ("go", "go.mod", """
            module example.test/db
            go 1.23
            require (
              github.com/jackc/pgx/v5 v5.7.0
              github.com/go-sql-driver/mysql v1.9.0
              github.com/redis/go-redis/v9 v9.7.0 // indirect
            )
            """),
            ("java", "pom.xml", """
            <project><dependencyManagement><dependencies><dependency><groupId>org.mongodb</groupId><artifactId>mongodb-driver-sync</artifactId></dependency></dependencies></dependencyManagement><dependencies>
              <dependency><groupId>org.postgresql</groupId><artifactId>postgresql</artifactId></dependency>
              <dependency><groupId>redis.clients</groupId><artifactId>jedis</artifactId><scope>test</scope></dependency>
              <dependency><groupId>org.mariadb.jdbc</groupId><artifactId>mariadb-java-client</artifactId><optional>true</optional></dependency>
            </dependencies><build><plugins><plugin><dependencies>
              <dependency><groupId>org.redisson</groupId><artifactId>redisson</artifactId></dependency>
            </dependencies></plugin></plugins></build></project>
            """),
            ("gradle", "build.gradle.kts", """
            dependencies {
              implementation("org.mongodb:mongodb-driver-sync:5.0.0")
              testRuntimeOnly("com.mysql:mysql-connector-j:9.0.0")
              implementation(project(":redis"))
              if (enableRedis) {
                implementation("redis.clients:jedis:5.0.0")
              }
            }
            """),
            ("rust", "Cargo.toml", """
            [package]
            name = "db"
            version = "1.0.0"
            [dependencies]
            postgres = "0.19"
            redis = { version = "0.27", optional=true }
            [dev-dependencies]
            mongodb = "3"
            [target.'cfg(unix)'.dependencies]
            mysql = "25"
            """),
            ("ruby", "Gemfile", """
            gem "pg"
            group :development, :test do
              gem "redis"
            end
            if ENV["MONGO"]
              gem "mongo"
            end
            group :production do
              gem "mongoid"
            end
            """),
            ("lua", "db.rockspec", """
            package = "db"
            version = "1.0-1"
            dependencies = { "luasql-postgres >= 2" }
            test_dependencies = { "lua-resty-redis >= 0.3" }
            """),
        ]
        for (directoryName, fileName, contents) in manifests {
            let directory = root.appendingPathComponent(directoryName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: directory.appendingPathComponent(fileName))
        }

        let analysis = ProjectRequirementsScanner().scan(projectRoot: root, machineSnapshot: snapshot())
        func databaseCapabilities(_ component: String) -> [String] {
            analysis.components.first { $0.relativePath == component }?.requirements
                .map(\.capability).filter { ["postgresql", "mysql-compatible", "mongodb", "redis"].contains($0) }
                .sorted() ?? []
        }

        XCTAssertEqual(databaseCapabilities("node"), ["mongodb", "postgresql"])
        XCTAssertEqual(databaseCapabilities("python"), ["mongodb", "mongodb", "mysql-compatible", "postgresql", "redis"])
        XCTAssertEqual(databaseCapabilities("go"), ["mysql-compatible", "postgresql"])
        XCTAssertEqual(databaseCapabilities("java"), ["postgresql", "redis"])
        XCTAssertEqual(databaseCapabilities("gradle"), ["mongodb", "mysql-compatible"])
        XCTAssertEqual(databaseCapabilities("rust"), ["mongodb", "postgresql"])
        XCTAssertEqual(databaseCapabilities("ruby"), ["postgresql", "redis"])
        XCTAssertEqual(databaseCapabilities("lua"), ["postgresql", "redis"])
    }

    func testDatabaseToolAndComposeDeclarationsUseAliasesPrecedenceProfilesAndVersionSemantics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("package.json"))
        try Data("postgres 16\nmongo latest\n".utf8).write(to: root.appendingPathComponent(".tool-versions"))
        try Data("[tools]\nmariadb = \"11.4\"\n".utf8).write(to: root.appendingPathComponent("mise.toml"))
        try Data("""
        services:
          pg:
            image: registry.example/team/postgres:16-alpine
          cache:
            image: redis:7.2.4
          dynamic-tag:
            image: postgres:${POSTGRES_TAG}
          dynamic-repository:
            image: ${POSTGRES_IMAGE}:16
          optional:
            image: mongo:7
            profiles: [debug]
          variant:
            image: postgis/postgis:16
        """.utf8).write(to: root.appendingPathComponent("compose.yaml"))
        try Data("services:\n  ignored:\n    image: mysql:8\n".utf8)
            .write(to: root.appendingPathComponent("docker-compose.yml"))

        let analysis = ProjectRequirementsScanner().scan(
            projectRoot: root,
            machineSnapshot: snapshot(databases: [
                databaseOverview(id: "postgresql", installations: [databaseInstallation(path: "/opt/postgres", version: "16.4")]),
                databaseOverview(id: "mongodb", installations: [databaseInstallation(path: "/opt/mongod", version: nil)]),
                databaseOverview(id: "redis", installations: [databaseInstallation(path: "/opt/redis", version: "7.2.4", listening: .listening)]),
                databaseOverview(id: "mariadb", installations: [databaseInstallation(path: "/opt/mariadbd", version: "11.4.2")]),
            ])
        )
        let requirements = try XCTUnwrap(analysis.components.first?.requirements)

        XCTAssertEqual(requirements.filter { $0.capability == "postgresql" }.count, 3)
        XCTAssertTrue(requirements.filter { $0.capability == "postgresql" }.allSatisfy { $0.satisfaction == .satisfied })
        XCTAssertEqual(requirements.first { $0.field == "services.dynamic-tag.image" }?.expression, "*")
        XCTAssertFalse(requirements.contains { $0.field == "services.dynamic-repository.image" })
        XCTAssertEqual(requirements.first { $0.capability == "mongodb" }?.expression, "*")
        XCTAssertEqual(requirements.first { $0.capability == "mongodb" }?.satisfaction, .satisfied)
        XCTAssertEqual(requirements.first { $0.capability == "redis" }?.expression, "7.2.4")
        XCTAssertEqual(requirements.first { $0.capability == "redis" }?.matches.first?.listeningState, .listening)
        XCTAssertEqual(requirements.first { $0.capability == "mariadb" }?.satisfaction, .satisfied)
        XCTAssertFalse(requirements.contains { $0.capability == "mysql" })
        XCTAssertEqual(requirements.filter { $0.capability == "mongodb" }.count, 1)
    }

    func testDatabaseCompatibilityConflictDiscoveryAndListeningStatesStayDistinct() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"dependencies":{"mysql2":"3","redis":"5"}}"#.utf8)
            .write(to: root.appendingPathComponent("package.json"))
        try Data("""
        services:
          first:
            image: postgres:15
          second:
            image: postgres:16
          mysql:
            image: mysql:8
        """.utf8).write(to: root.appendingPathComponent("compose.yaml"))

        let analysis = ProjectRequirementsScanner().scan(
            projectRoot: root,
            machineSnapshot: snapshot(databases: [
                databaseOverview(id: "postgresql", state: .notFound),
                databaseOverview(id: "mysql", state: .notFound),
                databaseOverview(id: "mariadb", installations: [databaseInstallation(path: "/opt/mariadbd", version: "11.4")]),
                databaseOverview(id: "redis", installations: [databaseInstallation(path: "/opt/redis", version: nil)]),
            ])
        )
        let requirements = try XCTUnwrap(analysis.components.first?.requirements)

        XCTAssertTrue(requirements.filter { $0.capability == "postgresql" }.allSatisfy { $0.satisfaction == .declarationConflict })
        XCTAssertEqual(requirements.first { $0.capability == "mysql-compatible" }?.satisfaction, .satisfied)
        XCTAssertEqual(requirements.first { $0.capability == "mysql" }?.satisfaction, .unsatisfied)
        XCTAssertEqual(requirements.first { $0.capability == "redis" }?.satisfaction, .satisfied)
        XCTAssertEqual(requirements.first { $0.capability == "redis" }?.matches.first?.version, "版本不可读")

        let unknown = ProjectRequirementsScanner().scan(
            projectRoot: root,
            machineSnapshot: snapshot(databases: [
                databaseOverview(id: "postgresql", installations: [databaseInstallation(path: "/broken/postgres", version: nil)]),
                databaseOverview(id: "mysql", state: .unknown),
                databaseOverview(id: "mariadb", state: .notFound),
                databaseOverview(id: "redis", state: .unknown),
            ])
        )
        XCTAssertEqual(unknown.components[0].requirements.first { $0.capability == "mysql" }?.satisfaction, .undetermined)
        XCTAssertTrue(unknown.components[0].requirements.first { $0.capability == "mysql" }?.evidence
            .contains { $0.contains("发现状态未知") } == true)
    }

    func testDatabaseUnknownVersionsDiscoveryAndListeningEvidenceDoNotConflateStates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"dependencies":{"redis":"5"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        try Data("redis\n".utf8).write(to: root.appendingPathComponent("requirements.txt"))
        try Data("""
        services:
          postgres:
            image: postgres:16
          mysql:
            image: mysql
          maria:
            image: mariadb:latest
          mongo:
            image: mongo@sha256:deadbeef
        """.utf8).write(to: root.appendingPathComponent("compose.yaml"))
        let scanner = ProjectRequirementsScanner()

        let analysis = scanner.scan(projectRoot: root, machineSnapshot: snapshot(databases: [
            databaseOverview(id: "postgresql", installations: [databaseInstallation(path: "/broken/postgres", version: nil)]),
            databaseOverview(id: "mysql", installations: [databaseInstallation(path: "/opt/mysql", version: nil)]),
            databaseOverview(id: "mariadb", installations: [databaseInstallation(path: "/opt/maria", version: nil)]),
            databaseOverview(id: "mongodb", installations: [databaseInstallation(path: "/opt/mongo", version: nil)]),
            databaseOverview(id: "redis", installations: [databaseInstallation(path: "/opt/redis", version: "7.4", listening: .unknown)]),
        ]))
        let requirements = try XCTUnwrap(analysis.components.first?.requirements)

        XCTAssertEqual(requirements.first { $0.capability == "postgresql" }?.satisfaction, .undetermined)
        XCTAssertTrue(requirements.filter { ["mysql", "mariadb", "mongodb"].contains($0.capability) }
            .allSatisfy { $0.expression == "*" && $0.satisfaction == .satisfied })
        XCTAssertEqual(requirements.first { $0.capability == "redis" }?.matches.first?.listeningState, .unknown)
        XCTAssertEqual(requirements.filter { $0.capability == "redis" }.count, 1)

        let mismatch = scanner.recalculate(analysis, machineSnapshot: snapshot(databases: [
            databaseOverview(id: "postgresql", installations: [databaseInstallation(path: "/opt/postgres15", version: "15.9")]),
            databaseOverview(id: "mysql", state: .notFound),
            databaseOverview(id: "mariadb", state: .notFound),
            databaseOverview(id: "mongodb", state: .notFound),
            databaseOverview(id: "redis", installations: [databaseInstallation(path: "/opt/redis", version: "7.4")]),
        ]))
        XCTAssertEqual(mismatch.components[0].requirements.first { $0.capability == "postgresql" }?.satisfaction, .unsatisfied)
        XCTAssertEqual(mismatch.components[0].requirements.first { $0.capability == "redis" }?.satisfaction, .satisfied)

        let insufficient = scanner.recalculate(analysis, machineSnapshot: snapshot(databases: []))
        XCTAssertTrue(insufficient.components[0].requirements.filter {
            ["postgresql", "mysql", "mariadb", "mongodb", "redis"].contains($0.capability)
        }.allSatisfy { $0.satisfaction == .undetermined })
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

    private func databaseInstallation(
        path: String,
        version: String?,
        listening: DatabaseListeningState = .notListening
    ) -> DatabaseInstallation {
        DatabaseInstallation(
            id: path,
            executable: path,
            actualExecutable: nil,
            version: version,
            error: version == nil ? "unreadable" : nil,
            sources: [.homebrew],
            homebrewFormula: nil,
            listeningState: listening
        )
    }

    private func databaseOverview(
        id: String,
        installations: [DatabaseInstallation] = [],
        state: DatabaseDiscoveryState = .discovered
    ) -> DatabaseInstallationOverview {
        DatabaseInstallationOverview(
            id: id,
            name: id,
            installations: installations,
            discoveryState: state,
            listeningState: installations.contains { $0.listeningState == .listening } ? .listening : .notListening
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
        gitVersion: String? = nil,
        databases: [DatabaseInstallationOverview] = [],
        packageManagers: [PackageManagerSnapshot] = []
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
            databaseInstallationOverviews: databases,
            homebrew: HomebrewSnapshot(executable: nil, version: nil, available: false, error: nil),
            packageManagers: packageManagers,
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

    private func packageManager(
        id: String,
        version: String?,
        state: PackageManagerState = .available
    ) -> PackageManagerSnapshot {
        PackageManagerSnapshot(
            id: id,
            name: id,
            executable: "/tools/\(id)",
            actualExecutable: nil,
            version: version,
            state: state,
            error: state == .failed ? "版本读取失败" : nil
        )
    }
}
