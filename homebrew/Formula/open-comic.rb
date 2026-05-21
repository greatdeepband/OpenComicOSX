# Documentation: https://docs.brew.sh/Formula-Cookbook
# Homebrew Cask documentation: https://docs.brew.sh/Cask-Cookbook
#
# Usage (once a tap exists at greatdeepband/homebrew-tap):
#   brew install --cask greatdeepband/tap/open-comic
#
# Or install directly from this file:
#   brew install --cask ./homebrew/Formula/open-comic.rb

class OpenComic < Cask
  version "0.14.0"
  sha256 "5ff98261ec6a27465ddd95566c630671711b5ed607ba11c904d0210c14ad1d25"

  url "https://github.com/greatdeepband/OpenComicOSX/releases/download/v#{version}/OpenComic-#{version}.zip"
  name "Open Comic"
  desc "Native macOS comic reader — CBZ, CBR, PDF, CBT, CB7"
  homepage "https://github.com/greatdeepband/OpenComicOSX"

  app "OpenComic.app", target: "Open Comic.app"

  zap trash: [
    "~/Library/Application Support/DC",
    "~/Library/Application Support/com.opncomic.open-comic",
    "~/Library/Preferences/com.opncomic.open-comic.plist",
  ]
end
