# ESPHome v2.1 Architecture Implementation Tracking

This document tracks the progress of the ESPHome v2.1 firmware migration. It lists the implementation status of all phases and sub-phases, along with a detailed log of additions and removals.

---

## Overall Progress Summary

| Phase | Description | Status | Target Timeline | Completed Date |
| :--- | :--- | :--- | :--- | :--- |
| **Phase 1** | Foundation & Memory Architecture | **Completed** | Week 1 | 2026-07-14 |
| **Phase 2** | Hardware Interfacing & ISR | **Completed** | Week 2 | 2026-07-14 |
| **Phase 3** | Networking & Cryptographic Security | **Completed** | Week 3 | 2026-07-14 |
| **Phase 4** | HiveMQ Integration & Rule Engine | **Completed** | Week 4 | 2026-07-14 |
| **Phase 5** | Stability & Testing | *Pending* | Week 5 | - |

---

## Detailed Phase Progress & Changelog

### Phase 1: Foundation & Memory Architecture (Core 1 Focus)
**Status:** Completed

- **[Completed] Sub-phase 1.1: Setup Architecture Tracking**
  - Setup of project tracking files.
- **[Completed] Sub-phase 1.2: Implement StorageManager (LittleFS)**
  - Initialize LittleFS.
  - Setup fallback formatting.
  - Initialize `/loads.json`, `/system.json`, and `/states.json` with secure configurations.
- **[Completed] Sub-phase 1.3: Implement Thread-Safe Utilities**
  - Implement recursive mutex wrapper `SystemMutex` with RAII `LockGuard`.
- **[Completed] Sub-phase 1.4: Implement Pre-allocated Event Bus**
  - Implement static pool `AppEvent` of size 16.
  - Set up `freeSlotQueue` and `eventQueue` pointer management to avoid heap fragmentation and dangling pointers.
- **[Completed] Sub-phase 1.5: FreeRTOS Tasks Core Allocation**
  - Set up dual-core task skeleton. Pinned task loops (`TaskCore0` and `TaskCore1`).
  - Integrate all modules in `ESPHome.ino`.

#### Phase 1 Changelog:
* **Added (2026-07-14):** Created tracking structure `Architecture/tracking.md`.
* **Added (2026-07-14):** Created `StorageManager` in `src/Storage/StorageManager.h` and `src/Storage/StorageManager.cpp`.
* **Added (2026-07-14):** Created `SystemMutex` and RAII `LockGuard` in `src/Core/SystemMutex.h`.
* **Added (2026-07-14):** Created `EventBus` static memory pool with FreeRTOS queues in `src/Core/EventBus.h` and `src/Core/EventBus.cpp`.
* **Added (2026-07-14):** Created `TaskManager` with dual-core task mappings in `src/Core/TaskManager.h` and `src/Core/TaskManager.cpp`.
* **Added (2026-07-14):** Bootstrapped `ESPHome.ino` to coordinate and initialize all subsystems.

---

### Phase 2: Hardware Interfacing & ISR
**Status:** Completed

- **[Completed] Sub-phase 2.1**: Runtime Pin and ID Conflict Validation.
  - Created `HardwareManager` to prevent overlapping assignments and validate GPIO ranges.
  - Implemented load deletion safety checks via `canDeleteLoad()`.
- **[Completed] Sub-phase 2.2**: IRAM-pinned Physical Switch ISR with `xQueueSendFromISR()`.
  - Created `SwitchHandler` using C++ ISR wrappers via `attachInterruptArg()`.
  - Implemented 50ms software debouncing inside Switch ISR using `esp_timer_get_time()`.
  - Supported toggle switch vs momentary push-button modes.
  - Implemented boot-time physical state scanning and initial event queueing.
- **[Completed] Sub-phase 2.3**: Coalesced 3-second Delayed Flash Writes.
  - Implemented zero-heap static file writing in `StorageManager` to avoid fragmentation.
  - Added coalescing scheduler that waits for 3 seconds of inactivity before flushing writes.
- **[Completed] Sub-phase 2.4**: Stress Test Implementation & Verification.
  - Added `runEventBusStressTest()` in `ESPHome.ino` firing 30 rapid events.
  - Verified heap remains completely constant before/after queue overflow stress, proving zero OOM crash vulnerability.

#### Phase 2 Changelog:
* **Added (2026-07-14):** Created `HardwareManager` in `src/Core/HardwareManager.h` and `src/Core/HardwareManager.cpp`.
* **Added (2026-07-14):** Created `SwitchHandler` in `src/Core/SwitchHandler.h` and `src/Core/SwitchHandler.cpp`.
* **Modified (2026-07-14):** Added zero-heap static writing and 3-second delayed coalesced saves in `StorageManager`.
* **Modified (2026-07-14):** Updated `ESPHome.ino` with conflict checks, critical load delete validators, and boot-time overflow stress tests.

---

### Phase 3: Networking & Cryptographic Security
**Status:** Completed

- **[Completed] Sub-phase 3.1**: WiFi Manager & Prefix Command Routing.
  - Integrated `ESPWiFiManager` inside `AppNetworkManager` running on Core 0.
  - Added serial commands routing using prefixes `WIFI:` (for credentials config) and `SYS:` (for system utilities).
- **[Completed] Sub-phase 3.2**: AsyncWebServer & WebSocket Server.
  - Setup AsyncWebServer on port 80 and AsyncWebSocket on `/ws` pinned to Core 0.
  - Formatted WebSocket text commands as `[Timestamp]:[Base64]`.
  - Bypassed decryption on Core 0; text frames are packetized and queued directly to the Coordinator task via `EventBus` to keep Core 0 overhead-free.
- **[Completed] Sub-phase 3.3**: NTP Time Sync & RTC Sync.
  - Configured SNTP client to sync time upon WiFi connect (GMT+6 timezone).
  - Provided thread-safe time getter `AppNetworkManager::getInstance().getUnixTimestamp()`.
- **[Completed] Sub-phase 3.4**: HMAC-SHA256 Session Key (`K1`) Derivation.
  - Implemented `mbedtls_md_hmac` deriving 16-byte key `K1 = HMAC-SHA256(api_key, timestamp_str)[:16]` using the private `api_key` securely stored in `/system.json`.
- **[Completed] Sub-phase 3.5**: Hardware-Accelerated AES-128-CBC & Base64 Packing.
  - Implemented `mbedtls_aes_crypt_cbc` encryption/decryption leveraging ESP32's hardware acceleration engine.
  - Utilized `esp_random()` hardware TRNG for generating 16-byte random IVs.
  - Packed/unpacked Base64 payloads formatted as `Base64(IV || Ciphertext)`.
- **[Completed] Sub-phase 3.6**: Request Verification Middleware.
  - Implemented ±30-second replay time-window protection and `mac4` identification verification in Core 1 Coordinator loop.
- **[Completed] Sub-phase 3.7**: Encrypted UDP Discovery Beacon.
  - Implemented periodic UDP broadcast beacon on port 4210 transmitting signature, IP, MAC, and uptime.
  - Encrypted beacon payload using session key `K1` derived from timestamp.
  - Configured broadcast intervals: 15s when unconnected, 60s when connected with active WebSocket clients.

#### Phase 3 Changelog:
* **Added (2026-07-14):** Created `AppNetworkManager` in `src/Network/AppNetworkManager.h` and `src/Network/AppNetworkManager.cpp`.
* **Added (2026-07-14):** Created `CryptoHelper` in `src/Security/CryptoHelper.h` and `src/Security/CryptoHelper.cpp`.
* **Modified (2026-07-14):** Partitioned `StorageManager` to separate `/loads.json`, `/system.json` (locking down the private `api_key`), and `/states.json`.
* **Modified (2026-07-14):** Updated `TaskManager.cpp` to run `AppNetworkManager::process()` on Core 0, and decrypt/verify network events on Core 1.
* **Modified (2026-07-14):** Updated `ESPHome.ino` with serial command prefix filters and local cryptography loopback checks.
* **Modified (2026-07-22):** Added `/api/set-state` HTTP POST endpoint on `AsyncWebServer` (`AppNetworkManager.cpp`) to handle direct local HTTP fallback command frames with instant `200 OK` plain text response on Core 0.

---

### Phase 4: HiveMQ Integration & Rule Engine
**Status:** Completed

- **[Completed] Sub-phase 4.1**: Core 1 SensorTask & Debug Mocking.
  - Implemented periodic 10-second SensorTask on Core 1 under debug mocking flags generating a smooth temperature wave to test thresholds.
- **[Completed] Sub-phase 4.2**: Dynamic Rule Engine.
  - Created `RuleEngine` class loaded from `/rules.json` with dynamic user hysteresis (default 0.5) to prevent relay rapid oscillations.
- **[Completed] Sub-phase 4.3**: Secure HiveMQ MQTT TLS Client (Core 1 Dedicated Task).
  - Spawned `TaskMQTT` pinned to Core 1 (`Priority 2`) to eliminate Core 0 crashes from TLS overhead.
  - Loaded Root CA certificate dynamically from `/system.json` (ISRG Root X1).
  - Integrated `WiFiClientSecure` and `PubSubClient` connecting to port 8883 using credentials and topic patterns with `K1` encryption.
- **[Completed] Sub-phase 4.4**: Fallback Command Pipeline & Offline Queue.
  - Added local WebSocket -> HTTP -> MQTTS fallback pipeline.
  - Created memory-bounded (8 slots) offline cache buffer for telemetry.

#### Phase 4 Changelog:
* **Added (2026-07-14):** Created `RuleEngine` in `src/Core/RuleEngine.h` and `src/Core/RuleEngine.cpp`.
* **Added (2026-07-14):** Created `MqttManager` in `src/Network/MqttManager.h` and `src/Network/MqttManager.cpp`.
* **Modified (2026-07-14):** Updated `StorageManager` to support Root CA cert loading and saving under `/system.json`.
* **Modified (2026-07-14):** Updated `TaskManager` to run `SensorTask` and `TaskMQTT` loops on Core 1, routing sensor telemetry to the Rule Engine and secure MQTT broker.
* **Modified (2026-07-14):** Updated `ESPHome.ino` with RuleEngine boot hooks, dummy output load registration on GPIO 13, and `SYS:SET_HYSTERESIS` dynamic command configurations.

---

### Phase 5: Stability & Testing
**Status:** Pending

- **[Pending] Sub-phase 5.1**: Task Watchdog Timer (TWDT) for Coordinator and Sensor Tasks.
- **[Pending] Sub-phase 5.2**: Heap Fragmentation Guard (25 KB lock latch).
- **[Pending] Sub-phase 5.3**: Memory Pool Exhaustion Policy tests.
- **[Pending] Sub-phase 5.4**: Unit Tests for Cryptography and Rule Evaluation.
- **[Pending] Sub-phase 5.5**: 168-Hour Soak Test and memory leakage analytics.

#### Phase 5 Changelog:
* *No changes yet.*
