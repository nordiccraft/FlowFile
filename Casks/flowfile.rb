cask "flowfile" do
  version "1.0.4"
  sha256 "885ae225dfc204fb3db39e18815d412f183f97b58fd4a31f695164637446855f"

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
