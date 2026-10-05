cask "mudroom" do
  version "0.1.0"
  sha256 "781b4b41556f33d974ee795f540c485d9c2636f5813ee9a386cfac88e7fe1e23"

  url "https://github.com/Kernel-Hunter/mudroom/releases/download/v#{version}/Mudroom-#{version}.zip"
  name "Mudroom"
  desc "Pull-request gate for local coding agents running in Linux micro-VMs"
  homepage "https://github.com/Kernel-Hunter/mudroom"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on formula: "container"
  depends_on macos: :tahoe

  app "Mudroom.app"
  binary "#{appdir}/Mudroom.app/Contents/Helpers/mudroom"

  # Mudroom is ad-hoc signed, not notarized. Without this, Gatekeeper refuses
  # to open the quarantined app.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/Mudroom.app"],
        writable_paths: ["Mudroom.app"],
        writable_base:  :appdir
  end

  zap trash: [
    "~/Library/Application Support/Mudroom",
    "~/Library/Preferences/io.github.kernel-hunter.mudroom.plist",
    "~/Library/Saved Application State/io.github.kernel-hunter.mudroom.savedState",
  ]

  caveats <<~EOS
    Mudroom is not notarized. This cask removes the quarantine flag from
    Mudroom.app so macOS will open it.

    Open Mudroom and follow the Setup window, or run Setup in a terminal:
      mudroom setup
  EOS
end
