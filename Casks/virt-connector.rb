cask "virt-connector" do
  version "0.1.5"
  sha256 "119a3fda65fff95b8bcfbf6a0ea58f7b42de10c8b7deb71219519d64ad07ebd2"

  url "https://github.com/rioriost/virt-connector/releases/download/v#{version}/VirtConnector-#{version}-signed.pkg"
  name "VirtConnector"
  desc "Link display sleep, wake, and shutdown events to Shortcuts"
  homepage "https://github.com/rioriost/virt-connector"

  depends_on macos: :ventura

  pkg "VirtConnector-#{version}-signed.pkg"

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
