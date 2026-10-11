#!/usr/bin/env bash
# ==============================================================================
# setting-up-antigravity-on-android
# Claude Code Setup Script for Google Cloud Vertex AI
# ==============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}   Claude Code on Google Cloud Vertex AI Setup                  ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""

# ------------------------------------------------------------------------------
# 1. 前提ツールの確認 (Node.js & npm)
# ------------------------------------------------------------------------------
echo -e "${BLUE}[1/6] Node.js & npm の確認中...${NC}"
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo -e "${YELLOW}Node.js が見つかりません。NodeSource (Node.js 22.x LTS) からインストールします...${NC}"
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl gnupg
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
else
    echo -e "Node.js はインストール済みです: $(node -v) (npm $(npm -v))"
fi

# ------------------------------------------------------------------------------
# 2. Claude Code CLI (@anthropic-ai/claude-code) の確認とインストール
# ------------------------------------------------------------------------------
echo -e "${BLUE}[2/6] Claude Code CLI (@anthropic-ai/claude-code) の確認中...${NC}"
if ! command -v claude >/dev/null 2>&1; then
    echo -e "Claude Code CLI をグローバルインストール中..."
    npm install -g @anthropic-ai/claude-code
else
    echo -e "Claude Code は既にインストールされています ($(claude --version 2>/dev/null || echo 'installed'))"
fi

# ------------------------------------------------------------------------------
# 3. Google Cloud SDK (gcloud) の確認
# ------------------------------------------------------------------------------
echo -e "${BLUE}[3/6] Google Cloud SDK (gcloud) の確認中...${NC}"
if ! command -v gcloud >/dev/null 2>&1; then
    echo -e "${YELLOW}gcloud が見つかりません。Google Cloud SDK をインストールします...${NC}"
    apt-get update -y
    apt-get install -y --no-install-recommends apt-transport-https ca-certificates gnupg curl
    mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg
    echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" > /etc/apt/sources.list.d/google-cloud-sdk.list
    apt-get update -y
    apt-get install -y --no-install-recommends google-cloud-cli
else
    echo -e "Google Cloud SDK はインストール済みです: $(gcloud --version 2>/dev/null | head -n 1)"
fi

# ------------------------------------------------------------------------------
# 4. プロジェクトIDおよびリージョンの対話的入力
# ------------------------------------------------------------------------------
echo -e "${BLUE}[4/6] Google Cloud プロジェクト設定...${NC}"

# 現在設定されている gcloud プロジェクトの検出
CURRENT_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [ "$CURRENT_PROJECT" = "(unset)" ] || [ -z "$CURRENT_PROJECT" ]; then
    CURRENT_PROJECT="${ANTHROPIC_VERTEX_PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-}}"
fi

PROJECT_ID=""
# 非対話環境（CI等）でプロジェクトIDが引数や環境変数で与えられている場合
if [ -n "${CLAUDE_PROJECT_ID:-}" ]; then
    PROJECT_ID="$CLAUDE_PROJECT_ID"
    echo -e "環境変数からプロジェクトID '${PROJECT_ID}' を使用します。"
else
    # ユーザーに入力させる
    while true; do
        if [ -n "$CURRENT_PROJECT" ]; then
            echo -ne "${BOLD}${YELLOW}Google Cloud プロジェクトIDを入力してください [デフォルト: ${CURRENT_PROJECT}]: ${NC}"
        else
            echo -ne "${BOLD}${YELLOW}Google Cloud プロジェクトIDを入力してください: ${NC}"
        fi
        
        if ! read -r INPUT_PROJECT; then
            # EOFに達した場合
            INPUT_PROJECT=""
        fi
        
        PROJECT_ID="${INPUT_PROJECT:-$CURRENT_PROJECT}"
        # 空白文字を除去
        PROJECT_ID="$(echo "$PROJECT_ID" | tr -d '[:space:]')"

        if [ -n "$PROJECT_ID" ]; then
            break
        fi
        # 非対話かつ入力がない場合は終了
        if [ ! -t 0 ]; then
            echo -e "${RED}[エラー] 非対話モードでプロジェクトIDが指定されていません。${NC}"
            exit 1
        fi
        echo -e "${RED}[エラー] プロジェクトIDは必須です。再度入力してください。${NC}"
    done
fi

echo -e "${GREEN}使用するプロジェクトID: ${PROJECT_ID}${NC}"

# リージョンの入力 (デフォルト: us-east5)
DEFAULT_REGION="${CLOUD_ML_REGION:-us-east5}"
REGION=""
if [ -n "${CLAUDE_REGION:-}" ]; then
    REGION="$CLAUDE_REGION"
    echo -e "環境変数からリージョン '${REGION}' を使用します。"
else
    echo ""
    echo -e "Vertex AI のリージョンを選択してください。"
    echo -e "  - ${CYAN}us-east5${NC}      : 推奨 (Claude 3.7 / 3.5 モデルの主要提供リージョン)"
    echo -e "  - ${CYAN}global${NC}        : グローバルエンドポイント"
    echo -e "  - ${CYAN}europe-west1${NC}  : ヨーロッパリージョン"
    echo -ne "${BOLD}${YELLOW}リージョンを入力してください [デフォルト: ${DEFAULT_REGION}]: ${NC}"
    
    if ! read -r INPUT_REGION; then
        INPUT_REGION=""
    fi
    
    REGION="${INPUT_REGION:-$DEFAULT_REGION}"
    REGION="$(echo "$REGION" | tr -d '[:space:]')"
fi

echo -e "${GREEN}使用するリージョン: ${REGION}${NC}"
echo ""

# gcloud プロジェクトの反映
echo -e "gcloud のデフォルトプロジェクトを '${PROJECT_ID}' に設定中..."
gcloud config set project "$PROJECT_ID" 2>&1 || true

# Vertex AI API の有効化試行
echo -e "Vertex AI API (aiplatform.googleapis.com) の有効化を確認中..."
if gcloud services enable aiplatform.googleapis.com 2>&1; then
    echo -e "${GREEN}Vertex AI API が有効化されました。${NC}"
else
    echo -e "${YELLOW}[注意] Vertex AI API の自動有効化がスキップされたか、権限がありません。${NC}"
    echo -e "後ほど管理者アカウントまたは Cloud Console で有効化されていることを確認してください。"
fi

# ------------------------------------------------------------------------------
# 5. Claude Code 設定ファイル (~/.claude/settings.json) & 環境変数の保存
# ------------------------------------------------------------------------------
echo -e "${BLUE}[5/6] Claude Code の設定を保存中...${NC}"

# ~/.claude/settings.json を Python で安全にマージ・更新
python3 - << EOF
import json
import os

config_dir = os.path.expanduser("~/.claude")
config_file = os.path.join(config_dir, "settings.json")
os.makedirs(config_dir, exist_ok=True)

data = {}
if os.path.exists(config_file):
    try:
        with open(config_file, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}

if "env" not in data or not isinstance(data["env"], dict):
    data["env"] = {}

data["env"]["CLAUDE_CODE_USE_VERTEX"] = "1"
data["env"]["ANTHROPIC_VERTEX_PROJECT_ID"] = "$PROJECT_ID"
data["env"]["CLOUD_ML_REGION"] = "$REGION"

# 自動認証リフレッシュ設定（ADC）
data["gcpAuthRefresh"] = "gcloud auth application-default login --no-launch-browser"

with open(config_file, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print(f"[Claude Code] {config_file} を更新しました。")

# T3 Code (settings.json) の claudeAgent プロバイダを自動構成
t3_settings_path = "/root/.t3/userdata/settings.json"
if os.path.exists(os.path.dirname(t3_settings_path)):
    try:
        t3_data = {}
        if os.path.exists(t3_settings_path):
            with open(t3_settings_path, "r", encoding="utf-8") as f:
                t3_data = json.load(f)
        
        if "providerInstances" not in t3_data:
            t3_data["providerInstances"] = {}
        
        if "claudeAgent" not in t3_data["providerInstances"]:
            t3_data["providerInstances"]["claudeAgent"] = {
                "driver": "claudeAgent",
                "enabled": True,
                "config": {
                    "binaryPath": "/usr/local/bin/claude",
                    "homePath": "",
                    "customModels": [],
                    "launchArgs": "",
                    "autoCompactWindow": ""
                }
            }
        else:
            t3_data["providerInstances"]["claudeAgent"]["enabled"] = True
            if "config" not in t3_data["providerInstances"]["claudeAgent"]:
                t3_data["providerInstances"]["claudeAgent"]["config"] = {}
            t3_data["providerInstances"]["claudeAgent"]["config"]["binaryPath"] = "/usr/local/bin/claude"
        
        with open(t3_settings_path, "w", encoding="utf-8") as f:
            json.dump(t3_data, f, indent=2, ensure_ascii=False)
        print(f"[Claude Code] T3 Code 設定 ({t3_settings_path}) の Claude プロバイダを有効化しました。")
    except Exception as e:
        print(f"[Claude Code] (注意) T3 Code 設定ファイルの更新をスキップしました: {e}")
EOF

# /etc/profile.d/claude-vertex.sh にシステム全体の環境変数を配置
PROFILE_FILE="/etc/profile.d/claude-vertex.sh"
cat << EOF > "$PROFILE_FILE"
# Claude Code Vertex AI Environment Configuration
export CLAUDE_CODE_USE_VERTEX="1"
export ANTHROPIC_VERTEX_PROJECT_ID="${PROJECT_ID}"
export CLOUD_ML_REGION="${REGION}"
EOF
chmod 644 "$PROFILE_FILE"

# 現在のシェルおよび ~/.bashrc にも確実にエクスポート
export CLAUDE_CODE_USE_VERTEX="1"
export ANTHROPIC_VERTEX_PROJECT_ID="${PROJECT_ID}"
export CLOUD_ML_REGION="${REGION}"

if [ -f "/root/.bashrc" ]; then
    sed -i '/CLAUDE_CODE_USE_VERTEX/d' /root/.bashrc 2>/dev/null || true
    sed -i '/ANTHROPIC_VERTEX_PROJECT_ID/d' /root/.bashrc 2>/dev/null || true
    sed -i '/CLOUD_ML_REGION/d' /root/.bashrc 2>/dev/null || true
    echo 'export CLAUDE_CODE_USE_VERTEX="1"' >> /root/.bashrc
    echo "export ANTHROPIC_VERTEX_PROJECT_ID=\"${PROJECT_ID}\"" >> /root/.bashrc
    echo "export CLOUD_ML_REGION=\"${REGION}\"" >> /root/.bashrc
fi

# PRoot Ubuntu 内のコマンドリンク
mkdir -p /usr/local/bin
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ln -sf "${SCRIPT_DIR}/setup-claude-vertex.sh" /usr/local/bin/t3-install-claude 2>/dev/null || true

# Termux コマンドの作成 (Termux 環境が存在する場合)
PREFIX_BIN="/data/data/com.termux/files/usr/bin"
if [ -d "$PREFIX_BIN" ] && [ -w "$PREFIX_BIN" ]; then
    cat << 'EOF' > "${PREFIX_BIN}/t3-install-claude"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- bash /root/setting-up-antigravity-on-android/scripts/setup-claude-vertex.sh
EOF
    chmod +x "${PREFIX_BIN}/t3-install-claude"

    cat << 'EOF' > "${PREFIX_BIN}/claude"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- claude "$@"
EOF
    chmod +x "${PREFIX_BIN}/claude"
    echo -e "[Claude Code] Termux ランチャー (claude, t3-install-claude) を作成しました。"
fi

# ------------------------------------------------------------------------------
# 6. 設定の検証とガイド案内
# ------------------------------------------------------------------------------
echo -e "${BLUE}[6/6] 設定の検証中...${NC}"
echo ""

AUTH_STATUS="$(claude auth status 2>&1 || true)"
echo "$AUTH_STATUS"

# ADC 認証の確認
HAS_ADC=0
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
    HAS_ADC=1
fi

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  Claude Code (Vertex AI) のセットアップが完了しました！        ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "設定内容:"
echo -e "  - プロジェクトID : ${CYAN}${PROJECT_ID}${NC}"
echo -e "  - リージョン     : ${CYAN}${REGION}${NC}"
echo -e "  - プロバイダ     : ${CYAN}Google Cloud Vertex AI${NC}"
echo -e "  - 設定ファイル   : ${CYAN}~/.claude/settings.json${NC}"
echo ""

if [ "$HAS_ADC" -eq 1 ]; then
    echo -e "${GREEN}✓ Application Default Credentials (ADC) は認証済みです。${NC}"
else
    echo -e "${YELLOW}⚠️ 【重要: Google Cloud 認証を行ってください】${NC}"
    echo -e "Claude Code が Vertex AI にアクセスするには ADC (Application Default Credentials) が必要です。"
    echo -e "以下のコマンドを実行して Google アカウントにログインしてください:"
    echo ""
    echo -e "   ${CYAN}gcloud auth application-default login --no-launch-browser${NC}"
    echo ""
    echo -e "表示された認証 URL をブラウザで開き、認証コードをターミナルに貼り付けてください。"
fi

echo ""
echo -e "${YELLOW}💡 【前提条件の確認: Vertex AI Model Garden】${NC}"
echo -e "1. Google Cloud Console で対象プロジェクトの請求 (Billing) が有効になっていること"
echo -e "2. Vertex AI Model Garden で Claude モデルへのアクセスが許可されていること:"
echo -e "   https://console.cloud.google.com/vertex-ai/model-garden"
echo -e "3. アカウントまたはサービスアカウントに以下の IAM 権限が付与されていること:"
echo -e "   - ${CYAN}roles/aiplatform.user${NC} (Vertex AI ユーザー)"
echo ""
echo -e "${GREEN}🚀 利用方法:${NC}"
echo -e "  - 単体 CLI 起動 : ${CYAN}claude${NC}"
echo -e "  - 状態確認      : 起動後に ${CYAN}/status${NC} を入力"
echo -e "  - T3 Code 連携  : ${CYAN}t3-stop && t3-start${NC} で T3 Code サーバーを再起動すると、"
echo -e "                    Web 画面 (http://127.0.0.1:3773) のモデル選択に Claude が有効化されます。"
echo -e "  - 設定再実行    : ${CYAN}t3-install-claude${NC} または ${CYAN}bash /root/setting-up-antigravity-on-android/scripts/setup-claude-vertex.sh${NC}"
echo ""
