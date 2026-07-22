import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../dashboard/data/nodes_provider.dart';
import '../../../core/widgets/custom_toast.dart';
import '../../../core/widgets/app_background.dart';

class BulkRulesScreen extends ConsumerStatefulWidget {
  const BulkRulesScreen({super.key});

  @override
  ConsumerState<BulkRulesScreen> createState() => _BulkRulesScreenState();
}

class _BulkRulesScreenState extends ConsumerState<BulkRulesScreen> {
  final _formKey = GlobalKey<FormState>();
  final ScrollController _scrollController = ScrollController();
  bool _isScrolled = false;

  String _selectedSensor = 'Temperature';
  String _selectedOperator = 'ABOVE'; // ABOVE or UNDER
  final TextEditingController _thresholdController = TextEditingController(
    text: '30.0',
  );
  double _hysteresis = 1.0; // Default hysteresis: 1.0

  // Mapped action state: Turn ON all loads / Turn OFF all loads
  bool _turnOnAction = true;

  List<Map<String, dynamic>> _bulkRules = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadBulkRules();
  }

  void _onScroll() {
    final scrolled = _scrollController.offset > 10;
    if (scrolled != _isScrolled) {
      setState(() => _isScrolled = scrolled);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _thresholdController.dispose();
    super.dispose();
  }

  void _loadBulkRules() async {
    final box = await Hive.openBox('bulk_rules');
    final List<Map<String, dynamic>> rules = [];
    for (var key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        rules.add(Map<String, dynamic>.from(val));
      }
    }
    setState(() {
      _bulkRules = rules;
      _isLoading = false;
    });
  }

  void _createBulkRule() async {
    if (_formKey.currentState?.validate() ?? false) {
      final nodes = ref.read(nodesProvider);
      if (nodes.isEmpty) return;

      final bulkBox = await Hive.openBox('bulk_rules');
      final rulesBox = await Hive.openBox('rules');

      final bulkId = 'bulk_${DateTime.now().millisecondsSinceEpoch}';
      final List<String> childRuleIds = [];

      final double threshold = double.parse(_thresholdController.text);

      // Generate individual rules for each node as requested
      for (var node in nodes) {
        final nodeName = node['name'] as String;
        final List loads = node['loads'] as List;
        if (loads.isEmpty) continue;

        final List<String> loadNames = loads
            .map((l) => l['name'] as String)
            .toList();
        final childRuleId = 'child_${bulkId}_${nodeName.hashCode}';
        childRuleIds.add(childRuleId);

        // Save individual rule for node
        final childRule = {
          'id': childRuleId,
          'nodeName': nodeName,
          'loads': loadNames,
          'sensor': _selectedSensor,
          'operator': _selectedOperator,
          'threshold': threshold,
          'hysteresis': _hysteresis, // Hysteresis from slider
          'isBulkChild': true,
        };
        await rulesBox.put(childRuleId, childRule);
      }

      // Save bulk rule structure
      final bulkRule = {
        'id': bulkId,
        'sensor': _selectedSensor,
        'operator': _selectedOperator,
        'threshold': threshold,
        'hysteresis': _hysteresis, // Save hysteresis
        'actionOn': _turnOnAction,
        'childRuleIds': childRuleIds,
      };
      await bulkBox.put(bulkId, bulkRule);

      GlassToast.show(
        context,
        icon: const Icon(Icons.check_circle_outline, color: Colors.green),
        color: Colors.green,
        message:
            'Bulk rule generated ${childRuleIds.length} sub-rules across nodes.',
        behave: ToastBehavior.success,
      );

      _loadBulkRules();
    }
  }

  void _deleteBulkRule(String bulkId, List<dynamic> childIds) async {
    final bulkBox = await Hive.openBox('bulk_rules');
    final rulesBox = await Hive.openBox('rules');

    // Delete bulk rule
    await bulkBox.delete(bulkId);

    // Delete generated individual node rules
    for (var childId in childIds) {
      if (childId is String) {
        await rulesBox.delete(childId);
      }
    }

    GlassToast.show(
      context,
      icon: const Icon(Icons.delete_sweep_outlined, color: Colors.redAccent),
      color: Colors.redAccent,
      message: 'Bulk Rule and sub-rules removed.',
      behave: ToastBehavior.success,
    );

    _loadBulkRules();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: Text(
          'Global Automations',
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isLarge = constraints.maxWidth > 700;
                  return Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: isLarge
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 4,
                                child: _buildForm(theme, isDark),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                flex: 5,
                                child: _buildRulesList(theme, isDark),
                              ),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildForm(theme, isDark),
                              const SizedBox(height: 16),
                              _buildRulesList(theme, isDark),
                            ],
                          ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(ThemeData theme, bool isDark) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Form(
        key: _formKey,
        child: Container(
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
                padding: const EdgeInsets.all(20.0),
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
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Create Global Rule',
                      style: GoogleFonts.outfit(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Generated sub-rules will deploy individually to all connected hardware node channels.',
                      style: GoogleFonts.inter(
                        color: Colors.grey,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Select Sensor
                    DropdownButtonFormField<String>(
                      value: _selectedSensor,
                      decoration: const InputDecoration(
                        labelText: 'Sensor Channel Type',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'Temperature',
                          child: Text('Temperature'),
                        ),
                        DropdownMenuItem(
                          value: 'Humidity',
                          child: Text('Humidity'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) setState(() => _selectedSensor = val);
                      },
                    ),
                    const SizedBox(height: 16),

                    // Condition
                    DropdownButtonFormField<String>(
                      value: _selectedOperator,
                      decoration: const InputDecoration(
                        labelText: 'Evaluation Operator',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'ABOVE',
                          child: Text('When value is ABOVE'),
                        ),
                        DropdownMenuItem(
                          value: 'UNDER',
                          child: Text('When value is UNDER'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _selectedOperator = val);
                        }
                      },
                    ),
                    const SizedBox(height: 16),

                    // Threshold Input
                    TextFormField(
                      controller: _thresholdController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Threshold Limit Value',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Enter threshold value';
                        }
                        if (double.tryParse(value) == null) {
                          return 'Enter a valid decimal number';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Hysteresis Deadband',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white70 : Colors.black87,
                              ),
                            ),
                            Text(
                              '±${_hysteresis.toStringAsFixed(1)}',
                              style: GoogleFonts.outfit(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: theme.primaryColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Prevent rapid load toggles (relay chatter) near the threshold.',
                          style: GoogleFonts.inter(
                            color: Colors.grey,
                            fontSize: 11,
                          ),
                        ),
                        Slider(
                          value: _hysteresis,
                          min: 0.5,
                          max: 2.0,
                          divisions: 15,
                          label: '±${_hysteresis.toStringAsFixed(1)}',
                          onChanged: (val) {
                            setState(() => _hysteresis = val);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Action Selector
                    DropdownButtonFormField<bool>(
                      value: _turnOnAction,
                      decoration: const InputDecoration(
                        labelText: 'Action Output State',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: true,
                          child: Text('Turn ON all node loads'),
                        ),
                        DropdownMenuItem(
                          value: false,
                          child: Text('Turn OFF all node loads'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) setState(() => _turnOnAction = val);
                      },
                    ),
                    const SizedBox(height: 24),

                    ElevatedButton(
                      onPressed: _createBulkRule,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        'Deploy Bulk Automation',
                        style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRulesList(ThemeData theme, bool isDark) {
    if (_isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Running Global Rules',
            style: GoogleFonts.outfit(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          const SizedBox(height: 12),
          if (_bulkRules.isEmpty)
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Container(
                    padding: const EdgeInsets.all(24.0),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withOpacity(0.06)
                          : Colors.black.withOpacity(0.03),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withOpacity(0.1)
                            : Colors.black.withOpacity(0.06),
                        width: 1.5,
                      ),
                    ),
                    child: Text(
                      'No global rules running.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(color: Colors.grey),
                    ),
                  ),
                ),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _bulkRules.length,
              itemBuilder: (context, index) {
                final rule = _bulkRules[index];
                final childIds = rule['childRuleIds'] as List;
                final double hysteresisVal = (rule['hysteresis'] ?? 1.0)
                    .toDouble();
                final conditionText =
                    'If ${rule['sensor']} is ${rule['operator']} ${rule['threshold']} (±${hysteresisVal.toStringAsFixed(1)})';
                final actionText = rule['actionOn']
                    ? 'Turn ON all node loads'
                    : 'Turn OFF all node loads';

                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withOpacity(0.06)
                              : Colors.black.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isDark
                                ? Colors.white.withOpacity(0.1)
                                : Colors.black.withOpacity(0.06),
                            width: 1.5,
                          ),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(16),
                          leading: CircleAvatar(
                            backgroundColor: theme.primaryColor.withOpacity(
                              0.15,
                            ),
                            child: Icon(
                              Icons.playlist_add_check_rounded,
                              color: theme.primaryColor,
                            ),
                          ),
                          title: Text(
                            conditionText,
                            style: GoogleFonts.outfit(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text(
                                actionText,
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  color: theme.primaryColor,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Deployed sub-rules: ${childIds.length} nodes',
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.redAccent,
                            ),
                            onPressed: () =>
                                _deleteBulkRule(rule['id'], childIds),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
