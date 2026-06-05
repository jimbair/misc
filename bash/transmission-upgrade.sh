#!/bin/bash
# Checks GitHub for the latest Transmission release and builds/installs it
# from source if newer than the currently installed version.
# Must be run as root.

# Configuration
SRC_DIR="/usr/src/transmission"
GITHUB_API="https://api.github.com/repos/transmission/transmission/releases/latest"
SERVICE="transmission-daemon"

# Helpers
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# Must be run as root
[[ $EUID -eq 0 ]] || die "This script must be run as root."

# Check upstream for a new release
log "Checking GitHub for latest Transmission release..."
LATEST_VERSION=$(curl -fsSL "$GITHUB_API" \
    | grep '"tag_name"' \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')

[[ -n "$LATEST_VERSION" ]] || die "Could not determine latest version from GitHub API."
log "Latest available version: $LATEST_VERSION"

# Check installed version 
INSTALLED_VERSION=""
if [[ -x /usr/local/bin/transmission-remote ]]; then
    INSTALLED_VERSION=$(/usr/local/bin/transmission-remote --version 2>&1 \
        | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' \
        | head -1)
fi

# Exit if we can't find the installed version
if [[ -z "$INSTALLED_VERSION" ]]; then
    die "Transmission does not appear to be installed yet."
fi

log "Currently installed version: $INSTALLED_VERSION"

# Exit if latest is already present
if [[ "$INSTALLED_VERSION" == "$LATEST_VERSION" ]]; then
    log "Already up to date ($INSTALLED_VERSION). Nothing to do."
    exit 0
fi

log "Upgrade available: $INSTALLED_VERSION -> $LATEST_VERSION"

# Check if we already have the tarball
TARBALL="transmission-${LATEST_VERSION}.tar.xz"
TARBALL_PATH="$SRC_DIR/$TARBALL"

mkdir -p "$SRC_DIR"

if [[ -f "$TARBALL_PATH" ]]; then
    log "Tarball already present: $TARBALL_PATH — skipping download."
else
    DOWNLOAD_URL="https://github.com/transmission/transmission/releases/download/${LATEST_VERSION}/${TARBALL}"
    log "Downloading $TARBALL..."
    wget -q --show-progress -O "$TARBALL_PATH" "$DOWNLOAD_URL" \
        || die "Download failed: $DOWNLOAD_URL"
fi

# Extract it, fresh if needed
BUILD_DIR="$SRC_DIR/transmission-${LATEST_VERSION}"

if [[ -d "$BUILD_DIR" ]]; then
    log "Source directory already exists; removing stale build: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

log "Extracting $TARBALL..."
tar xf "$TARBALL_PATH" -C "$SRC_DIR"

[[ -d "$BUILD_DIR" ]] || die "Expected source dir not found after extraction: $BUILD_DIR"

# Build it
cd "$BUILD_DIR"

log "Configuring build..."
cmake -B build -DCMAKE_BUILD_TYPE=Release || die "Build stage 1 failed"

log "Compiling (using $(nproc) cores)..."
cmake --build build -- -j"$(nproc)" || die "Build stage 2 failed"

# Shut it down
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    log "Stopping $SERVICE..."
    systemctl stop "$SERVICE"
    RESTART_SERVICE=true
else
    RESTART_SERVICE=false
fi

# Install it
log "Installing..."
cmake --install build || die "Install stage failed"

# Start it
if [[ "$RESTART_SERVICE" == true ]]; then
    log "Restarting $SERVICE..."
    systemctl start "$SERVICE"
    sleep 2
    if systemctl is-active --quiet "$SERVICE"; then
        log "$SERVICE restarted successfully."
    else
        die "$SERVICE failed to start — check: journalctl -u $SERVICE"
    fi
fi

# Did we do good work?
INSTALLED_NOW=$(transmission-daemon --version 2>&1 \
    | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' \
    | head -1)

# All done
log "Upgrade complete. Installed version: $INSTALLED_NOW"
exit 0
