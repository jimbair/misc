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

# Must be run on Alma or Fedora
command -v dnf &>/dev/null || die "This script requires dnf"

# Check build dependencies
MISSING=()
for pkg in cmake gcc gcc-c++ make pkgconf-pkg-config curl jq; do
    rpm -q "$pkg" &>/dev/null || MISSING+=("$pkg")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    die "Missing required packages: ${MISSING[*]}
       Install with: dnf install -y ${MISSING[*]}"
fi

# Check upstream for a new release
log "Checking GitHub for latest Transmission release..."
API_RESPONSE=$(curl -fsSL "$GITHUB_API") || die "GitHub API request failed."

LATEST_VERSION=$(echo "$API_RESPONSE" | jq -r '.tag_name')
[[ -n "$LATEST_VERSION" ]] || die "Could not determine latest version from GitHub API."
log "Latest available version: $LATEST_VERSION"

# Check the checksums baby
TARBALL_DIGEST=$(echo "$API_RESPONSE" \
    | jq -r --arg name "transmission-${LATEST_VERSION}.tar.xz" \
        '.assets[] | select(.name == $name) | .digest | ltrimstr("sha256:")')
[[ -n "$TARBALL_DIGEST" ]] || die "Could not extract tarball digest from GitHub API."

# Check installed version
INSTALLED_VERSION=""
if [[ -x /usr/local/bin/transmission-remote ]]; then
    INSTALLED_VERSION=$(/usr/local/bin/transmission-remote --version 2>&1 \
        | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' \
        | head -1)
fi

# Exit if we can't find the installed version
[[ -n "$INSTALLED_VERSION" ]] || die "Transmission does not appear to be installed yet."
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
RELEASE_BASE="https://github.com/transmission/transmission/releases/download/${LATEST_VERSION}"

mkdir -p "$SRC_DIR"

if [[ -f "$TARBALL_PATH" ]]; then
    log "Tarball already present: $TARBALL_PATH"
else
    log "Downloading $TARBALL..."
    curl -fL --progress-bar -o "$TARBALL_PATH" "$RELEASE_BASE/$TARBALL" \
        || die "Tarball download failed: $RELEASE_BASE/$TARBALL"
fi

# Verify checksum
log "Verifying checksum..."
ACTUAL_DIGEST=$(sha256sum "$TARBALL_PATH" | awk '{print $1}')
if [[ "$ACTUAL_DIGEST" != "$TARBALL_DIGEST" ]]; then
    rm -f "$TARBALL_PATH"
    die "Checksum mismatch — tarball deleted. Re-run to download fresh.
       Expected: $TARBALL_DIGEST
       Got:      $ACTUAL_DIGEST"
fi
log "Checksum OK."

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
INSTALLED_NOW=$(/usr/local/bin/transmission-remote --version 2>&1 \
    | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' \
    | head -1)
[[ -n "" ]] || die "Failed to capture installed version after install"

# All done
log "Upgrade complete. Installed version: $INSTALLED_NOW"
exit 0
