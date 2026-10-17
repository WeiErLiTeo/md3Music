import 'dart:async';
import 'dart:ui' as ui;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/layout/display_space.dart';
import '../../core/services/music_haptics_service.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/utils/app_toast.dart';
import '../../core/utils/local_lyric_loader.dart';
import '../../core/widgets/app_background.dart';
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../data/repositories/song_match_repository.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/local_favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../widgets/add_to_playlist_dialog.dart';
import '../../widgets/apple_lyrics/apple_lyrics_view.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../widgets/flowing_background.dart';
import '../../widgets/player_playlist_view.dart';
import '../../widgets/player_seek_bar.dart';
import '../../widgets/smart_artwork_image.dart';
import '../album/album_detail_page.dart';
import '../artist/artist_detail_page.dart';
import '../library/song_match_sheet.dart';
import '../settings/equalizer_settings_page.dart';
import 'car_mode_exit.dart';
import 'dlna_cast_sheet.dart';
import 'full_player_route.dart';
import 'mv_player_page.dart';
import 'player_cover_morph_layer.dart';
import 'player_page_role.dart';
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

  bool _wasPlayingBeforeDrag = false;
  double _queueDragDistance = 0.0;
  bool _isQueueDrawerShowing = false;

  @override
  void initState() {
    super.initState();
    MusicHapticsService.instance.setPlayerPageActive(true);
  }

  @override
  void dispose() {
    MusicHapticsService.instance.setPlayerPageActive(false);
    _playlistScrollAnchor.dispose();
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

  Future<void> _confirmExitCarMode() async {
    final exited = await confirmExitCarMode(context);
    if (exited && mounted) {
      showToast('已退出车机模式');
    }
  }

  Song _resolveMatchedSong(Song song) {
    if (song.isOnline) return song;
    final info = SongMatchRepository().get(song.id);
    return (info != null && info.isMatched) ? info.toSong() : song;
  }

  void _dismissAndPush(Route<dynamic> pageRoute) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      _isDismissing = true;
      route.dismiss();
      Future.delayed(const Duration(milliseconds: 300), () {
        navigator.push(pageRoute);
      });
    } else {
      navigator.push(pageRoute);
    }
  }

  void _navigateToAlbum(Song song) {
    final resolved = _resolveMatchedSong(song);
    final albumId = resolved.albumId;
    if (albumId == null || albumId.isEmpty) {
      showToast('暂无专辑信息', long: true);
      return;
    }
    final album = Album(
      id: albumId,
      name: resolved.album.isNotEmpty ? resolved.album : song.album,
      artist: resolved.artist.isNotEmpty ? resolved.artist : song.artist,
      artworkUri: resolved.artworkUri ?? song.artworkUri,
      songCount: 0,
    );
    _dismissAndPush(
      MaterialPageRoute(builder: (_) => AlbumDetailPage(album: album)),
    );
  }

  void _navigateToArtist(Song song) {
    final resolved = _resolveMatchedSong(song);
    final artists = splitSongArtistNames(resolved.artist);
    if (artists.isEmpty) {
      showToast('暂无歌手信息', long: true);
      return;
    }
    if (artists.length == 1) {
      _pushArtistPage(resolved.artistId, artists.first);
      return;
    }
    _showArtistSelector(context, resolved, artists);
  }

  void _showArtistSelector(
    BuildContext context,
    Song song,
    List<String> artists,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF212121),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '选择歌手',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ...artists.map((name) {
                return ListTile(
                  leading: const Icon(Icons.person, color: Colors.white70),
                  title: Text(name, style: const TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    if (name == artists.first &&
                        song.artistId != null &&
                        song.artistId!.isNotEmpty) {
                      _pushArtistPage(song.artistId, name);
                    } else {
                      _pushArtistPageByName(name);
                    }
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pushArtistPageByName(String name) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );
    final navigator = Navigator.of(context, rootNavigator: true);
    void Function()? pendingPush;
    try {
      final api = KugouApiClient();
      final result = await api.searchArtists(name, pagesize: 5);
      if (result == null || result.isEmpty) {
        showToast('未找到歌手「$name」', long: true);
        return;
      }
      final artist = result.first;
      pendingPush = () => _pushArtistPage(artist.id, artist.name);
    } catch (e) {
      showToast('搜索歌手失败：$e', long: true);
    } finally {
      navigator.pop();
    }
    pendingPush?.call();
  }

  void _pushArtistPage(String? artistId, String artistName) {
    if (artistId == null || artistId.isEmpty) {
      _pushArtistPageByName(artistName);
      return;
    }
    _dismissAndPush(
      MaterialPageRoute(
        builder: (_) => ArtistDetailPage(
          artistId: artistId,
          artistName: artistName,
          avatarUrl: null,
        ),
      ),
    );
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
      backgroundColor: const Color(0xFF212121),
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
                    leading: const Icon(Icons.music_video_outlined, color: Colors.white70),
                    title: const Text('查看 MV', style: TextStyle(color: Colors.white)),
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
                  leading: const Icon(Icons.album, color: Colors.white70),
                  title: Text(
                    albumTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      _navigateToAlbum(song);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.person, color: Colors.white70),
                  title: Text(
                    artistTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      _navigateToArtist(song);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add, color: Colors.white70),
                  title: const Text('添加到歌单', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      showAddToPlaylistDialog(rootContext, song);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.cast, color: Colors.white70),
                  title: const Text('投屏 (DLNA)', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      showModalBottomSheet(
                        context: rootContext,
                        isScrollControlled: true,
                        backgroundColor: const Color(0xFF212121),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                        ),
                        builder: (_) => const DlnaCastSheet(),
                      );
                    }
                  },
                ),
                if (!song.isOnline)
                  ListTile(
                    leading: const Icon(Icons.sync, color: Colors.white70),
                    title: const Text('匹配歌曲信息', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      if (rootContext.mounted) {
                        showSongMatchSheet(rootContext, song);
                      }
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.graphic_eq, color: Colors.white70),
                  title: const Text('均衡器与音效设置', style: TextStyle(color: Colors.white)),
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
                  leading: const Icon(Icons.speed, color: Colors.white70),
                  title: const Text('播放速度', style: TextStyle(color: Colors.white)),
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
                  leading: const Icon(Icons.timer_outlined, color: Colors.white70),
                  title: const Text('睡眠定时', style: TextStyle(color: Colors.white)),
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
                  leading: const Icon(Icons.info_outline, color: Colors.white70),
                  title: const Text('歌曲信息', style: TextStyle(color: Colors.white)),
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

  void _showLyricsModalSheet(BuildContext context, Song song) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        reverseDuration: Duration(milliseconds: 250),
        reverseCurve: Curves.easeInCubic,
      ),
      builder: (sheetContext) => _YtLyricsSheet(song: song),
    );
  }

  void _showQueueDrawer(BuildContext context) {
    if (_isQueueDrawerShowing) return;
    _isQueueDrawerShowing = true;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final screenHeight = MediaQuery.of(sheetContext).size.height;
        return Container(
          height: screenHeight * 0.72,
          decoration: const BoxDecoration(
            color: Color(0xFF212121),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
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
                    const Expanded(
                      child: Text(
                        '播放的音乐来自 · 播放队列',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
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
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.playlist_add,
                              size: 16,
                              color: Colors.white,
                            ),
                            SizedBox(width: 4),
                            Text(
                              '保存',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
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
      _isQueueDrawerShowing = false;
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

  Widget _buildBackground(Song song, PlayerProvider playerProvider) {
    if (LyricPreferences.instance.useFlowingBackground) {
      return Positioned.fill(
        child: FlowingBackground(
          artworkUrl: song.artworkUri,
          isPlaying: playerProvider.isPlaying,
        ),
      );
    }
    final themeProvider = context.watch<ThemeProvider>();
    if (themeProvider.useBackgroundImage) {
      return const Positioned.fill(child: AppBackground());
    }
    return Positioned.fill(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF1E1E1E),
              Color(0xFF030303),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: widget.dockMode ? null : _onTopBarDragStart,
      onVerticalDragUpdate: widget.dockMode ? null : _onTopBarDragUpdate,
      onVerticalDragEnd: widget.dockMode ? null : _onTopBarDragEnd,
      onVerticalDragCancel: widget.dockMode ? null : _onTopBarDragCancel,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 8,
        ),
        child: Row(
          children: [
            if (widget.dockMode)
              IconButton(
                icon: const Icon(
                  Icons.close_fullscreen,
                  size: 24,
                  color: Colors.white,
                ),
                tooltip: '退出车机模式',
                onPressed: _confirmExitCarMode,
              )
            else
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
    );
  }

  Widget _buildCoverSlot(Song song) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: widget.dockMode ? null : _onTopBarDragStart,
      onVerticalDragUpdate: widget.dockMode ? null : _onTopBarDragUpdate,
      onVerticalDragEnd: widget.dockMode ? null : _onTopBarDragEnd,
      onVerticalDragCancel: widget.dockMode ? null : _onTopBarDragCancel,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 18,
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
                size: 360,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitleAndArtist(Song song) {
    return PlayerTitleSlot(
      title: song.displayName,
      subtitle: song.artist,
      titleStyle: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
      subtitleStyle: const TextStyle(
        fontSize: 15,
        color: Colors.white70,
      ),
      align: Alignment.centerLeft,
      eligible: () => true,
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
          const SizedBox(height: 2),
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
    );
  }

  Widget _buildCapsuleRow(
    BuildContext context,
    Song song,
    bool isFavorited,
    bool isOnline,
  ) {
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
            onTap: () => _showLyricsModalSheet(context, song),
          ),
          const SizedBox(width: 10),
          _buildCapsuleButton(
            icon: Icons.playlist_add,
            label: '保存',
            onTap: () => showAddToPlaylistDialog(context, song),
          ),
          const SizedBox(width: 10),
          _buildCapsuleButton(
            icon: Icons.graphic_eq,
            label: '音效',
            onTap: () {
              Navigator.of(context).push(
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

  Widget _buildSeekBar(PlayerProvider playerProvider, Song song) {
    return ValueListenableBuilder<Duration>(
      valueListenable: playerProvider.positionNotifier,
      builder: (context, position, _) {
        return PlayerSeekBar(
          position: position,
          duration: playerProvider.duration ?? Duration.zero,
          isPlaying: playerProvider.isPlaying,
          speed: playerProvider.speed,
          activeColor: Colors.white,
          inactiveColor: Colors.white24,
          labelColor: Colors.white70,
          climaxStart: song.climaxStart?.toDouble(),
          climaxEnd: song.climaxEnd?.toDouble(),
          onSeekStart: () {
            _wasPlayingBeforeDrag = playerProvider.isPlaying;
            if (_wasPlayingBeforeDrag) {
              playerProvider.pauseForSeek();
            }
          },
          onSeekEnd: (pos) async {
            AppHaptics.tick(HapticCategory.transport);
            await playerProvider.seek(pos, forceNotify: true);
            if (_wasPlayingBeforeDrag) {
              playerProvider.resume();
            }
          },
        );
      },
    );
  }

  Widget _buildTransportControls(
    PlayerProvider playerProvider,
    ColorScheme colorScheme,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          icon: const Icon(Icons.shuffle, size: 22),
          color: playerProvider.shuffleEnabled
              ? colorScheme.primary
              : Colors.white70,
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
              playerProvider.isPlaying ? Icons.pause : Icons.play_arrow,
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
          color: playerProvider.loopMode != AppLoopMode.off
              ? colorScheme.primary
              : Colors.white70,
          onPressed: () {
            AppHaptics.lightImpact(HapticCategory.transport);
            playerProvider.toggleLoopMode();
          },
        ),
      ],
    );
  }

  Widget _buildQueueHandle(BuildContext context) {
    return GestureDetector(
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
        if (_queueDragDistance != -999.0 &&
            details.primaryVelocity != null &&
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
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

        Widget page = Scaffold(
          backgroundColor: const Color(0xFF030303),
          body: Stack(
                children: [
                  _buildBackground(song, playerProvider),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isLandscape =
                          constraints.maxWidth > constraints.maxHeight;
                      if (isLandscape) {
                        return SafeArea(
                          child: Row(
                            children: [
                              Expanded(
                                flex: 5,
                                child: Column(
                                  children: [
                                    _buildTopBar(),
                                    Expanded(
                                      child: Center(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 24,
                                            vertical: 8,
                                          ),
                                          child: _buildCoverSlot(song),
                                        ),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                        vertical: 6,
                                      ),
                                      child: _buildTitleAndArtist(song),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                flex: 5,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                      ),
                                      child: _buildCapsuleRow(
                                        context,
                                        song,
                                        isFavorited,
                                        isOnline,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 20,
                                      ),
                                      child: _buildSeekBar(
                                        playerProvider,
                                        song,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                      ),
                                      child: _buildTransportControls(
                                        playerProvider,
                                        colorScheme,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    _buildQueueHandle(context),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      return SafeArea(
                        child: Column(
                          children: [
                            _buildTopBar(),
                            Expanded(
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24.0),
                                  child: _buildCoverSlot(song),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24.0,
                                vertical: 8.0,
                              ),
                              child: _buildTitleAndArtist(song),
                            ),
                            const SizedBox(height: 10),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24.0,
                              ),
                              child: _buildCapsuleRow(
                                context,
                                song,
                                isFavorited,
                                isOnline,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20.0,
                              ),
                              child: _buildSeekBar(playerProvider, song),
                            ),
                            const SizedBox(height: 10),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24.0,
                                vertical: 6.0,
                              ),
                              child: _buildTransportControls(
                                playerProvider,
                                colorScheme,
                              ),
                            ),
                            const SizedBox(height: 6),
                            _buildQueueHandle(context),
                          ],
                        ),
                      );
                    },
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
          },
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

  @override
  void initState() {
    super.initState();
    _loadLyricsFor(widget.song);
  }

  Future<void> _loadLyricsFor(Song song, {bool force = false}) async {
    if (!force && _loadedSongId == song.id) return;
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
      // 严格左对齐：文字左边距 24dp，严禁居中。去除对唱 agentId，统一为左对齐
      final leftAligned = parsed.map((l) {
        if (l.agentId != null) {
          return l.copyWith(clearAgentId: true);
        }
        return l;
      }).toList();
      setState(() {
        _loading = false;
        _parsedLines = leftAligned;
      });
    } else {
      setState(() {
        _loading = false;
        _parsedLines = const [];
      });
    }
  }

  bool get _hasTranslation {
    return _parsedLines.any(
      (line) => line.translation != null && line.translation!.isNotEmpty,
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final currentSong = player.currentSong ?? widget.song;

    if (_loadedSongId != currentSong.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _loadedSongId != currentSong.id) {
          _loadLyricsFor(currentSong);
        }
      });
    }

    final screenHeight = MediaQuery.of(context).size.height;

    return SizedBox(
      height: screenHeight,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 顶部常驻 Mini 控制条：40x40 圆角封面 + 左对齐纯净歌名/歌手 + 紧凑的上一曲/播放暂停/下一曲图标
            SizedBox(
              height: 60,
              child: _buildTopMiniBar(context, currentSong, player),
            ),
            // 歌词抽屉主体：停在距离屏幕顶部约 60dp 处，不要全屏
            Expanded(
              child: _buildLyricsDrawer(context, currentSong, player),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部常驻 Mini 控制条
  Widget _buildTopMiniBar(
    BuildContext context,
    Song currentSong,
    PlayerProvider player,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            // 40x40 圆角封面
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SmartArtworkImage(
                artworkUri: currentSong.artworkUri,
                size: 40,
              ),
            ),
            const SizedBox(width: 12),
            // 左对齐纯净歌名与歌手
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    currentSong.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
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
            const SizedBox(width: 8),
            // 紧凑的上一曲/播放暂停/下一曲图标
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(
                    Icons.skip_previous,
                    color: Colors.white,
                    size: 24,
                  ),
                  splashRadius: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  onPressed: () {
                    AppHaptics.click(HapticCategory.transport);
                    player.previous();
                  },
                ),
                IconButton(
                  icon: Icon(
                    player.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 28,
                  ),
                  splashRadius: 22,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
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
                    color: Colors.white,
                    size: 24,
                  ),
                  splashRadius: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  onPressed: () {
                    AppHaptics.click(HapticCategory.transport);
                    player.next();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 歌词抽屉主体：深色毛玻璃材质、圆角 20、细长拉手、标题栏与边缘 ShaderMask 渐变淡出
  Widget _buildLyricsDrawer(
    BuildContext context,
    Song currentSong,
    PlayerProvider player,
  ) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xE61A1A1A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // 顶部拉手：正中央一条细长圆角拉手（36x4dp，微透白）
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.24),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // 标题栏：左侧紧贴加粗大字“歌词”（20sp，纯白），右侧为纯白“✕”关闭按钮
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 16, 4),
                child: Row(
                  children: [
                    const Text(
                      '歌词',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 22,
                      ),
                      splashRadius: 20,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              // 中间歌词主体与悬浮翻译药丸按钮
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _loading
                          ? const Center(
                              child: CircularProgressIndicator(
                                color: Colors.white70,
                              ),
                            )
                          : _parsedLines.isEmpty
                              ? _buildEmptyLyricsView(context, currentSong)
                              : ShaderMask(
                                  shaderCallback: (Rect bounds) {
                                    final double h = bounds.height;
                                    if (h <= 0) {
                                      return const LinearGradient(
                                        colors: [Colors.black, Colors.black],
                                      ).createShader(bounds);
                                    }
                                    final double topStop =
                                        (36.0 / h).clamp(0.0, 0.4);
                                    final double bottomStop =
                                        ((h - 36.0) / h).clamp(0.6, 1.0);
                                    return LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: const [
                                        Colors.transparent,
                                        Colors.black,
                                        Colors.black,
                                        Colors.transparent,
                                      ],
                                      stops: [
                                        0.0,
                                        topStop,
                                        bottomStop,
                                        1.0,
                                      ],
                                    ).createShader(bounds);
                                  },
                                  blendMode: BlendMode.dstIn,
                                  child: AppleLyricsView(
                                    lines: _parsedLines,
                                    currentTimeMs:
                                        player.position.inMilliseconds,
                                    positionListenable: player.positionNotifier,
                                    isPlaying: player.isPlaying,
                                    playbackNotReady: false,
                                    onSeek: (timeMs) => player.seek(
                                      Duration(milliseconds: timeMs),
                                    ),
                                    forceDarkBackground: true,
                                    doubleTapToJump: context
                                        .watch<ThemeProvider>()
                                        .lyricDoubleTapToJump,
                                    accentColor: null,
                                  ),
                                ),
                    ),
                    // 悬浮“文A 翻译”药丸按钮：Stack 固定在底部居中（距底 24dp）
                    if (!_loading && _parsedLines.isNotEmpty && _hasTranslation)
                      ListenableBuilder(
                        listenable: LyricPreferences.instance,
                        builder: (context, _) {
                          final showTranslation =
                              LyricPreferences.instance.showTranslation;
                          return Positioned(
                            bottom: 24,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () {
                                    AppHaptics.lightImpact(
                                      HapticCategory.control,
                                    );
                                    LyricPreferences.instance
                                        .setShowTranslation(!showTranslation);
                                  },
                                  borderRadius: BorderRadius.circular(24),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(24),
                                      border: Border.all(
                                        color: showTranslation
                                            ? Colors.white.withOpacity(0.3)
                                            : Colors.white.withOpacity(0.15),
                                        width: 0.8,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.25),
                                          blurRadius: 8,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.translate,
                                          size: 16,
                                          color: showTranslation
                                              ? Colors.white
                                              : Colors.white70,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          '翻译',
                                          style: TextStyle(
                                            color: showTranslation
                                                ? Colors.white
                                                : Colors.white70,
                                            fontSize: 13,
                                            fontWeight: showTranslation
                                                ? FontWeight.bold
                                                : FontWeight.w500,
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyLyricsView(BuildContext context, Song currentSong) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.lyrics_outlined,
            size: 56,
            color: Colors.white30,
          ),
          const SizedBox(height: 12),
          const Text(
            '暂无歌词',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            icon: const Icon(
              Icons.sync,
              size: 16,
              color: Colors.white,
            ),
            label: const Text(
              '匹配歌词',
              style: TextStyle(color: Colors.white),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(
                color: Colors.white24,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
            ),
            onPressed: () async {
              await showSongMatchSheet(
                context,
                currentSong,
              );
              if (mounted) {
                _loadLyricsFor(currentSong, force: true);
              }
            },
          ),
        ],
      ),
    );
  }
}
