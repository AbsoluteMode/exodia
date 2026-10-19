import Foundation

enum OpenCodeEnvironment {
    // WHY: .project-docs/decisions/2026-10-19-api-and-models.md
    /// Separate OpenCode config, history, snapshots and caches for every project.
    /// The user's HOME remains intact for ordinary tools, but unrelated CLI
    /// credentials and global Claude memories are never imported by this runtime.
    /// `key` is the Keychain key of `provider`, set after the inherited
    /// provider variables are dropped, so a parent's key never reaches OpenCode.
    static func make(workingDirectory: URL, model: String, provider: OpenCodeModelProvider = .openRouter,
                     key: String?, allowActions: Bool,
                     modelSpec: OpenCodeModelSpec? = nil,
                     caseMCPCommand: [String]? = nil,
                     inherited: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
        var env = inherited.filter { name, _ in
            !name.hasPrefix("OPENCODE_") && !name.hasPrefix("OPENROUTER_")
                && !name.hasPrefix("ANTHROPIC_") && !name.hasPrefix("OPENAI_")
                && !name.hasPrefix("GOOGLE_") && !name.hasPrefix("GEMINI_")
                && !name.hasPrefix("XDG_")
        }
        let runtime = workingDirectory.appendingPathComponent(".opencode-runtime", isDirectory: true)
        for (name, folder) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                               ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache")] {
            let dir = runtime.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            env[name] = dir.path
        }
        env[provider.keyEnvironmentName] = key
        env["OPENCODE_DISABLE_CLAUDE_CODE"] = "true"
        env["OPENCODE_DISABLE_AUTOUPDATE"] = "true"
        env["OPENCODE_DISABLE_DEFAULT_PLUGINS"] = "true"
        env["OPENCODE_DISABLE_LSP_DOWNLOAD"] = "true"
        env["OPENCODE_DISABLE_TERMINAL_TITLE"] = "true"
        let normalized = normalizeModel(model)
        // Secrets stay in the child's environment, not a JSON credential file.
        // Declaring the selected model also supports fresh models that have not
        // reached OpenCode's models.dev cache yet; the catalog limits keep
        // OpenCode from treating such a model's context as 0.
        var permissions: [String: String] = allowActions
            ? ["*": "allow", "question": "deny"]
            : ["*": "deny", "read": "allow", "glob": "allow", "grep": "allow", "webfetch": "allow"]
        // Case MCP only lists project and key names, so it stays usable with
        // actions off; running commands still follows the bash permission.
        if caseMCPCommand != nil { permissions["case_*"] = "allow" }
        let declaration: [String: Any] = modelSpec.map {
            ["tool_call": $0.toolCall, "reasoning": $0.reasoning,
             "limit": ["context": $0.contextLimit, "output": $0.outputLimit]]
        } ?? [:]
        let id = provider.openCodeID
        var config: [String: Any] = [
            "$schema": "https://opencode.ai/config.json", "model": "\(id)/\(normalized)",
            "enabled_providers": [id], "share": "disabled", "autoupdate": false,
            "permission": permissions,
            "provider": [id: ["options": ["apiKey": "{env:\(provider.keyEnvironmentName)}"],
                              "models": [normalized: declaration]]]
        ]
        // Present only while the built-in agent is registered in Case; the
        // entry holds the helper path, never a value or token.
        if let caseMCPCommand {
            config["mcp"] = ["case": ["type": "local", "command": caseMCPCommand, "enabled": true]]
        }
        env["OPENCODE_CONFIG_CONTENT"] = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        return env
    }

    static func normalizeModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("openrouter/") && trimmed.split(separator: "/").count >= 3
            ? String(trimmed.dropFirst("openrouter/".count)) : trimmed
    }
}
