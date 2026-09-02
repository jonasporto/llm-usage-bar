#!/bin/sh

set -eu

fail() {
    printf 'llm-usage-bar: %s\n' "$1" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "macOS is required"

for command_name in swift codesign; do
    command -v "$command_name" >/dev/null 2>&1 ||
        fail "$command_name is required"
done

install_root=${LLM_USAGE_BAR_INSTALL_DIR:-"$HOME/Applications"}

case "$install_root" in
    /*) ;;
    *) fail "the install directory must be an absolute path" ;;
esac

case "$install_root" in
    /|"$HOME") fail "refusing to use a broad install directory" ;;
esac

staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/llm-usage-bar-install.XXXXXX")
cleanup() {
    if [ -n "${staging_dir:-}" ] && [ -d "$staging_dir" ]; then
        rm -rf -- "$staging_dir"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

script_dir=
if [ -f "$0" ]; then
    script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fi

source_dir=$script_dir
if [ -z "$source_dir" ] ||
    [ ! -f "$source_dir/Package.swift" ] ||
    [ ! -f "$source_dir/Claude Usage.app/Contents/Info.plist" ]; then
    for command_name in curl tar; do
        command -v "$command_name" >/dev/null 2>&1 ||
            fail "$command_name is required for a one-line install"
    done

    source_url=${LLM_USAGE_BAR_SOURCE_URL:-https://github.com/jonasporto/llm-usage-bar/archive/refs/heads/main.tar.gz}
    source_dir="$staging_dir/source"
    source_archive="$staging_dir/source.tar.gz"
    mkdir -p "$source_dir"

    printf 'Downloading llm-usage-bar source...\n'
    curl -fsSL "$source_url" -o "$source_archive"
    tar -xzf "$source_archive" --strip-components=1 -C "$source_dir"
fi

[ -f "$source_dir/Package.swift" ] || fail "the source archive is incomplete"
[ -f "$source_dir/Claude Usage.app/Contents/Info.plist" ] ||
    fail "the app bundle template is incomplete"

printf 'Building llm-usage-bar...\n'
cd "$source_dir"
swift build -c release

binary="$source_dir/.build/release/ClaudeUsageBar"
info_plist="$source_dir/Claude Usage.app/Contents/Info.plist"
[ -x "$binary" ] || fail "the release binary was not produced"

staged_app="$staging_dir/Claude Usage.app"
mkdir -p "$staged_app/Contents/MacOS"
cp "$info_plist" "$staged_app/Contents/Info.plist"
cp "$binary" "$staged_app/Contents/MacOS/ClaudeUsageBar"
chmod 755 "$staged_app/Contents/MacOS/ClaudeUsageBar"
codesign --force --sign - "$staged_app"

mkdir -p "$install_root"
target_app="$install_root/Claude Usage.app"
previous_app="$staging_dir/previous.app"

if command -v pgrep >/dev/null 2>&1 && pgrep -x ClaudeUsageBar >/dev/null 2>&1; then
    osascript -e 'quit app "Claude Usage"' >/dev/null 2>&1 || true
fi

if [ -e "$target_app" ] || [ -L "$target_app" ]; then
    mv "$target_app" "$previous_app"
fi

if ! mv "$staged_app" "$target_app"; then
    if [ -e "$previous_app" ] || [ -L "$previous_app" ]; then
        mv "$previous_app" "$target_app"
    fi
    fail "could not install the app"
fi

printf 'Installed at %s\n' "$target_app"

if [ "${LLM_USAGE_BAR_SKIP_OPEN:-0}" != "1" ]; then
    open "$target_app"
fi
