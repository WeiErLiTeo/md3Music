import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song_model.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/artist_photo_background.dart';
import '../../widgets/depth_cover_host.dart';
import '../../widgets/lyrics_view.dart';
import '../../widgets/player_artwork_image.dart';
import '../../widgets/player_seek_bar.dart';
import '../../widgets/playing_spectrum_indicator.dart';
import '../../widgets/spectrum_background.dart';

/// YouTube Music 风格全屏播放器
class YtMusicFullPlayer extends StatefulWidget {
  const YtMusicFullPlayer({super.key});

  @override
  State<YtMusicFullPlayer> createState() => _YtMusicFullPlayerState();
}

class _YtMusicFullPlayerState extends State<YtMusicFullPlayer> {
  void _collapseByButton(BuildContext context) {
    final nav = Navigator.of(context, rootNavigator: true);
    if (nav.canPop()) {
      nav.pop();
    }
  }

  void _showMoreMenu(BuildContext context, SongModel song) {
    context.read<PlayerProvider>().showSongOptionsMenu(context, song);
  }

  void _addToPlaylist(BuildContext context, SongModel song) {
    context.read<PlayerProvider>().showAddToPlaylistDialog(context, song);
  }

  void _showEqualizerOrQuality(BuildContext context) {
    context.read<PlayerProvider>().showSoundEffectsDialog(context);
  }

  void _showQueueDrawer(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _YtQueueDrawerSheet(),
    );
  }

  void _showLyricsModalSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _YtLyricsModalSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final song = player.currentSong;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (song == null) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.expand_more),
            onPressed: () => _collapseByButton(context),
          ),
        ),
        body: const Center(child: Text('暂无正在播放的歌曲')),
      );
    }

    final isFavorite = player.isFavorite(song);

    return Scaffold(
      body: Stack(
        children: [
          // 1. 底层共享动态背景：歌手写真或频谱/网格渐变
          Positioned.fill(
            child: Consumer<ThemeProvider>(
              builder: (context, themeProv, _) {
                if (themeProv.useArtistPhotoBackground) {
                  return const ArtistPhotoBackground();
                }
                return const SpectrumBackground();
              },
            ),
          ),

          // 2. 半透明暗色遮罩以提升前景对比度（不遮挡流光）
          Positioned.fill(
            child: Container(color: Colors.black.withOpacity(0.35)),
          ),

          // 3. 播放界面主体内容
          SafeArea(
            child: Column(
              children: [
                // 顶部栏：收起按钮 + 居中空白 + 更多菜单
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8.0,
                    vertical: 4.0,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.expand_more, size: 28),
                        color: Colors.white,
                        onPressed: () => _collapseByButton(context),
                        tooltip: '收起',
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.more_vert, size: 24),
                        color: Colors.white,
                        onPressed: () => _showMoreMenu(context, song),
                        tooltip: '更多选项',
                      ),
                    ],
                  ),
                ),

                const Spacer(flex: 1),

                // 专辑封面 (正方形大圆角 16dp + 深度立体阴影)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 36.0),
                  child: AspectRatio(
                    aspectRatio: 1.0,
                    child: DepthCoverHost(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16.0),
                        child: Container(
                          decoration: BoxDecoration(
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.3),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: PlayerArtworkImage(
                            imageUrl: song.picUrl,
                            size: 320,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                const Spacer(flex: 2),

                // 歌曲信息栏（标题 + 歌手）
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              song.name,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 22,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            icon: const Icon(
                              Icons.chevron_right,
                              size: 22,
                              color: Colors.white70,
                            ),
                            onPressed: () => _showMoreMenu(context, song),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        song.artist,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white70,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // 操作胶囊栏 (水平 Material 3 色调药丸按钮组)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // 收藏按钮
                      _YtCapsuleButton(
                        icon: isFavorite
                            ? Icons.favorite
                            : Icons.favorite_border,
                        iconColor: isFavorite
                            ? colorScheme.secondary
                            : Colors.white,
                        label: isFavorite ? '已收藏' : '收藏',
                        onPressed: () => player.toggleFavorite(song),
                      ),
                      // 歌词按钮
                      _YtCapsuleButton(
                        icon: Icons.notes,
                        label: '歌词',
                        onPressed: () => _showLyricsModalSheet(context),
                      ),
                      // 保存到歌单
                      _YtCapsuleButton(
                        icon: Icons.playlist_add,
                        label: '保存',
                        onPressed: () => _addToPlaylist(context, song),
                      ),
                      // 音效 / 均衡器
                      _YtCapsuleButton(
                        icon: Icons.graphic_eq,
                        label: '音效',
                        onPressed: () => _showEqualizerOrQuality(context),
                      ),
                    ],
                  ),
                ),

                const Spacer(flex: 1),

                // 进度条与播放时间
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    children: [
                      const PlayerSeekBar(),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            player.formatDuration(player.position),
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            player.formatDuration(player.duration),
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // 播放控制栏（标准五键横排）
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // 随机播放
                      IconButton(
                        icon: Icon(
                          Icons.shuffle,
                          color: player.isShuffle
                              ? colorScheme.secondary
                              : Colors.white60,
                        ),
                        iconSize: 26,
                        onPressed: () => player.toggleShuffle(),
                        tooltip: '随机播放',
                      ),
                      // 上一首
                      IconButton(
                        icon: const Icon(
                          Icons.skip_previous,
                          color: Colors.white,
                        ),
                        iconSize: 36,
                        onPressed: () => player.previous(),
                        tooltip: '上一首',
                      ),
                      // 纯白实心圆形播放/暂停大按键
                      Container(
                        width: 64,
                        height: 64,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: Icon(
                            player.isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.black,
                            size: 36,
                          ),
                          onPressed: () => player.togglePlay(),
                          tooltip: player.isPlaying ? '暂停' : '播放',
                        ),
                      ),
                      // 下一首
                      IconButton(
                        icon: const Icon(Icons.skip_next, color: Colors.white),
                        iconSize: 36,
                        onPressed: () => player.next(),
                        tooltip: '下一首',
                      ),
                      // 循环模式
                      IconButton(
                        icon: Icon(
                          player.isRepeatOne ? Icons.repeat_one : Icons.repeat,
                          color: player.isRepeat
                              ? colorScheme.secondary
                              : Colors.white60,
                        ),
                        iconSize: 26,
                        onPressed: () => player.toggleRepeatMode(),
                        tooltip: '循环模式',
                      ),
                    ],
                  ),
                ),

                const Spacer(flex: 1),

                // 底部队列拉手 ("播放的音乐来自 / [当前歌单名称]")
                GestureDetector(
                  onTap: () => _showQueueDrawer(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12.0,
                      horizontal: 16.0,
                    ),
                    margin: const EdgeInsets.only(
                      bottom: 8.0,
                      left: 24.0,
                      right: 24.0,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(24.0),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 32,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white50,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            '播放的音乐来自 / ${player.playlistTitle.isNotEmpty ? player.playlistTitle : "默认队列"}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
  }
}

/// YT Music 风格药丸胶囊按钮
class _YtCapsuleButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? iconColor;

  const _YtCapsuleButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.iconColor,
  });

  @style
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(0.15),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: iconColor ?? Colors.white),
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
      ),
    );
  }
}

/// 播放队列底部抽屉 Sheet
class _YtQueueDrawerSheet extends StatelessWidget {
  const _YtQueueDrawerSheet();

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final playlist = player.playlist;
    final colorScheme = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24.0)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
            child: Container(
              color: colorScheme.surfaceContainerHigh.withOpacity(0.92),
              child: Column(
                children: [
                  // 顶栏 (拖拽指示器 + 歌单标题 + 保存按钮)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Column(
                      children: [
                        Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: colorScheme.onSurfaceVariant.withOpacity(
                              0.4,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '播放的音乐来自',
                                    style: TextStyle(
                                      color: colorScheme.onSurfaceVariant,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    player.playlistTitle.isNotEmpty
                                        ? player.playlistTitle
                                        : '当前播放队列',
                                    style: TextStyle(
                                      color: colorScheme.onSurface,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: () {
                                if (player.currentSong != null) {
                                  player.showAddToPlaylistDialog(
                                    context,
                                    player.currentSong!,
                                  );
                                }
                              },
                              icon: const Icon(Icons.playlist_add, size: 18),
                              label: const Text('保存'),
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),

                  // 队列列表
                  Expanded(
                    child: ReorderableListView.builder(
                      scrollController: scrollController,
                      itemCount: playlist.length,
                      onReorder: (oldIndex, newIndex) {
                        player.reorderPlaylist(oldIndex, newIndex);
                      },
                      itemBuilder: (context, index) {
                        final song = playlist[index];
                        final isCurrent = index == player.currentIndex;

                        return ListTile(
                          key: ValueKey('${song.id}_$index'),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(6.0),
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: PlayerArtworkImage(
                                imageUrl: song.picUrl,
                                size: 88,
                              ),
                            ),
                          ),
                          title: Row(
                            children: [
                              if (isCurrent) ...[
                                const PlayingSpectrumIndicator(size: 14),
                                const SizedBox(width: 6),
                              ],
                              Expanded(
                                child: Text(
                                  song.name,
                                  style: TextStyle(
                                    color: isCurrent
                                        ? colorScheme.primary
                                        : colorScheme.onSurface,
                                    fontWeight: isCurrent
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            '${song.artist} · ${player.formatDuration(Duration(milliseconds: song.duration))}',
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: ReorderableDragStartListener(
                            index: index,
                            child: Icon(
                              Icons.drag_handle,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          onTap: () {
                            player.playAtIndex(index);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 歌词模态 BottomSheet
class _YtLyricsModalSheet extends StatelessWidget {
  const _YtLyricsModalSheet();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.85,
      builder: (context, scrollController) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24.0)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              color: colorScheme.surfaceContainerHigh.withOpacity(0.95),
              child: Column(
                children: [
                  // 顶部标题栏
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20.0,
                      vertical: 12.0,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '歌词',
                          style: TextStyle(
                            color: colorScheme.onSurface,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(),
                          tooltip: '关闭',
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),

                  // 歌词列表展示
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16.0),
                      child: LyricsView(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
