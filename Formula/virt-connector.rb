class VirtConnector < Formula
  desc "Development source build linking macOS display events to Shortcuts"
  homepage "https://github.com/rioriost/Virt-Connector"
  license "MIT"
  head "https://github.com/rioriost/Virt-Connector.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on arch: :arm64
  depends_on macos: :ventura

  def install
    system "swift", "build", "-c", "release", "--triple", "arm64-apple-macosx13.0", "--disable-sandbox"
    bin.install ".build/arm64-apple-macosx/release/virt-connector"
    bin.install ".build/arm64-apple-macosx/release/virt-connectord"
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/virt-connector help")
  end
end
