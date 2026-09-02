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

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
install_root=${LLM_USAGE_BAR_INSTALL_DIR:-"$HOME/Applications"}

case "$install_root" in
    /*) ;;
    *) fail "the install directory must be an absolute path" ;;
esac

case "$install_root" in
    /|"$HOME") fail "refusing to use a broad install directory" ;;
esac

printf 'Building llm-usage-bar...\n'
cd "$script_dir"
swift build -c release

binary="$script_dir/.build/release/ClaudeUsageBar"
info_plist="$script_dir/Claude Usage.app/Contents/Info.plist"
[ -x "$binary" ] || fail "the release binary was not produced"
[ -f "$info_plist" ] || fail "the app bundle template is incomplete"

staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/llm-usage-bar-install.XXXXXX")
cleanup() {
    if [ -n "${staging_dir:-}" ] && [ -d "$staging_dir" ]; then
        rm -rf -- "$staging_dir"
    fi
}
trap cleanup EXIT HUP INT TERM

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
