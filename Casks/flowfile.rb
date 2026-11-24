cask "flowfile" do
  version "1.2.3"
  sha256 "d425965de2c9546ce1620a50c10c42f9e0375471eb253f0fc1f80703635cb333"

  url "https://github.com/nordiccraft/FlowFile/releases/download/v#{version}/FlowFile-Update.zip"
  name "FlowFile"
  desc "Fast native single- and dual-pane file manager for macOS"
  homepage "https://github.com/nordiccraft/FlowFile"

  app "FlowFile.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/FlowFile.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.flowfile.app.plist",
  ]
end
