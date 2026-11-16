import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../../core/utils/app_haptics.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/album.dart';
import '../../../data/models/song.dart';
import '../../../providers/kugou_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../services/kugou_api/kugou_api_client.dart';
import '../../../services/kugou_api/kugou_endpoints.dart';
import '../../../services/kugou_api/kugou_models.dart';
import '../../../widgets/player_artwork_image.dart';
import '../../album/album_detail_page.dart';
import '../../library/song_match_sheet.dart';
import '../song_info_page.dart';
import '../song_ranking_sheet.dart';
import 'yt_lyrics_drawer.dart';
import 'yt_more_menu.dart';

/// 1:1 复刻歌词与评论抽屉展开动画的全屏内嵌「相关内容 / 歌曲百科」双 Tab 抽屉
/// （点击播放页歌名打开：Tab 1 为原版 YT Music 风格「相关内容」，含你可能还喜欢、其他表演、
/// 同类音乐人大圆头像、歌手更多正方形大专辑；Tab 2 为网易云风格「歌曲百科」完整档案）
class YtSongInfoDrawer extends StatefulWidget {
  final Animation<double> expansion;
  final Song song;
  final bool isVideoMode;
  final VideoPlayerController? videoController;
  final VoidCallback onClose;
  final void Function([String? artistName])? onOpenArtist;
  final void Function(Route<dynamic>)? onPushPage;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const YtSongInfoDrawer({
    super.key,
    required this.expansion,
    required this.song,
    this.isVideoMode = false,
    this.videoController,
    required this.onClose,
    this.onOpenArtist,
    this.onPushPage,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  State<YtSongInfoDrawer> createState() => _YtSongInfoDrawerState();
}

class _YtSongInfoDrawerState extends State<YtSongInfoDrawer> {
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
  void didUpdateWidget(covariant YtSongInfoDrawer oldWidget) {
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
            '${widget.song.id}_${widget.song.albumId}_${widget.song.albumAudioId}_${widget.song.artworkUri}_${safeBottom.toStringAsFixed(1)}';
        if (_cachedSheet == null || _cachedSheetKey != sheetKey) {
          _cachedSheetKey = sheetKey;
          _cachedSheet = RepaintBoundary(
            child: _YtSongInfoDrawerContent(
              song: widget.song,
              safeBottom: safeBottom,
              onClose: widget.onClose,
              onOpenArtist: widget.onOpenArtist,
              onPushPage: widget.onPushPage,
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
}

enum _YtSongDrawerTab { related, wiki }

class _SimilarArtistCardData {
  final String id;
  final String name;
  final String? avatarUrl;
  final String subtitle;

  const _SimilarArtistCardData({
    required this.id,
    required this.name,
    this.avatarUrl,
    required this.subtitle,
  });
}

class _YtSongInfoData {
  final String? albumId;
  final String? albumName;
  final String? publishDate;
  final String? language;
  final String? albumType;
  final String? company;
  final int? heat;
  final bool exclusive;
  final String? albumIntro;
  final List<String> tags;
  final int? bpm;
  final double? climaxStartSec;
  final double? climaxEndSec;
  final List<String> qualityBadges;
  final List<({String role, String value})> credits;
  final KugouSongRanking? ranking;
  final List<Song> youMayLikeSongs;
  final List<Song> otherPerformances;
  final List<_SimilarArtistCardData> similarArtists;
  final String? primaryArtistName;
  final String? primaryArtistAvatar;
  final List<KugouAlbumBrief> artistAlbums;

  const _YtSongInfoData({
    this.albumId,
    this.albumName,
    this.publishDate,
    this.language,
    this.albumType,
    this.company,
    this.heat,
    this.exclusive = false,
    this.albumIntro,
    this.tags = const [],
    this.bpm,
    this.climaxStartSec,
    this.climaxEndSec,
    this.qualityBadges = const [],
    this.credits = const [],
    this.ranking,
    this.youMayLikeSongs = const [],
    this.otherPerformances = const [],
    this.similarArtists = const [],
    this.primaryArtistName,
    this.primaryArtistAvatar,
    this.artistAlbums = const [],
  });
}

class _YtSongInfoDrawerContent extends StatefulWidget {
  final Song song;
  final double safeBottom;
  final VoidCallback onClose;
  final void Function([String? artistName])? onOpenArtist;
  final void Function(Route<dynamic>)? onPushPage;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const _YtSongInfoDrawerContent({
    required this.song,
    required this.safeBottom,
    required this.onClose,
    this.onOpenArtist,
    this.onPushPage,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  State<_YtSongInfoDrawerContent> createState() =>
      _YtSongInfoDrawerContentState();
}

class _YtSongInfoDrawerContentState extends State<_YtSongInfoDrawerContent> {
  final ScrollController _scrollController = ScrollController();
  double? _pointerStartY;
  bool _capturingPullDown = false;
  double _lastStepDy = 0.0;

  _YtSongDrawerTab _tab = _YtSongDrawerTab.related;
  int _requestToken = 0;
  bool _loading = true;
  bool _introExpanded = false;
  _YtSongInfoData? _data;

  @override
  void initState() {
    super.initState();
    _loadSongInfo(notify: false);
  }

  @override
  void didUpdateWidget(covariant _YtSongInfoDrawerContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id ||
        oldWidget.song.albumId != widget.song.albumId ||
        oldWidget.song.albumAudioId != widget.song.albumAudioId) {
      _loadSongInfo();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  static String _stripSongVersionTitle(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'\s*[\(\[（【].*?[\)\]）】]'), '')
        .split(' - ')
        .first
        .trim();
    return cleaned.isNotEmpty ? cleaned : raw.trim();
  }

  static String? _detectPerformanceBadge(Song candidate, Song current) {
    final raw = '${candidate.title} ${candidate.album}'.toLowerCase();
    if (raw.contains('live') ||
        raw.contains('现场') ||
        raw.contains('演唱会') ||
        raw.contains('音乐节')) {
      return '现场';
    }
    if (raw.contains('cover') ||
        raw.contains('翻唱') ||
        raw.contains('女声版') ||
        raw.contains('男声版') ||
        raw.contains('粤语版') ||
        raw.contains('日文版') ||
        raw.contains('英文版')) {
      return '翻唱';
    }
    if (raw.contains('piano') ||
        raw.contains('钢琴') ||
        raw.contains('吉他') ||
        raw.contains('acoustic') ||
        raw.contains('不插电') ||
        raw.contains('纯音乐') ||
        raw.contains('伴奏') ||
        raw.contains('inst')) {
      return '演奏';
    }
    if (raw.contains('remix') ||
        raw.contains('dj') ||
        raw.contains('混音') ||
        raw.contains('慢摇') ||
        raw.contains('降调')) {
      return '混音';
    }
    if (candidate.artist.trim().toLowerCase() !=
        current.artist.trim().toLowerCase()) {
      return '翻唱';
    }
    return '版本';
  }

  Future<void> _loadSongInfo({
    bool forceRefreshLyrics = false,
    bool notify = true,
  }) async {
    final token = ++_requestToken;
    final song = widget.song;
    if (notify) {
      setState(() {
        _loading = true;
        _introExpanded = false;
      });
    } else {
      _loading = true;
      _introExpanded = false;
    }

    final api = KugouApiClient();
    final kugouProvider = context.read<KugouProvider>();

    String? albumId = song.albumId;
    String? albumName = !isUnknownAlbum(song.album) ? song.album : null;
    String? albumAudioId = song.albumAudioId;
    String? artistId = song.artistId;
    final qualityBadges = <String>[];

    // 1. 先加载制作名单与歌曲基础详情
    final lyricFuture = YtLyricsCache.load(
      song,
      kugouProvider,
      force: forceRefreshLyrics,
    ).catchError(
      (_) => const YtCachedLyricsEntry(parsedLines: [], rawLyricText: ''),
    );

    final detailFuture = song.isOnline && song.id.isNotEmpty
        ? api.getSongDetail(song.id).catchError((_) => null)
        : Future<KugouSongDetail?>.value(null);

    final baseResults = await Future.wait([lyricFuture, detailFuture]);
    if (!mounted || token != _requestToken) return;

    final lyricEntry = baseResults[0] as YtCachedLyricsEntry;
    final songDetail = baseResults[1] as KugouSongDetail?;
    final credits = YtLyricsCache.extractCredits(lyricEntry.rawLyricText);

    if (songDetail != null) {
      if ((albumId == null || albumId.isEmpty) &&
          songDetail.albumId != null &&
          songDetail.albumId!.isNotEmpty) {
        albumId = songDetail.albumId;
      }
      if ((albumName == null || albumName.isEmpty) &&
          songDetail.albumName != null &&
          songDetail.albumName!.isNotEmpty) {
        albumName = songDetail.albumName;
      }
      if ((albumAudioId == null || albumAudioId.isEmpty) &&
          songDetail.albumAudioId != null &&
          songDetail.albumAudioId!.isNotEmpty) {
        albumAudioId = songDetail.albumAudioId;
      }
      if ((artistId == null || artistId.isEmpty) &&
          songDetail.artistId != null &&
          songDetail.artistId!.isNotEmpty) {
        artistId = songDetail.artistId;
      }
      if (songDetail.sqHash != null && songDetail.sqHash!.isNotEmpty) {
        qualityBadges.add('SQ 无损');
      }
      if (songDetail.hqHash != null && songDetail.hqHash!.isNotEmpty) {
        qualityBadges.add('HQ 高品');
      }
    }
    if (song.quality != null &&
        song.quality!.isNotEmpty &&
        !qualityBadges.contains(song.quality)) {
      qualityBadges.add(song.quality!);
    }

    final splitArtists = splitSongArtistNames(song.artist);
    final primaryArtistName = splitArtists.isNotEmpty
        ? splitArtists.first
        : (!isUnknownArtist(song.artist) ? song.artist.trim() : null);

    // 2. 并行拉取：专辑百科、/krm/audio、高潮副歌、榜单成绩、AI 风格推荐 + 相似歌曲、其他表演版本、主歌手专辑
    final albumRawFuture = (albumId != null && albumId.isNotEmpty)
        ? _fetchAlbumRaw(api, albumId)
        : Future<Map<String, dynamic>?>.value(null);

    final krmRawFuture = (albumAudioId != null && albumAudioId.isNotEmpty)
        ? _fetchKrmAudioRaw(api, albumAudioId)
        : Future<Map<String, dynamic>?>.value(null);

    final climaxFuture = (song.climaxStart != null && song.climaxEnd != null)
        ? Future<KugouSongClimax?>.value(null)
        : (song.isOnline && song.id.isNotEmpty)
        ? api
              .getSongClimax(song.id, albumAudioId: albumAudioId)
              .catchError((_) => null)
        : Future<KugouSongClimax?>.value(null);

    final rankingFuture = (albumAudioId != null && albumAudioId.isNotEmpty)
        ? api.getSongRanking(albumAudioId).catchError((_) => null)
        : Future<KugouSongRanking?>.value(null);

    final aiRecommendFuture = (albumAudioId != null && albumAudioId.isNotEmpty)
        ? api
              .getAiRecommend(albumAudioId)
              .then(
                (list) => (list ?? const <KugouSongDetail>[])
                    .map((e) => e.toSong())
                    .toList(),
              )
              .catchError((_) => const <Song>[])
        : Future<List<Song>>.value(const <Song>[]);

    final relatedFuture = (albumAudioId != null && albumAudioId.isNotEmpty)
        ? _fetchRelatedSongs(api, albumAudioId, song.id)
        : (song.isOnline && song.id.isNotEmpty)
        ? api
              .getAudioRelated(song.id)
              .then(
                (list) => (list ?? const <KugouSongDetail>[])
                    .map((e) => e.toSong())
                    .toList(),
              )
              .catchError((_) => const <Song>[])
        : Future<List<Song>>.value(const <Song>[]);

    final otherPerfFuture = _fetchOtherPerformances(api, song);

    final artistBundleFuture = _fetchPrimaryArtistBundle(
      api,
      artistId: artistId,
      artistName: primaryArtistName,
    );

    final allResults = await Future.wait([
      albumRawFuture,
      krmRawFuture,
      climaxFuture,
      rankingFuture,
      aiRecommendFuture,
      relatedFuture,
      otherPerfFuture,
      artistBundleFuture,
    ]);
    if (!mounted || token != _requestToken) return;

    final albumMap = allResults[0] as Map<String, dynamic>?;
    final krmMap = allResults[1] as Map<String, dynamic>?;
    final climax = allResults[2] as KugouSongClimax?;
    final ranking = allResults[3] as KugouSongRanking?;
    final aiSongs = allResults[4] as List<Song>;
    final relatedSongs = allResults[5] as List<Song>;
    final otherPerformances = allResults[6] as List<Song>;
    final artistBundle =
        allResults[7]
            as ({String? avatarUrl, List<KugouAlbumBrief> albums});

    // 合并去重「你可能还喜欢」（优先 /ai/recommend 曲风推荐，其次 /audio/related）
    final seenHashes = <String>{song.id.toLowerCase()};
    final youMayLike = <Song>[];
    for (final s in [...aiSongs, ...relatedSongs]) {
      final key = s.id.trim().toLowerCase();
      if (key.isEmpty || seenHashes.contains(key)) continue;
      seenHashes.add(key);
      youMayLike.add(s);
      if (youMayLike.length >= 16) break;
    }

    // 解析专辑详情字段
    String? publishDate = _cleanDate(
      albumMap?['publish_date'] ??
          albumMap?['publishtime'] ??
          albumMap?['publishDate'],
    );
    String? language = _extractReadableString(albumMap?['language']);
    String? albumType = _extractAlbumType(albumMap?['type']);
    final int? heat = _parsePositiveInt(albumMap?['heat']);
    final bool exclusive =
        albumMap?['exclusive'] == 1 || albumMap?['exclusive'] == true;
    final String? albumIntro = _cleanText(
      albumMap?['intro'] ?? albumMap?['description'] ?? albumMap?['desc'],
    );
    final transParam = albumMap?['trans_param'] is Map<String, dynamic>
        ? albumMap!['trans_param'] as Map<String, dynamic>
        : null;
    String? company = _cleanText(
      albumMap?['company'] ??
          albumMap?['publish_company'] ??
          transParam?['company'] ??
          transParam?['publish_company'],
    );
    if ((albumName == null || albumName.isEmpty) && albumMap != null) {
      albumName = _cleanText(
        albumMap['album_name'] ??
            albumMap['albumname'] ??
            albumMap['AlbumName'],
      );
    }

    // 解析 /krm/audio 返回的曲风标签 / 语种 / BPM / 发行日兜底
    final tags = <String>[];
    int? bpm = song.bpm;
    if (krmMap != null) {
      final base = krmMap['base'] is Map<String, dynamic>
          ? krmMap['base'] as Map<String, dynamic>
          : null;
      final audioInfo = krmMap['audio_info'] is Map<String, dynamic>
          ? krmMap['audio_info'] as Map<String, dynamic>
          : null;
      final albumInfo = krmMap['album_info'] is Map<String, dynamic>
          ? krmMap['album_info'] as Map<String, dynamic>
          : null;

      publishDate ??= _cleanDate(
        base?['publish_date'] ??
            albumInfo?['publish_date'] ??
            krmMap['publish_date'],
      );
      language ??= _extractReadableString(
        base?['language'] ?? krmMap['language'],
      );
      bpm ??= _parsePositiveInt(audioInfo?['bpm'] ?? base?['bpm']);
      if ((albumId == null || albumId.isEmpty) && albumInfo != null) {
        final aid = albumInfo['album_id']?.toString() ?? '';
        if (aid.isNotEmpty && aid != '0') albumId = aid;
      }
      if ((albumName == null || albumName.isEmpty) && albumInfo != null) {
        albumName = _cleanText(albumInfo['album_name']);
      }
      company ??= _cleanText(
        albumInfo?['company'] ?? albumInfo?['publish_company'],
      );

      _collectTagNames(krmMap['tags'], tags);
      _collectTagNames(base?['tags'], tags);
      _collectTagNames(krmMap['tag'], tags);
      _collectTagNames(base?['genre'], tags);
      _collectTagNames(krmMap['genre'], tags);
      _collectTagNames(base?['style'], tags);
    }

    double? climaxStartSec = song.climaxStart;
    double? climaxEndSec = song.climaxEnd;
    if ((climaxStartSec == null || climaxEndSec == null) && climax != null) {
      final sMs = double.tryParse(climax.startTime ?? '');
      final eMs = double.tryParse(climax.endTime ?? '');
      if (sMs != null && eMs != null && eMs > sMs) {
        climaxStartSec = sMs / 1000.0;
        climaxEndSec = eMs / 1000.0;
      }
    }

    // 先渲染首屏数据（不等同类歌手头像二次查询）
    setState(() {
      _data = _YtSongInfoData(
        albumId: albumId,
        albumName: albumName,
        publishDate: publishDate,
        language: language,
        albumType: albumType,
        company: company,
        heat: heat,
        exclusive: exclusive,
        albumIntro: albumIntro,
        tags: tags,
        bpm: bpm,
        climaxStartSec: climaxStartSec,
        climaxEndSec: climaxEndSec,
        qualityBadges: qualityBadges,
        credits: credits,
        ranking: ranking,
        youMayLikeSongs: youMayLike,
        otherPerformances: otherPerformances,
        similarArtists: const [],
        primaryArtistName: primaryArtistName,
        primaryArtistAvatar: artistBundle.avatarUrl,
        artistAlbums: artistBundle.albums,
      );
      _loading = false;
    });

    // 3. 异步解析「同类音乐人」高清圆头像与作品数（基于曲风推荐里的关联音乐人）
    final similarArtists = await _resolveSimilarArtists(
      api,
      recommendPool: [...youMayLike, ...otherPerformances],
      excludeNames: splitArtists,
    );
    if (!mounted || token != _requestToken || similarArtists.isEmpty) return;
    setState(() {
      final prev = _data;
      if (prev != null) {
        _data = _YtSongInfoData(
          albumId: prev.albumId,
          albumName: prev.albumName,
          publishDate: prev.publishDate,
          language: prev.language,
          albumType: prev.albumType,
          company: prev.company,
          heat: prev.heat,
          exclusive: prev.exclusive,
          albumIntro: prev.albumIntro,
          tags: prev.tags,
          bpm: prev.bpm,
          climaxStartSec: prev.climaxStartSec,
          climaxEndSec: prev.climaxEndSec,
          qualityBadges: prev.qualityBadges,
          credits: prev.credits,
          ranking: prev.ranking,
          youMayLikeSongs: prev.youMayLikeSongs,
          otherPerformances: prev.otherPerformances,
          similarArtists: similarArtists,
          primaryArtistName: prev.primaryArtistName,
          primaryArtistAvatar: prev.primaryArtistAvatar,
          artistAlbums: prev.artistAlbums,
        );
      }
    });
  }

  Future<List<Song>> _fetchOtherPerformances(
    KugouApiClient api,
    Song currentSong,
  ) async {
    final baseTitle = _stripSongVersionTitle(currentSong.displayName);
    if (baseTitle.isEmpty) return const <Song>[];
    try {
      final res = await api.search(baseTitle, page: 1, pagesize: 24);
      final songs = res?.songs ?? const <KugouSongDetail>[];
      if (songs.isEmpty) return const <Song>[];
      final lowerBase = baseTitle.toLowerCase();
      final currentHash = currentSong.id.toLowerCase();
      final seen = <String>{currentHash};
      final out = <Song>[];
      for (final d in songs) {
        final s = d.toSong();
        final h = s.id.trim().toLowerCase();
        if (h.isEmpty || seen.contains(h)) continue;
        final candidateClean = _stripSongVersionTitle(
          s.displayName,
        ).toLowerCase();
        final titleMatches =
            candidateClean == lowerBase ||
            s.displayName.toLowerCase().contains(lowerBase);
        if (!titleMatches) continue;
        // 避免和当前歌曲完全同名同歌手且毫无版本差异的重复条目
        final sameArtist =
            s.artist.trim().toLowerCase() ==
            currentSong.artist.trim().toLowerCase();
        final sameRawTitle =
            s.displayName.trim().toLowerCase() ==
            currentSong.displayName.trim().toLowerCase();
        if (sameArtist && sameRawTitle && s.album == currentSong.album) {
          continue;
        }
        seen.add(h);
        out.add(s);
        if (out.length >= 8) break;
      }
      return out;
    } catch (_) {
      return const <Song>[];
    }
  }

  Future<({String? avatarUrl, List<KugouAlbumBrief> albums})>
  _fetchPrimaryArtistBundle(
    KugouApiClient api, {
    required String? artistId,
    required String? artistName,
  }) async {
    try {
      String? resolvedId = artistId;
      String? fallbackAvatar;
      if ((resolvedId == null || resolvedId.isEmpty) &&
          artistName != null &&
          artistName.isNotEmpty) {
        final hits = await api.searchArtists(artistName, pagesize: 5);
        if (hits != null && hits.isNotEmpty) {
          KugouArtistBrief picked = hits.first;
          final lower = artistName.toLowerCase();
          for (final h in hits) {
            if (h.name.trim().toLowerCase() == lower) {
              picked = h;
              break;
            }
          }
          resolvedId = picked.id;
          fallbackAvatar = picked.avatarUrl;
        }
      }
      if (resolvedId == null || resolvedId.isEmpty) {
        return (avatarUrl: fallbackAvatar, albums: const <KugouAlbumBrief>[]);
      }
      final res = await Future.wait([
        api.getArtistDetail(resolvedId).catchError((_) => null),
        api
            .getArtistAlbums(resolvedId, page: 1, pagesize: 14, sort: 'hot')
            .catchError((_) => null),
      ]);
      final detail = res[0] as KugouArtistDetail?;
      final albumsRes = res[1] as KugouArtistAlbums?;
      final avatar = YtMoreMenu.upgradeArtworkUri(
        (detail?.avatarUrl != null && detail!.avatarUrl!.isNotEmpty)
            ? detail.avatarUrl
            : fallbackAvatar,
      );
      return (
        avatarUrl: avatar,
        albums: albumsRes?.albums ?? const <KugouAlbumBrief>[],
      );
    } catch (_) {
      return (avatarUrl: null, albums: const <KugouAlbumBrief>[]);
    }
  }

  Future<List<_SimilarArtistCardData>> _resolveSimilarArtists(
    KugouApiClient api, {
    required List<Song> recommendPool,
    required List<String> excludeNames,
  }) async {
    final excluded = excludeNames.map((e) => e.trim().toLowerCase()).toSet();
    final candidateNames = <String>[];
    final fallbackCovers = <String, String?>{};
    for (final s in recommendPool) {
      for (final name in splitSongArtistNames(s.artist)) {
        final clean = name.trim();
        final lower = clean.toLowerCase();
        if (clean.isEmpty ||
            isUnknownArtist(clean) ||
            excluded.contains(lower)) {
          continue;
        }
        excluded.add(lower);
        candidateNames.add(clean);
        fallbackCovers[clean] = s.artworkUri;
        if (candidateNames.length >= 6) break;
      }
      if (candidateNames.length >= 6) break;
    }
    if (candidateNames.isEmpty) return const [];

    final futures = candidateNames.map((name) async {
      try {
        final hits = await api.searchArtists(name, pagesize: 3);
        if (hits != null && hits.isNotEmpty) {
          KugouArtistBrief picked = hits.first;
          final lower = name.toLowerCase();
          for (final h in hits) {
            if (h.name.trim().toLowerCase() == lower) {
              picked = h;
              break;
            }
          }
          KugouArtistDetail? detail;
          if (picked.id.isNotEmpty) {
            detail = await api
                .getArtistDetail(picked.id)
                .catchError((_) => null);
          }
          final avatar = YtMoreMenu.upgradeArtworkUri(
            (detail?.avatarUrl != null && detail!.avatarUrl!.isNotEmpty)
                ? detail.avatarUrl
                : (picked.avatarUrl ?? fallbackCovers[name]),
          );
          final statsParts = <String>[
            if ((detail?.songCount ?? 0) > 0) '${detail!.songCount} 首单曲',
            if ((detail?.albumCount ?? 0) > 0) '${detail!.albumCount} 张专辑',
          ];
          return _SimilarArtistCardData(
            id: picked.id,
            name: picked.name.isNotEmpty ? picked.name : name,
            avatarUrl: avatar,
            subtitle: statsParts.isNotEmpty
                ? statsParts.join(' · ')
                : '相似风格音乐人',
          );
        }
      } catch (_) {}
      return _SimilarArtistCardData(
        id: '',
        name: name,
        avatarUrl: YtMoreMenu.upgradeArtworkUri(fallbackCovers[name]),
        subtitle: '相似风格音乐人',
      );
    });

    final resolved = await Future.wait(futures);
    return resolved;
  }

  Future<Map<String, dynamic>?> _fetchAlbumRaw(
    KugouApiClient api,
    String albumId,
  ) async {
    try {
      final resp = await api.dio.get<dynamic>(
        KugouEndpoints.albumDetail,
        queryParameters: {'album_id': albumId},
      );
      final root = resp.data;
      if (root is! Map<String, dynamic>) return null;
      final rawData = root['data'];
      if (rawData is List && rawData.isNotEmpty && rawData.first is Map) {
        return Map<String, dynamic>.from(rawData.first as Map);
      }
      if (rawData is Map<String, dynamic>) {
        final info = rawData['info'];
        if (info is List && info.isNotEmpty && info.first is Map) {
          return Map<String, dynamic>.from(info.first as Map);
        }
        return rawData;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _fetchKrmAudioRaw(
    KugouApiClient api,
    String albumAudioId,
  ) async {
    try {
      final resp = await api.dio.get<dynamic>(
        KugouEndpoints.krmAudio,
        queryParameters: {
          'album_audio_id': albumAudioId,
          'fields': 'base,audio_info,album_info,tags,authors,trans_param',
        },
      );
      final root = resp.data;
      if (root is! Map<String, dynamic>) return null;
      final rawData = root['data'];
      if (rawData is List && rawData.isNotEmpty && rawData.first is Map) {
        return Map<String, dynamic>.from(rawData.first as Map);
      }
      if (rawData is Map<String, dynamic>) {
        final info = rawData['info'] ?? rawData['list'];
        if (info is List && info.isNotEmpty && info.first is Map) {
          return Map<String, dynamic>.from(info.first as Map);
        }
        return rawData;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<Song>> _fetchRelatedSongs(
    KugouApiClient api,
    String albumAudioId,
    String songHash,
  ) async {
    try {
      final resp = await api.dio.get<dynamic>(
        KugouEndpoints.audioRelated,
        queryParameters: {
          'album_audio_id': albumAudioId,
          'show_detail': 1,
          'pagesize': 15,
          'sort': 'hot',
        },
      );
      final root = resp.data;
      if (root is Map<String, dynamic>) {
        final rawData = root['data'];
        dynamic list;
        if (rawData is List) {
          list = rawData;
        } else if (rawData is Map<String, dynamic>) {
          list = rawData['list'] ?? rawData['songs'] ?? rawData['info'];
        }
        list ??= root['list'] ?? root['info'];
        if (list is List && list.isNotEmpty) {
          final parsed = list
              .whereType<Map>()
              .map(
                (e) => KugouSongDetail.fromJson(
                  Map<String, dynamic>.from(e),
                ).toSong(),
              )
              .where(
                (s) =>
                    s.id.isNotEmpty &&
                    s.id.toLowerCase() != songHash.toLowerCase(),
              )
              .toList();
          if (parsed.isNotEmpty) return parsed;
        }
      }
    } catch (_) {}

    if (songHash.isNotEmpty) {
      final fallback = await api.getAudioRelated(songHash);
      if (fallback != null && fallback.isNotEmpty) {
        return fallback
            .map((e) => e.toSong())
            .where(
              (s) =>
                  s.id.isNotEmpty &&
                  s.id.toLowerCase() != songHash.toLowerCase(),
            )
            .toList();
      }
    }
    return const <Song>[];
  }

  static void _collectTagNames(dynamic node, List<String> out) {
    if (node == null) return;
    if (node is String) {
      for (final part in node.split(RegExp(r'[,，/、;；]'))) {
        final clean = part.trim();
        if (clean.isNotEmpty &&
            clean.length <= 24 &&
            !out.contains(clean) &&
            out.length < 8) {
          out.add(clean);
        }
      }
      return;
    }
    if (node is List) {
      for (final item in node) {
        if (out.length >= 8) break;
        _collectTagNames(item, out);
      }
      return;
    }
    if (node is Map) {
      final candidate =
          node['tag_name'] ??
          node['tagname'] ??
          node['name'] ??
          node['title'];
      if (candidate != null) {
        _collectTagNames(candidate.toString(), out);
      }
      if (node['children'] != null) {
        _collectTagNames(node['children'], out);
      }
    }
  }

  static String? _cleanText(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty || s == 'null' || s == '0') return null;
    return s;
  }

  static String? _cleanDate(dynamic v) {
    final s = _cleanText(v);
    if (s == null) return null;
    if (s.startsWith('0000') || s.startsWith('1970-01-01')) return null;
    if (s.length >= 10 && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s)) {
      return s.substring(0, 10);
    }
    return s;
  }

  static String? _extractReadableString(dynamic v) {
    if (v == null) return null;
    if (v is List) {
      final parts = v
          .map((e) => e?.toString().trim() ?? '')
          .where((e) => e.isNotEmpty && e != 'null')
          .toList();
      return parts.isEmpty ? null : parts.join(' / ');
    }
    final s = v.toString().trim();
    if (s.isEmpty || s == 'null' || s == '0') return null;
    return s;
  }

  static String? _extractAlbumType(dynamic v) {
    final s = _cleanText(v);
    if (s == null) return null;
    if (RegExp(r'^\d+$').hasMatch(s)) return null;
    return s;
  }

  static int? _parsePositiveInt(dynamic v) {
    if (v == null) return null;
    final n = v is num ? v.toInt() : int.tryParse(v.toString());
    if (n == null || n <= 0) return null;
    return n;
  }

  String _formatSeconds(double sec) {
    final total = sec.round().clamp(0, 86400);
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _formatHeat(int heat) {
    if (heat >= 100000000) {
      return '${(heat / 100000000).toStringAsFixed(1)} 亿';
    }
    if (heat >= 10000) {
      return '${(heat / 10000).toStringAsFixed(1)} 万';
    }
    return '$heat';
  }

  void _openAlbumDetail(_YtSongInfoData info) {
    final albumId = info.albumId;
    if (albumId == null || albumId.isEmpty) {
      showToast('暂无关联专辑信息');
      return;
    }
    final push = widget.onPushPage ?? Navigator.of(context).push;
    push(
      MaterialPageRoute(
        builder: (_) => AlbumDetailPage(
          album: Album(
            id: albumId,
            name: info.albumName ?? widget.song.displayName,
            artist: widget.song.artist,
            artworkUri: widget.song.artworkUri,
            songCount: 0,
          ),
        ),
      ),
    );
  }

  void _openBriefAlbum(KugouAlbumBrief albumBrief) {
    final push = widget.onPushPage ?? Navigator.of(context).push;
    push(
      MaterialPageRoute(
        builder: (_) => AlbumDetailPage(album: albumBrief.toAlbum()),
      ),
    );
  }

  void _openTechnicalSongInfo() {
    final push = widget.onPushPage ?? Navigator.of(context).push;
    push(MaterialPageRoute(builder: (_) => const SongInfoPage()));
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.36),
              Colors.black.withValues(alpha: 0.72),
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
            _buildTopBar(),
            _buildDualTabSwitcher(),
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
                child: _buildBody(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: widget.onVerticalDragUpdate,
      onVerticalDragEnd: widget.onVerticalDragEnd,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
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
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _tab == _YtSongDrawerTab.related ? '相关内容' : '歌曲百科',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                if (_tab == _YtSongDrawerTab.wiki)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      minimumSize: const Size(0, 32),
                    ),
                    onPressed: _openTechnicalSongInfo,
                    icon: const Icon(Icons.graphic_eq_rounded, size: 15),
                    label: const Text('音频参数', style: TextStyle(fontSize: 12.5)),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white70,
                    size: 24,
                  ),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDualTabSwitcher() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Container(
        height: 38,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.10),
            width: 0.6,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: _buildTabItem(
                label: '相关内容',
                icon: Icons.explore_outlined,
                selected: _tab == _YtSongDrawerTab.related,
                onTap: () {
                  if (_tab != _YtSongDrawerTab.related) {
                    AppHaptics.lightImpact(HapticCategory.control);
                    setState(() => _tab = _YtSongDrawerTab.related);
                  }
                },
              ),
            ),
            Expanded(
              child: _buildTabItem(
                label: '歌曲百科',
                icon: Icons.menu_book_outlined,
                selected: _tab == _YtSongDrawerTab.wiki,
                onTap: () {
                  if (_tab != _YtSongDrawerTab.wiki) {
                    AppHaptics.lightImpact(HapticCategory.control);
                    setState(() => _tab = _YtSongDrawerTab.wiki);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabItem({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: selected
              ? Colors.white.withValues(alpha: 0.22)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(17),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: selected ? Colors.white : Colors.white60,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white60,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 2),
      );
    }

    final info = _data ?? const _YtSongInfoData();
    if (_tab == _YtSongDrawerTab.related) {
      return _buildRelatedTabBody(info);
    }
    return _buildWikiTabBody(info);
  }

  /// Tab 1：1:1 原版 YT Music「相关内容」视图（图 1 & 图 4）
  Widget _buildRelatedTabBody(_YtSongInfoData info) {
    final hasYouMayLike = info.youMayLikeSongs.isNotEmpty;
    final hasOtherPerf = info.otherPerformances.isNotEmpty;
    final hasSimilarArtists = info.similarArtists.isNotEmpty;
    final hasArtistAlbums = info.artistAlbums.isNotEmpty;

    if (!hasYouMayLike &&
        !hasOtherPerf &&
        !hasSimilarArtists &&
        !hasArtistAlbums) {
      return ListView(
        controller: _scrollController,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: EdgeInsets.fromLTRB(16, 48, 16, widget.safeBottom + 28),
        children: [
          const Icon(
            Icons.library_music_outlined,
            color: Colors.white38,
            size: 44,
          ),
          const SizedBox(height: 12),
          const Text(
            '暂未找到当前曲目的线上相关推荐',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 14),
          Center(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white30),
              ),
              onPressed: () => setState(() => _tab = _YtSongDrawerTab.wiki),
              icon: const Icon(Icons.menu_book_rounded, size: 16),
              label: const Text('查看歌曲百科'),
            ),
          ),
        ],
      );
    }

    return ListView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(0, 6, 0, widget.safeBottom + 32),
      children: [
        if (hasYouMayLike) ...[
          _buildYouMayLikeSection(info.youMayLikeSongs),
          const SizedBox(height: 26),
        ],
        if (hasOtherPerf) ...[
          _buildOtherPerformancesSection(info.otherPerformances),
          const SizedBox(height: 26),
        ],
        if (hasSimilarArtists) ...[
          _buildSimilarArtistsSection(info.similarArtists),
          const SizedBox(height: 28),
        ],
        if (hasArtistAlbums) ...[
          _buildMoreFromArtistAlbumsSection(info),
        ],
      ],
    );
  }

  /// 1. 「你可能还喜欢」—— 4 行一列横向分页滑动（复刻图 4 顶部效果）
  Widget _buildYouMayLikeSection(List<Song> songs) {
    final columns = <List<Song>>[];
    for (int i = 0; i < songs.length; i += 4) {
      columns.add(songs.sublist(i, math.min(i + 4, songs.length)));
    }
    final screenW = MediaQuery.sizeOf(context).width;
    final colWidth = columns.length > 1 ? screenW - 44.0 : screenW - 32.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '你可能还喜欢',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: math.min(4, songs.length) * 66.0,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: columns.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, colIndex) {
              final colSongs = columns[colIndex];
              return SizedBox(
                width: colWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int r = 0; r < colSongs.length; r++)
                      _buildYtSongRow(
                        song: colSongs[r],
                        playlist: songs,
                        indexInPlaylist: colIndex * 4 + r,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 2. 「其他表演」—— 同曲目不同版本 / 翻唱 / Live（复刻图 1 & 图 4 中部效果，带「翻唱 / 现场」小角标）
  Widget _buildOtherPerformancesSection(List<Song> songs) {
    final visible = songs.take(6).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '其他表演',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 10),
          for (int i = 0; i < visible.length; i++)
            _buildYtSongRow(
              song: visible[i],
              playlist: visible,
              indexInPlaylist: i,
              badge: _detectPerformanceBadge(visible[i], widget.song),
            ),
        ],
      ),
    );
  }

  Widget _buildYtSongRow({
    required Song song,
    required List<Song> playlist,
    required int indexInPlaylist,
    String? badge,
  }) {
    final cover = YtMoreMenu.upgradeArtworkUri(song.artworkUri);
    final subtitleParts = <String>[
      if (!isUnknownArtist(song.artist)) song.artist,
      if (!isUnknownAlbum(song.album) && song.album != song.displayName)
        song.album,
    ];

    return InkWell(
      onTap: () {
        AppHaptics.click(HapticCategory.transport);
        context.read<PlayerProvider>().playOnlinePlaylist(
          playlist,
          indexInPlaylist,
        );
      },
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        height: 66,
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 50,
                height: 50,
                color: Colors.white.withValues(alpha: 0.08),
                child: (cover != null && cover.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: cover,
                        memCacheWidth: 160,
                        memCacheHeight: 160,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => const Icon(
                          Icons.music_note_rounded,
                          color: Colors.white38,
                          size: 22,
                        ),
                      )
                    : const Icon(
                        Icons.music_note_rounded,
                        color: Colors.white38,
                        size: 22,
                      ),
              ),
            ),
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
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (badge != null && badge.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1.2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.20),
                            borderRadius: BorderRadius.circular(3.5),
                          ),
                          child: Text(
                            badge,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              height: 1.1,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          subtitleParts.join(' • '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12.5,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '插入下一首播放',
              icon: const Icon(
                Icons.playlist_play_rounded,
                color: Colors.white70,
                size: 24,
              ),
              onPressed: () {
                AppHaptics.lightImpact(HapticCategory.control);
                context.read<PlayerProvider>().insertAfterCurrent([song]);
                showToast('已加入下一首播放');
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 3. 「同类音乐人」—— 大号圆形头像横向画廊（1:1 复刻图 1 中部效果）
  Widget _buildSimilarArtistsSection(List<_SimilarArtistCardData> artists) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '同类音乐人',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: artists.length,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (context, index) {
              final item = artists[index];
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  AppHaptics.lightImpact(HapticCategory.control);
                  widget.onOpenArtist?.call(item.name);
                },
                child: SizedBox(
                  width: 144,
                  child: Column(
                    children: [
                      ClipOval(
                        child: Container(
                          width: 138,
                          height: 138,
                          color: Colors.white.withValues(alpha: 0.08),
                          child: (item.avatarUrl != null &&
                                  item.avatarUrl!.isNotEmpty)
                              ? CachedNetworkImage(
                                  imageUrl: item.avatarUrl!,
                                  memCacheWidth: 380,
                                  memCacheHeight: 380,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, _, _) => const Center(
                                    child: Icon(
                                      Icons.person_rounded,
                                      color: Colors.white38,
                                      size: 46,
                                    ),
                                  ),
                                )
                              : const Center(
                                  child: Icon(
                                    Icons.person_rounded,
                                    color: Colors.white38,
                                    size: 46,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12.2,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 4. 「更多曲目 - <歌手名>」—— 顶部歌手小圆头像 + 底部大号 1:1 正方形专辑卡片（1:1 复刻图 1 底部效果）
  Widget _buildMoreFromArtistAlbumsSection(_YtSongInfoData info) {
    final artistName = info.primaryArtistName ?? widget.song.artist;
    final avatar = info.primaryArtistAvatar;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              AppHaptics.lightImpact(HapticCategory.control);
              widget.onOpenArtist?.call(artistName);
            },
            child: Row(
              children: [
                ClipOval(
                  child: Container(
                    width: 40,
                    height: 40,
                    color: Colors.white.withValues(alpha: 0.10),
                    child: (avatar != null && avatar.isNotEmpty)
                        ? CachedNetworkImage(
                            imageUrl: avatar,
                            memCacheWidth: 140,
                            memCacheHeight: 140,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => const Icon(
                              Icons.person_rounded,
                              color: Colors.white54,
                              size: 22,
                            ),
                          )
                        : const Icon(
                            Icons.person_rounded,
                            color: Colors.white54,
                            size: 22,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '更多曲目 -',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        artistName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white54,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 216,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: info.artistAlbums.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, index) {
              final albumBrief = info.artistAlbums[index];
              final cover = YtMoreMenu.upgradeArtworkUri(albumBrief.coverUrl);
              final subtitleParts = <String>[
                '专辑',
                if (albumBrief.year != null && albumBrief.year! > 0)
                  '${albumBrief.year}年',
              ];
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  AppHaptics.lightImpact(HapticCategory.control);
                  _openBriefAlbum(albumBrief);
                },
                child: SizedBox(
                  width: 158,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          width: 158,
                          height: 158,
                          color: Colors.white.withValues(alpha: 0.08),
                          child: (cover != null && cover.isNotEmpty)
                              ? CachedNetworkImage(
                                  imageUrl: cover,
                                  memCacheWidth: 420,
                                  memCacheHeight: 420,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, _, _) => const Center(
                                    child: Icon(
                                      Icons.album_rounded,
                                      color: Colors.white38,
                                      size: 38,
                                    ),
                                  ),
                                )
                              : const Center(
                                  child: Icon(
                                    Icons.album_rounded,
                                    color: Colors.white38,
                                    size: 38,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        albumBrief.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitleParts.join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12.5,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Tab 2：网易云风格「歌曲百科」完整档案视图
  Widget _buildWikiTabBody(_YtSongInfoData info) {
    final hasAnyArchive =
        info.publishDate != null ||
        info.language != null ||
        info.albumType != null ||
        info.company != null ||
        info.heat != null ||
        info.bpm != null ||
        widget.song.loudnessLufs != null ||
        info.tags.isNotEmpty ||
        (info.climaxStartSec != null && info.climaxEndSec != null);

    return ListView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(16, 4, 16, widget.safeBottom + 28),
      children: [
        _buildSongHeaderCard(info),
        if (!widget.song.isOnline &&
            (info.albumId == null || info.albumId!.isEmpty)) ...[
          const SizedBox(height: 10),
          _buildLocalMatchBanner(),
        ],
        if (hasAnyArchive) ...[
          const SizedBox(height: 12),
          _buildArchiveCard(info),
        ],
        if (info.credits.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildCreditsCard(info.credits),
        ],
        if (info.ranking != null &&
            ((info.ranking!.title?.isNotEmpty ?? false) ||
                (info.ranking!.title2?.isNotEmpty ?? false) ||
                info.ranking!.info.isNotEmpty)) ...[
          const SizedBox(height: 12),
          _buildRankingCard(info.ranking!),
        ],
        if (info.albumIntro != null && info.albumIntro!.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildAlbumIntroCard(info.albumIntro!),
        ],
      ],
    );
  }

  Widget _buildSongHeaderCard(_YtSongInfoData info) {
    final song = widget.song;
    final hasArtist = !isUnknownArtist(song.artist);
    final albumText =
        info.albumName ?? (isUnknownAlbum(song.album) ? null : song.album);

    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: PlayerArtworkImage(
                    artworkUri: song.artworkUri,
                    fallbackFilePath: song.localPath,
                    isFill: true,
                    fit: BoxFit.cover,
                    iconSize: 28,
                    backgroundColor: Colors.white12,
                    iconColor: Colors.white54,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (song.duration > Duration.zero)
                          _smallBadge(song.displayDuration),
                        if (info.exclusive)
                          _smallBadge('独家', highlight: true),
                        for (final b in info.qualityBadges) _smallBadge(b),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (hasArtist || (albumText != null && albumText.isNotEmpty)) ...[
            const SizedBox(height: 12),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
            if (hasArtist)
              _navRow(
                icon: Icons.person_outline_rounded,
                label: '歌手',
                value: song.artist,
                onTap: widget.onOpenArtist != null
                    ? () => widget.onOpenArtist!()
                    : null,
              ),
            if (albumText != null && albumText.isNotEmpty)
              _navRow(
                icon: Icons.album_outlined,
                label: '专辑',
                value: albumText,
                onTap: (info.albumId != null && info.albumId!.isNotEmpty)
                    ? () => _openAlbumDetail(info)
                    : null,
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildLocalMatchBanner() {
    return _glassCard(
      child: Row(
        children: [
          const Icon(
            Icons.auto_awesome_outlined,
            color: Colors.white70,
            size: 20,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              '本地曲目暂未关联线上百科，可搜索匹配线上专辑、发行日期与榜单记录',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () async {
              await showSongMatchSheet(context, widget.song);
              if (mounted) _loadSongInfo(forceRefreshLyrics: true);
            },
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: Colors.white.withValues(alpha: 0.14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            child: const Text('匹配信息', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildArchiveCard(_YtSongInfoData info) {
    final rows = <(String, String)>[];
    if (info.publishDate != null) {
      final year = info.publishDate!.length >= 4
          ? info.publishDate!.substring(0, 4)
          : '';
      final text = (year.isNotEmpty && info.publishDate != year)
          ? '${info.publishDate} ($year年)'
          : info.publishDate!;
      rows.add(('发行时间', text));
    }
    if (info.language != null) rows.add(('语种', info.language!));
    if (info.albumType != null) rows.add(('发行形式', info.albumType!));
    if (info.company != null) rows.add(('发行方', info.company!));
    if (info.heat != null) rows.add(('热度指数', _formatHeat(info.heat!)));
    if (info.bpm != null) rows.add(('节奏速度', '${info.bpm} BPM'));
    if (widget.song.loudnessLufs != null) {
      rows.add((
        '响度指标',
        '${widget.song.loudnessLufs!.toStringAsFixed(1)} LUFS',
      ));
    }

    final hasClimax =
        info.climaxStartSec != null &&
        info.climaxEndSec != null &&
        info.climaxEndSec! > info.climaxStartSec!;

    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.library_books_outlined, '音乐档案'),
          if (info.tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in info.tags)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.14),
                        width: 0.6,
                      ),
                    ),
                    child: Text(
                      '# $tag',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (int i = 0; i < rows.length; i++)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 78,
                      child: Text(
                        rows[i].$1,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        rows[i].$2,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (hasClimax) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.local_fire_department_rounded,
                    color: Color(0xFFFFB74D),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '歌曲高潮  ${_formatSeconds(info.climaxStartSec!)} - ${_formatSeconds(info.climaxEndSec!)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      AppHaptics.click(HapticCategory.transport);
                      final start = Duration(
                        milliseconds: (info.climaxStartSec! * 1000).round(),
                      );
                      context.read<PlayerProvider>().seek(
                        start,
                        forceNotify: true,
                      );
                      showToast(
                        '已跳转至高潮段落 ${_formatSeconds(info.climaxStartSec!)}',
                      );
                    },
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Text(
                        '跳到高潮',
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCreditsCard(List<({String role, String value})> credits) {
    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.groups_outlined, '制作人员'),
          const SizedBox(height: 10),
          for (int i = 0; i < credits.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 78,
                    child: Text(
                      credits[i].role,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      credits[i].value,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
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

  Widget _buildRankingCard(KugouSongRanking ranking) {
    final summaryText = (ranking.title2?.isNotEmpty ?? false)
        ? ranking.title2!
        : (ranking.title ?? '');

    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _sectionTitle(Icons.emoji_events_outlined, '榜单成绩'),
              ),
              InkWell(
                onTap: () => showSongRankingSheet(context, widget.song),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Text(
                        '完整成绩单',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white54,
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (summaryText.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              summaryText,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12.8,
                height: 1.4,
              ),
            ),
          ],
          if (ranking.info.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final item in ranking.info.take(5))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    if (item.logoPic != null && item.logoPic!.isNotEmpty)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: CachedNetworkImage(
                          imageUrl: item.logoPic!,
                          width: 22,
                          height: 22,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => const Icon(
                            Icons.leaderboard_rounded,
                            color: Colors.white54,
                            size: 18,
                          ),
                        ),
                      )
                    else
                      const Icon(
                        Icons.leaderboard_rounded,
                        color: Colors.white54,
                        size: 18,
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        item.platformName ?? '榜单',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if ((item.rankingNum ?? 0) > 0)
                      _smallBadge('第 ${item.rankingNum} 名', highlight: true)
                    else if ((item.rankingTimes ?? 0) > 0)
                      _smallBadge('上榜 ${item.rankingTimes} 次'),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildAlbumIntroCard(String intro) {
    return _glassCard(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _introExpanded = !_introExpanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _sectionTitle(Icons.notes_rounded, '专辑简介'),
                ),
                Icon(
                  _introExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: Colors.white54,
                  size: 18,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              intro,
              maxLines: _introExpanded ? null : 4,
              overflow: _introExpanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _glassCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.09),
          width: 0.7,
        ),
      ),
      child: child,
    );
  }

  Widget _sectionTitle(IconData icon, String title) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white70, size: 17),
        const SizedBox(width: 7),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _smallBadge(String text, {bool highlight = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        color: highlight
            ? const Color(0xFFFFD54F).withValues(alpha: 0.20)
            : Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: highlight
            ? Border.all(
                color: const Color(0xFFFFD54F).withValues(alpha: 0.45),
                width: 0.6,
              )
            : null,
      ),
      child: Text(
        text,
        style: TextStyle(
          color: highlight ? const Color(0xFFFFE082) : Colors.white70,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _navRow({
    required IconData icon,
    required String label,
    required String value,
    VoidCallback? onTap,
  }) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Icon(icon, color: Colors.white54, size: 17),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            const Icon(
              Icons.chevron_right_rounded,
              color: Colors.white54,
              size: 18,
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: row,
    );
  }
}
