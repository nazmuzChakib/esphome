# Customization Rules

## General Agent Behavior Rules

- **Sequential Analysis of Open Files:** Do not analyze all currently open files simultaneously or in a single large step. Instead, analyze them sequentially, one by one. Prioritize the most relevant active documents first, and only examine other open files if the context demands it. This helps avoid context pollution and token exhaustion.
- **Open Questions for Known Unknowns in Plans:** Whenever creating or updating an implementation plan, explicitly identify and include open questions to surface known unknowns and clarify ambiguous requirements, design intent, or technical constraints before execution.

---

## Firmware (ESP32) Rules

- **Persistent Minification Mapping Integrity:** Always preserve the minification maps and comments inside `nodes_provider.dart` to avoid firmware configuration mismatches. Under no circumstances should key maps or their comments be deleted.
- **Safety Blocks on Delete:** Deleting a load must check if the load is active/ON and block deletion if so. Standard/bulk rules targeting the deleted load must be auto-cleaned or reset.

### Firmware Memory & Safety Mandates (Non-Negotiable)

- **Arduino String Class Banned:** Never use the Arduino `String` class in firmware. It causes heap fragmentation. All text must use `char[]` (stack) or caller-provided `char*` buffers with `snprintf()`. Function signatures must never return `String`; use `bool` or `int` return with output buffer parameters.

- **F() Macro Mandatory:** Every `Serial.print()` / `Serial.println()` call with a string literal MUST use the `F()` macro or `PSTR()` to store the string in PROGMEM (Flash), not RAM.
  - ❌ `Serial.println("System ready");`
  - ✅ `Serial.println(F("System ready"));`
  - ✅ `Serial.printf_P(PSTR("[HEAP] free=%lu\n"), ESP.getFreeHeap());`

- **Fixed Static Buffers — No Runtime Heap Alloc for Core Data:** All core buffers must be statically allocated at compile time:
  - `LOG_RING_SIZE 512` — Log ring buffer (`char[512]`), overflow = overwrite oldest
  - `SENSOR_HISTORY_SIZE 12` — Sensor ring buffer (`SensorSample[12]` = 144 bytes), integer-scaled fields (no `float`)
  - `WS_RX_BUF_SIZE 512` — WebSocket receive buffer, drop frame if `len >= 512`
  - `CRYPTO_BASE64_OUT_MAX 560` — Crypto output buffer (static inside `CryptoHelper`)

- **Buffer Overflow Is Contained:** When any ring buffer overflows, the overflow MUST stay within the buffer (overwrite oldest entry). Data must NEVER spill outside its defined bounds. An overflow counter must be tracked in `crash_logs.json`.

- **Heap Monitoring Task (Mandatory):** A `HeapMonitor` FreeRTOS task must run on Core 1 at priority 1, checking heap every 10 seconds:
  - `freeHeap < 30000` → log warning
  - `freeHeap < 25000` → set `g_heapLatchActive = true` (suspend MQTT/cloud publish)
  - `freeHeap < 15000` → flush crash log + `esp_restart()` after 3s delay
  - `freeHeap > 32000` → release latch

- **heap_caps_malloc Over malloc:** Any runtime heap allocation (e.g., mbedtls, HTTP responses) must use `heap_caps_malloc(size, MALLOC_CAP_INTERNAL)` not plain `malloc()`.

- **Task Stack Watermark Logging:** Before every firmware release, call `uxTaskGetStackHighWaterMark()` on all tasks and log results. Optimize stack sizes if watermark > 50% unused.

- **IRAM_ATTR for ISR:** All ISR functions and functions called from ISR must be decorated with `IRAM_ATTR`.



---

## Flutter App Rules
- **Glassmorphic Design Standards:** Cards, dialogs, and navigation wrappers should use BackdropFilter with blur `sigma: 16.0` or higher, thin translucent borders, soft shadow offsets, and glowing background blur circular containers.

---

## v3.0 Architecture: Connection-First, Security-First Rules

- **Current Architecture Version:** This project follows **v3.0 Architecture** (Connection-First paradigm). All development must follow the phase ordering defined in `Architecture/Architecture_3.0.md`. Do not skip phases or reorder them.

- **Phase Gate Enforcement:** Each phase must complete its defined Exit Criteria before proceeding to the next. Specifically:
  - **Phase 0 must be completed first**, before any feature work on firmware or app. The gate is: a verified, real, encrypted WebSocket round-trip between the ESP32 and Flutter app using the HMAC-SHA256 + AES-128-CBC protocol.
  - Never begin Phase 1 firmware wiring work before Phase 0 crypto handshake is verified live on hardware.

- **No Dummy Data After Phase 2:** Starting from Phase 2 completion, all UI screens, state providers, and data flows must bind to real firmware data. Any remaining hardcoded mock nodes, simulated temperature timers, or placeholder state values must be removed entirely before Phase 3 begins.

- **Crypto Parity Requirement:** Whenever modifying `CryptoHelper.cpp/.h` (firmware) or `NodeSecurityService.dart` (app), always verify cross-platform parity:
  - Same `api_key` + same `unix_timestamp` must produce the identical 16-byte session key `K1` on both platforms.
  - AES-128-CBC encrypt → transmit → decrypt must produce the original plaintext without exception.
  - Run the crypto round-trip test (Sub-phase 0.3) after any change to either side.

- **Connection-First Development Mandate:** When adding any new feature that involves App ↔ ESP32 data exchange, always implement and verify the live connection path first before building the UI or state logic on top of it. Do not build UI against mock data for new features.

- **Salvageable Modules — Do Not Rewrite Without Justification:** The following modules are verified correct and must not be rewritten without a documented reason: `EventBus`, `SystemMutex`, `StorageManager`, `CryptoHelper`, `AppNetworkManager`, `MqttManager`, `ConnectionManager`, `UdpDiscoveryService`, `NodeSecurityService`, `LocalCacheService`.

- **State Preservation Tracker:** Current phase is **Phase 0 — Foundation Reset & Live Crypto Handshake** (v3.0 rebuild). The immediate next action is to verify a real encrypted WebSocket round-trip on physical hardware before any further development.

---

## Mandatory Change Tracking Rule

- **Track All Changes in `tracking.md`:** After completing ANY sub-phase task or making ANY notable change to firmware (`src/`), Flutter app (`frontend/lib/`), or architecture documents (`Architecture/`), you MUST append a changelog entry to `Architecture/tracking.md`. This is non-negotiable.

  **Format to append under the `## Changelog` section:**
  ```
  * **[Action] (YYYY-MM-DD):** [What changed, 1 sentence] — [File path(s)]
  ```
  **Valid Actions:** `Added` | `Modified` | `Removed` | `Archived` | `Verified` | `Completed`

  **Examples:**
  ```
  * **Completed (2026-07-24):** Sub-phase 0.1.2 — SET_API_KEY serial command handler added — src/Network/AppNetworkManager.cpp
  * **Added (2026-07-24):** debug_connection_screen.dart for Phase 0 WS testing — frontend/lib/features/setup/debug_connection_screen.dart
  * **Verified (2026-07-24):** Crypto round-trip test passed on hardware — Phase 0.3.3 exit criteria met
  ```

- **Mark Sub-phases in tracking.md:** When a sub-phase is completed, update its checkbox from `[ ]` to `[x]` in `Architecture/tracking.md` in the same operation as the code change.

- **Architecture File Changes Must Be Archived First:** Before modifying `Architecture_3.0.md` in a breaking way, copy the current version to `Architecture/.archive/` with a date suffix (e.g., `Architecture_3.0_2026-07-24.md`), then update the main file.
