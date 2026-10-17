import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
import '../../widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../widgets/player_playlist_view.dart';
import '../../widgets/player_seek_bar.dart';
import '../../widgets/smart_artwork_image.dart';
import '../album/album_detail_page.dart';
import '../artist/artist_detail_page.dart';
import '../settings/equalizer_settings_page.dart';
import 'full_player_route.dart';
import 'lyrics_view.dart';
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

  @override
  void dispose() {
    _playlistScrollAnchor.dispose();
    super.dispose();
  }

  DraggablePlayerRoute? get _dragRoute {
    final route = ModalRoute.of(context);
    return route is DraggablePlayerRoute ? route : null;
  }

  void _collapseByButton() {
    final route = _dragRoute;
    if (route != null) {
      route.collapse();
    } else {
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
                      Navigator.of(rootContext).push(
                        MaterialPageRoute(
                          builder: (_) => MvPlayerPage(song: song),
                        ),
                      );
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
                    _navigateToAlbum(song);
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
                    _navigateToArtist(song);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add),
                  title: const Text('添加到歌单'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    showAddToPlaylistDialog(rootContext, song);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.graphic_eq),
                  title: const Text('均衡器与音效设置'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.of(rootContext).push(
                      MaterialPageRoute(
                        builder: (_) => const EqualizerSettingsPage(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.speed),
                  title: const Text('播放速度'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    showSpeedPickerDialog(
                      context: rootContext,
                      currentSpeed: player.speed,
                      onSelected: (speed) => player.setSpeed(speed),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('睡眠定时'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    showSleepTimerSheet(context: rootContext, player: player);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('歌曲信息'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.of(rootContext).push(
                      MaterialPageRoute(builder: (_) => const SongInfoPage()),
                    );
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

  void _showQueueDrawer(BuildContext context) {
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
                        final currentSong = context
                            .read<PlayerProvider>()
                            .currentSong;
                        if (currentSong != null) {
                          showAddToPlaylistDialog(context, currentSong);
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
    );
  }

  Widget _buildPlayModeIcon(bool shuffleEnabled, AppLoopMode loopMode) {
    if (shuffleEnabled) {
      return const Icon(Icons.shuffle, size: 22);
    }
    switch (loopMode) {
      case AppLoopMode.one:
        return const Icon(Icons.repeat_one, size: 22);
      case AppLoopMode.all:
      case AppLoopMode.off:
        return const Icon(Icons.repeat, size: 22);
    }
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
          if (didPop) return;
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
                  const Positioned.fill(child: AppBackground()),
                  Positioned.fill(
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.45),
                    ),
                  ),
                  SafeArea(
                    child: Column(
                      children: [
                        Padding(
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
                          child: PlayerSeekBar(
                            position: playerProvider.position,
                            duration: playerProvider.duration ?? Duration.zero,
                            activeColor: Colors.white,
                            inactiveColor: Colors.white24,
                            labelColor: Colors.white70,
                            onSeekEnd: (pos) {
                              playerProvider.seek(pos);
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
                                icon: _buildPlayModeIcon(
                                  playerProvider.shuffleEnabled,
                                  playerProvider.loopMode,
                                ),
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
                                  playerProvider.cyclePlayMode();
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        GestureDetector(
                          onTap: () => _showQueueDrawer(context),
                          child: Container(
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
  String _rawLyrics = '';
  List<LyricLine> _parsedLines = const [];

  @override
  void initState() {
    super.initState();
    _loadLyrics();
  }

  @override
  void didUpdateWidget(covariant _YtLyricsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id) {
      _loadLyrics();
    }
  }

  Future<void> _loadLyrics() async {
    setState(() {
      _loading = true;
      _rawLyrics = '';
      _parsedLines = const [];
    });

    final song = widget.song;
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

    if (!mounted) return;

    if (lyricText.isNotEmpty) {
      final parsed = LyricParserChain.parse(
        lyricText,
        translationText: translationText,
        romaText: romaText,
      );
      setState(() {
        _loading = false;
        _rawLyrics = lyricText;
        _parsedLines = parsed;
      });
    } else {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final screenHeight = MediaQuery.of(context).size.height;
    return Container(
      height: screenHeight * 0.72,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                Text(
                  '歌词',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Consumer<PlayerProvider>(
              builder: (context, player, _) {
                if (_loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (_parsedLines.isEmpty) {
                  return const Center(child: Text('暂无歌词'));
                }
                return LyricsView(
                  lyrics: _rawLyrics,
                  parsedLyrics: _parsedLines,
                  position: player.position,
                  positionListenable: player.positionNotifier,
                  onSeek: (pos) => player.seek(pos),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
