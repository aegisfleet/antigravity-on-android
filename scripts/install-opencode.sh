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
npm_root="$(npm root --global)"
installed_version="$(node -e 'try { console.log(require(process.argv[1]).version) } catch {}' "${npm_root}/@opencode/cli/package.json")"
latest_version="$(npm view @opencode/cli version)"
if [ "$installed_version" != "$latest_version" ]; then
    npm install --global @opencode/cli@latest
else
    echo "[OpenCode] 最新版です (@opencode/cli ${installed_version})。更新をスキップします。"
fi

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

echo "[OpenCode] Termux 完了通知プラグインをセットアップ中..."
mkdir -p "${CONFIG_DIR}/plugins"
install -m 644 "$(dirname "${BASH_SOURCE[0]}")/opencode-termux-notification.js" \
    "${CONFIG_DIR}/plugins/termux-notification.js"

echo "[OpenCode] T3 Code の OpenCode プロバイダーを有効化中..."
python3 - <<'PY'
import json
import os

path = "/root/.t3/userdata/settings.json"
data = {}
if os.path.isfile(path):
    with open(path, "r", encoding="utf-8") as stream:
        data = json.load(stream)

instances = data.setdefault("providerInstances", {})
instance = instances.setdefault("opencode", {})
instance["driver"] = "opencode"
instance["enabled"] = True
config = instance.setdefault("config", {})
config["binaryPath"] = "/usr/bin/opencode"

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream, indent=2, ensure_ascii=False)
PY

echo "[OpenCode] 設定を適用しました: $CONFIG_FILE"
opencode --version
