import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/app_haptics.dart';
import '../../../data/models/song.dart';
import '../../../providers/favorites_provider.dart';
import '../../../providers/local_favorites_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/add_to_playlist_dialog.dart';
import '../../../widgets/depth_cover_host.dart';
import '../../../widgets/dynamic_cover_view.dart';
import '../../../widgets/marquee_text.dart';
import '../../../widgets/player_artwork_image.dart'
    show isPlayerArtworkReady, preloadPlayerArtwork;
import '../../../widgets/player_playlist_view.dart';
import '../../../widgets/player_seek_bar.dart';
import '../../settings/equalizer_settings_page.dart';
import '../../sheet/song_sheet_sheet.dart';
import '../comments_view.dart';
import '../cover_switch_physics.dart';
import '../player_cover_morph.dart';
import '../player_cover_morph_layer.dart';
import '../player_cover_shadow.dart';
import '../widgets/cover_flip_crossfade.dart';
import '../widgets/cover_switch_pager.dart';
import '../widgets/play_pause_morph_icon.dart';
import '../widgets/song_danmaku_host.dart';
import '../widgets/title_switch_fade.dart';
import 'yt_more_menu.dart';

class YtMainView extends StatefulWidget {
  static final PlaylistScrollAnchor _playlistScrollAnchor =
      PlaylistScrollAnchor();

  final Song song;
  final bool dockMode;
  final Animation<double> lyricsExpansion;
  final VoidCallback onCollapse;
  final VoidCallback onOpenLyrics;
  final ValueChanged<Rect>? onCoverRectMeasured;
  final void Function(Route<dynamic>)? onPushPage;
  final void Function(Route<dynamic>)? onDismissAndPush;
  final GestureDragStartCallback? onDragStart;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;
  final GestureDragCancelCallback? onDragCancel;

  const YtMainView({
    super.key,
    required this.song,
    this.dockMode = false,
    required this.lyricsExpansion,
    required this.onCollapse,
    required this.onOpenLyrics,
    this.onCoverRectMeasured,
    this.onPushPage,
    this.onDismissAndPush,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
  });

  @override
  State<YtMainView> createState() => _YtMainViewState();
}

class _YtMainViewState extends State<YtMainView> {
  final GlobalKey<CoverSwitchPagerState> _coverPagerKey =
      GlobalKey<CoverSwitchPagerState>();
  PlayerProvider? _playerProvider;
  String? _lastSongId;
  int? _lastPagerIndex;
  int _coverFlipDirection = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final player = context.read<PlayerProvider>();
    if (_playerProvider != player) {
      _playerProvider?.removeListener(_onPlayerChanged);
      _playerProvider = player;
      _lastSongId = player.currentSong?.id;
      _lastPagerIndex = player.currentIndex;
      _playerProvider?.addListener(_onPlayerChanged);
    }
  }

  @override
  void dispose() {
    _playerProvider?.removeListener(_onPlayerChanged);
    super.dispose();
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    final player = _playerProvider;
    if (player == null) return;
    final song = player.currentSong;
    final slideDirection = coverSlideDirectionForIndexChange(
      fromIndex: _lastPagerIndex ?? player.currentIndex,
      toIndex: player.currentIndex,
      playlistLength: player.playlist.length,
    );
    _lastPagerIndex = player.currentIndex;
    if (song != null && song.id != _lastSongId) {
      _lastSongId = song.id;
      if (slideDirection != 0) {
        _coverFlipDirection = slideDirection;
      }
      final pager = _coverPagerKey.currentState;
      if (pager != null && pager.hasPendingCommit) {
        pager.rebase(slideDirection);
      } else if (slideDirection != 0) {
        pager?.playChange(slideDirection);
      } else {
        pager?.resetToIdle();
      }
      final playlist = player.playlist;
      final idx = player.currentIndex;
      if (idx > 0) preloadPlayerArtwork(playlist[idx - 1].artworkUri);
      if (idx < playlist.length - 1) {
        preloadPlayerArtwork(playlist[idx + 1].artworkUri);
      }
    }
  }

  Song? _pagerNeighborSong(PlayerProvider player, int delta) {
    final list = player.playlist;
    if (list.length < 2) return null;
    final index = player.currentIndex + delta;
    if (index < 0) {
      return player.loopMode == AppLoopMode.all ? list[list.length - 1] : null;
    }
    if (index >= list.length) {
      return player.loopMode == AppLoopMode.all ? list[0] : null;
    }
    return list[index];
  }

  void _onCoverPagerCommit(CoverSwitchIntent intent) {
    AppHaptics.click(HapticCategory.transport);
    final player = context.read<PlayerProvider>();
    switch (intent) {
      case CoverSwitchIntent.previous:
        player.previous();
      case CoverSwitchIntent.next:
        player.next();
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final isOnline = song.isOnline;
    final isFavorited = isOnline
        ? context.select<FavoritesProvider, bool>((p) => p.isFavorite(song.id))
        : context.select<LocalFavoritesProvider, bool>(
            (p) => p.isFavorite(song.id),
          );

    final resolvedSong = YtMoreMenu.resolveMatchedSong(song);
    final safeTop = MediaQuery.paddingOf(context).top;

    return SafeArea(
      top: true,
      bottom: true,
      child: Column(
        children: [
          _buildTopBar(context, resolvedSong),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final availW = math.max(0.0, constraints.maxWidth - 48.0);
                final availH = math.max(0.0, constraints.maxHeight - 16.0);
                final side = math.min(availW, availH);
                final left = (constraints.maxWidth - side) / 2.0;
                final top = safeTop + 56.0 + 8.0 + (availH - side) / 2.0;
                if (side > 0) {
                  widget.onCoverRectMeasured?.call(
                    Rect.fromLTWH(left, top, side, side),
                  );
                }
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24.0,
                      vertical: 8.0,
                    ),
                    child: _buildCover(context, resolvedSong, side),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 6.0,
            ),
            child: _buildTitleAndArtist(context, resolvedSong),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
            ),
            child: _buildCapsuleRow(
              context,
              resolvedSong,
              isFavorited,
              isOnline,
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 20.0,
            ),
            child: _buildSeekBar(context, resolvedSong),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 6.0,
            ),
            child: _buildTransportControls(context),
          ),
          const SizedBox(height: 6),
          _buildQueueHandle(context),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, Song resolvedSong) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: widget.onDragStart,
      onVerticalDragUpdate: widget.onDragUpdate,
      onVerticalDragEnd: widget.onDragEnd,
      onVerticalDragCancel: widget.onDragCancel,
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(
                  Icons.keyboard_arrow_down,
                  color: Colors.white,
                  size: 30,
                ),
                onPressed: widget.onCollapse,
              ),
              const Spacer(),
              Container(
                height: 32,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: 28,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.headphones_rounded,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: widget.onOpenLyrics,
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: const Center(
                          child: Icon(
                            Icons.subtitles_outlined,
                            size: 16,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(
                  Icons.more_vert,
                  color: Colors.white,
                  size: 24,
                ),
                onPressed: () => YtMoreMenu.show(
                  context,
                  resolvedSong,
                  onPushPage: widget.onPushPage,
                  onDismissAndPush: widget.onDismissAndPush,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPagerPage(Song? neighborSong) {
    if (neighborSong == null) return const SizedBox.shrink();
    final resolved = YtMoreMenu.resolveMatchedSong(neighborSong);
    return DepthCoverHost(
      artworkUri: resolved.artworkUri,
      fallbackFilePath: resolved.localPath,
      fit: BoxFit.cover,
      iconSize: 48,
      backgroundColor: Colors.white12,
      iconColor: Colors.white54,
    );
  }

  Widget _buildCurrentCoverPage(Song resolvedSong) {
    final artwork = DepthCoverHost(
      artworkUri: resolvedSong.artworkUri,
      fallbackFilePath: resolvedSong.localPath,
      fit: BoxFit.cover,
      iconSize: 48,
      backgroundColor: Colors.white12,
      iconColor: Colors.white54,
    );
    return CoverFlipCrossfade(
      version: resolvedSong.artworkUri,
      fallbackFilePath: resolvedSong.localPath,
      iconSize: 48,
      radius: kCoverMorphFullRadius,
      direction: _coverFlipDirection,
      readinessProbe: (uri, width, dpr) => isPlayerArtworkReady(
        artworkUri: uri,
        settledLogicalWidth: width,
        devicePixelRatio: dpr,
      ),
      child: resolvedSong.isOnline
          ? Stack(
              fit: StackFit.expand,
              children: [
                artwork,
                DynamicCoverView(song: resolvedSong, enabled: true),
              ],
            )
          : artwork,
    );
  }

  /// 封面区域：全面复用 PlayerCoverSlot + SongDanmakuHost + PlayerCoverShadow +
  /// CoverSwitchPager + CoverFlipCrossfade；仅在歌词抽屉拉开过程中交由外层插值封面接管。
  Widget _buildCover(BuildContext context, Song resolvedSong, double side) {
    final player = context.watch<PlayerProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    final prevSong = _pagerNeighborSong(player, -1);
    final nextSong = _pagerNeighborSong(player, 1);

    final coverContent = SizedBox(
      width: side,
      height: side,
      child: PlayerCoverSlot(
        songId: resolvedSong.id,
        artworkUri: resolvedSong.artworkUri,
        fallbackFilePath: resolvedSong.localPath,
        iconSize: 48,
        placeholderColor: Colors.white12,
        shadowColor: colorScheme.shadow,
        eligible: () =>
            !widget.dockMode && widget.lyricsExpansion.value <= 0.001,
        settledScale: 1.0,
        settledAnchor: Alignment.center,
        child: SongDanmakuHost(
          cover: PlayerCoverShadow.wrap(
            shadowColor: colorScheme.shadow,
            child: CoverSwitchPager(
              key: _coverPagerKey,
              side: side,
              radius: kCoverMorphFullRadius,
              pages: [
                _buildPagerPage(prevSong),
                _buildCurrentCoverPage(resolvedSong),
                _buildPagerPage(nextSong),
              ],
              canGoPrevious: prevSong != null,
              canGoNext: nextSong != null,
              onCommit: _onCoverPagerCommit,
            ),
          ),
        ),
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: widget.onDragStart,
      onVerticalDragUpdate: widget.onDragUpdate,
      onVerticalDragEnd: widget.onDragEnd,
      onVerticalDragCancel: widget.onDragCancel,
      child: AnimatedBuilder(
        animation: widget.lyricsExpansion,
        child: coverContent,
        builder: (context, child) {
          // 当歌词抽屉拉开（t > 0.001）时隐藏原位封面，由悬浮缩放封面接管过渡到左上角 40x40
          final drawerActive = widget.lyricsExpansion.value > 0.001;
          return Opacity(
            opacity: drawerActive ? 0.0 : 1.0,
            child: IgnorePointer(
              ignoring: drawerActive,
              child: child,
            ),
          );
        },
      ),
    );
  }

  Widget _buildTitleAndArtist(BuildContext context, Song song) {
    final title = song.displayName;
    final artist = song.artist.isNotEmpty ? song.artist : '未知艺术家';
    const titleStyle = TextStyle(
      color: Colors.white,
      fontSize: 24,
      fontWeight: FontWeight.bold,
      letterSpacing: -0.3,
    );
    final subtitleStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.72),
      fontSize: 15,
      fontWeight: FontWeight.w400,
    );

    final titleBlock = Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              final push =
                  widget.onDismissAndPush ??
                  widget.onPushPage ??
                  Navigator.of(context).push;
              YtMoreMenu.navigateToAlbum(context, song, push);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: GentleScrollingText(
                    title,
                    style: titleStyle,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.chevron_right,
                  color: Colors.white70,
                  size: 22,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () {
              final push =
                  widget.onDismissAndPush ??
                  widget.onPushPage ??
                  Navigator.of(context).push;
              YtMoreMenu.navigateToArtist(context, song, push);
            },
            child: Text(
              artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: subtitleStyle,
            ),
          ),
        ],
      ),
    );

    return PlayerTitleSlot(
      title: title,
      subtitle: artist,
      titleStyle: titleStyle,
      subtitleStyle: subtitleStyle,
      align: Alignment.centerLeft,
      eligible: () =>
          !widget.dockMode && widget.lyricsExpansion.value <= 0.001,
      child: TitleSwitchFade(
        version: song.id,
        align: Alignment.centerLeft,
        child: titleBlock,
      ),
    );
  }

  Widget _buildCapsuleRow(
    BuildContext context,
    Song song,
    bool isFavorited,
    bool isOnline,
  ) {
    final hasSheet =
        song.albumAudioId != null && song.albumAudioId!.isNotEmpty;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          _buildCapsuleButton(
            icon: isFavorited ? Icons.favorite : Icons.favorite_border,
            iconColor: isFavorited ? Colors.redAccent : Colors.white,
            label: '收藏',
            onTap: () {
              if (isOnline) {
                context.read<FavoritesProvider>().toggleFavorite(song);
              } else {
                context.read<LocalFavoritesProvider>().toggleFavorite(song.id);
              }
            },
          ),
          const SizedBox(width: 10),
          _buildCapsuleButton(
            icon: Icons.subtitles_outlined,
            label: '歌词',
            onTap: widget.onOpenLyrics,
          ),
          const SizedBox(width: 10),
          _buildCapsuleButton(
            icon: Icons.comment_outlined,
            label: '评论',
            onTap: () => showSongCommentsSheet(context, song),
          ),
          const SizedBox(width: 10),
          _buildCapsuleButton(
            icon: Icons.playlist_add,
            label: '保存',
            onTap: () => showAddToPlaylistDialog(context, song),
          ),
          if (hasSheet) ...[
            const SizedBox(width: 10),
            _buildCapsuleButton(
              icon: Icons.library_music_outlined,
              label: '曲谱',
              onTap: () => showSongSheetSheet(context, song),
            ),
          ],
          const SizedBox(width: 10),
          _buildCapsuleButton(
            icon: Icons.graphic_eq,
            label: '音效',
            onTap: () {
              final push = widget.onPushPage ?? Navigator.of(context).push;
              push(
                MaterialPageRoute(
                  builder: (_) => const EqualizerSettingsPage(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCapsuleButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color iconColor = Colors.white,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
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

  Widget _buildSeekBar(BuildContext context, Song song) {
    return Selector<
      PlayerProvider,
      ({Duration duration, bool isPlaying, double speed})
    >(
      selector: (_, p) => (
        duration: p.duration ?? Duration.zero,
        isPlaying: p.isPlaying,
        speed: p.speed,
      ),
      builder: (context, state, _) {
        final playerProvider = context.read<PlayerProvider>();
        return ValueListenableBuilder<bool>(
          valueListenable: kSeekBarWaveEnabled,
          builder: (context, waveEnabled, _) {
            return ValueListenableBuilder<Duration>(
              valueListenable: playerProvider.positionNotifier,
              builder: (context, position, _) {
                return PlayerSeekBar(
                  position: position,
                  duration: state.duration,
                  isPlaying: state.isPlaying,
                  speed: state.speed,
                  md3Style: true,
                  waveEnabled: waveEnabled,
                  activeColor: Colors.white,
                  inactiveColor: Colors.white24,
                  labelColor: Colors.white70,
                  climaxStart: song.climaxStart?.toDouble(),
                  climaxEnd: song.climaxEnd?.toDouble(),
                  onSeekStart: () {
                    if (playerProvider.isPlaying) {
                      playerProvider.pauseForSeek();
                    }
                  },
                  onSeekEnd: (pos) async {
                    AppHaptics.tick(HapticCategory.transport);
                    await playerProvider.seek(pos, forceNotify: true);
                    if (playerProvider.isPlaying) {
                      playerProvider.resume();
                    }
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildTransportControls(BuildContext context) {
    return Selector<
      PlayerProvider,
      ({bool isPlaying, bool shuffleEnabled, AppLoopMode loopMode})
    >(
      selector: (_, p) => (
        isPlaying: p.isPlaying,
        shuffleEnabled: p.shuffleEnabled,
        loopMode: p.loopMode,
      ),
      builder: (context, state, _) {
        final playerProvider = context.read<PlayerProvider>();
        final loopMode = state.loopMode;

        final IconData loopIcon = switch (loopMode) {
          AppLoopMode.one => Icons.repeat_one,
          AppLoopMode.all || AppLoopMode.off => Icons.repeat,
        };

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: const Icon(Icons.shuffle, size: 22),
              color: state.shuffleEnabled ? Colors.white : Colors.white60,
              onPressed: () {
                AppHaptics.lightImpact(HapticCategory.transport);
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
                if (state.isPlaying) {
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
                alignment: Alignment.center,
                child: PlayPauseMorphIcon(
                  isPlaying: state.isPlaying,
                  size: 34,
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
                loopIcon,
                size: 24,
              ),
              color: loopMode != AppLoopMode.off
                  ? Colors.white
                  : Colors.white60,
              onPressed: () {
                AppHaptics.lightImpact(HapticCategory.transport);
                playerProvider.toggleLoopMode();
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildQueueHandle(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showQueueSheet(context),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '接下来播放',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showQueueSheet(BuildContext context) {
    showM3EModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (sheetCtx) {
        return SizedBox(
          height: MediaQuery.sizeOf(sheetCtx).height * 0.72,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '接下来播放',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(sheetCtx),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PlayerPlaylistView(
                  scrollAnchor: YtMainView._playlistScrollAnchor,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
