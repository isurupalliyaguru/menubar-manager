cask "menubar-manager" do
  version "0.1.0"
  sha256 :no_check # replaced with the real checksum by the release workflow

  url "https://github.com/isurupalliyaguru/menubar-manager/releases/download/v#{version}/MenuBarManager.zip"
  name "MenuBar Manager"
  desc "Hide menu bar icons in a dropdown so the notch stops covering them"
  homepage "https://github.com/isurupalliyaguru/menubar-manager"

  depends_on macos: ">= :sonoma"

  app "MenuBar Manager.app"

  uninstall quit: "io.github.isurupalliyaguru.MenuBarManager"

  zap trash: [
    "~/Library/Preferences/io.github.isurupalliyaguru.MenuBarManager.plist",
  ]

  caveats <<~EOS
    MenuBar Manager is not notarized yet. If macOS says it "can't be opened",
    open System Settings > Privacy & Security and click "Open Anyway".

    On first launch, grant Accessibility (required) and Screen Recording
    (optional, shows real icons) in System Settings > Privacy & Security.
  EOS
end
