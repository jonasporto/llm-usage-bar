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
    [ ! -f "$source_dir/LLM Usage.app/Contents/Info.plist" ]; then
    for command_name in curl tar; do
        command -v "$command_name" >/dev/null 2>&1 ||
            fail "$command_name is required for a one-line install"
    done

    source_url=${LLM_USAGE_BAR_SOURCE_URL:-https://github.com/jonasporto/llm-usage-bar/releases/latest/download/llm-usage-bar-source.tar.gz}
    source_dir="$staging_dir/source"
    source_archive="$staging_dir/source.tar.gz"
    mkdir -p "$source_dir"

    printf 'Downloading llm-usage-bar source...\n'
    curl -fsSL "$source_url" -o "$source_archive"
    tar -xzf "$source_archive" --strip-components=1 -C "$source_dir"
fi

[ -f "$source_dir/Package.swift" ] || fail "the source archive is incomplete"
[ -f "$source_dir/LLM Usage.app/Contents/Info.plist" ] ||
    fail "the app bundle template is incomplete"

printf 'Building llm-usage-bar...\n'
cd "$source_dir"
swift build -c release

binary="$source_dir/.build/release/LLMUsageBar"
info_plist="$source_dir/LLM Usage.app/Contents/Info.plist"
[ -x "$binary" ] || fail "the release binary was not produced"

staged_app="$staging_dir/LLM Usage.app"
mkdir -p "$staged_app/Contents/MacOS"
cp "$info_plist" "$staged_app/Contents/Info.plist"
cp "$binary" "$staged_app/Contents/MacOS/LLMUsageBar"
chmod 755 "$staged_app/Contents/MacOS/LLMUsageBar"
codesign --force --sign - "$staged_app"

mkdir -p "$install_root"
target_app="$install_root/LLM Usage.app"
previous_app="$staging_dir/previous.app"
legacy_app="$install_root/Claude Usage.app"

if command -v pgrep >/dev/null 2>&1; then
    if pgrep -x LLMUsageBar >/dev/null 2>&1 || pgrep -x ClaudeUsageBar >/dev/null 2>&1; then
        osascript -e 'quit app "LLM Usage"' >/dev/null 2>&1 || true
        osascript -e 'quit app "Claude Usage"' >/dev/null 2>&1 || true
    fi
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

if [ -e "$legacy_app" ] || [ -L "$legacy_app" ]; then
    rm -rf -- "$legacy_app"
fi

config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
config_dir="$config_root/llm-usage-bar"
legacy_config_dir="$config_root/claude-usage-bar"
adapters_dir="${XDG_DATA_HOME:-"$HOME/.local/share"}/llm-usage-bar/adapters"
mkdir -p "$config_dir" "$config_dir/icons" "$adapters_dir"

if [ -f "$source_dir/profiles.example.json" ]; then
    cp "$source_dir/profiles.example.json" "$config_dir/profiles.example.json"
fi

# The provider marks are reference art to start an "icon" override from, and
# the starter adapter makes a custom provider a copy away instead of a
# download. The adapters directory is searched before $PATH, so neither
# needs shell setup.
for icon in "$source_dir"/docs/*.svg; do
    [ -f "$icon" ] || continue
    case "$icon" in
        */usage-adapter.example.svg) cp "$icon" "$config_dir/icons/example.svg" ;;
        *) cp "$icon" "$config_dir/icons/" ;;
    esac
done

if [ -f "$source_dir/docs/usage-adapter.example.sh" ]; then
    cp "$source_dir/docs/usage-adapter.example.sh" "$adapters_dir/example-usage"
    chmod 755 "$adapters_dir/example-usage"
fi

# An existing catalog is never overwritten. A pre-rename one is carried over;
# otherwise a one-account starter is written so there is a file to edit.
if [ ! -f "$config_dir/profiles.json" ]; then
    if [ -f "$legacy_config_dir/profiles.json" ]; then
        cp "$legacy_config_dir/profiles.json" "$config_dir/profiles.json"
        printf 'Carried over %s\n' "$legacy_config_dir/profiles.json"
    else
        cat > "$config_dir/profiles.json" <<'PROFILES'
[
  { "id": "personal", "name": "Personal", "provider": "anthropic" }
]
PROFILES
    fi
fi

printf 'Installed at %s\n' "$target_app"
printf 'Accounts: %s\n' "$config_dir/profiles.json"
printf 'Icons:    %s\n' "$config_dir/icons"
printf 'Adapters: %s\n' "$adapters_dir"

if [ "${LLM_USAGE_BAR_SKIP_OPEN:-0}" != "1" ]; then
    open "$target_app"
fi
