#!/bin/bash
# Builds an AppImage from the jammy-compiled PrivateDeploy binary.
# Runs inside the jammy build container (after in-container-build.sh has
# produced /repo/build/bin/PrivateDeploy and runtime data).

set -euo pipefail

cd /repo

APP_NAME="privatedeploy"
APP_DISPLAY_NAME="PrivateDeploy"
VERSION="${VERSION:-2.0.0}"
DESCRIPTION="Private deployment tool with cloud integration and proxy management"

if [[ ! -x build/bin/${APP_DISPLAY_NAME} ]]; then
    echo "ERROR: build/bin/${APP_DISPLAY_NAME} missing — run in-container-build.sh first" >&2
    exit 1
fi

OUT_DIR="build/bin/jammy"
mkdir -p "${OUT_DIR}"
APP_DIR="$(mktemp -d)/${APP_DISPLAY_NAME}.AppDir"

echo "==> Step A: stage AppDir at ${APP_DIR}"
mkdir -p "${APP_DIR}/usr/bin" \
         "${APP_DIR}/usr/share/applications" \
         "${APP_DIR}/usr/share/icons/hicolor/256x256/apps" \
         "${APP_DIR}/usr/lib/${APP_NAME}/data"

cp "build/bin/${APP_DISPLAY_NAME}" "${APP_DIR}/usr/bin/${APP_NAME}"
chmod +x "${APP_DIR}/usr/bin/${APP_NAME}"

# Bundle the runtime sing-box + cache assets next to the binary
cp -a build/bin/data/. "${APP_DIR}/usr/lib/${APP_NAME}/data/"
chmod +x "${APP_DIR}/usr/lib/${APP_NAME}/data/sing-box/sing-box" 2>/dev/null || true

# Icon — AppImage requires a standard size (8/16/.../256/.../512). Resize the
# 1024x1024 source down to 256x256 with ImageMagick.
if [[ -f build/appicon.png ]]; then
    convert build/appicon.png -resize 256x256 \
        "${APP_DIR}/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.png"
    cp "${APP_DIR}/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.png" \
        "${APP_DIR}/${APP_NAME}.png"
fi

cat > "${APP_DIR}/usr/share/applications/${APP_NAME}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${APP_DISPLAY_NAME}
Comment=${DESCRIPTION}
Exec=${APP_NAME}
Icon=${APP_NAME}
Categories=Network;Utility;
Terminal=false
StartupNotify=true
StartupWMClass=${APP_DISPLAY_NAME}
EOF
cp "${APP_DIR}/usr/share/applications/${APP_NAME}.desktop" "${APP_DIR}/${APP_NAME}.desktop"

# linuxdeploy-plugin-gtk discovers GTK via pkg-config; nudge it to webkit2gtk-4.0
# instead of the default 4.1, since our binary is linked against -4.0.
mkdir -p "${APP_DIR}/usr/lib/${APP_NAME}/conf"
cat > "${APP_DIR}/AppRun.gtk-env" <<'GTKENV'
# Loaded by linuxdeploy-plugin-gtk's wrapper before launching the binary.
# Block the host's GIO modules and pixbuf cache from being picked up — they
# call newer glib symbols not in our bundled jammy libs.
export GIO_MODULE_DIR="${APPDIR}/usr/lib/x86_64-linux-gnu/gio/modules"
export GIO_USE_VFS=local
GTKENV

echo "==> Step B: linuxdeploy --plugin gtk (auto-bundle deps + webkit-4.0)"
APPIMAGE_EXTRACT_AND_RUN=1 \
DEPLOY_GTK_VERSION=3 \
linuxdeploy \
    --appdir "${APP_DIR}" \
    --executable "${APP_DIR}/usr/bin/${APP_NAME}" \
    --desktop-file "${APP_DIR}/usr/share/applications/${APP_NAME}.desktop" \
    --icon-file "${APP_DIR}/${APP_NAME}.png" \
    --plugin gtk \
    --library /usr/lib/x86_64-linux-gnu/libwebkit2gtk-4.0.so.37 \
    --library /usr/lib/x86_64-linux-gnu/libjavascriptcoregtk-4.0.so.18

# linuxdeploy-plugin-gtk does NOT bundle WebKitWebProcess / NetworkProcess
# (those are exec'd as separate binaries at runtime). Ship them ourselves and
# patch the AppRun to point WEBKIT_EXEC_PATH at the bundled directory.
# Sidecar: tray + dbus runs in a separate process so godbus's package init()
# never touches the WebKit/JSC main process address space. Copy AFTER
# linuxdeploy has finished its dep-walking — its gtk plugin invokes ldd on
# every ELF inside the AppDir and aborts with "Failed to run ldd: exit 1"
# on stripped Go binaries (tested with both stripped and unstripped builds
# of the same binary; failure is reproducible inside the container only).
echo "==> Step C0: copy tray sidecar (post-linuxdeploy so it isn't ldd-walked)"
mkdir -p "${APP_DIR}/usr/lib/privatedeploy"
if [[ -x build/bin/privatedeploy-tray ]]; then
    cp build/bin/privatedeploy-tray "${APP_DIR}/usr/lib/privatedeploy/privatedeploy-tray"
    chmod +x "${APP_DIR}/usr/lib/privatedeploy/privatedeploy-tray"
fi

echo "==> Step C: bundle WebKit subprocess executables + LD_PRELOAD path-rewrite shim"
mkdir -p "${APP_DIR}/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/injected-bundle"
cp /usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/WebKitNetworkProcess \
   /usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/WebKitWebProcess \
   "${APP_DIR}/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/" 2>/dev/null || true
[[ -f /usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/WebKitGPUProcess ]] && \
    cp /usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/WebKitGPUProcess \
       "${APP_DIR}/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/" 2>/dev/null || true
cp -r /usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/injected-bundle/. \
   "${APP_DIR}/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/injected-bundle/" 2>/dev/null || true

# WebKit subprocesses on jammy ship without RPATH and rely on the system
# /lib/x86_64-linux-gnu being on the loader path. On noble those libs don't
# exist there, and WebKit deliberately scrubs LD_LIBRARY_PATH for the
# child processes for sandboxing — so we add an RPATH pointing back to the
# AppDir's bundled lib dir. $ORIGIN/../.. resolves to ${APPDIR}/usr/lib/.
for proc in WebKitNetworkProcess WebKitWebProcess WebKitGPUProcess; do
    procbin="${APP_DIR}/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/${proc}"
    [[ -f "${procbin}" ]] || continue
    patchelf --set-rpath '$ORIGIN/../..' "${procbin}"
done
# Same for the injected bundle .so so its dlopen finds bundled libs.
patchelf --set-rpath '$ORIGIN/../..' \
    "${APP_DIR}/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/injected-bundle/libwebkit2gtkinjectedbundle.so" 2>/dev/null || true

# Compile the LD_PRELOAD shim that rewrites WebKit's hardcoded LIBEXECDIR
# path lookups to point inside the AppDir.
gcc -shared -fPIC -O2 \
    -o "${APP_DIR}/usr/lib/webkit_path_rewrite.so" \
    /repo/scripts/jammy-build/webkit_path_rewrite.c \
    -ldl

# Inject our own apprun-hook that linuxdeploy's AppRun will source. Has to
# come AFTER linuxdeploy-plugin-gtk so APPDIR is already exported. Sets
# LD_PRELOAD to our path-rewrite shim that redirects WebKit's hardcoded
# LIBEXECDIR lookups to the AppDir copies.
mkdir -p "${APP_DIR}/apprun-hooks"
cat > "${APP_DIR}/apprun-hooks/zz-privatedeploy-webkit-path.sh" <<'HOOK'
# Sourced by AppRun (linuxdeploy autogenerated). $this_dir == AppDir root.
export APPDIR="${this_dir}"
# LD_PRELOAD shim rewrites WebKit's hardcoded LIBEXECDIR + dlopen paths.
export LD_PRELOAD="${this_dir}/usr/lib/webkit_path_rewrite.so${LD_PRELOAD:+:${LD_PRELOAD}}"
# Block host's GIO/GVFS modules from loading — they call newer glib symbols
# (e.g., g_task_set_static_name) not in our jammy libglib.
export GIO_MODULE_DIR=/nonexistent
export GIO_USE_VFS=local
# Move JSC's GC signal off SIGUSR1 (10) to avoid the Go runtime conflict that
# crashes gtk_main on noble at addr=0x48. Belt-and-braces with JSC_useJIT=0.
export JSC_SIGNAL_FOR_GC=48
export JSC_useJIT=0
# Take over the exec from AppRun so argv[0] is "PrivateDeploy", not the path
# "AppRun.wrapped". GTK derives WM_CLASS from basename(argv[0]); without this,
# the X11 WM_CLASS would be "AppRun.wrapped" and wouldn't match the .desktop's
# StartupWMClass=PrivateDeploy — which breaks GNOME taskbar association
# (clicks/icons don't bind to the running window). This exec replaces the
# shell, so AppRun's autogenerated `exec "$this_dir"/AppRun.wrapped "$@"` line
# below never runs (and re-runs of linuxdeploy can't undo the fix).
exec -a PrivateDeploy "${this_dir}/AppRun.wrapped" "$@"
HOOK

echo "==> Step D: pack AppImage"
APPIMAGE_OUT="${OUT_DIR}/${APP_DISPLAY_NAME}-${VERSION}-x86_64.AppImage"
APPIMAGE_EXTRACT_AND_RUN=1 \
ARCH=x86_64 \
OUTPUT="${APPIMAGE_OUT}" \
LDAI_RUNTIME_FILE=/usr/local/share/appimage/runtime-x86_64 \
linuxdeploy --appdir "${APP_DIR}" --output appimage

ls -lh "${APPIMAGE_OUT}"
echo ""
echo "=== AppImage build complete ==="
echo "Run:  chmod +x ${APPIMAGE_OUT} && ./${APPIMAGE_OUT}"
