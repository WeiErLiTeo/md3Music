import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../../core/layout/display_space.dart';
import '../../../core/services/wakelock_service.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/mv_models.dart';
import '../../../data/models/song.dart';
import '../../../providers/favorites_provider.dart';
import '../../../providers/local_favorites_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../services/kugou_api/kugou_api_client.dart';
import '../../../services/kugou_api/kugou_models.dart';
import '../../../widgets/add_to_playlist_dialog.dart';
import '../../../widgets/depth_cover_host.dart';
import '../../../widgets/dynamic_cover_view.dart';
import '../../../widgets/marquee_text.dart';
import '../../../widgets/player_artwork_image.dart'
    show isPlayerArtworkReady, preloadPlayerArtwork;
import '../../../widgets/player_playlist_view.dart';
import '../../../widgets/player_seek_bar.dart';
import '../../settings/equalizer_settings_page.dart';
import '../../sheet/song_sheet_sheet.dart';
import '../comments_view.dart';
import '../cover_switch_physics.dart';
import '../mv_player_page.dart';
import '../player_cover_morph_layer.dart';
import '../player_cover_shadow.dart';
import '../player_video_active.dart';
import '../widgets/cover_flip_crossfade.dart';
import '../widgets/cover_switch_pager.dart';
import '../widgets/play_pause_morph_icon.dart';
import '../widgets/song_danmaku_host.dart';
import '../widgets/title_switch_fade.dart';
import 'yt_more_menu.dart';

class YtMainView extends StatefulWidget {
  static final PlaylistScrollAnchor _playlistScrollAnchor =
      PlaylistScrollAnchor();

  /// 缓存每首歌是否存在可用 MV（key = albumAudioId）
  static final Map<String, MvInfo?> _mvInfoCache = <String, MvInfo?>{};

  /// 缓存已加入「默认收藏」歌单的歌曲 hash（小写）与记录 fileId
  static final Set<String> _defaultCollectionHashes = <String>{};
  static final Map<String, int> _defaultCollectionFileIds = <String, int>{};
  static Map<String, dynamic>? _cachedDefaultCollectionPlaylist;
  static bool _defaultCollectionSynced = false;
  static bool _syncingDefaultCollection = false;

  final Song song;
  final bool dockMode;
  final Animation<double> lyricsExpansion;
  final AnimationController? queueController;
  final VoidCallback onCollapse;
  final VoidCallback onOpenLyrics;
  final ValueChanged<Rect>? onCoverRectMeasured;
  final void Function(Route<dynamic>)? onPushPage;
  final void Function(Route<dynamic>)? onDismissAndPush;
  final GestureDragStartCallback? onDragStart;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;
  final GestureDragCancelCallback? onDragCancel;

  const YtMainView({
    super.key,
    required this.song,
    this.dockMode = false,
    required this.lyricsExpansion,
    this.queueController,
    required this.onCollapse,
    required this.onOpenLyrics,
    this.onCoverRectMeasured,
    this.onPushPage,
    this.onDismissAndPush,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
  });

  @override
  State<YtMainView> createState() => _YtMainViewState();
}

class _YtMainViewState extends State<YtMainView>
    with SingleTickerProviderStateMixin {
  final GlobalKey<CoverSwitchPagerState> _coverPagerKey =
      GlobalKey<CoverSwitchPagerState>();
  PlayerProvider? _playerProvider;
  String? _lastSongId;
  int? _lastPagerIndex;
  int _coverFlipDirection = 1;

  /// 拖动进度条前是否正在播放（修复点击/拖动时间轴导致歌曲暂停的 Bug）
  bool _wasPlayingBeforeDrag = false;

  /// 内部兜底队列动画控制器（当父级未传入 queueController 时使用）
  AnimationController? _internalQueueController;
  AnimationController get _queueCtrl =>
      widget.queueController ?? _internalQueueController!;

  // ============== 顶栏「音频 / 视频」原地 MV 切换状态 ==============
  String? _probedAlbumAudioId;
  MvInfo? _currentMvInfo;
  bool _isVideoMode = false;
  bool _videoLoading = false;
  String? _videoError;
  VideoPlayerController? _videoController;
  List<MvQuality> _mvQualities = const [];
  int _mvQualityIndex = 0;
  String? _currentVideoUrl;
  bool _enteredVideoActive = false;

  // ============== 「默认收藏」歌单状态 ==============
  bool _defaultStarred = false;
  bool _togglingDefaultStar = false;

  @override
  void initState() {
    super.initState();
    if (widget.queueController == null) {
      _internalQueueController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 340),
        reverseDuration: const Duration(milliseconds: 280),
      );
    }
    _syncSongCapabilities(widget.song);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final player = context.read<PlayerProvider>();
    if (_playerProvider != player) {
      _playerProvider?.removeListener(_onPlayerChanged);
      _playerProvider = player;
      _lastSongId = player.currentSong?.id;
      _lastPagerIndex = player.currentIndex;
      _playerProvider?.addListener(_onPlayerChanged);
    }
  }

  @override
  void didUpdateWidget(covariant YtMainView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.song.id != oldWidget.song.id ||
        widget.song.albumAudioId != oldWidget.song.albumAudioId) {
      _syncSongCapabilities(widget.song);
    }
  }

  @override
  void dispose() {
    _disposeVideoController(resumeAudio: false);
    _internalQueueController?.dispose();
    _playerProvider?.removeListener(_onPlayerChanged);
    super.dispose();
  }

  bool _isSongInDefaultCollection(Song rawSong, Song resolvedSong) {
    final rawHash = rawSong.id.toLowerCase();
    final resolvedHash = resolvedSong.id.toLowerCase();
    return YtMainView._defaultCollectionHashes.contains(rawHash) ||
        YtMainView._defaultCollectionHashes.contains(resolvedHash);
  }

  void _syncSongCapabilities(Song rawSong) {
    final resolved = YtMoreMenu.resolveMatchedSong(rawSong);
    _defaultStarred = _isSongInDefaultCollection(rawSong, resolved);
    unawaited(_ensureDefaultCollectionSynced());

    final albumAudioId = resolved.albumAudioId;
    if (albumAudioId == _probedAlbumAudioId) return;
    _probedAlbumAudioId = albumAudioId;

    if (_isVideoMode) {
      _exitVideoMode(resumeAudio: false);
    }

    if (albumAudioId == null || albumAudioId.isEmpty) {
      if (mounted) {
        setState(() => _currentMvInfo = null);
      }
      return;
    }

    if (YtMainView._mvInfoCache.containsKey(albumAudioId)) {
      if (mounted) {
        setState(() => _currentMvInfo = YtMainView._mvInfoCache[albumAudioId]);
      }
      return;
    }

    _currentMvInfo = null;
    KugouApiClient()
        .getMvByAlbumAudioId(albumAudioId)
        .then((info) {
          YtMainView._mvInfoCache[albumAudioId] = (info != null && info.hasMv)
              ? info
              : null;
          if (!mounted || _probedAlbumAudioId != albumAudioId) return;
          setState(() {
            _currentMvInfo = YtMainView._mvInfoCache[albumAudioId];
          });
        })
        .catchError((_) {});
  }

  bool get _hasMv => _currentMvInfo != null && _currentMvInfo!.hasMv;

  Future<void> _enterVideoMode(Song resolvedSong) async {
    if (!_hasMv) {
      showToast('当前歌曲暂无 MV 视频');
      return;
    }
    if (_isVideoMode) return;
    AppHaptics.lightImpact(HapticCategory.control);

    final player = context.read<PlayerProvider>();
    if (player.isPlaying) {
      player.pause();
    }
    if (!_enteredVideoActive) {
      enterVideoPlayback();
      _enteredVideoActive = true;
    }

    setState(() {
      _isVideoMode = true;
      _videoLoading = true;
      _videoError = null;
    });

    final mvInfo = _currentMvInfo!;
    final api = KugouApiClient();
    String? mvId = mvInfo.mvId;
    String? targetHash = mvInfo.hash;

    try {
      if (mvId != null && mvId.isNotEmpty) {
        final detail = await api.getVideoDetail(mvId);
        if (!mounted || !_isVideoMode) return;
        if (detail != null && detail.qualities.isNotEmpty) {
          _mvQualities = detail.qualities;
          _mvQualityIndex = _mvQualities.length - 1;
          targetHash = _mvQualities[_mvQualityIndex].hash;
        }
      }
      if (targetHash == null || targetHash.isEmpty) {
        if (mounted && _isVideoMode) {
          setState(() {
            _videoLoading = false;
            _videoError = '无法获取 MV 视频信息';
          });
        }
        return;
      }
      final url = await api.getVideoUrl(targetHash);
      if (!mounted || !_isVideoMode) return;
      if (url == null || url.isEmpty) {
        setState(() {
          _videoLoading = false;
          _videoError = '无法获取 MV 播放地址';
        });
        return;
      }
      await _startInlineVideo(url);
    } catch (_) {
      if (mounted && _isVideoMode) {
        setState(() {
          _videoLoading = false;
          _videoError = 'MV 加载失败';
        });
      }
    }
  }

  Future<void> _startInlineVideo(String url, {Duration? startAt}) async {
    final old = _videoController;
    _videoController = null;
    old?.removeListener(_onInlineVideoTick);
    unawaited(old?.dispose());

    _currentVideoUrl = url;
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
    _videoController = ctrl;
    try {
      await ctrl.initialize();
      if (!mounted || !_isVideoMode || _videoController != ctrl) {
        await ctrl.dispose();
        return;
      }
      if (startAt != null && startAt > Duration.zero) {
        await ctrl.seekTo(startAt);
      }
      ctrl.addListener(_onInlineVideoTick);
      await ctrl.play();
      WakelockService.instance.setVideoPlaying(true);
      if (mounted) {
        setState(() {
          _videoLoading = false;
          _videoError = null;
        });
      }
    } catch (_) {
      if (mounted && _videoController == ctrl) {
        setState(() {
          _videoLoading = false;
          _videoError = '视频解码初始化失败';
        });
      }
    }
  }

  Future<void> _switchMvQuality(int index) async {
    if (index < 0 ||
        index >= _mvQualities.length ||
        index == _mvQualityIndex ||
        _videoLoading) {
      return;
    }
    final pos = _videoController?.value.position ?? Duration.zero;
    setState(() {
      _mvQualityIndex = index;
      _videoLoading = true;
    });
    final hash = _mvQualities[index].hash;
    final url = await KugouApiClient().getVideoUrl(hash);
    if (!mounted || !_isVideoMode) return;
    if (url != null && url.isNotEmpty) {
      await _startInlineVideo(url, startAt: pos);
    } else {
      setState(() => _videoLoading = false);
      showToast('切换清晰度失败');
    }
  }

  void _onInlineVideoTick() {
    if (!mounted || !_isVideoMode) return;
    final ctrl = _videoController;
    if (ctrl != null) {
      WakelockService.instance.setVideoPlaying(ctrl.value.isPlaying);
    }
    setState(() {});
  }

  void _exitVideoMode({bool resumeAudio = true}) {
    if (!_isVideoMode && _videoController == null) return;
    AppHaptics.lightImpact(HapticCategory.control);
    _disposeVideoController(resumeAudio: resumeAudio);
    if (mounted) {
      setState(() {
        _isVideoMode = false;
        _videoLoading = false;
        _videoError = null;
      });
    }
  }

  void _disposeVideoController({required bool resumeAudio}) {
    final ctrl = _videoController;
    _videoController = null;
    ctrl?.removeListener(_onInlineVideoTick);
    if (ctrl != null) {
      unawaited(ctrl.dispose());
    }
    WakelockService.instance.setVideoPlaying(false);
    if (_enteredVideoActive) {
      exitVideoPlayback();
      _enteredVideoActive = false;
    }
    if (resumeAudio) {
      try {
        _playerProvider?.resume();
      } catch (_) {}
    }
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    final player = _playerProvider;
    if (player == null) return;
    final song = player.currentSong;
    final slideDirection = coverSlideDirectionForIndexChange(
      fromIndex: _lastPagerIndex ?? player.currentIndex,
      toIndex: player.currentIndex,
      playlistLength: player.playlist.length,
    );
    _lastPagerIndex = player.currentIndex;
    if (song != null && song.id != _lastSongId) {
      _lastSongId = song.id;
      if (_isVideoMode) {
        _exitVideoMode(resumeAudio: false);
      }
      _syncSongCapabilities(song);
      if (slideDirection != 0) {
        _coverFlipDirection = slideDirection;
      }
      final pager = _coverPagerKey.currentState;
      if (pager != null && pager.hasPendingCommit) {
        pager.rebase(slideDirection);
      } else if (slideDirection != 0) {
        pager?.playChange(slideDirection);
      } else {
        pager?.resetToIdle();
      }
      final playlist = player.playlist;
      final idx = player.currentIndex;
      if (idx > 0) preloadPlayerArtwork(playlist[idx - 1].artworkUri);
      if (idx < playlist.length - 1) {
        preloadPlayerArtwork(playlist[idx + 1].artworkUri);
      }
    } else if (_isVideoMode && player.isPlaying) {
      // 当处于 MV 视频模式时，若用户在播放列表中点击了当前同一首歌触发了音频播放，
      // 立即退出 MV 模式停止视频，避免音频与 MV 双声道同时发声
      _exitVideoMode(resumeAudio: false);
    }
  }

  Song? _pagerNeighborSong(PlayerProvider player, int delta) {
    final list = player.playlist;
    if (list.length < 2) return null;
    final index = player.currentIndex + delta;
    if (index < 0) {
      return player.loopMode == AppLoopMode.all ? list[list.length - 1] : null;
    }
    if (index >= list.length) {
      return player.loopMode == AppLoopMode.all ? list[0] : null;
    }
    return list[index];
  }

  void _onCoverPagerCommit(CoverSwitchIntent intent) {
    AppHaptics.click(HapticCategory.transport);
    final player = context.read<PlayerProvider>();
    switch (intent) {
      case CoverSwitchIntent.previous:
        player.previous();
      case CoverSwitchIntent.next:
        player.next();
    }
  }

  // ============== 「默认收藏」歌单云端同步与一键收藏/取消逻辑 ==============
  Future<Map<String, dynamic>?> _findDefaultCollectionPlaylist(
    KugouApiClient api,
  ) async {
    if (YtMainView._cachedDefaultCollectionPlaylist != null) {
      return YtMainView._cachedDefaultCollectionPlaylist;
    }
    final resp = await api.getUserPlaylist(pagesize: 50);
    if (resp == null) return null;
    final data = resp['data'];
    List<dynamic> rawPlaylists = [];
    if (data is List) {
      rawPlaylists = data;
    } else if (data is Map) {
      rawPlaylists = data['info'] ?? data['list'] ?? data['special_list'] ?? [];
    }
    for (final item in rawPlaylists) {
      if (item is! Map<String, dynamic>) continue;
      final brief = KugouPlaylistBrief.fromJson(item);
      if (brief.name == '默认收藏' || item['is_def'] == 1) {
        final resolved = <String, dynamic>{
          'name': brief.name.isEmpty ? '默认收藏' : brief.name,
          'listid': brief.listId.isEmpty ? brief.id : brief.listId,
          'global_collection_id': brief.globalCollectionId,
          ...item,
        };
        YtMainView._cachedDefaultCollectionPlaylist = resolved;
        return resolved;
      }
    }
    return null;
  }

  Future<void> _ensureDefaultCollectionSynced() async {
    if (YtMainView._defaultCollectionSynced ||
        YtMainView._syncingDefaultCollection) {
      return;
    }
    final api = KugouApiClient();
    if (!api.isLoggedIn) return;
    YtMainView._syncingDefaultCollection = true;
    try {
      final defaultPlaylist = await _findDefaultCollectionPlaylist(api);
      if (defaultPlaylist == null) return;
      final listid = defaultPlaylist['listid']?.toString() ?? '';
      if (listid.isNotEmpty) {
        const int pageSize = 200;
        for (int page = 1; page <= 25; page++) {
          final r = await api.getPlaylistSongsByListid(
            listid: listid,
            page: page,
            pagesize: pageSize,
          );
          if (r == null) break;
          for (final s in r.songs) {
            final h = s.hash.toLowerCase();
            if (h.isNotEmpty) {
              YtMainView._defaultCollectionHashes.add(h);
              if (s.fileId != null && s.fileId! > 0) {
                YtMainView._defaultCollectionFileIds[h] = s.fileId!;
              }
            }
          }
          if (r.songs.length < pageSize) break;
        }
      } else {
        final gid = defaultPlaylist['global_collection_id']?.toString() ?? '';
        if (gid.isNotEmpty) {
          final r = await api.getPlaylistSongs(gid, pagesize: 500);
          if (r != null) {
            for (final s in r.songs) {
              final h = s.hash.toLowerCase();
              if (h.isNotEmpty) {
                YtMainView._defaultCollectionHashes.add(h);
                if (s.fileId != null && s.fileId! > 0) {
                  YtMainView._defaultCollectionFileIds[h] = s.fileId!;
                }
              }
            }
          }
        }
      }
      YtMainView._defaultCollectionSynced = true;
      if (mounted) {
        final resolved = YtMoreMenu.resolveMatchedSong(widget.song);
        final starred = _isSongInDefaultCollection(widget.song, resolved);
        if (starred != _defaultStarred) {
          setState(() => _defaultStarred = starred);
        }
      }
    } catch (_) {
    } finally {
      YtMainView._syncingDefaultCollection = false;
    }
  }

  Future<String> _resolveDefaultCollectionFileId(
    KugouApiClient api,
    String listid,
    Song resolvedSong,
  ) async {
    final hash = resolvedSong.id.toLowerCase();
    final rawHash = widget.song.id.toLowerCase();
    final cached =
        YtMainView._defaultCollectionFileIds[hash] ??
        YtMainView._defaultCollectionFileIds[rawHash];
    if (cached != null && cached > 0) return cached.toString();

    const int pageSize = 200;
    final first = await api.getPlaylistSongsByListid(
      listid: listid,
      page: 1,
      pagesize: pageSize,
      noCache: true,
    );
    if (first != null) {
      for (final s in first.songs) {
        final h = s.hash.toLowerCase();
        if ((h == hash || h == rawHash) && s.fileId != null && s.fileId! > 0) {
          return s.fileId.toString();
        }
      }
      final lastPage = (first.total + pageSize - 1) ~/ pageSize;
      if (lastPage > 1) {
        final last = await api.getPlaylistSongsByListid(
          listid: listid,
          page: lastPage,
          pagesize: pageSize,
          noCache: true,
        );
        if (last != null) {
          for (final s in last.songs) {
            final h = s.hash.toLowerCase();
            if ((h == hash || h == rawHash) &&
                s.fileId != null &&
                s.fileId! > 0) {
              return s.fileId.toString();
            }
          }
        }
      }
    }
    if (resolvedSong.fileId != null && resolvedSong.fileId! > 0) {
      return resolvedSong.fileId.toString();
    }
    return resolvedSong.id;
  }

  Future<void> _toggleDefaultCollection(Song resolvedSong) async {
    if (_togglingDefaultStar) return;
    AppHaptics.lightImpact(HapticCategory.control);
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      showToast('请先登录酷狗账号以使用默认收藏歌单');
      return;
    }
    setState(() => _togglingDefaultStar = true);
    try {
      final defaultPlaylist = await _findDefaultCollectionPlaylist(api);
      if (!mounted) return;
      if (defaultPlaylist == null) {
        showToast('未找到「默认收藏」歌单，请从右侧「保存」选择歌单');
        return;
      }
      final hash = resolvedSong.id.toLowerCase();
      final rawHash = widget.song.id.toLowerCase();
      final listid = defaultPlaylist['listid']?.toString() ?? '';

      if (_defaultStarred) {
        if (listid.isNotEmpty) {
          final fileId = await _resolveDefaultCollectionFileId(
            api,
            listid,
            resolvedSong,
          );
          await api.deletePlaylistTracks(listid, fileId);
        }
        if (!mounted) return;
        setState(() {
          _defaultStarred = false;
          YtMainView._defaultCollectionHashes.remove(hash);
          YtMainView._defaultCollectionHashes.remove(rawHash);
          YtMainView._defaultCollectionFileIds.remove(hash);
          YtMainView._defaultCollectionFileIds.remove(rawHash);
        });
        showToast('已从「默认收藏」移除');
      } else {
        setState(() {
          _defaultStarred = true;
          YtMainView._defaultCollectionHashes.add(hash);
          YtMainView._defaultCollectionHashes.add(rawHash);
        });
        await addSongToPlaylist(resolvedSong, defaultPlaylist);
      }
    } finally {
      if (mounted) {
        setState(() => _togglingDefaultStar = false);
      }
    }
  }

  // ============== 「接下来播放」队列抽屉三态（0.0 收起 ↔ 0.5 半屏 ↔ 1.0 全屏）控制 ==============
  static const double _kQueueHalfSnap = 0.5;
  double? _listPointerStartY;
  double _listDragStartQueueVal = 0.0;
  bool _listCapturingQueueDrag = false;
  double _listLastDy = 0.0;

  void _snapQueueTo(double target) {
    final clamped = target.clamp(0.0, 1.0);
    if ((_queueCtrl.value - clamped).abs() > 0.02) {
      AppHaptics.lightImpact(HapticCategory.control);
    }
    _queueCtrl.animateTo(
      clamped,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _openQueue() => _snapQueueTo(_kQueueHalfSnap);

  void _closeQueue() => _snapQueueTo(0.0);

  void _onQueueDragUpdate(DragUpdateDetails details) {
    final screenH = MediaQuery.sizeOf(context).height;
    final range = (screenH * 0.68).clamp(240.0, 820.0);
    final dy = toDisplaySpaceDelta(context, details.delta).dy;
    _queueCtrl.stop();
    _queueCtrl.value = (_queueCtrl.value - dy / range).clamp(0.0, 1.0);
  }

  void _onQueueDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0.0;
    _settleQueueWithVelocity(v);
  }

  void _settleQueueWithVelocity(double v) {
    final q = _queueCtrl.value;
    if (v < -360.0) {
      // 向上快速滑动：从收起态推到半屏(0.5)，从半屏以上推到全屏(1.0)
      if (q < 0.52 && v > -1350.0) {
        _snapQueueTo(_kQueueHalfSnap);
      } else {
        _snapQueueTo(1.0);
      }
    } else if (v > 360.0) {
      // 向下快速滑动：从全屏态退回半屏(0.5)或直接收起(0.0)
      if (q > 0.62 && v < 1200.0) {
        _snapQueueTo(_kQueueHalfSnap);
      } else {
        _snapQueueTo(0.0);
      }
    } else {
      // 慢速松手：按最近的三档吸附点（0.0 / 0.5 / 1.0）停靠
      if (q < 0.25) {
        _snapQueueTo(0.0);
      } else if (q < 0.76) {
        _snapQueueTo(_kQueueHalfSnap);
      } else {
        _snapQueueTo(1.0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final isOnline = song.isOnline;
    final isFavorited = isOnline
        ? context.select<FavoritesProvider, bool>((p) => p.isFavorite(song.id))
        : context.select<LocalFavoritesProvider, bool>(
            (p) => p.isFavorite(song.id),
          );

    final resolvedSong = YtMoreMenu.resolveMatchedSong(song);
    final safeTop = MediaQuery.paddingOf(context).top;
    final safeBottom = MediaQuery.paddingOf(context).bottom;

    return LayoutBuilder(
      builder: (context, outerConstraints) {
        final screenW = outerConstraints.maxWidth;
        final screenH = outerConstraints.maxHeight;

        // 1. 正常态（q == 0）几何计算：1:1 对齐原版 YT Music（图 1）的均衡舒展分布
        const double topBarH = 52.0;
        const double coverSideMargin = 24.0;
        const double handleCollapsedH = 54.0;
        // 下半区固定高度：封面->标题(26) + 标题块+间距(68) + 胶囊+间距(56) + 进度条+间距(54) + 五键(64) = 268
        const double fixedBelowCoverH = 268.0;
        final double availForCoverAndVSpace = math.max(
          200.0,
          screenH -
              safeTop -
              safeBottom -
              topBarH -
              handleCollapsedH -
              fixedBelowCoverH,
        );
        final double normalCoverSide = math.min(
          math.max(0.0, screenW - coverSideMargin * 2),
          math.max(160.0, availForCoverAndVSpace - 52.0),
        );
        final double extraVertical = math.max(
          24.0,
          availForCoverAndVSpace - normalCoverSide,
        );
        // 顶栏与封面之间留出原版 YT 的呼吸留白（约 24~32px），不再紧贴顶栏
        final double coverTopGap = (extraVertical * 0.45).clamp(20.0, 34.0);
        final double normalCoverLeft = (screenW - normalCoverSide) / 2.0;
        final double normalCoverTop = safeTop + topBarH + coverTopGap;

        if (normalCoverSide > 0) {
          widget.onCoverRectMeasured?.call(
            Rect.fromLTWH(
              normalCoverLeft,
              normalCoverTop,
              normalCoverSide,
              normalCoverSide,
            ),
          );
        }

        // 正常态下各控件的纵向起点（拉开封面与标题、胶囊与进度条、进度条与播放键的呼吸感）
        final double normalTitleTop = normalCoverTop + normalCoverSide + 26.0;
        final double normalCapsuleTop = normalTitleTop + 68.0;
        final double normalSeekTop = normalCapsuleTop + 56.0;
        final double normalTransportTop = normalSeekTop + 54.0;

        // 2. 半屏态（q == 0.5，对应录屏）与全屏态（q == 1.0，对应图 5）几何锚点
        final double halfCoverH = (screenH * 0.41).clamp(240.0, 410.0);
        final double halfTitleTop = halfCoverH - 68.0;
        const double fullMiniBarH = 68.0;
        final double queueTopCollapsed =
            screenH - safeBottom - handleCollapsedH;
        final double queueTopHalf = halfCoverH;
        final double queueTopFull = safeTop + fullMiniBarH;

        // 3. 预构建重型子树并放入 RepaintBoundary，手势拖拽过程中 0 次列表与控件 Rebuild！
        final Widget cachedCapsuleRow = RepaintBoundary(
          child: _buildCapsuleRow(context, resolvedSong, isFavorited, isOnline),
        );
        final Widget cachedSeekBar = RepaintBoundary(
          child: _buildSeekBar(context, resolvedSong),
        );
        final Widget cachedTransport = RepaintBoundary(
          child: _buildTransportControls(context),
        );
        final Widget cachedPlaylistArea = RepaintBoundary(
          child: _buildInteractivePlaylistArea(safeBottom),
        );

        return AnimatedBuilder(
          animation: _queueCtrl,
          builder: (context, _) {
            final q = _queueCtrl.value.clamp(0.0, 1.0);
            // t1: 收起态(0.0) -> 半屏态(0.5) 的归一化进度 (0.0 ~ 1.0)
            final t1 = (q / _kQueueHalfSnap).clamp(0.0, 1.0);
            // t2: 半屏态(0.5) -> 全屏态(1.0) 的归一化进度 (0.0 ~ 1.0)
            final t2 = ((q - _kQueueHalfSnap) / (1.0 - _kQueueHalfSnap)).clamp(
              0.0,
              1.0,
            );

            // 封面区域插值：0 -> 0.5 放大铺满上半屏宽度；0.5 -> 1.0 向上收拢并淡出为顶部 Mini Bar
            final halfL = ui.lerpDouble(normalCoverLeft, 0.0, t1)!;
            final halfT = ui.lerpDouble(normalCoverTop, 0.0, t1)!;
            final halfW = ui.lerpDouble(normalCoverSide, screenW, t1)!;
            final halfH = ui.lerpDouble(normalCoverSide, halfCoverH, t1)!;
            final curCoverLeft = halfL;
            final curCoverTop = ui.lerpDouble(halfT, -40.0, t2)!;
            final curCoverW = halfW;
            final curCoverH = ui.lerpDouble(halfH, queueTopFull, t2)!;
            final curCoverRadius = ui.lerpDouble(12.0, 0.0, t1)!;
            final coverLayerOpacity = (1.0 - t2 * 1.25).clamp(0.0, 1.0);

            // 歌名与歌手名位置插值：0 -> 0.5 移至放大封面左下角；0.5 -> 1.0 渐隐交接给顶部 Mini Bar
            final curTitleTop =
                ui.lerpDouble(normalTitleTop, halfTitleTop, t1)! - 36.0 * t2;
            final titleLayerOpacity = (1.0 - t2 * 1.6).clamp(0.0, 1.0);

            // 胶囊栏在 t1: 0 -> 0.55 率先淡出
            final capsuleOpacity = (1.0 - t1 * 1.85).clamp(0.0, 1.0);
            final curCapsuleTop = normalCapsuleTop - 28.0 * t1;

            // 进度条与五键控制栏跟随歌单向上推并在半屏前淡出
            final transportOpacity = (1.0 - ((t1 - 0.15) / 0.75)).clamp(
              0.0,
              1.0,
            );
            final transportSlideUp = 46.0 * t1;
            final curSeekTop = normalSeekTop - transportSlideUp;
            final curTransportTop = normalTransportTop - transportSlideUp;

            // 队列面板顶部 Y 坐标：三段插值（收起 -> 半屏 -> 全屏）
            final curQueueTop = q <= _kQueueHalfSnap
                ? ui.lerpDouble(queueTopCollapsed, queueTopHalf, t1)!
                : ui.lerpDouble(queueTopHalf, queueTopFull, t2)!;
            final curQueueHeight = (screenH - curQueueTop).clamp(
              handleCollapsedH,
              screenH - queueTopFull,
            );

            // 原顶栏在进入全屏态（t2: 0 -> 0.7）时淡出，全屏 Mini Bar（图 5）在 t2: 0.25 -> 1.0 显现
            final topBarOpacity = (1.0 - t2 * 1.5).clamp(0.0, 1.0);
            final miniHeaderOpacity = ((t2 - 0.20) / 0.80).clamp(0.0, 1.0);

            return Stack(
              fit: StackFit.expand,
              children: [
                // 1. 封面 / MV 视频层（固定内部 CoverSwitchPager 逻辑尺寸为 normalCoverSide，避免逐帧重排卡顿）
                if (coverLayerOpacity > 0.01)
                  Positioned(
                    left: curCoverLeft,
                    top: curCoverTop,
                    width: curCoverW,
                    height: curCoverH,
                    child: Opacity(
                      opacity: coverLayerOpacity,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _isVideoMode
                              ? _buildInlineMvPlayer(
                                  context,
                                  resolvedSong,
                                  curCoverRadius,
                                )
                              : ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    curCoverRadius,
                                  ),
                                  child: FittedBox(
                                    fit: BoxFit.cover,
                                    clipBehavior: Clip.hardEdge,
                                    child: SizedBox(
                                      width: normalCoverSide,
                                      height: normalCoverSide,
                                      child: _buildCover(
                                        context,
                                        resolvedSong,
                                        normalCoverSide,
                                        borderRadius: curCoverRadius,
                                        queueExpanded: q > 0.02,
                                      ),
                                    ),
                                  ),
                                ),
                          if (t1 > 0.01)
                            IgnorePointer(
                              child: Opacity(
                                opacity: t1,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      stops: const [0.0, 0.28, 0.62, 1.0],
                                      colors: [
                                        Colors.black.withValues(alpha: 0.45),
                                        Colors.transparent,
                                        Colors.black.withValues(alpha: 0.25),
                                        const Color(0xFF0D0D0D),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (q > 0.25 && !_isVideoMode)
                            Positioned.fill(
                              child: GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onTap: _closeQueue,
                                onVerticalDragUpdate: _onQueueDragUpdate,
                                onVerticalDragEnd: _onQueueDragEnd,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),

                // 2. 正常态/半屏态顶部栏
                if (topBarOpacity > 0.01)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: safeTop,
                    height: topBarH,
                    child: IgnorePointer(
                      ignoring: topBarOpacity < 0.3,
                      child: Opacity(
                        opacity: topBarOpacity,
                        child: _buildTopBar(context, resolvedSong),
                      ),
                    ),
                  ),

                // 3. 全屏队列态顶部 Mini Player 栏（1:1 还原图 5：小封面 + 歌名/歌手 + 上一首/播放/下一首）
                if (miniHeaderOpacity > 0.01)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: safeTop + fullMiniBarH,
                    child: IgnorePointer(
                      ignoring: miniHeaderOpacity < 0.4,
                      child: Opacity(
                        opacity: miniHeaderOpacity,
                        child: _buildFullQueueMiniHeader(
                          context,
                          resolvedSong,
                          safeTop,
                          fullMiniBarH,
                        ),
                      ),
                    ),
                  ),

                // 4. 歌名与歌手名（正常态与半屏态）
                if (titleLayerOpacity > 0.01)
                  Positioned(
                    left: 24,
                    right: 24,
                    top: curTitleTop,
                    child: IgnorePointer(
                      ignoring: t2 > 0.3,
                      child: Opacity(
                        opacity: titleLayerOpacity,
                        child: _buildTitleAndArtist(context, resolvedSong),
                      ),
                    ),
                  ),

                // 5. 胶囊操作栏
                if (capsuleOpacity > 0.01)
                  Positioned(
                    left: 20,
                    right: 20,
                    top: curCapsuleTop,
                    child: IgnorePointer(
                      ignoring: q > 0.15,
                      child: Opacity(
                        opacity: capsuleOpacity,
                        child: cachedCapsuleRow,
                      ),
                    ),
                  ),

                // 6. 播放进度条
                if (transportOpacity > 0.01)
                  Positioned(
                    left: 18,
                    right: 18,
                    top: curSeekTop,
                    child: IgnorePointer(
                      ignoring: q > 0.25,
                      child: Opacity(
                        opacity: transportOpacity,
                        child: cachedSeekBar,
                      ),
                    ),
                  ),

                // 7. 五键播放控制栏
                if (transportOpacity > 0.01)
                  Positioned(
                    left: 20,
                    right: 20,
                    top: curTransportTop,
                    child: IgnorePointer(
                      ignoring: q > 0.25,
                      child: Opacity(
                        opacity: transportOpacity,
                        child: cachedTransport,
                      ),
                    ),
                  ),

                // 8. 底部「接下来播放」三态联动歌单抽屉（0.0 收起 ↔ 0.5 半屏 ↔ 1.0 全屏）
                Positioned(
                  left: 0,
                  right: 0,
                  top: curQueueTop,
                  height: curQueueHeight,
                  child: _buildQueueDrawer(
                    context,
                    resolvedSong,
                    q,
                    cachedPlaylistArea,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 顶栏：折叠按钮、原版 YT「🎧 音频 / ▶️ 视频」胶囊切换器与更多选项
  Widget _buildTopBar(BuildContext context, Song resolvedSong) {
    final hasMv = _hasMv;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: widget.onDragStart,
      onVerticalDragUpdate: widget.onDragUpdate,
      onVerticalDragEnd: widget.onDragEnd,
      onVerticalDragCancel: widget.onDragCancel,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: const Icon(
                    Icons.keyboard_arrow_down,
                    color: Colors.white,
                    size: 30,
                  ),
                  onPressed: () {
                    if (_queueCtrl.value > 0.1) {
                      _closeQueue();
                    } else {
                      widget.onCollapse();
                    }
                  },
                ),
              ),
              // 原版 YT Music 音频/视频切换胶囊（左：耳机，右：视频播放框，无 MV 时变灰）
              Container(
                height: 32,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        if (_isVideoMode) {
                          _exitVideoMode(resumeAudio: true);
                        }
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: !_isVideoMode
                              ? Colors.white.withValues(alpha: 0.22)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Center(
                          child: Icon(
                            Icons.headphones_outlined,
                            size: 16,
                            color: !_isVideoMode
                                ? Colors.white
                                : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: hasMv ? () => _enterVideoMode(resolvedSong) : null,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: _isVideoMode
                              ? Colors.white.withValues(alpha: 0.22)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Center(
                          child: Icon(
                            Icons.smart_display_outlined,
                            size: 17,
                            color: !hasMv
                                ? Colors.white24
                                : (_isVideoMode
                                      ? Colors.white
                                      : Colors.white70),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  icon: const Icon(
                    Icons.more_vert,
                    color: Colors.white,
                    size: 24,
                  ),
                  onPressed: () => YtMoreMenu.show(
                    context,
                    resolvedSong,
                    onPushPage: widget.onPushPage,
                    onDismissAndPush: widget.onDismissAndPush,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 原地内嵌 MV 视频播放器（复刻图 3 微信视频样式：同源动态柔光高斯模糊消除上下死黑边，且控件零遮挡主视频）
  Widget _buildInlineMvPlayer(
    BuildContext context,
    Song resolvedSong,
    double borderRadius,
  ) {
    final ctrl = _videoController;
    final initialized = ctrl != null && ctrl.value.isInitialized;
    final aspect = initialized && ctrl.value.aspectRatio > 0
        ? ctrl.value.aspectRatio
        : 16 / 9;
    final vSize = initialized ? ctrl.value.size : Size.zero;
    final vW = vSize.width > 0 ? vSize.width : 160.0;
    final vH = vSize.height > 0 ? vSize.height : 90.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Container(
        color: const Color(0xFF101012),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. 底层：微信同款同源动态高斯模糊环境光填充（彻底消除 1:1 容器上下死黑边）
            Positioned.fill(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: 28,
                  sigmaY: 28,
                  tileMode: TileMode.mirror,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DepthCoverHost(
                      artworkUri: resolvedSong.artworkUri,
                      fallbackFilePath: resolvedSong.localPath,
                      fit: BoxFit.cover,
                      iconSize: 48,
                      backgroundColor: Colors.white12,
                      iconColor: Colors.white54,
                    ),
                    if (initialized)
                      FittedBox(
                        fit: BoxFit.cover,
                        clipBehavior: Clip.hardEdge,
                        child: SizedBox(
                          width: vW,
                          height: vH,
                          child: VideoPlayer(ctrl),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // 柔和暗角渐变遮罩，让上下模糊带与主视频画面自然晕染衔接
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.22, 0.78, 1.0],
                    colors: [
                      Colors.black.withValues(alpha: 0.36),
                      Colors.black.withValues(alpha: 0.14),
                      Colors.black.withValues(alpha: 0.14),
                      Colors.black.withValues(alpha: 0.42),
                    ],
                  ),
                ),
              ),
            ),
            // 2. 中层：16:9 完整主视频画面（0 裁剪、0 遮挡）
            if (initialized)
              Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.32),
                        blurRadius: 16,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: AspectRatio(
                    aspectRatio: aspect,
                    child: VideoPlayer(ctrl),
                  ),
                ),
              ),
            if (_videoLoading)
              const Center(
                child: CircularProgressIndicator(
                  color: Colors.white70,
                  strokeWidth: 2.5,
                ),
              ),
            if (_videoError != null && !_videoLoading)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: Colors.white54,
                      size: 36,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _videoError!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: () {
                        _isVideoMode = false;
                        _enterVideoMode(resolvedSong);
                      },
                      child: const Text(
                        '重试',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            // 3. 顶层控件：置于右下角模糊氛围带内（位于 16:9 视频底边之下，100% 不遮挡视频内容）
            if (initialized)
              Positioned(
                right: 12,
                bottom: 10,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_mvQualities.length > 1)
                      PopupMenuButton<int>(
                        tooltip: '切换清晰度',
                        color: const Color(0xFF222222),
                        onSelected: _switchMvQuality,
                        itemBuilder: (_) => [
                          for (int i = 0; i < _mvQualities.length; i++)
                            PopupMenuItem<int>(
                              value: i,
                              child: Text(
                                _mvQualities[i].quality,
                                style: TextStyle(
                                  color: i == _mvQualityIndex
                                      ? Colors.white
                                      : Colors.white70,
                                  fontWeight: i == _mvQualityIndex
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                        ],
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.48),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.14),
                              width: 0.5,
                            ),
                          ),
                          child: Text(
                            _mvQualities[_mvQualityIndex].quality,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        final url = _currentVideoUrl;
                        _exitVideoMode(resumeAudio: false);
                        final push =
                            widget.onPushPage ?? Navigator.of(context).push;
                        push(
                          MaterialPageRoute(
                            builder: (_) => MvPlayerPage(
                              song: resolvedSong,
                              directVideoUrl: url,
                            ),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.48),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.14),
                            width: 0.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.fullscreen_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPagerPage(Song? neighborSong) {
    if (neighborSong == null) return const SizedBox.shrink();
    final resolved = YtMoreMenu.resolveMatchedSong(neighborSong);
    return DepthCoverHost(
      artworkUri: resolved.artworkUri,
      fallbackFilePath: resolved.localPath,
      fit: BoxFit.cover,
      iconSize: 48,
      backgroundColor: Colors.white12,
      iconColor: Colors.white54,
    );
  }

  Widget _buildCurrentCoverPage(Song resolvedSong, double borderRadius) {
    final artwork = DepthCoverHost(
      artworkUri: resolvedSong.artworkUri,
      fallbackFilePath: resolvedSong.localPath,
      fit: BoxFit.cover,
      iconSize: 48,
      backgroundColor: Colors.white12,
      iconColor: Colors.white54,
    );
    return CoverFlipCrossfade(
      version: resolvedSong.artworkUri,
      fallbackFilePath: resolvedSong.localPath,
      iconSize: 48,
      radius: borderRadius,
      direction: _coverFlipDirection,
      readinessProbe: (uri, width, dpr) => isPlayerArtworkReady(
        artworkUri: uri,
        settledLogicalWidth: width,
        devicePixelRatio: dpr,
      ),
      child: resolvedSong.isOnline
          ? Stack(
              fit: StackFit.expand,
              children: [
                artwork,
                DynamicCoverView(song: resolvedSong, enabled: true),
              ],
            )
          : artwork,
    );
  }

  Widget _buildCover(
    BuildContext context,
    Song resolvedSong,
    double side, {
    double borderRadius = 12.0,
    bool queueExpanded = false,
  }) {
    final player = context.watch<PlayerProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    final prevSong = _pagerNeighborSong(player, -1);
    final nextSong = _pagerNeighborSong(player, 1);

    final coverContent = SizedBox(
      width: side,
      height: side,
      child: PlayerCoverSlot(
        songId: resolvedSong.id,
        artworkUri: resolvedSong.artworkUri,
        fallbackFilePath: resolvedSong.localPath,
        iconSize: 48,
        placeholderColor: Colors.white12,
        shadowColor: colorScheme.shadow,
        eligible: () =>
            !widget.dockMode &&
            !_isVideoMode &&
            widget.lyricsExpansion.value <= 0.001 &&
            _queueCtrl.value <= 0.001,
        settledScale: 1.0,
        settledAnchor: Alignment.center,
        child: SongDanmakuHost(
          cover: PlayerCoverShadow.wrap(
            shadowColor: colorScheme.shadow,
            child: CoverSwitchPager(
              key: _coverPagerKey,
              side: side,
              radius: borderRadius,
              pages: [
                _buildPagerPage(prevSong),
                _buildCurrentCoverPage(resolvedSong, borderRadius),
                _buildPagerPage(nextSong),
              ],
              canGoPrevious: prevSong != null && !queueExpanded,
              canGoNext: nextSong != null && !queueExpanded,
              onCommit: _onCoverPagerCommit,
            ),
          ),
        ),
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: widget.onDragStart,
      onVerticalDragUpdate: widget.onDragUpdate,
      onVerticalDragEnd: widget.onDragEnd,
      onVerticalDragCancel: widget.onDragCancel,
      child: AnimatedBuilder(
        animation: widget.lyricsExpansion,
        child: coverContent,
        builder: (context, child) {
          final drawerActive = widget.lyricsExpansion.value > 0.001;
          return Opacity(
            opacity: drawerActive ? 0.0 : 1.0,
            child: IgnorePointer(ignoring: drawerActive, child: child),
          );
        },
      ),
    );
  }

  Widget _buildTitleAndArtist(BuildContext context, Song song) {
    final title = song.displayName;
    final artist = song.artist;
    const titleStyle = TextStyle(
      color: Colors.white,
      fontSize: 22,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.3,
    );
    const subtitleStyle = TextStyle(
      color: Colors.white70,
      fontSize: 15,
      fontWeight: FontWeight.w400,
    );

    final titleBlock = Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () {
              final push =
                  widget.onDismissAndPush ??
                  widget.onPushPage ??
                  Navigator.of(context).push;
              YtMoreMenu.navigateToAlbum(context, song, push);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: GentleScrollingText(title, style: titleStyle)),
                const SizedBox(width: 4),
                const Icon(
                  Icons.chevron_right,
                  color: Colors.white70,
                  size: 22,
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          GestureDetector(
            onTap: () {
              final push =
                  widget.onDismissAndPush ??
                  widget.onPushPage ??
                  Navigator.of(context).push;
              YtMoreMenu.navigateToArtist(context, song, push);
            },
            child: Text(
              artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: subtitleStyle,
            ),
          ),
        ],
      ),
    );

    return PlayerTitleSlot(
      title: title,
      subtitle: artist,
      titleStyle: titleStyle,
      subtitleStyle: subtitleStyle,
      align: Alignment.centerLeft,
      eligible: () =>
          !widget.dockMode &&
          widget.lyricsExpansion.value <= 0.001 &&
          _queueCtrl.value <= 0.001,
      child: TitleSwitchFade(
        version: song.id,
        align: Alignment.centerLeft,
        child: titleBlock,
      ),
    );
  }

  /// 胶囊栏：第一枚为合体双联胶囊 `[ ♥ 喜欢 | ⭐ 收藏 ]`，后接 `[ 歌词 ]` `[ ➕ 保存 ]` `[ 评论 ]` `[ 曲谱 ]` `[ 音效 ]`
  Widget _buildCapsuleRow(
    BuildContext context,
    Song song,
    bool isFavorited,
    bool isOnline,
  ) {
    final hasSheet = song.albumAudioId != null && song.albumAudioId!.isNotEmpty;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          // 原版 YT 双联胶囊：[ ♥ 喜欢 | ⭐ 收藏(默认收藏歌单) ]
          _buildLikeAndCollectSplitPill(
            context: context,
            song: song,
            isFavorited: isFavorited,
            isOnline: isOnline,
          ),
          const SizedBox(width: 10),
          _buildCapsuleButton(
            icon: Icons.subtitles_outlined,
            label: '歌词',
            onTap: widget.onOpenLyrics,
          ),
          const SizedBox(width: 10),
          _buildCapsuleButton(
            icon: Icons.playlist_add,
            label: '保存',
            onTap: () => showAddToPlaylistDialog(context, song),
          ),
          const SizedBox(width: 10),
          _buildCapsuleButton(
            icon: Icons.comment_outlined,
            label: '评论',
            onTap: () => showSongCommentsSheet(context, song),
          ),
          if (hasSheet) ...[
            const SizedBox(width: 10),
            _buildCapsuleButton(
              icon: Icons.library_music_outlined,
              label: '曲谱',
              onTap: () => showSongSheetSheet(context, song),
            ),
          ],
          const SizedBox(width: 10),
          _buildCapsuleButton(
            icon: Icons.graphic_eq,
            label: '音效',
            onTap: () {
              final push = widget.onPushPage ?? Navigator.of(context).push;
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

  /// 合体双联胶囊：`[ ♥ 喜欢 | ⭐ 收藏 ]`
  Widget _buildLikeAndCollectSplitPill({
    required BuildContext context,
    required Song song,
    required bool isFavorited,
    required bool isOnline,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () {
              AppHaptics.lightImpact(HapticCategory.control);
              if (isOnline) {
                context.read<FavoritesProvider>().toggleFavorite(song);
              } else {
                context.read<LocalFavoritesProvider>().toggleFavorite(song.id);
              }
            },
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 7, 11, 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isFavorited ? Icons.favorite : Icons.favorite_border,
                    size: 18,
                    color: isFavorited ? Colors.redAccent : Colors.white,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '喜欢',
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
          Container(
            width: 1,
            height: 16,
            color: Colors.white.withValues(alpha: 0.22),
          ),
          InkWell(
            onTap: () => _toggleDefaultCollection(song),
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(11, 7, 14, 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _defaultStarred
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    size: 19,
                    color: _defaultStarred
                        ? const Color(0xFFFFD54F)
                        : Colors.white,
                  ),
                  const SizedBox(width: 5),
                  const Text(
                    '收藏',
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

  Widget _buildSeekBar(BuildContext context, Song song) {
    final vCtrl = _videoController;
    if (_isVideoMode && vCtrl != null && vCtrl.value.isInitialized) {
      final vVal = vCtrl.value;
      return PlayerSeekBar(
        position: vVal.position,
        duration: vVal.duration,
        isPlaying: vVal.isPlaying,
        speed: vVal.playbackSpeed,
        md3Style: true,
        waveEnabled: false,
        activeColor: Colors.white,
        inactiveColor: Colors.white24,
        labelColor: Colors.white70,
        onSeekStart: () {
          _wasPlayingBeforeDrag = vCtrl.value.isPlaying;
          if (_wasPlayingBeforeDrag) {
            vCtrl.pause();
          }
        },
        onSeekEnd: (pos) async {
          AppHaptics.tick(HapticCategory.transport);
          await vCtrl.seekTo(pos);
          if (_wasPlayingBeforeDrag) {
            await vCtrl.play();
          }
        },
      );
    }

    return Selector<
      PlayerProvider,
      ({Duration duration, bool isPlaying, double speed})
    >(
      selector: (_, p) => (
        duration: p.duration ?? Duration.zero,
        isPlaying: p.isPlaying,
        speed: p.speed,
      ),
      builder: (context, state, _) {
        final playerProvider = context.read<PlayerProvider>();
        return ValueListenableBuilder<bool>(
          valueListenable: kSeekBarWaveEnabled,
          builder: (context, waveEnabled, _) {
            return ValueListenableBuilder<Duration>(
              valueListenable: playerProvider.positionNotifier,
              builder: (context, position, _) {
                return PlayerSeekBar(
                  position: position,
                  duration: state.duration,
                  isPlaying: state.isPlaying,
                  speed: state.speed,
                  md3Style: true,
                  waveEnabled: waveEnabled,
                  activeColor: Colors.white,
                  inactiveColor: Colors.white24,
                  labelColor: Colors.white70,
                  climaxStart: song.climaxStart?.toDouble(),
                  climaxEnd: song.climaxEnd?.toDouble(),
                  onSeekStart: () {
                    _wasPlayingBeforeDrag = playerProvider.isPlaying;
                    if (_wasPlayingBeforeDrag) {
                      playerProvider.pauseForSeek();
                    }
                  },
                  onSeekEnd: (pos) async {
                    AppHaptics.tick(HapticCategory.transport);
                    await playerProvider.seek(pos, forceNotify: true);
                    if (_wasPlayingBeforeDrag) {
                      playerProvider.resume();
                    }
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildTransportControls(BuildContext context) {
    return Selector<
      PlayerProvider,
      ({bool isPlaying, bool shuffleEnabled, AppLoopMode loopMode})
    >(
      selector: (_, p) => (
        isPlaying: p.isPlaying,
        shuffleEnabled: p.shuffleEnabled,
        loopMode: p.loopMode,
      ),
      builder: (context, state, _) {
        final playerProvider = context.read<PlayerProvider>();
        final loopMode = state.loopMode;
        final vCtrl = _videoController;
        final effectivePlaying =
            (_isVideoMode && vCtrl != null && vCtrl.value.isInitialized)
            ? vCtrl.value.isPlaying
            : state.isPlaying;

        final IconData loopIcon = switch (loopMode) {
          AppLoopMode.one => Icons.repeat_one,
          AppLoopMode.all || AppLoopMode.off => Icons.repeat,
        };

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: const Icon(Icons.shuffle, size: 22),
              color: state.shuffleEnabled ? Colors.white : Colors.white60,
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
                if (_isVideoMode &&
                    vCtrl != null &&
                    vCtrl.value.isInitialized) {
                  if (vCtrl.value.isPlaying) {
                    vCtrl.pause();
                  } else {
                    vCtrl.play();
                  }
                  return;
                }
                if (state.isPlaying) {
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
                alignment: Alignment.center,
                child: PlayPauseMorphIcon(
                  isPlaying: effectivePlaying,
                  size: 34,
                  color: Colors.black,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.skip_next, size: 36, color: Colors.white),
              onPressed: () {
                AppHaptics.click(HapticCategory.transport);
                playerProvider.next();
              },
            ),
            IconButton(
              icon: Icon(loopIcon, size: 24),
              color: loopMode != AppLoopMode.off
                  ? Colors.white
                  : Colors.white60,
              onPressed: () {
                AppHaptics.lightImpact(HapticCategory.transport);
                playerProvider.toggleLoopMode();
              },
            ),
          ],
        );
      },
    );
  }

  /// 全屏队列态顶部 Mini Player 顶栏（1:1 还原图 5：小封面 + 歌名/歌手 + 上一首/播放暂停/下一首）
  Widget _buildFullQueueMiniHeader(
    BuildContext context,
    Song resolvedSong,
    double safeTop,
    double barH,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _snapQueueTo(_kQueueHalfSnap),
      onVerticalDragUpdate: _onQueueDragUpdate,
      onVerticalDragEnd: _onQueueDragEnd,
      child: Container(
        color: const Color(0xFF141110),
        padding: EdgeInsets.only(top: safeTop, left: 16, right: 8),
        height: safeTop + barH,
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 44,
                height: 44,
                child: DepthCoverHost(
                  artworkUri: resolvedSong.artworkUri,
                  fallbackFilePath: resolvedSong.localPath,
                  fit: BoxFit.cover,
                  iconSize: 22,
                  backgroundColor: Colors.white12,
                  iconColor: Colors.white54,
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
                    resolvedSong.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    resolvedSong.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            Selector<PlayerProvider, bool>(
              selector: (_, p) => p.isPlaying,
              builder: (context, isPlaying, _) {
                final playerProvider = context.read<PlayerProvider>();
                final vCtrl = _videoController;
                final effectivePlaying =
                    (_isVideoMode && vCtrl != null && vCtrl.value.isInitialized)
                    ? vCtrl.value.isPlaying
                    : isPlaying;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.skip_previous,
                        color: Colors.white,
                        size: 28,
                      ),
                      onPressed: () {
                        AppHaptics.click(HapticCategory.transport);
                        playerProvider.previous();
                      },
                    ),
                    IconButton(
                      icon: PlayPauseMorphIcon(
                        isPlaying: effectivePlaying,
                        size: 28,
                        color: Colors.white,
                      ),
                      onPressed: () {
                        AppHaptics.click(HapticCategory.transport);
                        if (_isVideoMode &&
                            vCtrl != null &&
                            vCtrl.value.isInitialized) {
                          if (vCtrl.value.isPlaying) {
                            vCtrl.pause();
                          } else {
                            vCtrl.play();
                          }
                          return;
                        }
                        if (isPlaying) {
                          playerProvider.pause();
                        } else {
                          playerProvider.resume();
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.skip_next,
                        color: Colors.white,
                        size: 28,
                      ),
                      onPressed: () {
                        AppHaptics.click(HapticCategory.transport);
                        playerProvider.next();
                      },
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 预构建的可交互播放列表区域：支持在半屏态上推至全屏、以及列表到顶时任意位置顺滑下拉收起
  Widget _buildInteractivePlaylistArea(double safeBottom) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _listPointerStartY = event.position.dy;
        _listDragStartQueueVal = _queueCtrl.value;
        _listCapturingQueueDrag = false;
        _listLastDy = 0.0;
      },
      onPointerMove: (event) {
        final startY = _listPointerStartY;
        if (startY == null) return;
        final totalDy = event.position.dy - startY;
        final stepDy = toDisplaySpaceDelta(context, event.delta).dy;
        final sc = YtMainView._playlistScrollAnchor.controller;
        final atTop = !sc.hasClients || sc.offset <= 1.0;

        if (!_listCapturingQueueDrag && totalDy.abs() > 6.0) {
          // 1) 在半屏态向上推 -> 优先将抽屉推向全屏(1.0)
          if (totalDy < -6.0 && _listDragStartQueueVal < 0.98) {
            _listCapturingQueueDrag = true;
          }
          // 2) 列表已处于顶部且向下拉 -> 无缝接管下拉抽屉（全屏 -> 半屏 -> 收起）
          else if (totalDy > 6.0 && atTop && _queueCtrl.value > 0.01) {
            _listCapturingQueueDrag = true;
          }
        }

        if (_listCapturingQueueDrag) {
          if (sc.hasClients && sc.offset > 0 && _queueCtrl.value < 0.99) {
            sc.jumpTo(0);
          }
          final screenH = MediaQuery.sizeOf(context).height;
          final range = (screenH * 0.68).clamp(240.0, 820.0);
          _queueCtrl.stop();
          _queueCtrl.value = (_queueCtrl.value - stepDy / range).clamp(
            0.0,
            1.0,
          );
          _listLastDy = stepDy;
        }
      },
      onPointerUp: (_) {
        if (_listCapturingQueueDrag) {
          _listCapturingQueueDrag = false;
          _settleQueueWithVelocity(_listLastDy * 55.0);
        }
        _listPointerStartY = null;
      },
      onPointerCancel: (_) {
        if (_listCapturingQueueDrag) {
          _listCapturingQueueDrag = false;
          _settleQueueWithVelocity(0.0);
        }
        _listPointerStartY = null;
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: safeBottom),
        child: PlayerPlaylistView(
          scrollAnchor: YtMainView._playlistScrollAnchor,
        ),
      ),
    );
  }

  /// 原版 YT Music 风格「接下来播放」三态联动歌单抽屉（0.0 收起 ↔ 0.5 半屏 ↔ 1.0 全屏）
  Widget _buildQueueDrawer(
    BuildContext context,
    Song currentSong,
    double q,
    Widget cachedPlaylistArea,
  ) {
    final playerProvider = context.read<PlayerProvider>();
    final nextSong = _pagerNeighborSong(playerProvider, 1) ?? currentSong;
    final bgAlpha = (q * 1.6).clamp(0.0, 1.0);
    final topRadius = q <= _kQueueHalfSnap
        ? 18.0
        : ui.lerpDouble(
            18.0,
            12.0,
            (q - _kQueueHalfSnap) / (1.0 - _kQueueHalfSnap),
          )!;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF141110).withValues(alpha: bgAlpha),
        borderRadius: BorderRadius.vertical(top: Radius.circular(topRadius)),
      ),
      child: Column(
        children: [
          // 顶部拖拽把手与折叠态标题 / 展开态「播放的音乐来自 + 保存」头部
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (q < 0.25) {
                _snapQueueTo(_kQueueHalfSnap);
              } else if (q < 0.8) {
                _snapQueueTo(1.0);
              } else {
                _snapQueueTo(_kQueueHalfSnap);
              }
            },
            onVerticalDragUpdate: _onQueueDragUpdate,
            onVerticalDragEnd: _onQueueDragEnd,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white30,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (q < 0.18)
                    Opacity(
                      opacity: (1.0 - q * 5.5).clamp(0.0, 1.0),
                      child: SizedBox(
                        height: 24,
                        child: Center(
                          child: Text(
                            '接下来播放 · ${nextSong.displayName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    Opacity(
                      opacity: ((q - 0.18) / 0.32).clamp(0.0, 1.0),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    '播放的音乐来自',
                                    style: TextStyle(
                                      color: Colors.white60,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    currentSong.album.isNotEmpty &&
                                            currentSong.album != '未知专辑'
                                        ? currentSong.album
                                        : currentSong.displayName,
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
                            _buildCapsuleButton(
                              icon: Icons.playlist_add,
                              label: '保存',
                              onTap: () =>
                                  showAddToPlaylistDialog(context, currentSong),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 展开态下的播放队列列表（复用预缓存的 cachedPlaylistArea，拖拽 0 次 Rebuild）
          Expanded(
            child: Offstage(
              offstage: q <= 0.03,
              child: Opacity(
                opacity: ((q - 0.05) / 0.35).clamp(0.0, 1.0),
                child: IgnorePointer(
                  ignoring: q < 0.25,
                  child: cachedPlaylistArea,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
