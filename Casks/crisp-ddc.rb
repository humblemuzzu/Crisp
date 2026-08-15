# Homebrew cask for this fork.
#
# TEMPLATE. The `sha256` line below is a placeholder, not a real hash: there is
# no published release to hash yet. Homebrew will refuse to install this file as
# it stands, which is deliberate — a plausible-looking wrong hash is worse than
# an obviously missing one.
#
# `scripts/release.sh … --publish` rewrites the `version` and `sha256` lines
# from the DMG it just uploaded. docs/RELEASING.md documents the whole step,
# including how to serve this cask from a tap (Homebrew 4.6.4 removed installing
# a cask from a file path: Homebrew/brew#18371).
cask "crisp-ddc" do
  version "1.4.1"
  sha256 "REPLACE_WITH_DMG_SHA256_AT_RELEASE_TIME"

  url "https://github.com/humblemuzzu/Crisp/releases/download/v#{version}/Crisp.dmg"
  name "Crisp (DDC fork)"
  desc "Menu-bar control of an external monitor over DDC/CI"
  homepage "https://github.com/humblemuzzu/Crisp"

  livecheck do
    url :url
    strategy :github_latest
  end

  # LSMinimumSystemVersion in the shipped Info.plist is 14.0.
  depends_on macos: ">= :sonoma"

  app "Crisp.app"

  # The bundle identifier is com.crisp.app and must stay that way: the
  # Accessibility (TCC) grant the brightness keys need is recorded against it.
  uninstall quit: "com.crisp.app"

  # Both paths are the ones the app actually writes: UserDefaults under the
  # bundle id, and ~/Library/Application Support/Crisp for the JSON state
  # (DisplayStateStore, SettingsService).
  zap trash: [
    "~/Library/Application Support/Crisp",
    "~/Library/Preferences/com.crisp.app.plist",
  ]

  caveats <<~EOS
    Everything except the F1/F2 brightness keys works with no permissions.
    Those keys need System Settings → Privacy & Security → Accessibility;
    the app's first-run guide asks for it and shows whether it actually armed.

    This is a fork of didriksg/Crisp with DDC contrast, input switching and
    per-display persistence. Upstream's own cask installs upstream Crisp,
    which does not include those.
  EOS
end
