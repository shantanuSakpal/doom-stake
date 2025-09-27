import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:usage_stats/usage_stats.dart';
import 'package:http/http.dart' as http;
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:system_alert_window/system_alert_window.dart';

@pragma("vm:entry-point")
void overlayMain() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        color: Colors.black54,
        child: Center(
          child: Text(
            'App Blocked\nTouch grass to unlock 🌿',
            style: TextStyle(color: Colors.white, fontSize: 20),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Listen for clicks from overlay buttons
  SystemAlertWindow.overlayListener.listen((event) async {
    if (event == "close_overlay") {
      await SystemAlertWindow.closeSystemWindow();
    }
  });

  runApp(const ScreenTimeApp());
}

class ScreenTimeApp extends StatelessWidget {
  const ScreenTimeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Touch Grass',
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
  Timer? _usageRefreshTimer;
  Timer? _eventMonitorTimer;
  DateTime? _lastEventPollTime;
  final List<BlockedAppEntry> _blockedEntries = <BlockedAppEntry>[];
  final Map<String, DailyLimitEntry> _dailyLimits = {};
  final ImagePicker _imagePicker = ImagePicker();
  bool _showingOverlay = false;

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  Future<void> _requestOverlayPermission() async {
    await SystemAlertWindow.requestPermissions(
      prefMode: SystemWindowPrefMode.OVERLAY,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startDate = DateTime.now().subtract(const Duration(days: 1));
    _endDate = DateTime.now();
    _resetDailyLimitsIfNeeded();

    // Request overlay permission when app starts
    _requestOverlayPermission();

    _initUsageAccess();
  }

  Future<void> _handleTouchGrassRequest() async {
    if (!_isAndroid) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Camera unlock works only on Android for now.'),
        ),
      );
      return;
    }

    if (_dailyLimits.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set some app limits first!')),
      );
      return;
    }

    try {
      final blockedEntries = _dailyLimits.values
          .where((entry) => entry.isBlocked)
          .toList();

      if (blockedEntries.isEmpty) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You have no blocked apps right now.')),
        );
        return;
      }

      final photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
      );
      if (photo == null) {
        return;
      }

      var loaderVisible = false;
      _UploadResult uploadResult = const _UploadResult(uploaded: false);

      if (mounted) {
        loaderVisible = true;
        _showBlockingLoader('Analyzing your photo...');
      }

      try {
        uploadResult = await _uploadPhoto(photo);
      } finally {
        if (loaderVisible && mounted) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      }

      if (!mounted) {
        return;
      }

      if (uploadResult.approved) {
        setState(() {
          for (final entry in blockedEntries) {
            entry.extendLimit(const Duration(minutes: 1));
          }
        });

        await _checkDailyLimits(DateTime.now());

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Good job, fresh air feels nice dosen\'t it?. Limits extended by 1 minute.',
            ),
          ),
        );
      } else if (uploadResult.uploaded && uploadResult.modelApproved == false) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Get your butt out bro. You still need to touch grass.',
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not verify your photo. Please try again.'),
          ),
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to access camera: $error')),
      );
    }
  }

  void _showBlockingLoader(String message) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _LoadingDialog(message: message),
    );
  }

  Future<_UploadResult> _uploadPhoto(XFile photo) async {
    final uri = Uri.parse('https://6bc2a30c273e.ngrok-free.app/upload-image');
    try {
      final request = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath('image', photo.path));

      final response = await request.send();
      final body = await response.stream.bytesToString();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        debugPrint('Image upload successful: $body');

        bool? modelApproved;
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) {
            final fileUrl = decoded['fileUrl'];
            if (fileUrl != null) {
              debugPrint('File URL: $fileUrl');
            }
            final modelResponse = decoded['modelResponse'];
            if (modelResponse is bool) {
              modelApproved = modelResponse;
            } else if (modelResponse is String) {
              modelApproved = modelResponse.toLowerCase() == 'true';
            }
          }
        } catch (error) {
          debugPrint('Failed to parse upload response: $error');
        }

        return _UploadResult(uploaded: true, modelApproved: modelApproved);
      }

      debugPrint('Image upload failed: ${response.statusCode} -> $body');
    } catch (error, stackTrace) {
      debugPrint('Image upload error: $error');
      debugPrint('$stackTrace');
    }
    return const _UploadResult(uploaded: false);
  }

  Future<void> _bringAppToFront() async {
    const packageName = 'com.example.touch_grass';
    debugPrint('[BringAppToFront] Trying to launch $packageName');

    try {
      // final intent = AndroidIntent(
      //   action: 'android.intent.action.MAIN',
      //   category: 'android.intent.category.LAUNCHER',
      //   package: packageName,
      //   flags: <int>[
      //     Flag.FLAG_ACTIVITY_NEW_TASK,
      //     Flag.FLAG_ACTIVITY_REORDER_TO_FRONT,
      //   ],
      // );
      // await intent.launch();
      // debugPrint('[BringAppToFront] Relaunched app successfully');
      // Fallback to home screen if the system shows a popup
      final homeIntent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        category: 'android.intent.category.HOME',
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      await homeIntent.launch();
    } catch (e) {
      debugPrint('[BringAppToFront] Launch failed ($e), sending HOME intent');
      // Fallback to home screen if the system shows a popup
      final homeIntent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        category: 'android.intent.category.HOME',
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      await homeIntent.launch();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _usageRefreshTimer?.cancel();
    _eventMonitorTimer?.cancel();
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
      });
      return;
    }

    final permission = await UsageStats.checkUsagePermission();
    if (!mounted) {
      return;
    }

    final hasPermission = permission ?? false;
    if (!hasPermission) {
      _usageRefreshTimer?.cancel();
      _eventMonitorTimer?.cancel();
      setState(() {
        _hasPermission = false;
        _usageData = const [];
      });
      return;
    }

    if (!_hasPermission) {
      setState(() {
        _hasPermission = true;
      });
    }

    await _loadUsageStats();
    _startUsageRefreshTimer();
    _startEventMonitor();
  }

  void _startUsageRefreshTimer() {
    _usageRefreshTimer?.cancel();
    _usageRefreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _loadUsageStats();
      _checkDailyLimits(DateTime.now());
    });
  }

  void _startEventMonitor() {
    if (!_isAndroid || !_hasPermission) {
      return;
    }
    if (_eventMonitorTimer != null) {
      return;
    }
    _lastEventPollTime ??= DateTime.now().subtract(const Duration(minutes: 2));
    _eventMonitorTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkBlockedViolations(),
    );
  }

  void _stopEventMonitorIfIdle() {
    if (_blockedEntries.isEmpty && _dailyLimits.isEmpty) {
      _eventMonitorTimer?.cancel();
      _eventMonitorTimer = null;
    }
  }

  Future<void> _loadUsageStats() async {
    if (!_isAndroid || !_hasPermission) {
      return;
    }

    setState(() {
      _isLoading = true;
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

      final appsByPackage = <String, AppInfo>{
        for (final app in installedApps) app.packageName: app,
      };

      final results = usageByPackage.entries.map((entry) {
        final app = appsByPackage[entry.key];
        final resolvedName = app?.name ?? entry.key;
        return AppUsageInfo(
          packageName: entry.key,
          totalTime: entry.value,
          appName: resolvedName,
          icon: app?.icon,
        );
      }).toList()..sort((a, b) => b.totalTime.compareTo(a.totalTime));

      setState(() {
        _usageData = results.take(50).toList(growable: false);
      });
    } catch (error, stackTrace) {
      debugPrint('Failed to load usage stats: $error');
      debugPrint('$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _usageData = const [];
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _checkBlockedViolations() async {
    if (!_hasPermission || (_blockedEntries.isEmpty && _dailyLimits.isEmpty)) {
      _stopEventMonitorIfIdle();
      return;
    }

    final now = DateTime.now();
    _lastEventPollTime ??= now.subtract(const Duration(minutes: 2));
    final start = _lastEventPollTime!;
    final end = now;
    _lastEventPollTime = end;

    try {
      final events = await UsageStats.queryEvents(start, end);
      debugPrint(
        '[EventMonitor] Polled ${events.length} events from $start to $end',
      );

      // Build a merged list of all blocked apps
      final Map<String, String> blockedApps = {};

      // Add stake blocks
      for (final e in _blockedEntries) {
        if (e.blockedUntil.isAfter(now)) {
          blockedApps[e.packageName] = e.appName;
        }
      }

      // Add daily limit blocks
      _dailyLimits.forEach((pkg, entry) {
        if (entry.isBlocked) {
          blockedApps[pkg] = entry.appName;
        }
      });

      debugPrint('[BlockedApps] Currently blocked apps: $blockedApps');

      // Detect if a blocked app was opened
      for (final event in events) {
        final type = event.eventType?.toString() ?? '';
        final pkg = event.packageName ?? '';

        final isForegroundEvent =
            type == '1' ||
            type == 'MOVE_TO_FOREGROUND' ||
            type == 'ACTIVITY_RESUMED';
        if (isForegroundEvent && blockedApps.containsKey(pkg)) {
          final appName = blockedApps[pkg];
          debugPrint(
            '[BlockDetect] Blocked app opened: $appName ($pkg) | type=$type',
          );

          // Action when blocked app is opened
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$appName is blocked! Touch grass 🌿')),
          );

          // Optional: bring this app (touch_grass) back to foreground
          await _bringAppToFront();

          // Optional: short delay to avoid multiple triggers
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      await _checkDailyLimits(now);
    } catch (error, stackTrace) {
      debugPrint('[EventMonitor] Failed to monitor blocked apps: $error');
      debugPrint('$stackTrace');
    }
  }

  void _resetDailyLimitsIfNeeded() {
    final today = DateTime.now();
    _dailyLimits.removeWhere((_, entry) => !_isSameDay(entry.day, today));
  }

  Future<void> _checkDailyLimits(DateTime now) async {
    if (_dailyLimits.isEmpty) {
      return;
    }

    for (final entry in _dailyLimits.values) {
      if (!_isSameDay(entry.day, now)) {
        entry.resetForDay(now);
      }
    }

    final startOfDay = DateTime(now.year, now.month, now.day);
    final stats = await UsageStats.queryUsageStats(startOfDay, now);
    final totals = <String, Duration>{};

    for (final info in stats) {
      final package = info.packageName;
      final totalForeground = info.totalTimeInForeground;
      if (package == null || totalForeground == null) {
        continue;
      }

      final millis = int.tryParse(totalForeground);
      if (millis == null || millis <= 0) {
        continue;
      }

      totals[package] =
          (totals[package] ?? Duration.zero) + Duration(milliseconds: millis);
    }

    if (totals.isEmpty) {
      return;
    }

    // debugPrint(
    //   'Daily limit usage snapshot: ${totals.map((k, v) => MapEntry(k, v.inSeconds))}',
    // );

    bool updated = false;
    final newlyBlocked = <DailyLimitEntry>[];

    for (final entry in _dailyLimits.values) {
      final usage = totals[entry.packageName] ?? Duration.zero;
      final clamped = usage > entry.limit ? entry.limit : usage;
      final wasBlocked = entry.isBlocked;

      if (entry.accumulated != clamped ||
          wasBlocked != (usage >= entry.limit)) {
        entry.accumulated = clamped;
        entry.isBlocked = usage >= entry.limit;
        updated = true;

        debugPrint(
          'Daily limit update: ${entry.appName} -> '
          '${entry.accumulated.inSeconds}s/${entry.limit.inSeconds}s '
          '(blocked=${entry.isBlocked})',
        );

        if (!wasBlocked && entry.isBlocked) {
          newlyBlocked.add(entry);
        }
      }
    }

    if (updated && mounted) {
      setState(() {});
    }

    for (final entry in newlyBlocked) {
      if (!mounted) {
        break;
      }
      await _showDailyLimitOverlay(entry);
    }
  }

  Future<void> _showDailyLimitOverlay(DailyLimitEntry entry) async {
    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('Daily limit reached'),
          content: Text(
            '${entry.appName} has exceeded the daily limit of '
            '${_formatDuration(entry.limit)}. The app is blocked for today.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
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

  Future<void> _showStakeDialog() async {
    if (!_hasPermission) {
      await _openUsageSettings();
      return;
    }

    final apps = await InstalledApps.getInstalledApps(true, true);
    if (!mounted) {
      return;
    }
    apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final durationController = TextEditingController(text: '60');
    final amountController = TextEditingController(text: '1');
    Set<String> selectedPackages = <String>{};
    String? errorMessage;

    final request = await showDialog<_StakeRequest>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final selectedApps = apps
                .where((app) => selectedPackages.contains(app.packageName))
                .toList();
            return AlertDialog(
              title: const Text('Stake & Block'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Stake USD to block apps for a set duration.'),
                    const SizedBox(height: 12),
                    TextField(
                      controller: durationController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Block duration (minutes)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Stake amount (USD)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        final result = await showModalBottomSheet<Set<String>>(
                          context: context,
                          isScrollControlled: true,
                          builder: (context) => _AppSelectionSheet(
                            apps: apps,
                            initiallySelected: selectedPackages,
                            usageLookup: {
                              for (final app in apps)
                                app.packageName: _usageData.firstWhere(
                                  (usage) =>
                                      usage.packageName == app.packageName,
                                  orElse: () => AppUsageInfo(
                                    packageName: app.packageName,
                                    totalTime: Duration.zero,
                                    appName: app.name,
                                    icon: app.icon,
                                  ),
                                ),
                            },
                          ),
                        );
                        if (result != null) {
                          setState(() {
                            selectedPackages = result;
                            errorMessage = null;
                          });
                        }
                      },
                      icon: const Icon(Icons.playlist_add),
                      label: const Text('Select apps to block'),
                    ),
                    const SizedBox(height: 12),
                    if (selectedApps.isEmpty)
                      const Text(
                        'No apps selected yet.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    if (selectedApps.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: selectedApps
                            .map((app) => Chip(label: Text(app.name)))
                            .toList(),
                      ),
                    if (errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        errorMessage!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final durationMinutes = int.tryParse(
                      durationController.text.trim(),
                    );
                    final amount = double.tryParse(
                      amountController.text.trim(),
                    );
                    if (durationMinutes == null || durationMinutes <= 0) {
                      setState(() {
                        errorMessage = 'Enter a valid duration (minutes).';
                      });
                      return;
                    }
                    if (amount == null || amount <= 0) {
                      setState(() {
                        errorMessage = 'Enter a valid stake amount.';
                      });
                      return;
                    }
                    if (selectedPackages.isEmpty) {
                      setState(() {
                        errorMessage = 'Select at least one app to block.';
                      });
                      return;
                    }

                    final chosenApps = apps
                        .where(
                          (app) => selectedPackages.contains(app.packageName),
                        )
                        .toList(growable: false);
                    Navigator.of(context).pop(
                      _StakeRequest(
                        duration: Duration(minutes: durationMinutes),
                        amountUsd: amount,
                        selectedApps: chosenApps,
                      ),
                    );
                  },
                  child: const Text('Stake & Block'),
                ),
              ],
            );
          },
        );
      },
    );

    durationController.dispose();
    amountController.dispose();

    if (request == null) {
      return;
    }

    _handleStakeRequest(request);
  }

  void _handleStakeRequest(_StakeRequest request) {
    final blockedUntil = DateTime.now().add(request.duration);
    final appNames = request.selectedApps.map((app) => app.name).join(', ');
    debugPrint(
      'Stake function called: amount=${request.amountUsd} USD, '
      'duration=${request.duration.inMinutes} minutes, apps=[$appNames]',
    );

    setState(() {
      for (final app in request.selectedApps) {
        _blockedEntries.removeWhere(
          (entry) => entry.packageName == app.packageName,
        );
        _blockedEntries.add(
          BlockedAppEntry(
            packageName: app.packageName,
            appName: app.name,
            blockedUntil: blockedUntil,
            stakeAmount: request.amountUsd,
            icon: app.icon,
          ),
        );
      }
    });

    _startEventMonitor();
  }

  Widget _buildUsageContent() {
    if (!_hasPermission) {
      return _PermissionBanner(onGrantPermission: _openUsageSettings);
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_usageData.isEmpty) {
      return const Center(
        child: Text('No usage data available for the selected range.'),
      );
    }

    return ListView.separated(
      itemCount: _usageData.length,
      separatorBuilder: (_, __) => const Divider(),
      itemBuilder: (context, index) {
        final usage = _usageData[index];
        return ListTile(
          leading: usage.icon != null
              ? CircleAvatar(backgroundImage: MemoryImage(usage.icon!))
              : const CircleAvatar(child: Icon(Icons.apps)),
          title: Text(usage.appName ?? usage.packageName),
          subtitle: Text('Usage: ${_formatDuration(usage.totalTime)}'),
        );
      },
    );
  }

  List<BlockedAppEntry> _activeBlocks() {
    final now = DateTime.now();
    final expired = <BlockedAppEntry>[];
    final active = <BlockedAppEntry>[];

    for (final entry in _blockedEntries) {
      if (entry.blockedUntil.isAfter(now)) {
        active.add(entry);
      } else {
        expired.add(entry);
      }
    }

    if (expired.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        setState(() {
          _blockedEntries.removeWhere(expired.contains);
        });
        _stopEventMonitorIfIdle();
      });
    }

    return active;
  }

  Widget _buildStakePanel() {
    final activeBlocks = _activeBlocks();
    final rangeLabel = '${_formatDate(_startDate)} - ${_formatDate(_endDate)}';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Stake & Block',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Stake USD to block distracting apps for a custom time period.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _showStakeDialog,
              icon: const Icon(Icons.shield),
              label: const Text('Stake & Block'),
            ),
            const SizedBox(height: 12),
            Text(
              'Usage window: $rangeLabel',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (activeBlocks.isEmpty) const Text('No active blocks yet.'),
            if (activeBlocks.isNotEmpty) ...[
              const Text('Active blocks:'),
              const SizedBox(height: 8),
              for (final entry in activeBlocks)
                _ActiveBlockTile(
                  entry: entry,
                  onRemove: () {
                    setState(() {
                      _blockedEntries.remove(entry);
                    });
                    _stopEventMonitorIfIdle();
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLimitsPanel() {
    final entries = _dailyLimits.values.toList()
      ..sort((a, b) => a.appName.compareTo(b.appName));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Stop the doom',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Set a 1-minute limit for apps. Once crossed, the app is blocked for the day. To unlock, touch grass, literally!',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _showUsageLimitDialog,
              icon: const Icon(Icons.dangerous),
              label: const Text('Block em all!'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _handleTouchGrassRequest,
              child: const Text('1 more minute pleaseeee!!'),
            ),
            const SizedBox(height: 12),
            if (entries.isEmpty)
              const Text('No daily limits yet.')
            else ...[
              for (final entry in entries)
                _DailyLimitTile(
                  entry: entry,
                  onRemove: () => _removeDailyLimit(entry.packageName),
                ),
              const SizedBox(height: 12),
              Text(
                'Current time limits',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final entry in entries)
                      Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceVariant,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          '${entry.appName}: ${_formatDuration(entry.limit)}',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showUsageLimitDialog() async {
    final apps = await InstalledApps.getInstalledApps(true, true);
    if (!mounted) {
      return;
    }
    apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final usageSnapshot = {
      for (final entry in _usageData) entry.packageName: entry,
    };

    final selected = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AppSelectionSheet(
        apps: apps,
        initiallySelected: _dailyLimits.keys.toSet(),
        usageLookup: usageSnapshot,
      ),
    );

    if (selected == null || selected.isEmpty) {
      return;
    }

    final today = DateTime.now();
    final newLimits = <String, DailyLimitEntry>{};
    for (final app in apps) {
      if (!selected.contains(app.packageName)) {
        continue;
      }
      newLimits[app.packageName] = DailyLimitEntry(
        packageName: app.packageName,
        appName: app.name,
        limit: const Duration(minutes: 1),
        day: DateTime(today.year, today.month, today.day),
        icon: app.icon,
      );
    }

    setState(() {
      _dailyLimits
        ..clear()
        ..addAll(newLimits);
    });
  }

  void _removeDailyLimit(String packageName) {
    setState(() {
      _dailyLimits.remove(packageName);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAndroid) {
      return Scaffold(
        appBar: AppBar(title: const Text('Touch Grass')),
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
        title: const Text('Touch Grass'),
        actions: [
          IconButton(
            onPressed: _isLoading || !_hasPermission
                ? null
                : () => _loadUsageStats(),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh stats',
          ),
          // IconButton(
          //   onPressed: _selectDateRange,
          //   icon: const Icon(Icons.calendar_today),
          //   tooltip: 'Select date range',
          // ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStakePanel(),
            const SizedBox(height: 16),
            _buildLimitsPanel(),
            const SizedBox(height: 16),
            Expanded(child: _buildUsageContent()),
          ],
        ),
      ),
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

class _ActiveBlockTile extends StatelessWidget {
  const _ActiveBlockTile({required this.entry, required this.onRemove});

  final BlockedAppEntry entry;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final remaining = entry.blockedUntil.difference(DateTime.now());
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: entry.icon != null
          ? CircleAvatar(backgroundImage: MemoryImage(entry.icon!))
          : const CircleAvatar(child: Icon(Icons.block)),
      title: Text(entry.appName),
      subtitle: Text(
        'Time left: ${_formatRemainingDuration(remaining)} • '
        'Stake ${_formatCurrency(entry.stakeAmount)}',
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        onPressed: onRemove,
        tooltip: 'Remove block',
      ),
    );
  }
}

class _DailyLimitTile extends StatelessWidget {
  const _DailyLimitTile({required this.entry, required this.onRemove});

  final DailyLimitEntry entry;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: entry.icon != null
          ? CircleAvatar(backgroundImage: MemoryImage(entry.icon!))
          : const CircleAvatar(child: Icon(Icons.hourglass_top)),
      title: Text(entry.appName),
      subtitle: Text(
        entry.isBlocked
            ? 'Blocked for today'
            : 'Time used: ${_formatDuration(entry.accumulated)}',
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Remove limit',
        onPressed: onRemove,
      ),
    );
  }
}

class _AppSelectionSheet extends StatefulWidget {
  const _AppSelectionSheet({
    required this.apps,
    required this.initiallySelected,
    required this.usageLookup,
  });

  final List<AppInfo> apps;
  final Set<String> initiallySelected;
  final Map<String, AppUsageInfo> usageLookup;

  @override
  State<_AppSelectionSheet> createState() => _AppSelectionSheetState();
}

class _UploadResult {
  const _UploadResult({required this.uploaded, this.modelApproved});

  final bool uploaded;
  final bool? modelApproved;

  bool get approved => uploaded && (modelApproved ?? false);
}

class _LoadingDialog extends StatelessWidget {
  const _LoadingDialog({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _AppSelectionSheetState extends State<_AppSelectionSheet> {
  late Set<String> _selectedPackages;
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
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
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
                    'Select apps to block',
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
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: filteredApps.length,
                itemBuilder: (context, index) {
                  final app = filteredApps[index];
                  final isSelected = _selectedPackages.contains(
                    app.packageName,
                  );
                  final usage = widget.usageLookup[app.packageName];
                  final usageLabel = usage == null
                      ? 'No usage today'
                      : 'Used ${_formatDuration(usage.totalTime)} today';
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
                    subtitle: Text(usageLabel),
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

class BlockedAppEntry {
  BlockedAppEntry({
    required this.packageName,
    required this.appName,
    required this.blockedUntil,
    required this.stakeAmount,
    this.icon,
  });

  final String packageName;
  final String appName;
  final DateTime blockedUntil;
  final double stakeAmount;
  final Uint8List? icon;
  DateTime? lastPromptTime;
}

class _StakeRequest {
  const _StakeRequest({
    required this.duration,
    required this.amountUsd,
    required this.selectedApps,
  });

  final Duration duration;
  final double amountUsd;
  final List<AppInfo> selectedApps;
}

class DailyLimitEntry {
  DailyLimitEntry({
    required this.packageName,
    required this.appName,
    required this.limit,
    required this.day,
    this.icon,
  });

  final String packageName;
  final String appName;
  Duration limit;
  final Uint8List? icon;
  DateTime day;
  Duration accumulated = Duration.zero;
  bool isBlocked = false;

  void resetForDay(DateTime newDay) {
    day = DateTime(newDay.year, newDay.month, newDay.day);
    accumulated = Duration.zero;
    isBlocked = false;
  }

  Duration get remaining {
    final diff = limit - accumulated;
    return diff.isNegative ? Duration.zero : diff;
  }

  void addUsage(Duration amount) {
    if (isBlocked) {
      return;
    }
    accumulated += amount;
    if (accumulated >= limit) {
      accumulated = limit;
      isBlocked = true;
    }
  }

  void extendLimit(Duration additional) {
    limit += additional;
    if (accumulated < limit) {
      isBlocked = false;
    }
  }
}

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

String _formatRemainingDuration(Duration duration) {
  if (duration.isNegative) {
    return 'Expired';
  }
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours > 0) {
    return '${hours}h ${minutes}m';
  }
  return '${minutes}m';
}

String _formatCurrency(double amount) {
  return '  ${amount.toStringAsFixed(2)}';
}

String _formatDate(DateTime date) {
  return '${date.month}/${date.day}/${date.year}';
}

String _formatDateTime(DateTime date) {
  final hour12 = date.hour % 12 == 0 ? 12 : date.hour % 12;
  final minute = date.minute.toString().padLeft(2, '0');
  final period = date.hour >= 12 ? 'PM' : 'AM';
  return '${_formatDate(date)} $hour12:$minute $period';
}

bool _isSameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}
