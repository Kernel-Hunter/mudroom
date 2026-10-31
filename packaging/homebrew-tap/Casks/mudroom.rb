cask "mudroom" do
  version "0.6.0"
  sha256 "fd8c6d771ce78183ad454b2276693014b968b1e515e0812cf66e27ad4e914f56"

  url "https://github.com/Kernel-Hunter/mudroom/releases/download/v#{version}/Mudroom-#{version}.zip"
  name "Mudroom"
  desc "Pull-request gate for local coding agents running in Linux micro-VMs"
  homepage "https://github.com/Kernel-Hunter/mudroom"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Mudroom.app updates itself (Sparkle). `brew upgrade --cask mudroom`
  # still works when asked for by name.
  auto_updates true
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
    "~/Library/Caches/io.github.kernel-hunter.mudroom",
    "~/Library/HTTPStorages/io.github.kernel-hunter.mudroom",
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
