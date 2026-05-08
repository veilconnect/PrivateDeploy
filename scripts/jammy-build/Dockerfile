FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    GOROOT=/usr/local/go \
    GOPATH=/go \
    GOPROXY=https://goproxy.cn,direct \
    PATH=/usr/local/go/bin:/go/bin:/usr/local/bin:/usr/bin:/bin

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git build-essential pkg-config \
        libgtk-3-dev libwebkit2gtk-4.0-dev libsoup2.4-dev \
        libayatana-appindicator3-dev \
        ruby ruby-dev rubygems rpm \
        xz-utils file \
    && rm -rf /var/lib/apt/lists/*

# Go 1.23.0 (jammy ships 1.18; need newer for our go.mod)
RUN curl -fsSL https://go.dev/dl/go1.23.0.linux-amd64.tar.gz \
      -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

# Node 20 + pnpm
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm@9 \
    && rm -rf /var/lib/apt/lists/*

# fpm for deb/rpm packaging
RUN gem install --no-document fpm

# Wails CLI v2.12.0
RUN go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0

WORKDIR /repo
