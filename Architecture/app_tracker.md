# ESPHome Flutter Client App Migration & Development Tracking

This document tracks the progress of the ESPHome Flutter Client App development. It maps out all phases and sub-phases, starting with layout design, and logs additions/removals similarly to [tracking.md](file:///c:/Users/chaki/Desktop/ESPHome/Architecture/tracking.md).

---

## Overall Progress Summary

| Phase | Description | Status | Target Timeline | Completed Date |
| :--- | :--- | :--- | :--- | :--- |
| **Phase 1** | UI/UX Layout & Navigation (Skeleton) | **Completed** | Week 1 | 2026-07-15 |
| **Phase 2** | Local Cache & State Management | *Pending* | Week 2 | - |
| **Phase 3** | Cryptography & Security Engine | *Pending* | Week 3 | - |
| **Phase 4** | Networking, Discovery & Firebase Sync | *Pending* | Week 4 | - |
| **Phase 5** | Testing, Obfuscation & Deployment (CI/CD) | *Pending* | Week 5 | - |

---

## Detailed Phase Progress & Changelog

### Phase 1: UI/UX Layout & Navigation
**Status:** Completed

- **[Completed] Sub-phase 1.1: Setup Flutter Project & Architecture Skeleton**
  - Initialize Flutter project with flavors (`dev`, `staging`, `prod`).
  - Set up routing/navigation (using `go_router` or standard navigator).
  - Set up state management framework (e.g., Riverpod/Bloc).
- **[Completed] Sub-phase 1.2: Authentication & Login Screen Layout**
  - Create login form UI (email, password fields).
  - Integrate visual state for authentication loading.
- **[Completed] Sub-phase 1.3: Dashboard & Room Layout**
  - Implement Grid/List of active IoT nodes.
  - Implement online/offline status indicators.
  - Add room grouping UI widgets.
- **[Completed] Sub-phase 1.4: Node Control & Loads Layout**
  - Implement load toggles (ON/OFF buttons for relays/lights).
  - Implement sensor cards displaying temperature, humidity, and uptime.
- **[Completed] Sub-phase 1.5: Settings & Custom Rule Setup Layout**
  - Implement switch mode configurations (momentary/toggle switch).
  - Implement custom trigger rules UI (sensor rules, hysteresis configurations).

#### Phase 1 Changelog:
* **Added (2026-07-15):** Created `app_tracker.md` to track progress of the Flutter application.
* **Completed (2026-07-15):** Initialized `frontend` project with `com.adacode.esphome` package. Optimized Gradle configuration JVM heap parameters for low-end device compilation. Built layout screens for Splash, Setup Wizard with notification/location permissions checks, Login, Dashboard, Node Control, Settings, and update checkers. Fixed static analyses issues and verified a clean compile state. Created `build_apk.py` verbose compiler script.
* **Refined (2026-07-15):** Added Registration and Forgot Password screens with password toggles, multi-layout dashboard configuration (Grid, List, Minimal), verbal operator rule builder mapping target loads, active running rules list, secret details masking, Ceiling Fan rotation animation, and conditional dynamic sensor rendering.
* **Refined 2 (2026-07-15):** Created global `nodesProvider` state manager, integrated background simulator timer evaluating automation rules against temperature/humidity fluctuations in real-time, added quick layout switcher in AppBar, whitelisted GPIO pin assignment checks, safety check warnings when deleting loads linked to active rules, and added Account Sign Out flow.
* **Refined 3 (2026-07-15):** Relocated layout configurations from Dashboard to Settings, localized rule operators to English UNDER/ABOVE, structured Settings into a Master layout linking to Security and Bulk Rules sub-pages, moved automation rule builder inside Node Control (node-scoped loads), enabled dynamic chart drawing with real tempHistory values, drew custom symmetrical SpinningFan blades, hid unused labels in GPIO selectors, resolved the manual switch state resetting bug by adding manual override flags to simulator rules evaluations, displayed app version (`v1.0.0`) on Splash and Settings footers, and replaced default Android launcher icons with custom design layouts from `AppIcons/android`.

---

### Phase 2: Local Cache & State Management
**Status:** Pending

- **[Pending] Sub-phase 2.1: Hive/Isar Database Integration**
  - Set up local database database and adapters.
  - Define node profiles and device configurations schemas.
- **[Pending] Sub-phase 2.2: Reactive State Store**
  - Hook state management to local database changes.
  - Set up real-time UI rebuilds based on stream mutations.
- **[Pending] Sub-phase 2.3: Offline Queue Cache**
  - Implement offline memory cache for commands sent during disconnected state.
  - Define persistence policy for commands.

---

### Phase 3: Cryptography & Security Engine
**Status:** Pending

- **[Pending] Sub-phase 3.1: Session Key K1 Derivation**
  - Implement HMAC-SHA256 derivation of `K1` from shared `api_key` and timestamp.
- **[Pending] Sub-phase 3.2: AES-128-CBC Engine**
  - Implement AES encryption/decryption matching ESP32 firmware specs.
  - Secure random 16-byte IV generation using TRNG equivalent.
  - Implement PKCS7 padding and Base64 pack/unpack formatting: `Base64(IV || Ciphertext)`.
- **[Pending] Sub-phase 3.3: Secure Key Storage**
  - Implement secure device Keychain/Keystore access via `flutter_secure_storage` to lock down API keys.
- **[Pending] Sub-phase 3.4: Replay Protection & mac4 Validation**
  - Sync device time with internet time.
  - Implement ±30s message window filtering and `mac4` JSON payload injections.

---

### Phase 4: Networking, Discovery & Firebase Sync
**Status:** Pending

- **[Pending] Sub-phase 4.1: WebSocket Local Engine**
  - Implement connection manager targeting `/ws` on node local IP.
  - Support `[Timestamp]:[Base64]` command packaging.
- **[Pending] Sub-phase 4.2: UDP Discovery Engine**
  - Listen for encrypted UDP Discovery Beacons on port 4210.
  - Support active `ESPHOME_QUERY` broadcast and query reply handling.
- **[Pending] Sub-phase 4.3: HiveMQ MQTT TLS client**
  - Secure MQTTS connection setup on port 8883.
  - Sub/Pub logic for node-specific topic hierarchy.
- **[Pending] Sub-phase 4.4: Firebase Auth & Perms Sync**
  - Integrate user roles verification and admin device registration workflows.
- **[Pending] Sub-phase 4.5: Connection Fallback Pipeline**
  - Implement WebSocket -> HTTP -> MQTT -> Offline Cache fallback cascade.

---

### Phase 5: Testing, Obfuscation & Deployment (CI/CD)
**Status:** Pending

- **[Pending] Sub-phase 5.1: Unit & Security Tests**
  - Unit tests for crypto parity (HMAC-SHA256 / AES-128-CBC compatibility).
  - Validation tests for fallback triggers and reconnect behavior.
- **[Pending] Sub-phase 5.2: Code Obfuscation & Hardening**
  - Build-time obfuscation via `--obfuscate` flags.
  - Configure ProGuard/R8 to prevent static decompiling.
- **[Pending] Sub-phase 5.3: Fastlane & GitHub Actions CI/CD**
  - Automate builds, code signing, and uploads to Google Play Console and App Store Connect.
