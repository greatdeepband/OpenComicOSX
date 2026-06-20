# Documentation: https://docs.brew.sh/Formula-Cookbook
# Homebrew Cask documentation: https://docs.brew.sh/Cask-Cookbook
#
# Usage (once a tap exists at greatdeepband/homebrew-tap):
#   brew install --cask greatdeepband/tap/open-comic
#
# Or install directly from this file:
#   brew install --cask ./homebrew/Casks/open-comic.rb

class OpenComic < Cask
  version "0.15.2"
  sha256 "16277a56a31183cfccdd9af115e301c0958b119eb9ffcfb9b512ebee59fc1043"

  url "https://github.com/greatdeepband/OpenComicOSX/releases/download/v#{version}/OpenComic-#{version}.zip"
  name "Open Comic"
  desc "Native macOS comic reader — CBZ, CBR, PDF, CBT, CB7"
  homepage "https://github.com/greatdeepband/OpenComicOSX"

  app "OpenComic.app", target: "Open Comic.app"

  zap trash: [
    "~/Library/Application Support/DC",
    "~/Library/Application Support/com.opncomic.open-comic",
    "~/Library/Application Support/com.opencomic.open-comic",
    "~/Library/Preferences/com.opncomic.open-comic.plist",
    "~/Library/Preferences/com.opencomic.open-comic.plist",
    "~/Library/Caches/com.opncomic.open-comic",
    "~/Library/Caches/com.opencomic.open-comic",
  ]
end
