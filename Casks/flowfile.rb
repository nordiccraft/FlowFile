cask "flowfile" do
  version "1.2.0"
  sha256 "c0c8ee23803e81dd09463e6b660e4daf3a546e05e2ca56ff65571706baae3db5"

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
