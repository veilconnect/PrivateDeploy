FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    dbus-x11 \
    file \
    fonts-dejavu-core \
    imagemagick \
    jq \
    libasound2 \
    libayatana-appindicator3-1 \
    libgbm1 \
    libgdk-pixbuf-2.0-0 \
    libglib2.0-0 \
    libgtk-3-0 \
    libnss3 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libwebkit2gtk-4.1-0 \
    libx11-xcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    libxtst6 \
    procps \
    x11-utils \
    xauth \
    xvfb \
    xdotool \
  && mkdir -p /tmp/.X11-unix \
  && chmod 1777 /tmp/.X11-unix \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /work
ENTRYPOINT ["/bin/bash"]
