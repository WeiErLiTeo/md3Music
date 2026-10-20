import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/local_lyric_loader.dart';
import '../../../data/models/song.dart';
import '../../../data/repositories/song_match_repository.dart';
import '../../../providers/kugou_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/apple_lyrics/apple_lyrics_view.dart';
import '../../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../../widgets/apple_lyrics/models/lyric_line.dart';
import '../../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../../widgets/smart_artwork_image.dart';
import '../../library/song_match_sheet.dart';

/// YouTube Music 风格的歌词 Sheet 容器
class YtLyricsSheet extends StatelessWidget {
  final Song song;

  const YtLyricsSheet({
    super.key,
    required this.song,
  });

  /// 弹出 YT 风格歌词抽屉
  static void show(BuildContext context, Song song) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        reverseDuration: Duration(milliseconds: 260),
        reverseCurve: Curves.easeInCubic,
      ),
      builder: (sheetContext) => YtLyricsSheet(song: song),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final currentSong = player.currentSong ?? song;
    final topInset = MediaQuery.viewPaddingOf(context).top;
    final screenHeight = MediaQuery.sizeOf(context).height;

    return SizedBox(
      height: screenHeight,
      child: SafeArea(
        top: true,
        bottom: false,
        child: Column(
          children: [
            if (topInset > 0) SizedBox(height: math.max(topInset, 16.0)),
            // 顶部常驻 Mini 控制条：40x40 圆角封面 + 左对齐纯净歌名/歌手 + 紧凑播放控件
            SizedBox(
              height: 56,
              child: YtMiniBar(
                song: currentSong,
                onTap: () => Navigator.pop(context),
              ),
            ),
            // 歌词抽屉主体：停在 MiniBar 下方，半透明透出背景
            Expanded(
              child: YtLyricsDrawerContent(
                song: currentSong,
                onClose: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部常驻 Mini 控制条
class YtMiniBar extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;

  const YtMiniBar({
    super.key,
    required this.song,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            // 40x40 缩略封面
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SmartArtworkImage(
                artworkUri: song.artworkUri,
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
            // 紧凑控制器
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
                  icon: Icon(
                    player.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 28,
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

  const YtLyricsDrawerContent({
    super.key,
    required this.song,
    required this.onClose,
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

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 25, sigmaY: 25),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.22),
                Colors.black.withValues(alpha: 0.45),
              ],
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // 拖拽把手与工具栏
              _buildHandleBar(context, currentSong),
              // 歌词核心展示区
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
                        : _buildLyricsView(context, player),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHandleBar(BuildContext context, Song currentSong) {
    final prefs = LyricPreferences.instance;

    return Padding(
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
                final showTrans = prefs.showTranslation;
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
                    prefs.setShowTranslation(!showTrans);
                  },
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70, size: 20),
            onPressed: () => _loadLyricsFor(currentSong, force: true),
          ),
        ],
      ),
    );
  }

  Widget _buildLyricsView(BuildContext context, PlayerProvider player) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: AppleLyricsView(
        lines: _parsedLines,
        currentTimeMs: player.position.inMilliseconds,
        positionListenable: player.positionNotifier,
        isPlaying: player.isPlaying,
        playbackNotReady: false,
        onSeek: (timeMs) => player.seek(
          Duration(milliseconds: timeMs),
        ),
        forceDarkBackground: true,
      ),
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
