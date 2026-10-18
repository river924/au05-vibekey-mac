-- AU05 Vibe Key 控制（river，2026-10-18）
-- AU05 送出的鍵（用 ~/.hermes/scripts/au05_keymap.py 直接寫進裝置，不需 Ulanzi Studio）：
--   🎤 F13　✓ F14　× F15　旋鈕按下 F16　旋鈕右轉 F17　旋鈕左轉 F18
--
-- 規則：按 🎤 開始說話；用哪顆鍵結束，決定文字去哪裡
--   結束按 🎤   → 貼上
--   結束按 ✓    → 貼上並送出（Enter）
--   結束按旋鈕   → 交給 Hermes 在背景執行，完成時通知
--   按 ×        → 取消
--   開始時按住 🎤 超過 0.5 秒 → 中翻英：先顯示中文＋英文，✓ 貼上並送出 / 🎤 只貼上 / × 取消
-- 沒在錄音時：✓＝Enter、×＝Esc、旋鈕短按＝刪除、旋鈕長按＝切換 Agent（轉旋鈕選、按下或 ✓ 切過去、× 取消）
-- 旋鈕轉動＝上下捲動
--
-- 辨識：本機 GPU（mlx-whisper large-v3-turbo，臺灣繁體）；翻譯：本機 Qwen3-4B。錄音轉完即刪；
-- 只有「交給 Hermes」會把文字交給 Hermes 依它的設定處理。

require("hs.ipc")
hs.autoLaunch(true)
hs.menuIcon(false)
hs.dockicon.hide()
hs.automaticallyCheckForUpdates(true)

local HOME = os.getenv("HOME")
local FFMPEG = HOME .. "/.local/bin/ffmpeg"
local PY = HOME .. "/.hermes/tools/mlx-whisper/bin/python"
local SERVER = HOME .. "/.hermes/scripts/au05_stt_server.py"
local HERMES = HOME .. "/.hermes/hermes-agent/.hermes/bin/hermes"
local PCM = HOME .. "/.hammerspoon/au05-rec.pcm"
local TASK_DIR = HOME .. "/.hammerspoon/hermes-tasks"
local LOG = HOME .. "/.hammerspoon/au05.log"
local MIC = ":AU05"
local MAX_SECONDS = 180
local PREVIEW_EVERY = 0.5
local LONG_PRESS = 0.5
DEBUG_KEYS = false  -- 設 true 可記錄 AU05 相關按鍵以排查

local AGENTS = {
  { name = "Hermes", id = "com.nousresearch.hermes" },
  { name = "Codex", id = "com.openai.codex" },
  { name = "Claude", id = "com.anthropic.claudefordesktop" },
  { name = "Antigravity", id = "com.google.antigravity" },
}

local km = hs.keycodes.map
local KEYS = { [km["f13"]] = "mic", [km["f14"]] = "ok", [km["f15"]] = "x", [km["f16"]] = "knob",
  [km["f17"]] = "cw", [km["f18"]] = "ccw" }
local SCROLL_LINES = 3
local ESC = km["escape"]
local types = hs.eventtap.event.types
local props = hs.eventtap.event.properties

local function log(msg)
  local f = io.open(LOG, "a")
  if f then f:write(os.date("%H:%M:%S "), msg, "\n"); f:close() end
end

au05 = { state = "idle" }
local rec = {}            -- 這次錄音：endAction / translate / startedByPress
local recTask, maxTimer, previewTimer, hideTimer, confirmTimer, switcherTimer
local server, serverBuf = nil, ""
local reqId, previewInFlight, finalId, translateId, recStart, previewText = 0, false, nil, nil, 0, ""
local confirm = {}        -- 中翻英確認：zh / en
local sel = 1             -- Agent 切換選擇

---------------------------------------------------------------- 提示框
local W, H = 760, 176
local function frame()
  local s = hs.screen.mainScreen():frame()
  return { x = s.x + (s.w - W) / 2, y = s.y + s.h - H - 60, w = W, h = H }
end

au05Box = hs.canvas.new(frame()):level(hs.canvas.windowLevels.overlay)
  :behavior({ "canJoinAllSpaces", "stationary" })
au05Box:appendElements(
  { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 16, yRadius = 16 },
    fillColor = { red = 0.08, green = 0.08, blue = 0.1, alpha = 0.92 } },
  { id = "status", type = "text", text = "", frame = { x = 22, y = 14, w = W - 44, h = 28 },
    textSize = 17, textColor = { red = 1, green = 0.45, blue = 0.4 } },
  { id = "body", type = "text", text = "", frame = { x = 22, y = 46, w = W - 44, h = H - 56 },
    textSize = 19, textColor = { white = 1 } })

local function show(status, body)
  if hideTimer then hideTimer:stop(); hideTimer = nil end
  au05Box:frame(frame())
  au05Box["status"].text = status
  if body then au05Box["body"].text = body end
  au05Box:show()
end

local function hide(status, delay)
  if status then show(status, "") end
  if hideTimer then hideTimer:stop() end
  hideTimer = hs.timer.doAfter(delay or 0, function() au05Box:hide(); hideTimer = nil end)
end

local function tail(text, n)
  local len = utf8.len(text) or #text
  if len <= n then return text end
  return "…" .. text:sub(utf8.offset(text, len - n + 1))
end

local function recStatus()
  local s = math.floor(hs.timer.secondsSinceEpoch() - recStart)
  local head = rec.translate and "🌐 中翻英錄音中 " or "🎙 錄音中 "
  return head .. string.format("%d:%02d", s // 60, s % 60) .. "　🎤 貼上 · ✓ 貼上送出 · 旋鈕 交給 Hermes · × 取消"
end

---------------------------------------------------------------- 輸出
local function pasteText(text, pressEnter)
  local saved = hs.pasteboard.readAllData()
  hs.pasteboard.setContents(text)
  hs.timer.doAfter(0.05, function()
    hs.eventtap.keyStroke({ "cmd" }, "v")
    if pressEnter then hs.timer.doAfter(0.2, function() hs.eventtap.keyStroke({}, "return") end) end
    hs.timer.doAfter(0.9, function() if saved then hs.pasteboard.writeAllData(saved) end end)
  end)
end

local function sendToHermes(text)
  hs.fs.mkdir(TASK_DIR)
  local out = TASK_DIR .. "/" .. os.date("%Y%m%d-%H%M%S") .. ".txt"
  hide("🤖 已交給 Hermes：" .. tail(text, 40), 2)
  log("交給 Hermes：" .. text)
  hs.task.new(HERMES, function(code, stdout, stderr)
    local f = io.open(out, "w")
    if f then f:write("【指令】", text, "\n\n【Hermes 回覆】\n", stdout or "", "\n", code ~= 0 and (stderr or "") or ""); f:close() end
    log("Hermes 完成 code=" .. tostring(code))
    local summary = (stdout or ""):gsub("session_id:%s*%S+", ""):gsub("%s+", " ")
    hs.notify.new(function() hs.execute("open " .. string.format("%q", out)) end, {
      title = code == 0 and "Hermes 完成" or "Hermes 執行失敗",
      subTitle = tail(text, 40),
      informativeText = tail(summary ~= "" and summary or (stderr or ""), 200),
      withdrawAfter = 0,
    }):send()
  end, { "chat", "-q", text, "--oneshot", "-Q" }):start()
end

---------------------------------------------------------------- 中翻英確認
local function endConfirm(msg)
  if confirmTimer then confirmTimer:stop(); confirmTimer = nil end
  au05.state = "idle"
  if msg then hide(msg, 0.8) else hide() end
end

local function confirmPaste(pressEnter)
  local en = confirm.en
  endConfirm()
  pasteText(en, pressEnter)
end

---------------------------------------------------------------- 常駐辨識程式
local function finishText(text)
  if text == "" then au05.state = "idle"; hide("沒有聽到內容", 1.2); return end
  if rec.endAction == "hermes" then au05.state = "idle"; sendToHermes(text); return end   -- 交給 Hermes 一律用中文原文
  if rec.translate then
    au05.state = "translating"
    confirm = { zh = text }
    show("🌐 翻譯中…", "中：" .. tail(text, 120))
    translateId = au05.request("translate", { text = text })
    return
  end
  au05.state = "idle"
  if rec.endAction == "hermes" then sendToHermes(text); return end
  hide()
  pasteText(text, rec.endAction == "enter")
end

local function onReply(msg)
  if msg.mode == "ready" then log("辨識程式就緒"); return end
  if msg.mode == "error" then
    log("錯誤(" .. tostring(msg["for"]) .. "): " .. tostring(msg.error))
    previewInFlight = false
    if au05.state == "transcribing" or au05.state == "translating" then
      au05.state = "idle"; hide("⚠️ 處理失敗", 1.5)
    end
    return
  end
  if msg.mode == "preview" then
    previewInFlight = false
    if au05.state == "recording" and msg.text ~= "" then
      previewText = msg.text
      show(recStatus(), tail(previewText, 80))
    end
  elseif msg.mode == "final" and msg.id == finalId and au05.state == "transcribing" then
    os.remove(PCM)
    log(string.format("轉寫完成 %.2fs 字數=%d 結束方式=%s%s", msg.sec or -1, utf8.len(msg.text or "") or 0,
      tostring(rec.endAction), rec.translate and " 中翻英" or ""))
    finishText(msg.text or "")
  elseif msg.mode == "translate" and msg.id == translateId and au05.state == "translating" then
    log(string.format("翻譯完成 %.2fs", msg.sec or -1))
    confirm.en = msg.text or ""
    if confirm.en == "" then au05.state = "idle"; hide("⚠️ 翻譯失敗", 1.5); return end
    au05.state = "confirm"
    show("🌐 中翻英　✓ 貼上並送出 · 🎤 只貼上 · × 取消",
      "中：" .. tail(confirm.zh, 70) .. "\nEN：" .. tail(confirm.en, 160))
    confirmTimer = hs.timer.doAfter(30, function() if au05.state == "confirm" then endConfirm("已逾時取消") end end)
  end
end

local function ensureServer()
  if server and server:isRunning() then return end
  serverBuf = ""
  server = hs.task.new(PY, function(code, _, err)
    log("辨識程式結束 code=" .. tostring(code) .. " " .. (err or ""):sub(-200))
    server = nil
    previewInFlight = false
    if au05.state == "transcribing" or au05.state == "translating" then au05.state = "idle"; hide("⚠️ 處理失敗", 1.5) end
  end, function(_, out, _)
    serverBuf = serverBuf .. (out or "")
    while true do
      local line, rest = serverBuf:match("^(.-)\n(.*)$")
      if not line then break end
      serverBuf = rest
      local ok, msg = pcall(hs.json.decode, line)
      if ok and msg then onReply(msg) end
    end
    return true
  end, { "-u", SERVER })
  server:start()
end

function au05.request(mode, extra)
  ensureServer()
  reqId = reqId + 1
  local req = { id = reqId, mode = mode, pcm = PCM }
  for k, v in pairs(extra or {}) do req[k] = v end
  server:setInput(hs.json.encode(req) .. "\n")
  return reqId
end

---------------------------------------------------------------- 錄音
local function stopTimers()
  if maxTimer then maxTimer:stop(); maxTimer = nil end
  if previewTimer then previewTimer:stop(); previewTimer = nil end
end

local function startRecording()
  ensureServer()
  os.remove(PCM)
  rec = { endAction = "paste", translate = false }
  previewText, previewInFlight = "", false
  recTask = hs.task.new(FFMPEG, function(code, _, err)
    recTask = nil
    stopTimers()
    if au05.state == "cancelled" then au05.state = "idle"; os.remove(PCM); return end
    if au05.state ~= "stopping" then        -- 錄音程式自己結束了（通常是麥克風權限）
      au05.state = "idle"
      log("錄音異常 code=" .. tostring(code) .. " " .. (err or ""):sub(-300))
      hide("⚠️ 無法錄音：請允許 Hammerspoon 使用麥克風", 3)
      return
    end
    au05.state = "transcribing"
    show("⏳ 轉文字中…", tail(previewText, 80))
    finalId = au05.request("final")
  end, { "-hide_banner", "-loglevel", "error", "-y", "-f", "avfoundation", "-i", MIC,
         "-ac", "1", "-ar", "16000", "-t", tostring(MAX_SECONDS), "-flush_packets", "1", "-f", "s16le", PCM })
  if not recTask:start() then au05.state = "idle"; hide("⚠️ 無法啟動錄音", 1.5); return end
  au05.state = "recording"
  recStart = hs.timer.secondsSinceEpoch()
  show(recStatus(), "（開始說話…）")
  previewTimer = hs.timer.doEvery(PREVIEW_EVERY, function()
    if au05.state ~= "recording" then return end
    au05Box["status"].text = recStatus()
    if not previewInFlight and (hs.fs.attributes(PCM, "size") or 0) > 9600 then
      previewInFlight = true
      au05.request("preview")
    end
  end)
  maxTimer = hs.timer.doAfter(MAX_SECONDS + 1, function() if au05.state == "recording" then au05.stop("paste") end end)
  local app = hs.application.frontmostApplication()
  log("開始錄音 -> " .. (app and app:name() or "?"))
end

function au05.stop(endAction)
  if au05.state ~= "recording" or not recTask then return end
  rec.endAction = endAction or "paste"
  au05.state = "stopping"
  recTask:interrupt()                       -- SIGINT：ffmpeg 正常收尾
end

function au05.cancel()
  if au05.state ~= "recording" or not recTask then return end
  au05.state = "cancelled"
  recTask:terminate()
  hide("已取消", 0.8)
  log("取消")
end

---------------------------------------------------------------- Agent 切換
local function switcherBody()
  local lines = {}
  for i, a in ipairs(AGENTS) do lines[#lines + 1] = (i == sel and "▶  " or "     ") .. a.name end
  return table.concat(lines, "\n")
end

local function armSwitcherTimeout()
  if switcherTimer then switcherTimer:stop() end
  switcherTimer = hs.timer.doAfter(6, function() if au05.state == "switcher" then au05.closeSwitcher() end end)
end

function au05.openSwitcher()
  local front = hs.application.frontmostApplication()
  local fid = front and front:bundleID()
  sel = 1
  for i, a in ipairs(AGENTS) do if a.id == fid then sel = i % #AGENTS + 1 end end   -- 預選下一個
  au05.state = "switcher"
  show("🔀 切換 Agent　轉旋鈕選擇 · 按旋鈕或 ✓ 切換 · × 取消", switcherBody())
  au05Scroll:start()
  armSwitcherTimeout()
end

function au05.closeSwitcher()
  au05Scroll:stop()
  if switcherTimer then switcherTimer:stop(); switcherTimer = nil end
  au05.state = "idle"
  hide()
end

local function activateSelected()
  local a = AGENTS[sel]
  au05.closeSwitcher()
  hs.application.launchOrFocusByBundleID(a.id)
  log("切換到 " .. a.name)
end

local lastScroll = 0
au05Scroll = hs.eventtap.new({ types.scrollWheel }, function(e)
  if au05.state ~= "switcher" then return false end
  local dy = e:getProperty(props.scrollWheelEventDeltaAxis1)
  local now = hs.timer.secondsSinceEpoch()
  if dy ~= 0 and now - lastScroll > 0.12 then
    lastScroll = now
    sel = (sel - 1 + (dy > 0 and -1 or 1)) % #AGENTS + 1
    au05Box["body"].text = switcherBody()
    armSwitcherTimeout()
  end
  return true
end)

---------------------------------------------------------------- 按鍵行為
local ACTIONS = {
  idle = {
    mic = function() startRecording(); rec.startedByPress = true end,
    ok = function() hs.eventtap.keyStroke({}, "return") end,
    x = function() hs.eventtap.keyStroke({}, "escape") end,
  },
  recording = {
    mic = function() au05.stop("paste") end,
    ok = function() au05.stop("enter") end,
    x = function() au05.cancel() end,
    knob = function() au05.stop("hermes") end,
  },
  confirm = {
    mic = function() confirmPaste(false) end,
    ok = function() confirmPaste(true) end,
    x = function() endConfirm("已取消") end,
  },
  switcher = {
    ok = activateSelected,
    knob = activateSelected,
    x = function() au05.closeSwitcher() end,
  },
}

local function rotate(dir)                 -- dir: 1 往下（右轉）/ -1 往上（左轉）
  if au05.state == "switcher" then
    sel = (sel - 1 + dir) % #AGENTS + 1
    au05Box["body"].text = switcherBody()
    armSwitcherTimeout()
  else
    hs.eventtap.event.newScrollEvent({ 0, -dir * SCROLL_LINES }, {}, "line"):post()
  end
end

knobFromIdle = false
local function onPress(key)
  if key == "knob" then knobFromIdle = (au05.state == "idle") end
  local fn = (ACTIONS[au05.state] or {})[key]
  if fn then fn() end
end

local function onRelease(key, held)
  if key == "knob" and au05.state == "idle" and knobFromIdle then
    knobFromIdle = false
    if held >= LONG_PRESS then au05.openSwitcher() else hs.eventtap.keyStroke({}, "delete") end
    return
  end
  if key == "mic" and rec.startedByPress then
    rec.startedByPress = false
    if held >= LONG_PRESS and au05.state == "recording" then
      rec.translate = true
      au05Box["status"].text = recStatus()
      log("切換為中翻英")
    end
  end
end

---------------------------------------------------------------- 按鍵攔截
local held, pressAt, safety = {}, {}, {}

au05Tap = hs.eventtap.new({ types.keyDown, types.keyUp }, function(e)
  local code = e:getKeyCode()
  local f = e:getFlags()
  local down = e:getType() == types.keyDown
  local key = KEYS[code]

  if DEBUG_KEYS and (f.cmd and f.alt or f.ctrl and f.alt or key or code == km["m"]) then
    log(string.format("raw %s code=%d ctrl=%s alt=%s shift=%s cmd=%s kbtype=%d", down and "down" or "up", code,
      tostring(f.ctrl), tostring(f.alt), tostring(f.shift), tostring(f.cmd),
      e:getProperty(props.keyboardEventKeyboardType)))
  end

  -- 鍵盤上的 Esc：錄音中也能取消
  if code == ESC and down and au05.state == "recording" and not (f.cmd or f.alt or f.ctrl or f.shift) then
    au05.cancel()
    return true
  end

  if not key then return false end
  if key == "cw" or key == "ccw" then
    if down then rotate(key == "cw" and 1 or -1) end
    return true
  end
  local hyper = true    -- AU05 送 F13～F16，不需修飾鍵
  if down then
    if not hyper and not held[key] then return false end
    if held[key] then                                  -- 按住時的連發
      if safety[key] then safety[key]:stop() end
      safety[key] = hs.timer.doAfter(1.5, function() held[key] = false end)
      return true
    end
    held[key] = true
    pressAt[key] = hs.timer.secondsSinceEpoch()
    safety[key] = hs.timer.doAfter(1.5, function() held[key] = false end)
    onPress(key)
    return true
  end
  if held[key] then                                    -- 放開（修飾鍵可能已先鬆開）
    held[key] = false
    if safety[key] then safety[key]:stop(); safety[key] = nil end
    onRelease(key, hs.timer.secondsSinceEpoch() - (pressAt[key] or 0))
    return true
  end
  return hyper
end)
au05Tap:start()

au05Watchdog = hs.timer.doEvery(30, function()
  if not au05Tap:isEnabled() then au05Tap:start(); log("tap 重新啟用") end
  if au05.state == "idle" then ensureServer() end
end)

ensureServer()
log("啟動（AU05 新鍵位＋中翻英＋Hermes＋Agent 切換）；輔助使用權限=" .. tostring(hs.accessibilityState()))
