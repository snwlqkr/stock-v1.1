import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const StockApp());
}

// ── 1. 핵심 모델 ─────────────────────────────────────────
class Stock {
  final String symbol;
  final String name;
  final double price;
  final double change;
  final double changePercent;
  final List<double> chartData;

  const Stock({
    required this.symbol,
    required this.name,
    required this.price,
    required this.change,
    required this.changePercent,
    required this.chartData,
  });
}

class SearchResult {
  final String symbol;
  final String name;
  const SearchResult({required this.symbol, required this.name});
}

// ── 2. 디자인 토큰 (Obsidian Terminal 감성) ───────────────────
class T {
  static const bg = Color(0xFF090909);
  static const surface = Color(0xFF111111);
  static const raised = Color(0xFF181818);
  static const groove = Color(0xFF141414);
  static const line = Color(0xFF1E1E1E);
  static const lineDim = Color(0xFF161616);
  static const ink = Color(0xFFF0EFE9);
  static const sub = Color(0xFF4C4C4C);
  static const dim = Color(0xFF2E2E2E);
  static const up = Color(0xFF00D97E);
  static const down = Color(0xFFFF3356);
  static const flat = Color(0xFF4C4C4C);

  static const monoStyle = TextStyle(
    fontFamily: 'Courier',
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static BoxDecoration get raisedBox => BoxDecoration(
    color: raised,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: line),
  );

  static BoxDecoration get grooveBox => BoxDecoration(
    color: groove,
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: lineDim),
  );
}

// ── 3. 앱 시작점 ───────────────────────────────────────────
class StockApp extends StatelessWidget {
  const StockApp({super.key});

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarBrightness: Brightness.dark,
        statusBarIconBrightness: Brightness.light,
      ),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: T.bg,
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      ),
      home: const MarketScreen(),
    );
  }
}

// ── 4. 메인 화면 ──────────────────────────────────────────
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
  String _sortMode = 'change';

  // [수정 2] 헤더 상세화 — Yahoo Finance 차단 방지
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

  final ValueNotifier<int> _nextRefreshSec = ValueNotifier<int>(1800);
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _initData();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isUSMarketOpen() && !_loading && !_refreshing) {
        if (_nextRefreshSec.value > 0)
          _nextRefreshSec.value--;
        else
          _fetch();
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

    if (savedSort != null) _sortMode = savedSort;
    _watchlist = saved != null
        ? Map<String, String>.from(jsonDecode(saved))
        : Map<String, String>.from(_defaultWatchlist);
    _fetch(initial: true);
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('watchlist', jsonEncode(_watchlist));
    await prefs.setString('sortMode', _sortMode);
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

  Future<void> _fetch({bool initial = false, bool manual = false}) async {
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
      _error = result.isEmpty
          ? '네트워크 오류'
          : fail > 0
          ? '$fail개 로드 실패'
          : '';
    });
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
    });
    _saveData();
  }

  PopupMenuItem<String> _mkSortItem(String val, String label) => PopupMenuItem(
    value: val,
    child: Text(
      label,
      style: TextStyle(
        fontSize: 13,
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
            ? _buildLoader()
            : CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'MARKET',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: T.sub,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 2.0,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.baseline,
                                    textBaseline: TextBaseline.alphabetic,
                                    children: const [
                                      Text(
                                        'Watch',
                                        style: TextStyle(
                                          fontSize: 28,
                                          fontWeight: FontWeight.w300,
                                          color: T.ink,
                                          letterSpacing: -0.5,
                                          height: 1.1,
                                        ),
                                      ),
                                      Text(
                                        'list',
                                        style: TextStyle(
                                          fontSize: 28,
                                          fontWeight: FontWeight.w700,
                                          color: T.ink,
                                          letterSpacing: -0.5,
                                          height: 1.1,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              const Spacer(),
                              Row(
                                children: [
                                  _IconAction(
                                    icon: Icons.sort_rounded,
                                    child: PopupMenuButton<String>(
                                      padding: EdgeInsets.zero,
                                      icon: const Icon(
                                        Icons.sort_rounded,
                                        color: T.sub,
                                        size: 17,
                                      ),
                                      color: T.raised,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        side: const BorderSide(color: T.line),
                                      ),
                                      onSelected: (val) {
                                        setState(() {
                                          _sortMode = val;
                                          _applySorting();
                                        });
                                        _saveData();
                                      },
                                      itemBuilder: (_) => [
                                        _mkSortItem('change', '등락률 순'),
                                        _mkSortItem('price', '가격 순'),
                                        _mkSortItem('symbol', '심볼 순'),
                                        _mkSortItem('manual', '등록 순'),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  _IconAction(
                                    icon: Icons.add_rounded,
                                    onTap: _openSearch,
                                  ),
                                  const SizedBox(width: 6),
                                  _IconAction(
                                    icon: Icons.refresh_rounded,
                                    loading: _refreshing,
                                    onTap: _refreshing
                                        ? null
                                        : () => _fetch(manual: true),
                                  ),
                                ],
                              ),
                            ],
                          ),

                          const SizedBox(height: 16),

                          Row(
                            children: [
                              _StatusPill(label: _updatedAt),
                              const SizedBox(width: 6),
                              ValueListenableBuilder<int>(
                                valueListenable: _nextRefreshSec,
                                builder: (_, sec, __) => _isUSMarketOpen()
                                    ? _StatusPill(
                                        label:
                                            '${(sec ~/ 60).toString().padLeft(2, '0')}:'
                                            '${(sec % 60).toString().padLeft(2, '0')} 후 갱신',
                                        color: T.up,
                                      )
                                    : const _StatusPill(
                                        label: '장 마감',
                                        color: T.flat,
                                      ),
                              ),
                              if (_error.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                _StatusPill(label: _error, color: T.down),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  if (_data.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: Row(
                          children: const [
                            SizedBox(width: 4),
                            Expanded(
                              flex: 5,
                              child: Text(
                                '종목',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: T.sub,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                '차트',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: T.sub,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.2,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            Expanded(
                              flex: 4,
                              child: Text(
                                '가격 / 등락',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: T.sub,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.2,
                                ),
                                textAlign: TextAlign.right,
                              ),
                            ),
                            SizedBox(width: 20),
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
                    SliverList(
                      delegate: SliverChildBuilderDelegate((_, i) {
                        // [수정 1] 심볼 미리 캡처 — dismiss 중 인덱스 변경 방지
                        // [수정 1] ValueKey 추가 — 항목 재사용 오류 방지
                        final symbol = _data[i].symbol;
                        return _StockRow(
                          key: ValueKey(symbol),
                          stock: _data[i],
                          isLast: i == _data.length - 1,
                          onRemove: () => _removeStock(symbol),
                        );
                      }, childCount: _data.length),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _buildLoader() => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(color: T.up, strokeWidth: 1.5),
        ),
        SizedBox(height: 16),
        Text(
          '데이터 로딩 중',
          style: TextStyle(
            fontSize: 12,
            color: T.sub,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    ),
  );
}

// ── 5. 종목 행 ────────────────────────────────────────────
class _StockRow extends StatelessWidget {
  final Stock stock;
  final bool isLast;
  final VoidCallback onRemove;

  const _StockRow({
    super.key,
    required this.stock,
    required this.isLast,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isUp = stock.change > 0;
    final sigColor = stock.change == 0 ? T.flat : (isUp ? T.up : T.down);
    final sign = isUp ? '+' : '';
    final chartColor = stock.chartData.length > 1
        ? (stock.chartData.last >= stock.chartData.first ? T.up : T.down)
        : sigColor;

    return Dismissible(
      key: ValueKey(stock.symbol),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onRemove(),
      background: Container(
        color: T.down.withValues(alpha: 0.1),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(
          Icons.delete_outline_rounded,
          color: T.down,
          size: 20,
        ),
      ),
      child: Column(
        children: [
          Container(height: 1, color: T.lineDim),
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: IntrinsicHeight(
              child: Row(
                children: [
                  Container(width: 4, color: sigColor.withValues(alpha: 0.7)),
                  const SizedBox(width: 16),

                  Expanded(
                    flex: 5,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            stock.symbol,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: T.ink,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            stock.name,
                            style: const TextStyle(fontSize: 10, color: T.sub),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ],
                      ),
                    ),
                  ),

                  Expanded(
                    flex: 3,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 16,
                      ),
                      // 크기 명시 — 차트 변동성 정상 렌더링
                      child: SizedBox(
                        width: double.infinity,
                        height: 32,
                        child: stock.chartData.length > 1
                            ? CustomPaint(
                                painter: _SparklinePainter(
                                  stock.chartData,
                                  chartColor,
                                ),
                              )
                            : const SizedBox(),
                      ),
                    ),
                  ),

                  Expanded(
                    flex: 4,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '\$${stock.price.toStringAsFixed(2)}',
                            style: T.monoStyle.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: T.ink,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$sign${stock.changePercent.toStringAsFixed(2)}%',
                            style: T.monoStyle.copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: sigColor,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isLast) Container(height: 1, color: T.lineDim),
        ],
      ),
    );
  }
}

// ── 6. 검색 바텀시트 ──────────────────────────────────────
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

  // [수정 3] 검색 헤더도 동일하게 상세화
  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json',
    'Accept-Language': 'en-US,en;q=0.9',
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
      if (mounted)
        setState(() {
          _searching = false;
          _hint = '네트워크 오류';
        });
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
              width: 32,
              height: 3,
              decoration: BoxDecoration(
                color: T.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Text(
                    'ADD TICKER',
                    style: TextStyle(
                      fontSize: 11,
                      color: T.sub,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const Icon(
                      Icons.close_rounded,
                      color: T.sub,
                      size: 18,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                decoration: T.grooveBox,
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  onChanged: _onChanged,
                  style: const TextStyle(fontSize: 14, color: T.ink),
                  decoration: InputDecoration(
                    hintText: '티커 또는 종목명  (AAPL, Tesla …)',
                    hintStyle: const TextStyle(color: T.sub, fontSize: 13),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      color: T.sub,
                      size: 16,
                    ),
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                color: T.up,
                                strokeWidth: 1.5,
                              ),
                            ),
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
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
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
                        style: const TextStyle(fontSize: 12, color: T.sub),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      itemCount: _results.length,
                      separatorBuilder: (_, __) =>
                          Container(height: 1, color: T.lineDim),
                      itemBuilder: (_, i) {
                        final r = _results[i];
                        final added = widget.alreadyAdded.contains(r.symbol);
                        return GestureDetector(
                          onTap: added
                              ? null
                              : () {
                                  widget.onAdd(r.symbol, r.name);
                                  Navigator.pop(context);
                                },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14),
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
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          color: added ? T.sub : T.ink,
                                          letterSpacing: 0.2,
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
                                          fontSize: 11,
                                          color: T.sub,
                                        ),
                                      )
                                    : Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 5,
                                        ),
                                        decoration: BoxDecoration(
                                          border: Border.all(color: T.up),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: const Text(
                                          '+ 추가',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: T.up,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                              ],
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

// ── 7. 유틸리티 공용 위젯들 ───────────────────────────────
class _IconAction extends StatelessWidget {
  final IconData? icon;
  final VoidCallback? onTap;
  final bool active;
  final bool loading;
  final Widget? child;

  const _IconAction({
    this.icon,
    this.onTap,
    this.active = false,
    this.loading = false,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: active ? T.ink : T.raised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: active ? T.ink : T.line),
      ),
      child: loading
          ? const Center(
              child: SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(color: T.up, strokeWidth: 1.5),
              ),
            )
          : child != null
          ? ClipRRect(borderRadius: BorderRadius.circular(8), child: child)
          : GestureDetector(
              onTap: onTap,
              child: Icon(
                icon ?? Icons.circle_outlined,
                size: 16,
                color: active ? T.bg : (onTap == null ? T.dim : T.sub),
              ),
            ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusPill({required this.label, this.color = T.sub});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withValues(alpha: 0.15)),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 10,
        color: color,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    ),
  );
}

class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final Color color;
  _SparklinePainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final maxV = data.reduce(max);
    final minV = data.reduce(min);
    final isFlat = maxV == minV;
    final range = isFlat ? 1.0 : maxV - minV;
    final stepX = size.width / (data.length - 1);

    double yOf(double v) => isFlat
        ? size.height / 2
        : size.height - ((v - minV) / range) * size.height;

    final path = Path();
    for (int i = 0; i < data.length; i++) {
      i == 0
          ? path.moveTo(0, yOf(data[0]))
          : path.lineTo(i * stepX, yOf(data[i]));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.color != color ||
      old.data.length != data.length ||
      (data.isNotEmpty && old.data.last != data.last);
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
          'WATCHLIST EMPTY',
          style: TextStyle(
            fontSize: 11,
            color: T.sub,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: onAdd,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(color: T.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, color: T.sub, size: 16),
                SizedBox(width: 6),
                Text(
                  '종목 추가',
                  style: TextStyle(
                    fontSize: 13,
                    color: T.sub,
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
        const Text(
          'NETWORK ERROR',
          style: TextStyle(
            fontSize: 11,
            color: T.sub,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 20),
        GestureDetector(
          onTap: onRetry,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: T.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '다시 시도',
              style: TextStyle(
                fontSize: 12,
                color: T.sub,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
