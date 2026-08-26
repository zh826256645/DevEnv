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

    init(
        capability: String,
        expression: String,
        relativePath: String,
        field: String,
        satisfaction: ProjectRequirementSatisfactionState = .undetermined,
        matches: [ProjectRequirementMatch] = []
    ) {
        self.capability = capability
        self.expression = expression
        self.relativePath = relativePath
        self.field = field
        self.satisfaction = satisfaction
        self.matches = matches
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
                default: break
                }
            }
            for (capability, versionFiles) in [("node", [".nvmrc", ".node-version"]), ("python", [".python-version"])] {
                for name in versionFiles where names.contains(name) {
                    if let expression = readSmallText(root.appendingPathComponent(relativePath).appendingPathComponent(name)) {
                        requirements.append(ProjectRequirement(
                            capability: capability, expression: expression, relativePath: self.relativePath(root.appendingPathComponent(relativePath).appendingPathComponent(name), from: root), field: name
                        ))
                    } else {
                        notices.append(ProjectNotice(relativePath: self.relativePath(root.appendingPathComponent(relativePath).appendingPathComponent(name), from: root), message: "清单不可读"))
                    }
                }
            }
            let localPython = discoverVenv(at: directory)
            let evaluated = evaluate(
                requirements: requirements,
                localPythonInstallations: localPython,
                machineSnapshot: machineSnapshot
            )
            let componentSummary = requirements.isEmpty && !notices.isEmpty ? .unavailable : evaluated.summary
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
            if name == "package.json" || name == "pyproject.toml" || name == ".nvmrc" || name == ".node-version" || name == ".python-version" {
                names.insert(name)
            }
        }
        if !names.isEmpty {
            result[relativePath(directory, from: root), default: []].formUnion(names)
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

    private func tomlString(_ value: String) -> String? {
        let value = value.split(separator: "#", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
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
            return (requirements.map { var value = $0; value.satisfaction = .undetermined; return value }, .undetermined)
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
                }
                continue
            }
            if capability == "packageManager" || ["npm", "yarn", "pnpm", "bun"].contains(capability) {
                for index in indices { evaluated[index].satisfaction = .undetermined }
                continue
            }
            let constraints = indices.map { StaticVersionConstraint(evaluated[$0].expression) }
            if constraints.contains(where: { $0.isUnsupported }) {
                for index in indices { evaluated[index].satisfaction = .undetermined }
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
            for index in indices {
                evaluated[index].satisfaction = state
                evaluated[index].matches = matches.map { ProjectRequirementMatch(version: $0.version, path: $0.path) }
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
        guard capability == "node" || capability == "python" else { return [] }
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
        guard capability == "node" || capability == "python" else { return false }
        if machineSnapshot.runtimes.first(where: { $0.id.lowercased() == capability })?.installations.contains(where: { $0.version == nil }) == true {
            return true
        }
        return capability == "python" && localPythonInstallations.contains { $0.version == nil }
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
        self.expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
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
