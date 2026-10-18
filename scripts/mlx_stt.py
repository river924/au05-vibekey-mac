#!/usr/bin/env python3
"""本機語音轉文字：mlx-whisper large-v3-turbo（Apple GPU），輸出臺灣繁體。
Hermes 的 STT provider 與 AU05 全域聽寫（Hammerspoon）共用。
Usage: mlx_stt.py <input_audio> <output_txt> [language]
"""
import os
import re
import sys

# 桌面 App 的 PATH 可能不含 ffmpeg 所在目錄
os.environ["PATH"] = os.pathsep.join(
    [os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", "")])
os.environ.setdefault("HF_HUB_OFFLINE", "1")  # 模型已在本機，不連網

import mlx_whisper
import opencc

MODEL = "mlx-community/whisper-large-v3-turbo"
PROMPT = "以下是臺灣繁體中文對話，常夾雜英文，例如 Hermes、Codex、Claude、Antigravity、AU05、Ulanzi、API。"
# 固定誤聽 → 正確詞；常錯的詞加在這裡
FIXES = {
    "黑犬": "Codex", "扣得克斯": "Codex", "CodeX": "Codex", "Code X": "Codex", "Cadet": "Codex",
    "Cloud Code": "Claude Code", "Hermis": "Hermes", "Hermès": "Hermes", "Anti-Gravity": "Antigravity",
    "NT Craft": "Antigravity", "影術": "參數", "引數": "參數",
}
# 靜音時 Whisper 常見的幻覺句
HALLUCINATIONS = re.compile(r"(字幕|訂閱|點贊|點讚|轉發|打賞|明鏡|感謝觀看|謝謝觀看|Amara)")
CJK = r"[\u3400-\u9fff]"
_s2t = opencc.OpenCC("s2tw")


def clean(text: str) -> str:
    text = _s2t.convert(text.strip())
    for wrong, right in FIXES.items():
        text = text.replace(wrong, right)
    if HALLUCINATIONS.search(text) and len(text) < 40:
        return ""
    # 中文旁的半形標點轉全形
    for half, full in ((",", "，"), ("?", "？"), ("!", "！"), (":", "："), (";", "；")):
        text = re.sub(rf"(?<={CJK}){re.escape(half)}|{re.escape(half)}(?={CJK})", full, text)
    return text


def main() -> None:
    src, out = sys.argv[1], sys.argv[2]
    lang = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else "zh"
    r = mlx_whisper.transcribe(src, path_or_hf_repo=MODEL, language=lang, initial_prompt=PROMPT,
                               condition_on_previous_text=False, verbose=None)
    with open(out, "w", encoding="utf-8") as f:
        f.write(clean(r.get("text", "")))


if __name__ == "__main__":
    main()
