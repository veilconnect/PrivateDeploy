#!/usr/bin/env bash
#
# PrivateDeploy one-line installer (Linux desktop).
#
#   curl -fsSL https://github.com/veilconnect/PrivateDeploy/raw/main/install.sh | bash
#
# Downloads the latest release binary, installs it to ~/.local/bin/PrivateDeploy,
# and registers an application-menu entry. Idempotent — re-run to upgrade.
# For Windows/macOS, grab an installer from the Releases page instead.

set -euo pipefail

REPO="veilconnect/PrivateDeploy"
APP="PrivateDeploy"
BIN_DST="$HOME/.local/bin/$APP"
ICON_DST="$HOME/.local/share/icons/privatedeploy.png"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_DST="$DESKTOP_DIR/privatedeploy.desktop"

die() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "this one-line installer supports Linux only. For Windows/macOS download an installer from https://github.com/$REPO/releases"
for c in curl unzip; do command -v "$c" >/dev/null || die "'$c' is required (install it and re-run)"; done

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

echo "==> Resolving latest release of $REPO ..."
TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -oE '"tag_name"[^,]*' | head -1 | sed -E 's/.*"tag_name" *: *"([^"]+)".*/\1/')"
[ -n "$TAG" ] || die "no published release found at https://github.com/$REPO/releases — nothing to download yet"

ZIP="$APP-linux-$ARCH.zip"
BASE="https://github.com/$REPO/releases/download/$TAG"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading $ZIP ($TAG) ..."
curl -fSL --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "$TMP/$ZIP" "$BASE/$ZIP" || die "download failed: $BASE/$ZIP"

if curl -fsSL -o "$TMP/checksums.sha256" "$BASE/checksums.sha256" 2>/dev/null; then
  if (cd "$TMP" && grep -E " $ZIP\$" checksums.sha256 | sha256sum -c - >/dev/null 2>&1); then
    echo "==> checksum verified"
  else
    echo "warning: checksum could not be verified" >&2
  fi
fi

if pgrep -x "$APP" >/dev/null 2>&1; then die "$APP is running — quit it first, then re-run"; fi

unzip -oq "$TMP/$ZIP" -d "$TMP"
[ -f "$TMP/$APP" ] || die "release archive did not contain the $APP binary"

mkdir -p "$(dirname "$BIN_DST")" "$(dirname "$ICON_DST")" "$DESKTOP_DIR"
install -m 755 "$TMP/$APP" "$BIN_DST"
curl -fsSL -o "$ICON_DST" "https://github.com/$REPO/raw/main/build/appicon.png" 2>/dev/null || true

cat > "$DESKTOP_DST" <<EOF
[Desktop Entry]
Type=Application
Name=PrivateDeploy
Comment=Deploy your own VPN
Exec=$BIN_DST
Icon=$ICON_DST
Terminal=false
Categories=Network;Utility;
StartupWMClass=PrivateDeploy
EOF
command -v update-desktop-database >/dev/null && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true

# Runtime dependency: the desktop app links libwebkit2gtk-4.1 (not bundled).
if ! ldconfig -p 2>/dev/null | grep -q 'libwebkit2gtk-4.1'; then
  echo "note: libwebkit2gtk-4.1 not found. On Debian/Ubuntu install it with:" >&2
  echo "      sudo apt install libwebkit2gtk-4.1-0" >&2
fi

echo "==> Installed $APP $TAG -> $BIN_DST"
echo "    Launch it from your application menu, or run: $BIN_DST"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "    Tip: add ~/.local/bin to your PATH to run '$APP' directly." ;; esac
