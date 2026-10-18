#!/usr/bin/env python3
"""AU05（Ulanzi Vibe Key）按鍵設定讀寫工具，不需要 Ulanzi Studio。
協定依據開源專案 arumwu/vibekey-lite docs/protocol.md（TEA 加密、report 0x55、指令 01 06 50）。

用法：
  au05_keymap.py get                       讀出 6 個位置的設定（並存備份）
  au05_keymap.py set <index> <usage> ...   寫入一個位置；usage 為 USB 鍵盤用法碼（十六進位），
                                           修飾鍵用 m:E0~E7，例：set 0 68（F13）
位置：0 上鍵(🎤) 1 中鍵(✓) 2 下鍵(×) 3 旋鈕按下 4 旋鈕右轉 5 旋鈕左轉
"""
import json
import os
import struct
import sys
import time

import hid

VID, PID, PAGE = 0xFFF1, 0x00DD, 0xFFFC
KEY = struct.unpack("<4I", bytes.fromhex("cabaa5ca6d8a2abcba9e5acaca8bb89b"))
DELTA, MASK = 0x9E3779B9, 0xFFFFFFFF
BACKUP = os.path.expanduser("~/Documents/Ulanzi備份/AU05-keymap-backup.json")


def tea_enc(block: bytes) -> bytes:
    v0, v1 = struct.unpack("<2I", block)
    s = 0
    k0, k1, k2, k3 = KEY
    for _ in range(32):
        s = (s + DELTA) & MASK
        v0 = (v0 + ((((v1 << 4) & MASK) + k0) ^ (v1 + s) ^ ((v1 >> 5) + k1))) & MASK
        v1 = (v1 + ((((v0 << 4) & MASK) + k2) ^ (v0 + s) ^ ((v0 >> 5) + k3))) & MASK
    return struct.pack("<2I", v0, v1)


def tea_dec(block: bytes) -> bytes:
    v0, v1 = struct.unpack("<2I", block)
    s = 0xC6EF3720
    k0, k1, k2, k3 = KEY
    for _ in range(32):
        v1 = (v1 - ((((v0 << 4) & MASK) + k2) ^ (v0 + s) ^ ((v0 >> 5) + k3))) & MASK
        v0 = (v0 - ((((v1 << 4) & MASK) + k0) ^ (v1 + s) ^ ((v1 >> 5) + k1))) & MASK
        s = (s - DELTA) & MASK
    return struct.pack("<2I", v0, v1)


def encrypt(plain: bytes) -> bytes:
    plain = plain.ljust(64, b"\0")[:64]
    return b"".join(tea_enc(plain[i:i + 8]) for i in range(0, 64, 8))


def decrypt(data: bytes) -> bytes:
    n = len(data) // 8 * 8
    return b"".join(tea_dec(data[i:i + 8]) for i in range(0, n, 8))


def open_dev() -> hid.device:
    for d in hid.enumerate(VID, PID):
        if d["usage_page"] == PAGE and d["usage"] == 1:
            dev = hid.device()
            dev.open_path(d["path"])
            dev.set_nonblocking(False)
            return dev
    sys.exit("找不到 AU05 的設定介面（請確認接收器已插上、AU05 已開機、Ulanzi Studio 已關閉）")


def send(dev, plain: bytes) -> None:
    dev.write(b"\x55" + encrypt(plain)[:63])


def read_reply(dev, want: bytes, timeout=1.5):
    end = time.time() + timeout
    while time.time() < end:
        data = dev.read(64, 200)
        if not data:
            continue
        data = bytes(data)
        if data[0] == 0x55 and len(data) == 64:
            data = data[1:]
        p = decrypt(data)
        if (p[0] & 0x1F) == (want[0] & 0x1F) and p[1:3] == want[1:3]:
            return p
    return None


def get(dev, index: int):
    req = bytes([0x01, 0x06, 0x50, 0x01, index])
    send(dev, req)
    return read_reply(dev, bytes([0x81, 0x06, 0x50]))


def set_(dev, index: int, entries):
    send(dev, bytes([0x01, 0x01, 0x10, 0x00, 0x00]))  # 先切離線模式，否則寫入不生效（實測）
    time.sleep(0.08)
    body = bytes([0x01, 0x06, 0x50, 0x04, index, 0x01, len(entries)])
    for page, usage in entries:
        body += bytes([page & 0x7F, usage])
    send(dev, body)
    time.sleep(0.08)
    return read_reply(dev, bytes([0x81, 0x06, 0x50]))


def parse_entries(args):
    """一般鍵：USB 鍵盤用法碼（hex），例 68=F13；修飾鍵：m:<位元遮罩>，01 Ctrl 02 Shift 04 Option 08 Cmd。"""
    out = []
    for a in args:
        if a.lower().startswith("m:"):
            out.append((0x03, int(a[2:], 16)))
        else:
            out.append((0x02, int(a, 16)))
    return out


def main():
    dev = open_dev()
    try:
        if sys.argv[1] == "get":
            res = {}
            for i in range(6):
                p = get(dev, i)
                res[i] = p.hex(" ") if p else None
                print(i, res[i])
            if not os.path.exists(BACKUP):
                os.makedirs(os.path.dirname(BACKUP), exist_ok=True)
                json.dump(res, open(BACKUP, "w"), indent=1)
                print("已備份到", BACKUP)
        elif sys.argv[1] == "set":
            index = int(sys.argv[2])
            p = set_(dev, index, parse_entries(sys.argv[3:]))
            print("SET 回覆:", p.hex(" ") if p else None)
            g = get(dev, index)
            print("讀回:", g.hex(" ") if g else None)
    finally:
        dev.close()


if __name__ == "__main__":
    main()
