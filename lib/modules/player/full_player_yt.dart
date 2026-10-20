import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/layout/display_space.dart';
import '../../core/services/music_haptics_service.dart';
import '../../core/utils/app_haptics.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import 'full_player_route.dart';
import 'player_page_role.dart';
import 'yt/yt_background.dart';
import 'yt/yt_lyrics_drawer.dart';
import 'yt/yt_main_view.dart';

/// YouTube Music 风格的播放页界面
class FullPlayerYt extends StatefulWidget {
  final bool dockMode;

  const FullPlayerYt({
    super.key,
    this.dockMode = false,
  });

  @override
  State<FullPlayerYt> createState() => _FullPlayerYtState();
}

class _FullPlayerYtState extends State<FullPlayerYt> {
  bool _isDismissing = false;

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
  }

  @override
  void dispose() {
    MusicHapticsService.instance.setPlayerPageActive(false);
    super.dispose();
  }

  DraggablePlayerRoute? get _dragRoute {
    final route = ModalRoute.of(context);
    return route is DraggablePlayerRoute ? route : null;
  }

  PlayerPageRole get _pageRole => PlayerPageRole.of(context);

  bool get _isDragOverlay => _pageRole == PlayerPageRole.dragOverlay;

  void _onTopBarDragStart(DragStartDetails details) {
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
    _topBarDragDistance = (_topBarDragDistance +
            toDisplaySpaceDelta(context, details.delta).dy)
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
    final collapse = downVelocity >= -kPlayerPullBackVelocityThreshold &&
        (_topBarDragDistance >= threshold ||
            downVelocity > kPlayerFlingVelocityThreshold);
    if (collapse) {
      AppHaptics.lightImpact(HapticCategory.gesture);
      _isDismissing = true;
      route.dismiss();
    } else {
      route.settleToFull();
    }
  }

  void _onTopBarDragCancel() {
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

  void _pushOverPlayer(Route<dynamic> pageRoute) {
    Navigator.of(context).push(pageRoute);
  }

  void _dismissAndPush(Route<dynamic> pageRoute) {
    if (widget.dockMode) {
      Navigator.of(context).push(pageRoute);
      return;
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      _isDismissing = true;
      route.dismiss();
      Future.delayed(const Duration(milliseconds: 300), () {
        if (navigator.mounted) {
          navigator.push(pageRoute);
        }
      });
    } else {
      navigator.push(pageRoute);
    }
  }

  void _openLyrics(BuildContext context, Song song) {
    YtLyricsSheet.show(context, song);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    final currentSong = player.currentSong;

    if (currentSong == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            '未在播放',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    Widget page = Scaffold(
      backgroundColor: const Color(0xFF030303),
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: YtBackground(
              song: currentSong,
              isPlaying: player.isPlaying,
              useArtistPhoto: themeProvider.useArtistPhotoBackground,
            ),
          ),
          YtMainView(
            song: currentSong,
            onCollapse: _collapseByButton,
            onOpenLyrics: () => _openLyrics(context, currentSong),
            onPushPage: _pushOverPlayer,
            onDismissAndPush: _dismissAndPush,
            onDragStart: widget.dockMode ? null : _onTopBarDragStart,
            onDragUpdate: widget.dockMode ? null : _onTopBarDragUpdate,
            onDragEnd: widget.dockMode ? null : _onTopBarDragEnd,
            onDragCancel: widget.dockMode ? null : _onTopBarDragCancel,
          ),
        ],
      ),
    );

    if (!_isDragOverlay && !widget.dockMode) {
      page = PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop || _isDismissing) return;
          _collapseByButton();
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
