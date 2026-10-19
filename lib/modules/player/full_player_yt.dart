import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/smart_artwork_image.dart';
import 'full_player_route.dart';
import 'yt/yt_background.dart';
import 'yt/yt_lyrics_drawer.dart';
import 'yt/yt_main_view.dart';

class FullPlayerYt extends StatefulWidget {
  final bool dockMode;

  const FullPlayerYt({
    super.key,
    this.dockMode = false,
  });

  @override
  State<FullPlayerYt> createState() => _FullPlayerYtState();
}

class _FullPlayerYtState extends State<FullPlayerYt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _lyricsController;
  bool _isDismissing = false;

  @override
  void initState() {
    super.initState();
    _lyricsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
  }

  @override
  void dispose() {
    _lyricsController.dispose();
    super.dispose();
  }

  void _collapseByButton() {
    if (widget.dockMode || _isDismissing) return;
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      _isDismissing = true;
      route.dismiss();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _dismissAndPush(Route<dynamic> pageRoute) {
    if (widget.dockMode) {
      Navigator.of(context).push(pageRoute);
      return;
    }
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      route.dismiss();
      Navigator.of(context, rootNavigator: true).push(pageRoute);
    } else {
      Navigator.of(context).push(pageRoute);
    }
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

    final screenSize = MediaQuery.sizeOf(context);
    final screenWidth = screenSize.width;
    final screenHeight = screenSize.height;
    final topInset = MediaQuery.viewPaddingOf(context).top;

    final largeCoverSize = math.min(screenWidth - 48, 340.0);
    final largeLeft = (screenWidth - largeCoverSize) / 2;
    final largeTop = topInset + 56 + 12;

    const smallSize = 42.0;
    const smallLeft = 16.0;
    final smallTop = topInset + (56 - smallSize) / 2;

    final drawerMaxHeight = screenHeight - (topInset + 56);

    return Scaffold(
      backgroundColor: Colors.black,
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
          AnimatedBuilder(
            animation: _lyricsController,
            builder: (context, _) {
              final t = _lyricsController.value;
              final curSize = ui.lerpDouble(largeCoverSize, smallSize, t)!;
              final curLeft = ui.lerpDouble(largeLeft, smallLeft, t)!;
              final curTop = ui.lerpDouble(largeTop, smallTop, t)!;
              final curRadius = ui.lerpDouble(16.0, 6.0, t)!;
              final drawerTop = topInset + 56 + drawerMaxHeight * (1.0 - t);

              return Stack(
                fit: StackFit.expand,
                children: [
                  Opacity(
                    opacity: (1.0 - t).clamp(0.0, 1.0),
                    child: IgnorePointer(
                      ignoring: t > 0.05,
                      child: YtMainView(
                        song: currentSong,
                        largeCoverSize: largeCoverSize,
                        onCollapse: _collapseByButton,
                        onOpenLyrics: () {
                          _lyricsController.animateTo(
                            1.0,
                            curve: Curves.easeOutCubic,
                          );
                        },
                        onPushPage: _dismissAndPush,
                      ),
                    ),
                  ),
                  if (t > 0.001)
                    Positioned(
                      top: drawerTop,
                      left: 0,
                      right: 0,
                      height: drawerMaxHeight,
                      child: YtLyricsDrawer(
                        song: currentSong,
                        onClose: () {
                          _lyricsController.animateTo(
                            0.0,
                            curve: Curves.easeInCubic,
                          );
                        },
                        onVerticalDragUpdate: (details) {
                          final delta = details.primaryDelta ?? 0;
                          if (drawerMaxHeight > 0) {
                            _lyricsController.value = (_lyricsController.value -
                                    delta / drawerMaxHeight)
                                .clamp(0.0, 1.0);
                          }
                        },
                        onVerticalDragEnd: (details) {
                          final velocity = details.primaryVelocity ?? 0;
                          if (velocity > 500 || _lyricsController.value < 0.67) {
                            _lyricsController.animateTo(
                              0.0,
                              curve: Curves.easeOutCubic,
                            );
                          } else {
                            _lyricsController.animateTo(
                              1.0,
                              curve: Curves.easeOutCubic,
                            );
                          }
                        },
                      ),
                    ),
                  if (t > 0.001)
                    Positioned(
                      top: topInset,
                      left: 0,
                      right: 0,
                      height: 56,
                      child: Opacity(
                        opacity: t.clamp(0.0, 1.0),
                        child: IgnorePointer(
                          ignoring: t < 0.8,
                          child: YtMiniBar(
                            song: currentSong,
                            onTap: () {
                              _lyricsController.animateTo(
                                0.0,
                                curve: Curves.easeInCubic,
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: curLeft,
                    top: curTop,
                    width: curSize,
                    height: curSize,
                    child: IgnorePointer(
                      ignoring: t < 0.8,
                      child: GestureDetector(
                        onTap: t > 0.8
                            ? () {
                                _lyricsController.animateTo(
                                  0.0,
                                  curve: Curves.easeInCubic,
                                );
                              }
                            : null,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(curRadius),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: 0.35 * (1.0 - t),
                                ),
                                blurRadius: 20 * (1.0 - t),
                                offset: Offset(0, 10 * (1.0 - t)),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(curRadius),
                            child: SmartArtworkImage(
                              artworkUri: currentSong.artworkUri,
                              size: curSize,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
