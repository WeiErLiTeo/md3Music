import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/models/song.dart';
import '../../../providers/favorites_provider.dart';
import '../../../providers/local_favorites_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/add_to_playlist_dialog.dart';
import '../../../widgets/marquee_text.dart';
import '../../../widgets/player_playlist_view.dart';
import '../../../widgets/player_seek_bar.dart';
import '../../settings/equalizer_settings_page.dart';
import 'yt_more_menu.dart';

class YtMainView extends StatelessWidget {
  static final PlaylistScrollAnchor _playlistScrollAnchor = PlaylistScrollAnchor();

  final Song song;
  final double largeCoverSize;
  final VoidCallback onCollapse;
  final VoidCallback onOpenLyrics;
  final void Function(Route<dynamic>)? onPushPage;

  const YtMainView({
    super.key,
    required this.song,
    required this.largeCoverSize,
    required this.onCollapse,
    required this.onOpenLyrics,
    this.onPushPage,
  });

  @override
  Widget build(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final favoritesProvider = context.watch<FavoritesProvider>();
    final localFavoritesProvider = context.watch<LocalFavoritesProvider>();
    final isOnline = song.isOnline;
    final isFavorited = isOnline
        ? favoritesProvider.isFavorite(song.id)
        : localFavoritesProvider.isFavorite(song.id);

    final resolvedSong = YtMoreMenu.resolveMatchedSong(song);

    return SafeArea(
      top: true,
      bottom: true,
      child: Column(
        children: [
          _buildTopBar(context, resolvedSong),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  SizedBox(
                    width: largeCoverSize,
                    height: largeCoverSize,
                  ),
                  _buildTitleAndArtist(context, resolvedSong),
                  _buildCapsuleRow(context, resolvedSong, isFavorited, isOnline),
                  _buildSeekBar(playerProvider, resolvedSong),
                  _buildTransportControls(context, playerProvider),
                ],
              ),
            ),
          ),
          _buildQueueHandle(context),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, Song resolvedSong) {
    return SizedBox(
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
              onPressed: onCollapse,
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.headphones, size: 16, color: Colors.white),
                  SizedBox(width: 6),
                  Text(
                    '歌曲',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
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
                onPushPage: onPushPage,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleAndArtist(BuildContext context, Song song) {
    final title = song.displayName;
    final artist = song.artist.isNotEmpty ? song.artist : '未知艺术家';

    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => YtMoreMenu.show(context, song, onPushPage: onPushPage),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: GentleScrollingText(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.chevron_right,
                  color: Colors.white70,
                  size: 20,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () => YtMoreMenu.show(context, song, onPushPage: onPushPage),
            child: Text(
              artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: 15,
                fontWeight: FontWeight.w400,
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
            onTap: onOpenLyrics,
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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

  Widget _buildSeekBar(PlayerProvider playerProvider, Song song) {
    return ValueListenableBuilder<bool>(
      valueListenable: kSeekBarWaveEnabled,
      builder: (context, waveEnabled, _) {
        return ValueListenableBuilder<Duration>(
          valueListenable: playerProvider.positionNotifier,
          builder: (context, position, _) {
            return PlayerSeekBar(
              position: position,
              duration: playerProvider.duration ?? Duration.zero,
              activeColor: Colors.white,
              inactiveColor: Colors.white24,
              labelColor: Colors.white70,
              isPlaying: playerProvider.isPlaying,
              speed: playerProvider.speed,
              md3Style: true,
              waveEnabled: waveEnabled,
              climaxStart: song.climaxStart?.toDouble(),
              climaxEnd: song.climaxEnd?.toDouble(),
              onSeekEnd: (newPos) => playerProvider.seek(newPos),
            );
          },
        );
      },
    );
  }

  Widget _buildTransportControls(
    BuildContext context,
    PlayerProvider playerProvider,
  ) {
    final isPlaying = playerProvider.isPlaying;
    final isBuffering = playerProvider.isPlaybackNotReady;
    final loopMode = playerProvider.loopMode;

    IconData loopIcon;
    Color loopColor = Colors.white70;
    switch (loopMode) {
      case AppLoopMode.one:
        loopIcon = Icons.repeat_one;
        loopColor = Colors.white;
        break;
      case AppLoopMode.all:
        loopIcon = Icons.repeat;
        loopColor = Colors.white;
        break;
      case AppLoopMode.off:
      default:
        loopIcon = Icons.repeat_outlined;
        loopColor = Colors.white38;
        break;
    }

    final isShuffle = playerProvider.shuffleEnabled;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: Icon(
              Icons.shuffle,
              color: isShuffle ? Colors.white : Colors.white38,
              size: 26,
            ),
            onPressed: () => playerProvider.toggleShuffle(),
          ),
          IconButton(
            icon: const Icon(
              Icons.skip_previous,
              color: Colors.white,
              size: 38,
            ),
            onPressed: () => playerProvider.previous(),
          ),
          Container(
            width: 68,
            height: 68,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: isBuffering
                  ? const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.8,
                        color: Colors.black,
                      ),
                    )
                  : Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.black,
                      size: 38,
                    ),
              onPressed: () {
                if (playerProvider.isPlaying) {
                  playerProvider.pause();
                } else {
                  playerProvider.resume();
                }
              },
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.skip_next,
              color: Colors.white,
              size: 38,
            ),
            onPressed: () => playerProvider.next(),
          ),
          IconButton(
            icon: Icon(
              loopIcon,
              color: loopColor,
              size: 26,
            ),
            onPressed: () => playerProvider.toggleLoopMode(),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueHandle(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showQueueDrawer(context),
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.38),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '播放的音乐来自 / 播放队列',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showQueueDrawer(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final screenHeight = MediaQuery.sizeOf(sheetContext).height;
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
    );
  }
}
