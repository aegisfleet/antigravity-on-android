#!/usr/bin/env bash
# ==============================================================================
# antigravity-on-android
# AI CLI tools updater (runs inside the Ubuntu PRoot environment)
#   t3 / Antigravity (agy) / OpenAI Codex / OpenCode / Claude Code / GitHub CLI
# ==============================================================================
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/bin:${HOME}/.local/bin:${PATH}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

UPDATED=0
SKIPPED=0
FAILED=0

info() { echo -e "${CYAN}[更新]${NC} $*"; }
ok()   { echo -e "${GREEN}[完了]${NC} $*"; UPDATED=$((UPDATED + 1)); }
skip() { echo -e "${YELLOW}[スキップ]${NC} $*"; SKIPPED=$((SKIPPED + 1)); }
fail() { echo -e "${RED}[失敗]${NC} $*"; FAILED=$((FAILED + 1)); }
has()  { command -v "$1" >/dev/null 2>&1; }

npm_update() {
    local label="$1"
    local package="$2"
    info "${label} を最新版に更新中 (${package}@latest)..."
    if npm install --global --no-fund --no-audit --loglevel=error "${package}@latest"; then
        ok "${label}"
        return 0
    fi
    fail "${label} の更新に失敗しました (ネットワーク接続を確認してください)"
    return 1
}

# Codex は npm 更新後に静的バイナリへのシンボリックリンクを張り直す
link_codex_binary() {
    local npm_root triple path found
    npm_root="$(npm root --global 2>/dev/null || echo '/usr/lib/node_modules')"

    case "$(uname -m)" in
        aarch64|arm64) triple="aarch64-unknown-linux-musl" ;;
        x86_64)        triple="x86_64-unknown-linux-musl" ;;
        *)             triple="" ;;
    esac

    found=""
    if [ -n "$triple" ]; then
        for path in \
            "${npm_root}/@openai/codex/node_modules/@openai/codex-linux-arm64/vendor/${triple}/bin/codex" \
            "${npm_root}/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/${triple}/bin/codex" \
            "${npm_root}/@openai/codex/vendor/${triple}/bin/codex"; do
            if [ -f "$path" ] && [ -x "$path" ]; then
                found="$path"
                break
            fi
        done
    fi

    if [ -z "$found" ]; then
        found="$(find "${npm_root}/@openai/codex" -type f -name codex -perm -111 2>/dev/null \
            | grep -E 'vendor/.*/bin/codex' | head -n 1 || true)"
    fi

    if [ -n "$found" ] && [ -x "$found" ]; then
        ln -sf "$found" /usr/local/bin/codex
        ok "Codex 静的バイナリを再リンクしました: /usr/local/bin/codex -> $found"
    else
        echo -e "${YELLOW}[注意]${NC} Codex の静的バイナリが見つかりませんでした (npm ラッパーを使用します)"
    fi
}

echo ""
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}   インストール済み AI CLI ツールのアップデートを確認中        ${NC}"
echo -e "${CYAN}================================================================${NC}"

# 1. T3 Code
if has t3; then
    info "T3 Code を最新版に更新中 (t3 update)..."
    if t3 update -y; then
        ok "T3 Code"
    else
        fail "T3 Code の更新に失敗しました"
    fi
else
    skip "T3 Code (t3) は未インストール"
fi

# 2. Antigravity CLI (agy)
if has agy; then
    info "Antigravity CLI (agy) を最新版に更新中 (agy update)..."
    if agy update; then
        ok "Antigravity CLI (agy)"
    else
        fail "Antigravity CLI (agy) の更新に失敗しました"
    fi
else
    skip "Antigravity CLI (agy) は未インストール"
fi

# 3. OpenAI Codex CLI
if ! has npm; then
    skip "OpenAI Codex CLI (npm が未インストール)"
elif has codex || npm list --global --depth=0 @openai/codex >/dev/null 2>&1; then
    if npm_update "OpenAI Codex CLI" "@openai/codex"; then
        link_codex_binary
    fi
else
    skip "OpenAI Codex CLI は未インストール"
fi

# 4. OpenCode CLI
if ! has npm; then
    skip "OpenCode CLI (npm が未インストール)"
elif has opencode || npm list --global --depth=0 @opencode/cli >/dev/null 2>&1; then
    npm_update "OpenCode CLI" "@opencode/cli"
else
    skip "OpenCode CLI は未インストール"
fi

# 5. Claude Code CLI
if ! has npm; then
    skip "Claude Code CLI (npm が未インストール)"
elif has claude || npm list --global --depth=0 @anthropic-ai/claude-code >/dev/null 2>&1; then
    npm_update "Claude Code CLI" "@anthropic-ai/claude-code"
else
    skip "Claude Code CLI は未インストール"
fi

# 6. GitHub CLI (gh)
if has gh; then
    info "GitHub CLI (gh) を最新版に更新中..."
    if apt-get update -qq && apt-get install -y --only-upgrade --no-install-recommends gh; then
        ok "GitHub CLI (gh)"
    else
        fail "GitHub CLI (gh) の更新に失敗しました"
    fi
else
    skip "GitHub CLI (gh) は未インストール"
fi

echo ""
echo "------------------------------------------------------------"
echo -e " アップデート結果: ${GREEN}正常 ${UPDATED} 件${NC} / ${YELLOW}スキップ ${SKIPPED} 件${NC} / ${RED}失敗 ${FAILED} 件${NC}"
echo "------------------------------------------------------------"
echo ""

[ "$FAILED" -eq 0 ]
