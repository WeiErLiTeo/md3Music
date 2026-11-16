import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../../core/services/audio_service.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/utils/local_lyric_loader.dart';
import '../../../core/utils/lyric_line_balance.dart';
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
import '../../../widgets/player_artwork_image.dart';
import '../../../widgets/player_playlist_view.dart';
import '../../library/song_match_sheet.dart';
import '../comments_view.dart';
import '../widgets/play_pause_morph_icon.dart';
import 'yt_background.dart';

/// 拆分 KRC 中将整句或多歌手名（含内部空格或 `/`、`\`）打包为单个 [LyricWord] 的复合词，
/// 避免单词超宽无法换行或行高预留不足导致重叠。
List<LyricLine> _normalizeCompoundWords(List<LyricLine> lines) {
  List<LyricLine>? out;
  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.words.isEmpty) continue;
    bool needsSplit = false;
    for (final w in line.words) {
      final trimmed = w.text.trim();
      if (trimmed.length >= 4 &&
          (trimmed.contains(' ') ||
              trimmed.contains('/') ||
              trimmed.contains('\\'))) {
        needsSplit = true;
        break;
      }
    }
    if (!needsSplit) continue;

    final newWords = <LyricWord>[];
    for (final w in line.words) {
      final trimmed = w.text.trim();
      if (trimmed.length < 4 ||
          (!trimmed.contains(' ') &&
              !trimmed.contains('/') &&
              !trimmed.contains('\\'))) {
        newWords.add(w);
        continue;
      }
      final rawUnits = segmentLyricUnits(
        w.text.replaceAll('/', '/ ').replaceAll('\\', '\\ '),
      );
      final mergedUnits = <String>[];
      for (final u in rawUnits) {
        final restored = u.replaceAll('/ ', '/').replaceAll('\\ ', '\\');
        if (restored.trim().isEmpty && mergedUnits.isNotEmpty) {
          mergedUnits[mergedUnits.length - 1] = mergedUnits.last + restored;
        } else if (restored.isNotEmpty) {
          mergedUnits.add(restored);
        }
      }
      if (mergedUnits.length <= 1) {
        newWords.add(w);
        continue;
      }
      final totalLen = w.text.length;
      int offsetChars = 0;
      for (int idx = 0; idx < mergedUnits.length; idx++) {
        final piece = mergedUnits[idx];
        final startRatio = offsetChars / totalLen;
        final endRatio = (offsetChars + piece.length) / totalLen;
        final pieceStart = w.startTime + (w.duration * startRatio).round();
        final pieceEnd = idx == mergedUnits.length - 1
            ? w.startTime + w.duration
            : w.startTime + (w.duration * endRatio).round();
        newWords.add(
          LyricWord(
            startTime: pieceStart,
            duration: (pieceEnd - pieceStart).clamp(0, w.duration),
            text: piece,
          ),
        );
        offsetChars += piece.length;
      }
    }
    out ??= List<LyricLine>.of(lines);
    out[i] = line.copyWith(words: newWords);
  }
  return out ?? lines;
}

/// 轻量级派生淡入动画：配合 [FadeTransition] 直接更新 GPU OpacityLayer，
/// 避免动画 `Opacity` 在每帧重分配离屏 `saveLayer` 造成掉帧。
class YtDrawerFadeAnimation extends Animation<double> {
  final Listenable _parent;
  final double Function() _compute;

  const YtDrawerFadeAnimation({
    required Listenable parent,
    required double Function() compute,
  }) : _parent = parent,
       _compute = compute;

  @override
  void addListener(VoidCallback listener) => _parent.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _parent.removeListener(listener);

  @override
  void addStatusListener(AnimationStatusListener listener) {}

  @override
  void removeStatusListener(AnimationStatusListener listener) {}

  @override
  AnimationStatus get status {
    final v = value;
    if (v <= 0.0) return AnimationStatus.dismissed;
    if (v >= 1.0) return AnimationStatus.completed;
    return AnimationStatus.forward;
  }

  @override
  double get value => _compute().clamp(0.0, 1.0);
}

class YtCachedLyricsEntry {
  final List<LyricLine> parsedLines;
  final String rawLyricText;

  const YtCachedLyricsEntry({
    required this.parsedLines,
    required this.rawLyricText,
  });
}

/// YT 抽屉歌词内存缓存与预热池：
/// - 播放页打开平稳后在后台预取并解析，点击「歌词」瞬间首帧直出，无加载菊花或解析卡顿；
/// - 同时保留原始歌词文本，供歌曲百科抽屉提取作词/作曲/编曲等制作人员名单。
class YtLyricsCache {
  YtLyricsCache._();

  static const int _maxEntries = 24;
  static final Map<String, YtCachedLyricsEntry> _entries =
      <String, YtCachedLyricsEntry>{};
  static final Map<String, Future<YtCachedLyricsEntry>> _inflight =
      <String, Future<YtCachedLyricsEntry>>{};

  static YtCachedLyricsEntry? get(String songId) {
    final hit = _entries.remove(songId);
    if (hit != null) {
      _entries[songId] = hit;
    }
    return hit;
  }

  static void invalidate(String songId) {
    _entries.remove(songId);
  }

  static void _put(String songId, YtCachedLyricsEntry entry) {
    _entries.remove(songId);
    _entries[songId] = entry;
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  static Future<YtCachedLyricsEntry> load(
    Song song,
    KugouProvider kugouProvider, {
    bool force = false,
  }) {
    if (!force) {
      final cached = get(song.id);
      if (cached != null) {
        return Future<YtCachedLyricsEntry>.value(cached);
      }
      final pending = _inflight[song.id];
      if (pending != null) return pending;
    } else {
      invalidate(song.id);
    }

    final future = _fetchAndParse(song, kugouProvider).whenComplete(() {
      _inflight.remove(song.id);
    });
    _inflight[song.id] = future;
    return future;
  }

  static Future<void> prewarm(Song song, KugouProvider kugouProvider) async {
    if (get(song.id) != null || _inflight.containsKey(song.id)) return;
    try {
      await load(song, kugouProvider);
    } catch (_) {}
  }

  static Future<YtCachedLyricsEntry> _fetchAndParse(
    Song song,
    KugouProvider kugouProvider,
  ) async {
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

    if (lyricText.isEmpty) {
      return const YtCachedLyricsEntry(parsedLines: [], rawLyricText: '');
    }

    final parsed = _normalizeCompoundWords(
      LyricParserChain.parse(
        lyricText,
        translationText: translationText,
        romaText: romaText,
      ),
    );
    final entry = YtCachedLyricsEntry(
      parsedLines: parsed,
      rawLyricText: lyricText,
    );
    _put(song.id, entry);
    return entry;
  }

  static final RegExp _krcPrefixRe = RegExp(r'^\[\d+,\d+\]');
  static final RegExp _krcWordTagRe = RegExp(r'<[^>]*>');
  static final RegExp _lrcTimeRe = RegExp(r'^\[\d{2}:\d{2}(?:\.\d{2,3})?\]');
  static final RegExp _metaTagRe = RegExp(r'^\[[A-Za-z][A-Za-z0-9]*:.*\]$');
  static final RegExp _creditPairRe = RegExp(
    r'^(作词|作曲|编曲|制作人|监制|词|曲|编|混音|母带|录音|人声录音|人声编辑|和声|和音|配唱|吉他|贝斯|鼓|键盘|弦乐|弦乐编写|制作|统筹|企划|出品|发行|唱片|OP|SP|Lyrics\s+by|Composed\s+by|Produced\s+by|Written\s+by|Arranged\s+by|Mixed\s+by|Mastered\s+by|Recorded\s+by)\s*[：:]\s*(.+)$',
    caseSensitive: false,
  );

  /// 从原始歌词头部提取制作名单（作词/作曲/编曲/制作人等），用于歌曲百科卡片展示。
  static List<({String role, String value})> extractCredits(
    String rawLyricText,
  ) {
    if (rawLyricText.isEmpty) return const [];
    final results = <({String role, String value})>[];
    final seen = <String>{};
    final lines = rawLyricText.split(RegExp(r'\r?\n'));
    final scanLimit = math.min(lines.length, 40);
    for (int i = 0; i < scanLimit; i++) {
      var clean = lines[i].trim();
      if (clean.isEmpty) continue;
      if (_metaTagRe.hasMatch(clean)) continue;
      clean = clean
          .replaceFirst(_krcPrefixRe, '')
          .replaceAll(_krcWordTagRe, '')
          .replaceFirst(_lrcTimeRe, '')
          .trim();
      if (clean.isEmpty) continue;
      final m = _creditPairRe.firstMatch(clean);
      if (m == null) {
        if (results.isNotEmpty && i > 18) break;
        continue;
      }
      final rawRole = m.group(1)!.trim();
      final val = m.group(2)!.trim();
      if (val.isEmpty) continue;
      final role = _normalizeRole(rawRole);
      final key = '$role:$val';
      if (seen.add(key)) {
        results.add((role: role, value: val));
      }
    }
    return results;
  }

  static String _normalizeRole(String raw) {
    final lower = raw.toLowerCase();
    return switch (lower) {
      '词' || 'lyrics by' => '作词',
      '曲' || 'composed by' => '作曲',
      '编' || 'arranged by' => '编曲',
      'produced by' => '制作人',
      'mixed by' => '混音',
      'mastered by' => '母带',
      'recorded by' => '录音',
      'written by' => '词曲',
      'op' => 'OP',
      'sp' => 'SP',
      _ => raw,
    };
  }
}

/// YouTube Music 风格的内联歌词抽屉（配合悬浮封面缩放与跟手滑动）
class YtLyricsDrawer extends StatefulWidget {
  final Animation<double> expansion;
  final Song song;
  final bool isVideoMode;
  final VideoPlayerController? videoController;
  final VoidCallback onClose;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const YtLyricsDrawer({
    super.key,
    required this.expansion,
    required this.song,
    this.isVideoMode = false,
    this.videoController,
    required this.onClose,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  State<YtLyricsDrawer> createState() => _YtLyricsDrawerState();
}

class _YtLyricsDrawerState extends State<YtLyricsDrawer> {
  Widget? _cachedContent;
  String? _cachedSongId;
  Widget? _cachedMiniBar;
  String? _cachedMiniKey;
  late Animation<double> _miniFadeAnim;
  late Animation<double> _sheetFadeAnim;

  @override
  void initState() {
    super.initState();
    _initFadeAnims();
  }

  @override
  void didUpdateWidget(covariant YtLyricsDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expansion != widget.expansion) {
      _initFadeAnims();
    }
  }

  void _initFadeAnims() {
    _miniFadeAnim = YtDrawerFadeAnimation(
      parent: widget.expansion,
      compute: () => (widget.expansion.value - 0.25) / 0.75,
    );
    _sheetFadeAnim = YtDrawerFadeAnimation(
      parent: widget.expansion,
      compute: () => widget.expansion.value * 1.4,
    );
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.paddingOf(context).top;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final drawerSlideDistance = math.max(
      200.0,
      (screenHeight - safeTop - 56.0) * 0.72,
    );

    return AnimatedBuilder(
      animation: widget.expansion,
      builder: (context, _) {
        final t = widget.expansion.value.clamp(0.0, 1.0);
        if (t <= 0.001) {
          return const SizedBox.shrink();
        }
        if (_cachedContent == null || _cachedSongId != widget.song.id) {
          _cachedSongId = widget.song.id;
          _cachedContent = RepaintBoundary(
            child: YtLyricsDrawerContent(
              song: widget.song,
              onClose: widget.onClose,
              onVerticalDragUpdate: widget.onVerticalDragUpdate,
              onVerticalDragEnd: widget.onVerticalDragEnd,
            ),
          );
        }
        final miniKey =
            '${widget.song.id}_${widget.song.artworkUri}_${widget.isVideoMode}_${identityHashCode(widget.videoController)}';
        if (_cachedMiniBar == null || _cachedMiniKey != miniKey) {
          _cachedMiniKey = miniKey;
          _cachedMiniBar = RepaintBoundary(
            child: YtMiniBar(
              song: widget.song,
              onTap: widget.onClose,
              showCover: false,
              hideCoverSlot: widget.isVideoMode,
              videoController: widget.videoController,
              onVerticalDragUpdate: widget.onVerticalDragUpdate,
              onVerticalDragEnd: widget.onVerticalDragEnd,
            ),
          );
        }

        return IgnorePointer(
          ignoring: t < 0.05,
          child: SafeArea(
            top: true,
            bottom: false,
            child: Column(
              children: [
                SizedBox(
                  height: 56,
                  child: FadeTransition(
                    opacity: _miniFadeAnim,
                    child: Transform.translate(
                      offset: Offset(0, -10.0 * (1.0 - t)),
                      child: _cachedMiniBar,
                    ),
                  ),
                ),
                Expanded(
                  child: FadeTransition(
                    opacity: _sheetFadeAnim,
                    child: Transform.translate(
                      offset: Offset(0, (1.0 - t) * drawerSlideDistance),
                      child: _cachedContent,
                    ),
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

/// 顶部常驻 Mini 控制条
class YtMiniBar extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  final bool showCover;
  final bool hideCoverSlot;
  final VideoPlayerController? videoController;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const YtMiniBar({
    super.key,
    required this.song,
    required this.onTap,
    this.showCover = true,
    this.hideCoverSlot = false,
    this.videoController,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final state = context.select<PlayerProvider, ({bool isPlaying, bool isBuffering})>(
      (p) => (
        isPlaying: p.isPlaying,
        isBuffering:
            p.isStreamBuffering ||
            p.isWaitingForAudioStart ||
            p.isAwaitingPlaybackProgress,
      ),
    );
    final player = context.read<PlayerProvider>();
    final audioService = AudioService();
    final vCtrl = videoController;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onVerticalDragUpdate: onVerticalDragUpdate,
      onVerticalDragEnd: onVerticalDragEnd,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            if (showCover) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: PlayerArtworkImage(
                    artworkUri: song.artworkUri,
                    fallbackFilePath: song.localPath,
                    isFill: true,
                    fit: BoxFit.cover,
                    iconSize: 20,
                    backgroundColor: Colors.white12,
                    iconColor: Colors.white54,
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ] else if (!hideCoverSlot) ...[
              const SizedBox(width: 40, height: 40),
              const SizedBox(width: 12),
            ],
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
                if (hideCoverSlot && vCtrl != null && vCtrl.value.isInitialized)
                  ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: vCtrl,
                    builder: (context, vVal, _) {
                      return IconButton(
                        icon: PlayPauseMorphIcon(
                          isPlaying: vVal.isPlaying,
                          size: 26,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          if (vCtrl.value.isPlaying) {
                            vCtrl.pause();
                          } else {
                            if (vCtrl.value.position >=
                                vCtrl.value.duration -
                                    const Duration(milliseconds: 300)) {
                              vCtrl.seekTo(Duration.zero);
                            }
                            vCtrl.play();
                          }
                        },
                      );
                    },
                  )
                else
                  StreamBuilder<bool>(
                    stream: audioService.playingStream,
                    initialData: audioService.playing,
                    builder: (context, snapshot) {
                      final enginePlaying = snapshot.data ?? false;
                      final effectivePlaying = state.isPlaying || enginePlaying;
                      final showPauseIcon =
                          effectivePlaying && !state.isBuffering;
                      return IconButton(
                        icon: PlayPauseMorphIcon(
                          isPlaying: showPauseIcon,
                          size: 26,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          if (player.isPlaying || audioService.playing) {
                            player.pause();
                          } else {
                            player.resume();
                          }
                        },
                      );
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
    final cached = YtLyricsCache.get(widget.song.id);
    if (cached != null) {
      _loadedSongId = widget.song.id;
      _loading = false;
      _parsedLines = cached.parsedLines;
    } else {
      _loadLyricsFor(widget.song, notify: false);
    }
  }

  @override
  void didUpdateWidget(covariant YtLyricsDrawerContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.song.id != oldWidget.song.id) {
      _loadLyricsFor(widget.song);
    }
  }

  Future<void> _loadLyricsFor(
    Song song, {
    bool force = false,
    bool notify = true,
  }) async {
    if (!force && _loadedSongId == song.id) return;
    _loadedSongId = song.id;

    if (!force) {
      final cached = YtLyricsCache.get(song.id);
      if (cached != null) {
        if (mounted) {
          if (notify) {
            setState(() {
              _loading = false;
              _parsedLines = cached.parsedLines;
            });
          } else {
            _loading = false;
            _parsedLines = cached.parsedLines;
          }
        }
        return;
      }
    }

    if (mounted) {
      if (notify) {
        setState(() {
          _loading = true;
          _parsedLines = const [];
        });
      } else {
        _loading = true;
        _parsedLines = const [];
      }
    }

    final kugouProvider = context.read<KugouProvider>();
    final entry = await YtLyricsCache.load(
      song,
      kugouProvider,
      force: force,
    );
    if (!mounted || _loadedSongId != song.id) return;

    setState(() {
      _loading = false;
      _parsedLines = entry.parsedLines;
    });
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

    return ListenableBuilder(
      listenable: YtPaletteTheme.instance,
      builder: (context, _) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: Container(
            decoration: YtPaletteTheme.drawerDecoration(),
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
      },
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

/// 清晰高锐度的「罗马音（あa）」图标，使用原生字形光栅化渲染以对齐 `Icons.translate_rounded`
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
    final kanaPainter = TextPainter(
      text: TextSpan(
        text: 'あ',
        style: TextStyle(
          color: color,
          fontSize: size.width * 0.56,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final latinPainter = TextPainter(
      text: TextSpan(
        text: 'a',
        style: TextStyle(
          color: color,
          fontSize: size.width * 0.58,
          fontWeight: FontWeight.w800,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    kanaPainter.paint(
      canvas,
      Offset(size.width * 0.02, size.height * 0.02),
    );
    latinPainter.paint(
      canvas,
      Offset(
        size.width - latinPainter.width - size.width * 0.04,
        size.height - latinPainter.height - size.height * 0.02,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _RomanizationGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 1:1 复刻歌词展开动画的全屏「接下来播放」歌单抽屉（配合 FullPlayerYt 悬浮封面飞行缩放）
class YtQueueDrawer extends StatefulWidget {
  final Animation<double> expansion;
  final Song song;
  final bool isVideoMode;
  final VideoPlayerController? videoController;
  final PlaylistScrollAnchor scrollAnchor;
  final GlobalKey<PlayerPlaylistViewState>? playlistKey;
  final VoidCallback onClose;
  final VoidCallback? onOpenSave;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const YtQueueDrawer({
    super.key,
    required this.expansion,
    required this.song,
    this.isVideoMode = false,
    this.videoController,
    required this.scrollAnchor,
    this.playlistKey,
    required this.onClose,
    this.onOpenSave,
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

  PlaylistSortBy _sortBy = PlaylistSortBy.queue;
  bool _sortAscending = true;
  final List<String> _originalQueueIds = <String>[];
  final GlobalKey _sortAnchorKey = GlobalKey();
  Widget? _cachedMiniBar;
  String? _cachedMiniKey;
  Widget? _cachedSheet;
  String? _cachedSheetKey;
  late Animation<double> _miniFadeAnim;
  late Animation<double> _sheetFadeAnim;

  @override
  void initState() {
    super.initState();
    _initFadeAnims();
  }

  @override
  void didUpdateWidget(covariant YtQueueDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expansion != widget.expansion) {
      _initFadeAnims();
    }
  }

  void _initFadeAnims() {
    _miniFadeAnim = YtDrawerFadeAnimation(
      parent: widget.expansion,
      compute: () => (widget.expansion.value - 0.25) / 0.75,
    );
    _sheetFadeAnim = YtDrawerFadeAnimation(
      parent: widget.expansion,
      compute: () => widget.expansion.value * 1.4,
    );
  }

  void _syncOriginalQueueSnapshot(List<Song> currentPlaylist) {
    if (currentPlaylist.isEmpty) {
      _originalQueueIds.clear();
      return;
    }
    final currentIds = currentPlaylist.map((s) => s.id).toSet();
    _originalQueueIds.removeWhere((id) => !currentIds.contains(id));
    final known = _originalQueueIds.toSet();
    for (final s in currentPlaylist) {
      if (!known.contains(s.id)) {
        _originalQueueIds.add(s.id);
        known.add(s.id);
      }
    }
  }

  Future<void> _applyQueueSort(
    PlayerProvider playerProvider,
    PlaylistSortBy by,
    bool ascending,
  ) async {
    final playlist = playerProvider.playlist;
    if (playlist.length < 2) return;
    _syncOriginalQueueSnapshot(playlist);

    final orderIndexMap = <String, int>{
      for (int i = 0; i < _originalQueueIds.length; i++)
        _originalQueueIds[i]: i,
    };

    final targetOrder = List<Song>.from(playlist);
    targetOrder.sort((a, b) {
      int cmp;
      switch (by) {
        case PlaylistSortBy.queue:
          final ia = orderIndexMap[a.id] ?? 0;
          final ib = orderIndexMap[b.id] ?? 0;
          cmp = ia.compareTo(ib);
          break;
        case PlaylistSortBy.title:
          cmp = a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          );
          if (cmp == 0) {
            final ia = orderIndexMap[a.id] ?? 0;
            final ib = orderIndexMap[b.id] ?? 0;
            cmp = ia.compareTo(ib);
          }
          break;
        case PlaylistSortBy.duration:
          cmp = a.duration.compareTo(b.duration);
          if (cmp == 0) {
            final ia = orderIndexMap[a.id] ?? 0;
            final ib = orderIndexMap[b.id] ?? 0;
            cmp = ia.compareTo(ib);
          }
          break;
      }
      return ascending ? cmp : -cmp;
    });

    // 检查顺序是否已经与目标一致
    bool alreadyMatched = true;
    for (int i = 0; i < playlist.length; i++) {
      if (playlist[i].id != targetOrder[i].id) {
        alreadyMatched = false;
        break;
      }
    }
    if (alreadyMatched) return;

    final currentSong = playerProvider.currentSong;
    int curIdx = playerProvider.currentIndex;
    if (currentSong == null || curIdx < 0 || curIdx >= playlist.length) {
      for (int i = 0; i < targetOrder.length; i++) {
        final found = playlist.indexWhere((s) => s.id == targetOrder[i].id);
        if (found > i) {
          await playerProvider.reorderPlaylist(found, i);
        }
      }
      return;
    }

    final targetCurrentIdx = targetOrder.indexWhere(
      (s) => s.id == currentSong.id,
    );
    if (targetCurrentIdx < 0) return;

    // 若当前播放歌曲在排序前后恰好处在同一索引，先用一次相移腾出差位，
    // 再用单次 reorderPlaylist 精确落位并自动同步 PlayerProvider._currentIndex。
    if (curIdx == targetCurrentIdx) {
      final altIdx = curIdx == 0 ? 1 : curIdx - 1;
      await playerProvider.reorderPlaylist(
        curIdx,
        curIdx < altIdx ? altIdx + 1 : altIdx,
      );
      curIdx = playerProvider.currentIndex;
    }

    final withoutCurrent = targetOrder
        .where((s) => s.id != currentSong.id)
        .toList();
    final safeInsert = curIdx.clamp(0, withoutCurrent.length);
    withoutCurrent.insert(safeInsert, currentSong);

    playlist
      ..clear()
      ..addAll(withoutCurrent);

    await playerProvider.reorderPlaylist(
      safeInsert,
      safeInsert < targetCurrentIdx ? targetCurrentIdx + 1 : targetCurrentIdx,
    );
  }

  Future<void> _openYtSortMenu() async {
    final playerProvider = context.read<PlayerProvider>();
    if (playerProvider.playlist.isEmpty) return;
    _syncOriginalQueueSnapshot(playerProvider.playlist);

    final anchorCtx = _sortAnchorKey.currentContext;
    final box = anchorCtx?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final Offset anchorTopRight = (box != null && overlay != null)
        ? box.localToGlobal(Offset(box.size.width, box.size.height), ancestor: overlay)
        : Offset(MediaQuery.sizeOf(context).width - 56, 200);

    final screenSize = MediaQuery.sizeOf(context);
    const double menuWidth = 220.0;
    final double left = (anchorTopRight.dx - menuWidth).clamp(
      12.0,
      math.max(12.0, screenSize.width - menuWidth - 12.0),
    );
    final double top = (anchorTopRight.dy + 4.0).clamp(
      64.0,
      math.max(64.0, screenSize.height - 260.0),
    );

    AppHaptics.lightImpact(HapticCategory.control);

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭排序菜单',
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogCtx, anim, secondaryAnim) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final cs = Theme.of(ctx).colorScheme;
            const options = <(PlaylistSortBy, String)>[
              (PlaylistSortBy.queue, '播放顺序'),
              (PlaylistSortBy.title, '标题'),
              (PlaylistSortBy.duration, '时长'),
            ];

            void selectSortOption(PlaylistSortBy picked) {
              AppHaptics.lightImpact(HapticCategory.control);
              setState(() {
                if (_sortBy == picked) {
                  _sortAscending = !_sortAscending;
                } else {
                  _sortBy = picked;
                  _sortAscending = true;
                }
              });
              setModalState(() {});
              unawaited(
                _applyQueueSort(playerProvider, _sortBy, _sortAscending),
              );
            }

            void selectDirection(bool ascending) {
              if (_sortAscending == ascending) return;
              AppHaptics.lightImpact(HapticCategory.control);
              setState(() => _sortAscending = ascending);
              setModalState(() {});
              unawaited(
                _applyQueueSort(playerProvider, _sortBy, _sortAscending),
              );
            }

            return Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  width: menuWidth,
                  child: ScaleTransition(
                    scale: CurvedAnimation(
                      parent: anim,
                      curve: Curves.easeOutBack,
                    ),
                    alignment: Alignment.topRight,
                    child: Material(
                      color: cs.surfaceContainerHigh,
                      elevation: 8,
                      shadowColor: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                      clipBehavior: Clip.antiAlias,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final opt in options)
                              InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => selectSortOption(opt.$1),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 11,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _sortBy == opt.$1
                                        ? cs.secondaryContainer.withValues(
                                            alpha: 0.65,
                                          )
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          opt.$2,
                                          style: TextStyle(
                                            color: _sortBy == opt.$1
                                                ? cs.onSecondaryContainer
                                                : cs.onSurface,
                                            fontSize: 14,
                                            fontWeight: _sortBy == opt.$1
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                      if (_sortBy == opt.$1)
                                        Icon(
                                          Icons.check_rounded,
                                          size: 18,
                                          color: cs.primary,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 6,
                              ),
                              child: Divider(
                                height: 1,
                                color: cs.outlineVariant.withValues(alpha: 0.5),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: _buildDirectionSegment(
                                      cs: cs,
                                      selected: _sortAscending,
                                      icon: Icons.arrow_upward_rounded,
                                      label: '正序',
                                      isLeft: true,
                                      onTap: () => selectDirection(true),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: _buildDirectionSegment(
                                      cs: cs,
                                      selected: !_sortAscending,
                                      icon: Icons.arrow_downward_rounded,
                                      label: '倒序',
                                      isLeft: false,
                                      onTap: () => selectDirection(false),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDirectionSegment({
    required ColorScheme cs,
    required bool selected,
    required IconData icon,
    required String label,
    required bool isLeft,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? cs.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? cs.primary
                : cs.outlineVariant.withValues(alpha: 0.6),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: selected ? cs.onPrimary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? cs.onPrimary : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

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
      builder: (context, _) {
        final t = widget.expansion.value.clamp(0.0, 1.0);
        if (t <= 0.001) {
          return const SizedBox.shrink();
        }
        final miniKey =
            '${widget.song.id}_${widget.song.artworkUri}_${widget.isVideoMode}_${identityHashCode(widget.videoController)}';
        if (_cachedMiniBar == null || _cachedMiniKey != miniKey) {
          _cachedMiniKey = miniKey;
          _cachedMiniBar = RepaintBoundary(
            child: YtMiniBar(
              song: widget.song,
              onTap: widget.onClose,
              showCover: false,
              hideCoverSlot: widget.isVideoMode,
              videoController: widget.videoController,
              onVerticalDragUpdate: widget.onVerticalDragUpdate,
              onVerticalDragEnd: widget.onVerticalDragEnd,
            ),
          );
        }
        final sheetKey =
            '${widget.song.id}_${widget.song.album}_${safeBottom.toStringAsFixed(1)}';
        if (_cachedSheet == null || _cachedSheetKey != sheetKey) {
          _cachedSheetKey = sheetKey;
          _cachedSheet = RepaintBoundary(
            child: _buildSheetContent(context, safeBottom),
          );
        }

        return IgnorePointer(
          ignoring: t < 0.05,
          child: SafeArea(
            top: true,
            bottom: false,
            child: Column(
              children: [
                SizedBox(
                  height: 56,
                  child: FadeTransition(
                    opacity: _miniFadeAnim,
                    child: Transform.translate(
                      offset: Offset(0, -10.0 * (1.0 - t)),
                      child: _cachedMiniBar,
                    ),
                  ),
                ),
                Expanded(
                  child: FadeTransition(
                    opacity: _sheetFadeAnim,
                    child: Transform.translate(
                      offset: Offset(0, (1.0 - t) * drawerSlideDistance),
                      child: _cachedSheet,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSheetContent(BuildContext context, double safeBottom) {
    final currentSong = widget.song;
    final sourceTitle =
        currentSong.album.isNotEmpty && currentSong.album != '未知专辑'
        ? currentSong.album
        : currentSong.displayName;

    return ListenableBuilder(
      listenable: YtPaletteTheme.instance,
      builder: (context, _) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: Container(
            decoration: YtPaletteTheme.drawerDecoration(),
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
                          onTap: () {
                            if (widget.onOpenSave != null) {
                              widget.onOpenSave!();
                            } else {
                              showAddToPlaylistDialog(context, currentSong);
                            }
                          },
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
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PlayerPlaylistView(
                        key: widget.playlistKey,
                        scrollAnchor: widget.scrollAnchor,
                      ),
                      // 覆盖在 PlayerPlaylistView 常态顶栏「排序」按钮位之上：
                      // 编辑模式下自动放行触摸给「全选」按钮，常态下接管排序弹窗，
                      // 零侵入修复上游播放顺序还原与正倒序切换问题。
                      Positioned(
                        top: 10,
                        right: 56,
                        width: 48,
                        height: 50,
                        child: _YtSortButtonTouchGate(
                          key: _sortAnchorKey,
                          shouldIntercept: () {
                            final edit =
                                widget.playlistKey?.currentState?.editMode ??
                                false;
                            if (edit) return false;
                            final p = context.read<PlayerProvider>();
                            return p.playlist.isNotEmpty;
                          },
                          onTap: _openYtSortMenu,
                        ),
                      ),
                    ],
                  ),
                ),
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

/// 动态触摸门控：仅在非编辑模式下拦截 PlayerPlaylistView 右上角的排序图标点击
class _YtSortButtonTouchGate extends SingleChildRenderObjectWidget {
  final bool Function() shouldIntercept;
  final VoidCallback onTap;

  _YtSortButtonTouchGate({
    super.key,
    required this.shouldIntercept,
    required this.onTap,
  }) : super(
         child: GestureDetector(
           behavior: HitTestBehavior.opaque,
           onTap: onTap,
           child: const SizedBox.expand(),
         ),
       );

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderYtSortButtonTouchGate(shouldIntercept: shouldIntercept);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderYtSortButtonTouchGate renderObject,
  ) {
    renderObject.shouldIntercept = shouldIntercept;
  }
}

class _RenderYtSortButtonTouchGate extends RenderProxyBox {
  bool Function() shouldIntercept;

  _RenderYtSortButtonTouchGate({required this.shouldIntercept});

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!shouldIntercept()) return false;
    return super.hitTest(result, position: position);
  }
}

/// 1:1 复刻歌词与播放列表展开动画的全屏「评论区」抽屉（配合 FullPlayerYt 悬浮封面飞行缩放）
class YtCommentsDrawer extends StatefulWidget {
  final Animation<double> expansion;
  final Song song;
  final bool isVideoMode;
  final VideoPlayerController? videoController;
  final VoidCallback onClose;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const YtCommentsDrawer({
    super.key,
    required this.expansion,
    required this.song,
    this.isVideoMode = false,
    this.videoController,
    required this.onClose,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  State<YtCommentsDrawer> createState() => _YtCommentsDrawerState();
}

class _YtCommentsDrawerState extends State<YtCommentsDrawer> {
  final ScrollController _scrollController = ScrollController();
  double? _pointerStartY;
  bool _capturingPullDown = false;
  double _lastStepDy = 0.0;
  Widget? _cachedMiniBar;
  String? _cachedMiniKey;
  Widget? _cachedSheet;
  String? _cachedSheetKey;
  late Animation<double> _miniFadeAnim;
  late Animation<double> _sheetFadeAnim;

  @override
  void initState() {
    super.initState();
    _initFadeAnims();
  }

  @override
  void didUpdateWidget(covariant YtCommentsDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expansion != widget.expansion) {
      _initFadeAnims();
    }
  }

  void _initFadeAnims() {
    _miniFadeAnim = YtDrawerFadeAnimation(
      parent: widget.expansion,
      compute: () => (widget.expansion.value - 0.25) / 0.75,
    );
    _sheetFadeAnim = YtDrawerFadeAnimation(
      parent: widget.expansion,
      compute: () => widget.expansion.value * 1.4,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

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
      builder: (context, _) {
        final t = widget.expansion.value.clamp(0.0, 1.0);
        if (t <= 0.001) {
          return const SizedBox.shrink();
        }
        final miniKey =
            '${widget.song.id}_${widget.song.artworkUri}_${widget.isVideoMode}_${identityHashCode(widget.videoController)}';
        if (_cachedMiniBar == null || _cachedMiniKey != miniKey) {
          _cachedMiniKey = miniKey;
          _cachedMiniBar = RepaintBoundary(
            child: YtMiniBar(
              song: widget.song,
              onTap: widget.onClose,
              showCover: false,
              hideCoverSlot: widget.isVideoMode,
              videoController: widget.videoController,
              onVerticalDragUpdate: widget.onVerticalDragUpdate,
              onVerticalDragEnd: widget.onVerticalDragEnd,
            ),
          );
        }
        final sheetKey =
            '${widget.song.id}_${widget.song.albumAudioId}_${widget.song.artworkUri}_${safeBottom.toStringAsFixed(1)}';
        if (_cachedSheet == null || _cachedSheetKey != sheetKey) {
          _cachedSheetKey = sheetKey;
          _cachedSheet = RepaintBoundary(
            child: _buildSheetContent(context, safeBottom),
          );
        }

        return IgnorePointer(
          ignoring: t < 0.05,
          child: SafeArea(
            top: true,
            bottom: false,
            child: Column(
              children: [
                SizedBox(
                  height: 56,
                  child: FadeTransition(
                    opacity: _miniFadeAnim,
                    child: Transform.translate(
                      offset: Offset(0, -10.0 * (1.0 - t)),
                      child: _cachedMiniBar,
                    ),
                  ),
                ),
                Expanded(
                  child: FadeTransition(
                    opacity: _sheetFadeAnim,
                    child: Transform.translate(
                      offset: Offset(0, (1.0 - t) * drawerSlideDistance),
                      child: _cachedSheet,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSheetContent(BuildContext context, double safeBottom) {
    final currentSong = widget.song;

    return ListenableBuilder(
      listenable: YtPaletteTheme.instance,
      builder: (context, _) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: Container(
            decoration: YtPaletteTheme.drawerDecoration(),
            child: Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: widget.onVerticalDragUpdate,
              onVerticalDragEnd: widget.onVerticalDragEnd,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 16, 6),
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
                    const SizedBox(height: 4),
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
                                '歌曲评论',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                '${currentSong.displayName} · ${currentSong.artist}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
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
                  final atTop =
                      !_scrollController.hasClients ||
                      _scrollController.offset <= 1.0;
                  if (!_capturingPullDown && totalDy > 8.0 && atTop) {
                    _capturingPullDown = true;
                  }
                  if (_capturingPullDown) {
                    if (_scrollController.hasClients &&
                        _scrollController.offset > 0) {
                      _scrollController.jumpTo(0);
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
                  child: CommentsView(
                    songHash: currentSong.id,
                    albumAudioId: currentSong.albumAudioId,
                    artworkUri: currentSong.artworkUri,
                    isAmStyle: true,
                    scrollController: _scrollController,
                  ),
                ),
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
