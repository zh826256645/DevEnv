import Foundation

enum ProjectRequirementSatisfactionState: String, Codable, Sendable {
    case satisfied
    case unsatisfied
    case undetermined
    case declarationConflict
}

enum ProjectRequirementsSummary: String, Codable, Sendable {
    case satisfied
    case unsatisfied
    case undetermined
    case declarationConflict
    case undeclared
    case unavailable
}

struct ProjectNotice: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let relativePath: String
    let message: String

    init(relativePath: String, message: String) {
        self.relativePath = relativePath
        self.message = message
        id = "\(relativePath):\(message)"
    }
}

struct ProjectRequirementMatch: Codable, Equatable, Sendable {
    let version: String
    let path: String
}

struct ProjectRequirement: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let capability: String
    let expression: String
    let relativePath: String
    let field: String
    var satisfaction: ProjectRequirementSatisfactionState
    var matches: [ProjectRequirementMatch]
    var evidence: [String]

    init(
        capability: String,
        expression: String,
        relativePath: String,
        field: String,
        satisfaction: ProjectRequirementSatisfactionState = .undetermined,
        matches: [ProjectRequirementMatch] = [],
        evidence: [String] = []
    ) {
        self.capability = capability
        self.expression = expression
        self.relativePath = relativePath
        self.field = field
        self.satisfaction = satisfaction
        self.matches = matches
        self.evidence = evidence
        id = "\(relativePath):\(field):\(capability):\(expression)"
    }
}

struct ProjectLocalRuntimeInstallation: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let executable: String
    let version: String?
    let isUsable: Bool

    init(executable: String, version: String?, isUsable: Bool) {
        self.executable = executable
        self.version = version
        self.isUsable = isUsable
        id = executable
    }
}

struct ProjectComponent: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let relativePath: String
    let title: String
    let manifestNames: [String]
    let manifestName: String?
    let requirements: [ProjectRequirement]
    let notices: [ProjectNotice]
    let localPythonInstallations: [ProjectLocalRuntimeInstallation]
    let summary: ProjectRequirementsSummary

    init(
        rootPath: String,
        relativePath: String,
        manifestNames: [String],
        displayName: String? = nil,
        requirements: [ProjectRequirement],
        notices: [ProjectNotice],
        localPythonInstallations: [ProjectLocalRuntimeInstallation] = [],
        summary: ProjectRequirementsSummary = .undeclared
    ) {
        self.relativePath = relativePath
        self.manifestNames = manifestNames.sorted()
        manifestName = displayName
        title = relativePath == "." ? "." : relativePath
        self.requirements = requirements
        self.notices = notices
        self.localPythonInstallations = localPythonInstallations
        self.summary = summary
        id = "\(rootPath)/\(relativePath)"
    }
}

struct ProjectRequirementsAnalysis: Codable, Equatable, Sendable {
    let rootPath: String
    let components: [ProjectComponent]
    let notices: [ProjectNotice]
    let summary: ProjectRequirementsSummary

    init(rootPath: String, components: [ProjectComponent], notices: [ProjectNotice] = []) {
        self.rootPath = rootPath
        self.components = components
        self.notices = notices
        guard !components.isEmpty else {
            summary = notices.isEmpty ? .undeclared : .unavailable
            return
        }
        let states = components.map(\.summary)
        if states.contains(.declarationConflict) { summary = .declarationConflict }
        else if states.contains(.unsatisfied) { summary = .unsatisfied }
        else if states.contains(.undetermined) { summary = .undetermined }
        else if states.contains(.unavailable) { summary = .unavailable }
        else if states.allSatisfy({ $0 == .undeclared }) { summary = .undeclared }
        else if states.contains(.satisfied) { summary = .satisfied }
        else { summary = .unavailable }
    }

}

/// Reads only the small, well-known project declaration files. It never executes project tools.
struct ProjectRequirementsScanner: Sendable {
    static let maxManifestBytes = 4 * 1024 * 1024
    static let excludedDirectories: Set<String> = [
        ".git", ".hg", ".svn", ".venv", "venv", "node_modules", "vendor", ".build", "build", "dist", "target"
    ]
    private static let primaryManifestNames: Set<String> = [
        "Cargo.toml", "Gemfile", "build.gradle", "build.gradle.kts", "compose.yaml", "compose.yml",
        "docker-compose.yaml", "docker-compose.yml", "go.mod", "go.work", "package.json", "pom.xml",
        "pyproject.toml", "settings.gradle", "settings.gradle.kts",
    ]
    private static let versionFileCapabilities: [String: String] = [
        ".go-version": "go", ".java-version": "java", ".lua-version": "lua", ".node-version": "node",
        ".nvmrc": "node", ".python-version": "python", ".ruby-version": "ruby",
    ]
    private static let runtimeCapabilities: Set<String> = ["node", "python", "go", "java", "rust", "ruby", "lua"]

    func scan(projectRoot: URL, machineSnapshot: MachineSnapshot? = nil) -> ProjectRequirementsAnalysis {
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        guard isDirectory(root) else {
            return ProjectRequirementsAnalysis(
                rootPath: root.path,
                components: [],
                notices: [ProjectNotice(relativePath: ".", message: "Project Root 不可用")]
            )
        }

        var manifestDirectories: [String: Set<String>] = [:]
        collectManifests(root: root, directory: root, into: &manifestDirectories)
        var components: [ProjectComponent] = []
        var rootNotices: [ProjectNotice] = []
        for relativePath in manifestDirectories.keys.sorted() {
            let directory = relativePath == "." ? root : root.appendingPathComponent(relativePath)
            let names = manifestDirectories[relativePath, default: []].sorted()
            var requirements: [ProjectRequirement] = []
            var notices: [ProjectNotice] = []
            var displayName: String?
            var hasComposeRequirement = false
            for name in names {
                let file = directory.appendingPathComponent(name)
                switch name {
                case "package.json":
                    let result = parsePackageJSON(file: file, root: root)
                    requirements.append(contentsOf: result.requirements)
                    notices.append(contentsOf: result.notices)
                    displayName = displayName ?? result.name
                case "pyproject.toml":
                    let result = parsePyProject(file: file, root: root)
                    requirements.append(contentsOf: result.requirements)
                    notices.append(contentsOf: result.notices)
                    displayName = displayName ?? result.name
                case "go.mod", "go.work":
                    let result = parseGoManifest(file: file, root: root)
                    requirements.append(contentsOf: result.requirements)
                    notices.append(contentsOf: result.notices)
                case "Cargo.toml":
                    let result = parseCargoManifest(file: file, root: root)
                    requirements.append(contentsOf: result.requirements)
                    notices.append(contentsOf: result.notices)
                case "rust-toolchain", "rust-toolchain.toml":
                    let result = parseRustToolchain(file: file, root: root)
                    requirements.append(contentsOf: result.requirements)
                    notices.append(contentsOf: result.notices)
                case "pom.xml":
                    let result = parseMaven(file: file, root: root)
                    requirements.append(contentsOf: result.requirements)
                    notices.append(contentsOf: result.notices)
                case "build.gradle", "build.gradle.kts":
                    let result = parseGradle(file: file, root: root)
                    requirements.append(contentsOf: result.requirements)
                    notices.append(contentsOf: result.notices)
                case "Gemfile":
                    let result = parseRubyManifest(file: file, root: root, gemspec: false)
                    requirements.append(contentsOf: result.requirements)
                    notices.append(contentsOf: result.notices)
                case let name where name.hasSuffix(".gemspec"):
                    let result = parseRubyManifest(file: file, root: root, gemspec: true)
                    requirements.append(contentsOf: result.requirements)
                    notices.append(contentsOf: result.notices)
                case let name where name.hasSuffix(".rockspec"):
                    let result = parseLuaRockspec(file: file, root: root)
                    requirements.append(contentsOf: result.requirements)
                    notices.append(contentsOf: result.notices)
                case ".tool-versions":
                    let result = parseToolVersions(file: file, root: root)
                    requirements.append(contentsOf: result.requirements)
                    notices.append(contentsOf: result.notices)
                case "mise.toml", ".mise.toml":
                    let result = parseMise(file: file, root: root)
                    requirements.append(contentsOf: result.requirements)
                    notices.append(contentsOf: result.notices)
                case "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml":
                    if readSmallData(file) == nil {
                        notices.append(ProjectNotice(
                            relativePath: self.relativePath(file, from: root), message: "清单不可读或超过 4 MiB"
                        ))
                    } else if !hasComposeRequirement {
                        requirements.append(ProjectRequirement(
                            capability: "docker-compose", expression: "*",
                            relativePath: self.relativePath(file, from: root), field: "compose"
                        ))
                        hasComposeRequirement = true
                    }
                case let name where Self.versionFileCapabilities[name] != nil:
                    if let expression = readSmallText(file) {
                        requirements.append(ProjectRequirement(
                            capability: Self.versionFileCapabilities[name]!, expression: expression,
                            relativePath: self.relativePath(file, from: root), field: name
                        ))
                    } else {
                        notices.append(ProjectNotice(relativePath: self.relativePath(file, from: root), message: "清单不可读"))
                    }
                default: break
                }
            }
            let localPython = discoverVenv(at: directory)
            let evaluated = evaluate(
                requirements: requirements,
                localPythonInstallations: localPython,
                machineSnapshot: machineSnapshot
            )
            let componentSummary = requirements.isEmpty && !notices.isEmpty ? .undetermined : evaluated.summary
            let component = ProjectComponent(
                rootPath: root.path,
                relativePath: relativePath,
                manifestNames: names,
                displayName: displayName,
                requirements: evaluated.requirements,
                notices: notices,
                localPythonInstallations: localPython,
                summary: componentSummary
            )
            components.append(component)
            rootNotices.append(contentsOf: notices)
        }
        return ProjectRequirementsAnalysis(rootPath: root.path, components: components, notices: rootNotices)
    }

    func recalculate(
        _ analysis: ProjectRequirementsAnalysis,
        machineSnapshot: MachineSnapshot?
    ) -> ProjectRequirementsAnalysis {
        let components = analysis.components.map { component in
            let evaluated = evaluate(
                requirements: component.requirements,
                localPythonInstallations: component.localPythonInstallations,
                machineSnapshot: machineSnapshot
            )
            return ProjectComponent(
                rootPath: analysis.rootPath,
                relativePath: component.relativePath,
                manifestNames: component.manifestNames,
                displayName: component.manifestName,
                requirements: evaluated.requirements,
                notices: component.notices,
                localPythonInstallations: component.localPythonInstallations,
                summary: component.requirements.isEmpty && !component.notices.isEmpty
                    ? .undetermined
                    : evaluated.summary
            )
        }
        return ProjectRequirementsAnalysis(
            rootPath: analysis.rootPath,
            components: components,
            notices: analysis.notices
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func collectManifests(root: URL, directory: URL, into result: inout [String: Set<String>]) {
        if directory != root && FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            return
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
        var names = Set<String>()
        for entry in entries {
            let name = entry.lastPathComponent
            if Self.primaryManifestNames.contains(name)
                || Self.versionFileCapabilities[name] != nil
                || name == "rust-toolchain" || name == "rust-toolchain.toml"
                || name == ".tool-versions" || name == "mise.toml" || name == ".mise.toml"
                || name.hasSuffix(".gemspec") || name.hasSuffix(".rockspec") {
                names.insert(name)
            }
        }
        let relative = relativePath(directory, from: root)
        let hasPrimaryManifest = names.contains(where: {
            Self.primaryManifestNames.contains($0) || $0.hasSuffix(".gemspec") || $0.hasSuffix(".rockspec")
        })
        if !names.isEmpty && (relative == "." || hasPrimaryManifest) {
            result[relative, default: []].formUnion(names)
        }
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true,
                  !Self.excludedDirectories.contains(entry.lastPathComponent) else { continue }
            collectManifests(root: root, directory: entry, into: &result)
        }
    }

    private func readSmallData(_ file: URL) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maxManifestBytes,
              let data = try? Data(contentsOf: file) else { return nil }
        return data.count <= Self.maxManifestBytes ? data : nil
    }

    private func readSmallText(_ file: URL) -> String? {
        guard let data = readSmallData(file), let value = String(data: data, encoding: .utf8) else { return nil }
        let lines = value.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.isEmpty ? nil : lines.joined(separator: " || ")
    }

    private func parsePackageJSON(file: URL, root: URL) -> (name: String?, requirements: [ProjectRequirement], notices: [ProjectNotice]) {
        let relative = relativePath(file, from: root)
        guard let data = readSmallData(file) else { return (nil, [], [ProjectNotice(relativePath: relative, message: "清单不可读或超过 4 MiB")]) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, [], [ProjectNotice(relativePath: relative, message: "package.json 格式无效")])
        }
        var requirements: [ProjectRequirement] = []
        func add(_ capability: String, _ expression: String, _ field: String) {
            requirements.append(ProjectRequirement(capability: capability, expression: expression, relativePath: relative, field: field))
        }
        if let engines = object["engines"] as? [String: Any] {
            for key in ["node", "npm", "yarn", "pnpm", "bun"] {
                if let expression = engines[key] as? String { add(key, expression, "engines.\(key)") }
            }
        }
        if let packageManager = object["packageManager"] as? String {
            let parts = packageManager.split(separator: "@", maxSplits: 1).map(String.init)
            if let first = parts.first, ["npm", "yarn", "pnpm", "bun"].contains(first) {
                add(first, parts.dropFirst().first ?? "*", "packageManager")
            } else { add("packageManager", packageManager, "packageManager") }
        }
        for key in ["os", "cpu"] {
            if let value = object[key] as? String { add(key, value, key) }
            if let values = object[key] as? [String] { add(key, values.joined(separator: " || "), key) }
        }
        return (object["name"] as? String, requirements, [])
    }

    private func parsePyProject(file: URL, root: URL) -> (name: String?, requirements: [ProjectRequirement], notices: [ProjectNotice]) {
        let relative = relativePath(file, from: root)
        guard let data = readSmallData(file), let text = String(data: data, encoding: .utf8) else {
            return (nil, [], [ProjectNotice(relativePath: relative, message: "清单不可读或超过 4 MiB")])
        }
        var requirements: [ProjectRequirement] = []
        var name: String?
        var section = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard let expression = tomlString(value) else { continue }
            if section == "project" && key == "requires-python" {
                requirements.append(ProjectRequirement(capability: "python", expression: expression, relativePath: relative, field: "project.requires-python"))
            } else if section == "tool.poetry.dependencies" && key == "python" {
                requirements.append(ProjectRequirement(capability: "python", expression: expression, relativePath: relative, field: "tool.poetry.dependencies.python"))
            } else if (section == "project" || section == "tool.poetry") && key == "name" {
                name = expression
            }
        }
        return (name, requirements, [])
    }

    private func parseGoManifest(file: URL, root: URL) -> (requirements: [ProjectRequirement], notices: [ProjectNotice]) {
        let relative = relativePath(file, from: root)
        guard let data = readSmallData(file), let text = String(data: data, encoding: .utf8) else {
            return ([], [ProjectNotice(relativePath: relative, message: "清单不可读或超过 4 MiB")])
        }
        let requirements = text.split(whereSeparator: \.isNewline).compactMap { rawLine -> ProjectRequirement? in
            let parts = rawLine.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[0] == "go" || parts[0] == "toolchain" else { return nil }
            let value = String(parts[1]).replacingOccurrences(of: "^go", with: "", options: .regularExpression)
            return ProjectRequirement(
                capability: "go", expression: ">=\(value)", relativePath: relative, field: String(parts[0])
            )
        }
        return (requirements, [])
    }

    private func parseCargoManifest(file: URL, root: URL) -> (requirements: [ProjectRequirement], notices: [ProjectNotice]) {
        let relative = relativePath(file, from: root)
        guard let data = readSmallData(file), let text = String(data: data, encoding: .utf8) else {
            return ([], [ProjectNotice(relativePath: relative, message: "清单不可读或超过 4 MiB")])
        }
        var section = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
            } else if section == "package", let separator = line.firstIndex(of: "="),
                      line[..<separator].trimmingCharacters(in: .whitespaces) == "rust-version" {
                let version = tomlString(String(line[line.index(after: separator)...])) ?? "dynamic"
                return ([ProjectRequirement(
                    capability: "rust", expression: ">=\(version)", relativePath: relative,
                    field: "package.rust-version"
                )], [])
            }
        }
        return ([], [])
    }

    private func parseRustToolchain(file: URL, root: URL) -> (requirements: [ProjectRequirement], notices: [ProjectNotice]) {
        let relative = relativePath(file, from: root)
        guard let data = readSmallData(file), let text = String(data: data, encoding: .utf8) else {
            return ([], [ProjectNotice(relativePath: relative, message: "清单不可读或超过 4 MiB")])
        }
        let expression: String?
        if file.lastPathComponent == "rust-toolchain" {
            expression = text.split(whereSeparator: \.isNewline).first.map {
                String($0.split(separator: "#", maxSplits: 1).first ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            expression = text.split(whereSeparator: \.isNewline).compactMap { rawLine -> String? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = line.firstIndex(of: "="),
                      line[..<separator].trimmingCharacters(in: .whitespaces) == "channel" else { return nil }
                return tomlString(String(line[line.index(after: separator)...])) ?? "dynamic"
            }.first
        }
        return (expression.map {
            [ProjectRequirement(capability: "rust", expression: $0, relativePath: relative, field: "toolchain.channel")]
        } ?? [], [])
    }

    private func parseMaven(file: URL, root: URL) -> (requirements: [ProjectRequirement], notices: [ProjectNotice]) {
        let relative = relativePath(file, from: root)
        guard let data = readSmallData(file) else {
            return ([], [ProjectNotice(relativePath: relative, message: "清单不可读或超过 4 MiB")])
        }
        let collector = MavenXMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse() else {
            return ([], [ProjectNotice(relativePath: relative, message: "pom.xml 格式无效")])
        }
        let fields: [(suffix: String, field: String)] = [
            (".properties.java.version", "java.version"),
            (".properties.maven.compiler.release", "maven.compiler.release"),
            (".properties.maven.compiler.source", "maven.compiler.source"),
            (".requireJavaVersion.version", "enforcer.requireJavaVersion"),
        ]
        var requirements: [ProjectRequirement] = []
        for value in collector.values {
            guard let field = fields.first(where: { value.path.hasSuffix($0.suffix) })?.field else { continue }
            requirements.append(ProjectRequirement(
                capability: "java", expression: javaMinimumExpression(value.text),
                relativePath: relative, field: field
            ))
        }
        for value in collector.compilerValues {
            requirements.append(ProjectRequirement(
                capability: "java", expression: javaMinimumExpression(value.text), relativePath: relative,
                field: value.path.hasSuffix(".release") ? "compiler.release" : "compiler.source"
            ))
        }
        if collector.values.contains(where: { $0.path.contains(".parent.") }) {
            requirements.append(ProjectRequirement(
                capability: "java", expression: "dynamic", relativePath: relative, field: "parent"
            ))
        }
        return (requirements, [])
    }

    private func parseGradle(file: URL, root: URL) -> (requirements: [ProjectRequirement], notices: [ProjectNotice]) {
        let relative = relativePath(file, from: root)
        guard let data = readSmallData(file), var text = String(data: data, encoding: .utf8) else {
            return ([], [ProjectNotice(relativePath: relative, message: "清单不可读或超过 4 MiB")])
        }
        text = text.replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .map { String($0).components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
        var requirements = regexCaptures(
            #"(?m)(?:^|[\{;])\s*languageVersion\s*(?:=\s*)?JavaLanguageVersion\.of\(\s*([0-9]+(?:\.[0-9]+){0,2})\s*\)"#,
            in: text
        ).map {
            ProjectRequirement(capability: "java", expression: ">=\($0)", relativePath: relative, field: "java.toolchain")
        }
        requirements.append(contentsOf: regexCaptures(
            #"(?:sourceCompatibility|targetCompatibility)\s*(?:=\s*)?(?:JavaVersion\.VERSION_)?[\"']?([0-9]+(?:[_.][0-9]+){0,2})[\"']?"#,
            in: text
        ).map {
            ProjectRequirement(
                capability: "java", expression: ">=\($0.replacingOccurrences(of: "_", with: "."))",
                relativePath: relative, field: "java.sourceCompatibility"
            )
        })
        if requirements.isEmpty && (text.contains("JavaLanguageVersion.of(") || text.contains("sourceCompatibility")) {
            requirements.append(ProjectRequirement(
                capability: "java", expression: "dynamic", relativePath: relative, field: "java.dynamic"
            ))
        }
        return (requirements, [])
    }

    private func parseRubyManifest(file: URL, root: URL, gemspec: Bool) -> (requirements: [ProjectRequirement], notices: [ProjectNotice]) {
        let relative = relativePath(file, from: root)
        guard let data = readSmallData(file), let text = String(data: data, encoding: .utf8) else {
            return ([], [ProjectNotice(relativePath: relative, message: "清单不可读或超过 4 MiB")])
        }
        let pattern = gemspec
            ? #"(?m)^\s*\w+\.required_ruby_version\s*=\s*[\"']([^\"']+)[\"']"#
            : #"(?m)^\s*ruby\s+[\"']([^\"']+)[\"']"#
        let field = gemspec ? "required_ruby_version" : "ruby"
        if !gemspec, text.range(of: #"\bengine\s*:"#, options: .regularExpression) != nil {
            return ([ProjectRequirement(
                capability: "ruby", expression: "dynamic", relativePath: relative, field: field
            )], [])
        }
        var requirements = regexCaptures(pattern, in: text).map {
            ProjectRequirement(capability: "ruby", expression: $0, relativePath: relative, field: field)
        }
        if requirements.isEmpty && regexCaptures(
            gemspec ? #"(?m)^\s*\w+\.(required_ruby_version)\s*="# : #"(?m)^\s*(ruby)\s+"#,
            in: text
        ).isEmpty == false {
            requirements.append(ProjectRequirement(
                capability: "ruby", expression: "dynamic", relativePath: relative, field: field
            ))
        }
        return (requirements, [])
    }

    private func parseLuaRockspec(file: URL, root: URL) -> (requirements: [ProjectRequirement], notices: [ProjectNotice]) {
        let relative = relativePath(file, from: root)
        guard let data = readSmallData(file), let rawText = String(data: data, encoding: .utf8) else {
            return ([], [ProjectNotice(relativePath: relative, message: "清单不可读或超过 4 MiB")])
        }
        let text = rawText.split(whereSeparator: \.isNewline).map {
            String($0).components(separatedBy: "--").first ?? ""
        }.joined(separator: "\n")
        let dependencyTables = regexCaptures(#"(?s)\bdependencies\s*=\s*\{([^}]*)\}"#, in: text)
        var requirements = dependencyTables.flatMap {
            regexCaptures(#"[\"']lua\s+([^\"']+)[\"']"#, in: $0)
        }.map {
            ProjectRequirement(capability: "lua", expression: $0, relativePath: relative, field: "dependencies.lua")
        }
        if requirements.isEmpty && dependencyTables.contains(where: {
            $0.range(of: #"[\"']lua(?:\s|[\"'])"#, options: .regularExpression) != nil
        }) {
            requirements.append(ProjectRequirement(
                capability: "lua", expression: "dynamic", relativePath: relative, field: "dependencies.lua"
            ))
        }
        return (requirements, [])
    }

    private func parseToolVersions(file: URL, root: URL) -> (requirements: [ProjectRequirement], notices: [ProjectNotice]) {
        let relative = relativePath(file, from: root)
        guard let data = readSmallData(file), let text = String(data: data, encoding: .utf8) else {
            return ([], [ProjectNotice(relativePath: relative, message: "清单不可读或超过 4 MiB")])
        }
        let requirements = text.split(whereSeparator: \.isNewline).compactMap { rawLine -> ProjectRequirement? in
            let line = rawLine.split(separator: "#", maxSplits: 1).first ?? ""
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { return nil }
            return ProjectRequirement(
                capability: canonicalTool(parts[0]), expression: parts.dropFirst().joined(separator: " || "),
                relativePath: relative, field: ".tool-versions.\(parts[0])"
            )
        }
        return (requirements, [])
    }

    private func parseMise(file: URL, root: URL) -> (requirements: [ProjectRequirement], notices: [ProjectNotice]) {
        let relative = relativePath(file, from: root)
        guard let data = readSmallData(file), let text = String(data: data, encoding: .utf8) else {
            return ([], [ProjectNotice(relativePath: relative, message: "清单不可读或超过 4 MiB")])
        }
        var inTools = false
        var requirements: [ProjectRequirement] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inTools = line == "[tools]"
                continue
            }
            guard inTools, let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let rawValue = String(line[line.index(after: separator)...])
            let versions: [String]
            if let version = tomlString(rawValue) {
                versions = [version]
            } else if let values = tomlStringArray(rawValue) {
                versions = values
            } else {
                continue
            }
            guard !key.isEmpty, !versions.isEmpty else { continue }
            requirements.append(ProjectRequirement(
                capability: canonicalTool(key), expression: versions.joined(separator: " || "),
                relativePath: relative, field: "mise.tools.\(key)"
            ))
        }
        return (requirements, [])
    }

    private func canonicalTool(_ name: String) -> String {
        switch name.lowercased() {
        case "node", "nodejs": "node"
        case "python": "python"
        case "go", "golang": "go"
        case "java": "java"
        case "rust": "rust"
        case "ruby": "ruby"
        case "lua": "lua"
        case "git": "git"
        default: name.lowercased()
        }
    }

    private func tomlStringArray(_ rawValue: String) -> [String]? {
        let value = tomlValueWithoutComment(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(
            of: #"^\[\s*(?:[\"'][^\"']*[\"']\s*(?:,\s*[\"'][^\"']*[\"']\s*)*)?\]$"#,
            options: .regularExpression
        ) != nil else { return nil }
        return regexCaptures(#"[\"']([^\"']*)[\"']"#, in: value)
    }

    private func tomlValueWithoutComment(_ value: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in value {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\", quote == "\"" {
                result.append(character)
                escaped = true
            } else if let currentQuote = quote {
                result.append(character)
                if character == currentQuote { quote = nil }
            } else if character == "#" {
                break
            } else {
                result.append(character)
                if character == "\"" || character == "'" { quote = character }
            }
        }
        return result
    }

    private func javaMinimumExpression(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("[") || value.hasPrefix("(")), let comma = value.firstIndex(of: ",") {
            let lower = value[value.index(after: value.startIndex) ..< comma]
            let upper = value[value.index(after: comma) ..< value.index(before: value.endIndex)]
            var terms: [String] = []
            if !lower.isEmpty { terms.append("\(value.first == "[" ? ">=" : ">")\(lower)") }
            if !upper.isEmpty { terms.append("\(value.last == "]" ? "<=" : "<")\(upper)") }
            return terms.joined(separator: " ")
        }
        return SemanticVersion(value) == nil ? value : ">=\(value)"
    }

    private func regexCaptures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func tomlString(_ value: String) -> String? {
        let value = tomlValueWithoutComment(value).trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") else { return nil }
        return String(value.dropFirst().dropLast())
    }

    private func discoverVenv(at component: URL) -> [ProjectLocalRuntimeInstallation] {
        let venv = component.appendingPathComponent(".venv", isDirectory: true)
        let config = venv.appendingPathComponent("pyvenv.cfg")
        let executable = venv.appendingPathComponent("bin/python").path
        let configExists = FileManager.default.fileExists(atPath: config.path)
        let executableExists = FileManager.default.fileExists(atPath: executable)
        guard configExists || executableExists else { return [] }
        let text = readSmallData(config).flatMap { String(data: $0, encoding: .utf8) }
        let version = text?.split(whereSeparator: \.isNewline).first { $0.lowercased().hasPrefix("version") }
            .flatMap { $0.split(separator: "=", maxSplits: 1).dropFirst().first?.trimmingCharacters(in: .whitespaces) }
            .map { String($0) }
        return [ProjectLocalRuntimeInstallation(
            executable: executable,
            version: version,
            isUsable: version != nil && FileManager.default.isExecutableFile(atPath: executable)
        )]
    }

    private func evaluate(
        requirements: [ProjectRequirement],
        localPythonInstallations: [ProjectLocalRuntimeInstallation],
        machineSnapshot: MachineSnapshot?
    ) -> (requirements: [ProjectRequirement], summary: ProjectRequirementsSummary) {
        guard !requirements.isEmpty else { return ([], .undeclared) }
        guard let machineSnapshot else {
            return (requirements.map {
                var value = $0
                value.satisfaction = .undetermined
                value.matches = []
                value.evidence = ["尚无 Machine Snapshot"]
                return value
            }, .undetermined)
        }
        var evaluated = requirements
        var groups: [String: [Int]] = [:]
        for index in evaluated.indices { groups[evaluated[index].capability, default: []].append(index) }
        for (capability, indices) in groups {
            if capability == "os" || capability == "cpu" {
                let actual = capability == "os" ? ["darwin", "macos"] : machineSnapshot.system.architecture.map { [$0, $0 == "x86_64" ? "x64" : $0] } ?? []
                let possible = indices.allSatisfy { index in
                    platformExpression(evaluated[index].expression, matches: actual)
                }
                let state: ProjectRequirementSatisfactionState = possible ? .satisfied : .unsatisfied
                for index in indices {
                    evaluated[index].satisfaction = state
                    evaluated[index].matches = possible ? [ProjectRequirementMatch(version: actual.first ?? "", path: "Machine Snapshot")] : []
                    evaluated[index].evidence = possible ? [] : ["Machine Snapshot：\(actual.joined(separator: ", "))"]
                }
                continue
            }
            if capability != "git" && !Self.runtimeCapabilities.contains(capability) {
                for index in indices {
                    evaluated[index].satisfaction = .undetermined
                    evaluated[index].matches = []
                    evaluated[index].evidence = ["Machine Environment 尚未建模 \(capability)"]
                }
                continue
            }
            let constraints = indices.map { StaticVersionConstraint(evaluated[$0].expression) }
            if constraints.contains(where: { $0.isUnsupported }) {
                for index in indices {
                    evaluated[index].satisfaction = .undetermined
                    evaluated[index].matches = []
                    evaluated[index].evidence = ["原始表达式无法静态比较"]
                }
                continue
            }
            let candidates = candidates(for: capability, machineSnapshot: machineSnapshot, localPythonInstallations: localPythonInstallations)
            let matches = candidates.filter { candidate in constraints.allSatisfy { $0.matches(candidate.version) } }
            let mathematicallyPossible = constraintsIntersectionIsPossible(constraints)
            let state: ProjectRequirementSatisfactionState = !mathematicallyPossible
                ? .declarationConflict
                : !matches.isEmpty ? .satisfied
                : hasUnknownVersionCandidate(
                    for: capability,
                    machineSnapshot: machineSnapshot,
                    localPythonInstallations: localPythonInstallations
                ) ? .undetermined : .unsatisfied
            let alternatives = discoveredEvidence(
                for: capability,
                machineSnapshot: machineSnapshot,
                localPythonInstallations: localPythonInstallations
            )
            let evidence = state == .declarationConflict
                ? indices.map {
                    "冲突声明：\(evaluated[$0].relativePath) · \(evaluated[$0].field) · \(evaluated[$0].expression)"
                } + alternatives
                : alternatives
            for index in indices {
                evaluated[index].satisfaction = state
                evaluated[index].matches = matches.map { ProjectRequirementMatch(version: $0.version, path: $0.path) }
                evaluated[index].evidence = matches.isEmpty ? evidence : []
            }
        }
        let states = evaluated.map(\.satisfaction)
        let summary: ProjectRequirementsSummary
        if states.contains(.declarationConflict) { summary = .declarationConflict }
        else if states.contains(.unsatisfied) { summary = .unsatisfied }
        else if states.contains(.undetermined) { summary = .undetermined }
        else { summary = .satisfied }
        return (evaluated, summary)
    }

    private func platformExpression(_ expression: String, matches actual: [String]) -> Bool {
        let alternatives = expression.split(separator: "|", omittingEmptySubsequences: true).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !alternatives.isEmpty else { return false }
        if alternatives.contains(where: { $0.hasPrefix("!") && actual.contains($0.dropFirst().lowercased()) }) {
            return false
        }
        let allowed = alternatives.filter { !$0.hasPrefix("!") }
        return allowed.isEmpty || allowed.contains { actual.contains($0.lowercased()) }
    }

    private func candidates(for capability: String, machineSnapshot: MachineSnapshot, localPythonInstallations: [ProjectLocalRuntimeInstallation]) -> [(version: String, path: String)] {
        if capability == "os" {
            return [(machineSnapshot.system.macOSVersion ?? "darwin", "Machine Snapshot")]
        }
        if capability == "cpu" {
            return machineSnapshot.system.architecture.map { [($0, "Machine Snapshot")] } ?? []
        }
        if capability == "git" {
            guard machineSnapshot.gitCLI.state == .available,
                  let version = machineSnapshot.gitCLI.version?.firstMatch(of: /\d+(?:\.\d+){0,2}/).map({ String($0.output) }) else { return [] }
            return [(version, machineSnapshot.gitCLI.executable ?? "Git CLI")]
        }
        guard Self.runtimeCapabilities.contains(capability) else { return [] }
        let runtime = machineSnapshot.runtimes.first { $0.id.lowercased() == capability }
        var result = runtime?.installations.compactMap { installation -> (String, String)? in
            guard installation.state == .discovered, let version = installation.version else { return nil }
            return (version, installation.executable)
        } ?? []
        if capability == "python" {
            result.append(contentsOf: localPythonInstallations.compactMap { installation in
                guard installation.isUsable, let version = installation.version else { return nil }
                return (version, installation.executable)
            })
        }
        return result
    }

    private func hasUnknownVersionCandidate(
        for capability: String,
        machineSnapshot: MachineSnapshot,
        localPythonInstallations: [ProjectLocalRuntimeInstallation]
    ) -> Bool {
        if capability == "git" {
            switch machineSnapshot.gitCLI.state {
            case .unavailable: return false
            case .failed: return true
            case .available:
                return machineSnapshot.gitCLI.version?.firstMatch(of: /\d+(?:\.\d+){0,2}/) == nil
            }
        }
        guard Self.runtimeCapabilities.contains(capability) else { return false }
        if machineSnapshot.runtimes.first(where: { $0.id.lowercased() == capability })?.installations.contains(where: { $0.version == nil }) == true {
            return true
        }
        return capability == "python" && localPythonInstallations.contains { $0.version == nil }
    }

    private func discoveredEvidence(
        for capability: String,
        machineSnapshot: MachineSnapshot,
        localPythonInstallations: [ProjectLocalRuntimeInstallation]
    ) -> [String] {
        if capability == "git" {
            let version = machineSnapshot.gitCLI.version ?? "版本不可读"
            let path = machineSnapshot.gitCLI.executable ?? "Git CLI"
            return ["\(version) · \(path) · \(machineSnapshot.gitCLI.state.rawValue)"]
        }
        var evidence = machineSnapshot.runtimes
            .first { $0.id.lowercased() == capability }?
            .installations.map {
                "\($0.version ?? "版本不可读") · \($0.executable) · \($0.state.rawValue)"
            } ?? []
        if capability == "python" {
            evidence.append(contentsOf: localPythonInstallations.map {
                "\($0.version ?? "版本不可读") · \($0.executable) · \($0.isUsable ? "project-local" : "不可用")"
            })
        }
        return evidence.isEmpty ? ["未发现相关 Machine Environment 证据"] : evidence
    }

    private func constraintsIntersectionIsPossible(_ constraints: [StaticVersionConstraint]) -> Bool {
        let candidates = constraints.flatMap(\.sampleVersions)
        return candidates.contains { candidate in constraints.allSatisfy { constraint in constraint.matches(candidate) } }
    }

    private func relativePath(_ url: URL, from root: URL) -> String {
        relativePath(url.path, from: root)
    }

    private func relativePath(_ path: String, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized != rootPath else { return "." }
        return normalized.hasPrefix(rootPath + "/") ? String(normalized.dropFirst(rootPath.count + 1)) : normalized
    }
}

private struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let precision: Int

    init?(_ text: String) {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.first == "v" { clean.removeFirst() }
        guard !clean.contains("-"), !clean.contains("+") else { return nil }
        let numbers = clean.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(numbers.count), let major = Int(numbers[0]) else { return nil }
        self.major = major
        minor = numbers.dropFirst().first.flatMap { Int($0) } ?? 0
        patch = numbers.dropFirst(2).first.flatMap { Int($0) } ?? 0
        precision = numbers.count
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

private struct StaticVersionConstraint: Sendable {
    let expression: String
    let alternatives: [[(op: String, version: SemanticVersion)]]
    let sampleVersions: [String]
    let isUnsupported: Bool

    init(_ expression: String) {
        self.expression = expression.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
            of: #"([<>=~^!]+)\s+([0-9v])"#,
            with: "$1$2",
            options: .regularExpression
        )
        let rawAlternatives = self.expression.components(separatedBy: "||")
        var parsed: [[(String, SemanticVersion)]] = []
        var samples: [String] = []
        var unsupported = false
        for raw in rawAlternatives {
            let value = raw.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { unsupported = true; continue }
            if value == "*" || value.lowercased() == "latest" || value.contains("${") || value.contains("workspace:") {
                if value != "*" { unsupported = true }
                continue
            }
            var terms: [(String, SemanticVersion)] = []
            let hyphenParts = value.components(separatedBy: " - ")
            let normalized = hyphenParts.count == 2 ? ">=\(hyphenParts[0]) <=\(hyphenParts[1])" : value
            for token in normalized.split(whereSeparator: { $0 == " " || $0 == "," }) {
                let text = String(token)
                let op: String
                let versionText: String
                if text.hasPrefix("===") { unsupported = true; continue }
                else if text.hasPrefix(">=") || text.hasPrefix("<=") || text.hasPrefix("!=") || text.hasPrefix("~=") { op = String(text.prefix(2)); versionText = String(text.dropFirst(2)) }
                else if text.hasPrefix("==") { op = "="; versionText = String(text.dropFirst(2)) }
                else if text.hasPrefix(">") || text.hasPrefix("<") || text.hasPrefix("=") { op = String(text.prefix(1)); versionText = String(text.dropFirst()) }
                else if text.hasPrefix("^") { op = "^"; versionText = String(text.dropFirst()) }
                else if text.hasPrefix("~") { op = "~"; versionText = String(text.dropFirst()) }
                else { op = "line"; versionText = text }
                if versionText.contains("x") || versionText.contains("X") || versionText.contains("*") {
                    let prefix = versionText.split(separator: ".").prefix { !["x", "X", "*"].contains(String($0)) }.joined(separator: ".")
                    guard let version = SemanticVersion(prefix) else { unsupported = true; continue }
                    terms.append((op == "!=" ? "notPrefix" : "prefix", version))
                    samples.append("\(version.major).\(version.minor).\(version.patch)")
                } else if let version = SemanticVersion(versionText) {
                    terms.append((op, version))
                    samples.append(contentsOf: [
                        "\(version.major).\(version.minor).\(version.patch)",
                        "\(version.major).\(version.minor).\(version.patch + 1)",
                        "\(version.major).\(version.minor + 1).0",
                        "\(version.major + 1).0.0",
                    ])
                } else { unsupported = true }
            }
            parsed.append(terms)
        }
        alternatives = parsed
        sampleVersions = samples + ["0.0.0", "1.0.0", "3.0.0", "6.0.0", "12.0.0", "16.0.0", "18.0.0", "20.0.0", "22.0.0", "24.0.0"]
        isUnsupported = unsupported || parsed.isEmpty
    }

    func matches(_ value: String) -> Bool {
        guard let candidate = SemanticVersion(value) else { return false }
        if expression == "*" { return true }
        return alternatives.contains { terms in
            terms.allSatisfy { term in
                switch term.0 {
                case "=": candidate == term.1
                case "line": samePrefix(candidate, term.1)
                case "!=": !samePrefix(candidate, term.1)
                case ">": candidate > term.1
                case ">=": candidate >= term.1
                case "<": candidate < term.1
                case "<=": candidate <= term.1
                case "^": candidate >= term.1 && (term.1.major > 0 ? candidate.major == term.1.major : candidate.major == 0 && candidate.minor == term.1.minor)
                case "~": candidate >= term.1 && (term.1.precision == 1 ? candidate.major == term.1.major : candidate.major == term.1.major && candidate.minor == term.1.minor)
                case "~=": candidate >= term.1 && (term.1.precision <= 2 ? candidate.major == term.1.major : candidate.major == term.1.major && candidate.minor == term.1.minor)
                case "prefix": samePrefix(candidate, term.1)
                case "notPrefix": !samePrefix(candidate, term.1)
                default: false
                }
            }
        }
    }

    private func samePrefix(_ lhs: SemanticVersion, _ rhs: SemanticVersion) -> Bool {
        if rhs.precision == 1 { return lhs.major == rhs.major }
        if rhs.precision == 2 { return lhs.major == rhs.major && lhs.minor == rhs.minor }
        return lhs == rhs
    }
}

private final class MavenXMLCollector: NSObject, XMLParserDelegate {
    private(set) var values: [(path: String, text: String)] = []
    private(set) var compilerValues: [(path: String, text: String)] = []
    private var elements: [String] = []
    private var text = ""
    private var pluginArtifactID: String?
    private var pluginValues: [(path: String, text: String)]?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "plugin", pluginValues == nil {
            pluginArtifactID = nil
            pluginValues = []
        }
        elements.append(elementName)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = (path: elements.joined(separator: "."), text: value)
        if !value.isEmpty {
            values.append(entry)
            pluginValues?.append(entry)
            if elements.suffix(2).elementsEqual(["plugin", "artifactId"]) { pluginArtifactID = value }
        }
        if elementName == "plugin", let pluginValues {
            if pluginArtifactID == "maven-compiler-plugin" {
                compilerValues.append(contentsOf: pluginValues.filter {
                    $0.path.hasSuffix(".configuration.release") || $0.path.hasSuffix(".configuration.source")
                })
            }
            self.pluginValues = nil
            pluginArtifactID = nil
        }
        elements.removeLast()
        text = ""
    }
}
