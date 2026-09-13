cask "virt-connector" do
  version "0.1.4"
  sha256 "12feb15357ea915ae951afc1411c1bd58c36f667bcb63a23c54b7091391280d8"

  url "https://github.com/rioriost/virt-connector/releases/download/v#{version}/VirtConnector-#{version}-signed.pkg"
  name "VirtConnector"
  desc "Link display sleep, wake, and shutdown events to Shortcuts"
  homepage "https://github.com/rioriost/virt-connector"

  depends_on macos: :ventura

  pkg "VirtConnector-#{version}-signed.pkg"

  postflight_steps do
    run "/Library/VirtConnector/bin/virt-connector",
        args:           ["restore-agent"],
        writable_paths: [
          "~/.config/virt-connector",
          "~/Library/LaunchAgents",
          "~/Library/Logs",
        ]
  end

  uninstall launchctl: "st.rio.virt-connectord",
            pkgutil:   "st.rio.virt-connector.pkg",
            delete:    [
              "/Library/VirtConnector",
              "/usr/local/bin/virt-connector",
              "/usr/local/bin/virt-connectord",
            ]

  zap trash: [
    "~/.config/virt-connector",
    "~/Library/LaunchAgents/st.rio.virt-connectord.plist",
    "~/Library/Logs/virt-connectord.err.log",
    "~/Library/Logs/virt-connectord.log",
    "~/Library/Logs/virt-connectord.out.log",
  ]

  caveats do
    files_in_usr_local
  end
end
