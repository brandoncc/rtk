#!/usr/bin/env sh
# rtk installer - https://github.com/rtk-ai/rtk
# Usage: curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh

set -e

REPO="rtk-ai/rtk"
BINARY_NAME="rtk"
INSTALL_DIR="${RTK_INSTALL_DIR:-$HOME/.local/bin}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
    exit 1
}

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Linux*)  OS="linux";;
        Darwin*) OS="darwin";;
        *)       error "Unsupported operating system: $(uname -s)";;
    esac
}

# Detect architecture
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="x86_64";;
        arm64|aarch64) ARCH="aarch64";;
        *)             error "Unsupported architecture: $(uname -m)";;
    esac
}

# Get latest release version
# Primary: parse the 302 redirect on /releases/latest (no API call, no rate limit).
# Fallback: the GitHub REST API (subject to 60 req/hour anonymous limit).
get_latest_version() {
    # Try the web redirect first — does not count against the API rate limit.
    VERSION=$(curl -sI "https://github.com/${REPO}/releases/latest" \
        | grep -i '^location:' \
        | sed -E 's|.*/tag/([^[:space:]]+).*|\1|' \
        | tr -d '\r')

    # Fallback to the REST API if the redirect didn't yield a tag.
    if [ -z "$VERSION" ]; then
        warn "Redirect lookup failed, falling back to GitHub API..."
        VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
            | grep '"tag_name":' \
            | sed -E 's/.*"([^"]+)".*/\1/')
    fi

    if [ -z "$VERSION" ]; then
        error "Failed to get latest version (GitHub API may be rate-limited; set RTK_VERSION=vX.Y.Z to pin)"
    fi
}

# Build target triple
get_target() {
    case "$OS" in
        linux)
            case "$ARCH" in
                x86_64)  TARGET="x86_64-unknown-linux-musl";;
                aarch64) TARGET="aarch64-unknown-linux-gnu";;
            esac
            ;;
        darwin)
            TARGET="${ARCH}-apple-darwin"
            ;;
    esac
}

checksum_command() {
    command -v sha256sum >/dev/null 2>&1 && { echo "sha256sum"; return; }
    command -v shasum >/dev/null 2>&1 && { echo "shasum"; return; }
    error "Need sha256sum or shasum to verify release checksums"
}

expected_checksum() {
    grep " ${BINARY_NAME}-${TARGET}.tar.gz$" "$CHECKSUMS" | awk '{print $1}' | head -1
}

actual_checksum() {
    case "$(checksum_command)" in
        sha256sum) sha256sum "$ARCHIVE" | awk '{print $1}' ;;
        shasum) shasum -a 256 "$ARCHIVE" | awk '{print $1}' ;;
    esac
}

verify_checksum() {
    EXPECTED=$(expected_checksum)
    [ -n "$EXPECTED" ] || error "checksums.txt is missing ${BINARY_NAME}-${TARGET}.tar.gz"
    ACTUAL=$(actual_checksum)
    [ "$ACTUAL" = "$EXPECTED" ] || error "Checksum mismatch for ${BINARY_NAME}-${TARGET}.tar.gz"
}

# Download and install
install() {
    info "Detected: $OS $ARCH"
    info "Target: $TARGET"
    info "Version: $VERSION"

    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${BINARY_NAME}-${TARGET}.tar.gz"
    CHECKSUMS_URL="https://github.com/${REPO}/releases/download/${VERSION}/checksums.txt"
    TEMP_DIR=$(mktemp -d)
    ARCHIVE="${TEMP_DIR}/${BINARY_NAME}.tar.gz"
    CHECKSUMS="${TEMP_DIR}/checksums.txt"

    info "Downloading from: $DOWNLOAD_URL"
    if ! curl -fsSL "$DOWNLOAD_URL" -o "$ARCHIVE"; then
        error "Failed to download binary"
    fi

    info "Downloading checksums..."
    if ! curl -fsSL "$CHECKSUMS_URL" -o "$CHECKSUMS"; then
        error "Failed to download checksums"
    fi

    info "Verifying checksum..."
    verify_checksum

    # Verify archive contents before extraction (CWE-22 path traversal).
    # Reject any entry with an absolute path or a ".." component.
    info "Verifying archive..."
    if tar -tzf "$ARCHIVE" | grep -qE '^/|(^|/)\.\.(/|$)'; then
        error "Archive contains unsafe paths (absolute or directory traversal) — refusing to extract"
    fi

    info "Extracting..."
    tar -xzf "$ARCHIVE" -C "$TEMP_DIR"

    mkdir -p "$INSTALL_DIR"
    mv "${TEMP_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/"

    chmod +x "${INSTALL_DIR}/${BINARY_NAME}"

    # Cleanup
    rm -rf "$TEMP_DIR"

    info "Successfully installed ${BINARY_NAME} to ${INSTALL_DIR}/${BINARY_NAME}"
}

# Verify installation
verify() {
    INSTALLED_BINARY="${INSTALL_DIR}/${BINARY_NAME}"
    if [ -x "$INSTALLED_BINARY" ]; then
        info "Verification: $("$INSTALLED_BINARY" --version)"
    else
        warn "Binary installed but not executable: $INSTALLED_BINARY"
    fi

    if ! command -v "$BINARY_NAME" >/dev/null 2>&1; then
        warn "Binary installed but not in PATH. Add to your shell profile:"
        warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
}

main() {
    info "Installing $BINARY_NAME..."

    detect_os
    detect_arch
    get_target
    if [ -n "$RTK_VERSION" ]; then
        VERSION="$RTK_VERSION"
        info "Using pinned version from RTK_VERSION: $VERSION"
    else
        get_latest_version
    fi
    install
    verify

    echo ""
    info "Installation complete! Run '$BINARY_NAME --help' to get started."
}

main
