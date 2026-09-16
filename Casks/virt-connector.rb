cask "virt-connector" do
  version "0.1.6"
  sha256 "ebd0b49ab035b2ff4b26b2353a5f48e6e48a01af2a55696b3c5af9ccde5332c1"

  url "https://github.com/rioriost/virt-connector/releases/download/v#{version}/VirtConnector-#{version}-signed.pkg"
  name "VirtConnector"
  desc "Link display sleep, wake, and shutdown events to Shortcuts"
  homepage "https://github.com/rioriost/virt-connector"

  depends_on arch: :arm64
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
    "~/Library/Caches/st.rio.virt-connectord",
    "~/Library/LaunchAgents/st.rio.virt-connectord.plist",
    "~/Library/Logs/virt-connectord.err.log",
    "~/Library/Logs/virt-connectord.log",
    "~/Library/Logs/virt-connectord.out.log",
  ]

  caveats do
    files_in_usr_local
  end
end
