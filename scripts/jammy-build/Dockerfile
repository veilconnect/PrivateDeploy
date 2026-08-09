FROM ubuntu:22.04

ARG GO_VERSION=1.25.11

ENV DEBIAN_FRONTEND=noninteractive \
    GOROOT=/usr/local/go \
    GOPATH=/go \
    GOPROXY=https://goproxy.cn,direct \
    PATH=/usr/local/go/bin:/go/bin:/usr/local/bin:/usr/bin:/bin

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git patch build-essential pkg-config \
        libgtk-3-dev libwebkit2gtk-4.0-dev libsoup2.4-dev \
        libayatana-appindicator3-dev \
        ruby ruby-dev rubygems rpm \
        xz-utils file \
    && rm -rf /var/lib/apt/lists/*

# Jammy's packaged Go is too old. The host wrapper passes the version declared
# by go.mod so the release container cannot silently drift behind the project.
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
      -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

# Node 20 + the exact pnpm release declared by frontend/package.json and CI.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm@10.33.0 \
    && rm -rf /var/lib/apt/lists/*

# fpm for deb/rpm packaging
RUN gem install --no-document fpm

# Wails CLI v2.12.0
RUN go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0

# linuxdeploy + GTK plugin (AppImage builder).  Pre-download these on the
# host (where the proxy works) and ship them via the build context — github
# isn't reliably reachable from inside the container behind the regional reachability.
COPY linuxdeploy-x86_64.AppImage /usr/local/bin/linuxdeploy
COPY linuxdeploy-plugin-gtk.sh /usr/local/bin/linuxdeploy-plugin-gtk.sh
COPY runtime-x86_64 /usr/local/share/appimage/runtime-x86_64
RUN chmod +x /usr/local/bin/linuxdeploy /usr/local/bin/linuxdeploy-plugin-gtk.sh \
    && apt-get update && apt-get install -y --no-install-recommends \
        appstream librsvg2-bin desktop-file-utils zsync libfuse2 \
        imagemagick patchelf \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /repo
