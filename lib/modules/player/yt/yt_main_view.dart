import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/app_haptics.dart';
import '../../../data/models/song.dart';
import '../../../providers/favorites_provider.dart';
import '../../../providers/local_favorites_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/add_to_playlist_dialog.dart';
import '../../../widgets/marquee_text.dart';
import '../../../widgets/player_playlist_view.dart';
import '../../../widgets/player_seek_bar.dart';
import '../../../widgets/smart_artwork_image.dart';
import '../../settings/equalizer_settings_page.dart';
import 'yt_more_menu.dart';

class YtMainView extends StatelessWidget {
  static final PlaylistScrollAnchor _playlistScrollAnchor = PlaylistScrollAnchor();

  final Song song;
  final VoidCallback onCollapse;
  final VoidCallback onOpenLyrics;
  final void Function(Route<dynamic>)? onPushPage;
  final void Function(Route<dynamic>)? onDismissAndPush;
  final GestureDragStartCallback? onDragStart;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;
  final GestureDragCancelCallback? onDragCancel;

  const YtMainView({
    super.key,
    required this.song,
    required this.onCollapse,
    required this.onOpenLyrics,
    this.onPushPage,
    this.onDismissAndPush,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
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
          // 顶部栏（支持下拉收起手势）
          _buildTopBar(context, resolvedSong),
          // 核心封面区：通过 Expanded(Center) 天然居中在顶栏和歌名之间，自适应呼吸间距
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24.0,
                  vertical: 8.0,
                ),
                child: _buildCover(context, resolvedSong),
              ),
            ),
          ),
          // 歌名与歌手
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 6.0,
            ),
            child: _buildTitleAndArtist(context, resolvedSong),
          ),
          const SizedBox(height: 10),
          // 胶囊操作栏（收藏 / 歌词 / 保存 / 音效）
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
          // 播放进度条
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 20.0,
            ),
            child: _buildSeekBar(playerProvider, resolvedSong),
          ),
          const SizedBox(height: 10),
          // 五键控制区（播放/暂停/上一曲/下一曲/循环/随机）
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 6.0,
            ),
            child: _buildTransportControls(context, playerProvider),
          ),
          const SizedBox(height: 6),
          // 底部队列把手
          _buildQueueHandle(context),
        ],
      ),
    );
  }

  /// 顶栏：保留折叠按钮、[🎵 歌曲] [🎬 视频/MV] 双模胶囊与更多选项
  Widget _buildTopBar(BuildContext context, Song resolvedSong) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: onDragStart,
      onVerticalDragUpdate: onDragUpdate,
      onVerticalDragEnd: onDragEnd,
      onVerticalDragCancel: onDragCancel,
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
                onPressed: onCollapse,
              ),
              const Spacer(),
              // 双模胶囊切换器：1:1 原版 YouTube Music 样式
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
                    // 歌曲模式 (当前激活态)
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
                    // 视频/MV 模式 (目前仅做按钮，暂不加功能)
                    InkWell(
                      onTap: () {
                        // 视频按钮视觉对齐，目前无功能
                      },
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: const Center(
                          child: Icon(
                            Icons.smart_display_outlined,
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
                  onPushPage: onPushPage,
                  onDismissAndPush: onDismissAndPush,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 封面部件：支持下拉收起手势与 1:1 正方形居中
  Widget _buildCover(BuildContext context, Song song) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: onDragStart,
      onVerticalDragUpdate: onDragUpdate,
      onVerticalDragEnd: onDragEnd,
      onVerticalDragCancel: onDragCancel,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SmartArtworkImage(
              artworkUri: song.artworkUri,
              size: 400,
            ),
          ),
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
            onTap: () {
              final push = onDismissAndPush ?? onPushPage ?? Navigator.of(context).push;
              YtMoreMenu.navigateToAlbum(context, song, push);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: GentleScrollingText(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.3,
                    ),
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
              final push = onDismissAndPush ?? onPushPage ?? Navigator.of(context).push;
              YtMoreMenu.navigateToArtist(context, song, push);
            },
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
              final push = onPushPage ?? Navigator.of(context).push;
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
              isPlaying: playerProvider.isPlaying,
              speed: playerProvider.speed,
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
  }

  Widget _buildTransportControls(
    BuildContext context,
    PlayerProvider playerProvider,
  ) {
    final loopMode = playerProvider.loopMode;

    IconData loopIcon;
    switch (loopMode) {
      case AppLoopMode.one:
        loopIcon = Icons.repeat_one;
        break;
      case AppLoopMode.all:
      default:
        loopIcon = Icons.repeat;
        break;
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          icon: const Icon(Icons.shuffle, size: 22),
          color: playerProvider.shuffleEnabled ? Colors.white : Colors.white60,
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
            loopIcon,
            size: 24,
          ),
          color: loopMode != AppLoopMode.off ? Colors.white : Colors.white60,
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: Container(
            color: const Color(0xFF1E1E1E),
            height: MediaQuery.of(sheetCtx).size.height * 0.72,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                    scrollAnchor: _playlistScrollAnchor,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
