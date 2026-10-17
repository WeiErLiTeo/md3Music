import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/layout/display_space.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/utils/local_lyric_loader.dart';
import '../../core/widgets/app_background.dart';
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../data/repositories/song_match_repository.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/local_favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/add_to_playlist_dialog.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../widgets/flowing_background.dart';
import '../../widgets/player_playlist_view.dart';
import '../../widgets/player_seek_bar.dart';
import '../../widgets/smart_artwork_image.dart';
import 'player_cover_morph_layer.dart';
import '../album/album_detail_page.dart';
import '../artist/artist_detail_page.dart';
import '../../widgets/apple_lyrics/apple_lyrics_view.dart';
import '../settings/equalizer_settings_page.dart';
import 'full_player_route.dart';
import 'mv_player_page.dart';
import 'sleep_timer_sheet.dart';
import 'song_info_page.dart';
import 'speed_picker_sheet.dart';

/// YouTube Music 风格的播放页界面
class FullPlayerYt extends StatefulWidget {
  const FullPlayerYt({super.key, this.dockMode = false});

  /// 车机模式常驻面板模式
  final bool dockMode;

  @override
  State<FullPlayerYt> createState() => _FullPlayerYtState();
}

class _FullPlayerYtState extends State<FullPlayerYt> {
  final PlaylistScrollAnchor _playlistScrollAnchor = PlaylistScrollAnchor();

  DraggablePlayerRoute? _topBarDragRoute;
  double _topBarDragDistance = 0.0;
  double _topBarDragTotal = 0.0;
  double? _topBarDragLastY;
  Duration? _topBarDragLastTime;
  double _topBarDragVelocity = 0.0;
  bool _isDismissing = false;

  Duration? _optimisticSeekPosition;
  Timer? _seekTimer;

  @override
  void dispose() {
    _playlistScrollAnchor.dispose();
    _seekTimer?.cancel();
    super.dispose();
  }

  DraggablePlayerRoute? get _dragRoute {
    final route = ModalRoute.of(context);
    return route is DraggablePlayerRoute ? route : null;
  }

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
      _isDismissing = true;
      Navigator.of(context).maybePop();
    }
  }

  void _showMoreMenu(BuildContext rootContext) {
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    if (song == null) return;

    final albumTitle = song.album.isEmpty ? '查看专辑' : '查看专辑：${song.album}';
    final artistTitle = song.artist.isEmpty ? '查看歌手' : '查看歌手：${song.artist}';

    showModalBottomSheet(
      context: rootContext,
      isScrollControlled: true,
      backgroundColor: Theme.of(rootContext).colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (song.isOnline == true)
                  ListTile(
                    leading: const Icon(Icons.music_video_outlined),
                    title: const Text('查看 MV'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      if (rootContext.mounted) {
                        Navigator.of(rootContext).push(
                          MaterialPageRoute(
                            builder: (_) => MvPlayerPage(song: song),
                          ),
                        );
                      }
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.album),
                  title: Text(
                    albumTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      _navigateToAlbum(song);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(
                    artistTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      _navigateToArtist(song);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add),
                  title: const Text('添加到歌单'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      showAddToPlaylistDialog(rootContext, song);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.graphic_eq),
                  title: const Text('均衡器与音效设置'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      Navigator.of(rootContext).push(
                        MaterialPageRoute(
                          builder: (_) => const EqualizerSettingsPage(),
                        ),
                      );
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.speed),
                  title: const Text('播放速度'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      showSpeedPickerDialog(
                        context: rootContext,
                        currentSpeed: player.speed,
                        onSelected: (speed) => player.setSpeed(speed),
                      );
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('睡眠定时'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      showSleepTimerSheet(
                        context: rootContext,
                        player: player,
                      );
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('歌曲信息'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      Navigator.of(rootContext).push(
                        MaterialPageRoute(builder: (_) => const SongInfoPage()),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _navigateToAlbum(Song song) {
    if (song.album.isNotEmpty) {
      final albumObj = Album(
        id: song.albumId ?? '',
        name: song.album,
        artist: song.artist,
        artworkUri: song.artworkUri,
        songCount: 0,
      );
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AlbumDetailPage(album: albumObj)),
      );
    }
  }

  void _navigateToArtist(Song song) {
    if (song.artistId != null && song.artistId!.isNotEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ArtistDetailPage(
            artistId: song.artistId!,
            artistName: song.artist,
          ),
        ),
      );
    }
  }

  void _showLyricsModalSheet(BuildContext context, Song song) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _YtLyricsSheet(song: song),
    );
  }

  double _queueDragDistance = 0.0;
  bool _isQueueDrawerOpen = false;

  void _showQueueDrawer(BuildContext context) {
    if (_isQueueDrawerOpen) return;
    _isQueueDrawerOpen = true;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        final screenHeight = MediaQuery.of(sheetContext).size.height;
        return Container(
          height: screenHeight * 0.72,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainer,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '播放的音乐来自 · 播放队列',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    InkWell(
                      onTap: () {
                        final currentSong = sheetContext
                            .read<PlayerProvider>()
                            .currentSong;
                        if (currentSong != null && sheetContext.mounted) {
                          showAddToPlaylistDialog(sheetContext, currentSong);
                        }
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.playlist_add,
                              size: 16,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '保存',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: PlayerPlaylistView(
                  scrollAnchor: _playlistScrollAnchor,
                  useAmColors: true,
                  useDisplayName: true,
                ),
              ),
            ],
          ),
        );
      },
    ).whenComplete(() {
      _isQueueDrawerOpen = false;
    });
  }


  Widget _buildCapsuleButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color iconColor = Colors.white,
  }) {
    return InkWell(
      onTap: () {
        AppHaptics.lightImpact(HapticCategory.control);
        onTap();
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: iconColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PlayerSystemUiScope(
      dragRoute: _dragRoute,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop || _isDismissing) return;
          if (widget.dockMode) return;
          _collapseByButton();
        },
        child: Consumer<PlayerProvider>(
          builder: (context, playerProvider, _) {
            final song = playerProvider.currentSong;
            final colorScheme = Theme.of(context).colorScheme;

            if (song == null) {
              return Scaffold(
                backgroundColor: colorScheme.surface,
                appBar: AppBar(leading: const BackButton()),
                body: const Center(child: Text('暂无播放曲目')),
              );
            }

            final isOnline = song.isOnline;
            final isFavorited = isOnline
                ? context.watch<FavoritesProvider>().isFavorite(song.id)
                : context.watch<LocalFavoritesProvider>().isFavorite(song.id);

            return Scaffold(
              backgroundColor: Colors.black,
              body: Stack(
                children: [
                  if (LyricPreferences.instance.useFlowingBackground)
                    Positioned.fill(
                      child: FlowingBackground(
                        artworkUrl: song.artworkUri,
                        isPlaying: playerProvider.isPlaying,
                      ),
                    )
                  else
                    const Positioned.fill(child: AppBackground()),
                  SafeArea(
                    child: Column(
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onVerticalDragStart: widget.dockMode
                              ? null
                              : _onTopBarDragStart,
                          onVerticalDragUpdate: widget.dockMode
                              ? null
                              : _onTopBarDragUpdate,
                          onVerticalDragEnd: widget.dockMode
                              ? null
                              : _onTopBarDragEnd,
                          onVerticalDragCancel: widget.dockMode
                              ? null
                              : _onTopBarDragCancel,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.expand_more,
                                    size: 28,
                                    color: Colors.white,
                                  ),
                                  onPressed: _collapseByButton,
                                ),
                                const Spacer(),
                                IconButton(
                                  icon: const Icon(
                                    Icons.more_vert,
                                    size: 24,
                                    color: Colors.white,
                                  ),
                                  onPressed: () => _showMoreMenu(context),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24.0),
                              child: AspectRatio(
                                aspectRatio: 1.0,
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.4,
                                        ),
                                        blurRadius: 16,
                                        offset: const Offset(0, 8),
                                      ),
                                    ],
                                  ),
                                  child: PlayerCoverSlot(
                                    songId: song.id,
                                    artworkUri: song.artworkUri,
                                    fallbackFilePath: song.localPath,
                                    iconSize: 48,
                                    placeholderColor: Colors.white12,
                                    shadowColor: Colors.black45,
                                    eligible: () => true,
                                    settledScale: 1.0,
                                    settledAnchor: Alignment.center,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(16),
                                      child: SmartArtworkImage(
                                        artworkUri: song.artworkUri,
                                        size: 320,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24.0,
                            vertical: 8.0,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      song.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  if (song.album.isNotEmpty)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.chevron_right,
                                        color: Colors.white70,
                                      ),
                                      onPressed: () => _navigateToAlbum(song),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              GestureDetector(
                                onTap: () => _navigateToArtist(song),
                                child: Text(
                                  song.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24.0),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                _buildCapsuleButton(
                                  icon: isFavorited
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  iconColor: isFavorited
                                      ? Colors.redAccent
                                      : Colors.white,
                                  label: '收藏',
                                  onTap: () {
                                    if (isOnline) {
                                      context
                                          .read<FavoritesProvider>()
                                          .toggleFavorite(song);
                                    } else {
                                      context
                                          .read<LocalFavoritesProvider>()
                                          .toggleFavorite(song.id);
                                    }
                                  },
                                ),
                                const SizedBox(width: 10),
                                _buildCapsuleButton(
                                  icon: Icons.subtitles_outlined,
                                  label: '歌词',
                                  onTap: () =>
                                      _showLyricsModalSheet(context, song),
                                ),
                                const SizedBox(width: 10),
                                _buildCapsuleButton(
                                  icon: Icons.playlist_add,
                                  label: '保存',
                                  onTap: () =>
                                      showAddToPlaylistDialog(context, song),
                                ),
                                const SizedBox(width: 10),
                                _buildCapsuleButton(
                                  icon: Icons.graphic_eq,
                                  label: '音效',
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const EqualizerSettingsPage(),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20.0),
                          child: ValueListenableBuilder<Duration>(
                            valueListenable: playerProvider.positionNotifier,
                            builder: (context, position, _) {
                              final optimistic = _optimisticSeekPosition;
                              final displayPos = optimistic ?? position;
                              return PlayerSeekBar(
                                position: displayPos,
                                duration: playerProvider.duration ?? Duration.zero,
                                isPlaying: playerProvider.isPlaying,
                                speed: playerProvider.speed,
                                activeColor: Colors.white,
                                inactiveColor: Colors.white24,
                                labelColor: Colors.white70,
                                onSeekEnd: (pos) {
                                  setState(() {
                                    _optimisticSeekPosition = pos;
                                  });
                                  playerProvider.seek(pos);
                                  _seekTimer?.cancel();
                                  _seekTimer = Timer(
                                    const Duration(milliseconds: 800),
                                    () {
                                      if (mounted && _optimisticSeekPosition != null) {
                                        setState(() {
                                          _optimisticSeekPosition = null;
                                        });
                                      }
                                    },
                                  );
                                },
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24.0,
                            vertical: 8.0,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.shuffle, size: 22),
                                color: playerProvider.shuffleEnabled
                                    ? colorScheme.primary
                                    : Colors.white70,
                                onPressed: () {
                                  AppHaptics.lightImpact(
                                    HapticCategory.transport,
                                  );
                                  playerProvider.toggleShuffle();
                                },
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.skip_previous,
                                  size: 36,
                                  color: Colors.white,
                                ),
                                onPressed: () {
                                  AppHaptics.click(HapticCategory.transport);
                                  playerProvider.previous();
                                },
                              ),
                              GestureDetector(
                                onTap: () {
                                  AppHaptics.click(HapticCategory.transport);
                                  if (playerProvider.isPlaying) {
                                    playerProvider.pause();
                                  } else {
                                    playerProvider.resume();
                                  }
                                },
                                child: Container(
                                  width: 64,
                                  height: 64,
                                  decoration: const BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    playerProvider.isPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                    size: 38,
                                    color: Colors.black,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.skip_next,
                                  size: 36,
                                  color: Colors.white,
                                ),
                                onPressed: () {
                                  AppHaptics.click(HapticCategory.transport);
                                  playerProvider.next();
                                },
                              ),
                              IconButton(
                                icon: Icon(
                                  playerProvider.loopMode == AppLoopMode.one
                                      ? Icons.repeat_one
                                      : Icons.repeat,
                                  size: 24,
                                ),
                                color:
                                    playerProvider.loopMode != AppLoopMode.off
                                    ? colorScheme.primary
                                    : Colors.white70,
                                onPressed: () {
                                  AppHaptics.lightImpact(
                                    HapticCategory.transport,
                                  );
                                  playerProvider.toggleLoopMode();
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _showQueueDrawer(context),
                          onVerticalDragStart: (_) {
                            _queueDragDistance = 0.0;
                          },
                          onVerticalDragUpdate: (details) {
                            _queueDragDistance -= details.delta.dy;
                            if (_queueDragDistance > 30) {
                              _queueDragDistance = -999.0;
                              _showQueueDrawer(context);
                            }
                          },
                          onVerticalDragEnd: (details) {
                            if (details.primaryVelocity != null &&
                                details.primaryVelocity! < -150) {
                              _showQueueDrawer(context);
                            }
                          },
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 16,
                            ),
                            color: Colors.transparent,
                            child: Column(
                              children: [
                                Container(
                                  width: 36,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: Colors.white38,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  '播放的音乐来自 / 播放队列',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.white70,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _YtLyricsSheet extends StatefulWidget {
  final Song song;
  const _YtLyricsSheet({required this.song});

  @override
  State<_YtLyricsSheet> createState() => _YtLyricsSheetState();
}

class _YtLyricsSheetState extends State<_YtLyricsSheet> {
  bool _loading = true;
  List<LyricLine> _parsedLines = const [];
  String? _loadedSongId;
  String? _fetchingSongId;

  @override
  void initState() {
    super.initState();
    _loadLyricsFor(widget.song);
  }

  Future<void> _loadLyricsFor(Song song) async {
    if (_loadedSongId == song.id || _fetchingSongId == song.id) return;
    _fetchingSongId = song.id;
    _loadedSongId = song.id;

    setState(() {
      _loading = true;
      _parsedLines = const [];
    });

    String lyricText = '';
    String? translationText;
    String? romaText;

    if (!song.isOnline) {
      final localPath = song.localPath;
      if (localPath != null && localPath.isNotEmpty) {
        final embedded = await LocalLyricLoader.loadForAudioAsync(localPath);
        if (embedded != null && embedded.isNotEmpty) {
          lyricText = embedded;
        }
      }
    }

    if (lyricText.isEmpty) {
      try {
        await SongMatchRepository().ensureLoaded();
        if (!mounted) return;
        final matchInfo = !song.isOnline
            ? SongMatchRepository().get(song.id)
            : null;
        final kugouProvider = context.read<KugouProvider>();
        final matchedHash = (matchInfo != null && matchInfo.isMatched)
            ? matchInfo.hash
            : null;
        final lyricHash = matchedHash ?? (!song.isOnline ? '' : song.id);
        final searchName = song.artist != '未知艺术家'
            ? '${song.displayName} ${song.artist}'
            : song.displayName;
        final lyric = await kugouProvider.getLyric(
          lyricHash,
          songName: searchName,
        );
        lyricText =
            lyric?.displayKrcLyric ??
            lyric?.displayLrcLyric ??
            lyric?.displayLyric ??
            '';
        translationText = lyric?.translatedContent;
        romaText = lyric?.romaContent;
      } catch (_) {}
    }

    if (!mounted || _loadedSongId != song.id) return;

    if (lyricText.isNotEmpty) {
      final parsed = LyricParserChain.parse(
        lyricText,
        translationText: translationText,
        romaText: romaText,
      );
      setState(() {
        _loading = false;
        _parsedLines = parsed;
      });
    } else {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final player = context.read<PlayerProvider>();
    final currentSong = player.currentSong ?? widget.song;
    if (_loadedSongId != currentSong.id && _fetchingSongId != currentSong.id) {
      scheduleMicrotask(() {
        if (mounted && _loadedSongId != currentSong.id && _fetchingSongId != currentSong.id) {
          _loadLyricsFor(currentSong);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final screenHeight = MediaQuery.of(context).size.height;

    return Container(
      height: screenHeight * 0.78,
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Stack(
        children: [
          Column(
            children: [
              // 顶部 Mini 控制条
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SmartArtworkImage(
                        artworkUri: currentSong.artworkUri,
                        size: 42,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            currentSong.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            currentSong.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        player.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                        size: 32,
                        color: Colors.white,
                      ),
                      onPressed: () {
                        AppHaptics.click(HapticCategory.transport);
                        if (player.isPlaying) {
                          player.pause();
                        } else {
                          player.resume();
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.skip_next,
                        size: 28,
                        color: Colors.white70,
                      ),
                      onPressed: () {
                        AppHaptics.click(HapticCategory.transport);
                        player.next();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
              // 中间 Apple 风格歌词主体
              Expanded(
                child: ValueListenableBuilder<Duration>(
                  valueListenable: player.positionNotifier,
                  builder: (context, position, _) {
                    return AppleLyricsView(
                      lines: _parsedLines,
                      currentTimeMs: position.inMilliseconds,
                      isPlaying: player.isPlaying,
                      playbackNotReady: false,
                      onSeek: (timeMs) => player.seek(Duration(milliseconds: timeMs)),
                      forceDarkBackground: true,
                    );
                  },
                ),
              ),
            ],
          ),
          // 底部悬浮“文A 翻译”药丸按钮
          ListenableBuilder(
            listenable: LyricPreferences.instance,
            builder: (context, _) {
              final showTranslation = LyricPreferences.instance.showTranslation;
              return Positioned(
                bottom: 20,
                left: 0,
                right: 0,
                child: Center(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        AppHaptics.lightImpact(HapticCategory.control);
                        LyricPreferences.instance.setShowTranslation(!showTranslation);
                      },
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.15),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.translate,
                              size: 18,
                              color: showTranslation
                                  ? Colors.white
                                  : Colors.white54,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              showTranslation ? '隐藏翻译' : '文A 翻译',
                              style: TextStyle(
                                color: showTranslation
                                    ? Colors.white
                                    : Colors.white70,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
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
