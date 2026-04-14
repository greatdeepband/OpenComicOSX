# Documentation: https://docs.brew.sh/Formula-Cookbook
# Homebrew Cask documentation: https://docs.brew.sh/Cask-Cookbook
#
# Usage:
#   brew install --cask --force --appdir=~/Applications przemekwiklicki/tap/open-comic
#
# NOTE: The `url` and `sha256` below are placeholders. Update them before publishing:
#   1. Host the .app somewhere (GitHub Release, your own server, etc.)
#   2. Download the .app, compute: shasum -a 256 "Open Comic.app.zip"
#   3. Replace the placeholder URL and sha256 values
#   4. Also update the version if needed (currently 0.2.0)

class OpenComic < Cask
  version "0.2.0"
  sha256 "REPLACE_WITH_ACTUAL_SHA256_OF_DOWNLOADED_APP_ZIP"

  url "https://REPLACE_WITH_YOUR_HOSTING_URL/OpenComic-#{version}.zip"
  name "Open Comic"
  desc "Native macOS comic reader — CBZ, CBR, PDF, CBT, CB7"
  homepage "https://github.com/przemekwiklicki/open-comic" # replace with actual repo URL

  app "Open Comic.app", target: "Open Comic.app"

  # Bundled tools for CBR/CB7 support
  artifact "Contents/Resources/bin/unar", target: "#{appdir}/Open Comic.app/Contents/Resources/bin/unar"
  artifact "Contents/Resources/bin/lsar", target: "#{appdir}/Open Comic.app/Contents/Resources/bin/lsar"

  zap trash: [
    "~/Library/Application Support/DC",
    "~/Library/Application Support/com.przemek.opencomic",
  ]
end
