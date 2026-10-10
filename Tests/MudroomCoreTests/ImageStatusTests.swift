#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif
import Foundation
import Testing
@testable import MudroomCore

@Suite("Agent image status")
struct ImageStatusTests {
    @Test("missing, outdated (no or other hash) and current images are told apart")
    func status() {
        #expect(AgentBaseImage.status(labels: nil) == .missing)
        #expect(AgentBaseImage.status(labels: [:]) == .outdated)
        #expect(AgentBaseImage.status(labels: [AgentBaseImage.hashLabel: "0000"]) == .outdated)
        #expect(AgentBaseImage.status(labels: [AgentBaseImage.hashLabel: AgentBaseImage.containerfileHash]) == .current)
        #expect(AgentBaseImage.containerfileHash.count == 16)
    }

    @Test("labels are found in Apple container and Docker inspect output")
    func labels() {
        let apple = #"[{"variants":[{"config":{"config":{"Labels":{"io.github.kernel-hunter.mudroom.containerfile":"abc"}}}}]}]"#
        #expect(AgentBaseImage.parseLabels(Data(apple.utf8)) == [AgentBaseImage.hashLabel: "abc"])
        #expect(AgentBaseImage.parseLabels(Data(#"[{"variants":[]}]"#.utf8)) == [:])
        #expect(AgentBaseImage.parseLabels(Data("[]".utf8)) == nil)
    }

    @Test("build progress comes from BuildKit's step counters")
    func progress() {
        #expect(AgentBaseImage.progress("#7 [3/5] RUN npm install -g ...") ?? (0, 0) == (3, 5))
        #expect(AgentBaseImage.progress("#8 [linux/arm64 stage-0 2/6] RUN npm install") ?? (0, 0) == (2, 6))
        #expect(AgentBaseImage.progress("#2 [resolver] fetching image...") == nil)
        #expect(AgentBaseImage.progress("#7 DONE 3.1s") == nil)
        #expect(AgentBaseImage.progress("[6/5]") == nil)
    }

    @Test("the new presets run in auto-approve style and are found by name")
    func presets() {
        #expect(AgentPreset.find("aider")?.command.contains("--yes-always") == true)
        #expect(AgentPreset.find("aider")?.command.contains("--no-auto-commits") == true)
        #expect(AgentPreset.find("opencode")?.command == ["opencode"])
        #expect(AgentPreset.opencode.environment["OPENCODE_DISABLE_AUTOUPDATE"] == "1")
        #expect(AgentPreset.aider.isMultiProvider && !AgentPreset.claude.isMultiProvider)
        #expect(AgentImageContains("opencode-ai") && AgentImageContains("aider-chat"))
    }

    @Test("the container version is shown short")
    func containerVersion() {
        #expect(RuntimeSetup.containerVersionLabel("container CLI version 1.5.0 (build: release, commit: unspeci)\n") == "container 1.5.0")
        #expect(RuntimeSetup.containerVersionLabel("garbage") == "container")
    }

    func AgentImageContains(_ s: String) -> Bool { AgentBaseImage.containerfile.contains(s) }
}
