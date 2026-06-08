#!/usr/bin/env bash
#
# install-local.sh — build PrivateDeploy and install a SINGLE desktop copy on
# this Linux machine, always to the same fixed location so upgrades overwrite in
# place instead of leaving duplicate installs behind.
#
# What it does (idempotent):
#   1. `wails build` (unless --no-build) → build/bin/PrivateDeploy
#   2. install the binary to ~/.local/bin/PrivateDeploy        (overwrite)
#   3. install the icon to   ~/.local/share/icons/privatedeploy.png
#   4. write the single      ~/.local/share/applications/privatedeploy.desktop
#   5. remove any STRAY older installs (AppImage / differently-named .desktop)
#   6. refresh the desktop database
#
# It NEVER touches the data dir (~/.config/PrivateDeploy, ~/.local/share/PrivateDeploy)
# and NEVER launches the app.
#
# Usage:
#   scripts/install-local.sh            # build + install
#   scripts/install-local.sh --no-build # reuse existing build/bin/PrivateDeploy
#   scripts/install-local.sh --uninstall# remove the install (keeps data dir)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DST="$HOME/.local/bin/PrivateDeploy"
ICON_DST="$HOME/.local/share/icons/privatedeploy.png"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_DST="$DESKTOP_DIR/privatedeploy.desktop"
APP_NAME="PrivateDeploy"

c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { c '0;32' "✓ $1"; }
warn() { c '1;33' "! $1"; }

# Remove duplicate/stray installs created by other methods (e.g. the AppImage in
# ~/Applications, or a differently-cased PrivateDeploy.desktop). Data dir is left
# untouched.
clean_strays() {
  local removed=0
  for f in "$HOME/Applications/PrivateDeploy.AppImage" \
           "$DESKTOP_DIR/PrivateDeploy.desktop"; do
    if [ -e "$f" ]; then rm -f "$f"; warn "removed stray install: $f"; removed=1; fi
  done
  # Any other PrivateDeploy binary outside our fixed path → just warn, don't delete.
  while IFS= read -r other; do
    [ "$other" = "$BIN_DST" ] && continue
    warn "another PrivateDeploy binary exists (not removed): $other"
  done < <(find "$HOME" -maxdepth 4 -name 'PrivateDeploy' -type f -executable 2>/dev/null \
             | grep -vE "/\.cache/|/build/bin/|$REPO_ROOT" || true)
  [ "$removed" -eq 0 ] && return 0 || return 0
}

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$BIN_DST" "$ICON_DST" "$DESKTOP_DST"
  clean_strays
  command -v update-desktop-database >/dev/null && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  info "uninstalled (data dir kept: ~/.config/PrivateDeploy, ~/.local/share/PrivateDeploy)"
  exit 0
fi

# 1) build
if [ "${1:-}" != "--no-build" ]; then
  command -v wails >/dev/null || { c '0;31' "wails not found in PATH"; exit 1; }
  c '1;33' "[1/5] wails build ..."
  ( cd "$REPO_ROOT" && wails build -clean >/dev/null 2>&1 ) || { c '0;31' "build failed"; exit 1; }
fi
BIN_SRC="$REPO_ROOT/build/bin/PrivateDeploy"
[ -x "$BIN_SRC" ] || { c '0;31' "binary not found: $BIN_SRC (run without --no-build)"; exit 1; }

# 2) refuse to overwrite a running instance
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  c '0;31' "PrivateDeploy is running — quit it first, then re-run."; exit 1
fi

# 3) install binary + icon
mkdir -p "$(dirname "$BIN_DST")" "$(dirname "$ICON_DST")" "$DESKTOP_DIR"
install -m755 "$BIN_SRC" "$BIN_DST"; info "binary  → $BIN_DST"
[ -f "$REPO_ROOT/build/appicon.png" ] && cp "$REPO_ROOT/build/appicon.png" "$ICON_DST" && info "icon    → $ICON_DST"

# 4) single .desktop (overwrites in place on every run — no duplicates)
cat > "$DESKTOP_DST" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=PrivateDeploy — VPN / cloud node manager
Exec=$BIN_DST
Icon=$ICON_DST
Terminal=false
Categories=Network;Utility;
StartupWMClass=$APP_NAME
EOF
info "desktop → $DESKTOP_DST"

# 5) clean strays + refresh menu
clean_strays
command -v update-desktop-database >/dev/null && update-desktop-database "$DESKTOP_DIR" 2>/dev/null && info "menu refreshed" || true

c '0;32' "Done. Single install at $BIN_DST (data dir untouched)."
