cask "flowfile" do
  version "1.1.1"
  sha256 "20202e331a4bb0e37cb84e0e0fbe35b4738385d4cb6830bfeb3f6a4ce35fe00e"

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
