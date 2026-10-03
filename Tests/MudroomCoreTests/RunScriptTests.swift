import Foundation
import Testing
@testable import MudroomCore

@Suite("run.command")
struct RunScriptTests {
    @Test("odd paths and values reach mudroom intact; a failed start keeps the window in front")
    func quotingAndFailure() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
        let tmp = try TempDir()
        // Spaces, quotes, $, backslash and non-ASCII, as in an iCloud Drive path.
        let dir = tmp.path("Mobile Documents/it's \"$HOME\" \\ café — 日本")
        let out = tmp.path("out.txt")
        let cli = dir.appendingPathComponent("mudroom")
        try write("#!/bin/sh\nprintf '%s\\n' \"$@\" \"$MUDROOM_HOME\" \"${MUDROOM_BACKEND-unset}\" > \"$OUT\"\nexit 3\n", to: cli, mode: 0o755)
        let home = dir.appendingPathComponent("store $(touch pwned)").path
        let text = RunScript.text(cli: cli.path, sessionID: "20260101-000000-abcd",
                                  environment: ["MUDROOM_HOME": home, "MUDROOM_BACKEND": "", "PATH": "/x"],
                                  appBundleID: "local.test.never-opened")
        let script = tmp.path("run.command")
        try text.write(to: script, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", script.path]
        // An empty HOME, so no real ~/.zshrc is read.
        p.environment = ["HOME": tmp.url.path, "OUT": out.path, "PATH": "/usr/bin:/bin", "TERM": "dumb"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let shown = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        #expect(p.terminationStatus == 3)
        #expect(try read(out) == "start\n20260101-000000-abcd\n\(home)\nunset\n")
        #expect(!exists(dir.appendingPathComponent("pwned")) && !exists(tmp.path("pwned")))
        #expect(shown.contains("Stopped with status 3"))
        #expect(!shown.contains("You can close this window"))
        #expect(!text.contains("PATH="))
    }
}
