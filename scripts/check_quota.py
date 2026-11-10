#!/usr/bin/env python3
"""
Antigravity, Codex & OpenCode Quota Checker
Fetches user quota and rate limits from Google Antigravity backend,
OpenAI Codex CLI backend (if installed), and OpenCode (if installed).
"""
import sys
import os
import json
import time
import shutil
import subprocess
import urllib.request
import urllib.error
from datetime import datetime, timezone

# Antigravity settings
AGY_TOKEN_FILE = "/root/.gemini/antigravity-cli/antigravity-oauth-token"
# The Antigravity web UI and the agy CLI read the daily endpoint. Keep it first
# so t3-quota shows the same values as the web; the production endpoint is only
# a fallback for when the daily one returns no groups.
AGY_QUOTA_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
AGY_QUOTA_FALLBACK_URL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"

# Codex settings
CODEX_HOME = os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex"))
CODEX_AUTH_FILE = os.path.join(CODEX_HOME, "auth.json")

# OpenCode settings
# Only the free DeepSeek model is tracked here; paid Console/Go usage is not
# exposed to unsigned-in installs.
OPENCODE_FREE_MODEL = "deepseek-v4.1-flash-free"
OPENCODE_FREE_MODEL_LABEL = "DeepSeek V4.1 Flash Free"
OPENCODE_FREE_ENDPOINT = "https://opencode.ai/inference/openai/v1/chat/completions"
OPENCODE_FREE_API_KEY = "public"
OPENCODE_FREE_CACHE_FILE = os.path.expanduser("~/.cache/t3-quota/opencode_free.json")
OPENCODE_FREE_CACHE_TTL = 300  # 5分

def get_antigravity_quota_summary():
    """Fetches quota summary from Google Antigravity backend."""
    try:
        with open(AGY_TOKEN_FILE, "r", encoding="utf-8") as f:
            token_data = json.load(f)
        access_token = token_data.get("token", {}).get("access_token")
        if not access_token:
            return {"error": "OAuth access token is empty or missing"}
    except Exception as e:
        return {"error": f"Failed to read oauth token: {e}"}

    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
        # Google returns only the Claude/GPT bucket to the legacy CLI identity.
        # The ACP client identity receives Gemini and Gemini 4 Argon buckets too.
        "User-Agent": "antigravity/acp/1.3.0"
    }

    last_err = None
    for url in (AGY_QUOTA_URL, AGY_QUOTA_FALLBACK_URL):
        req = urllib.request.Request(url, data=b"{}", headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if data and "groups" in data and len(data["groups"]) > 0:
                    return data
                if data and not last_err:
                    last_err = data
        except urllib.error.HTTPError as e:
            last_err = {"error": f"HTTP {e.code}: {e.reason}"}
        except Exception as e:
            last_err = {"error": str(e)}

    return last_err or {"error": "Failed to fetch quota summary"}

def authenticate_antigravity():
    """Run agy's interactive login flow when quota access needs authentication."""
    agy_bin = shutil.which("agy") or "/root/.local/bin/agy"
    if not os.path.isfile(agy_bin) or not os.access(agy_bin, os.X_OK):
        return False, "Antigravity CLI (agy) が見つかりません。agy をインストールしてください。"
    if not sys.stdin.isatty():
        return False, "認証が必要ですが対話端末ではありません。Termux で t3-quota を再実行してください。"

    print("\nGoogle Antigravity の認証が必要です。agy の画面でログインし、完了後に exit してください。\n", flush=True)
    try:
        result = subprocess.run([agy_bin], check=False)
    except Exception as e:
        return False, f"agy の起動に失敗しました: {e}"
    if result.returncode != 0:
        return False, f"agy が終了コード {result.returncode} で終了しました。"
    return True, None

def get_antigravity_quota_with_auth():
    """Authenticate on first use or 401, then retry the quota request once."""
    token_missing = not os.path.isfile(AGY_TOKEN_FILE)
    data = get_antigravity_quota_summary() if not token_missing else {"error": "OAuth token is missing"}
    error = str(data.get("error", "")) if isinstance(data, dict) else ""
    if token_missing or "HTTP 401" in error:
        ok, auth_error = authenticate_antigravity()
        if not ok:
            return {"error": f"{error or 'Google 認証が必要です'}\n{auth_error}"}
        data = get_antigravity_quota_summary()
    return data

def get_codex_quota_summary(timeout=7):
    """
    Fetches rate limits from OpenAI Codex via `codex app-server` JSON-RPC.
    Returns None if Codex is not installed.
    """
    codex_bin = shutil.which("codex") or ("/usr/local/bin/codex" if os.path.exists("/usr/local/bin/codex") else None)
    if not codex_bin:
        return None

    if not os.path.exists(CODEX_AUTH_FILE):
        return {"not_logged_in": True}

    try:
        proc = subprocess.Popen(
            [codex_bin, "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
    except Exception as e:
        return {"error": f"Failed to spawn codex app-server: {e}"}

    def send(msg):
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    try:
        # Step 1: Initialize
        send({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "t3-quota",
                    "version": "1.0.0"
                }
            }
        })

        start_time = time.time()
        limits_resp = None

        while time.time() - start_time < timeout:
            line = proc.stdout.readline()
            if not line:
                break
            try:
                msg = json.loads(line.strip())
            except Exception:
                continue

            msg_id = msg.get("id")
            if msg_id == 1:
                send({"jsonrpc": "2.0", "method": "initialized"})
                send({
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "account/rateLimits/read",
                    "params": {}
                })
            elif msg_id == 2:
                limits_resp = msg.get("result")
                break

        proc.terminate()
        try:
            proc.wait(timeout=1.5)
        except subprocess.TimeoutExpired:
            proc.kill()

        if limits_resp is None:
            return {"error": "Timeout waiting for rate limits from codex app-server"}
        return limits_resp

    except Exception as e:
        try:
            proc.kill()
        except Exception:
            pass
        return {"error": str(e)}

def _read_opencode_free_cache():
    try:
        with open(OPENCODE_FREE_CACHE_FILE, "r", encoding="utf-8") as f:
            cached = json.load(f)
        if time.time() - cached.get("timestamp", 0) < OPENCODE_FREE_CACHE_TTL:
            return cached.get("data")
    except Exception:
        pass
    return None

def _write_opencode_free_cache(data):
    try:
        os.makedirs(os.path.dirname(OPENCODE_FREE_CACHE_FILE), exist_ok=True)
        with open(OPENCODE_FREE_CACHE_FILE, "w", encoding="utf-8") as f:
            json.dump({"timestamp": time.time(), "data": data}, f)
    except Exception:
        pass

def probe_opencode_free_limit(timeout=10, use_cache=True):
    """
    Probes the free DeepSeek endpoint to detect the daily free-tier limit.

    OpenCode does not expose free-tier quota through its API, so send a request
    that stops at validation. The limiter runs first: 400/422 means the request
    was allowed through, while 429 FreeUsageLimitError means the daily free
    quota is exhausted. `Retry-After` points at the next 00:00 UTC reset.
    """
    if use_cache:
        cached = _read_opencode_free_cache()
        if cached:
            return cached

    payload = json.dumps({
        "model": OPENCODE_FREE_MODEL,
        "messages": []
    }).encode("utf-8")
    req = urllib.request.Request(
        OPENCODE_FREE_ENDPOINT,
        data=payload,
        headers={
            "Authorization": f"Bearer {OPENCODE_FREE_API_KEY}",
            "Content-Type": "application/json",
            # Cloudflare rejects Python's default User-Agent (error 1010).
            "User-Agent": "opencode-t3-quota/1.0",
        },
        method="POST",
    )

    now = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp.read()
            result = {"status": "available"}
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")
        except Exception:
            pass

        retry_after = None
        if e.headers is not None:
            raw_retry = e.headers.get("Retry-After")
            if raw_retry:
                try:
                    retry_after = max(0, int(float(raw_retry)))
                except (TypeError, ValueError):
                    retry_after = None

        if e.code == 429 and "FreeUsageLimitError" in body:
            result = {
                "status": "limited",
                "retry_after_seconds": retry_after,
                "reset_epoch": (now + retry_after) if retry_after else None,
                "message": "無料枠の利用上限に達しています",
            }
        elif e.code in (400, 422):
            # The limiter ran before request validation, so reaching this
            # branch means the free quota is still available.
            result = {"status": "available"}
        elif e.code == 429:
            result = {
                "status": "limited",
                "rate_limited": True,
                "retry_after_seconds": retry_after,
                "reset_epoch": (now + retry_after) if retry_after else None,
                "message": "一時的なレート制限中です",
            }
        else:
            result = {"status": "unknown", "error": f"HTTP {e.code}: {e.reason}"}
    except Exception as e:
        result = {"status": "unknown", "error": str(e)}

    if result.get("status") != "unknown":
        _write_opencode_free_cache(result)
    return result

def get_opencode_usage_summary(timeout=15):
    """Reads today's local token usage for the free DeepSeek model."""
    opencode_bin = shutil.which("opencode")
    if not opencode_bin:
        return None

    try:
        proc = subprocess.run(
            [opencode_bin, "stats", "--models", "--days", "0", "--json"],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except Exception as e:
        return {"error": str(e)}

    if proc.returncode != 0:
        return {"error": f"opencode stats failed (exit {proc.returncode})"}
    try:
        stats = json.loads(proc.stdout)
    except Exception as e:
        return {"error": f"invalid opencode stats output: {e}"}

    for entry in stats.get("models", []):
        model = entry.get("model", {})
        if model.get("id") != OPENCODE_FREE_MODEL:
            continue
        if model.get("providerID") and model.get("providerID") != "opencode":
            continue
        tokens = entry.get("tokens", {}) or {}
        cache = tokens.get("cache", {}) or {}
        return {
            "steps": entry.get("steps", 0),
            "input": tokens.get("input", 0),
            "output": tokens.get("output", 0),
            "reasoning": tokens.get("reasoning", 0),
            "cache_read": cache.get("read", 0),
            "cost": entry.get("cost", 0),
        }

    return {
        "steps": 0,
        "input": 0,
        "output": 0,
        "reasoning": 0,
        "cache_read": 0,
        "cost": 0,
    }

def get_opencode_quota_summary():
    """
    Returns OpenCode free-tier status plus today's local usage.
    Returns None when the OpenCode CLI is not installed.
    """
    opencode_bin = shutil.which("opencode")
    if not opencode_bin:
        return None

    return {
        "model": OPENCODE_FREE_MODEL,
        "label": OPENCODE_FREE_MODEL_LABEL,
        "limit": probe_opencode_free_limit(),
        "usage": get_opencode_usage_summary(),
    }

def _format_token_count(count):
    count = int(count or 0)
    if count >= 1000000:
        return f"{count / 1000000:.2f}M"
    if count >= 1000:
        return f"{count / 1000:.1f}K"
    return str(count)

def format_opencode_markdown(data):
    if not data:
        return ""

    title = "### 📊 OpenCode 利用状況 (Quota & Limits)"
    if data.get("error"):
        return f"{title}\n\n⚠️ **OpenCode 利用状況の取得に失敗しました**: {data['error']}"

    limit = data.get("limit") or {}
    status = limit.get("status")
    lines = [title, "", f"#### 🔹 **{data.get('label', OPENCODE_FREE_MODEL_LABEL)}**"]

    if status == "available":
        lines.append("- 🟢 **無料枠**: 利用可能")
    elif status == "limited":
        reset_info = ""
        reset_epoch = limit.get("reset_epoch")
        if reset_epoch:
            rel = parse_relative_time_epoch(reset_epoch)
            reset_at = datetime.fromtimestamp(reset_epoch, timezone.utc).strftime("%m/%d %H:%M UTC")
            reset_info = f" (🔄 回復: 約 {rel} / {reset_at})"
        lines.append(f"- 🔴 **無料枠**: 上限に達しました{reset_info}")
    else:
        err = limit.get("error", "不明なエラー")
        lines.append(f"- ⚪ **無料枠**: 状態を取得できませんでした ({err})")

    usage = data.get("usage")
    if isinstance(usage, dict):
        if usage.get("error"):
            lines.append(f"- ⚠️ **本日の利用量**: 取得に失敗しました ({usage['error']})")
        else:
            steps = usage.get("steps", 0)
            if steps:
                usage_text = (
                    "- 📈 **本日の利用量**: "
                    f"入力 `{_format_token_count(usage.get('input'))}` / "
                    f"出力 `{_format_token_count(usage.get('output'))}`"
                )
                if usage.get("reasoning"):
                    usage_text += f" / 推論 `{_format_token_count(usage.get('reasoning'))}`"
                usage_text += f" トークン (ステップ: {steps})"
                lines.append(usage_text)
            else:
                lines.append("- 📈 **本日の利用量**: まだありません")

    lines.append("- ℹ️ 無料枠は毎日 00:00 UTC にリセットされます。")
    return "\n".join(lines).strip()

def make_bar(fraction, width=15):
    filled = int(round(fraction * width))
    filled = max(0, min(width, filled))
    return "█" * filled + "░" * (width - filled)

def format_duration_mins(minutes):
    if not minutes:
        return ""
    if minutes < 60:
        return f"{minutes}分"
    hours = minutes // 60
    rem_min = minutes % 60
    if hours < 24:
        return f"{hours}時間" + (f"{rem_min}分" if rem_min else "")
    days = hours // 24
    rem_hours = hours % 24
    return f"{days}日" + (f"{rem_hours}時間" if rem_hours else "")

def parse_relative_time_iso(iso_str):
    if not iso_str:
        return ""
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        diff = dt - now
        total_sec = max(0, int(diff.total_seconds()))
        hours = total_sec // 3600
        mins = (total_sec % 3600) // 60
        if hours >= 24:
            days = hours // 24
            rem_hours = hours % 24
            return f"{days}日{rem_hours}時間後"
        elif hours > 0:
            return f"{hours}時間{mins}分後"
        else:
            return f"{mins}分後"
    except Exception:
        return iso_str

def parse_relative_time_epoch(ts):
    if not ts:
        return ""
    try:
        now = time.time()
        diff = ts - now
        total_sec = max(0, int(diff))
        hours = total_sec // 3600
        mins = (total_sec % 3600) // 60
        if hours >= 24:
            days = hours // 24
            rem_hours = hours % 24
            return f"{days}日{rem_hours}時間後"
        elif hours > 0:
            return f"{hours}時間{mins}分後"
        else:
            return f"{mins}分後"
    except Exception:
        return str(ts)

def format_antigravity_markdown(data):
    if "error" in data:
        err = data["error"]
        return f"### 📊 Google Antigravity 利用状況 (Quota & Limits)\n\n⚠️ **クォータ情報の取得に失敗しました**: {err}\n\nTermux で `agy` を起動して Google 認証が完了しているか確認してください。"

    groups = data.get("groups", [])
    if not groups:
        return "### 📊 Google Antigravity 利用状況 (Quota & Limits)\n\n利用状況データが見つかりませんでした。"

    lines = ["### 📊 Google Antigravity 利用状況 (Quota & Limits)", ""]
    for g in groups:
        name = g.get("displayName", "Group")
        desc = g.get("description", "")
        lines.append(f"#### 🔹 **{name}**")
        if desc:
            lines.append(f"*{desc}*")
        lines.append("")
        for b in g.get("buckets", []):
            dname = b.get("displayName", "Limit")
            frac = b.get("remainingFraction", 1.0)
            pct = frac * 100.0
            bar = make_bar(frac)
            rel_time = parse_relative_time_iso(b.get("resetTime", ""))
            reset_info = f" (🔄 全回復: 約 {rel_time})" if rel_time else ""
            
            if pct > 50:
                icon = "🟢"
            elif pct > 20:
                icon = "🟡"
            else:
                icon = "🔴"

            lines.append(f"- {icon} **{dname}**: `[{bar}]` **{pct:.1f}% 残り**{reset_info}")
        lines.append("")

    return "\n".join(lines).strip()

def format_codex_markdown(data):
    if not data:
        return ""

    if data.get("not_logged_in"):
        return (
            "### 📊 OpenAI Codex 利用状況 (Quota & Limits)\n\n"
            "⚠️ **Codex アカウントが未認証です**\n\n"
            "`codex login` でログインすると利用状況が表示されます。"
        )

    if "error" in data:
        err = data["error"]
        return (
            "### 📊 OpenAI Codex 利用状況 (Quota & Limits)\n\n"
            f"⚠️ **Codex 利用状況の取得に失敗しました**: {err}\n\n"
            "`codex login` の認証状態を確認してください。"
        )

    plan_type = str(data.get("rateLimits", {}).get("planType", "unknown")).upper()
    allowed = data.get("ordinaryUsageAllowed", True)
    status_icon = "🟢 利用可能" if allowed else "🔴 利用制限中"

    lines = [
        "### 📊 OpenAI Codex 利用状況 (Quota & Limits)",
        "",
        f"#### 🔹 **ChatGPT アカウント** (プラン: `{plan_type}` / {status_icon})"
    ]

    credits = data.get("rateLimits", {}).get("credits", {})
    if credits.get("hasCredits") and credits.get("balance"):
        lines.append(f"- 💳 **クレジット残高**: `{credits.get('balance')}`")
    elif credits.get("unlimited"):
        lines.append("- 💳 **クレジット**: `無制限`")

    rate_limits = data.get("rateLimits", {})
    windows = []
    if rate_limits.get("primary"):
        windows.append(("プライマリ枠", rate_limits["primary"]))
    if rate_limits.get("secondary"):
        windows.append(("セカンダリ枠", rate_limits["secondary"]))

    by_id = data.get("rateLimitsByLimitId", {})
    for lid, linfo in by_id.items():
        if lid != "codex" and isinstance(linfo, dict):
            name = linfo.get("limitName") or lid
            if linfo.get("primary"):
                windows.append((f"{name} (プライマリ)", linfo["primary"]))
            if linfo.get("secondary"):
                windows.append((f"{name} (セカンダリ)", linfo["secondary"]))

    for title, win in windows:
        used_pct = win.get("usedPercent", 0)
        rem_pct = max(0.0, 100.0 - float(used_pct))
        frac = rem_pct / 100.0
        bar = make_bar(frac)
        dur = win.get("windowDurationMins")
        dur_str = f" ({format_duration_mins(dur)}枠)" if dur else ""
        reset_ts = win.get("resetsAt")
        rel_reset = parse_relative_time_epoch(reset_ts) if reset_ts else ""
        reset_info = f" (🔄 リセット: 約 {rel_reset})" if rel_reset else ""

        if rem_pct > 50:
            icon = "🟢"
        elif rem_pct > 20:
            icon = "🟡"
        else:
            icon = "🔴"

        lines.append(f"- {icon} **{title}**{dur_str}: `[{bar}]` **{rem_pct:.1f}% 残り**{reset_info}")

    return "\n".join(lines).strip()

def format_quota_markdown(agy_data, codex_data=None, opencode_data=None):
    sections = []
    agy_text = format_antigravity_markdown(agy_data)
    if agy_text:
        sections.append(agy_text)

    if codex_data is not None:
        codex_text = format_codex_markdown(codex_data)
        if codex_text:
            sections.append(codex_text)

    if opencode_data is not None:
        opencode_text = format_opencode_markdown(opencode_data)
        if opencode_text:
            sections.append(opencode_text)

    hint = (
        "---\n"
        "> 💡 **ヒント**: モデルグループごとに短期枠や週間・月間枠が設けられています。"
        "残り枠が少なくなった場合は、T3 Code 上で別グループ（Gemini ⇔ Claude ⇔ Codex ⇔ OpenCode）に切り替えることで作業を継続できます。"
    )
    sections.append(hint)
    return "\n\n---\n\n".join(sections[:len(sections)-1]) + "\n\n" + hint

def get_quota_map_short(data):
    """
    Returns a dictionary of group prefix to short remaining string.
    e.g. {'gemini': '5h:73% 週:22%', '3p': '5h:99% 週:99%'}
    """
    res = {}
    if not data or "error" in data:
        return res
    for g in data.get("groups", []):
        dname = g.get("displayName", "").lower()
        bucket_ids = [b.get("bucketId", "").lower() for b in g.get("buckets", [])]
        if "argon" in dname or any("gemini-argon" in bucket_id for bucket_id in bucket_ids):
            key = "gemini_argon"
        elif "gemini" in dname or any(bucket_id.startswith("gemini-") for bucket_id in bucket_ids):
            key = "gemini"
        elif "claude" in dname or "gpt" in dname:
            key = "claude"
        else:
            key = "other"
        b_5h = None
        b_week = None
        for b in g.get("buckets", []):
            w = b.get("window", "")
            pct = int(round(b.get("remainingFraction", 1.0) * 100))
            if w == "5h":
                b_5h = pct
            elif w == "weekly":
                b_week = pct
        parts = []
        if b_5h is not None:
            parts.append(f"5h:{b_5h}%")
        if b_week is not None:
            parts.append(f"週:{b_week}%")
        if parts:
            res[key] = " ".join(parts)
    return res

if __name__ == "__main__":
    agy_data = get_antigravity_quota_with_auth()
    codex_data = get_codex_quota_summary()
    opencode_data = get_opencode_quota_summary()

    if len(sys.argv) > 1 and sys.argv[1] == "--json":
        out = {
            "antigravity": agy_data,
            "codex": codex_data,
            "opencode": opencode_data
        }
        if isinstance(agy_data, dict):
            for k, v in agy_data.items():
                if k not in out:
                    out[k] = v
        print(json.dumps(out, indent=2, ensure_ascii=False))
    elif len(sys.argv) > 1 and sys.argv[1] == "--short":
        print(json.dumps(get_quota_map_short(agy_data), ensure_ascii=False))
    else:
        print(format_quota_markdown(agy_data, codex_data, opencode_data))
