import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const StockApp());
}

// ── 모델 ────────────────────────────────────────────
class Stock {
  final String symbol;
  final String name;
  final double price;
  final double change;
  final double changePercent;
  final double dayHigh;
  final double dayLow;
  final int volume;
  final List<double> chartData;

  const Stock({
    required this.symbol,
    required this.name,
    required this.price,
    required this.change,
    required this.changePercent,
    required this.dayHigh,
    required this.dayLow,
    required this.volume,
    required this.chartData,
  });
}

class SearchResult {
  final String symbol;
  final String name;
  const SearchResult({required this.symbol, required this.name});
}

// ── 디자인 토큰 ──────────────────────────────────────
class T {
  static const bg = Color(0xFF0D0D0D);
  static const surface = Color(0xFF141414);
  static const card = Color(0xFF1A1A1A);
  static const border = Color(0xFF242424);
  static const ink = Color(0xFFFFFFFF);
  static const sub = Color(0xFF555555);
  static const mute = Color(0xFF2A2A2A);
  static const up = Color(0xFF00C97B);
  static const down = Color(0xFFFF453A);
  static const flat = Color(0xFF636366);

  static BoxDecoration get cardDeco => BoxDecoration(
    color: card,
    borderRadius: BorderRadius.circular(14),
    border: Border.all(color: border),
  );
}

// ── 앱 ──────────────────────────────────────────────
class StockApp extends StatelessWidget {
  const StockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: T.bg,
        fontFamily: 'SF Pro Display',
      ),
      home: const MarketScreen(),
    );
  }
}

// ── 메인 화면 ────────────────────────────────────────
class MarketScreen extends StatefulWidget {
  const MarketScreen({super.key});
  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends State<MarketScreen> {
  static const Map<String, String> _defaultWatchlist = {
    'QQQM': 'Invesco NASDAQ 100',
    'TQQQ': 'ProShares UltraPro QQQ',
    'VOO': 'Vanguard S&P 500',
    'NVDA': 'NVIDIA Corporation',
    'AAPL': 'Apple Inc.',
    'TSLA': 'Tesla, Inc.',
  };

  Map<String, String> _watchlist = {};
  String _sortMode = 'manual';

  Map<String, Map<String, double>> _portfolio = {};
  final Set<String> _triggeredAlerts = {};

  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json',
    'Accept-Language': 'en-US,en;q=0.9',
    'Referer': 'https://finance.yahoo.com',
  };

  List<Stock> _data = [];
  bool _loading = true;
  bool _refreshing = false;
  String _error = '';
  String _updatedAt = '--:--';
  bool _editMode = false;

  final ValueNotifier<int> _nextRefreshSec = ValueNotifier<int>(1800);
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _initData();

    // [수정 1] 가드 추가: 이미 로딩/새로고침 중이면 fetch 건너뜀
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isUSMarketOpen() && !_loading && !_refreshing) {
        if (_nextRefreshSec.value > 0) {
          _nextRefreshSec.value--;
        } else {
          _fetch();
        }
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _nextRefreshSec.dispose();
    super.dispose();
  }

  Future<void> _initData() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('watchlist');
    final savedSort = prefs.getString('sortMode');
    final savedPort = prefs.getString('portfolio');

    if (savedSort != null) _sortMode = savedSort;
    _watchlist = saved != null
        ? Map<String, String>.from(jsonDecode(saved))
        : Map<String, String>.from(_defaultWatchlist);

    if (savedPort != null) {
      try {
        final decoded = jsonDecode(savedPort) as Map<String, dynamic>;
        _portfolio = decoded.map(
          (k, v) => MapEntry(
            k,
            (v as Map<String, dynamic>).map(
              (ik, iv) => MapEntry(ik, (iv as num).toDouble()),
            ),
          ),
        );
      } catch (_) {
        _portfolio = {};
      }
    }

    _fetch(initial: true);
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('watchlist', jsonEncode(_watchlist));
    await prefs.setString('sortMode', _sortMode);
    await prefs.setString('portfolio', jsonEncode(_portfolio));
  }

  bool _isUSMarketOpen() {
    final now = DateTime.now().toUtc();
    if (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday)
      return false;
    final t = now.hour + now.minute / 60.0;
    return t >= 13.0 && t <= 21.5;
  }

  String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';

  void _applySorting() {
    switch (_sortMode) {
      case 'change':
        _data.sort((a, b) => b.changePercent.compareTo(a.changePercent));
      case 'price':
        _data.sort((a, b) => b.price.compareTo(a.price));
      case 'symbol':
        _data.sort((a, b) => a.symbol.compareTo(b.symbol));
      default:
        final order = _watchlist.keys.toList();
        _data.sort((a, b) {
          int ia = order.indexOf(a.symbol);
          int ib = order.indexOf(b.symbol);
          if (ia == -1) ia = 999;
          if (ib == -1) ib = 999;
          return ia.compareTo(ib);
        });
    }
  }

  void _checkAlerts(List<Stock> stocks) {
    for (final s in stocks) {
      final port = _portfolio[s.symbol];
      if (port == null) continue;
      final target = port['alertPrice'] ?? 0.0;
      if (target <= 0) continue;
      if (s.price >= target && !_triggeredAlerts.contains(s.symbol)) {
        _triggeredAlerts.add(s.symbol);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(
                  Icons.notifications_active_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${s.symbol}이(가) \$${target.toStringAsFixed(2)} 돌파!',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            backgroundColor: T.up,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _fetch({bool initial = false, bool manual = false}) async {
    // [수정 1] 이미 진행 중이면 중복 호출 차단
    if (!initial && !manual && (_loading || _refreshing)) return;

    if (!initial && !manual && !_isUSMarketOpen()) {
      _nextRefreshSec.value = 1800;
      return;
    }
    if (!mounted) return;

    setState(() {
      if (initial)
        _loading = true;
      else
        _refreshing = true;
      _error = '';
    });

    final List<Stock> result = [];
    int fail = 0;

    for (final entry in _watchlist.entries.toList()) {
      if (!mounted) return;
      try {
        final url = Uri.parse(
          'https://query1.finance.yahoo.com/v8/finance/chart/'
          '${entry.key}?range=1d&interval=5m',
        );
        final res = await http
            .get(url, headers: _headers)
            .timeout(const Duration(seconds: 10));

        if (res.statusCode == 200) {
          final body = jsonDecode(res.body);
          final meta = body['chart']['result'][0]['meta'];

          final price = (meta['regularMarketPrice'] ?? 0.0).toDouble();
          final prev =
              (meta['regularMarketPreviousClose'] ??
                      meta['chartPreviousClose'] ??
                      price)
                  .toDouble();
          final chg = price - prev;
          final pct = prev == 0 ? 0.0 : chg / prev * 100;
          final dayHigh = (meta['regularMarketDayHigh'] ?? 0.0).toDouble();
          final dayLow = (meta['regularMarketDayLow'] ?? 0.0).toDouble();
          final volume = (meta['regularMarketVolume'] ?? 0).toInt();

          final List<double> chartData = [];
          final indList = body['chart']['result'][0]['indicators'];
          if (indList != null &&
              indList['quote'] != null &&
              (indList['quote'] as List).isNotEmpty) {
            final closes = indList['quote'][0]['close'] as List?;
            if (closes != null) {
              for (final c in closes) {
                if (c != null) chartData.add((c as num).toDouble());
              }
            }
          }

          result.add(
            Stock(
              symbol: entry.key,
              name: entry.value,
              price: price,
              change: chg,
              changePercent: pct,
              dayHigh: dayHigh,
              dayLow: dayLow,
              volume: volume,
              chartData: chartData,
            ),
          );
        } else {
          fail++;
        }
      } catch (_) {
        fail++;
      }
    }

    if (!mounted) return;

    setState(() {
      _data = result;
      _applySorting();
      _loading = false;
      _refreshing = false;
      _updatedAt = _fmtTime(DateTime.now());
      _nextRefreshSec.value = 1800;
      // [수정 2] _error는 여전히 저장 (MetaBadge에서 표시)
      _error = result.isEmpty
          ? '네트워크 오류'
          : fail > 0
          ? '$fail개 로드 실패'
          : '';
    });

    _checkAlerts(result);
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _data.removeAt(oldIndex);
      _data.insert(newIndex, item);
      final newWl = <String, String>{};
      for (final s in _data) newWl[s.symbol] = s.name;
      for (final e in _watchlist.entries) {
        if (!newWl.containsKey(e.key)) newWl[e.key] = e.value;
      }
      _watchlist = newWl;
      _sortMode = 'manual';
    });
    _saveData();
  }

  void _openSearch() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: T.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SearchSheet(
        alreadyAdded: _watchlist.keys.toSet(),
        onAdd: (symbol, name) {
          setState(() => _watchlist[symbol] = name);
          _saveData();
          _fetch(manual: true);
        },
      ),
    );
  }

  void _removeStock(String symbol) {
    setState(() {
      _watchlist.remove(symbol);
      _data.removeWhere((s) => s.symbol == symbol);
      _triggeredAlerts.remove(symbol);
    });
    _saveData();
  }

  PopupMenuItem<String> _mkSortItem(String val, String label) => PopupMenuItem(
    value: val,
    child: Text(
      label,
      style: TextStyle(
        color: _sortMode == val ? T.up : T.ink,
        fontWeight: _sortMode == val ? FontWeight.w600 : FontWeight.normal,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.bg,
      body: SafeArea(
        child: _loading
            ? const Center(child: _Spinner())
            : CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'Market',
                                style: TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.w700,
                                  color: T.ink,
                                  letterSpacing: -1,
                                ),
                              ),
                              const Spacer(),
                              PopupMenuButton<String>(
                                icon: const Icon(
                                  Icons.sort_rounded,
                                  color: T.sub,
                                  size: 20,
                                ),
                                color: T.surface,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                onSelected: (val) {
                                  setState(() {
                                    _sortMode = val;
                                    _applySorting();
                                  });
                                  _saveData();
                                },
                                itemBuilder: (_) => [
                                  _mkSortItem('manual', '직접 지정'),
                                  _mkSortItem('change', '등락률 순'),
                                  _mkSortItem('price', '가격 순'),
                                  _mkSortItem('symbol', '심볼 순'),
                                ],
                              ),
                              const SizedBox(width: 4),
                              _HeaderBtn(
                                icon: _editMode
                                    ? Icons.check_rounded
                                    : Icons.tune_rounded,
                                onTap: () =>
                                    setState(() => _editMode = !_editMode),
                                active: _editMode,
                              ),
                              const SizedBox(width: 8),
                              _HeaderBtn(
                                icon: Icons.add_rounded,
                                onTap: _openSearch,
                              ),
                              const SizedBox(width: 8),
                              _HeaderBtn(
                                icon: Icons.refresh_rounded,
                                onTap: _refreshing
                                    ? null
                                    : () => _fetch(manual: true),
                                loading: _refreshing,
                              ),
                            ],
                          ),

                          const SizedBox(height: 8),

                          // [수정 2] _error 있으면 경고 뱃지 표시
                          Row(
                            children: [
                              _MetaBadge(
                                icon: Icons.access_time_rounded,
                                label: _updatedAt,
                              ),
                              const SizedBox(width: 8),
                              ValueListenableBuilder<int>(
                                valueListenable: _nextRefreshSec,
                                builder: (_, sec, __) {
                                  if (!_isUSMarketOpen()) {
                                    return const _MetaBadge(
                                      icon: Icons.nightlight_round,
                                      label: '장 마감',
                                      color: T.flat,
                                    );
                                  }
                                  return _MetaBadge(
                                    icon: Icons.autorenew_rounded,
                                    label:
                                        '${(sec ~/ 60).toString().padLeft(2, '0')}:'
                                        '${(sec % 60).toString().padLeft(2, '0')}',
                                  );
                                },
                              ),
                              if (_sortMode == 'manual') ...[
                                const SizedBox(width: 8),
                                const _MetaBadge(
                                  icon: Icons.drag_indicator_rounded,
                                  label: '길게 눌러 순서 변경',
                                ),
                              ],
                              if (_error.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                _MetaBadge(
                                  icon: Icons.warning_amber_rounded,
                                  label: _error,
                                  color: T.down,
                                ),
                              ],
                            ],
                          ),

                          const SizedBox(height: 20),
                          if (_data.isNotEmpty) ...[
                            _PortfolioSummaryRow(
                              stocks: _data,
                              portfolio: _portfolio,
                            ),
                            const SizedBox(height: 20),
                          ],
                        ],
                      ),
                    ),
                  ),

                  if (_watchlist.isEmpty)
                    SliverFillRemaining(
                      child: _EmptyWatchlist(onAdd: _openSearch),
                    )
                  else if (_data.isEmpty)
                    SliverFillRemaining(
                      child: _ErrorView(onRetry: () => _fetch(initial: true)),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                      sliver: SliverReorderableList(
                        itemCount: _data.length,
                        onReorder: _onReorder,
                        itemBuilder: (_, i) {
                          final s = _data[i];
                          return ReorderableDelayedDragStartListener(
                            key: ValueKey(s.symbol),
                            index: i,
                            child: _StockRow(
                              stock: s,
                              portData: _portfolio[s.symbol],
                              rank: i + 1,
                              editMode: _editMode,
                              onRemove: () => _removeStock(s.symbol),
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => StockDetailScreen(
                                      stock: s,
                                      initialPort: _portfolio[s.symbol],
                                      onSavePortfolio: (avg, qty, alert) {
                                        setState(() {
                                          _portfolio[s.symbol] = {
                                            'avgPrice': avg,
                                            'qty': qty,
                                            'alertPrice': alert,
                                          };
                                          _triggeredAlerts.remove(s.symbol);
                                        });
                                        _saveData();
                                      },
                                    ),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

// ── 포트폴리오 요약 바 ────────────────────────────────
class _PortfolioSummaryRow extends StatelessWidget {
  final List<Stock> stocks;
  final Map<String, Map<String, double>> portfolio;
  const _PortfolioSummaryRow({required this.stocks, required this.portfolio});

  @override
  Widget build(BuildContext context) {
    double invested = 0, current = 0;

    for (final s in stocks) {
      final p = portfolio[s.symbol];
      if (p == null) continue;
      final avg = p['avgPrice'] ?? 0.0;
      final qty = p['qty'] ?? 0.0;
      if (avg > 0 && qty > 0) {
        invested += avg * qty;
        current += s.price * qty;
      }
    }

    final holding = invested > 0;
    final diff = current - invested;
    final pct = holding ? diff / invested * 100 : 0.0;
    final isUp = diff > 0;
    final color = diff == 0 ? T.flat : (isUp ? T.up : T.down);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: T.cardDeco,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '내 포트폴리오',
            style: TextStyle(
              fontSize: 11,
              color: T.sub,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                holding ? '\$${current.toStringAsFixed(2)}' : '보유 종목 없음',
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: T.ink,
                  letterSpacing: -1,
                ),
              ),
              if (holding) ...[
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '${isUp ? "+" : ""}${diff.toStringAsFixed(2)}'
                    ' (${pct.toStringAsFixed(2)}%)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (holding) ...[
            const SizedBox(height: 5),
            Text(
              '투자원금  \$${invested.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 11, color: T.sub),
            ),
          ],
        ],
      ),
    );
  }
}

// ── 상세 화면 ─────────────────────────────────────────
class StockDetailScreen extends StatefulWidget {
  final Stock stock;
  final Map<String, double>? initialPort;
  final void Function(double avg, double qty, double alert) onSavePortfolio;

  const StockDetailScreen({
    super.key,
    required this.stock,
    required this.initialPort,
    required this.onSavePortfolio,
  });

  @override
  State<StockDetailScreen> createState() => _StockDetailScreenState();
}

class _StockDetailScreenState extends State<StockDetailScreen> {
  late TextEditingController _priceCtrl, _qtyCtrl, _alertCtrl;
  late double _avgPrice, _qty;

  @override
  void initState() {
    super.initState();
    _avgPrice = widget.initialPort?['avgPrice'] ?? 0.0;
    _qty = widget.initialPort?['qty'] ?? 0.0;
    _priceCtrl = TextEditingController(
      text: _avgPrice > 0 ? _avgPrice.toStringAsFixed(2) : '',
    );
    _qtyCtrl = TextEditingController(
      text: _qty > 0 ? _qty.toStringAsFixed(2) : '',
    );
    _alertCtrl = TextEditingController(
      text: (widget.initialPort?['alertPrice'] ?? 0.0) > 0
          ? widget.initialPort!['alertPrice']!.toStringAsFixed(2)
          : '',
    );

    _priceCtrl.addListener(
      () => setState(() {
        _avgPrice = double.tryParse(_priceCtrl.text) ?? 0.0;
      }),
    );
    _qtyCtrl.addListener(
      () => setState(() {
        _qty = double.tryParse(_qtyCtrl.text) ?? 0.0;
      }),
    );
  }

  @override
  void dispose() {
    _priceCtrl.dispose();
    _qtyCtrl.dispose();
    _alertCtrl.dispose();
    super.dispose();
  }

  String _fmtVol(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(2)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K';
    return '$v';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.stock;
    final isUp = s.change > 0;
    final color = s.change == 0 ? T.flat : (isUp ? T.up : T.down);
    final sign = isUp ? '+' : '';

    final hasPos = _avgPrice > 0 && _qty > 0;
    final eval = s.price * _qty;
    final cost = _avgPrice * _qty;
    final myPct = hasPos ? (s.price - _avgPrice) / _avgPrice * 100 : 0.0;
    final myPnl = eval - cost;
    final retColor = myPct > 0 ? T.up : (myPct < 0 ? T.down : T.flat);

    return Scaffold(
      backgroundColor: T.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: T.ink,
            size: 20,
          ),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.symbol,
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                color: T.ink,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(height: 2),
            Text(s.name, style: const TextStyle(fontSize: 13, color: T.sub)),
            const SizedBox(height: 20),

            Text(
              '\$${s.price.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 44,
                fontWeight: FontWeight.w700,
                color: T.ink,
                letterSpacing: -2,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '$sign\$${s.change.abs().toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 15,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  // [수정 3] withOpacity → withValues
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$sign${s.changePercent.toStringAsFixed(2)}%',
                    style: TextStyle(
                      fontSize: 13,
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            if (s.chartData.length > 1) ...[
              SizedBox(
                height: 90,
                child: CustomPaint(
                  size: const Size(double.infinity, 90),
                  painter: _SparklinePainter(
                    s.chartData,
                    // 차트 첫값 → 마지막값 방향으로 색상 결정
                    s.chartData.last >= s.chartData.first ? T.up : T.down,
                    showArea: true,
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],

            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: T.cardDeco,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _StatCell(
                    label: '고가',
                    value: '\$${s.dayHigh.toStringAsFixed(2)}',
                  ),
                  Container(width: 1, height: 30, color: T.border),
                  _StatCell(
                    label: '저가',
                    value: '\$${s.dayLow.toStringAsFixed(2)}',
                  ),
                  Container(width: 1, height: 30, color: T.border),
                  _StatCell(label: '거래량', value: _fmtVol(s.volume)),
                ],
              ),
            ),

            const SizedBox(height: 12),

            if (hasPos)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: T.cardDeco,
                child: Column(
                  children: [
                    _DetailRow(
                      label: '평균 매수가',
                      value: '\$${_avgPrice.toStringAsFixed(2)}',
                    ),
                    const SizedBox(height: 10),
                    _DetailRow(
                      label: '보유 수량',
                      value:
                          '${_qty % 1 == 0 ? _qty.toInt() : _qty.toStringAsFixed(2)}주',
                    ),
                    const SizedBox(height: 10),
                    _DetailRow(
                      label: '평가금액',
                      value: '\$${eval.toStringAsFixed(2)}',
                    ),
                    const SizedBox(height: 10),
                    _DetailRow(
                      label: '수익률',
                      value:
                          '${myPct > 0 ? "+" : ""}${myPct.toStringAsFixed(2)}%'
                          '  (${myPnl >= 0 ? "+" : ""}'
                          '\$${myPnl.toStringAsFixed(2)})',
                      valueColor: retColor,
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 24),

            const Text(
              '포트폴리오 설정',
              style: TextStyle(
                fontSize: 15,
                color: T.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),

            Container(
              padding: const EdgeInsets.all(20),
              decoration: T.cardDeco,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _FormField(
                          ctrl: _priceCtrl,
                          label: '평균 매수가 (\$)',
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _FormField(ctrl: _qtyCtrl, label: '보유 수량 (주)'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _FormField(
                    ctrl: _alertCtrl,
                    label: '돌파 알림 가격 (\$)',
                    helper: '이 가격 도달 시 앱 화면에 알림이 표시됩니다',
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        final p = double.tryParse(_priceCtrl.text) ?? 0.0;
                        final q = double.tryParse(_qtyCtrl.text) ?? 0.0;
                        final a = double.tryParse(_alertCtrl.text) ?? 0.0;
                        widget.onSavePortfolio(p, q, a);
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('저장되었습니다'),
                            backgroundColor: T.up,
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: T.ink,
                        foregroundColor: T.bg,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        '저장하기',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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

// ── 스파크라인 페인터 ─────────────────────────────────
class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final Color color;
  final bool showArea;
  _SparklinePainter(this.data, this.color, {this.showArea = false});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final maxV = data.reduce(max);
    final minV = data.reduce(min);
    final range = maxV == minV ? 1.0 : maxV - minV;
    final stepX = size.width / (data.length - 1);

    double yOf(double v) => size.height - ((v - minV) / range) * size.height;

    final line = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    for (int i = 0; i < data.length; i++) {
      i == 0
          ? path.moveTo(0, yOf(data[0]))
          : path.lineTo(i * stepX, yOf(data[i]));
    }
    canvas.drawPath(path, line);

    if (showArea) {
      final area = Path()
        ..addPath(path, Offset.zero)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            // [수정 3] withOpacity → withValues
            colors: [
              color.withValues(alpha: 0.2),
              color.withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.data != data || old.color != color;
}

// ── 종목 행 ──────────────────────────────────────────
class _StockRow extends StatelessWidget {
  final Stock stock;
  final Map<String, double>? portData;
  final int rank;
  final bool editMode;
  final VoidCallback onRemove, onTap;

  const _StockRow({
    super.key,
    required this.stock,
    this.portData,
    required this.rank,
    required this.editMode,
    required this.onRemove,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isUp = stock.change > 0;
    final color = stock.change == 0 ? T.flat : (isUp ? T.up : T.down);
    final sign = isUp ? '+' : '';

    final avg = portData?['avgPrice'] ?? 0.0;
    final qty = portData?['qty'] ?? 0.0;
    String? myReturnText;
    Color myReturnColor = T.sub;
    if (avg > 0 && qty > 0) {
      final ret = (stock.price - avg) / avg * 100;
      myReturnText = '내 수익률  ${ret > 0 ? "+" : ""}${ret.toStringAsFixed(1)}%';
      myReturnColor = ret > 0 ? T.up : (ret < 0 ? T.down : T.flat);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
            child: Row(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: editMode
                      ? GestureDetector(
                          key: const ValueKey('del'),
                          onTap: onRemove,
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: const BoxDecoration(
                              color: T.down,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.remove_rounded,
                              color: T.ink,
                              size: 14,
                            ),
                          ),
                        )
                      : SizedBox(
                          key: const ValueKey('rank'),
                          width: 22,
                          child: Text(
                            '$rank',
                            style: const TextStyle(
                              fontSize: 12,
                              color: T.sub,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 8),

                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stock.symbol,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: T.ink,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        myReturnText ?? stock.name,
                        style: TextStyle(
                          fontSize: 11,
                          color: myReturnText != null ? myReturnColor : T.sub,
                          fontWeight: myReturnText != null
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),

                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: SizedBox(
                      height: 28,
                      child: stock.chartData.length > 1
                          ? CustomPaint(
                              painter: _SparklinePainter(
                                stock.chartData,
                                // 차트 첫값 → 마지막값 방향으로 색상 결정
                                stock.chartData.last >= stock.chartData.first
                                    ? T.up
                                    : T.down,
                              ),
                            )
                          : const SizedBox(),
                    ),
                  ),
                ),

                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '\$${stock.price.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: T.ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            '$sign\$${stock.change.abs().toStringAsFixed(2)}',
                            style: TextStyle(fontSize: 11, color: color),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            // [수정 3] withOpacity → withValues
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              '$sign${stock.changePercent.toStringAsFixed(2)}%',
                              style: TextStyle(
                                fontSize: 11,
                                color: color,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
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

// ── 검색 바텀시트 ────────────────────────────────────
class _SearchSheet extends StatefulWidget {
  final Set<String> alreadyAdded;
  final void Function(String symbol, String name) onAdd;
  const _SearchSheet({required this.alreadyAdded, required this.onAdd});

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  List<SearchResult> _results = [];
  bool _searching = false;
  String _hint = '';
  Timer? _debounce;

  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json',
    'Referer': 'https://finance.yahoo.com',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() {
        _results = [];
        _hint = '';
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => _search(q.trim()),
    );
  }

  Future<void> _search(String q) async {
    setState(() {
      _searching = true;
      _hint = '';
    });
    try {
      final url = Uri.parse(
        'https://query1.finance.yahoo.com/v1/finance/search'
        '?q=${Uri.encodeComponent(q)}&quotesCount=8&newsCount=0',
      );
      final res = await http
          .get(url, headers: _headers)
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;

      if (res.statusCode == 200) {
        final quotes = jsonDecode(res.body)['quotes'] as List? ?? [];
        final found = quotes
            .where((q) => q['quoteType'] == 'EQUITY' || q['quoteType'] == 'ETF')
            .map(
              (q) => SearchResult(
                symbol: (q['symbol'] ?? '').toString(),
                name: (q['longname'] ?? q['shortname'] ?? '').toString(),
              ),
            )
            .where((r) => r.symbol.isNotEmpty)
            .toList();
        setState(() {
          _results = found;
          _searching = false;
          if (found.isEmpty) _hint = '검색 결과가 없어요';
        });
      } else {
        setState(() {
          _searching = false;
          _hint = '검색 실패';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _searching = false;
          _hint = '네트워크 오류';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.8,
        decoration: const BoxDecoration(
          color: T.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: T.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  const Text(
                    '종목 추가',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: T.ink,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const Icon(
                      Icons.close_rounded,
                      color: T.sub,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                onChanged: _onChanged,
                style: const TextStyle(fontSize: 15, color: T.ink),
                decoration: InputDecoration(
                  hintText: '티커 또는 종목명 (예: AAPL, Tesla)',
                  hintStyle: const TextStyle(color: T.sub, fontSize: 14),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: T.sub,
                    size: 18,
                  ),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: _Spinner(size: 16),
                        )
                      : (_ctrl.text.isNotEmpty
                            ? GestureDetector(
                                onTap: () {
                                  _ctrl.clear();
                                  setState(() {
                                    _results = [];
                                    _hint = '';
                                  });
                                },
                                child: const Icon(
                                  Icons.clear_rounded,
                                  color: T.sub,
                                  size: 16,
                                ),
                              )
                            : null),
                  filled: true,
                  fillColor: T.mute,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Text(
                        _hint.isEmpty ? '티커나 회사명으로 검색하세요' : _hint,
                        style: const TextStyle(fontSize: 13, color: T.sub),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                      itemCount: _results.length,
                      itemBuilder: (_, i) {
                        final r = _results[i];
                        final added = widget.alreadyAdded.contains(r.symbol);
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: added
                                ? null
                                : () {
                                    widget.onAdd(r.symbol, r.name);
                                    Navigator.pop(context);
                                  },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 14,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          r.symbol,
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            color: added ? T.sub : T.ink,
                                            letterSpacing: -0.3,
                                          ),
                                        ),
                                        if (r.name.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            r.name,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: T.sub,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  added
                                      ? const Text(
                                          '추가됨',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: T.sub,
                                          ),
                                        )
                                      : Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: T.mute,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: const Text(
                                            '+ 추가',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: T.ink,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 소형 공용 위젯 ────────────────────────────────────
class _StatCell extends StatelessWidget {
  final String label, value;
  const _StatCell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(label, style: const TextStyle(fontSize: 11, color: T.sub)),
      const SizedBox(height: 4),
      Text(
        value,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: T.ink,
        ),
      ),
    ],
  );
}

class _DetailRow extends StatelessWidget {
  final String label, value;
  final Color? valueColor;
  const _DetailRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label, style: const TextStyle(fontSize: 13, color: T.sub)),
      Text(
        value,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: valueColor ?? T.ink,
        ),
      ),
    ],
  );
}

class _FormField extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final String? helper;
  const _FormField({required this.ctrl, required this.label, this.helper});

  @override
  Widget build(BuildContext context) => TextField(
    controller: ctrl,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    style: const TextStyle(color: T.ink, fontSize: 14),
    decoration: InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: T.sub, fontSize: 13),
      helperText: helper,
      helperStyle: const TextStyle(color: T.sub, fontSize: 11),
      enabledBorder: const UnderlineInputBorder(
        borderSide: BorderSide(color: T.border),
      ),
      focusedBorder: const UnderlineInputBorder(
        borderSide: BorderSide(color: T.ink),
      ),
    ),
  );
}

class _HeaderBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool active, loading;
  const _HeaderBtn({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: active ? T.ink : T.mute,
        borderRadius: BorderRadius.circular(10),
      ),
      child: loading
          ? const Center(child: _Spinner(size: 16))
          : Icon(
              icon,
              size: 18,
              color: active ? T.bg : (onTap == null ? T.flat : T.sub),
            ),
    ),
  );
}

class _MetaBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _MetaBadge({
    required this.icon,
    required this.label,
    this.color = T.sub,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: T.mute,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    ),
  );
}

class _EmptyWatchlist extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyWatchlist({required this.onAdd});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '관심 종목이 없어요',
          style: TextStyle(
            fontSize: 16,
            color: T.sub,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '+ 버튼으로 종목을 추가해보세요',
          style: TextStyle(fontSize: 13, color: T.flat),
        ),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: onAdd,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: T.border),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, color: T.ink, size: 16),
                SizedBox(width: 6),
                Text(
                  '종목 추가',
                  style: TextStyle(
                    fontSize: 13,
                    color: T.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _ErrorView extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorView({required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('—', style: TextStyle(fontSize: 40, color: T.sub)),
        const SizedBox(height: 12),
        const Text(
          '데이터를 불러올 수 없어요',
          style: TextStyle(fontSize: 14, color: T.sub),
        ),
        const SizedBox(height: 20),
        GestureDetector(
          onTap: onRetry,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: T.border),
            ),
            child: const Text(
              '다시 시도',
              style: TextStyle(
                fontSize: 13,
                color: T.ink,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _Spinner extends StatelessWidget {
  final double size;
  const _Spinner({this.size = 20});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: const CircularProgressIndicator(color: T.up, strokeWidth: 1.5),
  );
}
