# 踩坑紀錄與設計決策

這套設定經過大量試錯才定案。以下是實際遇到的問題和最後的解法，可以讓後來的人（或 agent）少走冤枉路。

> **最重要的一條：動手前先查官方文件和開源社群的逆向研究。** 這裡大部分的坑，社群文件早就寫過了。

## 1. 為什麼不用各 App 自己的聽寫

一開始的設計是 AU05 送 ⌃M，讓每個 App 用自己的聽寫功能，結果四個 App 各有各的狀況：

| App | 問題 |
|---|---|
| Codex | 只有「全域」聽寫快捷鍵，沒有只在 App 內作用的版本。只要 Codex 開著，就會搶走其他 App 的 ⌃M |
| Claude 桌面版 | 帳號的 managed config 是 `"dictationAvailable": false`：會出現錄音中的點點，但永遠不出字 |
| Antigravity | 不接受直接送到它行程的按鍵（`event:post(app)`），一定要真正的系統層按鍵 |
| macOS 系統聽寫 | 會被其他 agent 悄悄打開並綁上同一個鍵（本案是 Antigravity 的 agent 把它設成 ⌃M）。它會邊講邊出字，但準確度較差 |

再加上有的要「按住」、有的要「按一下開關」，操作邏輯完全不一致。

**解法**：所有 App 共用同一套 Hammerspoon 語音輸入加本機模型，操作邏輯和辨識品質完全一致。

**排查原則**：同一個按鍵在 A 可以用、在 B 不行，或行為不一樣時，先把所有可能註冊這個鍵的地方列出來（Codex `~/.codex/keybindings.json`、Claude `claude_desktop_config.json`、macOS 系統聽寫 `com.apple.speech.recognition.AppleSpeechRecognition.prefs` 的 `CustomizedDictationHotKey` 和 `symbolichotkeys` 164），再從紀錄確認文字實際是哪個引擎產生的。

## 2. Ulanzi Studio 的問題

- 每次開啟都會：
  - 在 `~/.codex/hooks.json`、`~/.claude/settings.json`、`~/.gemini/config/hooks.json` 寫入 hook
  - 啟動常駐的 `ustudio-cli --singleton-server`
  - 內建當機回報和 Countly 使用分析
  - 要求「輔助使用」權限（拒絕也不影響改按鍵）
- Mac 版 3.4.4 **寫入多個修飾鍵的組合時會出錯**：`⌃ ⌥  1`、`⌃ ⌥ ⇧ ⌘  1` 脫機後都只送出單純的 `1`，會直接打字到 App 裡。只有單一修飾鍵（`⌃  M`）正常。韌體本身支援組合鍵，社群已經實測過。
- 手動輸入的熱鍵字串（`Ctrl+M`）存得進去但不會觸發，必須用它的錄製欄位按實體鍵盤，存成 `⌃  M` 這種格式（符號加兩個空格）。
- 預設設定的旋鈕右轉，標籤是簡繁混用的「鼠標滚輪下」。
- 不能在改完後馬上強制結束（`pkill`）：裝置只記得最後一次**完成**的同步，會留下錯亂的設定。
- `/Applications/Ulanzi Studio.app` 屬於 root，移除要用 Finder 移到垃圾桶，再由使用者輸入密碼清空。

**解法**：完全不用它。依開源協定，用 `scripts/au05_keymap.py` 直接寫入裝置。

## 3. 直接寫入 AU05 的注意事項

- 介面：VID `0xFFF1`、PID `0x00DD`、usage page `0xFFFC`、usage `1`（同時還有標準 HID 介面，不要選錯）
- 封包：`0x55` 加上 TEA 加密後 64 bytes 的前 63 bytes；先用文件的測試向量驗證 TEA 實作
- **寫入前必須先送離線模式 `01 01 10 00 00`**，否則寫入沒有任何錯誤，但完全不生效
- 寫入指令：`01 06 50 04 <位置> 01 <筆數> <page> <值>...`
  - 一般按鍵：page `0x02`，值是 USB 鍵盤用法碼
  - 修飾鍵：page `0x03`，值是**位元遮罩**（`01` Ctrl、`02` Shift、`04` Option、`08` Cmd），不是 `E0`～`E7`
- 位置：0 上鍵、1 中鍵、2 下鍵、3 旋鈕按下、4 旋鈕右轉、5 旋鈕左轉
- 寫入後，Studio 原本的「滑鼠滾輪」旋轉功能會消失，所以旋轉也改成 F17／F18，由 Hammerspoon 轉成捲動
- GET（讀回設定）沒有「輸入監控」權限就收不到回覆，改用實際按一下來驗證

## 4. Hammerspoon 細節

- AU05 按住時會連續重複送出按下訊號（每秒約 12 次）；放開訊號可能沒有修飾鍵旗標。要用「按住中」旗標加 1.5 秒的保險計時器去重複，避免卡在按住狀態
- ffmpeg 輸出要加 `-flush_packets 1`，不然資料會卡在緩衝區 2 秒以上，即時預覽一直拿不到最新的聲音
- 停止 ffmpeg 用 `interrupt()`（SIGINT），檔案才會正常收尾
- 貼上用 `hs.eventtap.keyStroke({"cmd"},"v")`，**用預設延遲**；設成 `0` 在部分 App 不會觸發
- 桌面 App 啟動的子程式，PATH 裡沒有 `~/.local/bin`：ffmpeg 要寫絕對路徑，Python 腳本自己補 PATH
- `require("hs.ipc")` 之後，可以用 `/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c 'return au05.state'` 在背景檢查狀態，不用跳視窗測試

## 5. 語音辨識

- faster-whisper 在 Mac 上只能用 CPU：`base` 模型沒固定語言時，會把中英夾雜辨識成德文或英文；`large-v3-turbo` 準確但要 4～5 秒
- 改用 mlx-whisper（GPU），模型常駐後一次只要約 0.1 秒
- Whisper 的中文偏向簡體：用臺灣繁體的 `initial_prompt` 引導，再用 OpenCC 轉字形
- OpenCC 用 **`s2tw`**，不要用 `s2twp`：後者會換詞，例如「参数」變成「引數」
- 固定聽錯的詞，用 `FIXES` 做最後校正（例如「黑犬」改成 Codex、「影術」改成參數）
- 靜音時 Whisper 常會冒出幻覺句（字幕、訂閱、點讚…），短句直接過濾掉
- 用 `say` 產生測試音檔時，Eddy、Flo 這兩個聲音會**直接跳過中文**，造成「模型很爛」的假象；要用 Meijia 或 Tingting，並檢查音檔長度
- 不要在使用者面前播放測試語音或跳出測試視窗，用音檔測試就好

## 6. 中翻英

- 用 Whisper 的 translate 功能不可靠（turbo 版本沒有針對翻譯訓練），改用本機語言模型 Qwen3-4B-Instruct
- system prompt 要求它順便修正明顯的辨識錯誤，並保留專有名詞和程式碼
- 一定先顯示中英對照，確認後才貼上，避免辨識錯了還直接送出
