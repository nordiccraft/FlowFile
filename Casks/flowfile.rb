cask "flowfile" do
  version "1.0.3"
  sha256 "74203fd93f65c5c30a95b2c3e111c520e2b59b9ff1d63af21d81ce1447c5fb35"

  url "https://github.com/nordiccraft/FlowFile/releases/download/v#{version}/FlowFile-Update.zip"
  name "FlowFile"
  desc "Native macOS file explorer combining Windows Explorer and Total Commander"
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
