import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../dashboard/data/nodes_provider.dart';
import '../data/node_permission_service.dart';
import '../../../core/widgets/custom_toast.dart';
import '../../../core/widgets/glass_dialog.dart';
import '../../../core/widgets/glass_container.dart';
import '../../../core/widgets/app_background.dart';
import '../../../core/utils/sensor_registry.dart';

class NodeControlScreen extends ConsumerStatefulWidget {
  final String mac;
  final String ip;
  final String name;
  final List<String> sensors;

  const NodeControlScreen({
    super.key,
    required this.mac,
    required this.ip,
    required this.name,
    required this.sensors,
  });

  @override
  ConsumerState<NodeControlScreen> createState() => _NodeControlScreenState();
}

class _NodeControlScreenState extends ConsumerState<NodeControlScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _fanAnimationController;

  // Active automation rules list for this node
  List<Map<String, dynamic>> _nodeRules = [];
  bool _isLoadingRules = true;

  // Scroll-aware AppBar
  final ScrollController _scrollController = ScrollController();
  bool _isScrolled = false;

  @override
  void initState() {
    super.initState();
    _fanAnimationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _scrollController.addListener(_onScroll);
    _loadNodeRules();
  }

  void _onScroll() {
    final scrolled = _scrollController.offset > 10;
    if (scrolled != _isScrolled) {
      setState(() => _isScrolled = scrolled);
    }
  }

  void _loadNodeRules() async {
    final box = await Hive.openBox('rules');
    final List<Map<String, dynamic>> rules = [];
    for (var key in box.keys) {
      if (key != 'isFreshOpen') {
        final val = box.get(key);
        if (val is Map) {
          final rule = Map<String, dynamic>.from(val);
          if (rule['nodeName'] == widget.name) {
            rules.add(rule);
          }
        }
      }
    }
    setState(() {
      _nodeRules = rules;
      _isLoadingRules = false;
    });
  }

  void _deleteRule(String ruleId) async {
    final box = await Hive.openBox('rules');
    await box.delete(ruleId);
    GlassToast.show(
      context,
      icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
      color: Colors.redAccent,
      message: 'Automation rule deleted.',
      behave: ToastBehavior.success,
    );
    _loadNodeRules();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _fanAnimationController.dispose();
    super.dispose();
  }

  // Helper: Whitelisted GPIOs
  final List<int> _whitelistedGpios = const [2, 4, 12, 13, 14, 15, 16];

  // Helper: Get unused GPIOs for this node
  List<int> _getUnusedGpios(List loads, {int? exceptGpio}) {
    final List<int> usedGpios = [];
    for (var load in loads) {
      final gpioVal = load['load_gpio'] ?? load['gpio'];
      if (gpioVal is int && (exceptGpio == null || gpioVal != exceptGpio)) {
        usedGpios.add(gpioVal);
      }
    }
    return _whitelistedGpios.where((pin) => !usedGpios.contains(pin)).toList();
  }

  // Helper: Get icon based on load type
  IconData _getIconForType(String type) {
    switch (type) {
      case 'Light':
        return Icons.lightbulb_outline_rounded;
      case 'Fan':
        return Icons.toys_outlined;
      case 'Power':
        return Icons.power_rounded;
      default:
        return Icons.toggle_off_outlined;
    }
  }

  void _confirmDeleteLoad(String loadName, String loadId) {
    GlassDialog.show(
      context,
      title: const Text('Delete Hardware Load?'),
      content: Text(
        'Are you sure you want to remove the load "$loadName"? This action deletes its configurations.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: GoogleFonts.inter(fontWeight: FontWeight.bold),
          ),
        ),
        ElevatedButton(
          onPressed: () {
            final result = ref
                .read(nodesProvider.notifier)
                .deleteLoad(widget.mac, loadId);
            Navigator.pop(context);
            if (result['success'] == true) {
              GlassToast.show(
                context,
                icon: const Icon(Icons.check_circle_outline),
                color: Colors.green,
                message: 'Load "$loadName" deleted successfully.',
                behave: ToastBehavior.success,
              );
            } else {
              GlassToast.show(
                context,
                icon: const Icon(Icons.error_outline),
                color: Colors.redAccent,
                message: result['error'] ?? 'Failed to delete load.',
                behave: ToastBehavior.error,
              );
            }
            _loadNodeRules(); // reload rules since some might have been cleaned up
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Delete'),
        ),
      ],
    );
  }

  void _showAddLoadDialog(List loads) {
    final nameController = TextEditingController();
    final unusedPins = _getUnusedGpios(loads);

    if (unusedPins.isEmpty) {
      GlassToast.show(
        context,
        icon: const Icon(Icons.warning_amber_rounded),
        color: Colors.orangeAccent,
        message: 'All whitelisted GPIO pins are currently in use!',
        behave: ToastBehavior.warning,
      );
      return;
    }

    int? selectedGpio = unusedPins.first;
    int selectedType = 0; // Light
    bool activeHigh = true;
    bool hasSwitch = true;
    bool isPushBtn = false;
    int? selectedSwitchGpio = unusedPins.length > 1
        ? unusedPins[1]
        : unusedPins.first;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    GlassDialog.show(
      context,
      title: const Text('Add Hardware Load'),
      content: StatefulBuilder(
        builder: (context, setStateDialog) {
          // Re-compute switch GPIOs to exclude the selected main GPIO
          final switchUnusedPins = unusedPins
              .where((pin) => pin != selectedGpio)
              .toList();
          if (selectedSwitchGpio == selectedGpio) {
            selectedSwitchGpio = switchUnusedPins.isNotEmpty
                ? switchUnusedPins.first
                : -1;
          }

          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: 'Load Name (e.g. Fan Relay)',
                    prefixIcon: const Icon(Icons.edit_note_rounded),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    filled: true,
                    fillColor: isDark
                        ? Colors.black.withOpacity(0.2)
                        : Colors.white.withOpacity(0.5),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  value: selectedGpio,
                  dropdownColor: isDark
                      ? const Color(0xFF1E293B)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  decoration: InputDecoration(
                    labelText: 'GPIO Connection Pin',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    filled: true,
                    fillColor: isDark
                        ? Colors.black.withOpacity(0.2)
                        : Colors.white.withOpacity(0.5),
                  ),
                  items: unusedPins.map((pin) {
                    return DropdownMenuItem(
                      value: pin,
                      child: Text('GPIO $pin'),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setStateDialog(() {
                        selectedGpio = val;
                      });
                    }
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  value: selectedType,
                  dropdownColor: isDark
                      ? const Color(0xFF1E293B)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  decoration: InputDecoration(
                    labelText: 'Load Category Type',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    filled: true,
                    fillColor: isDark
                        ? Colors.black.withOpacity(0.2)
                        : Colors.white.withOpacity(0.5),
                  ),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Light')),
                    DropdownMenuItem(value: 1, child: Text('Fan')),
                    DropdownMenuItem(value: 2, child: Text('Power Socket')),
                    DropdownMenuItem(value: 3, child: Text('General Switch')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setStateDialog(() => selectedType = val);
                    }
                  },
                ),
                const SizedBox(height: 16),
                // Active High Trigger Row with GlassToggle
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Active High Signal',
                            style: GoogleFonts.outfit(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            'High voltage triggers the load',
                            style: GoogleFonts.inter(
                              color: Colors.grey,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    GlassToggle(
                      value: activeHigh,
                      onChanged: (val) {
                        setStateDialog(() => activeHigh = val);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Has Switch Trigger Row with GlassToggle
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Has Physical Switch',
                            style: GoogleFonts.outfit(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            'Connect physical switch on wall',
                            style: GoogleFonts.inter(
                              color: Colors.grey,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    GlassToggle(
                      value: hasSwitch,
                      onChanged: (val) {
                        setStateDialog(() => hasSwitch = val);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: hasSwitch
                      ? Column(
                          key: const ValueKey('has_switch_settings'),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Divider(height: 24),
                            // Push button toggle row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Momentary Push Button',
                                        style: GoogleFonts.outfit(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                      Text(
                                        'Elastic push button instead of toggle',
                                        style: GoogleFonts.inter(
                                          color: Colors.grey,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                GlassToggle(
                                  value: isPushBtn,
                                  onChanged: (val) {
                                    setStateDialog(() => isPushBtn = val);
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            // Switch GPIO Dropdown
                            if (switchUnusedPins.isEmpty)
                              const Text(
                                'No additional GPIO pins available for switch connection!',
                                style: TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 11,
                                ),
                              )
                            else
                              DropdownButtonFormField<int>(
                                value: selectedSwitchGpio == -1
                                    ? switchUnusedPins.first
                                    : selectedSwitchGpio,
                                dropdownColor: isDark
                                    ? const Color(0xFF1E293B)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                decoration: InputDecoration(
                                  labelText: 'Switch GPIO Connection Pin',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  filled: true,
                                  fillColor: isDark
                                      ? Colors.black.withOpacity(0.2)
                                      : Colors.white.withOpacity(0.5),
                                ),
                                items: switchUnusedPins.map((pin) {
                                  return DropdownMenuItem(
                                    value: pin,
                                    child: Text('GPIO $pin'),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setStateDialog(
                                      () => selectedSwitchGpio = val,
                                    );
                                  }
                                },
                              ),
                          ],
                        )
                      : const SizedBox.shrink(
                          key: ValueKey('no_switch_settings'),
                        ),
                ),
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: GoogleFonts.inter(fontWeight: FontWeight.bold),
          ),
        ),
        ElevatedButton(
          onPressed: () {
            final String trimmedName = nameController.text.trim();
            if (trimmedName.isEmpty) return;

            final success = ref
                .read(nodesProvider.notifier)
                .addLoad(
                  mac: widget.mac,
                  loadName: trimmedName,
                  gpio: selectedGpio!,
                  type: selectedType,
                  activeHigh: activeHigh,
                  hasSwitch: hasSwitch,
                  isPushBtn: isPushBtn,
                  switchGpio: hasSwitch ? selectedSwitchGpio : null,
                );

            if (success) {
              Navigator.pop(context);
              GlassToast.show(
                context,
                icon: const Icon(Icons.check_circle_outline),
                color: Colors.green,
                message: 'Load "$trimmedName" added successfully.',
                behave: ToastBehavior.success,
              );
            } else {
              GlassToast.show(
                context,
                icon: const Icon(Icons.error_outline),
                color: Colors.redAccent,
                message: 'Configuration pin or name conflict!',
                behave: ToastBehavior.error,
              );
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Add'),
        ),
      ],
    );
  }

  void _showEditLoadDialog(Map<String, dynamic> load, List loads) {
    final loadId = load['load_id'] as String;
    final loadName = (load['load_name'] ?? load['name']) as String;
    final currentGpio = (load['load_gpio'] ?? load['gpio']) as int;

    // Resolve type to int
    final rawType = load['load_type'] ?? load['type'];
    int currentType = 0;
    if (rawType is int) {
      currentType = rawType;
    } else if (rawType == 'Fan') {
      currentType = 1;
    } else if (rawType == 'Power') {
      currentType = 2;
    } else if (rawType == 'Switch') {
      currentType = 3;
    }

    final nameController = TextEditingController(text: loadName);
    int selectedType = currentType;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    GlassDialog.show(
      context,
      title: const Text('Modify Load Configuration'),
      content: StatefulBuilder(
        builder: (context, setStateDialog) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: 'Load Name',
                  prefixIcon: const Icon(Icons.edit_note_rounded),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  filled: true,
                  fillColor: isDark
                      ? Colors.black.withOpacity(0.2)
                      : Colors.white.withOpacity(0.5),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                value: selectedType,
                dropdownColor: isDark ? const Color(0xFF1E293B) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                decoration: InputDecoration(
                  labelText: 'Category Type',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  filled: true,
                  fillColor: isDark
                      ? Colors.black.withOpacity(0.2)
                      : Colors.white.withOpacity(0.5),
                ),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Light (Bulb)')),
                  DropdownMenuItem(value: 1, child: Text('Fan (Spinning)')),
                  DropdownMenuItem(value: 2, child: Text('Power Socket')),
                  DropdownMenuItem(value: 3, child: Text('General Switch')),
                ],
                onChanged: (val) {
                  if (val != null) setStateDialog(() => selectedType = val);
                },
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                'Physical Configurations (Locked)',
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 8),
              _buildReadOnlyField('Load ID', loadId),
              _buildReadOnlyField('GPIO Pin', 'GPIO $currentGpio'),
              _buildReadOnlyField(
                'Active High',
                load['active_high'] == true ? 'Yes' : 'No',
              ),
              _buildReadOnlyField(
                'Has Physical Switch',
                load['hasSwitch'] == true ? 'Yes' : 'No',
              ),
              if (load['hasSwitch'] == true) ...[
                _buildReadOnlyField(
                  'Switch Type',
                  load['isPushBtn'] == true
                      ? 'Momentary Push Button'
                      : 'Toggle Switch',
                ),
                _buildReadOnlyField(
                  'Switch GPIO',
                  'GPIO ${load['switch_gpio']}',
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: GoogleFonts.inter(fontWeight: FontWeight.bold),
          ),
        ),
        ElevatedButton(
          onPressed: () {
            if (nameController.text.trim().isEmpty) return;
            final success = ref
                .read(nodesProvider.notifier)
                .editLoad(
                  mac: widget.mac,
                  loadId: loadId,
                  newLoadName: nameController.text.trim(),
                  newLoadType: selectedType,
                );
            if (success) {
              Navigator.pop(context);
              GlassToast.show(
                context,
                icon: const Icon(Icons.check_circle_outline),
                color: Colors.green,
                message: 'Load "${nameController.text.trim()}" updated.',
                behave: ToastBehavior.success,
              );
            } else {
              GlassToast.show(
                context,
                icon: const Icon(Icons.error_outline),
                color: Colors.redAccent,
                message: 'Load name conflict!',
                behave: ToastBehavior.error,
              );
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _buildReadOnlyField(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          Text(
            value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  void _showAddRuleDialog(List nodeLoads) {
    if (nodeLoads.isEmpty) {
      GlassToast.show(
        context,
        icon: const Icon(Icons.warning_amber_rounded),
        color: Colors.orangeAccent,
        message: 'Add at least one output load first!',
        behave: ToastBehavior.warning,
      );
      return;
    }

    String selectedLoadId = nodeLoads.first['load_id']?.toString() ?? '';
    bool actionState = true; // Turn ON / OFF
    String logicalOp = 'AND'; // AND / OR

    // Dynamic list of conditions
    List<Map<String, dynamic>> conditionsList = [
      {
        'type': 'sensor',
        'sensor': 'Temperature', // Temperature / Humidity
        'operator': 'ABOVE', // ABOVE / UNDER
        'threshold': 32.0,
        'hysteresis': 1.0, // Default hysteresis value
      },
    ];

    final isDark = Theme.of(context).brightness == Brightness.dark;

    GlassDialog.show(
      context,
      title: const Text('Add Automation Rule'),
      content: StatefulBuilder(
        builder: (context, setStateDialog) => SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            physics: const BouncingScrollPhysics(),
            children: [
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: selectedLoadId.isEmpty ? null : selectedLoadId,
                dropdownColor: isDark ? const Color(0xFF1E293B) : Colors.white,
                borderRadius: BorderRadius.circular(12),
                decoration: InputDecoration(
                  labelText: 'Target Output Load',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: isDark
                      ? Colors.white.withOpacity(0.04)
                      : Colors.black.withOpacity(0.02),
                ),
                items: nodeLoads.map((load) {
                  final lId = load['load_id']?.toString() ?? '';
                  final lName = (load['load_name'] ?? load['name']) as String;
                  return DropdownMenuItem(value: lId, child: Text(lName));
                }).toList(),
                onChanged: (val) {
                  if (val != null) setStateDialog(() => selectedLoadId = val);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<bool>(
                value: actionState,
                dropdownColor: isDark ? const Color(0xFF1E293B) : Colors.white,
                borderRadius: BorderRadius.circular(12),
                decoration: InputDecoration(
                  labelText: 'Action Output State',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: isDark
                      ? Colors.white.withOpacity(0.04)
                      : Colors.black.withOpacity(0.02),
                ),
                items: const [
                  DropdownMenuItem(
                    value: true,
                    child: Text('Turn ON target load'),
                  ),
                  DropdownMenuItem(
                    value: false,
                    child: Text('Turn OFF target load'),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) setStateDialog(() => actionState = val);
                },
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Logical Connector',
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  ToggleButtons(
                    isSelected: [logicalOp == 'AND', logicalOp == 'OR'],
                    onPressed: (index) {
                      setStateDialog(() {
                        logicalOp = index == 0 ? 'AND' : 'OR';
                      });
                    },
                    borderRadius: BorderRadius.circular(8),
                    color: isDark ? Colors.white60 : Colors.black54,
                    selectedColor: Colors.white,
                    fillColor: Theme.of(context).primaryColor,
                    constraints: const BoxConstraints(
                      minWidth: 55,
                      minHeight: 28,
                    ),
                    children: const [
                      Text(
                        'AND',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'OR',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Conditions List',
                    style: GoogleFonts.outfit(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.add, size: 14),
                    label: const Text(
                      'Add Condition',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onPressed: () {
                      setStateDialog(() {
                        conditionsList.add({
                          'type': 'sensor',
                          'sensor': 'Temperature',
                          'operator': 'ABOVE',
                          'threshold': 30.0,
                          'hysteresis': 1.0,
                        });
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...conditionsList.asMap().entries.map((entry) {
                final index = entry.key;
                final cond = entry.value;
                final type = cond['type'] ?? 'sensor';

                return GlassContainer(
                  borderRadius: 16.0,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Condition #${index + 1}',
                            style: GoogleFonts.outfit(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: Theme.of(context).primaryColor,
                            ),
                          ),
                          if (conditionsList.length > 1)
                            GestureDetector(
                              onTap: () {
                                setStateDialog(() {
                                  conditionsList.removeAt(index);
                                });
                              },
                              child: const Icon(
                                Icons.delete_outline,
                                color: Colors.redAccent,
                                size: 18,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            'Type:',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text(
                              'Sensor',
                              style: TextStyle(fontSize: 11),
                            ),
                            selected: type == 'sensor',
                            onSelected: (selected) {
                              if (selected) {
                                setStateDialog(() {
                                  conditionsList[index] = {
                                    'type': 'sensor',
                                    'sensor': 'Temperature',
                                    'operator': 'ABOVE',
                                    'threshold': 30.0,
                                    'hysteresis': 1.0,
                                  };
                                });
                              }
                            },
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text(
                              'Time',
                              style: TextStyle(fontSize: 11),
                            ),
                            selected: type == 'time',
                            onSelected: (selected) {
                              if (selected) {
                                setStateDialog(() {
                                  conditionsList[index] = {
                                    'type': 'time',
                                    'operator': 'after',
                                    'value': '12:00',
                                    'end_value': null,
                                  };
                                });
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (type == 'sensor') ...[
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: cond['sensor'],
                                dropdownColor: isDark
                                    ? const Color(0xFF1E293B)
                                    : Colors.white,
                                decoration: const InputDecoration(
                                  labelText: 'Sensor',
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'Temperature',
                                    child: Text('Temp'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'Humidity',
                                    child: Text('Humi'),
                                  ),
                                ],
                                onChanged: (val) {
                                  if (val != null) {
                                    setStateDialog(() => cond['sensor'] = val);
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: cond['operator'],
                                dropdownColor: isDark
                                    ? const Color(0xFF1E293B)
                                    : Colors.white,
                                decoration: const InputDecoration(
                                  labelText: 'Limit',
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'ABOVE',
                                    child: Text('Above'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'UNDER',
                                    child: Text('Under'),
                                  ),
                                ],
                                onChanged: (val) {
                                  if (val != null) {
                                    setStateDialog(() {
                                      cond['operator'] = val;
                                    });
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          initialValue: cond['threshold']?.toString(),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Threshold Trigger Value',
                          ),
                          onChanged: (val) {
                            final double? d = double.tryParse(val);
                            if (d != null) cond['threshold'] = d;
                          },
                        ),
                        const SizedBox(height: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Hysteresis deadband:',
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: isDark
                                        ? Colors.white70
                                        : Colors.black87,
                                  ),
                                ),
                                Text(
                                  '±${(cond['hysteresis'] ?? 1.0).toStringAsFixed(1)}',
                                  style: GoogleFonts.outfit(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(context).primaryColor,
                                  ),
                                ),
                              ],
                            ),
                            Slider(
                              value: (cond['hysteresis'] ?? 1.0).toDouble(),
                              min: 0.5,
                              max: 2.0,
                              divisions: 15,
                              label:
                                  '±${(cond['hysteresis'] ?? 1.0).toStringAsFixed(1)}',
                              onChanged: (val) {
                                setStateDialog(() {
                                  cond['hysteresis'] = val;
                                });
                              },
                            ),
                          ],
                        ),
                      ] else ...[
                        DropdownButtonFormField<String>(
                          value: cond['operator'],
                          dropdownColor: isDark
                              ? const Color(0xFF1E293B)
                              : Colors.white,
                          decoration: const InputDecoration(
                            labelText: 'Condition',
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'after',
                              child: Text('Is After'),
                            ),
                            DropdownMenuItem(
                              value: 'before',
                              child: Text('Is Before'),
                            ),
                            DropdownMenuItem(
                              value: 'between',
                              child: Text('Is Between'),
                            ),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setStateDialog(() {
                                cond['operator'] = val;
                                if (val == 'between' &&
                                    cond['end_value'] == null) {
                                  cond['end_value'] = '23:59';
                                }
                              });
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(
                                  Icons.access_time_rounded,
                                  size: 16,
                                ),
                                onPressed: () async {
                                  final TimeOfDay? t = await showTimePicker(
                                    context: context,
                                    initialTime: TimeOfDay.now(),
                                  );
                                  if (t != null) {
                                    final formatted =
                                        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
                                    setStateDialog(
                                      () => cond['value'] = formatted,
                                    );
                                  }
                                },
                                label: Text(
                                  cond['value'] != null
                                      ? _formatTimeDisplay(
                                          cond['value']!,
                                          Hive.box('settings').get(
                                            'timeFormat',
                                            defaultValue: '12h',
                                          ),
                                        )
                                      : 'Select Time',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                            if (cond['operator'] == 'between') ...[
                              const SizedBox(width: 8),
                              Text(
                                'to',
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(
                                    Icons.access_time_rounded,
                                    size: 16,
                                  ),
                                  onPressed: () async {
                                    final TimeOfDay? t = await showTimePicker(
                                      context: context,
                                      initialTime: const TimeOfDay(
                                        hour: 23,
                                        minute: 59,
                                      ),
                                    );
                                    if (t != null) {
                                      final formatted =
                                          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
                                      setStateDialog(
                                        () => cond['end_value'] = formatted,
                                      );
                                    }
                                  },
                                  label: Text(
                                    cond['end_value'] != null
                                        ? _formatTimeDisplay(
                                            cond['end_value']!,
                                            Hive.box('settings').get(
                                              'timeFormat',
                                              defaultValue: '12h',
                                            ),
                                          )
                                        : 'Select End Time',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: GoogleFonts.inter(fontWeight: FontWeight.bold),
          ),
        ),
        ElevatedButton(
          onPressed: () async {
            final List<Map<String, dynamic>> minifiedConditions = [];
            for (var cond in conditionsList) {
              final String type = cond['type'] ?? 'sensor';
              if (type == 'sensor') {
                minifiedConditions.add({
                  't': 'sensor',
                  'src': cond['sensor'] == 'Temperature' ? 'temp' : 'humi',
                  'op': cond['operator'],
                  'th': cond['threshold'] ?? 30.0,
                  'hy': cond['hysteresis'] ?? 1.0,
                });
              } else {
                minifiedConditions.add({
                  't': 'time',
                  'op': cond['operator'],
                  'v': cond['value'] ?? '00:00',
                  'ev': cond['end_value'],
                });
              }
            }

            final box = await Hive.openBox('rules');
            final List<Map<String, dynamic>> existingRules = [];
            for (var key in box.keys) {
              final val = box.get(key);
              if (val is Map) {
                existingRules.add(Map<String, dynamic>.from(val));
              }
            }

            // Helper to canonicalize a condition map for exact matching
            String canonicalize(Map<String, dynamic> m) {
              final keys = m.keys.toList()..sort();
              return keys.map((k) => "$k:${m[k]}").join(",");
            }

            bool isConflict = false;
            for (var rule in existingRules) {
              if (rule['act'] == selectedLoadId && rule['op'] == logicalOp) {
                final List ruleConds = rule['conds'] is List
                    ? rule['conds']
                    : [];
                if (ruleConds.length == minifiedConditions.length) {
                  final set1 = ruleConds
                      .map((c) => canonicalize(Map<String, dynamic>.from(c)))
                      .toSet();
                  final set2 = minifiedConditions.map(canonicalize).toSet();
                  if (set1.length == set2.length && set1.containsAll(set2)) {
                    isConflict = true;
                    break;
                  }
                }
              }
            }

            if (isConflict) {
              GlassToast.show(
                context,
                icon: const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.orangeAccent,
                ),
                color: Colors.orange,
                message:
                    'Conflict: Identical rule conditions already exist for this load.',
                behave: ToastBehavior.warning,
              );
              return;
            }

            final ruleId = 'rule_${DateTime.now().millisecondsSinceEpoch}';

            final rule = {
              'id': ruleId,
              'nodeName': widget.name,
              'nodeMac': widget.mac,
              'op': logicalOp,
              'conds': minifiedConditions,
              'act': selectedLoadId,
              'val': actionState,
            };
            await box.put(ruleId, rule);

            Navigator.pop(context);
            GlassToast.show(
              context,
              icon: const Icon(Icons.check_circle_outline),
              color: Colors.green,
              message: 'Automation rule registered.',
              behave: ToastBehavior.success,
            );
            _loadNodeRules();
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Realtime Permission Revoke Check
    ref.listen<AsyncValue<NodePermissionStatus>>(
      nodeAccessStreamProvider(widget.mac),
      (previous, next) {
        next.whenData((status) {
          if (status == NodePermissionStatus.unapproved) {
            if (context.mounted) {
              _showRevokedAccessDialog(context);
            }
          }
        });
      },
    );

    // Watch modifications to nodes list in real-time
    final nodesList = ref.watch(nodesProvider);
    final nodeInfo = nodesList.firstWhere(
      (n) => n['mac'] == widget.mac,
      orElse: () => <String, dynamic>{},
    );

    if (nodeInfo.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Node Error')),
        body: const Center(child: Text('Device not found.')),
      );
    }

    final List nodeLoads = nodeInfo['loads'] as List? ?? [];
    final hasSensors =
        nodeInfo['sensors'] is List && (nodeInfo['sensors'] as List).isNotEmpty;
    final List<double> history =
        (nodeInfo['tempHistory'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        const <double>[];

    // Check if any fan is active to animate rotation safely after frame builds
    bool hasActiveFan = false;
    for (var l in nodeLoads) {
      final rawType = l['load_type'] ?? l['type'];
      final bool isFanType = (rawType == 1 || rawType == 'Fan');
      final bool isStateOn = (l['state'] == true || l['load_state'] == true);
      if (isFanType && isStateOn) {
        hasActiveFan = true;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (hasActiveFan) {
          if (!_fanAnimationController.isAnimating) {
            _fanAnimationController.repeat();
          }
        } else {
          if (_fanAnimationController.isAnimating) {
            _fanAnimationController.stop();
          }
        }
      }
    });

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: Text(
          nodeInfo['name'] ?? widget.name ?? 'Node Details',
          style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
        ),
        leading: Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDark
                ? Colors.white.withOpacity(0.1)
                : Colors.black.withOpacity(0.05),
            border: Border.all(
              color: isDark
                  ? Colors.white.withOpacity(0.15)
                  : Colors.black.withOpacity(0.08),
              width: 1.5,
            ),
          ),
          child: IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              size: 16,
              color: isDark ? Colors.white : Colors.black87,
            ),
            onPressed: () => Navigator.maybePop(context),
            padding: EdgeInsets.zero,
          ),
        ),
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: _isScrolled ? 20.0 : 0.0,
              sigmaY: _isScrolled ? 20.0 : 0.0,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: _isScrolled
                    ? (isDark
                          ? const Color(0xFF0A0F1E).withOpacity(0.82)
                          : Colors.white.withOpacity(0.85))
                    : Colors.transparent,
                border: Border(
                  bottom: BorderSide(
                    color: _isScrolled
                        ? (isDark
                              ? Colors.white.withOpacity(0.12)
                              : Colors.black.withOpacity(0.08))
                        : Colors.transparent,
                    width: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          AppBackground(isDark: isDark),
          SafeArea(
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Secret Masking details
                  _buildDetailsCard(theme, isDark),
                  const SizedBox(height: 24),

                  // Actuator Toggles Section
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Load Controller',
                        style: GoogleFonts.outfit(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.add_circle_outline_rounded,
                          color: Colors.blueAccent,
                        ),
                        onPressed: () => _showAddLoadDialog(nodeLoads),
                        tooltip: 'Add Load Pin',
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (nodeLoads.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: theme.cardColor,
                      ),
                      child: Center(
                        child: Text(
                          'No output loads configured on this node.\nClick the "+" icon above to configure.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(color: Colors.grey),
                        ),
                      ),
                    )
                  else
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                            childAspectRatio: 1.25,
                          ),
                      itemCount: nodeLoads.length,
                      itemBuilder: (context, index) {
                        final load = nodeLoads[index];
                        return _buildToggleCard(
                          load: load,
                          nodeLoads: nodeLoads,
                          theme: theme,
                          isDark: isDark,
                        );
                      },
                    ),

                  // Automation Rules Scoped Section inside Details
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Device Automation Rules',
                        style: GoogleFonts.outfit(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.add_task_rounded,
                          color: Colors.teal,
                        ),
                        onPressed: () => _showAddRuleDialog(nodeLoads),
                        tooltip: 'Add Node Automation Rule',
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildLocalRulesWidget(theme, isDark, nodeLoads),
                  // Dynamic Sensor Telemetry Section (SensorRegistry-based)
                  // Renders ALL sensors from sensorReadings map — no app update needed for new sensors.
                  if (hasSensors) ...[
                    const SizedBox(height: 32),
                    Text(
                      'Realtime Sensor Telemetry',
                      style: GoogleFonts.outfit(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Build sensor cards from sensorReadings map (universal)
                    Builder(
                      builder: (context) {
                        final dynamic readings = nodeInfo['sensorReadings'];
                        Map<String, dynamic> sensorMap = {};

                        if (readings is Map && readings.isNotEmpty) {
                          readings.forEach((k, v) {
                            if (v is num) sensorMap[k.toString()] = v;
                          });
                        } else {
                          // Fallback: legacy fields
                          final sensors = nodeInfo['sensors'] as List? ?? [];
                          if (sensors.contains('temperature') &&
                              nodeInfo['temp'] != null) {
                            sensorMap['temperature'] = nodeInfo['temp'];
                          }
                          if (sensors.contains('humidity') &&
                              nodeInfo['humi'] != null) {
                            sensorMap['humidity'] = nodeInfo['humi'];
                          }
                        }

                        if (sensorMap.isEmpty) return const SizedBox.shrink();

                        final entries = sensorMap.entries.toList();
                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: entries.map((entry) {
                            final def = SensorRegistry.get(entry.key);
                            return SizedBox(
                              width:
                                  (MediaQuery.of(context).size.width - 56) / 2,
                              child: GlassContainer(
                                borderRadius: 16.0,
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(def.icon, color: def.color, size: 32),
                                    const SizedBox(height: 8),
                                    Text(
                                      def.label,
                                      style: GoogleFonts.inter(
                                        fontSize: 12,
                                        color: Colors.grey,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      def.formatValue(entry.value),
                                      style: GoogleFonts.outfit(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: isDark
                                            ? Colors.white
                                            : Colors.black87,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    // Temperature history chart
                    if (history.isNotEmpty)
                      SizedBox(
                        height: 120,
                        child: CustomPaint(
                          painter: _TelemetryChartPainter(
                            history: history,
                            color: Colors.orangeAccent.withOpacity(0.8),
                          ),
                          child: Container(),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailsCard(ThemeData theme, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withOpacity(0.06)
                  : Colors.black.withOpacity(0.03),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark
                    ? Colors.white.withOpacity(0.1)
                    : Colors.black.withOpacity(0.06),
                width: 1.5,
              ),
            ),
            child: Column(
              children: [
                _buildDetailsRow(
                  Icons.timer_outlined,
                  'Node Uptime',
                  '03 hrs 24 mins',
                ),
                const Divider(height: 24),
                _buildDetailsRow(
                  Icons.link,
                  'Connection Link',
                  'Active (Local-WS Mode)',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailsRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF94A3B8), size: 20),
        const SizedBox(width: 12),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 14,
            color: const Color(0xFF94A3B8),
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildToggleCard({
    required Map<String, dynamic> load,
    required List nodeLoads,
    required ThemeData theme,
    required bool isDark,
  }) {
    final String loadName = load['load_name'] ?? load['name'] ?? '';
    final String loadId = load['load_id']?.toString() ?? '';
    final int gpio = load['load_gpio'] ?? load['gpio'] ?? -1;
    final rawType = load['load_type'] ?? load['type'];
    final String type;
    if (rawType is int) {
      if (rawType == 0) {
        type = 'Light';
      } else if (rawType == 1) {
        type = 'Fan';
      } else if (rawType == 2) {
        type = 'Power';
      } else {
        type = 'Switch';
      }
    } else {
      type = rawType?.toString() ?? 'Light';
    }
    final bool state = load['state'] == true;

    Color typeColor = theme.primaryColor;
    if (type == 'Light') typeColor = Colors.orangeAccent;
    if (type == 'Fan') typeColor = Colors.blueAccent;
    if (type == 'Power') typeColor = Colors.teal;

    final cardBgColor = state
        ? typeColor.withOpacity(0.12)
        : (isDark
              ? Colors.white.withOpacity(0.05)
              : Colors.black.withOpacity(0.03));

    final iconColor = state ? typeColor : const Color(0xFF64748B);

    final borderStyle = state
        ? Border.all(color: typeColor.withOpacity(0.6), width: 1.5)
        : Border.all(
            color: isDark
                ? Colors.white.withOpacity(0.1)
                : Colors.black.withOpacity(0.06),
            width: 1.5,
          );

    Widget iconWidget;
    if (type == 'Fan') {
      iconWidget = SpinningFan(
        animation: _fanAnimationController,
        color: iconColor,
      );
    } else {
      iconWidget = Icon(_getIconForType(type), color: iconColor, size: 28);
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: state
            ? [
                BoxShadow(
                  color: typeColor.withOpacity(0.15),
                  blurRadius: 8,
                  spreadRadius: 1,
                  offset: const Offset(0, 4),
                ),
              ]
            : [],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(
              horizontal: 12.0,
              vertical: 10.0,
            ),
            decoration: BoxDecoration(
              color: cardBgColor,
              borderRadius: BorderRadius.circular(16),
              border: borderStyle,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    iconWidget,
                    PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.more_vert,
                        size: 20,
                        color: Colors.grey,
                      ),
                      onSelected: (val) async {
                        if (val == 'edit') {
                          _showEditLoadDialog(load, nodeLoads);
                        } else if (val == 'delete') {
                          _confirmDeleteLoad(loadName, loadId);
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                      ],
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            loadName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          Text(
                            'GPIO $gpio',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: const Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: state,
                      activeColor: typeColor,
                      onChanged: (val) {
                        ref
                            .read(nodesProvider.notifier)
                            .toggleLoadState(widget.mac, loadId);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLocalRulesWidget(
    ThemeData theme,
    bool isDark,
    List<dynamic> nodeLoads,
  ) {
    if (_isLoadingRules) {
      return const Center(child: CircularProgressIndicator());
    }

    final nodes = ref.watch(nodesProvider);
    final nodeInfo = nodes.firstWhere(
      (n) => n['mac'] == widget.mac,
      orElse: () => <String, dynamic>{},
    );
    final resolvedLoads = nodeInfo['loads'] as List? ?? [];

    if (_nodeRules.isEmpty) {
      return GlassContainer(
        borderRadius: 16.0,
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: Text(
            'No active automation rules on this node.',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: Colors.grey,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _nodeRules.map((rule) {
        final List conds = rule['conds'] ?? [];
        final String op = rule['op'] ?? 'AND';
        final String targetId = rule['act']?.toString() ?? '';
        final bool targetVal = rule['val'] ?? true;

        // Resolve load name from ID
        final matchedLoad = resolvedLoads.firstWhere(
          (l) => l['load_id']?.toString() == targetId,
          orElse: () => <String, dynamic>{},
        );
        final targetName = matchedLoad.isNotEmpty
            ? (matchedLoad['load_name'] ?? matchedLoad['name'])
            : targetId;

        String condsText = '';
        if (conds.isEmpty) {
          // Old rule format display compatibility
          final sensor = rule['sensor'] ?? 'Temperature';
          final operator = rule['operator'] == 'ABOVE' ? 'Above' : 'Below';
          final threshold = rule['threshold'] ?? '';
          final List? loadsList = rule['loads'] is List
              ? rule['loads'] as List
              : null;
          final loads = loadsList?.join(', ') ?? '';
          condsText =
              'If $sensor is $operator $threshold then turn $loads ${rule['actionOn'] == false ? 'OFF' : 'ON'}';
        } else {
          final List<String> condStrings = [];
          for (var cond in conds) {
            final String type = cond['t'] ?? 'sensor';
            if (type == 'sensor') {
              final src =
                  (cond['src'] == 'temp' || cond['src'] == 'temperature')
                  ? 'Temp'
                  : 'Humidity';
              final opSign = cond['op'] == 'ABOVE' ? '>' : '<';
              final th = cond['th'] ?? '';
              final double hy = (cond['hy'] ?? 1.0).toDouble();
              condStrings.add('$src $opSign $th (±${hy.toStringAsFixed(1)})');
            } else if (type == 'time') {
              final opTime = cond['op'] ?? 'after';
              final vTime = cond['v'] ?? '';
              final timeFormat = Hive.box(
                'settings',
              ).get('timeFormat', defaultValue: '12h');
              final formattedV = _formatTimeDisplay(vTime, timeFormat);
              if (opTime == 'between') {
                final evTime = cond['ev'] ?? '';
                final formattedEV = _formatTimeDisplay(evTime, timeFormat);
                condStrings.add('Time is between $formattedV and $formattedEV');
              } else {
                condStrings.add('Time is $opTime $formattedV');
              }
            }
          }
          condsText =
              'If ${condStrings.join(' $op ')} then turn $targetName ${targetVal ? 'ON' : 'OFF'}';
        }

        return GlassContainer(
          borderRadius: 16.0,
          margin: const EdgeInsets.only(bottom: 12),
          padding: EdgeInsets.zero,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            leading: CircleAvatar(
              backgroundColor: theme.primaryColor.withOpacity(0.15),
              child: Icon(
                conds.isNotEmpty && conds.first['t'] == 'time'
                    ? Icons.schedule
                    : Icons.thermostat,
                color: theme.primaryColor,
              ),
            ),
            title: Text(
              condsText,
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            trailing: IconButton(
              icon: const Icon(
                Icons.delete_outline,
                color: Colors.redAccent,
                size: 20,
              ),
              onPressed: () => _deleteRule(rule['id']),
            ),
          ),
        );
      }).toList(),
    );
  }

  String _formatTimeDisplay(String timeStr, String userFormat) {
    if (userFormat == '24h') return timeStr;
    try {
      final parts = timeStr.split(':');
      final hour = int.parse(parts[0]);
      final min = int.parse(parts[1]);
      final ampm = hour >= 12 ? 'PM' : 'AM';
      final h12 = hour % 12 == 0 ? 12 : hour % 12;
      return '$h12:${min.toString().padLeft(2, '0')} $ampm';
    } catch (_) {
      return timeStr;
    }
  }

  void _showRevokedAccessDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF1E1B29).withOpacity(0.8)
                  : Colors.white.withOpacity(0.8),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Theme.of(context).primaryColor.withOpacity(0.2),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.redAccent.withOpacity(0.12),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.redAccent.withOpacity(0.15),
                  ),
                  child: const Icon(
                    Icons.gpp_bad_rounded,
                    color: Colors.redAccent,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Access Terminated',
                  style: GoogleFonts.outfit(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.redAccent,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Administrator has revoked your permissions for this node. Returning to dashboard.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop(); // pop dialog
                    Navigator.of(context).pop(); // pop control screen
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 12,
                    ),
                  ),
                  child: Text(
                    'Return to Dashboard',
                    style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// === NEW: CUSTOM SYMMETRICAL FAN SVG PAINTER ===
class SpinningFan extends StatelessWidget {
  final Animation<double> animation;
  final Color color;

  const SpinningFan({super.key, required this.animation, required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        return Transform.rotate(angle: animation.value * 2 * pi, child: child);
      },
      child: CustomPaint(
        size: const Size(28, 28),
        painter: _FanPainter(color: color),
      ),
    );
  }
}

class _FanPainter extends CustomPainter {
  final Color color;

  _FanPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // Draw central hub ring
    canvas.drawCircle(center, radius * 0.25, paint);

    // Draw 3 blades symmetrically around center
    final path = Path();
    for (int i = 0; i < 3; i++) {
      final double startAngle = i * 2 * pi / 3;
      final double endAngle = startAngle + 0.55;

      path.moveTo(center.dx, center.dy);
      path.quadraticBezierTo(
        center.dx + radius * cos(endAngle),
        center.dy + radius * sin(endAngle),
        center.dx + radius * cos(startAngle),
        center.dy + radius * sin(startAngle),
      );
    }
    path.close();
    canvas.drawPath(path, paint);

    // Draw center pin
    final pinPaint = Paint()..color = Colors.white;
    canvas.drawCircle(center, radius * 0.08, pinPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// === NEW: DYNAMIC SENSOR DATA GRAPH REDRAWER ===
class _TelemetryChartPainter extends CustomPainter {
  final List<double> history;
  final Color color;

  _TelemetryChartPainter({required this.history, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withOpacity(0.3), color.withOpacity(0.0)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final path = Path();

    // Map history points to coordinates dynamically based on min/max bounds
    double minVal = history.reduce((a, b) => a < b ? a : b);
    double maxVal = history.reduce((a, b) => a > b ? a : b);
    if (maxVal == minVal) {
      maxVal += 1.0;
      minVal -= 1.0;
    }

    final double range = maxVal - minVal;
    final double stepX =
        size.width / (history.length > 1 ? history.length - 1 : 1);

    for (int i = 0; i < history.length; i++) {
      final double x = i * stepX;
      // Normalise and invert Y coordinates for chart drawing
      final double normY = (history[i] - minVal) / range;
      final double y =
          size.height - (normY * size.height * 0.7 + size.height * 0.15);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final fillPath = Path.from(path);
    fillPath.lineTo(size.width, size.height);
    fillPath.lineTo(0, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);

    // Draw grid lines
    final gridPaint = Paint()
      ..color = Colors.grey.withOpacity(0.1)
      ..strokeWidth = 1.0;

    for (int i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _TelemetryChartPainter oldDelegate) {
    // Force redraw whenever telemetry history values update!
    return oldDelegate.history != history ||
        oldDelegate.history.length != history.length;
  }
}

class GlassToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const GlassToggle({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;

    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        width: 50,
        height: 28,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: value
              ? primaryColor.withOpacity(0.35)
              : (isDark
                    ? Colors.white.withOpacity(0.08)
                    : Colors.black.withOpacity(0.05)),
          border: Border.all(
            color: value
                ? primaryColor.withOpacity(0.6)
                : (isDark
                      ? Colors.white.withOpacity(0.12)
                      : Colors.black.withOpacity(0.08)),
            width: 1.5,
          ),
        ),
        padding: const EdgeInsets.all(2),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: value
                ? primaryColor
                : (isDark ? Colors.white70 : Colors.black45),
            boxShadow: value
                ? [
                    BoxShadow(
                      color: primaryColor.withOpacity(0.4),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ]
                : [],
          ),
        ),
      ),
    );
  }
}
