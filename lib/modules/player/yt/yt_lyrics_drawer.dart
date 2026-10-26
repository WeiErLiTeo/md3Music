import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/local_lyric_loader.dart';
import '../../../data/models/song.dart';
import '../../../data/repositories/song_match_repository.dart';
import '../../../providers/kugou_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/add_to_playlist_dialog.dart';
import '../../../widgets/apple_lyrics/apple_lyrics_view.dart';
import '../../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../../widgets/apple_lyrics/layout/lyric_preferences_panel.dart';
import '../../../widgets/apple_lyrics/models/lyric_line.dart';
import '../../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../../widgets/apple_lyrics/utils/lyric_credit_filter.dart';
import '../../../widgets/player_playlist_view.dart';
import '../../../widgets/smart_artwork_image.dart';
import '../../library/song_match_sheet.dart';
import '../widgets/play_pause_morph_icon.dart';

/// YouTube Music 风格的内联歌词抽屉（配合悬浮封面缩放与跟手滑动）
class YtLyricsDrawer extends StatelessWidget {
  final Animation<double> expansion;
  final Song song;
  final VoidCallback onClose;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const YtLyricsDrawer({
    super.key,
    required this.expansion,
    required this.song,
    required this.onClose,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.paddingOf(context).top;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final drawerSlideDistance = math.max(
      200.0,
      (screenHeight - safeTop - 56.0) * 0.72,
    );

    return AnimatedBuilder(
      animation: expansion,
      child: RepaintBoundary(
        child: YtLyricsDrawerContent(
          song: song,
          onClose: onClose,
          onVerticalDragUpdate: onVerticalDragUpdate,
          onVerticalDragEnd: onVerticalDragEnd,
        ),
      ),
      builder: (context, drawerContent) {
        final t = expansion.value.clamp(0.0, 1.0);
        final miniBarOpacity = ((t - 0.25) / 0.75).clamp(0.0, 1.0);
        final sheetOpacity = (t * 1.4).clamp(0.0, 1.0);

        return Offstage(
          offstage: t <= 0.001,
          child: IgnorePointer(
            ignoring: t < 0.05,
            child: SafeArea(
              top: true,
              bottom: false,
              child: Column(
                children: [
                  SizedBox(
                    height: 56,
                    child: Opacity(
                      opacity: miniBarOpacity,
                      child: Transform.translate(
                        offset: Offset(0, -10.0 * (1.0 - t)),
                        child: YtMiniBar(
                          song: song,
                          onTap: onClose,
                          showCover: false,
                          onVerticalDragUpdate: onVerticalDragUpdate,
                          onVerticalDragEnd: onVerticalDragEnd,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Opacity(
                      opacity: sheetOpacity,
                      child: Transform.translate(
                        offset: Offset(0, (1.0 - t) * drawerSlideDistance),
                        child: drawerContent,
                      ),
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

/// 顶部常驻 Mini 控制条
class YtMiniBar extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  final bool showCover;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const YtMiniBar({
    super.key,
    required this.song,
    required this.onTap,
    this.showCover = true,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final isPlaying = context.select<PlayerProvider, bool>((p) => p.isPlaying);
    final player = context.read<PlayerProvider>();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onVerticalDragUpdate: onVerticalDragUpdate,
      onVerticalDragEnd: onVerticalDragEnd,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            if (showCover)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SmartArtworkImage(
                  artworkUri: song.artworkUri,
                  fallbackFilePath: song.localPath,
                  songId: song.id,
                  size: 40,
                ),
              )
            else
              const SizedBox(width: 40, height: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.displayName,
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
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(
                    Icons.skip_previous,
                    color: Colors.white,
                    size: 24,
                  ),
                  onPressed: () => player.previous(),
                ),
                IconButton(
                  icon: PlayPauseMorphIcon(
                    isPlaying: isPlaying,
                    size: 26,
                    color: Colors.white,
                  ),
                  onPressed: () {
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
                  onPressed: () => player.next(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 歌词抽屉内容主体
class YtLyricsDrawerContent extends StatefulWidget {
  final Song song;
  final VoidCallback onClose;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const YtLyricsDrawerContent({
    super.key,
    required this.song,
    required this.onClose,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  State<YtLyricsDrawerContent> createState() => _YtLyricsDrawerContentState();
}

class _YtLyricsDrawerContentState extends State<YtLyricsDrawerContent> {
  bool _loading = true;
  List<LyricLine> _parsedLines = const [];
  String? _loadedSongId;

  @override
  void initState() {
    super.initState();
    _loadLyricsFor(widget.song);
  }

  @override
  void didUpdateWidget(covariant YtLyricsDrawerContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.song.id != oldWidget.song.id) {
      _loadLyricsFor(widget.song);
    }
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
      setState(() {
        _loading = false;
        _parsedLines = parsed;
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

  bool get _hasRomanization {
    return _parsedLines.any(
      (line) => line.roma != null && line.roma!.isNotEmpty,
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentSong =
        context.select<PlayerProvider, Song?>((p) => p.currentSong) ??
        widget.song;

    if (_loadedSongId != currentSong.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _loadedSongId != currentSong.id) {
          _loadLyricsFor(currentSong);
        }
      });
    }

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.28),
              Colors.black.withValues(alpha: 0.54),
            ],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(
            top: BorderSide(
              color: Colors.white.withValues(alpha: 0.10),
              width: 0.5,
            ),
          ),
        ),
        child: Column(
          children: [
            _buildHandleBar(context, currentSong),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Colors.white70,
                        strokeWidth: 2,
                      ),
                    )
                  : _parsedLines.isEmpty
                  ? _buildEmptyState(context, currentSong)
                  : _buildLyricsView(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHandleBar(BuildContext context, Song currentSong) {
    final prefs = LyricPreferences.instance;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: widget.onVerticalDragUpdate,
      onVerticalDragEnd: widget.onVerticalDragEnd,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.keyboard_arrow_down,
                    color: Colors.white70,
                    size: 26,
                  ),
                  onPressed: widget.onClose,
                ),
              ),
              IgnorePointer(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_hasTranslation)
                      ListenableBuilder(
                        listenable: prefs,
                        builder: (context, _) {
                          final showTrans =
                              prefs.showTranslation &&
                              prefs.displayMode == LyricDisplayMode.translation;
                          return IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '歌词翻译',
                            icon: Icon(
                              Icons.translate_rounded,
                              color: showTrans ? Colors.white : Colors.white38,
                              size: 20,
                            ),
                            onPressed: () {
                              if (showTrans) {
                                prefs.setShowTranslation(false);
                              } else {
                                prefs.setDisplayMode(
                                  LyricDisplayMode.translation,
                                );
                                prefs.setShowTranslation(true);
                              }
                            },
                          );
                        },
                      ),
                    if (_hasRomanization)
                      ListenableBuilder(
                        listenable: prefs,
                        builder: (context, _) {
                          final showRoma =
                              prefs.showTranslation &&
                              prefs.displayMode == LyricDisplayMode.roma;
                          return IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '罗马音',
                            icon: _RomanizationGlyphIcon(
                              color: showRoma ? Colors.white : Colors.white38,
                              size: 20,
                            ),
                            onPressed: () {
                              if (showRoma) {
                                prefs.setShowTranslation(false);
                              } else {
                                prefs.setDisplayMode(LyricDisplayMode.roma);
                                prefs.setShowTranslation(true);
                              }
                            },
                          );
                        },
                      ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.tune_rounded,
                        color: Colors.white70,
                        size: 20,
                      ),
                      tooltip: '歌词显示设置',
                      onPressed: () {
                        showM3EModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerLow,
                          builder: (_) =>
                              const SafeArea(child: LyricPreferencesPanel()),
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

  Widget _buildLyricsView(BuildContext context) {
    final isPlaying = context.select<PlayerProvider, bool>((p) => p.isPlaying);
    final player = context.read<PlayerProvider>();

    return ListenableBuilder(
      listenable: LyricPreferences.instance,
      builder: (context, _) {
        final filteredLines = LyricCreditFilter.filterLines(_parsedLines);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: AppleLyricsView(
            lines: filteredLines,
            currentTimeMs: player.position.inMilliseconds,
            positionListenable: player.positionNotifier,
            isPlaying: isPlaying,
            playbackNotReady: false,
            onSeek: (timeMs) => player.seek(Duration(milliseconds: timeMs)),
            forceDarkBackground: true,
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context, Song currentSong) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.music_off_outlined, color: Colors.white38, size: 48),
          const SizedBox(height: 12),
          const Text(
            '暂无歌词',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white30),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            onPressed: () async {
              await showSongMatchSheet(context, currentSong);
              if (mounted) {
                _loadLyricsFor(currentSong, force: true);
              }
            },
            child: const Text('搜索匹配歌词'),
          ),
        ],
      ),
    );
  }
}

/// 精致重绘的「罗马音（あa）」矢量图标，笔触粗细与左侧 `Icons.translate_rounded`（文A）1:1 对仗
class _RomanizationGlyphIcon extends StatelessWidget {
  final Color color;
  final double size;

  const _RomanizationGlyphIcon({required this.color, this.size = 20});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _RomanizationGlyphPainter(color: color)),
    );
  }
}

class _RomanizationGlyphPainter extends CustomPainter {
  final Color color;

  const _RomanizationGlyphPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.85 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 1. 左上角：日文假名「あ」的精炼几何特征（上横 + 微弯中轴 + 回环弧线）
    final hLine = Path()
      ..moveTo(3.2 * s, 5.5 * s)
      ..quadraticBezierTo(7.5 * s, 5.2 * s, 11.4 * s, 5.0 * s);
    canvas.drawPath(hLine, paint);

    final vStem = Path()
      ..moveTo(7.3 * s, 2.8 * s)
      ..quadraticBezierTo(6.9 * s, 8.2 * s, 7.6 * s, 13.8 * s);
    canvas.drawPath(vStem, paint);

    final kanaLoop = Path()
      ..moveTo(10.5 * s, 7.6 * s)
      ..cubicTo(9.0 * s, 12.2 * s, 4.2 * s, 14.2 * s, 3.3 * s, 11.4 * s)
      ..cubicTo(2.6 * s, 9.1 * s, 6.2 * s, 7.3 * s, 9.8 * s, 8.3 * s)
      ..cubicTo(12.2 * s, 9.0 * s, 12.5 * s, 12.1 * s, 10.2 * s, 13.8 * s);
    canvas.drawPath(kanaLoop, paint);

    // 2. 右下角：精致小写拉丁字母「a」（圆腹 + 顶部微挑弧 + 右侧收笔竖钩）
    final latinTop = Path()
      ..moveTo(14.2 * s, 13.6 * s)
      ..cubicTo(15.2 * s, 12.0 * s, 19.6 * s, 11.9 * s, 19.8 * s, 14.8 * s)
      ..lineTo(19.8 * s, 19.6 * s)
      ..quadraticBezierTo(19.8 * s, 20.8 * s, 21.0 * s, 20.8 * s);
    canvas.drawPath(latinTop, paint);

    final latinBowl = Path()
      ..moveTo(19.7 * s, 16.2 * s)
      ..cubicTo(16.2 * s, 15.8 * s, 13.4 * s, 16.9 * s, 13.6 * s, 19.1 * s)
      ..cubicTo(13.8 * s, 21.1 * s, 17.8 * s, 21.2 * s, 19.7 * s, 19.2 * s);
    canvas.drawPath(latinBowl, paint);
  }

  @override
  bool shouldRepaint(covariant _RomanizationGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 1:1 复刻歌词展开动画的全屏「接下来播放」歌单抽屉（配合 FullPlayerYt 悬浮封面飞行缩放）
class YtQueueDrawer extends StatefulWidget {
  final Animation<double> expansion;
  final Song song;
  final PlaylistScrollAnchor scrollAnchor;
  final VoidCallback onClose;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const YtQueueDrawer({
    super.key,
    required this.expansion,
    required this.song,
    required this.scrollAnchor,
    required this.onClose,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  State<YtQueueDrawer> createState() => _YtQueueDrawerState();
}

class _YtQueueDrawerState extends State<YtQueueDrawer> {
  double? _pointerStartY;
  bool _capturingPullDown = false;
  double _lastStepDy = 0.0;

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.paddingOf(context).top;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final drawerSlideDistance = math.max(
      200.0,
      (screenHeight - safeTop - 56.0) * 0.72,
    );

    return AnimatedBuilder(
      animation: widget.expansion,
      child: RepaintBoundary(child: _buildSheetContent(context, safeBottom)),
      builder: (context, sheetChild) {
        final t = widget.expansion.value.clamp(0.0, 1.0);
        final miniBarOpacity = ((t - 0.25) / 0.75).clamp(0.0, 1.0);
        final sheetOpacity = (t * 1.4).clamp(0.0, 1.0);

        return Offstage(
          offstage: t <= 0.001,
          child: IgnorePointer(
            ignoring: t < 0.05,
            child: SafeArea(
              top: true,
              bottom: false,
              child: Column(
                children: [
                  SizedBox(
                    height: 56,
                    child: Opacity(
                      opacity: miniBarOpacity,
                      child: Transform.translate(
                        offset: Offset(0, -10.0 * (1.0 - t)),
                        child: YtMiniBar(
                          song: widget.song,
                          onTap: widget.onClose,
                          showCover: false,
                          onVerticalDragUpdate: widget.onVerticalDragUpdate,
                          onVerticalDragEnd: widget.onVerticalDragEnd,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Opacity(
                      opacity: sheetOpacity,
                      child: Transform.translate(
                        offset: Offset(0, (1.0 - t) * drawerSlideDistance),
                        child: sheetChild,
                      ),
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

  Widget _buildSheetContent(BuildContext context, double safeBottom) {
    final currentSong =
        context.select<PlayerProvider, Song?>((p) => p.currentSong) ??
        widget.song;
    final sourceTitle =
        currentSong.album.isNotEmpty && currentSong.album != '未知专辑'
        ? currentSong.album
        : currentSong.displayName;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.34),
              Colors.black.withValues(alpha: 0.62),
            ],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(
            top: BorderSide(
              color: Colors.white.withValues(alpha: 0.10),
              width: 0.5,
            ),
          ),
        ),
        child: Column(
          children: [
            // 顶部把手与「播放的音乐来自 + 保存」头部
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: widget.onVerticalDragUpdate,
              onVerticalDragEnd: widget.onVerticalDragEnd,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 16, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(
                            Icons.keyboard_arrow_down,
                            color: Colors.white70,
                            size: 26,
                          ),
                          onPressed: widget.onClose,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                '播放的音乐来自',
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 11.5,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                sourceTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        InkWell(
                          onTap: () =>
                              showAddToPlaylistDialog(context, currentSong),
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.playlist_add,
                                  size: 18,
                                  color: Colors.white,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  '保存',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // 列表主体：当列表位于顶部且继续下拉时，无缝转发拖拽手势跟手收起抽屉
            Expanded(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (e) {
                  _pointerStartY = e.position.dy;
                  _capturingPullDown = false;
                  _lastStepDy = 0.0;
                },
                onPointerMove: (e) {
                  final startY = _pointerStartY;
                  if (startY == null) return;
                  final totalDy = e.position.dy - startY;
                  final sc = widget.scrollAnchor.controller;
                  final atTop = !sc.hasClients || sc.offset <= 1.0;
                  if (!_capturingPullDown && totalDy > 8.0 && atTop) {
                    _capturingPullDown = true;
                  }
                  if (_capturingPullDown) {
                    if (sc.hasClients && sc.offset > 0) {
                      sc.jumpTo(0);
                    }
                    _lastStepDy = e.delta.dy;
                    widget.onVerticalDragUpdate?.call(
                      DragUpdateDetails(
                        globalPosition: e.position,
                        localPosition: e.localPosition,
                        delta: Offset(0, e.delta.dy),
                        primaryDelta: e.delta.dy,
                      ),
                    );
                  }
                },
                onPointerUp: (_) {
                  if (_capturingPullDown) {
                    _capturingPullDown = false;
                    final velocity = _lastStepDy * 55.0;
                    widget.onVerticalDragEnd?.call(
                      DragEndDetails(
                        velocity: Velocity(
                          pixelsPerSecond: Offset(0, velocity),
                        ),
                        primaryVelocity: velocity,
                      ),
                    );
                  }
                  _pointerStartY = null;
                },
                onPointerCancel: (_) {
                  if (_capturingPullDown) {
                    _capturingPullDown = false;
                    widget.onVerticalDragEnd?.call(DragEndDetails());
                  }
                  _pointerStartY = null;
                },
                child: Padding(
                  padding: EdgeInsets.only(bottom: safeBottom),
                  child: PlayerPlaylistView(scrollAnchor: widget.scrollAnchor),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
