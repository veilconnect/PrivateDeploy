#!/bin/bash
# Runs inside the jammy build container. Builds Linux deb/rpm against
# libwebkit2gtk-4.0 (webkit2gtk-4.0 / libsoup2) instead of 4.1.

set -euo pipefail

cd /repo

APP_NAME="privatedeploy"
APP_DISPLAY_NAME="PrivateDeploy"
VERSION="${VERSION:-2.0.0}"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.12.12}"
SINGBOX_ARCHIVE_PATH="${SINGBOX_ARCHIVE_PATH:-}"
DESCRIPTION="Private deployment tool with cloud integration and proxy management"
HOMEPAGE="https://github.com/PrivateDeploy/PrivateDeploy"
MAINTAINER="PrivateDeploy Team <team@privatedeploy.dev>"
RUNTIME_DATA_DIR="build/bin/data"

echo "==> Building PrivateDeploy ${VERSION} (jammy / webkit2_40)"

echo "==> Step 1: build frontend"
cd frontend
pnpm install --frozen-lockfile=false
pnpm run build
cd ..

echo "==> Step 2: prepare runtime data"
TMP_DIR="$(mktemp -d)"
trap "rm -rf ${TMP_DIR}" EXIT
rm -rf "${RUNTIME_DATA_DIR}"
mkdir -p "${RUNTIME_DATA_DIR}/sing-box"

ARCHIVE_PATH="${TMP_DIR}/sing-box-linux.tar.gz"
if [[ -n "${SINGBOX_ARCHIVE_PATH}" && -f "${SINGBOX_ARCHIVE_PATH}" ]]; then
    echo "  -> using provided archive: ${SINGBOX_ARCHIVE_PATH}"
    cp "${SINGBOX_ARCHIVE_PATH}" "${ARCHIVE_PATH}"
else
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"
    echo "  -> downloading sing-box ${SINGBOX_VERSION}"
    curl -LfsS "${URL}" -o "${ARCHIVE_PATH}"
fi
tar -xzf "${ARCHIVE_PATH}" -C "${TMP_DIR}"
SINGBOX_BIN="$(find "${TMP_DIR}" -name 'sing-box' -type f | head -1)"
cp "${SINGBOX_BIN}" "${RUNTIME_DATA_DIR}/sing-box/sing-box"
chmod +x "${RUNTIME_DATA_DIR}/sing-box/sing-box"

if [[ -d "data/.cache" ]]; then
    mkdir -p "${RUNTIME_DATA_DIR}/.cache"
    cp -a "data/.cache/." "${RUNTIME_DATA_DIR}/.cache/"
fi

cat > "${RUNTIME_DATA_DIR}/README.txt" <<'EOF'
PrivateDeploy Runtime Data
=========================
Linux sing-box binary bundled with the desktop app.
EOF

echo "==> Step 3: wails build (webkit2_40)"
GOOS=linux GOARCH=amd64 wails build \
    -m -s -trimpath -skipbindings \
    -devtools -tags webkit2_40 \
    -ldflags "-X privatedeploy/bridge.AppVersion=v${VERSION}" \
    -o "${APP_DISPLAY_NAME}"

echo "==> Step 4: stage package layout"
STAGING_DIR="/tmp/${APP_NAME}-packaging"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"/{usr/bin,usr/lib/${APP_NAME},usr/lib/${APP_NAME}/lib,usr/share/applications,usr/share/pixmaps}

cp "build/bin/${APP_DISPLAY_NAME}" "${STAGING_DIR}/usr/lib/${APP_NAME}/${APP_NAME}.bin"
chmod +x "${STAGING_DIR}/usr/lib/${APP_NAME}/${APP_NAME}.bin"

# Bundle the full transitive .so closure of libwebkit2gtk-4.0 (minus glibc /
# kernel-level libs that must match the host kernel) so the binary can run
# on noble without dragging in noble's libxml2 / libicu74 / etc.
echo "  -> computing transitive .so closure for webkit2gtk-4.0"
EXCLUDE='ld-linux|libc\.so\.6|libdl\.so|libpthread\.so|libm\.so\.6|librt\.so|libnsl\.so|libresolv\.so|linux-vdso'
ldd /usr/lib/x86_64-linux-gnu/libwebkit2gtk-4.0.so.37 2>&1 \
    | awk '/=>/ && $3 ~ /^\// {print $3}' \
    | grep -vE "${EXCLUDE}" \
    | sort -u > /tmp/bundle-libs.txt
# Also include the WebKitWebProcess / NetworkProcess deps that aren't in the
# main lib's chain (they get exec'd in their own ELF context).
for proc in WebKitWebProcess WebKitNetworkProcess; do
    procbin=/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/${proc}
    [[ -x "${procbin}" ]] || continue
    ldd "${procbin}" 2>&1 \
        | awk '/=>/ && $3 ~ /^\// {print $3}' \
        | grep -vE "${EXCLUDE}" \
        | sort -u >> /tmp/bundle-libs.txt
done
sort -u /tmp/bundle-libs.txt > /tmp/bundle-libs-uniq.txt
echo "  -> bundling $(wc -l < /tmp/bundle-libs-uniq.txt) libs"

while read libpath; do
    [[ -f "${libpath}" ]] || continue
    # Copy preserving symlinks; also drop the resolved target so the SONAME
    # symlink resolves inside the bundle.
    cp -P "${libpath}" "${STAGING_DIR}/usr/lib/${APP_NAME}/lib/"
    real="$(readlink -f "${libpath}")"
    if [[ "${libpath}" != "${real}" ]]; then
        cp "${real}" "${STAGING_DIR}/usr/lib/${APP_NAME}/lib/"
    fi
done < /tmp/bundle-libs-uniq.txt

# Run ldconfig in the bundle dir so SONAME symlinks (libfoo.so.X -> libfoo.so.X.Y.Z)
# exist before packaging — the loader looks up SONAMEs, not version-suffixed files.
/sbin/ldconfig -n "${STAGING_DIR}/usr/lib/${APP_NAME}/lib"

# Bundle the WebKitWebProcess + WebKitNetworkProcess + injected bundle
# (libwebkit2gtk-4.0 spawns these as separate executables at runtime)
mkdir -p "${STAGING_DIR}/usr/lib/${APP_NAME}/lib/webkit2gtk-4.0/injected-bundle"
if [[ -d /usr/lib/x86_64-linux-gnu/webkit2gtk-4.0 ]]; then
    cp -a /usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/. \
          "${STAGING_DIR}/usr/lib/${APP_NAME}/lib/webkit2gtk-4.0/"
fi

# Wrapper script: sets LD_LIBRARY_PATH and the WebKit process search path,
# then execs the actual binary. Replaces the previous /usr/bin/${APP_NAME}
# symlink so dpkg, .desktop file, and CLI all hit the wrapper.
cat > "${STAGING_DIR}/usr/lib/${APP_NAME}/${APP_NAME}" <<'WRAPPER'
#!/bin/bash
PD_PREFIX="$(dirname "$(readlink -f "$0")")"
PD_LIB="${PD_PREFIX}/lib"
export LD_LIBRARY_PATH="${PD_LIB}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
# WebKitGTK 4.0 finds its WebProcess/NetworkProcess binaries via this var.
export WEBKIT_EXEC_PATH="${PD_LIB}/webkit2gtk-4.0"
export WEBKIT_INJECTED_BUNDLE_PATH="${PD_LIB}/webkit2gtk-4.0/injected-bundle"
# Block GLib/GIO from loading the host's GVFS / GTK / pixbuf modules — they
# call newer glib symbols (e.g., g_task_set_static_name on noble) that aren't
# in the bundled jammy libglib, causing undefined-symbol crashes when the
# WebView attaches to the GTK widget tree.
export GIO_MODULE_DIR=/nonexistent
export GTK_PATH=/nonexistent
export GDK_PIXBUF_MODULE_FILE=/nonexistent
export GIO_USE_VFS=local
exec "${PD_PREFIX}/privatedeploy.bin" "$@"
WRAPPER
chmod +x "${STAGING_DIR}/usr/lib/${APP_NAME}/${APP_NAME}"
ln -s "../lib/${APP_NAME}/${APP_NAME}" "${STAGING_DIR}/usr/bin/${APP_NAME}"

mkdir -p "${STAGING_DIR}/usr/lib/${APP_NAME}/data/sing-box"
mkdir -p "${STAGING_DIR}/usr/lib/${APP_NAME}/data/subscribes"
mkdir -p "${STAGING_DIR}/usr/lib/${APP_NAME}/data/cloud"
cp "build/bin/data/sing-box/sing-box" "${STAGING_DIR}/usr/lib/${APP_NAME}/data/sing-box/"
chmod +x "${STAGING_DIR}/usr/lib/${APP_NAME}/data/sing-box/sing-box"
[[ -d "build/bin/data/.cache" ]] && cp -r "build/bin/data/.cache" "${STAGING_DIR}/usr/lib/${APP_NAME}/data/"
[[ -f "build/appicon.png" ]] && cp build/appicon.png "${STAGING_DIR}/usr/share/pixmaps/${APP_NAME}.png"

cat > "${STAGING_DIR}/usr/share/applications/${APP_NAME}.desktop" <<EOF
[Desktop Entry]
Name=${APP_DISPLAY_NAME}
Comment=${DESCRIPTION}
Exec=${APP_NAME}
Icon=${APP_NAME}
Type=Application
Categories=Network;Utility;
Terminal=false
StartupNotify=true
EOF

OUT_DIR="build/bin/jammy"
mkdir -p "${OUT_DIR}"
DEB_PATH="${OUT_DIR}/${APP_NAME}_${VERSION}-jammy_amd64.deb"
RPM_PATH="${OUT_DIR}/${APP_NAME}-${VERSION}-1.jammy.x86_64.rpm"
rm -f "${DEB_PATH}" "${RPM_PATH}"

# Postinst: create the system symlink WebKit hardcodes to find its sibling
# binaries (WebKitWebProcess / NetworkProcess), and run ldconfig on the bundle
# so missing SONAME symlinks get materialized on the target system.
POSTINST_SCRIPT="$(mktemp)"
cat > "${POSTINST_SCRIPT}" <<'POSTINST'
#!/bin/sh
set -e
PD_WEBKIT_DIR=/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0
PD_BUNDLED=/usr/lib/privatedeploy/lib/webkit2gtk-4.0
if [ ! -e "${PD_WEBKIT_DIR}" ] || [ -L "${PD_WEBKIT_DIR}" ]; then
    ln -sf "${PD_BUNDLED}" "${PD_WEBKIT_DIR}"
fi
ldconfig -n /usr/lib/privatedeploy/lib || true
POSTINST
chmod +x "${POSTINST_SCRIPT}"

PRERM_SCRIPT="$(mktemp)"
cat > "${PRERM_SCRIPT}" <<'PRERM'
#!/bin/sh
set -e
PD_WEBKIT_DIR=/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0
PD_BUNDLED=/usr/lib/privatedeploy/lib/webkit2gtk-4.0
# Only remove the symlink if it points at our bundle (don't trash a real
# system install if one was added later by the user).
if [ -L "${PD_WEBKIT_DIR}" ] && [ "$(readlink "${PD_WEBKIT_DIR}")" = "${PD_BUNDLED}" ]; then
    rm -f "${PD_WEBKIT_DIR}"
fi
PRERM
chmod +x "${PRERM_SCRIPT}"

echo "==> Step 5: build deb"
fpm -s dir -t deb \
    -n "${APP_NAME}" \
    -v "${VERSION}-jammy" \
    --description "${DESCRIPTION}" \
    --url "${HOMEPAGE}" \
    --maintainer "${MAINTAINER}" \
    --license "MIT" \
    --category "net" \
    --depends "libgtk-3-0" \
    --after-install "${POSTINST_SCRIPT}" \
    --before-remove "${PRERM_SCRIPT}" \
    -C "${STAGING_DIR}" \
    -p "${DEB_PATH}" \
    usr

echo "==> Step 6: build rpm"
fpm -s dir -t rpm \
    -n "${APP_NAME}" \
    -v "${VERSION}" \
    --iteration "1.jammy" \
    --description "${DESCRIPTION}" \
    --url "${HOMEPAGE}" \
    --maintainer "${MAINTAINER}" \
    --license "MIT" \
    --category "Applications/Internet" \
    --depends "gtk3" \
    --after-install "${POSTINST_SCRIPT}" \
    --before-remove "${PRERM_SCRIPT}" \
    -C "${STAGING_DIR}" \
    -p "${RPM_PATH}" \
    usr

rm -f "${POSTINST_SCRIPT}" "${PRERM_SCRIPT}"

rm -rf "${STAGING_DIR}"

echo ""
echo "=== jammy build complete ==="
ls -lh "${OUT_DIR}"/*.deb "${OUT_DIR}"/*.rpm
echo ""
echo "Install: sudo apt install ${DEB_PATH}"
