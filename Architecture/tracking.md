# ESPHome v3.0 Architecture Implementation Tracking

> এই ডকুমেন্টটি v3.0 "Connection-First, Security-First" আর্কিটেকচারের progress track করে।
> পূর্ববর্তী v2.1 tracking: `.archive/tracking_v2.1.md`

---

## Changelog Rules

> [!IMPORTANT]
> যেকোনো পরিবর্তন করলে নিচের format এ এই ফাইলের শেষে log করতে হবে:
>
> ```
> * **[Action] (YYYY-MM-DD):** [কী পরিবর্তন হয়েছে] — [কোন ফাইল]
> ```
>
> Actions: `Added` | `Modified` | `Removed` | `Archived` | `Verified`

---

## Overall Progress Summary

| Phase | বিবরণ | অবস্থা | Target | সম্পন্ন তারিখ |
|:---|:---|:---|:---|:---|
| **Phase 0** | Foundation Reset & Live Crypto Handshake | *Pending* | Week 1 | - |
| **Phase 1** | Firmware Core Integration Layer | *Pending* | Week 2 | - |
| **Phase 2** | App Real Data Binding | *Pending* | Week 2–3 | - |
| **Phase 3** | MQTT + Sensors (BME280, MQ2) + Rules | *Pending* | Week 3–4 | - |
| **Phase 4** | Glassmorphic UI Polish + OTA | *Pending* | Week 4 | - |
| **Phase 5** | Hardening, Testing & Deploy | *Pending* | Week 5 | - |

---

## Detailed Phase Progress

---

### Phase 0: Foundation Reset & Live Crypto Handshake
**Branch:** `feature/v3-connection-first`
**Status:** Pending

#### Sub-phase 0.1: Firmware Minimal Boot Skeleton
- [ ] **0.1.1** `ESPHome.ino` minimal cleanup — RuleEngine, SensorTask, MqttManager disabled
- [ ] **0.1.2** `AppNetworkManager.cpp` — `WIFI:SET_API_KEY:<key>` serial command handler যোগ
- [ ] **0.1.3** `StorageManager.h/.cpp` — `setApiKey(String)` method যোগ
- [ ] **0.1.4** Boot serial output verify: IP, MAC, heap, NTP sync

#### Sub-phase 0.2: App Minimal Connection Skeleton
- [ ] **0.2.1** `debug_connection_screen.dart` (নতুন) — scan + connect + status debug UI
- [ ] **0.2.2** `UdpDiscoveryService` verify — beacon decrypt, IP/MAC extract
- [ ] **0.2.3** `ConnectionManager` verify — `connect(ip)` → WS session establish

#### Sub-phase 0.3: ⭐ Crypto Handshake + EtM Verification (Critical Gate)
- [ ] **0.3.0** `CryptoHelper.h/.cpp` — `deriveKeys()`, `encryptAndMac()`, `verifyAndDecrypt()` method যোগ (Firmware)
- [ ] **0.3.1** `node_security_service.dart` — `deriveKeys()`, `encryptAndMac()`, `verifyAndDecrypt()`, `_constantTimeEqual()` যোগ (App)
- [ ] **0.3.1b** `connection_manager.dart` — `_onMessage()` এ `verifyAndDecrypt()` + null check ব্যবহার
- [ ] **0.3.2** Firmware EtM self-test (Serial: timestamp + EtM packet + self-verify PASS)
- [ ] **0.3.3** App decrypt test in debug screen (paste firmware EtM packet, verify plaintext, red on MAC mismatch)
- [ ] **0.3.4** Live EtM round-trip test: App `encryptAndMac(PING)` → Firmware `verifyAndDecrypt()` → `encryptAndMac(PONG)` → App verify (< 50ms)
- [ ] **0.3.5** MAC Tamper Test A — bit-flip ciphertext → `verifyAndDecrypt()` returns null/false
- [ ] **0.3.5b** MAC Tamper Test B — MAC strip (remove last 16 bytes) → reject
- [ ] **0.3.5c** MAC Tamper Test C — replay 31s old packet → 401 Unauthorized
- [ ] **0.3.6** Timestamp window test: 31s old timestamp → 401 reject verify
- [ ] **0.3.6b** mac4 mismatch test (after MAC verified) → 409 Conflict verify

#### Sub-phase 0.4: UDP Discovery End-to-End
- [ ] **0.4.1** Firmware UDP beacon format verify (encrypted, port 4210)
- [ ] **0.4.2** App auto-connect from beacon
- [ ] **0.4.3** Interval verify: 15s (no clients) / 60s (clients connected)

**Phase 0 Exit Criteria:** Real hardware তে encrypted WS message round-trip verified ✓

---

### Phase 1: Firmware Core Integration Layer
**Status:** Pending (Phase 0 exit required first)

#### Sub-phase 1.1: EventBus → Coordinator Live Wiring
- [ ] **1.1.1** WS frame → EventBus → Coordinator chain verify
- [ ] **1.1.2** HTTP POST `/api/set-state` → EventBus → Coordinator chain verify
- [ ] **1.1.3** Event pool stress test (30 rapid events, drop policy verify)
- [ ] **1.1.4** Core 0 → Core 1 latency measurement (target < 5ms)

#### Sub-phase 1.2: HardwareManager + GPIO Live Test
- [ ] **1.2.1** Load config load from `/loads.json` on boot verify
- [ ] **1.2.2** App `TURN_ON`/`TURN_OFF` → GPIO toggle via Coordinator
- [ ] **1.2.3** State persistence: 3s coalesced write + power cycle restore
- [ ] **1.2.4** Delete safety: `canDeleteLoad()` blocks ON loads

#### Sub-phase 1.3: SwitchHandler ISR → App Real-Time Sync
- [ ] **1.3.1** Physical switch → ISR → Coordinator → GPIO chain verify
- [ ] **1.3.2** Physical switch event → encrypted WS push → App UI update
- [ ] **1.3.3** Debounce test: 10ms rapid toggle → single event
- [ ] **1.3.4** ISR reserved slot — high-frequency events no drop

#### Sub-phase 1.4: StorageManager Live R/W
- [ ] **1.4.1** `ADD_LOAD` command → `/loads.json` persist → reboot restore
- [ ] **1.4.2** Coalesced write: 3 changes → 1 write verify
- [ ] **1.4.3** LittleFS corruption recovery test
- [ ] **1.4.4** `crash_logs.json` drop count logging verify

#### Sub-phase 1.5: Memory Stability Baseline
- [ ] **1.5.1** TWDT in Coordinator + SensorTask
- [ ] **1.5.2** Heap monitor baseline: 10s interval log
- [ ] **1.5.3** 25KB heap guard latch verify
- [ ] **1.5.4** 1-hour continuous operation: heap flat confirm

---

### Phase 2: App Real Data Binding
**Status:** Pending

#### Sub-phase 2.1: NodesProvider Dummy Data Removal
- [ ] **2.1.1** Hardcoded mock node list সরানো
- [ ] **2.1.2** Simulated temperature timer (Timer.periodic) সরানো
- [ ] **2.1.3** Real WS message → `NodesProvider.updateFromFirmware()` pipe
- [ ] **2.1.4** Load toggle → real command → ack → UI confirm

#### Sub-phase 2.2: LocalCacheService Real Data
- [ ] **2.2.1** Real node data Hive তে store
- [ ] **2.2.2** App restart → Hive load → UI render (no re-fetch)
- [ ] **2.2.3** Offline queue: command buffer → reconnect → replay

#### Sub-phase 2.3: UDP Discovery → Auto Pairing
- [ ] **2.3.1** `PairingDialog` (GlassDialog) — api_key input + pair
- [ ] **2.3.2** IP change auto-reconnect via UDP beacon
- [ ] **2.3.3** Multi-node (2+ nodes) simultaneous test

#### Sub-phase 2.4: Firebase Auth Integration
- [ ] **2.4.1** Real Firebase UID login + `approved_nodes` check
- [ ] **2.4.2** Admin approval flow end-to-end
- [ ] **2.4.3** Multi-user role test (Admin + User)

#### Sub-phase 2.5: Connection Fallback Real Test
- [ ] **2.5.1** WS kill → HTTP auto-fallback verify
- [ ] **2.5.2** HTTP fail → Offline Queue buffer
- [ ] **2.5.3** WiFi restore → offline queue auto-drain

---

### Phase 3: MQTT + Sensors + Rules
**Status:** Pending

#### Sub-phase 3.1: HiveMQ Firmware
- [ ] **3.1.1** `MqttManager` re-enable in `ESPHome.ino`
- [ ] **3.1.2** MQTT credentials from `/system.json` + serial command set
- [ ] **3.1.3** Retained message publish verify (MQTT Explorer)
- [ ] **3.1.4** Command subscribe → execute verify

#### Sub-phase 3.2: App HiveMQ Integration
- [ ] **3.2.1** `mqtt_client` package add to `pubspec.yaml`
- [ ] **3.2.2** `MqttConnectionService` (নতুন ফাইল) — TLS connect, subscribe, publish
- [ ] **3.2.3** Retained message sync: cold open → dashboard populated

#### Sub-phase 3.3: Full Fallback Pipeline
- [ ] **3.3.1** WS → HTTP → MQTT → Queue cascade test
- [ ] **3.3.2** Mobile data test (MQTT cloud path)
- [ ] **3.3.3** MQTT reconnect backoff verify

#### Sub-phase 3.4: BME280 + MQ2 Sensor Integration
- [ ] **3.4.1** `SensorTask` re-enable in `ESPHome.ino`
- [ ] **3.4.2** BME280 I2C driver — 10s read, publish temperature/humidity/pressure
- [ ] **3.4.3** MQ2 analog driver — 30s warm-up, 10s read, publish gas_level
- [ ] **3.4.4** Debug mock flag remove (`SENSOR_DEBUG_MOCK` disable)
- [ ] **3.4.5** App sensor chart — real BME280 data + MQ2 gas widget

#### Sub-phase 3.5: RuleEngine Live
- [ ] **3.5.1** `RuleEngine` re-enable in `ESPHome.ino`
- [ ] **3.5.2** BME280 temperature rule test (fan on > 30°C)
- [ ] **3.5.3** MQ2 gas rule test (alarm on > 500 ppm)
- [ ] **3.5.4** App rule builder → `/rules.json` update → live rule active

---

### Phase 4: UI Polish
**Status:** Pending

#### Sub-phase 4.1: Dashboard Real Cards
- [ ] **4.1.1** Real firmware data in node cards (IP, MAC, uptime, heap)
- [ ] **4.1.2** Connection path badge (WS/HTTP/MQTT)
- [ ] **4.1.3** Multi-node grid (2+ nodes)

#### Sub-phase 4.2: Node Control Screen
- [ ] **4.2.1** Real GPIO toggle with ack animation
- [ ] **4.2.2** Real BME280 temperature history chart
- [ ] **4.2.3** MQ2 gas level widget
- [ ] **4.2.4** BME280 pressure widget

#### Sub-phase 4.3: Settings Screen
- [ ] **4.3.1** API key masking + SecureStorage bind
- [ ] **4.3.2** Time format 12h/24h toggle
- [ ] **4.3.3** MQTT status indicator

#### Sub-phase 4.4: Glassmorphic Full Polish
- [ ] **4.4.1** All cards — blur sigma ≥ 16, translucent border, glow shadow
- [ ] **4.4.2** `GlassDialog` wrapper class (নতুন: `core/widgets/glass_dialog.dart`)
- [ ] **4.4.3** Glassmorphic navigation bar
- [ ] **4.4.4** Offline/reconnecting banner

#### Sub-phase 4.5: OTA Update
- [ ] **4.5.1** Local OTA: file picker → HTTP upload → reboot
- [ ] **4.5.2** Version mismatch banner
- [ ] **4.5.3** OTA progress indicator

---

### Phase 5: Hardening & Deploy
**Status:** Pending

#### Sub-phase 5.1: Crypto Unit Tests (EtM Included)
- [ ] **5.1.1** Cross-platform key derivation parity: same api_key+timestamp → identical k_enc AND k_mac on both sides
- [ ] **5.1.2** EtM round-trip test: payload sizes 10, 100, 500, 1000 bytes → encrypt+MAC → verify+decrypt → identical
- [ ] **5.1.3** MAC tamper: ciphertext bit-flip → verifyAndDecrypt() null/false
- [ ] **5.1.4** MAC strip attack: remove last 16 bytes → packet too short → reject
- [ ] **5.1.5** IV tamper: first 16 bytes change → MAC mismatch → reject
- [ ] **5.1.6** Constant-time compare verify (`_constantTimeEqual` timing-safe)
- [ ] **5.1.7** Replay window: 31s → 401, fresh → 200
- [ ] **5.1.8** mac4 mismatch (after MAC passes) → 409 Conflict

#### Sub-phase 5.2: Memory Tests
- [ ] **5.2.1** 50-event pool exhaustion test
- [ ] **5.2.2** 1000 rapid ISR toggles — no crash
- [ ] **5.2.3** 24-hour soak — heap flat
- [ ] **5.2.4** Power cycle × 10 — state restore correct

#### Sub-phase 5.3: Network Resilience
- [ ] **5.3.1** WiFi dropout — Core 1 uninterrupted
- [ ] **5.3.2** Full cascade test (WS→HTTP→MQTT→Queue)
- [ ] **5.3.3** MQTT reconnect backoff

#### Sub-phase 5.4: App Tests & Build
- [ ] **5.4.1** `flutter test` + `flutter analyze`
- [ ] **5.4.2** Obfuscated release build verify
- [ ] **5.4.3** ProGuard crypto class preservation

#### Sub-phase 5.5: CI/CD
- [ ] **5.5.1** GitHub Actions PR workflow
- [ ] **5.5.2** Fastlane Android → Google Play Internal
- [ ] **5.5.3** Fastlane iOS → TestFlight

---

* **Archived (2026-07-23):** `Architecture 2.1.md` → `.archive/Architecture_2.1.md`
* **Archived (2026-07-23):** `tracking.md` (v2.1) → `.archive/tracking_v2.1.md`
* **Archived (2026-07-23):** `app_tracker.md` (v2.1) → `.archive/app_tracker_v2.1.md`
* **Added (2026-07-23):** `Architecture_3.0.md` — v3.0 Connection-First architecture specification
* **Added (2026-07-23):** `tracking.md` (v3.0) — নতুন v3.0 progress tracker (এই ফাইল)
* **Modified (2026-07-23):** `.agents/AGENTS.md` — v3.0 rules যোগ: Phase Gate Enforcement, Connection-First Mandate, Crypto Parity, No Dummy Data, Salvageable Modules, Tracking Rule
* **Modified (2026-07-23):** `Architecture_3.0.md` — Encrypt-then-MAC (EtM) security layer যোগ: Section ২, Sub-phase 0.3, Sub-phase 5.1, Key Design Decisions table — CBC bit-flipping attack mitigation
* **Modified (2026-07-23):** `tracking.md` — Sub-phase 0.3 ও 5.1 এ EtM implementation + tamper test tasks যোগ
* **Modified (2026-07-23):** `Architecture_3.0.md` — Section ৩ Memory Management & Safety Standards যোগ: String ban, F() macro mandate, fixed ring buffers (Log 512B, Sensor 144B, WS 512B, Crypto 560B), HeapMonitor task, heap thresholds (WARN/LATCH/CRITICAL) — Sections ৩→৯ renumbered
* **Modified (2026-07-23):** `.agents/AGENTS.md` — Firmware Memory & Safety Mandates যোগ: String ban, F() macro, static buffers, buffer overflow containment, HeapMonitor, heap_caps_malloc, IRAM_ATTR rules
* **Archived (2026-07-23):** Obsolete files moved to `.archive/` (`attachment.md`, `implementation_plan_app`, `implementation_plan_phase_4`, `client_build_deploy_report.md`, `release_note.md`, `utils/cripto/cripto.ino`). Redundant root architecture copies (`Architecture 2.1.md`, `app_tracker.md`) removed.
* **Added (2026-07-23):** `Architecture_3.0.md` — Section ১০ Critical Credentials & System Configuration Registry (HiveMQ MQTT, Firebase DB/Auth, API Keys, Port Registry)

