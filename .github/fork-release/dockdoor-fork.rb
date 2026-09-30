# Cask for a DoubleGremlin181/homebrew-tap repo (Casks/dockdoor-fork.rb). It always
# installs the latest release; the app updates itself through Sparkle afterwards.
cask "dockdoor-fork" do
  version :latest
  sha256 :no_check

  url "https://github.com/DoubleGremlin181/DockDoor/releases/latest/download/DockDoor.dmg"
  name "DockDoor (Space Switcher fork)"
  desc "Dock window previews, window switcher and Space Switcher"
  homepage "https://github.com/DoubleGremlin181/DockDoor/tree/space-switcher"

  auto_updates true
  conflicts_with cask: "dockdoor"
  depends_on macos: ">= :ventura"

  app "DockDoor.app"

  zap trash: [
    "~/Library/Caches/io.github.doublegremlin181.DockDoor",
    "~/Library/HTTPStorages/io.github.doublegremlin181.DockDoor",
    "~/Library/Preferences/io.github.doublegremlin181.DockDoor.plist",
  ]

  caveats <<~EOS
    This build is not notarized, so macOS blocks the first launch.
    Open System Settings › Privacy & Security and click "Open Anyway".
  EOS
end
