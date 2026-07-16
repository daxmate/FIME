#!/bin/bash
set -euo pipefail

PRODUCT="FIME"
BUILD_DIR=".build"
SOURCES_DIR="Sources"
RESOURCES_DIR="Resources"
DEST="/Library/Input Methods/$PRODUCT.app"
ENTITLEMENTS="FIME.entitlements"
LSBIN="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

clean() {
    echo "==> Cleaning ..."
    rm -rf "$BUILD_DIR"
    echo "Done."
    exit 0
}

build_bundle() {
    local OUT="$1"
    local SIGN_ID="${2:--}"   # default: ad-hoc (-)

    echo "==> Creating app bundle at $OUT ..."
    rm -rf "$OUT"
    mkdir -p "$OUT/Contents/MacOS"
    mkdir -p "$OUT/Contents/Resources"

    # Build the binary
    swiftc \
        -target arm64-apple-macosx14.0 \
        -module-name "$PRODUCT" \
        -o "$OUT/Contents/MacOS/$PRODUCT" \
        -framework InputMethodKit \
        -framework AppKit \
        -framework Foundation \
        "$SOURCES_DIR/main.swift" \
        "$SOURCES_DIR/FIMEController.swift" \
        "$SOURCES_DIR/WordEngine.swift" \
        "$SOURCES_DIR/WordDatabase.swift"

    cp "Info.plist" "$OUT/Contents/"

    # Copy all resources
    for f in "$RESOURCES_DIR"/*; do
        if [ -f "$f" ]; then
            cp "$f" "$OUT/Contents/Resources/"
        fi
    done

    # Fix permissions on bundle BEFORE signing so the signature covers the final state
    echo "  Fixing permissions before signing..."
    chmod 755 "$OUT"
    chmod 755 "$OUT/Contents"
    chmod 755 "$OUT/Contents/MacOS"
    chmod 755 "$OUT/Contents/Resources"
    chmod 644 "$OUT/Contents/Info.plist"
    chmod 755 "$OUT/Contents/MacOS/$PRODUCT"
    find "$OUT/Contents/Resources" -type f -exec chmod 644 {} \;

    echo "==> Signing bundle ($SIGN_ID) ..."
    if [ "$SIGN_ID" = "-" ]; then
        # Ad-hoc signing: no hardened runtime, no library validation needed
        codesign \
            --force \
            --sign - \
            --entitlements "$ENTITLEMENTS" \
            "$OUT"
    else
        # Developer ID signing: use hardened runtime
        codesign \
            --force \
            --sign "$SIGN_ID" \
            --entitlements "$ENTITLEMENTS" \
            --options runtime \
            --timestamp \
            "$OUT"
    fi

    codesign --verify --verbose "$OUT"
    echo "✅ Bundle built and signed: $OUT"
}

build() {
    echo "==> Building $PRODUCT ..."
    mkdir -p "$BUILD_DIR"
    build_bundle "$BUILD_DIR/$PRODUCT.app" "${SIGN_ID:--}"
}

install() {
    local SIGN_ID="${SIGN_ID:--}"

    echo "==> Building with signing: ${SIGN_ID:-"ad-hoc"} ..."
    mkdir -p "$BUILD_DIR"
    build_bundle "$BUILD_DIR/$PRODUCT.app" "$SIGN_ID"

    echo "==> Installing to $DEST ..."

    # Kill running instances
    killall "$PRODUCT" 2>/dev/null || true
    sleep 1

    # Remove old bundle
    if [ -d "$DEST" ]; then
        echo "  Removing old version..."
        sudo rm -rf "$DEST"
    fi

    # Copy freshly built bundle (macOS cp -R preserves extended attrs & code signature)
    sudo cp -R "$BUILD_DIR/$PRODUCT.app" "$DEST"
    sudo chown -R root:wheel "$DEST"

    echo ""
    echo "✅ Bundle copied to $DEST"
    echo ""
    echo "=== Next Steps ==="
    echo "  Log out and log back in (or restart)"
    echo "  Then go to System Settings → Keyboard → Input Sources"
    echo "  and add 'FIME' to enable it."
    echo ""
    echo "⚠️  Note: no system registration was performed. A logout/login"
    echo "   is required for macOS to detect the new input method."
    echo ""
    if [ "$SIGN_ID" = "-" ]; then
        echo "  ⚠️  Ad-hoc signed. For auto-launch you may need Developer ID signing:"
        echo "       SIGN_ID='Developer ID Application: Your Name (TEAM)' bash $0 install"
    fi
}

# Determine if SIGN_ID env var is set
case "${1:-build}" in
    build)
        build
        ;;
    install)
        install
        ;;
    clean)
        clean
        ;;
    *)
        echo "Usage: $0 [build|install|clean]"
        echo ""
        echo "Environment variables:"
        echo "  SIGN_ID   Code signing identity (default: ad-hoc)"
        echo ""
        echo "Examples:"
        echo "  bash $0 build"
        echo "  bash $0 install                    # ad-hoc (no auto-launch on macOS 26+)"
        echo "  SIGN_ID='Developer ID Application: NAME (TEAM)' bash $0 install"
        exit 1
        ;;
esac
