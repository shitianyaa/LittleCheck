import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'settings_page.dart';
import 'feed_view.dart';
import 'note_view.dart';
import 'storage.dart';
import 'appearance.dart';
import 'brand_mark.dart';
import 'external_documents.dart';
import 'custom_fonts.dart';
import 'daily_tracker.dart';
import 'daily_log_sheet.dart';

const accent = Color(0xFF4F7693);

class DailyTrackerScope extends InheritedWidget {
  const DailyTrackerScope({
    super.key,
    required this.tracker,
    required this.revision,
    required super.child,
  });

  final DailyTracker tracker;

  /// tracker 的变更版本号；供依赖方（dependOnInheritedWidgetOfExactType）感知刷新。
  final int revision;

  /// 只读取、不建立依赖（刷新由顶层 setState 承担）。
  static DailyTracker? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DailyTrackerScope>()?.tracker;

  @override
  bool updateShouldNotify(DailyTrackerScope oldWidget) =>
      tracker != oldWidget.tracker || revision != oldWidget.revision;
}

class SmoothPageTransitionsBuilder extends PageTransitionsBuilder {
  const SmoothPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 用 drive(CurveTween) 而非 CurvedAnimation：后者每帧 build 会重复注册监听且不释放，
    // 长会话下泄漏；Animatable 求值不持有监听，可安全地在每帧调用。
    // fastOutSlowIn 保证返回点击瞬间高速响应、末尾温润减速。
    final curved = animation.drive(CurveTween(curve: Curves.fastOutSlowIn));

    // 微位移（8% 距离）：保留轻微层级方向感，同时干脆利落。
    final slide = Tween<Offset>(
      begin: const Offset(0.08, 0),
      end: Offset.zero,
    ).animate(curved);

    // 伴随平滑透明度淡入淡出，消除生硬感。
    final fade = Tween<double>(begin: 0.0, end: 1.0).animate(curved);

    return SlideTransition(
      position: slide,
      child: FadeTransition(opacity: fade, child: child),
    );
  }
}

class LittleCheckApp extends StatefulWidget {
  const LittleCheckApp({super.key, required this.store});
  final LocalStore store;
  @override
  State<LittleCheckApp> createState() => _LittleCheckAppState();
}

class _LittleCheckAppState extends State<LittleCheckApp>
    with WidgetsBindingObserver {
  final _feedKey = GlobalKey<FeedViewState>();
  final _notesKey = GlobalKey<NotesViewState>();
  int _tab = 0;
  final _pages = PageController();
  double _headerDrag = 0;
  final _navigator = GlobalKey<NavigatorState>();
  late final ExternalDocuments _documents;
  late final DailyTracker _dailyTracker;
  bool _searching = false;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  int _trackerRevision = 0;

  @override
  void initState() {
    super.initState();
    _dailyTracker = DailyTracker(widget.store);
    _dailyTracker.init().then((_) {
      if (!mounted) return;
      _dailyTracker.recordOpen();
      setState(() {});
    });
    _dailyTracker.addListener(_onTrackerUpdate);
    WidgetsBinding.instance.addObserver(this);
    _documents = ExternalDocuments(
      navigator: _navigator,
      store: widget.store,
      onSaved: () => _notesKey.currentState?.reload(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _documents.start();
      final context = _navigator.currentContext;
      if (mounted && context != null && widget.store.fontError != null) {
        showFailure(context, widget.store.fontError!);
      }
    });
  }

  void _onTrackerUpdate() {
    if (mounted) setState(() => _trackerRevision++);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _dailyTracker.recordOpen();
      // 从后台切回时同步磁盘上的笔记与文件夹变化（外部 lck 等改动）。
      _notesKey.currentState?.reload();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dailyTracker.removeListener(_onTrackerUpdate);
    _dailyTracker.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _pages.dispose();
    _documents.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searching = true);
    _searchFocus.requestFocus();
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    _searchController.clear();
    _feedKey.currentState?.setQuery('');
    _notesKey.currentState?.setQuery('');
    setState(() => _searching = false);
  }

  void _onSearchChanged(String query) {
    setState(() {});
    if (_tab == 0) {
      _feedKey.currentState?.setQuery(query);
    } else {
      _notesKey.currentState?.setQuery(query);
    }
  }

  void _selectTab(BuildContext context, int index) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_tab != index) setState(() => _tab = index);
    _pages.animateToPage(
      index,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final palette = AppPalette.values.byName(widget.store.palette);
    final primary = palette.primary(brightness);
    final font = widget.store.font == 'custom'
        ? customFontFamily(
            (widget.store.settings['customFont'] as Map)['hash'] as String,
          )
        : null;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: brightness,
        ).copyWith(
          primary: primary,
          onPrimary: dark ? palette.surface(brightness) : Colors.white,
          surface: palette.surface(brightness),
          onSurface: dark ? const Color(0xFFE4E7EC) : const Color(0xFF262B33),
          onSurfaceVariant: dark
              ? const Color(0xFF969FAA)
              : const Color(0xFF697380),
          surfaceContainerLow: Color.alphaBlend(
            primary.withValues(alpha: dark ? .08 : .045),
            palette.surface(brightness),
          ),
        );
    return ThemeData(
      useMaterial3: true,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: SmoothPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        },
      ),
      fontFamily: font,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(
        color: dark ? const Color(0xFF2B3139) : const Color(0xFFE9ECF0),
        thickness: 1,
        space: 1,
      ),
      textTheme: ThemeData(brightness: brightness).textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
        fontFamily: font,
      ),
      iconTheme: IconThemeData(size: 22, color: scheme.onSurfaceVariant),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: BorderSide(color: scheme.onSurfaceVariant, width: 1.5),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: dark ? scheme.surface : Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: false,
        hintStyle: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
      ),
    );
  }

  Future<void> _settings(BuildContext context) async {
    final sources = widget.store.subscriptions.toString();
    final days = widget.store.feedRetentionDays;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          store: widget.store,
          onAppearanceChanged: () => setState(() {}),
        ),
      ),
    );
    if (mounted) {
      setState(() {});
      await _notesKey.currentState?.reload();
      if (sources != widget.store.subscriptions.toString()) {
        await _feedKey.currentState?.reloadEndpoint(fetch: false);
      } else if (days != widget.store.feedRetentionDays) {
        _feedKey.currentState?.pruneHistory();
      }
    }
  }

  @override
  Widget build(BuildContext context) => DailyTrackerScope(
    tracker: _dailyTracker,
    revision: _trackerRevision,
    child: MaterialApp(
      title: 'Little Check',
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: switch (widget.store.theme) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      },
      home: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          return PopScope(
            canPop: !_searching,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && _searching) {
                _closeSearch();
              }
            },
            child: Scaffold(
              appBar: AppBar(
                elevation: 0,
                scrolledUnderElevation: 0,
                automaticallyImplyLeading: false,
                leading: _searching
                    ? IconButton(
                        tooltip: '退出搜索',
                        icon: const Icon(Icons.arrow_back_rounded),
                        onPressed: _closeSearch,
                      )
                    : null,
                title: _searching
                    ? TextField(
                        controller: _searchController,
                        focusNode: _searchFocus,
                        autofocus: true,
                        style: TextStyle(
                          fontSize: 16,
                          color: theme.colorScheme.onSurface,
                        ),
                        decoration: InputDecoration(
                          hintText: _tab == 0 ? '搜索信息流' : '搜索笔记',
                          hintStyle: TextStyle(
                            fontSize: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          isDense: true,
                        ),
                        onChanged: _onSearchChanged,
                      )
                    : InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => showDailyLogSheet(
                          context,
                          _dailyTracker,
                          onNoteSaved: () => _notesKey.currentState?.reload(),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  const BrandMark(size: 24, animate: true),
                                  if (_dailyTracker.shouldShowBadge)
                                    Positioned(
                                      top: -1,
                                      right: -2,
                                      child: Container(
                                        width: 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.primary,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: theme.colorScheme.surface,
                                            width: 1.5,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'Little Check',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: -.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                actions: [
                  if (_searching) ...[
                    if (_searchController.text.isNotEmpty)
                      IconButton(
                        tooltip: '清空',
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                      ),
                    const SizedBox(width: 4),
                  ] else ...[
                    IconButton(
                      tooltip: '搜索',
                      onPressed: _openSearch,
                      icon: const Icon(Icons.search_rounded),
                    ),
                    IconButton(
                      tooltip: '设置',
                      onPressed: () => _settings(context),
                      icon: const Icon(Icons.tune_rounded),
                    ),
                    const SizedBox(width: 4),
                  ],
                ],
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(48),
                  child: GestureDetector(
                    onHorizontalDragStart: (_) => _headerDrag = 0,
                    onHorizontalDragUpdate: (details) =>
                        _headerDrag += details.primaryDelta ?? 0,
                    onHorizontalDragEnd: (details) {
                      final speed = details.primaryVelocity ?? 0;
                      if (_headerDrag.abs() > 48 || speed.abs() > 100) {
                        _selectTab(
                          context,
                          (_headerDrag.abs() > 48 ? _headerDrag : speed) < 0
                              ? 1
                              : 0,
                        );
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: List.generate(
                          2,
                          (index) => Expanded(
                            child: Semantics(
                              selected: _tab == index,
                              button: true,
                              child: InkWell(
                                onTap: () => _selectTab(context, index),
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  height: 48,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Expanded(
                                        child: Center(
                                          child: Text(
                                            index == 0 ? '信息流' : '笔记',
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                              color: _tab == index
                                                  ? theme.colorScheme.primary
                                                  : theme
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      ),
                                      AnimatedContainer(
                                        duration:
                                            MediaQuery.disableAnimationsOf(
                                              context,
                                            )
                                            ? Duration.zero
                                            : const Duration(milliseconds: 160),
                                        height: 3,
                                        width: _tab == index ? 48 : 0,
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.primary,
                                          borderRadius: BorderRadius.circular(
                                            3,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              body: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: PageView(
                    key: const ValueKey('main-pages'),
                    controller: _pages,
                    allowImplicitScrolling: true,
                    onPageChanged: (index) {
                      setState(() => _tab = index);
                      if (_searching) {
                        _feedKey.currentState?.setQuery(
                          index == 0 ? _searchController.text : '',
                        );
                        _notesKey.currentState?.setQuery(
                          index == 1 ? _searchController.text : '',
                        );
                      }
                    },
                    children: [
                      KeepAlivePage(
                        child: FeedView(
                          key: _feedKey,
                          store: widget.store,
                          onNoteSaved: () => _notesKey.currentState?.reload(),
                          onNextSection: () => _selectTab(context, 1),
                        ),
                      ),
                      KeepAlivePage(
                        child: NotesView(key: _notesKey, store: widget.store),
                      ),
                    ],
                  ),
                ),
              ),
              floatingActionButton: _tab == 1
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        FloatingActionButton.small(
                          tooltip: '刷新笔记',
                          elevation: 2,
                          heroTag: 'notes-refresh',
                          onPressed: () => _notesKey.currentState?.reload(),
                          child: const Icon(Icons.refresh_rounded),
                        ),
                        const SizedBox(height: 12),
                        FloatingActionButton(
                          tooltip: '新建笔记',
                          elevation: 2,
                          heroTag: 'notes-create',
                          onPressed: () => _notesKey.currentState?.createNote(),
                          child: const Icon(Icons.edit_outlined),
                        ),
                      ],
                    )
                  : null,
            ),
          );
        },
      ),
    ),
  );
}

class KeepAlivePage extends StatefulWidget {
  const KeepAlivePage({super.key, required this.child});
  final Widget child;
  @override
  State<KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

String shortTime(DateTime value) {
  final date = value.toLocal();
  final now = DateTime.now();
  final sameDay =
      date.year == now.year && date.month == now.month && date.day == now.day;
  final clock =
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  return sameDay ? clock : '${date.month}月${date.day}日 $clock';
}

void showFailure(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text('$error'), showCloseIcon: true));
}
