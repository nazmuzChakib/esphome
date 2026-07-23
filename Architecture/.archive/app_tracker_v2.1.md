# ESPHome Flutter Client App Migration & Development Tracking

This document tracks the progress of the ESPHome Flutter Client App development. It maps out all phases and sub-phases, starting with layout design, and logs additions/removals similarly to [tracking.md](file:///c:/Users/chaki/Desktop/ESPHome/Architecture/tracking.md).

---

## Overall Progress Summary

| Phase | Description | Status | Target Timeline | Completed Date |
| :--- | :--- | :--- | :--- | :--- |
| **Phase 1** | UI/UX Layout & Navigation (Skeleton) | **Completed** | Week 1 | 2026-07-15 |
| **Phase 2** | Local Cache & State Management | **In Progress** | Week 2 | - |
| **Phase 3** | Cryptography & Security Engine | **In Progress** | Week 3 | - |
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
**Status:** Completed

- **[Completed] Sub-phase 2.1: Hive Database Integration**
  - Set up Hive boxes for `nodes_list` and `rules` in `nodes_provider.dart`.
  - Cache node profiles, dynamic state snapshots, and rule settings locally.
- **[Completed] Sub-phase 2.2: Reactive State Store**
  - Hook Riverpod state management (`NodesNotifier`) to local Hive cache (`LocalCacheService`).
  - Listen to Hive box mutations to reactively update state and re-render UI.
- **[Completed] Sub-phase 2.3: Offline Queue Cache**
  - Implemented `LocalCacheService.enqueueOfflineCommand` using dedicated Hive box (`offline_command_queue`).
  - Automatically buffer commands sent during network disconnects and auto-replay when connection to node/broker restores.

---

### Phase 3: Cryptography & Security Engine
**Status:** Completed

- **[Completed] Sub-phase 3.1: Session Key K1 Derivation**
  - Implemented `NodeSecurityService.deriveSessionKey` generating 16-byte session key $K_1 = \text{HMAC-SHA256}(\text{api\_key}, \text{timestamp})[0..16]$.
- **[Completed] Sub-phase 3.2: AES-128-CBC Engine**
  - Implemented AES-128-CBC payload encryption and decryption with 16-byte random IV generation and PKCS7 padding formatting: `[Timestamp]:[Base64(IV || Ciphertext)]`.
- **[Completed] Sub-phase 3.3: Secure Key Storage**
  - Implemented secure device Keychain/Keystore access via `flutter_secure_storage` in `secure_storage_provider.dart` for locking down API keys.
- **[Completed] Sub-phase 3.4: Replay Protection & mac4 Validation**
  - Implemented `mac4` MAC address tail payload injection and $\pm 30$s timestamp validation filter for node commands.

---

### Phase 4: Networking, Discovery & Fallback Pipeline
**Status:** In Progress (Sub-phase 1 WS + HTTP + UDP Completed, Sub-phase 2 HiveMQ Pending)

- **[Completed] Sub-phase 4.1: WebSocket Local Engine**
  - Implemented `ConnectionManager` targeting `ws://[NODE_IP]:80/ws` with `[Timestamp]:[Base64]` encrypted packet structure.
- **[Completed] Sub-phase 4.2: UDP Discovery Engine & Tray Notifications**
  - Implemented `UdpDiscoveryService` handling passive beacon listening and active `ESPHOME_QUERY` broadcasts on port 4210.
  - Cold boot: 3 rapid scans every 15-20s. Unpaired nodes: scan every 15-20s. Paired nodes: scan every 60s.
  - Sends system notification tray alerts on new node discovery via `flutter_local_notifications`.
- **[Pending] Sub-phase 4.3: HiveMQ MQTT TLS Client (Sub-phase 2)**
  - MQTTS TLS connection setup on port 8883 (scheduled for Phase 4 Sub-phase 2).
- **[Completed] Sub-phase 4.5: Connection Fallback Pipeline (WS + HTTP + Offline Queue)**
  - Implemented `WebSocket (Local Primary)` $\rightarrow$ `HTTP API POST (Local Secondary)` $\rightarrow$ `Offline Queue (Hive DB)` fallback cascade.


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
