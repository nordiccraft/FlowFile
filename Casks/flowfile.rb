cask "flowfile" do
  version "1.0.2"
  sha256 "01b5d64fd311a5e585bcc15ec67ef3fba009a344e7c5eff575794b016cf957b7"

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
