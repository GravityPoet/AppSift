cask "appsift" do
  # Set to the published ZIP checksum after each release. Current customer
  # artifacts are explicitly self-signed; a future Developer ID migration
  # rewrites this URL to the notarized artifact name.
  version "1.0.4"
  sha256 "0ac19b0f70a455ae8bc845ed4a5d676d4d1a6400243ee300861b3241ffdad0d3"

  url "https://github.com/GravityPoet/AppSift/releases/download/v#{version}/AppSift-#{version}-self-signed.zip"
  name "AppSift"
  desc "Free, open-source app manager and system cleaner"
  homepage "https://github.com/GravityPoet/AppSift"

  depends_on macos: :ventura

  app "AppSift.app"

  # Refresh LaunchServices so the Dock/Launchpad icon updates immediately on
  # (re)install instead of showing a stale cached icon (issue #111).
  postflight do
    lsregister = "/System/Library/Frameworks/CoreServices.framework/" \
                 "Frameworks/LaunchServices.framework/Support/lsregister"
    system_command lsregister, args: ["-f", "#{appdir}/AppSift.app"]
  end

  zap trash: [
    "~/Library/Caches/com.gravitypoet.appsift",
    "~/Library/LaunchAgents/com.gravitypoet.appsift.scheduler.plist",
    "~/Library/Preferences/com.gravitypoet.appsift.plist",
  ]
end
