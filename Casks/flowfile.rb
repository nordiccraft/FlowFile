cask "flowfile" do
  version "1.0.6"
  sha256 "bfcdf87f911a3f0c9164a28907be00fbd8ba2829d1a844830d3a9299451ff6d8"

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
