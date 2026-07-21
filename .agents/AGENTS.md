# Customization Rules

- **Sequential Analysis of Open Files:** Do not analyze all currently open files simultaneously or in a single large step. Instead, analyze them sequentially, one by one. Prioritize the most relevant active documents first, and only examine other open files if the context demands it. This helps avoid context pollution and token exhaustion.

- **Persistent Minification Mapping Integrity:** Always preserve the minification maps and comments inside `nodes_provider.dart` to avoid firmware configuration mismatches. Under no circumstances should key maps or their comments be deleted.
- **App Display Time Format Rules:** App time conditions must display based on user-defined time format configurations in settings (`12h` or `24h`), but under the hood, times are processed and evaluated in standard 24-hour format.
- **Safety Blocks on Delete:** Deleting a load must check if the load is active/ON and block deletion if so. Standard/bulk rules targeting the deleted load must be auto-cleaned or reset.
- **Glassmorphic Design Standards:** Cards, dialogs, and navigation wrappers should use BackdropFilter with blur `sigma: 16.0` or higher, thin translucent borders, soft shadow offsets, and glowing background blur circular containers.
- **State Preservation Tracker:** Current phase focuses on applying full glassmorphic modern redesign across screens and widgets including implementing a custom iOS-style GlassDialog wrapper class.
