cask "appsift" do
  # Set to the published ZIP checksum after each release. v1.0.7 keeps its
  # historical -self-signed URL; the next release switches to the version-only
  # asset name while the Release copy still states its signing status.
  version "1.0.7"
  sha256 "b2441a08c4c9342888a99a67532f5d9b6037c55bf1c6fbd80367e404a179121b"

  url "https://github.com/GravityPoet/AppSift/releases/download/v#{version}/AppSift-#{version}-self-signed.zip"
  name "AppSift"
  desc "Free, open-source app manager and system cleaner"
  homepage "https://github.com/GravityPoet/AppSift"

  depends_on macos: :ventura

  app "AppSift.app"

  # Refresh LaunchServices so the Dock/Launchpad icon updates immediately on
  # (re)install instead of showing a stale cached icon (issue #111).
  postflight_steps do
    run "/System/Library/Frameworks/CoreServices.framework/" \
        "Frameworks/LaunchServices.framework/Support/lsregister",
        args: ["-f", "{{appdir}}/AppSift.app"]
  end

  zap trash: [
    "~/Library/Caches/com.gravitypoet.appsift",
    "~/Library/LaunchAgents/com.gravitypoet.appsift.scheduler.plist",
    "~/Library/Preferences/com.gravitypoet.appsift.plist",
  ]
end
