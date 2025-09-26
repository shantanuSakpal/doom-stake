import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:usage_stats/usage_stats.dart';

void main() {
  runApp(const ScreenTimeApp());
}

class ScreenTimeApp extends StatelessWidget {
  const ScreenTimeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Screen Time Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const ScreenTimeHomePage(),
    );
  }
}

class ScreenTimeHomePage extends StatefulWidget {
  const ScreenTimeHomePage({super.key});

  @override
  State<ScreenTimeHomePage> createState() => _ScreenTimeHomePageState();
}

class _ScreenTimeHomePageState extends State<ScreenTimeHomePage>
    with WidgetsBindingObserver {
  bool _isLoading = false;
  bool _hasPermission = false;
  late DateTime _startDate;
  late DateTime _endDate;
  List<AppUsageInfo> _usageData = const [];
  String? _errorMessage;
  Timer? _refreshTimer;
  final Set<String> _trackedPackages = <String>{};
  final Map<String, AppInfo> _trackedAppInfo = <String, AppInfo>{};

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;
  bool get _isTrackingAll => _trackedPackages.isEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startDate = DateTime.now().subtract(const Duration(days: 1));
    _endDate = DateTime.now();
    _initUsageAccess();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _initUsageAccess();
    }
  }

  Future<void> _initUsageAccess() async {
    if (!_isAndroid) {
      setState(() {
        _hasPermission = false;
        _usageData = const [];
        _trackedAppInfo.clear();
      });
      return;
    }

    final permission = await UsageStats.checkUsagePermission();
    if (!mounted) {
      return;
    }

    final effectivePermission = permission ?? false;
    if (!effectivePermission) {
      _refreshTimer?.cancel();
      if (_hasPermission || _usageData.isNotEmpty) {
        setState(() {
          _hasPermission = false;
          _usageData = const [];
          _trackedAppInfo.clear();
        });
      }
      return;
    }

    if (!_hasPermission) {
      setState(() {
        _hasPermission = true;
      });
    }

    await _loadUsageStats();
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _loadUsageStats(),
    );
  }

  Future<void> _loadUsageStats() async {
    if (!_isAndroid || !_hasPermission) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final queryEnd = _endDate.add(const Duration(days: 1));
      final stats = await UsageStats.queryUsageStats(_startDate, queryEnd);

      final usageByPackage = <String, Duration>{};
      for (final usage in stats) {
        final packageName = usage.packageName;
        final totalTime = usage.totalTimeInForeground;
        if (packageName == null || totalTime == null) {
          continue;
        }

        final milliseconds = int.tryParse(totalTime);
        if (milliseconds == null || milliseconds <= 0) {
          continue;
        }

        usageByPackage[packageName] =
            (usageByPackage[packageName] ?? Duration.zero) +
            Duration(milliseconds: milliseconds);
      }

      final installedApps = await InstalledApps.getInstalledApps(true, true);

      if (!mounted) {
        return;
      }

      final appsByPackage = <String, AppInfo>{};
      for (final app in installedApps) {
        appsByPackage[app.packageName] = app;
      }

      if (_trackedPackages.isNotEmpty) {
        _trackedAppInfo
          ..clear()
          ..addEntries(
            appsByPackage.entries.where(
              (entry) => _trackedPackages.contains(entry.key),
            ),
          );
      } else {
        _trackedAppInfo.clear();
      }

      final results =
          usageByPackage.entries
              .where((entry) {
                if (_trackedPackages.isEmpty) {
                  return true;
                }
                return _trackedPackages.contains(entry.key);
              })
              .map((entry) {
                final app = appsByPackage[entry.key];
                final resolvedName = app?.name ?? entry.key;
                final icon = app?.icon;

                return AppUsageInfo(
                  packageName: entry.key,
                  totalTime: entry.value,
                  appName: resolvedName,
                  icon: icon,
                );
              })
              .toList()
            ..sort((a, b) => b.totalTime.compareTo(a.totalTime));

      setState(() {
        _usageData = results.take(50).toList(growable: false);
        _errorMessage = null;
      });
    } catch (error, stackTrace) {
      debugPrint('Failed to load usage stats: $error');
      debugPrint('$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _usageData = const [];
        _errorMessage = 'Unable to read usage data. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _selectDateRange() async {
    if (!_isAndroid) {
      return;
    }

    final pickedRange = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
    );

    if (pickedRange == null) {
      return;
    }

    setState(() {
      _startDate = pickedRange.start;
      _endDate = pickedRange.end;
    });

    await _loadUsageStats();
  }

  Future<void> _openUsageSettings() async {
    if (!_isAndroid) {
      return;
    }

    await UsageStats.grantUsagePermission();
    await _initUsageAccess();
  }

  Future<void> _openAppSelection() async {
    if (!_isAndroid) {
      return;
    }

    try {
      final apps = await InstalledApps.getInstalledApps(true, true);
      if (!mounted) {
        return;
      }

      apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      final result = await showModalBottomSheet<Set<String>>(
        context: context,
        isScrollControlled: true,
        builder: (context) {
          return _AppSelectionSheet(
            apps: apps,
            initiallySelected: _trackedPackages,
          );
        },
      );

      if (result == null) {
        return;
      }

      setState(() {
        _trackedPackages
          ..clear()
          ..addAll(result);
        if (_trackedPackages.isNotEmpty) {
          _trackedAppInfo
            ..clear()
            ..addEntries(
              apps
                  .where((app) => _trackedPackages.contains(app.packageName))
                  .map((app) => MapEntry(app.packageName, app)),
            );
        } else {
          _trackedAppInfo.clear();
        }
      });

      await _loadUsageStats();
    } catch (error, stackTrace) {
      debugPrint('Failed to open app selector: $error');
      debugPrint('$stackTrace');
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to load installed apps. Please try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAndroid) {
      return Scaffold(
        appBar: AppBar(title: const Text('Screen Time Tracker')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Screen time monitoring is only available on Android devices.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Screen Time Tracker'),
        actions: [
          IconButton(
            onPressed: _isLoading || !_hasPermission
                ? null
                : () => _loadUsageStats(),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh stats',
          ),
          IconButton(
            onPressed: _selectDateRange,
            icon: const Icon(Icons.calendar_today),
            tooltip: 'Select date range',
          ),
          PopupMenuButton<_OverflowAction>(
            onSelected: (action) {
              switch (action) {
                case _OverflowAction.manageTrackedApps:
                  _openAppSelection();
                  break;
                case _OverflowAction.trackAll:
                  setState(() {
                    _trackedPackages.clear();
                    _trackedAppInfo.clear();
                  });
                  _loadUsageStats();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem<_OverflowAction>(
                value: _OverflowAction.manageTrackedApps,
                child: ListTile(
                  leading: Icon(Icons.playlist_add),
                  title: Text('Add apps to track'),
                ),
              ),
              PopupMenuItem<_OverflowAction>(
                value: _OverflowAction.trackAll,
                enabled: !_isTrackingAll,
                child: const ListTile(
                  leading: Icon(Icons.select_all),
                  title: Text('Track all apps'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DateRangeSummary(startDate: _startDate, endDate: _endDate),
            const SizedBox(height: 12),
            Expanded(child: _buildUsageContent()),
          ],
        ),
      ),
      floatingActionButton: _hasPermission
          ? FloatingActionButton.extended(
              onPressed: _isLoading ? null : () => _loadUsageStats(),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            )
          : FloatingActionButton.extended(
              onPressed: _openUsageSettings,
              icon: const Icon(Icons.settings),
              label: const Text('Grant Access'),
            ),
    );
  }

  Widget _buildUsageContent() {
    if (!_hasPermission) {
      return Center(
        child: _PermissionBanner(onGrantPermission: _openUsageSettings),
      );
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_errorMessage!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _loadUsageStats(),
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }

    final listView = Expanded(
      child: _usageData.isEmpty
          ? Center(
              child: Text(
                _isTrackingAll
                    ? 'No usage data available for the selected period.'
                    : 'None of the tracked apps have usage in this period.',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.separated(
              itemCount: _usageData.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final info = _usageData[index];
                return _AppUsageTile(info: info);
              },
            ),
    );

    return Column(
      children: [
        if (!_isTrackingAll && _trackedPackages.isNotEmpty) ...[
          _TrackedAppsBanner(
            count: _trackedPackages.length,
            appNames: _trackedPackages
                .map((pkg) => _trackedAppInfo[pkg]?.name ?? pkg)
                .toList(growable: false),
            onClear: () {
              setState(() {
                _trackedPackages.clear();
                _trackedAppInfo.clear();
              });
              _loadUsageStats();
            },
            onManage: _openAppSelection,
          ),
          const SizedBox(height: 12),
        ],
        listView,
      ],
    );
  }
}

class AppUsageInfo {
  AppUsageInfo({
    required this.packageName,
    required this.totalTime,
    this.appName,
    this.icon,
  });

  final String packageName;
  final Duration totalTime;
  final String? appName;
  final Uint8List? icon;

  AppUsageInfo copyWith({String? appName, Uint8List? icon}) {
    return AppUsageInfo(
      packageName: packageName,
      totalTime: totalTime,
      appName: appName ?? this.appName,
      icon: icon ?? this.icon,
    );
  }
}

class _AppUsageTile extends StatelessWidget {
  const _AppUsageTile({required this.info});

  final AppUsageInfo info;

  @override
  Widget build(BuildContext context) {
    final formattedDuration = _formatDuration(info.totalTime);
    return ListTile(
      leading: info.icon != null
          ? CircleAvatar(backgroundImage: MemoryImage(info.icon!))
          : CircleAvatar(
              child: Text(
                info.appName != null && info.appName!.isNotEmpty
                    ? info.appName![0].toUpperCase()
                    : '?',
              ),
            ),
      title: Text(info.appName ?? info.packageName),
      subtitle: Text(info.packageName),
      trailing: Text(formattedDuration),
    );
  }
}

class _DateRangeSummary extends StatelessWidget {
  const _DateRangeSummary({required this.startDate, required this.endDate});

  final DateTime startDate;
  final DateTime endDate;

  @override
  Widget build(BuildContext context) {
    final formatter = DateFormat('MMM d, yyyy');
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Tracking window',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '${formatter.format(startDate)} - ${formatter.format(endDate)}',
                ),
              ],
            ),
            const Icon(Icons.calendar_month),
          ],
        ),
      ),
    );
  }
}

class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner({required this.onGrantPermission});

  final VoidCallback onGrantPermission;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.orange.shade100,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Usage Access Needed',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'To display your screen time, allow this app to access usage data. '
              'This permission is required to read app activity statistics.',
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: onGrantPermission,
                icon: const Icon(Icons.settings),
                label: const Text('Grant access'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackedAppsBanner extends StatelessWidget {
  const _TrackedAppsBanner({
    required this.count,
    required this.appNames,
    required this.onClear,
    required this.onManage,
  });

  final int count;
  final List<String> appNames;
  final VoidCallback onClear;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final displayNames = appNames.take(3).join(', ');
    final remaining = count - appNames.take(3).length;

    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tracking $count app${count == 1 ? '' : 's'}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              remaining > 0 ? '$displayNames +$remaining more' : displayNames,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: onManage,
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Manage'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: onClear,
                  icon: const Icon(Icons.clear),
                  label: const Text('Clear'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AppSelectionSheet extends StatefulWidget {
  const _AppSelectionSheet({
    required this.apps,
    required this.initiallySelected,
  });

  final List<AppInfo> apps;
  final Set<String> initiallySelected;

  @override
  State<_AppSelectionSheet> createState() => _AppSelectionSheetState();
}

class _AppSelectionSheetState extends State<_AppSelectionSheet> {
  late final Set<String> _selectedPackages;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _selectedPackages = Set<String>.from(widget.initiallySelected);
  }

  @override
  Widget build(BuildContext context) {
    final filteredApps = widget.apps.where((app) {
      if (_filter.isEmpty) {
        return true;
      }
      final query = _filter.toLowerCase();
      return app.name.toLowerCase().contains(query) ||
          app.packageName.toLowerCase().contains(query);
    }).toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Select apps to track',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _selectedPackages.clear();
                      });
                    },
                    child: const Text('Clear all'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search apps…',
                ),
                onChanged: (value) {
                  setState(() {
                    _filter = value;
                  });
                },
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: filteredApps.length,
                itemBuilder: (context, index) {
                  final app = filteredApps[index];
                  final isSelected = _selectedPackages.contains(
                    app.packageName,
                  );
                  return CheckboxListTile(
                    value: isSelected,
                    onChanged: (selected) {
                      setState(() {
                        if (selected == true) {
                          _selectedPackages.add(app.packageName);
                        } else {
                          _selectedPackages.remove(app.packageName);
                        }
                      });
                    },
                    title: Text(app.name),
                    subtitle: Text(app.packageName),
                    secondary: app.icon != null
                        ? CircleAvatar(backgroundImage: MemoryImage(app.icon!))
                        : const CircleAvatar(child: Icon(Icons.apps)),
                    controlAffinity: ListTileControlAffinity.leading,
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () =>
                          Navigator.of(context).pop(_selectedPackages),
                      child: const Text('Apply'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _OverflowAction { manageTrackedApps, trackAll }

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);

  if (hours > 0) {
    return '${hours}h ${minutes}m';
  }
  if (minutes > 0) {
    return '${minutes}m ${seconds}s';
  }
  return '${seconds}s';
}
