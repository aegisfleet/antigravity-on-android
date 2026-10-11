#!/usr/bin/env bash
# ==============================================================================
# setting-up-antigravity-on-android
# Claude Code Bridge for T3 Code (PRoot Ubuntu ARM64)
# ==============================================================================
set -e

# 1. PRoot (root ユーザー) での --dangerously-skip-permissions ブロックを解除
#    Claude Code は root 権限時にこのフラグをブロックするが、PRoot サンドボックス環境では
#    IS_SANDBOX=1 を渡すことで安全に自動ツール実行を許可できる。
export IS_SANDBOX=1

# 2. Vertex AI 設定のロード
if [ -f "/root/.claude/settings.json" ]; then
    V_PROJECT=$(python3 -c "import json; print(json.load(open('/root/.claude/settings.json')).get('env',{}).get('ANTHROPIC_VERTEX_PROJECT_ID',''))" 2>/dev/null || true)
    V_REGION=$(python3 -c "import json; print(json.load(open('/root/.claude/settings.json')).get('env',{}).get('CLOUD_ML_REGION',''))" 2>/dev/null || true)
    [ -n "$V_PROJECT" ] && export ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID:-$V_PROJECT}"
    [ -n "$V_REGION" ] && export CLOUD_ML_REGION="${CLOUD_ML_REGION:-$V_REGION}"
fi

export CLAUDE_CODE_USE_VERTEX="${CLAUDE_CODE_USE_VERTEX:-1}"
export CLOUD_ML_REGION="${CLOUD_ML_REGION:-global}"

# 3. Opus クォータ枯渇 (429 RESOURCE_EXHAUSTED) を回避し、Sonnet 3.7 を既定モデルに設定
#    多くの GCP プロジェクトでは Opus の割当クォータが未割り当てのため、既定を Sonnet 3.7 に固定する
export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-3-7-sonnet@20250219}"
export ANTHROPIC_DEFAULT_SONNET_MODEL="${ANTHROPIC_DEFAULT_SONNET_MODEL:-claude-3-7-sonnet@20250219}"
export ANTHROPIC_DEFAULT_OPUS_MODEL="${ANTHROPIC_DEFAULT_OPUS_MODEL:-claude-3-7-sonnet@20250219}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-claude-3-5-haiku@20241022}"

# 4. 元の claude コマンドを実行
REAL_BIN="/usr/bin/claude"
if [ ! -x "$REAL_BIN" ]; then
    REAL_BIN="$(which claude 2>/dev/null || echo '/usr/bin/claude')"
fi

exec "$REAL_BIN" "$@"
