#!/usr/bin/env python3
"""AU05 語音輸入常駐程式（由 Hammerspoon 啟動）。模型常駐 GPU。
stdin 每行一個 JSON：
  {"id": n, "mode": "preview"|"final", "pcm": "<16kHz mono s16le 檔>"}   語音 → 中文
  {"id": n, "mode": "translate", "text": "<中文>"}                         中文 → 英文（本機 Qwen3-4B）
stdout 每行回一個 JSON：{"id": n, "mode": ..., "text": ..., "sec": 耗時}
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402

import mlx_whisper  # noqa: E402
from mlx_stt import MODEL, PROMPT, clean  # noqa: E402

RATE = 16000
PREVIEW_TAIL_SEC = 25  # 預覽只轉最後 25 秒，長錄音也不會越來越慢
LLM = os.path.expanduser("~/.hermes/tools/models/Qwen3-4B-Instruct-2507-4bit")
TRANSLATE_SYSTEM = (
    "You translate Taiwanese Mandarin speech-recognition output into natural, concise English. "
    "The input may contain recognition errors; fix obvious ones from context "
    "(e.g. 黑犬 or 扣得克斯 means 'Codex', 影術/引數 means 參數 'parameter'). "
    "Known names: Hermes, Codex, Claude, Claude Code, Antigravity, AU05, Ulanzi, ComfyUI, Hammerspoon. "
    "Keep code, file names and English terms unchanged. Output only the English translation."
)
_llm = None


def load_pcm(path: str, tail_sec: float = 0) -> np.ndarray:
    with open(path, "rb") as f:
        raw = f.read()
    raw = raw[: len(raw) // 2 * 2]
    audio = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if tail_sec:
        audio = audio[-int(tail_sec * RATE):]
    return audio


def transcribe(audio: np.ndarray) -> str:
    if audio.size < RATE * 0.3:
        return ""
    r = mlx_whisper.transcribe(audio, path_or_hf_repo=MODEL, language="zh", initial_prompt=PROMPT,
                               condition_on_previous_text=False, verbose=None)
    return clean(r.get("text", ""))


def translate(text: str) -> str:
    global _llm
    from mlx_lm import generate, load
    if _llm is None:
        _llm = load(LLM)  # 第一次翻譯時載入，之後常駐
    model, tok = _llm
    prompt = tok.apply_chat_template(
        [{"role": "system", "content": TRANSLATE_SYSTEM}, {"role": "user", "content": text}],
        add_generation_prompt=True, tokenize=False)
    return generate(model, tok, prompt, max_tokens=600).strip()


def reply(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle(req: dict) -> str:
    mode = req.get("mode")
    if mode == "translate":
        return translate(req.get("text", ""))
    return transcribe(load_pcm(req["pcm"], PREVIEW_TAIL_SEC if mode == "preview" else 0))


def main() -> None:
    transcribe(np.zeros(RATE, dtype=np.float32))  # 預熱，把語音模型載入 GPU
    reply({"id": 0, "mode": "ready", "text": ""})
    for line in sys.stdin:
        req = {}
        try:
            req = json.loads(line)
            t = time.time()
            text = handle(req)
            reply({"id": req.get("id"), "mode": req.get("mode"), "text": text, "sec": round(time.time() - t, 2)})
        except Exception as exc:  # 單次失敗不讓常駐程式掛掉
            reply({"id": req.get("id"), "mode": "error", "for": req.get("mode"), "text": "",
                   "error": str(exc)[-300:]})


if __name__ == "__main__":
    main()
