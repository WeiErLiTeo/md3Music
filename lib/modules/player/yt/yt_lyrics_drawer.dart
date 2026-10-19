import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/app_toast.dart';

import '../../../core/utils/local_lyric_loader.dart';
import '../../../data/models/song.dart';
import '../../../data/repositories/song_match_repository.dart';
import '../../../providers/kugou_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/apple_lyrics/apple_lyrics_view.dart';
import '../../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../../widgets/apple_lyrics/models/lyric_line.dart';
import '../../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../library/song_match_sheet.dart';

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
            const SizedBox(width: 42 + 12),
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

class YtLyricsDrawer extends StatefulWidget {
  final Song song;
  final VoidCallback onClose;
  final GestureDragUpdateCallback onVerticalDragUpdate;
  final GestureDragEndCallback onVerticalDragEnd;

  const YtLyricsDrawer({
    super.key,
    required this.song,
    required this.onClose,
    required this.onVerticalDragUpdate,
    required this.onVerticalDragEnd,
  });

  @override
  State<YtLyricsDrawer> createState() => _YtLyricsDrawerState();
}

class _YtLyricsDrawerState extends State<YtLyricsDrawer> {
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
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xEB161616),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: widget.onVerticalDragUpdate,
                onVerticalDragEnd: widget.onVerticalDragEnd,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(
                      child: Container(
                        margin: const EdgeInsets.only(top: 10, bottom: 6),
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.24),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
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
                            onPressed: widget.onClose,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
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
                                    return LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: const [
                                        Colors.transparent,
                                        Colors.black,
                                        Colors.black,
                                      ],
                                      stops: [0.0, topStop, 1.0],
                                    ).createShader(bounds);
                                  },
                                  blendMode: BlendMode.dstIn,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                    ),
                                    child: AppleLyricsView(
                                      lines: _parsedLines,
                                      currentTimeMs: 0,
                                      positionListenable:
                                          player.positionNotifier,
                                      isPlaying: player.isPlaying,
                                      playbackNotReady:
                                          player.isPlaybackNotReady,
                                      forceDarkBackground: true,
                                      onSeek: (positionMs) {
                                        player.seek(
                                          Duration(milliseconds: positionMs),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                    ),
                    if (_hasTranslation)
                      Positioned(
                        right: 20,
                        bottom: 24,
                        child: ListenableBuilder(
                          listenable: LyricPreferences.instance,
                          builder: (context, _) {
                            final showTrans =
                                LyricPreferences.instance.showTranslation;
                            return Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () {
                                  LyricPreferences.instance
                                      .setShowTranslation(!showTrans);
                                },
                                borderRadius: BorderRadius.circular(20),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: showTrans
                                        ? Colors.white.withValues(alpha: 0.22)
                                        : Colors.white.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: showTrans
                                          ? Colors.white54
                                          : Colors.white24,
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.translate,
                                        size: 16,
                                        color: showTrans
                                            ? Colors.white
                                            : Colors.white70,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '文A 翻译',
                                        style: TextStyle(
                                          color: showTrans
                                              ? Colors.white
                                              : Colors.white70,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
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
          Icon(
            Icons.lyrics_outlined,
            size: 48,
            color: Colors.white.withValues(alpha: 0.38),
          ),
          const SizedBox(height: 12),
          Text(
            '暂无歌词',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            icon: const Icon(Icons.search, size: 18),
            label: const Text('搜索匹配歌词'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            onPressed: () {
              showSongMatchSheet(context, currentSong);
            },
          ),
        ],
      ),
    );
  }
}
