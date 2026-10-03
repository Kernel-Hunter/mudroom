import Foundation

/// The `run.command` file the app opens in Terminal to run `mudroom start`.
public enum RunScript {
    /// Variables passed on to the script, so the session uses the same
    /// store, token store and backend as the app.
    public static let passedVariables = ["MUDROOM_HOME", "MUDROOM_TOKEN_STORE", "MUDROOM_BACKEND", "MUDROOM_OCI_RUNTIME"]

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// - Parameters:
    ///   - cli: the `mudroom` tool.
    ///   - environment: the app's environment; only `passedVariables` are used.
    ///   - appBundleID: brought to the front once the agent is done.
    public static func text(cli: String, sessionID: String, environment: [String: String], appBundleID: String) -> String {
        var env = ""
        for name in passedVariables {
            if let v = environment[name], !v.isEmpty {
                env += "export \(name)=\(shellQuote(v))\n"
            }
        }
        // When `mudroom start` fails (runtime gone, not signed in...) the
        // window stays in front with the reason; bringing Mudroom up would
        // hide it behind a session that just says "Not started". An agent's
        // own non-zero exit lands here too, so the text covers both.
        return """
        #!/bin/zsh -l
        # Written by Mudroom.app: runs the agent for session \(sessionID).
        # A login shell, plus ~/.zshrc, so PATH and API keys match your usual terminal.
        [[ -f ~/.zshrc ]] && source ~/.zshrc >/dev/null 2>&1
        \(env)clear
        \(shellQuote(cli)) start \(shellQuote(sessionID))
        rc=$?
        echo
        if [[ $rc -eq 0 ]]; then
          echo "Review the changes in Mudroom. You can close this window."
          open -b \(shellQuote(appBundleID)) 2>/dev/null
        else
          echo "Stopped with status $rc. If the agent didn't get to run, fix the problem above, then"
          echo "start the session again from Mudroom (right-click it in the sidebar). Otherwise review"
          echo "the changes in Mudroom."
        fi
        exit $rc

        """
    }
}
