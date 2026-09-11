import Foundation

/// Native prompt hooks report readiness; terminal output and foreground PIDs cannot prove it.
final class ProjectRunShellIntegration {
    static let oscCode = 6973
    let token = UUID().uuidString
    let directory: URL
    let arguments: [String]
    let loginName: String
    let environment: [String]
    private let shell: String

    init(executable: String, environment inherited: [String: String] = ProcessInfo.processInfo.environment) throws {
        shell = URL(fileURLWithPath: executable).lastPathComponent
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("devenv-shell-\(token)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        var environment = inherited
        environment["TERM"] = "xterm-256color"
        let home = inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let quote = Self.quote
        let prompt = "\\033]\(Self.oscCode);\(token);P;%s\\007"
        let busy = "\\033]\(Self.oscCode);\(token);C\\007"
        var files: [String: String] = [:]
        switch shell {
        case "zsh":
            arguments = ["-i"]
            loginName = "-zsh"
            environment["ZDOTDIR"] = directory.path
            let dotdir = inherited["ZDOTDIR"] ?? home
            for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
                let origin = name == ".zshenv" ? quote(dotdir) : "$_devenv_zdotdir"
                let history = name == ".zshrc"
                    ? "[[ $HISTFILE == \(quote(directory.path))/.zsh_history ]] && HISTFILE=$ZDOTDIR/.zsh_history\n"
                    : ""
                files[name] = """
                ZDOTDIR=\(origin)
                \(history)[[ -r "$ZDOTDIR/\(name)" ]] && source "$ZDOTDIR/\(name)"
                _devenv_zdotdir=$ZDOTDIR
                ZDOTDIR=\(quote(directory.path))
                """
            }
            files[".zlogin", default: ""] += """

            ZDOTDIR=$_devenv_zdotdir
            unset _devenv_zdotdir
            _devenv_capture_status() { _devenv_status=$?; }
            _devenv_prompt() { builtin printf '\(prompt)' "$_devenv_status"; }
            _devenv_preexec() { builtin printf '\(busy)'; }
            precmd_functions=(_devenv_capture_status $precmd_functions _devenv_prompt)
            preexec_functions+=(_devenv_preexec)
            """
        case "bash":
            arguments = ["--rcfile", directory.appendingPathComponent("bashrc").path, "-i"]
            loginName = "bash"
            files["bashrc"] = """
            [[ -r /etc/profile ]] && source /etc/profile
            for _devenv_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
                if [[ -r "$_devenv_profile" ]]; then source "$_devenv_profile"; break; fi
            done
            unset _devenv_profile
            _devenv_prompt() { builtin printf '\(prompt)' "$_devenv_status"; }
            _devenv_old_prompt=$(printf '%s\\n' "${PROMPT_COMMAND[@]}")
            unset PROMPT_COMMAND
            PROMPT_COMMAND='_devenv_status=$?; '"$_devenv_old_prompt"$'\\n_devenv_prompt'
            unset _devenv_old_prompt
            """
        case "fish":
            arguments = ["-l", "-i", "-C", "source \(quote(directory.appendingPathComponent("fishrc").path))"]
            loginName = "fish"
            files["fishrc"] = """
            function _devenv_preexec --on-event fish_preexec
                printf '\(busy)'
            end
            function _devenv_postexec --on-event fish_postexec
                set -g _devenv_status $status
            end
            function _devenv_prompt --on-event fish_prompt
                if not set -q _devenv_status; set -g _devenv_status 0; end
                printf '\(prompt)' $_devenv_status
            end
            """
        case "sh":
            arguments = ["-i"]
            loginName = "-\(shell)"
            environment["ENV"] = directory.appendingPathComponent("env").path
            let readyPrompt = "$(printf \(quote(prompt)) \"$?\")"
            files["env"] = (inherited["ENV"].map { "[ ! -r \(quote($0)) ] || . \(quote($0))\n" } ?? "")
                + "PS1=\(quote(readyPrompt))\"${PS1:-$ }\"\n"
        default:
            try? FileManager.default.removeItem(at: directory)
            throw ProjectRunLaunchError.unsupportedInteractiveShell(shell)
        }
        self.environment = environment.map { "\($0.key)=\($0.value)" }
        do {
            for (name, text) in files {
                try Self.write(text, to: directory.appendingPathComponent(name))
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func commandInput(_ command: String, workingDirectory: String) throws -> String {
        let file = directory.appendingPathComponent("command")
        let changeDirectory = "\(shell == "sh" ? "command" : "builtin") cd \(Self.quote(workingDirectory))"
        let text = shell == "fish"
            ? "\(changeDirectory); or return $status\n\(command)\n"
            : "\(changeDirectory) || return $?\n\(command)\n"
        try Self.write(text, to: file)
        return "\(shell == "sh" ? "command ." : "builtin source") \(Self.quote(file.path))\n"
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
