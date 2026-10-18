# AU05 Vibe Key × Mac：本機語音輸入與 AI Agent 控制

把 Ulanzi **AU05 Vibe Key**（三鍵＋旋鈕＋麥克風）變成一套**不需要 Ulanzi Studio**、在 Hermes、Codex、Claude、Antigravity 等所有 App 操作都一致的工具：

- 🎤 按一下就能語音輸入，辨識在本機 GPU 上執行（Apple MLX，Whisper large-v3-turbo），輸出臺灣繁體，邊講邊即時預覽
- 中翻英：用本機 Qwen3-4B 翻譯，先顯示中英對照，確認後才貼上
- 用不同的鍵結束錄音，文字就送到不同地方：貼上、貼上並送出、交給 Hermes 在背景執行
- 旋鈕可以捲動、刪字，長按可快速切換 AI agent
- 不連網、不讓廠商軟體常駐，也不讓它安裝 hook

> 實測環境：MacBook Pro（Apple M5 Max）、macOS 27.0.1、Hammerspoon 1.1.1、AU05（USB 接收器）。

---

## 操作方式

### 平常（沒在錄音時）

| 按鍵 | 動作 | 功能 |
|---|---|---|
| 🎤 | 短按 | 開始語音輸入 |
| 🎤 | 按住超過 0.5 秒再放開 | 開始中翻英錄音 |
| ✓ | 按一下 | Enter（確定） |
| × | 按一下 | Esc（取消） |
| 旋鈕 | 短按 | 刪除一個字（Backspace） |
| 旋鈕 | 長按 0.5 秒放開 | 叫出 agent 切換清單 |
| 旋鈕 | 轉動 | 頁面上下捲動 |

### 錄音中（畫面下方有提示框和即時預覽）

| 按鍵 | 功能 |
|---|---|
| 🎤 | 結束，貼上文字 |
| ✓ | 結束，貼上並送出 |
| 旋鈕按下 | 結束，交給 Hermes 在背景處理，完成時跳通知（點通知可看完整回覆） |
| ×（或鍵盤 Esc） | 取消，不貼任何字 |

### 中翻英錄音結束後（顯示中英對照）

| 按鍵 | 功能 |
|---|---|
| ✓ | 貼上英文並送出 |
| 🎤 | 只貼上英文 |
| × | 取消（30 秒沒動作也會自動取消） |

### agent 切換清單開著時（6 秒沒動作自動關閉）

| 按鍵 | 功能 |
|---|---|
| 旋鈕轉動 | 選擇 Hermes／Codex／Claude／Antigravity |
| 旋鈕按下或 ✓ | 切換過去（沒開的 App 會自動啟動） |
| × | 關閉清單 |

**補充**
- 逗號、句號不用唸，模型會自動加；中文旁邊的標點會轉成全形。
- 錄音時選單列會亮橘色麥克風燈，這是 macOS 的隱私提示，結束就熄。
- 單次錄音最長 3 分鐘；即時預覽只看最後 25 秒，但最後貼上的是完整轉寫。
- 預覽只是參考，最後貼上的是整段重新轉寫的版本，會比較準。

---

## 架構

```
AU05 ──USB HID──▶ 送出 F13～F18（已直接寫進裝置，不需要 Ulanzi Studio）
                     │
                     ▼
Hammerspoon（hammerspoon/init.lua）
  ├─ 攔截 F13～F18，依「目前狀態 × 按鍵 × 短按／長按」決定動作
  ├─ ffmpeg 從 AU05 麥克風錄音（16 kHz 單聲道 PCM，即時寫入）
  ├─ 畫面下方的提示框（hs.canvas）：狀態、計時、即時預覽、中英對照
  └─ 貼上：剪貼簿 + ⌘V，0.9 秒後還原原本的剪貼簿
                     │ stdin／stdout JSON
                     ▼
常駐辨識程式（scripts/au05_stt_server.py，模型常駐 GPU）
  ├─ preview／final：mlx-whisper large-v3-turbo → mlx_stt.clean()
  └─ translate：Qwen3-4B-Instruct（MLX 4-bit），第一次使用時才載入
                     │
                     ▼
交給 Hermes：hermes chat -q "<文字>" --oneshot -Q（背景執行）→ macOS 通知
```

| 按鍵 | 寫入 AU05 的位置 | 送出 | macOS keycode |
|---|---|---|---|
| 🎤（上鍵） | 0 | F13 (USB 0x68) | 105 |
| ✓（中鍵） | 1 | F14 (0x69) | 107 |
| ×（下鍵） | 2 | F15 (0x6A) | 113 |
| 旋鈕按下 | 3 | F16 (0x6B) | 106 |
| 旋鈕右轉 | 4 | F17 (0x6C) | 64 |
| 旋鈕左轉 | 5 | F18 (0x6D) | 79 |

**為什麼要用 F13～F18？** 出廠設定送的是 Enter、Esc、Backspace 這類一般按鍵，Mac 分不出是 AU05 還是鍵盤按的：兩者回報的 `keyboardEventKeyboardType` 都是 40。改成鍵盤上沒有的 F13～F18 後，所有功能都可以放心地只綁在 AU05 上，不會干擾鍵盤。

### 效能（M5 Max 實測）

| 項目 | 時間 |
|---|---|
| 即時預覽更新間隔 | 0.5 秒（每次推論約 0.1 秒） |
| 最終轉寫（10 秒語音） | 約 0.1～0.2 秒 |
| 中翻英（首次，含載入模型） | 約 3～4 秒 |
| 中翻英（之後每次） | 約 0.2 秒 |
| 交給 Hermes（簡單問題） | 約 8 秒 |
| 常駐記憶體 | 語音模型約 1.8 GB；第一次翻譯後再加約 2.5 GB |

---

## 安裝

> 路徑沿用作者機器上的配置（`~/.hermes/...`）。要放到別的地方，請同步修改 `hammerspoon/init.lua` 開頭的路徑常數。

### 1. 系統套件

```bash
brew install --cask hammerspoon
# 需要 ffmpeg；腳本預設路徑是 ~/.local/bin/ffmpeg，用 brew 安裝的話請改 init.lua 的 FFMPEG
brew install ffmpeg
```

### 2. Python 環境（隔離的 venv，不動系統 Python）

```bash
uv venv --python 3.12 ~/.hermes/tools/mlx-whisper
VIRTUAL_ENV=~/.hermes/tools/mlx-whisper uv pip install \
  mlx-whisper==0.4.3 mlx-lm==0.32.2 opencc==1.4.2 hidapi==0.15.0
mkdir -p ~/.hermes/scripts
cp scripts/*.py ~/.hermes/scripts/
```

### 3. 模型

```bash
# 語音辨識：第一次執行會自動下載到 ~/.cache/huggingface（約 1.5 GB）
~/.hermes/tools/mlx-whisper/bin/python -c \
  "from huggingface_hub import snapshot_download; snapshot_download('mlx-community/whisper-large-v3-turbo')"

# 翻譯：Qwen3-4B-Instruct-2507 4-bit（約 2.3 GB），直接下載到固定資料夾
D=~/.hermes/tools/models/Qwen3-4B-Instruct-2507-4bit; mkdir -p $D; cd $D
for f in added_tokens.json chat_template.jinja config.json generation_config.json merges.txt \
         model.safetensors.index.json special_tokens_map.json tokenizer.json tokenizer_config.json \
         vocab.json model.safetensors; do
  curl -sSL -C - -o $f https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/main/$f
done
```

> 不要讓兩個 `snapshot_download` 同時下載同一個模型：它們會互相鎖住，檔案一直停在 0 bytes。

### 4. 把按鍵寫進 AU05（不需要 Ulanzi Studio）

先**完全結束 Ulanzi Studio**，再執行：

```bash
P=~/.hermes/tools/mlx-whisper/bin/python
S=~/.hermes/scripts/au05_keymap.py
$P $S set 0 68   # 🎤 → F13
$P $S set 1 69   # ✓  → F14
$P $S set 2 6A   # ×  → F15
$P $S set 3 6B   # 旋鈕按下 → F16
$P $S set 4 6C   # 旋鈕右轉 → F17
$P $S set 5 6D   # 旋鈕左轉 → F18
```

- 寫入前程式會先送「離線模式」指令（`01 01 10 00 00`）；少了這一步，寫入會**沒有任何錯誤但完全不生效**。
- 讀回設定（GET）需要 macOS 的「輸入監控」權限，所以這個工具改用實際按一下來驗證。建議**先寫一顆、按一下確認，再寫其他顆**。
- 修飾鍵用 `m:<位元遮罩>`：`01` Ctrl、`02` Shift、`04` Option、`08` Cmd。例如 `set 0 m:05 10` 代表 Ctrl+Option+M。

### 5. Hammerspoon

```bash
mkdir -p ~/.hammerspoon
cp hammerspoon/init.lua ~/.hammerspoon/init.lua
open -a Hammerspoon
```

- 系統設定 → 隱私權與安全性 → **輔助使用**：打開 Hammerspoon
- 第一次錄音時，允許 Hammerspoon 使用**麥克風**
- 設定檔會讓 Hammerspoon 開機自動啟動，並隱藏選單列和 Dock 圖示

### 6.（選用）Hermes 本身的語音輸入也用同一個模型

```bash
hermes config set --force stt.providers.mlx.type command
hermes config set --force stt.providers.mlx.command \
  "$HOME/.hermes/tools/mlx-whisper/bin/python $HOME/.hermes/scripts/mlx_stt.py {input_path} {output_path} {language}"
hermes config set --force stt.providers.mlx.format txt
hermes config set --force stt.provider mlx
hermes config set stt.language zh
```

### 7. 確認沒有衝突

- **macOS 系統聽寫**：不要設定在相同的按鍵上（建議關閉）。
- **Codex**：它的聽寫只有「全域」快捷鍵，不要設成 ⌃M 或 F13～F18。
- **Ulanzi Studio**：每次開啟都會把 hook 寫回 `~/.codex/hooks.json` 和 `~/.claude/settings.json`，並啟動常駐的 `ustudio-cli`，用完要清掉（見 [docs/lessons.md](docs/lessons.md)）。

---

## 自訂

| 想改的東西 | 位置 |
|---|---|
| 常聽錯的詞（例如「黑犬」→ Codex） | `scripts/mlx_stt.py` 的 `FIXES` |
| 辨識提示詞（專有名詞） | `scripts/mlx_stt.py` 的 `PROMPT` |
| 翻譯風格、專有名詞 | `scripts/au05_stt_server.py` 的 `TRANSLATE_SYSTEM` |
| agent 清單 | `hammerspoon/init.lua` 的 `AGENTS`（App 名稱 + bundle id） |
| 長按門檻、捲動速度、預覽頻率 | `init.lua` 的 `LONG_PRESS`、`SCROLL_LINES`、`PREVIEW_EVERY` |
| 排查按鍵 | `init.lua` 的 `DEBUG_KEYS = true`，紀錄在 `~/.hammerspoon/au05.log` |

改完 Python 後要重啟常駐程式：`pkill -f au05_stt_server`，Hammerspoon 會在 30 秒內自動重新啟動它；或直接執行 `hs -c 'hs.reload()'`。

---

## 隱私

- 錄音只存在 `~/.hammerspoon/au05-rec.pcm`，轉完立即刪除。
- 辨識和翻譯都在本機執行，`HF_HUB_OFFLINE=1`，不連網。
- 只有「交給 Hermes」會把文字交給 Hermes，依它設定的模型處理。
- Ulanzi Studio 可以完全移除：按鍵設定存在 AU05 裡，日常使用不需要它。

## 致謝

AU05 的 HID 通訊格式（TEA 加密、report `0x55`、`01 06 50` 寫入指令）來自以下兩個開源專案的逆向研究；本 repo 的 `au05_keymap.py` 依照這些文件獨立實作，沒有使用任何 Ulanzi 的程式庫。

- [arumwu/vibekey-lite](https://github.com/arumwu/vibekey-lite)（MIT）— `docs/protocol.md`
- [MrCroxx/olanzi](https://github.com/MrCroxx/olanzi)

與 Ulanzi 官方無關。

## 授權

MIT
