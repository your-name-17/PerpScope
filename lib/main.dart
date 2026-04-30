import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'web_notifications/web_notification_service_stub.dart'
    if (dart.library.html) 'web_notifications/web_notification_service_web.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Binance EMA+MA Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const EmaScannerPage(),
    );
  }
}

class EmaScannerPage extends StatefulWidget {
  const EmaScannerPage({super.key});

  @override
  State<EmaScannerPage> createState() => _EmaScannerPageState();
}

class _EmaScannerPageState extends State<EmaScannerPage>
    with WidgetsBindingObserver {
  String _status = '';

  // 为了让 EMA120 更贴近交易所图表，需要更长历史进行预热。
  static const int _indicatorWarmupKlines = 1000;
  static const int _binanceKlinesMaxLimit = 1500;

  String interval = '1d';
  int topN = 100;
  double threshold = 0.1;
  int klinesLimit = 120;
  int workers = 8;

  static const Duration _fallbackContinuousDelay = Duration(seconds: 5);
  static const Duration _scanAlignSafetyBuffer = Duration(seconds: 1);

  final List<_ScanTask> _tasks = <_ScanTask>[];

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _isAppResumed = true;

  late TextEditingController _topNController;
  late TextEditingController _thresholdController;
  late TextEditingController _klinesLimitController;
  late TextEditingController _workersController;
  late TextEditingController _newListingDaysController;

  int newListingDays = 7;
  bool scanOnlyNew = false;

  void _log(String message) {
    debugPrint('[EMA] $message');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _topNController = TextEditingController(text: topN.toString());
    _thresholdController = TextEditingController(
      text: threshold.toStringAsFixed(2),
    );
    _klinesLimitController = TextEditingController(
      text: klinesLimit.toString(),
    );
    _workersController = TextEditingController(text: workers.toString());
    _newListingDaysController = TextEditingController(
      text: newListingDays.toString(),
    );

    _initNotifications();
  }

  @override
  void dispose() {
    _topNController.dispose();
    _thresholdController.dispose();
    _klinesLimitController.dispose();
    _workersController.dispose();
    _newListingDaysController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppResumed = state == AppLifecycleState.resumed;
  }

  Future<void> _initNotifications() async {
    if (kIsWeb) {
      await initWebNotifications();
      return;
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const windowsInit = WindowsInitializationSettings(
      appName: 'Binance EMA+MA Scanner',
      appUserModelId: 'dev.trading.ema_scanner',
      guid: 'd49b0314-ee7a-4626-bf79-97cdb8a991bb',
    );

    const initSettings = InitializationSettings(
      android: androidInit,
      windows: windowsInit,
    );

    await _notifications.initialize(settings: initSettings);

    if (Platform.isAndroid) {
      final androidImpl = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidImpl?.requestNotificationsPermission();
    }
  }

  void _clearResults() {
    setState(() {
      for (final task in _tasks) {
        task.matches.clear();
        task.lastMatchedSymbols.clear();
        task.status = '';
        task.isRunning = false;
        task.cancelRequested = false;
      }
      _status = '已清空所有任务结果';
    });
    _log('已清空所有任务结果');
  }

  void _addTask() {
    final parsedThreshold = double.tryParse(_thresholdController.text);
    if (parsedThreshold == null || parsedThreshold <= 0) {
      setState(() {
        _status = '无法添加任务：threshold 不合法（需要 > 0）';
      });
      _log('添加任务失败：threshold 不合法，值=${_thresholdController.text}');
      return;
    }

    threshold = parsedThreshold;
    final int id = _tasks.isEmpty ? 1 : (_tasks.last.id + 1);
    final parsedDays =
        int.tryParse(_newListingDaysController.text) ?? newListingDays;
    setState(() {
      _tasks.add(
        _ScanTask(
          id: id,
          interval: interval,
          threshold: parsedThreshold,
          onlyNewSymbols: scanOnlyNew,
          newListingDays: parsedDays,
        ),
      );
      _status = '已添加任务 #$id (周期 $interval, threshold=$parsedThreshold)';
    });
    _log('已添加任务 #$id (周期 $interval, threshold=$parsedThreshold)');
  }

  void _stopTask(_ScanTask task) {
    if (!task.isRunning) return;
    setState(() {
      task.cancelRequested = true;
      task.status = '已请求终止扫描...';
    });
    _log('收到终止任务 #${task.id} (周期 ${task.interval}) 的请求');
  }

  void _deleteTask(_ScanTask task) {
    setState(() {
      if (task.isRunning) {
        task.cancelRequested = true;
        task.status = '删除中，已请求终止扫描...';
      }
      _tasks.remove(task);
      _status = '已删除任务 #${task.id} (周期 ${task.interval})';
    });
    _log('已删除任务 #${task.id} (周期 ${task.interval})');
  }

  Future<void> _showMatchesDialog(
    String taskInterval,
    List<MatchResult> matches,
  ) async {
    if (!mounted || matches.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('周期 $taskInterval 发现 EMA 收敛币种'),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: matches
                    .map(
                      (m) => Text(
                        '${m.symbol}  spread=${m.spreadPct.toStringAsFixed(4)}%',
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showMatchesNotification(
    String taskInterval,
    List<MatchResult> matches,
  ) async {
    if (kIsWeb || matches.isEmpty) return;

    const androidDetails = AndroidNotificationDetails(
      'ema_scanner_channel',
      'EMA 收敛提醒',
      channelDescription: '当扫描到满足 EMA 收敛条件的币种时提醒',
      importance: Importance.high,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);

    final title = '周期 $taskInterval 发现 ${matches.length} 个 EMA 收敛币种';
    final body = matches
        .take(3)
        .map((m) => '${m.symbol} (${m.spreadPct.toStringAsFixed(2)}%)')
        .join(', ');

    try {
      await _notifications.show(
        id: 0,
        title: title,
        body: body.isEmpty ? null : body,
        notificationDetails: details,
      );
    } catch (e) {
      _log('发送系统通知失败: $e');
    }
  }

  Future<void> _notifyForTaskMatches(
    _ScanTask task,
    List<MatchResult> matches,
  ) async {
    if (!mounted || matches.isEmpty) return;

    if (kIsWeb) {
      final canNotify = await webCanNotify();
      final title = '周期 ${task.interval} 发现 ${matches.length} 个 EMA 收敛币种';
      final body = matches
          .take(3)
          .map((m) => '${m.symbol} (${m.spreadPct.toStringAsFixed(2)}%)')
          .join(', ');

      if (canNotify) {
        await showWebNotification(title, body);
      }

      if (_isAppResumed || !canNotify) {
        await _showMatchesDialog(task.interval, matches);
      }
      return;
    }

    final isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

    if (isDesktop) {
      if (_isAppResumed) {
        await _showMatchesDialog(task.interval, matches);
      } else {
        await _showMatchesNotification(task.interval, matches);
      }
    } else {
      // 手机端统一使用系统通知，避免后台场景弹对话框失败。
      await _showMatchesNotification(task.interval, matches);
    }
  }

  Future<void> _scanNewListings() async {
    final parsedDays =
        int.tryParse(_newListingDaysController.text) ?? newListingDays;
    final parsedTopN = int.tryParse(_topNController.text) ?? topN;
    if (parsedDays <= 0) {
      setState(() {
        _status = '天数必须为正整数';
      });
      return;
    }

    setState(() {
      _status = '扫描新币(${parsedDays}天, top=${parsedTopN}) ...';
    });
    try {
      final results = await fetchNewlyListedSymbols(parsedDays, parsedTopN);
      if (results.isEmpty) {
        setState(() {
          _status = '未发现最近 ${parsedDays} 天内的新币 (top ${parsedTopN})';
        });
        _log('未发现最近 ${parsedDays} 天内的新币 (top ${parsedTopN})');
        await showDialog<void>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text('最近 ${parsedDays} 天新币 (top ${parsedTopN})'),
              content: SizedBox(
                width: 320,
                child: Text('未发现最近 ${parsedDays} 天内的新币 (top ${parsedTopN})。'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
        return;
      }

      setState(() {
        _status =
            '发现 ${results.length} 个最近 ${parsedDays} 天新币 (top ${parsedTopN})';
      });
      _log('发现 ${results.length} 个最近 ${parsedDays} 天新币 (top ${parsedTopN})');
      await _showNewListingsDialog(results);
    } catch (e) {
      setState(() {
        _status = '扫描新币失败: $e';
      });
      _log('扫描新币失败: $e');
    }
  }

  Future<void> _showNewListingsDialog(List<_NewListingResult> results) async {
    if (!mounted || results.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('最近上新的币种'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: results.map((r) {
                  final d = r.listedAt.toUtc();
                  final date =
                      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                  return Text(
                    '$date  ${r.symbol}  成交额(USDT)=${r.quoteVolume.toStringAsFixed(2)}',
                  );
                }).toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Duration? _intervalToDuration(String value) {
    final match = RegExp(r'^(\d+)([mhdw])$').firstMatch(value);
    if (match == null) return null;

    final amount = int.tryParse(match.group(1) ?? '');
    final unit = match.group(2);
    if (amount == null || amount <= 0 || unit == null) return null;

    switch (unit) {
      case 'm':
        return Duration(minutes: amount);
      case 'h':
        return Duration(hours: amount);
      case 'd':
        return Duration(days: amount);
      case 'w':
        return Duration(days: amount * 7);
      default:
        return null;
    }
  }

  DateTime _nextBoundaryUtc(DateTime nowUtc, Duration interval) {
    final intervalMs = interval.inMilliseconds;
    final nowMs = nowUtc.millisecondsSinceEpoch;
    final nextMs = ((nowMs ~/ intervalMs) + 1) * intervalMs;
    return DateTime.fromMillisecondsSinceEpoch(nextMs, isUtc: true);
  }

  Future<DateTime> _getExchangeNowUtc() async {
    try {
      final data =
          await httpGetJson('https://fapi.binance.com/fapi/v1/time') as dynamic;
      if (data is Map<String, dynamic>) {
        final serverTimeMs = data['serverTime'];
        if (serverTimeMs is int) {
          return DateTime.fromMillisecondsSinceEpoch(serverTimeMs, isUtc: true);
        }
        if (serverTimeMs is String) {
          final parsed = int.tryParse(serverTimeMs);
          if (parsed != null) {
            return DateTime.fromMillisecondsSinceEpoch(parsed, isUtc: true);
          }
        }
      }
    } catch (e) {
      _log('获取 Binance 服务器时间失败，回退本地时间: $e');
    }
    return DateTime.now().toUtc();
  }

  Future<void> _waitUntilNextKlineClose(_ScanTask task) async {
    final intervalDuration = _intervalToDuration(task.interval);
    if (intervalDuration == null) {
      _log('任务 #${task.id} 周期 ${task.interval} 无法解析，使用兜底等待 5 秒');
      await Future.delayed(_fallbackContinuousDelay);
      return;
    }

    final nowUtc = await _getExchangeNowUtc();
    final nextCloseUtc = _nextBoundaryUtc(nowUtc, intervalDuration);
    var remaining = nextCloseUtc.difference(nowUtc) + _scanAlignSafetyBuffer;
    if (remaining <= Duration.zero) {
      remaining = const Duration(milliseconds: 500);
    }

    _log(
      '任务 #${task.id} 等待至下一根 ${task.interval} K线收线后再扫描（约 ${remaining.inSeconds}s）',
    );

    const tick = Duration(seconds: 1);
    while (!task.cancelRequested && remaining > Duration.zero) {
      final step = remaining > tick ? tick : remaining;
      await Future.delayed(step);
      remaining -= step;
    }
  }

  Future<void> _runScanForTask(_ScanTask task) async {
    if (task.isRunning) return;

    final parsedTopN = int.tryParse(_topNController.text);
    final parsedKlinesLimit = int.tryParse(_klinesLimitController.text);
    final parsedWorkers = int.tryParse(_workersController.text);

    if (parsedTopN == null ||
        parsedTopN <= 0 ||
        parsedKlinesLimit == null ||
        parsedKlinesLimit < 121 ||
        parsedWorkers == null ||
        parsedWorkers <= 0) {
      setState(() {
        _status = '参数不合法，请检查 topN、threshold、klinesLimit（>=121）、workers（>0）';
        task.status = '参数不合法，无法启动任务';
      });
      _log(
        '任务 #${task.id} 参数不合法: topN=$parsedTopN klinesLimit=$parsedKlinesLimit workers=$parsedWorkers',
      );
      return;
    }

    topN = parsedTopN;
    klinesLimit = parsedKlinesLimit;
    workers = parsedWorkers;

    final taskThreshold = task.threshold;

    setState(() {
      task.isRunning = true;
      task.cancelRequested = false;
      task.status = '开始扫描...';
      task.matches.clear();
      task.lastMatchedSymbols.clear();
      _status = '任务 #${task.id} (周期 ${task.interval}) 开始扫描';
    });
    _log(
      '任务 #${task.id} 开始扫描: interval=${task.interval} topN=$topN threshold=$taskThreshold klinesLimit=$klinesLimit workers=$workers 持续=${task.continuous}',
    );

    try {
      while (true) {
        if (!mounted || task.cancelRequested) {
          _log('检测到任务 #${task.id} 终止标志，结束扫描循环');
          break;
        }

        _log('任务 #${task.id} 开始新一轮扫描');
        List<String> symbols;
        if (task.onlyNewSymbols) {
          final newList = await fetchNewlyListedSymbols(
            task.newListingDays,
            topN,
          );
          symbols = newList.map((e) => e.symbol).toList();
        } else {
          symbols = await fetchTopSymbolsByQuoteVolume(topN);
        }
        if (symbols.isEmpty) {
          setState(() {
            task.status = '未获取到任何 symbol';
            _status = '任务 #${task.id} (周期 ${task.interval}) 未获取到任何 symbol';
          });
          _log('任务 #${task.id} 未获取到任何 symbol');

          if (!task.continuous) {
            break;
          }

          await _waitUntilNextKlineClose(task);
          continue;
        }

        final matches = <MatchResult>[];
        final total = symbols.length;
        int idx = 0;

        Future<MatchResult?> worker(int localIdx, String symbol) async {
          if (task.cancelRequested) {
            return null;
          }
          try {
            final indicatorLimit = math.min(
              math.max(klinesLimit, _indicatorWarmupKlines),
              _binanceKlinesMaxLimit,
            );
            _log(
              '任务 #${task.id} [$localIdx/$total] $symbol 使用K线数量=$indicatorLimit (UI klinesLimit=$klinesLimit)',
            );
            final closes = await fetchKlines(
              symbol,
              task.interval,
              indicatorLimit,
            );
            final List<double> closedCloses = closes.length > 1
                ? closes.sublist(0, closes.length - 1)
                : [];

            if (closedCloses.length < 120) {
              if (!mounted) return null;
              setState(() {
                task.status = '[$localIdx/$total] $symbol 跳过(数据不足)';
                _status =
                    '任务 #${task.id} (周期 ${task.interval}) $symbol 跳过(数据不足) [$localIdx/$total]';
              });
              _log('任务 #${task.id} [$localIdx/$total] $symbol 跳过(数据不足)');
              return null;
            }

            final ema20 = ema(closedCloses, 20);
            final ema60 = ema(closedCloses, 60);
            final ema120 = ema(closedCloses, 120);
            final ma20 = ma(closedCloses, 20);
            final ma60 = ma(closedCloses, 60);
            final ma120 = ma(closedCloses, 120);

            if (ema20 == null ||
                ema60 == null ||
                ema120 == null ||
                ma20 == null ||
                ma60 == null ||
                ma120 == null) {
              if (!mounted) return null;
              setState(() {
                task.status = '[$localIdx/$total] $symbol 跳过(均线计算失败)';
                _status =
                    '任务 #${task.id} (周期 ${task.interval}) $symbol 跳过(均线计算失败) [$localIdx/$total]';
              });
              _log('任务 #${task.id} [$localIdx/$total] $symbol 跳过(均线计算失败)');
              return null;
            }

            final result = isDense6([
              ema20,
              ema60,
              ema120,
              ma20,
              ma60,
              ma120,
            ], taskThreshold);
            final spreadPct = result.spread * 100.0;
            final lines = <double>[ema20, ema60, ema120, ma20, ma60, ma120];
            final mn = lines.reduce(math.min);
            final mx = lines.reduce(math.max);
            _log(
              '任务 #${task.id} [$localIdx/$total] $symbol 明细 '
              'EMA20=${ema20.toStringAsFixed(6)} '
              'EMA60=${ema60.toStringAsFixed(6)} '
              'EMA120=${ema120.toStringAsFixed(6)} '
              'MA20=${ma20.toStringAsFixed(6)} '
              'MA60=${ma60.toStringAsFixed(6)} '
              'MA120=${ma120.toStringAsFixed(6)} '
              'min=${mn.toStringAsFixed(6)} '
              'max=${mx.toStringAsFixed(6)} '
              'spread=${spreadPct.toStringAsFixed(4)}% '
              'threshold=${(taskThreshold * 100).toStringAsFixed(4)}% '
              'ok=${result.ok}',
            );

            if (result.ok) {
              final m = MatchResult(symbol: symbol, spreadPct: spreadPct);
              if (!mounted) return m;
              if (task.cancelRequested) return null;
              setState(() {
                task.status =
                    '[$localIdx/$total] $symbol 发现 EMA+MA 密集 spread=${spreadPct.toStringAsFixed(4)}%';
                _status =
                    '任务 #${task.id} (周期 ${task.interval}) $symbol 发现 EMA+MA 密集 spread=${spreadPct.toStringAsFixed(4)}% [$localIdx/$total]';
                task.matches = [...task.matches, m];
              });
              _log(
                '任务 #${task.id} [$localIdx/$total] $symbol 发现 EMA+MA 密集 spread=${spreadPct.toStringAsFixed(4)}%',
              );
              return m;
            } else {
              if (!mounted) return null;
              if (task.cancelRequested) return null;
              setState(() {
                task.status =
                    '[$localIdx/$total] $symbol 不满足 EMA+MA 密集 spread=${spreadPct.toStringAsFixed(4)}%';
                _status =
                    '任务 #${task.id} (周期 ${task.interval}) $symbol 不满足 EMA+MA 密集 spread=${spreadPct.toStringAsFixed(4)}% [$localIdx/$total]';
              });
              _log(
                '任务 #${task.id} [$localIdx/$total] $symbol 不满足 EMA+MA 密集 spread=${spreadPct.toStringAsFixed(4)}%',
              );
              return null;
            }
          } catch (e) {
            if (!mounted) return null;
            if (task.cancelRequested) return null;
            setState(() {
              task.status = '[$localIdx/$total] $symbol 失败($e)';
              _status =
                  '任务 #${task.id} (周期 ${task.interval}) $symbol 失败($e) [$localIdx/$total]';
            });
            _log('任务 #${task.id} [$localIdx/$total] $symbol 失败: $e');
            return null;
          }
        }

        var i = 0;
        final batchSize = workers;
        while (i < total) {
          if (task.cancelRequested) {
            break;
          }
          final end = (i + batchSize) > total ? total : (i + batchSize);
          final batch = symbols.sublist(i, end);
          final futures = <Future<MatchResult?>>[];
          for (final symbol in batch) {
            idx += 1;
            futures.add(worker(idx, symbol));
          }
          final results = await Future.wait(futures);
          for (final r in results) {
            if (r != null) {
              matches.add(r);
            }
          }
          i = end;
        }

        if (task.cancelRequested) {
          setState(() {
            task.status = '扫描已终止，当前匹配数量: ${matches.length}';
            _status =
                '任务 #${task.id} (周期 ${task.interval}) 扫描已终止，当前匹配数量: ${matches.length}';
          });
          _log('任务 #${task.id} 扫描被终止，匹配数量: ${matches.length}');
          break;
        }

        // 本轮匹配的 symbol 集合，用于判断哪些是“本轮新加入队伍”的币种。
        final currentSymbols = matches.map((m) => m.symbol).toSet();
        // 与上一轮相比，新进入“符合条件队伍”的币种。
        final newSymbols = currentSymbols.difference(task.lastMatchedSymbols);

        setState(() {
          if (matches.isEmpty) {
            task.status = task.continuous
                ? '本轮扫描完成，没有任何币种满足阈值条件（持续扫描已开启）。'
                : '扫描完成，没有任何币种满足阈值条件。';
          } else {
            task.status = task.continuous
                ? '本轮扫描完成，共找到 ${matches.length} 个匹配币种（持续扫描已开启）。'
                : '扫描完成，共找到 ${matches.length} 个匹配币种。';
          }
          _status = '任务 #${task.id} (周期 ${task.interval}) ${task.status}';
          // 用本轮匹配结果覆盖任务的匹配列表，移除本轮不再符合的币种。
          task.matches = List<MatchResult>.from(matches);
        });
        _log('任务 #${task.id} 本轮扫描完成，匹配数量: ${matches.length}');

        // 只对“本轮新进入符合条件队伍”的币种提醒；
        // 对于中途消失又在本轮重新出现的币种，会再次被视为新成员并提醒。
        final toNotify = matches
            .where((m) => newSymbols.contains(m.symbol))
            .toList(growable: false);

        // 记录本轮的符合条件队伍，用于下一轮对比；
        // 没有在本轮中出现的币种会从集合中移除，
        // 以后若再次出现，将再次被视为“新出现”，重新提醒。
        task.lastMatchedSymbols = currentSymbols;
        if (toNotify.isNotEmpty) {
          await _notifyForTaskMatches(task, toNotify);
        }

        if (!task.continuous) {
          break;
        }

        if (task.cancelRequested) {
          break;
        }

        _log('任务 #${task.id} 持续扫描已开启，等待当前未走完 K线收线...');
        await _waitUntilNextKlineClose(task);
      }
    } catch (e) {
      setState(() {
        task.status = '扫描失败: $e';
        _status = '任务 #${task.id} (周期 ${task.interval}) 扫描失败: $e';
      });
      _log('任务 #${task.id} 扫描失败: $e');
    } finally {
      setState(() {
        task.isRunning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const double taskPanelHeight = 300;
    const double resultPanelHeight = 720;

    return Scaffold(
      appBar: AppBar(title: const Text('Binance USDT EMA+MA(20/60/120) 扫描器')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 32,
              ),
              child: Column(
                children: [
                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('周期:'),
                              const SizedBox(width: 8),
                              DropdownButton<String>(
                                value: interval,
                                items: const [
                                  DropdownMenuItem(
                                    value: '3m',
                                    child: Text('3m'),
                                  ),
                                  DropdownMenuItem(
                                    value: '15m',
                                    child: Text('15m'),
                                  ),
                                  DropdownMenuItem(
                                    value: '1h',
                                    child: Text('1h'),
                                  ),
                                  DropdownMenuItem(
                                    value: '4h',
                                    child: Text('4h'),
                                  ),
                                  DropdownMenuItem(
                                    value: '1d',
                                    child: Text('1d'),
                                  ),
                                ],
                                onChanged: (v) {
                                  if (v == null) return;
                                  setState(() {
                                    interval = v;
                                  });
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                child: TextField(
                                  controller: _topNController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: false,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: 'topN',
                                    hintText: '例如 100',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: TextField(
                                  controller: _thresholdController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: 'threshold',
                                    hintText: '例如 0.1',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                child: TextField(
                                  controller: _klinesLimitController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: false,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: 'klinesLimit',
                                    hintText: '例如 150 (>=121)',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: TextField(
                                  controller: _workersController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: false,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: 'workers',
                                    hintText: '并发数，例如 8',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                child: TextField(
                                  controller: _newListingDaysController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: false,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: '天数',
                                    hintText: '例如 7',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: _addTask,
                                child: const Text('添加任务'),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: _clearResults,
                                child: const Text('清空结果'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                fit: FlexFit.loose,
                                child: OutlinedButton(
                                  onPressed: _scanNewListings,
                                  child: const Text('扫描新币(含天数和topN参数)'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Checkbox(
                                    value: scanOnlyNew,
                                    onChanged: (v) {
                                      if (v == null) return;
                                      setState(() {
                                        scanOnlyNew = v;
                                      });
                                    },
                                  ),
                                  const Text('仅在新币中扫描EMA'),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(_status, style: const TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: taskPanelHeight,
                    child: Card(
                      elevation: 1,
                      child: _tasks.isEmpty
                          ? const Center(
                              child: Text(
                                '暂无扫描任务，先在上方选择周期并点击“添加任务”。',
                                style: TextStyle(color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              itemCount: _tasks.length,
                              itemBuilder: (context, index) {
                                final task = _tasks[index];
                                final statusText = task.status.isEmpty
                                    ? (task.isRunning ? '运行中' : '未开始')
                                    : task.status;
                                return ListTile(
                                  title: Text(
                                    '任务 #${task.id}  周期: ${task.interval}',
                                  ),
                                  subtitle: Text(
                                    '状态: $statusText\n匹配数量: ${task.matches.length}  持续扫描: ${task.continuous ? '是' : '否'}  threshold=${task.threshold}',
                                    maxLines: 2,
                                  ),
                                  isThreeLine: true,
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Checkbox(
                                        value: task.continuous,
                                        onChanged: (v) {
                                          if (v == null) return;
                                          setState(() {
                                            task.continuous = v;
                                          });
                                        },
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          task.isRunning
                                              ? Icons.stop
                                              : Icons.play_arrow,
                                        ),
                                        tooltip: task.isRunning
                                            ? '停止任务'
                                            : '开始任务',
                                        onPressed: () {
                                          if (task.isRunning) {
                                            _stopTask(task);
                                          } else {
                                            _runScanForTask(task);
                                          }
                                        },
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.delete),
                                        tooltip: '删除任务',
                                        onPressed: () => _deleteTask(task),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: resultPanelHeight,
                    child: Card(
                      elevation: 1,
                      child: Builder(
                        builder: (context) {
                          final entries = <_TaskMatchEntry>[];
                          for (final task in _tasks) {
                            for (final m in task.matches) {
                              entries.add(_TaskMatchEntry(task.interval, m));
                            }
                          }
                          if (entries.isEmpty) {
                            return const Center(
                              child: Text(
                                '暂无匹配结果',
                                style: TextStyle(color: Colors.grey),
                              ),
                            );
                          }
                          return ListView.builder(
                            itemCount: entries.length,
                            itemBuilder: (context, index) {
                              final e = entries[index];
                              return ListTile(
                                title: Text(
                                  '${e.match.symbol}  (${e.interval})',
                                ),
                                subtitle: Text(
                                  'spread=${e.match.spreadPct.toStringAsFixed(4)}%',
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ===== 网络与计算逻辑 =====

class _ScanTask {
  final int id;
  final String interval;
  final double threshold;
  final bool onlyNewSymbols;
  final int newListingDays;
  bool continuous;
  bool isRunning;
  bool cancelRequested;
  String status;
  List<MatchResult> matches;
  Set<String> lastMatchedSymbols;

  _ScanTask({
    required this.id,
    required this.interval,
    required this.threshold,
    this.onlyNewSymbols = false,
    this.newListingDays = 7,
    this.continuous = true,
  }) : isRunning = false,
       cancelRequested = false,
       status = '',
       matches = <MatchResult>[],
       lastMatchedSymbols = <String>{};
}

class _TaskMatchEntry {
  final String interval;
  final MatchResult match;

  _TaskMatchEntry(this.interval, this.match);
}

// 直接访问 Binance USDT 永续合约接口，对应 Python 代码中的 BINANCE_FAPI_BASE。
const String binanceFapiBase = 'https://fapi.binance.com';

Future<dynamic> httpGetJson(
  String url, {
  Map<String, String>? params,
  int timeoutSeconds = 15,
  int maxRetries = 3,
}) async {
  var uri = Uri.parse(url);
  if (params != null && params.isNotEmpty) {
    uri = uri.replace(queryParameters: {...uri.queryParameters, ...params});
  }

  final headers = <String, String>{
    'User-Agent': 'Mozilla/5.0 (compatible; ema-converge-scanner/1.0)',
    'Accept': 'application/json',
  };

  Object? lastError;

  for (var attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      debugPrint('[EMA][HTTP] GET $uri (attempt $attempt/$maxRetries)');
      http.Response resp;
      if (kIsWeb) {
        resp = await http
            .get(uri, headers: headers)
            .timeout(Duration(seconds: timeoutSeconds));
      } else {
        final ioHttpClient = HttpClient()
          // 如需严格校验证书，可以把下面这一行去掉。
          ..badCertificateCallback =
              (X509Certificate cert, String host, int port) => true;
        // 与 curl/Python 一样，强制直连，不使用系统代理，避免某些环境下代理拦截。
        ioHttpClient.findProxy = (uri) => 'DIRECT';
        final ioClient = IOClient(ioHttpClient);
        resp = await ioClient
            .get(uri, headers: headers)
            .timeout(Duration(seconds: timeoutSeconds));
      }
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        debugPrint('[EMA][HTTP] OK $uri status=${resp.statusCode}');
        return jsonDecode(utf8.decode(resp.bodyBytes));
      }

      lastError = 'HTTP ${resp.statusCode} ${resp.reasonPhrase}';
      debugPrint('[EMA][HTTP] Non-2xx $uri: $lastError');
      if ([418, 429, 500, 502, 503, 504].contains(resp.statusCode)) {
        final delay = Duration(milliseconds: 500 * attempt);
        await Future.delayed(delay);
        continue;
      } else {
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      }
    } on TimeoutException catch (e) {
      lastError = e;
      debugPrint('[EMA][HTTP] Timeout $uri on attempt $attempt: $e');
      await Future.delayed(Duration(milliseconds: 400 * attempt));
    } catch (e) {
      lastError = e;
      debugPrint('[EMA][HTTP] Error $uri on attempt $attempt: $e');
      await Future.delayed(Duration(milliseconds: 400 * attempt));
    }
  }

  throw Exception('请求失败，已重试 $maxRetries 次。最后错误: $lastError');
}

Future<Set<String>> fetchUsdtPerpetualSymbols() async {
  final info =
      await httpGetJson('$binanceFapiBase/fapi/v1/exchangeInfo') as dynamic;

  final symbols = <String>{};
  if (info is! Map<String, dynamic>) {
    return symbols;
  }

  final list = info['symbols'];
  if (list is! List) return symbols;

  for (final s in list) {
    if (s is! Map<String, dynamic>) continue;
    try {
      if (s['contractType'] != 'PERPETUAL') continue;
      if (s['status'] != 'TRADING') continue;
      if (s['quoteAsset'] != 'USDT') continue;

      final symbol = (s['symbol'] ?? '').toString();
      if (symbol.isNotEmpty) {
        symbols.add(symbol);
      }
    } catch (_) {
      continue;
    }
  }
  return symbols;
}

Future<List<String>> fetchTopSymbolsByQuoteVolume(int topN) async {
  final usdtPerpSymbols = await fetchUsdtPerpetualSymbols();
  if (usdtPerpSymbols.isEmpty) {
    throw Exception('未能获取 USDT 永续合约列表');
  }

  final tickers =
      await httpGetJson('$binanceFapiBase/fapi/v1/ticker/24hr') as dynamic;
  if (tickers is! List) {
    throw Exception('返回数据格式异常：期望 list');
  }

  final filtered = <_SymbolVolume>[];

  for (final item in tickers) {
    if (item is! Map<String, dynamic>) continue;
    try {
      final symbol = (item['symbol'] ?? '').toString();
      if (!usdtPerpSymbols.contains(symbol)) continue;

      final qv =
          double.tryParse((item['quoteVolume'] ?? '0').toString()) ?? 0.0;
      if (qv <= 0) continue;

      filtered.add(_SymbolVolume(symbol: symbol, quoteVolume: qv));
    } catch (_) {
      continue;
    }
  }

  filtered.sort((a, b) => b.quoteVolume.compareTo(a.quoteVolume));
  final result = filtered.take(topN).map((e) => e.symbol).toList();
  return result;
}

/// 返回最近 `days` 天内上新的 USDT 永续合约列表（基于 exchangeInfo 中的上架时间字段）
Future<List<_NewListingResult>> fetchNewlyListedSymbols(
  int days,
  int topN,
) async {
  final info =
      await httpGetJson('$binanceFapiBase/fapi/v1/exchangeInfo') as dynamic;
  final results = <_NewListingResult>[];
  if (info is! Map<String, dynamic>) return results;

  final list = info['symbols'];
  if (list is! List) return results;

  final cutoffMs = DateTime.now()
      .toUtc()
      .subtract(Duration(days: days))
      .millisecondsSinceEpoch;

  // 预取 24h 成交量数据，用于按成交量排序
  final tickersRaw =
      await httpGetJson('$binanceFapiBase/fapi/v1/ticker/24hr') as dynamic;
  final Map<String, double> volMap = {};
  if (tickersRaw is List) {
    for (final t in tickersRaw) {
      if (t is! Map<String, dynamic>) continue;
      try {
        final sym = (t['symbol'] ?? '').toString();
        final qv = double.tryParse((t['quoteVolume'] ?? '0').toString()) ?? 0.0;
        volMap[sym] = qv;
      } catch (_) {
        continue;
      }
    }
  }

  for (final s in list) {
    if (s is! Map<String, dynamic>) continue;
    try {
      if (s['contractType'] != 'PERPETUAL') continue;
      if (s['status'] != 'TRADING') continue;
      if (s['quoteAsset'] != 'USDT') continue;

      final symbol = (s['symbol'] ?? '').toString();
      if (symbol.isEmpty) continue;

      dynamic timeField =
          s['onboardDate'] ??
          s['onboardTime'] ??
          s['listTime'] ??
          s['onboardAt'] ??
          s['onboardTimestamp'];
      int? ts;
      if (timeField is int) ts = timeField;
      if (timeField is String) ts = int.tryParse(timeField);
      if (ts == null) continue;

      if (ts >= cutoffMs) {
        double qv = volMap[symbol] ?? 0.0;
        if (qv == 0.0) {
          try {
            final single =
                await httpGetJson(
                      '$binanceFapiBase/fapi/v1/ticker/24hr',
                      params: {'symbol': symbol},
                    )
                    as dynamic;
            if (single is Map<String, dynamic>) {
              qv =
                  double.tryParse((single['quoteVolume'] ?? '0').toString()) ??
                  qv;
            }
          } catch (_) {
            // ignore fetch errors, keep qv as-is
          }
        }

        results.add(
          _NewListingResult(
            symbol: symbol,
            listedAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
            quoteVolume: qv,
          ),
        );
      }
    } catch (_) {
      continue;
    }
  }

  // 按成交量降序，并取前 topN
  results.sort((a, b) => b.quoteVolume.compareTo(a.quoteVolume));
  return results.take(topN).toList();
}

Future<List<double>> fetchKlines(
  String symbol,
  String interval,
  int limit,
) async {
  final klines =
      await httpGetJson(
            '$binanceFapiBase/fapi/v1/klines',
            params: {'symbol': symbol, 'interval': interval, 'limit': '$limit'},
          )
          as dynamic;

  if (klines is! List || klines.isEmpty) {
    return const [];
  }

  final closes = <double>[];
  for (final k in klines) {
    try {
      if (k is List && k.length > 4) {
        closes.add(double.parse(k[4].toString()));
      }
    } catch (_) {
      continue;
    }
  }
  return closes;
}

double? ema(List<double> values, int span) {
  if (span <= 0) {
    throw ArgumentError('span 必须为正数');
  }
  if (values.length < span) {
    return null;
  }

  // Binance/主流行情图表常见做法：以第一根收盘价为初值递推 EMA。
  final alpha = 2.0 / (span + 1.0);
  double e = values.first;

  for (var i = 1; i < values.length; i++) {
    final x = values[i];
    e = alpha * x + (1.0 - alpha) * e;
  }
  return e;
}

double? ma(List<double> values, int span) {
  if (span <= 0) {
    throw ArgumentError('span 必须为正数');
  }
  if (values.length < span) {
    return null;
  }

  final window = values.sublist(values.length - span);
  return window.reduce((a, b) => a + b) / span.toDouble();
}

class ConvergeResult {
  final bool ok;
  final double spread;

  ConvergeResult(this.ok, this.spread);
}

ConvergeResult isDense6(List<double> averages, double threshold) {
  final mn = averages.reduce(math.min);
  final mx = averages.reduce(math.max);
  final mnAbs = mn.abs();
  if (mnAbs == 0) {
    return ConvergeResult(false, double.infinity);
  }
  final spread = (mx - mn) / mnAbs;
  return ConvergeResult(spread <= threshold, spread);
}

class MatchResult {
  final String symbol;
  final double spreadPct;

  MatchResult({required this.symbol, required this.spreadPct});
}

class _NewListingResult {
  final String symbol;
  final DateTime listedAt;
  final double quoteVolume;

  _NewListingResult({
    required this.symbol,
    required this.listedAt,
    required this.quoteVolume,
  });
}

class _SymbolVolume {
  final String symbol;
  final double quoteVolume;

  _SymbolVolume({required this.symbol, required this.quoteVolume});
}
