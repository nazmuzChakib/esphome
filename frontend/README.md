# ESPHome Secure Node Control Client

A modern, highly optimized Flutter client application designed for real-time ESPHome IoT gateway monitoring, secure local sensor telemetry analysis, and automation rule deployment.

---

## 🚀 Key Features

* **Dynamic Nodes State Engine & Simulator:** Governs live data telemetry of IoT gateways using a Riverpod StateNotifier. Features a background periodic simulator that fluctuates temperature and humidity values to mirror active real-world operations.
* **Interactive Load Management (GPIO Binding):** Supports dynamic pin assignment using a strict whitelisting protocol (`2, 4, 12, 13, 14, 15, 16`). Prevent conflict mapping by dynamically displaying only unused GPIO channels.
* **Inline Node-Scoped Automations:** Configure rules directly from a specific node control view. Support operators **ABOVE** and **UNDER** combined with a custom hysteresis margin to eliminate trigger oscillations.
* **Bulk Global Automations:** Deploy single-condition rules that automatically split and distribute matching trigger definitions to target channels on all connected nodes.
* **Custom Symmetric Spinning Fan:** Symmetrical custom-drawn 3-blade SVG fan widget that rotates smoothly under `AnimationController` and eliminates material icon off-center wobbles.
* **Live Telemetry Trend Charting:** Real-time line graph plotting that connects to actual historical sensor values (`tempHistory`) and repaints dynamically as the background simulation fluctuates.
* **Robust Safety Locks:** Queries active automation rule states before allowing load deletion, blocking high-risk modifications and preventing state inconsistency.
* **Master Configurations Page:** Centralized quick-toggle dashboard layout (Grid, List, Minimal) and physical switch preferences (Toggle, Momentary), with separate sub-pages for AES Decryption Key settings and Bulk Global Automations.
* **Dynamic Versioning:** Queries and displays current platform build configurations dynamically using `package_info_plus` on both Splash and Settings footers.

---

## 🛠️ Technology Stack

* **UI Framework:** Flutter / Dart SDK (`^3.11.4`)
* **State Management:** Riverpod (`StateNotifierProvider`)
* **Database & Cache:** HiveDB (`Hive` / `HiveRunner`) for encrypted local configurations, device states, and rule profiles.
* **Routing:** GoRouter (centralized router registry with settings sub-pathing).
* **Local Notifications & Permissions:** `permission_handler` and `flutter_local_notifications` for managing wizard flows.
* **Build Optimizations:** Tailored heap configurations (`gradle.properties`) for compiling smoothly on low-end development laptops.

---

## 📁 Core Directory Structure

```
lib/
├── core/
│   ├── router/          # GoRouter config (app_router.dart)
│   └── security/        # Secure storage provider & AES decryption keys
├── features/
│   ├── auth/            # Sign In, Registration, Forgot Password pages
│   ├── control/         # Node detail metrics, dynamic line charts, load bindings
│   ├── dashboard/       # layout variations (Grid, List, Minimal), quick averages banner
│   ├── settings/        # Master configurations, bulk rule builders, decryption keys
│   ├── setup/           # wizard configuration flow (permissions check)
│   └── splash/          # Dynamic version loader splash screen
└── main.dart            # Encryption initialization and main runner
```

---

## ⚡ Performance Optimizations

1. **Zero-IO Periodic Timers:** The 5-second telemetry simulator reads from an already open in-memory Hive box reference (`_rulesBox`), entirely bypassing disk operations during periodic ticks. This keeps the rendering pipeline jank-free.
2. **Post-Frame Animation Triggers:** Animation controller side-effects (`repeat()`, `stop()`) are deferred to `WidgetsBinding.instance.addPostFrameCallback`. This isolates UI rebuild triggers from the animation ticker and prevents frame-flickering.
3. **Low-Memory Gradle Setup:** Heap constraints configured inside `gradle.properties` restrict JVM footprint to `2048M`, allowing compilation to complete without system thrashing.

---

## ⚙️ How to Build and Run

### Run Local Debug Build
Ensure you have a connected device/emulator running, then execute:
```bash
flutter pub get
flutter run
```

### Static Analysis Validation
To run the lint analyzer and verify compiler correctness:
```bash
flutter analyze
```

### Build Optimized Android APK
Run the custom Python script to build the release package verbosely:
```bash
python utils/tools/build_apk.py --verbose
```
