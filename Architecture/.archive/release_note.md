# ESPHome Client App Release Notes — v1.2.0 to v1.3.0 Beta

This document lists the new features, user experience enhancements, performance optimizations, and bug fixes introduced in the ESPHome Client App from version `1.2.0` up to the current version `1.3.0 Beta`.

---

## [v1.3.0 Beta] - 2026-07-22
### Added
- **Real-Time Debug Data Monitor**: Integrated a live, terminal-style log viewer screen (`/settings/debug-monitor`) under Settings. Monitors and captures raw incoming/outgoing data payloads across WebSocket, Local HTTP POST fallback, UDP Discovery, and Firebase channels in real time.
- **Persistent Telemetry Logging**: Created `DebugLogService` and `DebugLogger` engine that persists up to 500 network and system telemetry entries in Hive local storage (`debug_logs_box`) across app restarts.
- **Terminal UI & Filtering Tools**: Designed a dark glassmorphic terminal interface featuring `GoogleFonts.firaCode` typography, source filter chips (`ALL`, `WS`, `HTTP`, `UDP`, `FIREBASE`, `SYSTEM`), real-time payload search bar, auto-scroll lock toggle, clear logs, and copy-to-clipboard tools.
- **Unified Master Toast Class (`AppToast`)**: Built a centralized, standardized master toast utility class (`AppToast`) providing static entry points (`AppToast.success`, `AppToast.error`, `AppToast.warning`, `AppToast.info`) with glassmorphic aesthetics, backdrop blur (`sigma: 16.0`), spring/elastic slide animations, and color-coded status indicator bars.
- **AuthProvider GlassToast Integration**: Refactored authentication workflows (`login`, `register`, `loginWithGoogle`, `updateProfile`, `resetPassword`, `logout`) to dispatch glassmorphic `AppToast` notifications directly upon success or error events.
- **Firmware `POST /api/set-state` HTTP Fallback Endpoint**: Registered `POST /api/set-state` HTTP POST endpoint on `AsyncWebServer` in ESP32 firmware (`AppNetworkManager.cpp`). Responds with instant HTTP 200 `"OK"` plain text on Core 0 while queuing `EVENT_NETWORK_COMMAND` to `EventBus` for Core 1 decryption and coordinator execution.
- **Local HTTP Fallback (3s Timeout)**: Implemented local HTTP fallback (`http://<ip>:80/api/set-state`) on Flutter client (`connection_manager.dart`) when WebSocket connection drops or times out after 3 seconds.
- **Offline Queue Pacing & Overload Protection**: Implemented a **200ms pacing delay** between sent commands inside `_flushOfflineQueueForNode` to protect ESP32 FreeRTOS static `EventBus` static queue (16 slots) from buffer overflow or task canary crashes.

### Improved & Cleaned
- **Unused Import & Dead Code Cleanup**: Removed unused imports across presentation screens and refactored authentication screens (`login_screen.dart`, `registration_screen.dart`, `forget_password_screen.dart`, `setup_wizard_screen.dart`) to use `AppToast` directly.
- **Minification Map & State Integrity**: Maintained full preservation of minification maps and comments inside `nodes_provider.dart` to prevent firmware configuration mismatches.

---

## [v1.2.4] - 2026-07-21
### Added
- **Synchronous Cache-First Rendering**: Nodes list and permission statuses are now loaded and rendered synchronously from the local Hive cache on startup, completely eliminating the startup loading spinners and screen flickering.
- **Robust Connection Checks**: Refactored startup connectivity checks to use stream listeners instead of a one-shot `.get()` call, preventing false-positive server connection warnings.
- **Interface & Internet Validation**: Checked for active WiFi/mobile data interfaces first before attempting server connections, alerting the user to connect to the internet if no networks are available.
- **DNS Resolution Host Swap**: Changed the internet check target host from raw IP address `8.8.8.8` to `google.com` to resolve DNS query issues on Android/Windows platforms.
- **Web Platform Permission Bypass**: Bypassed device permissions on Web targets and initialized statuses to `kIsWeb` to prevent `setState` synchronous initState crashes and blocker dialogs on browsers.
- **Link Styling Enhancement**: Removed underlines from the "Why do I need a Cryptographic API Key? Learn more" helper text links on both the setup wizard and security settings screens.
- **Admin Role Sync Blocker**: Solved the issue where Admin accounts displayed as Standard users on fresh app installations. The app now blocks rendering if the profile cache is empty, awaiting Firebase Database synchronization first to build local cache profiles.
- **Registration & Profile Caching**: Synchronized signup registrations by writing data (`firstName`, `lastName`, `email`, `role`) directly to both local Hive cache and Firebase database in parallel.
- **Credential Mismatch Reload Handler**: Showed a modal stating "Please reload app" when a **different account** (different email) logs in with existing cache. Clicking applies new credentials and re-renders the UI safely.
- **Synchronized Decryption Key Retrieval**: Added proactive fetching of the database encryption key from `system/config/encryption_key` before decrypting user roles and profiles.
- **State-Aware Profile Prompt**: Replaced the fixed 1-second delayed popup trigger with a loading-aware polling loop that awaits active Firebase sync before prompting for missing first/last names.
- **Profile Picture Base64 Resize & Sync**: Added automatic image resizing (max 200x200, 60% quality) and Base64 data URL conversion for profile pictures. The compressed string is encrypted and synced directly to Firebase Database (`users/$hash/photo_url`) and Hive local cache without requiring external storage setups. Created `AvatarHelper` to seamlessly decode Base64, URLs, and local files across Web, Android, iOS, and Desktop.
- **Streamlined Edit Profile Dialog**: Redesigned the Edit Profile modal to feature an interactive profile picture avatar picker with live preview. Removed First Name and Last Name text fields from the modal, streamlining profile editing to only require the Display Name.

---


## [v1.2.3] - 2026-07-21
### Added
- **Global App Background Propagation**: Replaced static screen backgrounds on the **Access Control Screen**, **Global Automation Screen**, and **Security Credentials Screen** with the reusable `AppBackground` widget. Custom wallpapers selected in Settings now propagate correctly across all application pages.
- **Settings Avatar Image Sync**: Profile photos uploaded on the Profile edit screen now automatically display in the profile list tile on the main Settings screen, fallback to text initials when no photo exists.
- **Manual Update Check Loader & Timeout**:
  - Implemented a glassmorphic `_UpdateCheckingDialog` progress loader while update checking is in progress.
  - Enforced a `15` seconds HTTP connection timeout limit on GitHub API queries to prevent infinite loading.
  - Customized the update dialog to display a clean **Check Failed** screen with a `cloud_off_rounded` icon and error status on failure, instead of falsely stating "System Up to Date".
- **Cryptographic API Key Explanation Links**:
  - Added a details hyperlink (`Why do I need a Cryptographic API Key? Learn more.`) under the API key input fields on both the **Setup Wizard** and the **Security Credentials** screens.
  - Tapping the hyperlink opens a glassmorphic details popup explaining AES-128-CBC encryption, message signatures, replay attack window protection, and local network security protocols.
- **Parallel Connectivity Checks & Cache-First Rendering**:
  - **Nodes Synchronization**: App checks internet connection in parallel with a 3s timeout. Loads data instantly from the local Hive cache so the dashboard is immediately accessible. If online, fetches node changes (8s timeout limit), updates cache, and updates UI from cache.
  - **Auth Profile & Roles**: Auth initialization loads the user's role and profile data instantly from cache. A background worker connects to Firebase in parallel (5s timeout) to update credentials without freezing the splash screen.
  - **User Permission Service**: Node access checks load permission status from Hive local cache instantly. Offline mode queries the cache directly, and online database queries are limited to a 4s timeout.

### Fixed
- Fixed brackets/braces syntax mismatches in [setup_wizard_screen.dart](file:///c:/Users/chaki/Desktop/ESPHome/frontend/lib/features/setup/presentation/setup_wizard_screen.dart) that caused parser and top-level class definition errors.
- Verified that minification maps and comment integrity inside `nodes_provider.dart` are fully preserved to prevent firmware configuration mismatches.

---

## [v1.2.2] - 2026-07-18
### Added
- **Firebase Authentication & Payload Encryption**: Integrated Firebase Authentication (with support for Google sign-in) and implemented client-side encryption/decryption modules for secure realtime database communication.
- **Automatic/OTA Update Checking**: Integrated automatic checking for newer versions of the app by querying assets from the GitHub Releases API.

### Fixed
- Corrected duplicate closing brackets and syntax formatting errors in the login screen.
- Resolved Firebase startup configuration crashes and made client-side account sign-out execution safe/fail-proof.

---

## [v1.2.1] - 2026-07-16
### Added
- **Hive Cache Integration**: Installed and configured Hive local database storage for persistence of user details, settings, and discovered microcontrollers.
- **Switch Modes and Operators**: Added support for momentary push-buttons vs. toggle switch configuration modes in the loads panel.

### Fixed
- Resolved layout overflow errors in room list views on low-resolution screens.
- Fixed ceiling fan rotation animation layout bugs.

---

## [v1.2.0] - 2026-07-15
### Added
- **Initial App Architecture**: Set up Riverpod state management framework, GoRouter configurations, and multi-flavor compilation variables.
- **App Layout Skeleton**: Bootstrapped UI screens including Splash Screen, Setup Wizard, Login, Dashboard Grid/List, Node Control page, and Settings screens.
- **Safety Blocks on Delete**: Integrated check mechanism inside the rules engine to prevent deleting physical loads that are active or linked to automation rules.
