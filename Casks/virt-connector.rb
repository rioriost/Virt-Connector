cask "virt-connector" do
  version "0.1.3"
  sha256 "e068117f5e110636b1a9305d24d1bee424a8e26e10c73879026c0afbb9ad60e8"

  url "https://github.com/rioriost/virt-connector/releases/download/v#{version}/VirtConnector-#{version}-signed.pkg"
  name "VirtConnector"
  desc "Link macOS display sleep, wake, and shutdown events to Shortcuts"
  homepage "https://github.com/rioriost/virt-connector"

  depends_on macos: :ventura

  pkg "VirtConnector-#{version}-signed.pkg"

  postflight do
    config_path = File.expand_path("~/.config/virt-connector/config.json")
    if File.exist?(config_path)
      begin
        require "json"
        config = JSON.parse(File.read(config_path))
        if config.fetch("enabled", true)
          system_command "/Library/VirtConnector/bin/virt-connector", args: ["install-agent"]
        end
      rescue JSON::ParserError
        nil
      end
    end
  end

  uninstall launchctl: "st.rio.virt-connectord",
            pkgutil: "st.rio.virt-connector.pkg",
            delete: [
              "/Library/VirtConnector",
              "/usr/local/bin/virt-connector",
              "/usr/local/bin/virt-connectord",
            ]

  zap trash: [
    "~/.config/virt-connector",
    "~/Library/LaunchAgents/st.rio.virt-connectord.plist",
    "~/Library/Logs/virt-connectord.log",
    "~/Library/Logs/virt-connectord.out.log",
    "~/Library/Logs/virt-connectord.err.log",
  ]

  caveats do
    files_in_usr_local
  end
end
