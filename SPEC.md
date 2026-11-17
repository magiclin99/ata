# ATA 正式版規格（v2）

Android → Mac 的隔空傳檔。這份文件是 `mac-app/` 與 `android-app/` 的共同契約；測試向量在 `spec/vectors.json`。

## 1. 範圍

做：
- Mac 選單列 app（接收端）、Android app（傳送端，從系統分享選單進入）。
- 首次用 QR code 配對；之後所有訊號與檔案都經過驗證與加密。
- 連線順序：BLE 找到 Mac → 區網 TCP 直連 → 失敗則 WebRTC data channel（只用公開 STUN，永不使用 TURN 或任何中繼）→ 都失敗就明確告知「沒有直連路徑」；雙方都支援時，同時提議改用手機的臨時熱點（第 7c 節），由使用者按下才開始。
- 一次可傳多個檔案。

不做（v2 範圍外）：Mac → Android、續傳、多台 Mac 同時接收。

## 2. 身分與配對

- 每台裝置第一次啟動時產生 `deviceId`：16 個隨機 bytes，文字表示為 32 字元小寫 hex。
- 每一組（手機, Mac）共用一把 32 bytes 的配對金鑰 `K`。
- Mac 進入配對模式時產生新的隨機 `K`，顯示 QR code，內容是：

  `ata://pair?v=2&id=<macId hex>&name=<URL-encoded Mac 名稱>&k=<K 的 base64url，無 padding>`

- QR code 有效 5 分鐘，或被成功使用一次後失效。
- 手機掃描後立刻經 BLE 連線並完成第 4 節的握手（`pairing`:true）。握手成功後雙方才把 `K` 存起來：Mac 以 `phoneId` 為索引，手機以 `macId` 為索引。
- 金鑰儲存：Mac 存成檔案 `~/Library/Application Support/io.github.magiclin99.ata.mac/pairings.json`，只有目前的使用者帳號能讀寫（資料夾 0700、檔案 0600），資料夾排除在備份之外；不用 Keychain，因為沒有 Apple Team ID 的 app 每次更新都會要使用者重新輸入密碼。1.0 之前的版本存在 Keychain，第一次啟動時會在不跳出提示的情況下匯入一次，匯入後刪除 Keychain 項目。Android 用 Keystore 保護的儲存（例如 EncryptedSharedPreferences 或以 Keystore 金鑰包裝）。
- 任一方都可以在 UI 上移除配對；移除後對方握手會收到 `auth_fail`。

## 3. BLE 傳輸層

| 項目 | UUID | 屬性 |
|---|---|---|
| Service | `8E7F0101-3A5B-4C6D-9E1F-A7A0C0FFEE01` | Mac 廣播此 UUID |
| RX（手機 → Mac） | `8E7F0102-3A5B-4C6D-9E1F-A7A0C0FFEE01` | write（with response） |
| TX（Mac → 手機） | `8E7F0103-3A5B-4C6D-9E1F-A7A0C0FFEE01` | notify |

- UUID 與 v1 不同，兩個版本可以並存。
- Fragment 規則與 v1 相同：第 1 個 byte 是旗標（`0x00` 還有、`0x01` 最後一片），總長度不超過 `min(ATT MTU - 3, 512)`，同一方向一次一則訊息。
- 一則訊息的內容（重組後的 bytes）在握手完成前是 UTF-8 JSON 明文，握手完成後是第 5 節的密文。
- Mac 同時只服務一支手機；已有 session 時，新的連線握手回 `auth_fail`（`reason`:"busy"）。「session」從 `auth` 驗證成功才算開始：只連線、讀了 `hello` 就斷開的 central 不占用 session，也不得擋住別人。
- Mac 廣播的 local name 是 `ATA-` 加上 macId hex 的前 8 個字元（例如 `ATA-a0a1a2a3`），讓手機不必連線就能判斷附近是哪一台已配對的 Mac。這只是提示：廣播裡拿不到名稱時，手機改用連線後 `hello.id` 判斷，判斷完若使用者還沒選擇就先斷開。

### 3a. 手機端的裝置選擇（主要使用流程）

最常用的流程是：使用者在別的 app 按分享 → 在系統分享選單選 ATA → ATA 開啟後顯示「傳送到哪台裝置」的清單。

- 清單列出所有已配對的 Mac，並標示目前是否在附近（BLE 掃描到）；掃描持續進行，狀態即時更新。
- 使用者點選一台「在附近」的 Mac 才開始傳送。即使只配對了一台，也要顯示清單讓使用者點選，不自動開始。
- 沒有任何已配對的 Mac 時，這個畫面直接引導去配對，配對完成後回到清單並保留原本要分享的檔案。
- Debug 掛鉤（第 9 節的 `debugSendMiB`）不經過這個畫面，直接傳給唯一已配對的 Mac。

## 4. 握手（明文 JSON）

`b64` 一律指標準 base64（有 padding）。`nonce` 是 16 個隨機 bytes。

1. 手機訂閱 TX 後，Mac 送：`{"t":"hello","v":2,"id":"<macId hex>","n":"<nonceM b64>"}`
2. 手機送：`{"t":"auth","id":"<phoneId hex>","name":"<手機名稱>","n":"<nonceP b64>","pairing":<bool>,"mac":"<b64>"}`
   - `mac` = HMAC-SHA256(K, `"ata2-auth-phone"` ‖ macId ‖ phoneId ‖ nonceM ‖ nonceP)
3. Mac 找 `K`：`pairing` 為 true 用目前 QR code 的 `K`（必須仍有效）；否則用 `phoneId` 查已存的 `K`。驗證 `mac`（常數時間比較）。
   - 成功送：`{"t":"auth_ok","name":"<Mac 名稱>","mac":"<b64>"}`，`mac` = HMAC-SHA256(K, `"ata2-auth-mac"` ‖ macId ‖ phoneId ‖ nonceM ‖ nonceP)
   - 失敗送：`{"t":"auth_fail","reason":"unknown_device"|"bad_mac"|"pairing_expired"|"busy"|"bad_version"}`，然後中斷連線。
4. 手機驗證 Mac 的 `mac`，不符就中斷並顯示錯誤。

HMAC 輸入的串接：標籤是 ASCII bytes（不含結尾 0），macId / phoneId 是原始 16 bytes，nonce 是原始 16 bytes，中間沒有分隔符號。

## 5. Session 金鑰與 BLE 訊息加密

握手成功後雙方導出三把 32 bytes 金鑰，全部用 HKDF-SHA256，`ikm` = K，`salt` = nonceM ‖ nonceP（32 bytes），`info` 是下列 ASCII 字串：

| 金鑰 | info |
|---|---|
| `kP2M`（手機 → Mac 的 BLE 訊息） | `ata2 ble p2m` |
| `kM2P`（Mac → 手機的 BLE 訊息） | `ata2 ble m2p` |
| `kFile`（區網 TCP 檔案傳輸） | `ata2 file` |

另外導出 `sid`：同樣的 HKDF，`info` = `ata2 sid`，長度 16 bytes。

`auth_ok` 之後的每一則 BLE 訊息：
- 明文是 UTF-8 JSON。
- 用 AES-256-GCM 加密，金鑰依方向選 `kP2M` 或 `kM2P`，沒有 AAD。
- Nonce 12 bytes = 4 個 `0x00` ‖ 8 bytes big-endian 計數器；每個方向各自從 0 開始，每則訊息加 1。計數器不上線傳輸（通道本身有序可靠）。
- 上線的內容 = 密文 ‖ 16 bytes tag，再照第 3 節切 fragment。
- 解密失敗就中斷連線。

## 6. 加密後的 BLE 訊息

| `t` | 方向 | 欄位 | 說明 |
|---|---|---|---|
| `send` | 手機 → Mac | `files`:[{`name`,`size`}], `total`:總 bytes, `caps`:[字串]（可省略） | 要傳的檔案清單；`caps` 含 `"hotspot"` 表示手機能開臨時熱點 |
| `accept` | Mac → 手機 | `tcpPort`, `lan`:[IPv4 字串], `hotspot`:bool（可省略） | Mac 已開始監聽 TCP；`hotspot`:true 只在 `send.caps` 含 `"hotspot"` 且 Mac 有 Wi-Fi 介面時出現 |
| `reject` | Mac → 手機 | `reason` | 例如磁碟空間不足 |
| `rtc_offer` | 手機 → Mac | `sdp` | 區網 TCP 連不上時才送；完整 SDP，不做 trickle |
| `rtc_answer` | Mac → 手機 | `sdp` | |
| `rtc_error` | Mac → 手機 | `error` | |
| `hotspot` | 手機 → Mac | `ssid`, `psk` | 第 7c 節；只在 `accept.hotspot` 為 true 時、尚未送 `rtc_offer` 前送 |
| `hotspot_ready` | Mac → 手機 | `lan`:[IPv4 字串], `tcpPort` | Mac 已加入熱點並取得位址；`tcpPort` 與 `accept` 相同 |
| `hotspot_error` | Mac → 手機 | `error` | `bad_request`、`unsupported`、`not_found`、`join_failed`、`no_address`、`busy` |
| `bye` | 手機 → Mac | `ok`:bool, `via`:"lan"\|"rtc"\|"hotspot"\|null, `error`:字串或 null | 傳輸結束，雙方清理 session |

未知欄位一律忽略，未知 `t` 記 log 後忽略；所以舊版 Mac 看不到 `caps`、不回 `accept.hotspot`，新版手機就照舊只走區網與 WebRTC。

已配對的手機送來的 `send` 預設自動接受（Mac 端設定可改成每次詢問，v2 可先不做詢問 UI）。

## 7. 檔案紀錄格式（兩種通道共用）

一筆「紀錄」= 1 byte 型別 ‖ 內容。

| 型別 | 方向 | 內容 |
|---|---|---|
| `0x01` 檔案開始 | 手機 → Mac | JSON `{"name":"a.jpg","size":12345}` |
| `0x02` 資料 | 手機 → Mac | 原始 bytes |
| `0x03` 檔案結束 | 手機 → Mac | JSON `{"sha256":"<小寫 hex>"}`（邊傳邊算，不需要先讀一遍） |
| `0x04` 檔案結果 | Mac → 手機 | JSON `{"ok":true}` 或 `{"ok":false,"error":"..."}` |
| `0x05` 全部結束 | 手機 → Mac | 空 |

- 多個檔案依序傳：`01 02… 03`，等到 `04` 再傳下一個；最後送 `05`。
- Mac 存到設定的資料夾（預設 `~/Downloads`），檔名只取最後一段路徑、重複時加序號；先寫到暫存檔，sha256 相符才改成正式檔名，不符或中斷就刪除。

### 7a. 區網 TCP

- 手機連上 `accept.lan` 的任一 IP（每個逾時 1.5 秒；socket 必須綁在與該 IP 同網段的 Wi-Fi 網路上）。
- 連上後手機先送 16 bytes 明文 `sid`。Mac 比對不符就關閉連線。
- 之後每筆紀錄包成：4 bytes big-endian 長度 N ‖ N bytes（AES-256-GCM 密文 ‖ tag）。金鑰 `kFile`，沒有 AAD。
- Nonce 12 bytes = 4 bytes 方向 ‖ 8 bytes big-endian 計數器。方向：手機 → Mac 是 `0x00000001`，Mac → 手機是 `0x00000002`；各自從 0 開始。
- `0x02` 資料紀錄的明文內容最多 64 KiB。N 超過 1 MiB 視為錯誤。

### 7b. WebRTC data channel

- ICE 只設 `stun:stun.l.google.com:19302` 與 `stun:stun.cloudflare.com:3478`，關閉 ICE-TCP，不做 trickle（gathering 最多等 5 秒）。Data channel 由手機建立：label `ata-file`、ordered、reliable。20 秒內沒開啟算失敗。
- 每筆紀錄是一則 binary 訊息，不再額外加密（DTLS 已加密，且 SDP 的指紋是經過加密的 BLE 通道交換的）。
- `0x02` 資料紀錄內容最多 16 KiB；傳送端依 `bufferedAmount` 做背壓（高水位 1 MiB）。

### 7c. 臨時熱點（手機與 Mac 的網路互相連不到時）

情境：手機和 Mac 各自在不同的網路（例如訪客 Wi-Fi 與公司 Wi-Fi），區網 TCP 跳過、WebRTC 的 ICE 失敗（實測：兩邊在同一個 NAT 後面、NAT 不做 hairpin）。

觸發與同意：
- 一般傳送照舊（區網 → WebRTC）。結果是「沒有直連路徑」、且這次的 `accept.hotspot` 為 true、手機也支援時，手機的失敗畫面多一個選項，說明 Mac 會暫時離開目前的 Wi-Fi、傳完自動連回，由使用者按下才開始。不自動切換 Mac 的網路。
- 按下後手機先要權限（Android 12/12L：位置；Android 13 以上：附近裝置），再重新開始一次傳送（重新 BLE 握手），這次在 `accept` 之後直接走熱點，不試區網與 WebRTC。

流程（同一個 session）：
1. 手機 `send`（`caps`:["hotspot"]）→ Mac `accept`（`hotspot`:true，照常開 TCP 監聽，`0.0.0.0`）。
2. 手機用 `WifiManager.startLocalOnlyHotspot` 開熱點（名稱與密碼由系統決定；最多等 15 秒），把名稱與密碼用 `hotspot` 送出。這則訊息只走加密後的 BLE；密碼不得寫進任何 log。
3. Mac 記下目前 Wi-Fi 狀態（是否開啟、是否連著網路），並把這份狀態寫到 `~/Library/Application Support/io.github.magiclin99.ata.mac/wifi-restore.json`，然後用 `/usr/sbin/networksetup -setairportnetwork <介面> <名稱> -` 依名稱加入（Wi-Fi 關著就先打開；密碼從 stdin 給，不出現在行程的參數列，也不寫 log）。不用 CoreWLAN 自己加入：沒有定位權限的 app 拿到的掃描結果沒有網路名稱，而沒有名稱的結果 airportd 加入不了（錯誤 -3900）。第一次加入前先等 2 秒（手機剛開的熱點要一下子才開始廣播）；找不到或失敗就隔 4 秒再試（networksetup 每次自己掃描約 6 秒，macOS 每個行程每 10 秒只做一次真正的掃描），總共最多 30 秒。已知限制：依賴系統工具的行為；Mac 若設定「更改網路需要管理者」就會失敗（之後照常恢復）。加入後等 Wi-Fi 介面拿到 IPv4 位址，最多 15 秒。成功送 `hotspot_ready`，失敗送 `hotspot_error`（之後照常等手機的 `bye`）。加入期間不計 session 的閒置逾時。
4. 手機收 `hotspot_ready`（最多等 60 秒），對 `lan` 的位址連 TCP（socket 不綁網路，走熱點介面；每次 3 秒，最多 15 秒），之後完全照第 7a 節（`sid`、`kFile` 加密的紀錄）。
5. 傳完照常 `0x05` → `bye`（`via`:"hotspot"）。手機送出 `bye` 後才關熱點。

Mac 一定要回到原本的網路（session 用任何方式結束都一樣：完成、失敗、手機取消、BLE 斷線、逾時、Mac app 結束）：
- 斷開熱點；原本 Wi-Fi 是關的就關掉；原本連著網路就等 macOS 自動連回已知網路（最多 10 秒），沒連回就把 Wi-Fi 關掉再打開（之後最多等 20 秒）；原本開著但沒連網路就只斷開。
- 恢復之後試著把手機的熱點從 Mac 的「已儲存網路」移除（`networksetup -removepreferredwirelessnetwork`）；macOS 要求管理者權限時就留著，結果寫 log。
- 判斷「連著網路」只看 Wi-Fi 介面有沒有 IPv4 位址，不讀網路名稱（macOS 讀網路名稱需要定位權限）。
- 結果寫 log；沒能確認連回時，Mac 畫面告訴使用者從選單列的 Wi-Fi 圖示選回自己的網路。
- App 結束時（含 SIGTERM）先做完這一步再結束，最多等 20 秒。App 當掉時，下次啟動看到 `wifi-restore.json` 就檢查：Wi-Fi 介面的位址還在熱點的網段就照上面的步驟恢復，然後刪檔。

版本相容：舊版手機不送 `caps`，Mac 不提熱點；舊版 Mac 不回 `accept.hotspot`，手機不顯示這個選項，失敗訊息與現在相同（請讓手機和 Mac 連上同一個 Wi-Fi）。`hello.v` 維持 2。

## 8. 測試向量

`spec/vectors.json` 有一組固定輸入與預期輸出（握手 HMAC、四個 HKDF 輸出、一則 BLE 訊息密文、一筆 TCP 紀錄）。兩邊都必須有單元測試證明自己的實作與向量一致。

## 9. 自動化測試掛鉤（只在 debug 版）

實機整合測試由 adb 與指令列驅動，不能依賴人手掃 QR code：

- Mac app：啟動參數 `--pairing-uri-file <path>` 會直接進入配對模式並把 `ata://pair?...` 寫到該檔；`--log-file <path>` 把 log 同步寫到檔案；`--save-dir <path>` 覆寫存檔資料夾。
- Android app（applicationId `io.github.magiclin99.ata`，僅 debug build）：
  - `adb shell am start -n io.github.magiclin99.ata/.MainActivity --es debugPairUri "<uri>"`：等同掃到這個 QR code。
  - `adb shell am start -n io.github.magiclin99.ata/.MainActivity --ei debugSendMiB <N> [--ei debugCount <M>] [--ez debugForceRtc true]`：產生 M 個各 N MiB 的隨機檔並傳給唯一已配對的 Mac；`debugForceRtc` 跳過區網 TCP 直接走 WebRTC。
  - 所有協定事件用 `Log.i("ATA", …)` 記錄，傳輸結束時記一行 `RESULT ok=<bool> via=<lan|rtc|none> files=<n> bytes=<n> ms=<n>`。
