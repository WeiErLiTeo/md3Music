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
  static final PlaylistScrollAnchor playlistScrollAnchor =
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
  bool _mvControlsVisible = true;
  Timer? _mvControlsHideTimer;

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
        _showMvControlsTemporarily();
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

  void _showMvControlsTemporarily() {
    _mvControlsHideTimer?.cancel();
    if (mounted) {
      setState(() => _mvControlsVisible = true);
    }
    _mvControlsHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isVideoMode) {
        setState(() => _mvControlsVisible = false);
      }
    });
  }

  void _onTapMvArea() {
    if (_mvControlsVisible) {
      _mvControlsHideTimer?.cancel();
      setState(() => _mvControlsVisible = false);
    } else {
      _showMvControlsTemporarily();
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
    _mvControlsHideTimer?.cancel();
    _mvControlsHideTimer = null;
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

  // ============== 「接下来播放」队列抽屉全屏展开控制（1:1 复刻歌词展开动画） ==============
  void _openQueue() {
    AppHaptics.lightImpact(HapticCategory.control);
    _queueCtrl.animateTo(
      1.0,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );
  }

  void _closeQueue() {
    AppHaptics.lightImpact(HapticCategory.control);
    _queueCtrl.animateBack(
      0.0,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInCubic,
    );
  }

  void _onQueueDragUpdate(DragUpdateDetails details) {
    final screenH = MediaQuery.sizeOf(context).height;
    final range = (screenH * 0.72).clamp(200.0, 900.0);
    final dy = toDisplaySpaceDelta(context, details.delta).dy;
    _queueCtrl.stop();
    _queueCtrl.value = (_queueCtrl.value - dy / range).clamp(0.0, 1.0);
  }

  void _onQueueDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0.0;
    if (v < -400.0) {
      _openQueue();
    } else if (v > 400.0) {
      _closeQueue();
    } else if (_queueCtrl.value >= 0.5) {
      _openQueue();
    } else {
      _closeQueue();
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

        // 横屏模式：自动切换为「左封面/MV + 右控制区」双栏分屏布局
        if (screenW > screenH * 1.1) {
          return _buildLandscapeLayout(
            context: context,
            resolvedSong: resolvedSong,
            isFavorited: isFavorited,
            isOnline: isOnline,
            screenW: screenW,
            screenH: screenH,
            safeTop: safeTop,
            safeBottom: safeBottom,
          );
        }

        // 1. 封面几何计算（保持与原版 YT Music 完全一致的黄金位置与尺寸）
        const double topBarH = 52.0;
        const double coverSideMargin = 24.0;
        const double handleCollapsedH = 52.0;
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

        // 2. 下半区四件套位置：1:1 对齐原版 YT Music（图 2），自底向上贴近底部「接下来播放」把手锚定，
        // 将多余垂直呼吸空间留在「封面底边 → 歌名」之间，彻底消除播放键下方的空洞！
        final double queueHandleTop = screenH - safeBottom - handleCollapsedH;
        final double normalTransportTop = queueHandleTop - 18.0 - 64.0;
        final double normalSeekTop = normalTransportTop - 52.0;
        final double normalCapsuleTop = normalSeekTop - 54.0;
        final double normalTitleTop = math.max(
          normalCoverTop + normalCoverSide + 16.0,
          normalCapsuleTop - 68.0,
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            // 当处于 MV 视频模式时，同源动态高斯模糊光晕向上延伸入侵至顶栏、向下入侵至歌名与胶囊栏背后，
            // 并通过长渐变羽化无缝融入播放器主背景，彻底消除图 3 的圆角方框割裂感
            if (_isVideoMode)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: math.min(screenH, normalCapsuleTop + 48.0),
                child: IgnorePointer(
                  child: _buildMvAmbientInvasionBackdrop(resolvedSong),
                ),
              ),

            // 封面 / 全宽无界 MV 视频层
            Positioned(
              left: _isVideoMode ? 0.0 : normalCoverLeft,
              top: normalCoverTop,
              width: _isVideoMode ? screenW : normalCoverSide,
              height: normalCoverSide,
              child: _isVideoMode
                  ? _buildInlineMvPlayer(context, resolvedSong, 0.0)
                  : _buildCover(
                      context,
                      resolvedSong,
                      normalCoverSide,
                      borderRadius: 12.0,
                    ),
            ),

            // 顶部栏
            Positioned(
              left: 0,
              right: 0,
              top: safeTop,
              height: topBarH,
              child: _buildTopBar(context, resolvedSong),
            ),

            // 歌名与歌手名
            Positioned(
              left: 24,
              right: 24,
              top: normalTitleTop,
              child: _buildTitleAndArtist(context, resolvedSong),
            ),

            // 胶囊操作栏
            Positioned(
              left: 20,
              right: 20,
              top: normalCapsuleTop,
              child: _buildCapsuleRow(
                context,
                resolvedSong,
                isFavorited,
                isOnline,
              ),
            ),

            // 播放进度条
            Positioned(
              left: 18,
              right: 18,
              top: normalSeekTop,
              child: _buildSeekBar(context, resolvedSong),
            ),

            // 五键播放控制栏
            Positioned(
              left: 20,
              right: 20,
              top: normalTransportTop,
              child: _buildTransportControls(context),
            ),

            // 底部「接下来播放」把手（点击或上滑触发全屏展开动画，1:1 复刻歌词展开动画）
            Positioned(
              left: 0,
              right: 0,
              top: queueHandleTop,
              height: handleCollapsedH + safeBottom,
              child: _buildBottomQueueHandle(context, resolvedSong, safeBottom),
            ),
          ],
        );
      },
    );
  }

  /// 横屏模式布局：左栏封面/MV + 右栏歌曲信息与控制区
  Widget _buildLandscapeLayout({
    required BuildContext context,
    required Song resolvedSong,
    required bool isFavorited,
    required bool isOnline,
    required double screenW,
    required double screenH,
    required double safeTop,
    required double safeBottom,
  }) {
    final availH = math.max(180.0, screenH - safeTop - safeBottom);
    final leftW = screenW * 0.45;
    final coverSide = math.min(leftW - 40.0, availH - 68.0).clamp(120.0, 340.0);
    final coverLeft = (leftW - coverSide) / 2.0;
    final coverTop = safeTop + 48.0 + (availH - 48.0 - coverSide) / 2.0;

    widget.onCoverRectMeasured?.call(
      Rect.fromLTWH(coverLeft, coverTop, coverSide, coverSide),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        if (_isVideoMode)
          Positioned.fill(
            child: IgnorePointer(
              child: _buildMvAmbientInvasionBackdrop(resolvedSong),
            ),
          ),
        Padding(
          padding: EdgeInsets.only(
            top: safeTop,
            bottom: safeBottom,
            left: 12,
            right: 16,
          ),
          child: Row(
            children: [
              // 左栏：顶栏切换器 + 封面 / MV
              SizedBox(
                width: leftW - 12,
                child: Column(
                  children: [
                    SizedBox(
                      height: 48,
                      child: _buildTopBar(context, resolvedSong),
                    ),
                    Expanded(
                      child: Center(
                        child: _isVideoMode
                            ? AspectRatio(
                                aspectRatio: 16 / 9,
                                child: _buildInlineMvPlayer(
                                  context,
                                  resolvedSong,
                                  12.0,
                                ),
                              )
                            : _buildCover(
                                context,
                                resolvedSong,
                                coverSide,
                                borderRadius: 12.0,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // 右栏：歌名、胶囊栏、进度条、五键控制栏、底部接下来播放把手
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: _buildTitleAndArtist(context, resolvedSong),
                    ),
                    _buildCapsuleRow(
                      context,
                      resolvedSong,
                      isFavorited,
                      isOnline,
                    ),
                    _buildSeekBar(context, resolvedSong),
                    _buildTransportControls(context),
                    _buildBottomQueueHandle(context, resolvedSong, 0),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// MV 视频模式下延伸入侵整个播放器上半屏的同源动态柔光高斯模糊层
  Widget _buildMvAmbientInvasionBackdrop(Song resolvedSong) {
    final ctrl = _videoController;
    final initialized = ctrl != null && ctrl.value.isInitialized;
    final vSize = initialized ? ctrl.value.size : Size.zero;
    final vW = vSize.width > 0 ? vSize.width : 160.0;
    final vH = vSize.height > 0 ? vSize.height : 90.0;

    return ShaderMask(
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: [0.0, 0.14, 0.68, 1.0],
        colors: [
          Colors.transparent,
          Colors.black,
          Colors.black,
          Colors.transparent,
        ],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: 34,
          sigmaY: 34,
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
              backgroundColor: Colors.transparent,
              iconColor: Colors.white24,
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
            ColoredBox(color: Colors.black.withValues(alpha: 0.22)),
          ],
        ),
      ),
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

  /// 原地内嵌 MV 视频播放器（上下边缘 ShaderMask 柔化消除横线 + 控件 3 秒无操作自动隐去）
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

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onTapMvArea,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. 中央 16:9 完整主视频画面：上下边缘使用 ShaderMask Alpha 羽化过渡，彻底消除两条硬横线
            if (initialized)
              Center(
                child: ShaderMask(
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.0, 0.055, 0.945, 1.0],
                    colors: [
                      Colors.transparent,
                      Colors.black,
                      Colors.black,
                      Colors.transparent,
                    ],
                  ).createShader(rect),
                  blendMode: BlendMode.dstIn,
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
            // 2. 右下角「清晰度」与「全屏」按钮：位于视频底边下方光晕带内零遮挡，且 3 秒自动淡出隐藏
            if (initialized)
              Positioned(
                right: 16,
                bottom: 10,
                child: IgnorePointer(
                  ignoring: !_mvControlsVisible,
                  child: AnimatedOpacity(
                    opacity: _mvControlsVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_mvQualities.length > 1)
                          PopupMenuButton<int>(
                            tooltip: '切换清晰度',
                            color: const Color(0xFF222222),
                            onOpened: () => _mvControlsHideTimer?.cancel(),
                            onCanceled: _showMvControlsTemporarily,
                            onSelected: (idx) {
                              _showMvControlsTemporarily();
                              _switchMvQuality(idx);
                            },
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
                                color: Colors.black.withValues(alpha: 0.45),
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
                              color: Colors.black.withValues(alpha: 0.45),
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
        animation: Listenable.merge([widget.lyricsExpansion, _queueCtrl]),
        child: coverContent,
        builder: (context, child) {
          final drawerActive =
              widget.lyricsExpansion.value > 0.001 || _queueCtrl.value > 0.001;
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

  /// 底部「接下来播放」入口把手（点击或向上拖拽直接以 1:1 歌词展开动画打开全屏播放列表抽屉）
  Widget _buildBottomQueueHandle(
    BuildContext context,
    Song currentSong,
    double safeBottom,
  ) {
    final playerProvider = context.read<PlayerProvider>();
    final nextSong = _pagerNeighborSong(playerProvider, 1) ?? currentSong;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openQueue,
      onVerticalDragUpdate: _onQueueDragUpdate,
      onVerticalDragEnd: _onQueueDragEnd,
      child: Padding(
        padding: EdgeInsets.only(left: 20, right: 20, bottom: safeBottom),
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
            SizedBox(
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
          ],
        ),
      ),
    );
  }
}
