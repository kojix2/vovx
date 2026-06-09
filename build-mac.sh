#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
APP_NAME="${APP_NAME:-vovx}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-VOVX}"
VERSION="${VERSION:-$(awk '/^version:/ { print $2; exit }' shard.yml)}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.kojix2.vovx}"

: "${VERSION:?VERSION could not be detected from shard.yml}"

EXECUTABLE_PATH="bin/$APP_NAME"
APP_BUNDLE="$APP_DISPLAY_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
PLIST_PATH="$APP_BUNDLE/Contents/Info.plist"

ICON_NAME="app_icon"
ICON_PNG="resources/$ICON_NAME.png"
ICON_SVG="resources/$ICON_NAME.svg"
ICON_ICNS="resources/$ICON_NAME.icns"

ARCH="${ARCH:-$(uname -m)}"
DMG_NAME="${APP_NAME}_${VERSION}_${ARCH}.dmg"
VOL_NAME="$APP_DISPLAY_NAME"
STAGING_DIR="dmg_stage"
DIST_DIR="dist"
APP_BUNDLE_DIST="${APP_DISPLAY_NAME}_${VERSION}_${ARCH}.app"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.bundle.XXXXXX")"
SEEN_DIR="$TMP_DIR/seen"
mkdir -p "$SEEN_DIR"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
log() {
  printf '%s\n' "$*"
}

hash_key() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

is_seen() {
  local key
  key="$(hash_key "$1")"
  [ -e "$SEEN_DIR/$key" ]
}

mark_seen() {
  local key
  key="$(hash_key "$1")"
  touch "$SEEN_DIR/$key"
}

list_deps() {
  local target="$1"
  otool -L "$target" | tail -n +2 | awk '{print $1}'
}

is_system_lib() {
  case "$1" in
    /System/Library/*) return 0 ;;
    /usr/lib/*) return 0 ;;
    /System/Volumes/Preboot/Cryptexes/OS/usr/lib/*) return 0 ;;
    /System/iOSSupport/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_bundle_internal_ref() {
  case "$1" in
    @executable_path/*|@loader_path/*|@rpath/*) return 0 ;;
    "$FRAMEWORKS_DIR"/*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_writable() {
  chmod u+w "$1" 2>/dev/null || true
}

render_svg_to_png() {
  local svg="$1"
  local out_png="$2"
  local ql_out

  if command -v qlmanage >/dev/null 2>&1; then
    qlmanage -t -s 1024 -o "$TMP_DIR" "$svg" >/dev/null 2>&1 || true
    ql_out="$TMP_DIR/$(basename "$svg").png"
    if [ -f "$ql_out" ]; then
      mv "$ql_out" "$out_png"
      return 0
    fi
  fi

  if command -v rsvg-convert >/dev/null 2>&1; then
    if rsvg-convert -w 1024 -h 1024 "$svg" -o "$out_png" >/dev/null 2>&1; then
      return 0
    fi
  fi

  if command -v inkscape >/dev/null 2>&1; then
    if inkscape "$svg" --export-type=png --export-filename="$out_png" -w 1024 -h 1024 >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

copy_lib_into_frameworks() {
  local src="$1"
  local base dest

  base="$(basename "$src")"
  dest="$FRAMEWORKS_DIR/$base"

  if [ ! -e "$dest" ]; then
    printf 'Copying: %s -> %s\n' "$src" "$dest" >&2
    cp -fL "$src" "$dest"
    ensure_writable "$dest"

    # Normalize the dylib's own install name.
    install_name_tool -id "@rpath/$base" "$dest"
  fi

  printf '%s\n' "$dest"
}

maybe_add_rpath() {
  local target="$1"
  local rpath="$2"

  if ! otool -l "$target" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  ' | grep -Fx "$rpath" >/dev/null 2>&1; then
    ensure_writable "$target"
    install_name_tool -add_rpath "$rpath" "$target"
  fi
}

patch_dep_reference() {
  local target="$1"
  local old="$2"
  local new="$3"

  ensure_writable "$target"
  install_name_tool -change "$old" "$new" "$target"
}

scan_and_bundle_binary() {
  local target="$1"
  local kind="$2"   # executable | dylib
  local dep dep_dest dep_base new_ref

  if is_seen "$target"; then
    return
  fi
  mark_seen "$target"

  if [ "$kind" = "executable" ]; then
    maybe_add_rpath "$target" "@executable_path/../Frameworks"
  else
    maybe_add_rpath "$target" "@loader_path"
    install_name_tool -id "@rpath/$(basename "$target")" "$target"
  fi

  while IFS= read -r dep; do
    [ -n "$dep" ] || continue

    if is_system_lib "$dep"; then
      continue
    fi

    # Already internalized? leave it as-is.
    if is_bundle_internal_ref "$dep"; then
      continue
    fi

    # Only bundle absolute non-system libs.
    case "$dep" in
      /*)
        dep_dest="$(copy_lib_into_frameworks "$dep")"
        dep_base="$(basename "$dep_dest")"

        if [ "$kind" = "executable" ]; then
          new_ref="@executable_path/../Frameworks/$dep_base"
        else
          new_ref="@loader_path/$dep_base"
        fi

        log "Patching: $target"
        log "  $dep"
        log "  -> $new_ref"
        patch_dep_reference "$target" "$dep" "$new_ref"

        # Recurse into copied dylib.
        scan_and_bundle_binary "$dep_dest" "dylib"
        ;;
      *)
        # Leave unknown relative-style refs untouched.
        ;;
    esac
  done < <(list_deps "$target")
}

validate_bundle() {
  local failed=0
  local target dep

  log "Validating bundled dependencies..."

  while IFS= read -r target; do
    [ -n "$target" ] || continue

    while IFS= read -r dep; do
      [ -n "$dep" ] || continue

      if is_system_lib "$dep"; then
        continue
      fi

      if is_bundle_internal_ref "$dep"; then
        continue
      fi

      echo "ERROR: external dependency remains:" >&2
      echo "  binary: $target" >&2
      echo "  dep:    $dep" >&2
      failed=1
    done < <(list_deps "$target")
  done < <(
    find "$MACOS_DIR" "$FRAMEWORKS_DIR" -type f \
      \( -perm -111 -o -name "*.dylib" -o -name "*.so" \) \
      2>/dev/null
  )

  if [ "$failed" -ne 0 ]; then
    echo "Bundle validation failed." >&2
    exit 1
  fi
}

generate_icon() {
  local source_png="$ICON_PNG"
  local temp_png=""

  if [ ! -f "$source_png" ] && [ -f "$ICON_SVG" ]; then
    temp_png="$TMP_DIR/${ICON_NAME}.png"

    log "Rendering $ICON_SVG..."
    if render_svg_to_png "$ICON_SVG" "$temp_png"; then
      source_png="$temp_png"
    else
      echo "ERROR: $ICON_PNG not found, and failed to render $ICON_SVG." >&2
      echo "Install one of: qlmanage (macOS), rsvg-convert, inkscape." >&2
      exit 1
    fi
  fi

  if [ ! -f "$source_png" ]; then
    return
  fi

  log "Generating $ICON_ICNS from $source_png..."
  local iconset_dir="resources/$ICON_NAME.iconset"
  mkdir -p "$iconset_dir"

  sips -z 16   16   "$source_png" --out "$iconset_dir/icon_16x16.png" >/dev/null
  sips -z 32   32   "$source_png" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
  sips -z 32   32   "$source_png" --out "$iconset_dir/icon_32x32.png" >/dev/null
  sips -z 64   64   "$source_png" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
  sips -z 128  128  "$source_png" --out "$iconset_dir/icon_128x128.png" >/dev/null
  sips -z 256  256  "$source_png" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
  sips -z 256  256  "$source_png" --out "$iconset_dir/icon_256x256.png" >/dev/null
  sips -z 512  512  "$source_png" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
  sips -z 512  512  "$source_png" --out "$iconset_dir/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$source_png" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$iconset_dir" -o "$ICON_ICNS"
  rm -rf "$iconset_dir"

  log "Generated $ICON_ICNS"
}

write_plist() {
  cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_IDENTIFIER</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_NAME</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
</dict>
</plist>
EOF
}

ad_hoc_sign() {
  log "Signing app bundle..."
  /usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
}

create_dmg() {
  mkdir -p "$STAGING_DIR"
  cp -R "$APP_BUNDLE" "$STAGING_DIR/"
  ln -s /Applications "$STAGING_DIR/Applications"

  hdiutil create "$DMG_NAME" \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -quiet

  rm -rf "$STAGING_DIR"

  mv "$DMG_NAME" "$DIST_DIR/"
  mv "$APP_BUNDLE" "$DIST_DIR/$APP_BUNDLE_DIST"
}

# ------------------------------------------------------------
# Build
# ------------------------------------------------------------
log "Building $APP_DISPLAY_NAME v$VERSION..."
shards install

build_args=(-Dpreview_mt -Dexecution_context --release --link-flags "-Wl,-headerpad_max_install_names")
if [ -n "${CRFLAGS:-}" ]; then
  # shellcheck disable=SC2206
  build_args+=($CRFLAGS)
fi

shards build "${build_args[@]}"

# ------------------------------------------------------------
# Bundle layout
# ------------------------------------------------------------
rm -rf "$APP_BUNDLE" "$DMG_NAME" "$STAGING_DIR" "$DIST_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$DIST_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

generate_icon
if [ -f "$ICON_ICNS" ]; then
  cp "$ICON_ICNS" "$RESOURCES_DIR/$ICON_NAME.icns"
fi

write_plist

# ------------------------------------------------------------
# Recursive dependency bundling
# ------------------------------------------------------------
scan_and_bundle_binary "$MACOS_DIR/$APP_NAME" "executable"
validate_bundle
ad_hoc_sign

# ------------------------------------------------------------
# Package
# ------------------------------------------------------------
create_dmg

log "Created: dist/$DMG_NAME"
log "Created: dist/$APP_BUNDLE_DIST"
