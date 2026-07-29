cask "appsift" do
  # Set to the published ZIP checksum after each release. Current customer
  # artifacts are explicitly self-signed; a future Developer ID migration
  # rewrites this URL to the notarized artifact name.
  version "1.0.5"
  sha256 "3aa8a5ed6ad9b83289432105781679ac039719d36c6da7c259b95f639bb3c822"

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
