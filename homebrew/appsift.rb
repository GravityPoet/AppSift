cask "appsift" do
  # Set to the published ZIP checksum by the release workflow. Until the
  # first AppSift release exists, Homebrew cannot verify a remote artifact.
  version "1.0.0"
  sha256 :no_check

  url "https://github.com/GravityPoet/AppSift/releases/download/v#{version}/AppSift-#{version}.zip"
  name "AppSift"
  desc "Free, open-source macOS app manager and system cleaner"
  homepage "https://github.com/GravityPoet/AppSift"

  depends_on macos: :ventura

  app "AppSift.app"

  # Refresh LaunchServices so the Dock/Launchpad icon updates immediately on
  # (re)install instead of showing a stale cached icon (issue #111).
  postflight do
    system_command "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
                   args: ["-f", "#{appdir}/AppSift.app"]
  end

  zap trash: [
    "~/Library/Preferences/com.gravitypoet.appsift.plist",
    "~/Library/Caches/com.gravitypoet.appsift",
    "~/Library/LaunchAgents/com.gravitypoet.appsift.scheduler.plist",
  ]
end
