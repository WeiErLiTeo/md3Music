import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../main.dart' show appNavigatorKey;
import '../../core/layout/display_space.dart';
import '../../core/services/music_haptics_service.dart';
import '../../core/utils/app_haptics.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/player_artwork_image.dart';
import '../../widgets/player_playlist_view.dart';
import 'full_player_route.dart';
import 'player_page_role.dart';
import 'yt/yt_background.dart';
import 'yt/yt_lyrics_drawer.dart';
import 'yt/yt_main_view.dart';
import 'yt/yt_more_menu.dart';

/// YouTube Music 风格的播放页界面
class FullPlayerYt extends StatefulWidget {
  final bool dockMode;

  const FullPlayerYt({super.key, this.dockMode = false});

  @override
  State<FullPlayerYt> createState() => _FullPlayerYtState();
}

class _FullPlayerYtState extends State<FullPlayerYt>
    with TickerProviderStateMixin {
  bool _isDismissing = false;

  late final AnimationController _lyricsController;
  late final AnimationController _queueController;
  final PlaylistScrollAnchor _playlistScrollAnchor = PlaylistScrollAnchor();
  final GlobalKey<PlayerPlaylistViewState> _playlistKey =
      GlobalKey<PlayerPlaylistViewState>();
  Rect? _measuredCoverRect;
  String? _prewarmedCoverKey;

  DraggablePlayerRoute? _topBarDragRoute;
  double _topBarDragDistance = 0.0;
  double _topBarDragTotal = 0.0;
  double? _topBarDragLastY;
  Duration? _topBarDragLastTime;
  double _topBarDragVelocity = 0.0;

  @override
  void initState() {
    super.initState();
    MusicHapticsService.instance.setPlayerPageActive(true);
    _lyricsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
      reverseDuration: const Duration(milliseconds: 280),
    );
    _queueController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
      reverseDuration: const Duration(milliseconds: 280),
    );
  }

  @override
  void dispose() {
    _lyricsController.dispose();
    _queueController.dispose();
    _playlistScrollAnchor.dispose();
    MusicHapticsService.instance.setPlayerPageActive(false);
    super.dispose();
  }

  DraggablePlayerRoute? get _dragRoute {
    final route = ModalRoute.of(context);
    return route is DraggablePlayerRoute ? route : null;
  }

  PlayerPageRole get _pageRole => PlayerPageRole.of(context);

  bool get _isDragOverlay => _pageRole == PlayerPageRole.dragOverlay;

  void _openLyrics() {
    AppHaptics.lightImpact(HapticCategory.control);
    if (_queueController.value > 0.0) {
      _queueController.animateBack(
        0.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInCubic,
      );
    }
    _lyricsController.animateTo(
      1.0,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );
  }

  void _closeLyrics() {
    AppHaptics.lightImpact(HapticCategory.control);
    _lyricsController.animateBack(
      0.0,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInCubic,
    );
  }

  void _onLyricsDragUpdate(DragUpdateDetails details) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final dragRange = (screenHeight * 0.72).clamp(200.0, 900.0);
    final dy = toDisplaySpaceDelta(context, details.delta).dy;
    _lyricsController.stop();
    _lyricsController.value = (_lyricsController.value - dy / dragRange).clamp(
      0.0,
      1.0,
    );
  }

  void _onLyricsDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0.0;
    if (v < -400.0) {
      _openLyrics();
    } else if (v > 400.0) {
      _closeLyrics();
    } else if (_lyricsController.value >= 0.5) {
      _openLyrics();
    } else {
      _closeLyrics();
    }
  }

  void _openQueue() {
    AppHaptics.lightImpact(HapticCategory.control);
    if (_lyricsController.value > 0.0) {
      _lyricsController.animateBack(
        0.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInCubic,
      );
    }
    _queueController.animateTo(
      1.0,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );
  }

  void _closeQueue() {
    AppHaptics.lightImpact(HapticCategory.control);
    _queueController.animateBack(
      0.0,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInCubic,
    );
  }

  void _onQueueDragUpdate(DragUpdateDetails details) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final dragRange = (screenHeight * 0.72).clamp(200.0, 900.0);
    final dy = toDisplaySpaceDelta(context, details.delta).dy;
    _queueController.stop();
    _queueController.value = (_queueController.value - dy / dragRange).clamp(
      0.0,
      1.0,
    );
  }

  void _onQueueDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0.0;
    if (v < -400.0) {
      _openQueue();
    } else if (v > 400.0) {
      _closeQueue();
    } else if (_queueController.value >= 0.5) {
      _openQueue();
    } else {
      _closeQueue();
    }
  }

  void _onTopBarDragStart(DragStartDetails details) {
    _isDismissing = false;
    final route = ModalRoute.of(context);
    if (route is! DraggablePlayerRoute) return;
    _topBarDragRoute = route;
    route.beginDrag();
    route.controller.value = 1.0;
    final total = route.dragOriginTop ?? playerDragOriginTop;
    _topBarDragTotal = total > 0 ? total : MediaQuery.sizeOf(context).height;
    route.topBarDragging = true;
    route.topBarDragTotal = _topBarDragTotal;
    _topBarDragDistance = 0.0;
    _topBarDragLastY = toDisplaySpace(context, details.globalPosition).dy;
    _topBarDragLastTime = null;
    _topBarDragVelocity = 0.0;
  }

  void _onTopBarDragUpdate(DragUpdateDetails details) {
    final route = _topBarDragRoute;
    if (route == null) return;
    _topBarDragDistance =
        (_topBarDragDistance + toDisplaySpaceDelta(context, details.delta).dy)
            .clamp(0.0, double.infinity);
    final ts = details.sourceTimeStamp;
    if (ts != null && _topBarDragLastTime != null && _topBarDragLastY != null) {
      final dt = (ts - _topBarDragLastTime!).inMicroseconds / 1e6;
      if (dt > 0) {
        _topBarDragVelocity =
            (toDisplaySpace(context, details.globalPosition).dy -
                _topBarDragLastY!) /
            dt;
      }
    }
    _topBarDragLastY = toDisplaySpace(context, details.globalPosition).dy;
    _topBarDragLastTime = ts;
    final total = _topBarDragTotal;
    if (total <= 0) return;
    final progress = (1.0 - _topBarDragDistance / total).clamp(0.0, 1.0);
    route.controller.stop();
    route.controller.value = progress;
  }

  void _onTopBarDragEnd(DragEndDetails details) {
    final route = _topBarDragRoute;
    _topBarDragRoute = null;
    if (route == null) return;
    route.topBarDragging = false;
    final threshold =
        MediaQuery.sizeOf(context).height * kPlayerExpandDistanceRatio;
    final downVelocity = details.primaryVelocity ?? _topBarDragVelocity;
    final collapse =
        downVelocity >= -kPlayerPullBackVelocityThreshold &&
        (_topBarDragDistance >= threshold ||
            downVelocity > kPlayerFlingVelocityThreshold);
    if (collapse) {
      AppHaptics.lightImpact(HapticCategory.gesture);
      route.dismiss();
    } else {
      _isDismissing = false;
      route.settleToFull();
    }
  }

  void _onTopBarDragCancel() {
    _isDismissing = false;
    final route = _topBarDragRoute;
    _topBarDragRoute = null;
    if (route == null) return;
    route.topBarDragging = false;
    if (route.controller.value < 1.0) {
      route.settleToFull();
    } else {
      route.topBarDragTotal = null;
    }
  }

  void _collapseByButton() {
    if (widget.dockMode) return;
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      _isDismissing = true;
      route.dismiss();
    } else if (route == null) {
      _isDismissing = true;
      playerDragActive.value = false;
      playerExpansion.value = 0.0;
    } else {
      Navigator.of(context).maybePop();
    }
  }

  bool _handleSystemBack() {
    if (_isDragOverlay) return false;
    if (_playlistKey.currentState?.exitEditModeIfActive() ?? false) {
      return true;
    }
    if (_lyricsController.value > 0.01 || _lyricsController.isAnimating) {
      _closeLyrics();
      return true;
    }
    if (_queueController.value > 0.01 || _queueController.isAnimating) {
      _closeQueue();
      return true;
    }
    if (widget.dockMode) return false;
    if (!_isDismissing) {
      _collapseByButton();
    }
    return true;
  }

  NavigatorState? _pageNavigator(BuildContext context) {
    if (widget.dockMode) return appNavigatorKey.currentState;
    return Navigator.maybeOf(context);
  }

  void _pushOverPlayer(Route<dynamic> pageRoute) {
    _pageNavigator(context)?.push(pageRoute);
  }

  void _dismissAndPush(Route<dynamic> pageRoute) {
    final navigatorState = _pageNavigator(context);
    if (widget.dockMode) {
      navigatorState?.push(pageRoute);
      return;
    }
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      _isDismissing = true;
      route.dismiss();
      Future.delayed(const Duration(milliseconds: 300), () {
        navigatorState?.push(pageRoute);
      });
    } else {
      navigatorState?.push(pageRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentSong = context.select<PlayerProvider, Song?>(
      (p) => p.currentSong,
    );

    if (currentSong == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text('未在播放', style: TextStyle(color: Colors.white70)),
        ),
      );
    }

    final resolvedSong = YtMoreMenu.resolveMatchedSong(currentSong);
    final safeTop = MediaQuery.paddingOf(context).top;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final screenSize = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);

    final Listenable overlayExpansion = Listenable.merge([
      _lyricsController,
      _queueController,
    ]);

    Widget page = Scaffold(
      backgroundColor: const Color(0xFF030303),
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Builder(
              builder: (context) {
                final isPlaying = context.select<PlayerProvider, bool>(
                  (p) => p.isPlaying,
                );
                final useArtistPhoto = context.select<ThemeProvider, bool>(
                  (p) => p.useArtistPhotoBackground,
                );
                return YtBackground(
                  song: resolvedSong,
                  isPlaying: isPlaying,
                  useArtistPhoto: useArtistPhoto,
                );
              },
            ),
          ),
          // 主界面层：随歌词抽屉或播放列表抽屉展开淡出并轻微上移
          AnimatedBuilder(
            animation: overlayExpansion,
            child: RepaintBoundary(
              child: YtMainView(
                song: currentSong,
                dockMode: widget.dockMode,
                lyricsExpansion: _lyricsController,
                queueController: _queueController,
                onCollapse: _collapseByButton,
                onOpenLyrics: _openLyrics,
                onCoverRectMeasured: (rect) {
                  _measuredCoverRect = rect;
                },
                onPushPage: _pushOverPlayer,
                onDismissAndPush: _dismissAndPush,
                onDragStart: widget.dockMode ? null : _onTopBarDragStart,
                onDragUpdate: widget.dockMode ? null : _onTopBarDragUpdate,
                onDragEnd: widget.dockMode ? null : _onTopBarDragEnd,
                onDragCancel: widget.dockMode ? null : _onTopBarDragCancel,
              ),
            ),
            builder: (context, mainViewChild) {
              final t = math
                  .max(_lyricsController.value, _queueController.value)
                  .clamp(0.0, 1.0);
              final mainOpacity = (1.0 - t * 1.6).clamp(0.0, 1.0);
              return IgnorePointer(
                ignoring: t > 0.05,
                child: Opacity(
                  opacity: mainOpacity,
                  child: Transform.translate(
                    offset: Offset(0, -24.0 * t),
                    child: mainViewChild,
                  ),
                ),
              );
            },
          ),
          if (!_isDragOverlay) ...[
            // 歌词抽屉层：支持点击展开与跟手上下拖拽
            Positioned.fill(
              child: YtLyricsDrawer(
                expansion: _lyricsController,
                song: resolvedSong,
                onClose: _closeLyrics,
                onVerticalDragUpdate: _onLyricsDragUpdate,
                onVerticalDragEnd: _onLyricsDragEnd,
              ),
            ),
            // 播放列表抽屉层（1:1 复刻歌词抽屉展开动画：共用顶部 MiniBar 与悬浮封面飞行缩放）
            Positioned.fill(
              child: YtQueueDrawer(
                expansion: _queueController,
                song: resolvedSong,
                scrollAnchor: _playlistScrollAnchor,
                playlistKey: _playlistKey,
                onClose: _closeQueue,
                onVerticalDragUpdate: _onQueueDragUpdate,
                onVerticalDragEnd: _onQueueDragEnd,
              ),
            ),
          ],
          // 悬浮封面层：当歌词抽屉或播放列表抽屉拉开（t > 0.001）时接管，
          // 与主封面共享同一份 1080p PlayerArtworkImage 解码档位与 GPU 纹理，
          // 全程以 Transform 矩阵缩放平移，零二次加载、零布局重算。
          LayoutBuilder(
            builder: (context, constraints) {
              final defaultAvailW = math.max(0.0, screenSize.width - 48.0);
              final defaultAvailH = math.max(
                160.0,
                screenSize.height - safeTop - safeBottom - 52.0 - 24.0 - 280.0,
              );
              final defaultSide = math.min(defaultAvailW, defaultAvailH);
              final fallbackRect = Rect.fromLTWH(
                (screenSize.width - defaultSide) / 2.0,
                safeTop + 52.0 + 32.0,
                defaultSide,
                defaultSide,
              );
              final largeRect = _measuredCoverRect ?? fallbackRect;
              final baseSide = math.max(1.0, largeRect.width);

              final prewarmKey =
                  '${resolvedSong.artworkUri}_${baseSide.round()}_$dpr';
              if (_prewarmedCoverKey != prewarmKey) {
                _prewarmedCoverKey = prewarmKey;
                unawaited(
                  prewarmPlayerArtworkTexture(
                    artworkUri: resolvedSong.artworkUri,
                    settledLogicalWidth: baseSide,
                    devicePixelRatio: dpr,
                  ),
                );
              }

              const double smallSize = 40.0;
              const double smallLeft = 16.0;
              final double smallTop = safeTop + (56.0 - smallSize) / 2.0;

              final Widget sharedCoverSurface = RepaintBoundary(
                child: SizedBox(
                  width: baseSide,
                  height: baseSide,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12.0),
                    child: PlayerArtworkImage(
                      key: ValueKey(
                        'yt_floating_cover_${resolvedSong.id}_${resolvedSong.artworkUri}',
                      ),
                      artworkUri: resolvedSong.artworkUri,
                      fallbackFilePath: resolvedSong.localPath,
                      isFill: true,
                      fit: BoxFit.cover,
                      iconSize: 48,
                      backgroundColor: Colors.white12,
                      iconColor: Colors.white54,
                    ),
                  ),
                ),
              );

              return AnimatedBuilder(
                animation: overlayExpansion,
                child: sharedCoverSurface,
                builder: (context, coverChild) {
                  final t = math
                      .max(_lyricsController.value, _queueController.value)
                      .clamp(0.0, 1.0);
                  final active = t > 0.001;
                  final curLeft = ui.lerpDouble(largeRect.left, smallLeft, t)!;
                  final curTop = ui.lerpDouble(largeRect.top, smallTop, t)!;
                  final curSize = math.max(
                    1.0,
                    ui.lerpDouble(baseSide, smallSize, t)!,
                  );
                  final scale = curSize / baseSide;

                  return Offstage(
                    offstage: !active,
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Transform.translate(
                          offset: Offset(curLeft, curTop),
                          child: Transform.scale(
                            scale: scale,
                            alignment: Alignment.topLeft,
                            child: coverChild,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );

    if (!_isDragOverlay) {
      page = PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _handleSystemBack();
        },
        child: page,
      );
    }

    return PlayerSystemUiScope(
      dragRoute: _dragRoute,
      forceMainStyle: _isDragOverlay || widget.dockMode,
      child: page,
    );
  }
}
