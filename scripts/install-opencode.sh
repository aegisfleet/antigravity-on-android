#!/usr/bin/env bash
# Install/update OpenCode and apply the private aegisfleet global settings.
set -euo pipefail

SETTINGS_REPO="${OPENCODE_SETTINGS_REPO:-https://github.com/aegisfleet/opencode-settings.git}"
SETTINGS_DIR="${OPENCODE_SETTINGS_DIR:-${HOME}/.cache/aegisfleet/opencode-settings}"
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_FILE="${CONFIG_DIR}/opencode.jsonc"

if ! command -v npm >/dev/null 2>&1; then
    echo "[OpenCode] npm が見つかりません。先に Node.js をインストールしてください。" >&2
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    echo "[OpenCode] git が見つかりません。" >&2
    exit 1
fi

echo "[OpenCode] 最新版をインストール中..."
if npm list --global opencode-ai --depth=0 >/dev/null 2>&1; then
    npm uninstall --global opencode-ai
fi
npm install --global @opencode/cli@latest

echo "[OpenCode] プライベート設定リポジトリを同期中..."
mkdir -p "$(dirname "$SETTINGS_DIR")"
if [ -d "${SETTINGS_DIR}/.git" ]; then
    git -C "$SETTINGS_DIR" fetch --prune origin
    branch="$(git -C "$SETTINGS_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
    if [ -z "$branch" ]; then
        branch="$(git -C "$SETTINGS_DIR" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -n 1)"
    fi
    if [ -z "$branch" ]; then
        echo "[OpenCode] 設定リポジトリの既定ブランチを特定できません。" >&2
        exit 1
    fi
    git -C "$SETTINGS_DIR" checkout -q "$branch"
    git -C "$SETTINGS_DIR" pull --ff-only origin "$branch"
else
    git clone --depth=1 "$SETTINGS_REPO" "$SETTINGS_DIR"
fi

source_config="${SETTINGS_DIR}/opencode.jsonc"
if [ ! -f "$source_config" ]; then
    echo "[OpenCode] 設定ファイルが見つかりません: $source_config" >&2
    exit 1
fi
node -e 'const fs=require("fs"); const s=fs.readFileSync(process.argv[1],"utf8").replace(/^\uFEFF/,""); JSON.parse(s)' "$source_config"

mkdir -p "$CONFIG_DIR"
if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
    backup="${CONFIG_FILE}.$(date -u +%Y%m%dT%H%M%SZ).bak"
    cp -p "$CONFIG_FILE" "$backup"
    echo "[OpenCode] 既存設定をバックアップしました: $backup"
fi
install -m 600 "$source_config" "$CONFIG_FILE"

echo "[OpenCode] 設定を適用しました: $CONFIG_FILE"
opencode --version
