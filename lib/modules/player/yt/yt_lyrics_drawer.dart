import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/local_lyric_loader.dart';
import '../../../data/models/song.dart';
import '../../../data/repositories/song_match_repository.dart';
import '../../../providers/kugou_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/apple_lyrics/apple_lyrics_view.dart';
import '../../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../../widgets/apple_lyrics/layout/lyric_preferences_panel.dart';
import '../../../widgets/apple_lyrics/models/lyric_line.dart';
import '../../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../../widgets/apple_lyrics/utils/lyric_credit_filter.dart';
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
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(
                Icons.keyboard_arrow_down,
                color: Colors.white70,
                size: 26,
              ),
              onPressed: widget.onClose,
            ),
            const Spacer(),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Spacer(),
            if (_hasTranslation)
              ListenableBuilder(
                listenable: prefs,
                builder: (context, _) {
                  final showTrans =
                      prefs.showTranslation &&
                      prefs.displayMode == LyricDisplayMode.translation;
                  return IconButton(
                    icon: Text(
                      '译',
                      style: TextStyle(
                        color: showTrans ? Colors.white : Colors.white38,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onPressed: () {
                      if (showTrans) {
                        prefs.setShowTranslation(false);
                      } else {
                        prefs.setDisplayMode(LyricDisplayMode.translation);
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
                    icon: Text(
                      '音',
                      style: TextStyle(
                        color: showRoma ? Colors.white : Colors.white38,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
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
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceContainerLow,
                  builder: (_) =>
                      const SafeArea(child: LyricPreferencesPanel()),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white70, size: 20),
              onPressed: () => _loadLyricsFor(currentSong, force: true),
            ),
          ],
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
            onSeek: (timeMs) => player.seek(
              Duration(milliseconds: timeMs),
            ),
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
          const Icon(
            Icons.music_off_outlined,
            color: Colors.white38,
            size: 48,
          ),
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
              await showSongMatchSheet(
                context,
                currentSong,
              );
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
