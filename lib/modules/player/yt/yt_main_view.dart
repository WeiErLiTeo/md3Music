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
import '../../../widgets/player_seek_bar.dart';
import '../../settings/equalizer_settings_page.dart';
import '../../sheet/song_sheet_sheet.dart';
import '../comments_view.dart';
import '../cover_switch_physics.dart';
import '../dlna_cast_sheet.dart';
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
  bool _isSeekingVideo = false;
  bool _lastVideoPlayingState = false;
  DateTime? _lastSongSwitchAt;

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
  bool _handlingMvCompletion = false;
  bool _autoReenterVideoOnNextSong = false;
  Timer? _songSwitchDeferTimer;
  bool _dynamicCoverReady = true;

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
        widget.song.albumAudioId != oldWidget.song.albumAudioId ||
        widget.song.artworkUri != oldWidget.song.artworkUri) {
      final resolved = YtMoreMenu.resolveMatchedSong(widget.song);
      _defaultStarred = _isSongInDefaultCollection(widget.song, resolved);
      if (widget.song.albumAudioId != oldWidget.song.albumAudioId) {
        _syncSongCapabilities(
          widget.song,
          autoEnterVideoIfAvailable: _isVideoMode,
        );
      }
    }
  }

  @override
  void dispose() {
    _songSwitchDeferTimer?.cancel();
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

  void _syncSongCapabilities(
    Song rawSong, {
    bool autoEnterVideoIfAvailable = false,
  }) {
    final resolved = YtMoreMenu.resolveMatchedSong(rawSong);
    _defaultStarred = _isSongInDefaultCollection(rawSong, resolved);
    unawaited(_ensureDefaultCollectionSynced());

    final albumAudioId = resolved.albumAudioId;
    if (albumAudioId == _probedAlbumAudioId && !autoEnterVideoIfAvailable) {
      return;
    }
    _probedAlbumAudioId = albumAudioId;

    if (_isVideoMode && !autoEnterVideoIfAvailable) {
      _exitVideoMode(resumeAudio: false);
    }

    if (albumAudioId == null || albumAudioId.isEmpty) {
      if (mounted) {
        setState(() => _currentMvInfo = null);
      }
      if (autoEnterVideoIfAvailable) {
        _exitVideoMode(resumeAudio: true);
      }
      return;
    }

    if (YtMainView._mvInfoCache.containsKey(albumAudioId)) {
      final cachedInfo = YtMainView._mvInfoCache[albumAudioId];
      if (mounted) {
        setState(() => _currentMvInfo = cachedInfo);
        if (autoEnterVideoIfAvailable) {
          if (cachedInfo != null && cachedInfo.hasMv) {
            unawaited(_enterVideoMode(resolved, forceReload: true));
          } else {
            _exitVideoMode(resumeAudio: true);
          }
        }
      }
      return;
    }

    _currentMvInfo = null;
    KugouApiClient()
        .getMvByAlbumAudioId(albumAudioId)
        .then((info) {
          final validInfo = (info != null && info.hasMv) ? info : null;
          YtMainView._mvInfoCache[albumAudioId] = validInfo;
          if (!mounted || _probedAlbumAudioId != albumAudioId) return;
          setState(() {
            _currentMvInfo = validInfo;
          });
          if (autoEnterVideoIfAvailable) {
            if (validInfo != null) {
              unawaited(_enterVideoMode(resolved, forceReload: true));
            } else {
              _exitVideoMode(resumeAudio: true);
            }
          }
        })
        .catchError((_) {
          if (mounted &&
              _probedAlbumAudioId == albumAudioId &&
              autoEnterVideoIfAvailable) {
            _exitVideoMode(resumeAudio: true);
          }
        });
  }

  bool get _hasMv => _currentMvInfo != null && _currentMvInfo!.hasMv;

  Future<void> _enterVideoMode(
    Song resolvedSong, {
    bool forceReload = false,
  }) async {
    if (!_hasMv) {
      showToast('当前歌曲暂无 MV 视频');
      return;
    }
    if (_isVideoMode && !forceReload) return;
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
    _handlingMvCompletion = false;
    final ctrl = VideoPlayerController.networkUrl(
      Uri.parse(url),
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
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
      final loopOne = _playerProvider?.loopMode == AppLoopMode.one;
      await ctrl.setLooping(loopOne);
      if (_playerProvider?.isPlaying ?? false) {
        _playerProvider?.pause();
      }
      ctrl.addListener(_onInlineVideoTick);
      await ctrl.play();
      _lastVideoPlayingState = true;
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
    if (ctrl == null) return;
    final val = ctrl.value;
    if (val.isPlaying != _lastVideoPlayingState) {
      _lastVideoPlayingState = val.isPlaying;
      WakelockService.instance.setVideoPlaying(val.isPlaying);
    }
    if (val.isInitialized &&
        !_videoLoading &&
        !_isSeekingVideo &&
        !_handlingMvCompletion &&
        !val.isLooping &&
        val.duration > const Duration(seconds: 1) &&
        val.position >= val.duration - const Duration(milliseconds: 250) &&
        !val.isPlaying) {
      _handlingMvCompletion = true;
      final player = _playerProvider;
      if (player != null) {
        if (player.loopMode == AppLoopMode.one) {
          ctrl.seekTo(Duration.zero).then((_) => ctrl.play()).whenComplete(() {
            _handlingMvCompletion = false;
          });
        } else if (player.loopMode == AppLoopMode.off &&
            player.currentIndex >= player.playlist.length - 1) {
          // 列表不循环且已到最后一首：停留在末尾，不再循环切歌
          _handlingMvCompletion = false;
        } else {
          _autoReenterVideoOnNextSong = true;
          player.next().whenComplete(() {
            _handlingMvCompletion = false;
          });
        }
      } else {
        _handlingMvCompletion = false;
      }
    }
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

    // 同步单曲循环状态至内嵌 MV 播放器
    final ctrl = _videoController;
    if (_isVideoMode && ctrl != null && ctrl.value.isInitialized) {
      final shouldLoop = player.loopMode == AppLoopMode.one;
      if (ctrl.value.isLooping != shouldLoop) {
        unawaited(ctrl.setLooping(shouldLoop));
      }
    }

    final song = player.currentSong;
    final slideDirection = coverSlideDirectionForIndexChange(
      fromIndex: _lastPagerIndex ?? player.currentIndex,
      toIndex: player.currentIndex,
      playlistLength: player.playlist.length,
    );
    _lastPagerIndex = player.currentIndex;
    if (song != null && song.id != _lastSongId) {
      _lastSongId = song.id;
      _lastSongSwitchAt = DateTime.now();
      final bool shouldAutoPlayMv = _isVideoMode || _autoReenterVideoOnNextSong;
      _autoReenterVideoOnNextSong = false;
      if (shouldAutoPlayMv) {
        // 切歌但希望保持 MV 模式：立即压制背景音频起播，并探测新歌 MV
        if (player.isPlaying) {
          player.pause();
        }
        _syncSongCapabilities(song, autoEnterVideoIfAvailable: true);
      } else {
        if (_isVideoMode) {
          _exitVideoMode(resumeAudio: false);
        }
        _dynamicCoverReady = false;
        _songSwitchDeferTimer?.cancel();
        _songSwitchDeferTimer = Timer(const Duration(milliseconds: 280), () {
          if (!mounted) return;
          setState(() => _dynamicCoverReady = true);
          _syncSongCapabilities(song, autoEnterVideoIfAvailable: false);
        });
      }
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
      if (idx > 0) {
        final prevResolved = YtMoreMenu.resolveMatchedSong(playlist[idx - 1]);
        preloadPlayerArtwork(prevResolved.artworkUri);
      }
      if (idx < playlist.length - 1) {
        final nextResolved = YtMoreMenu.resolveMatchedSong(playlist[idx + 1]);
        preloadPlayerArtwork(nextResolved.artworkUri);
      }
    } else if (_isVideoMode && player.isPlaying) {
      final switchAt = _lastSongSwitchAt;
      final isJustSwitched =
          switchAt != null &&
          DateTime.now().difference(switchAt) <
              const Duration(milliseconds: 1600);
      if (_videoLoading || isJustSwitched) {
        // 切歌或 MV 正在加载期间，音频引擎异步解析完自动起播：静默压制音频，不退出 MV 模式
        player.pause();
      } else {
        // 当处于稳定 MV 模式时，若用户在播放列表或迷你栏主动触发了音频播放，退出 MV 模式避免双声道混音
        _exitVideoMode(resumeAudio: false);
      }
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
        // 封面位置稍微往下一点点，与原版 YT Music 视觉重心完全对齐
        final double coverTopGap = (extraVertical * 0.58).clamp(28.0, 44.0);
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

        // 2. 下半区四件套位置：1:1 对齐原版 YT Music，
        // 歌名和歌手稍微往上一丢丢，配合稍大一点的胶囊按钮与五键控制栏
        final double queueHandleTop = screenH - safeBottom - handleCollapsedH;
        final double normalTransportTop = queueHandleTop - 28.0 - 78.0;
        final double normalSeekTop = normalTransportTop - 54.0;
        final double normalCapsuleTop = normalSeekTop - 60.0;
        final double normalTitleTop = math.max(
          normalCoverTop + normalCoverSide + 10.0,
          normalCapsuleTop - 78.0,
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            // 当处于 MV 视频模式时，同源动态高斯模糊光晕 100% 全屏延伸入侵（从顶栏直达最底部把手），
            // 彻底消除下半屏断层与分界横线
            if (_isVideoMode)
              Positioned.fill(
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

            // 胶囊操作栏（外层铺满全屏宽度，内部 SingleChildScrollView 设 24px 内边距，消除右侧硬截断）
            Positioned(
              left: 0,
              right: 0,
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

            // 五键播放控制栏（左右 24px 严格对齐进度条与歌名两端）
            Positioned(
              left: 24,
              right: 24,
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
                      horizontalPadding: 4,
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

  /// MV 视频模式下 100% 全屏延伸入侵整个播放器的同源动态柔光高斯模糊层
  Widget _buildMvAmbientInvasionBackdrop(Song resolvedSong) {
    final ctrl = _videoController;
    final initialized = ctrl != null && ctrl.value.isInitialized;
    final vSize = initialized ? ctrl.value.size : Size.zero;
    final vW = vSize.width > 0 ? vSize.width : 160.0;
    final vH = vSize.height > 0 ? vSize.height : 90.0;

    return RepaintBoundary(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: 46,
          sigmaY: 46,
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
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.25, 0.65, 1.0],
                  colors: [
                    Colors.black.withValues(alpha: 0.26),
                    Colors.black.withValues(alpha: 0.14),
                    Colors.black.withValues(alpha: 0.34),
                    Colors.black.withValues(alpha: 0.56),
                  ],
                ),
              ),
            ),
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

  /// 原地内嵌 MV 视频播放器（上下边缘拓宽 ShaderMask 羽化消除横线，画面 100% 纯净无浮动按钮遮挡）
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
            // 中央 16:9 完整主视频画面：上下边缘使用宽幅 ShaderMask Alpha 羽化过渡，彻底消除两条硬横线
            if (initialized)
              Center(
                child: ShaderMask(
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.0, 0.11, 0.89, 1.0],
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
      child: resolvedSong.isOnline && _dynamicCoverReady
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
    final colorScheme = Theme.of(context).colorScheme;

    final coverContent = SizedBox(
      width: side,
      height: side,
      child: Selector<PlayerProvider, (Song?, Song?)>(
        selector: (_, p) =>
            (_pagerNeighborSong(p, -1), _pagerNeighborSong(p, 1)),
        builder: (context, neighbors, _) {
          final prevSong = neighbors.$1;
          final nextSong = neighbors.$2;
          return PlayerCoverSlot(
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
          );
        },
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

  /// 弹出 MV 清晰度切换底部面板
  void _showMvQualitySheet(BuildContext context) {
    if (_mvQualities.isEmpty) {
      showToast('当前 MV 仅提供默认清晰度');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '选择视频清晰度',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                for (int i = 0; i < _mvQualities.length; i++)
                  ListTile(
                    leading: Icon(
                      i == _mvQualityIndex
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      color: i == _mvQualityIndex
                          ? Colors.white
                          : Colors.white54,
                      size: 20,
                    ),
                    title: Text(
                      _mvQualities[i].quality,
                      style: TextStyle(
                        color: i == _mvQualityIndex
                            ? Colors.white
                            : Colors.white70,
                        fontWeight: i == _mvQualityIndex
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _switchMvQuality(i);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 胶囊栏：
  /// - 音频模式：`[ ♥ 喜欢 | ⭐ 收藏 ]`、`[ 歌词 ]`、`[ 保存 ]`、`[ 评论 ]`、`[ 曲谱 ]`、`[ 音效 ]`
  /// - MV 视频模式：`[ ♥ 喜欢 | ⭐ 收藏 ]`、`[ 投屏 ]`、`[ 清晰度 ]`、`[ 全屏 ]`、`[ 保存 ]`、`[ 评论 ]`
  Widget _buildCapsuleRow(
    BuildContext context,
    Song song,
    bool isFavorited,
    bool isOnline, {
    double horizontalPadding = 24.0,
  }) {
    final hasSheet = song.albumAudioId != null && song.albumAudioId!.isNotEmpty;
    final currentQualityLabel =
        (_mvQualities.isNotEmpty &&
            _mvQualityIndex >= 0 &&
            _mvQualityIndex < _mvQualities.length)
        ? '清晰度 · ${_mvQualities[_mvQualityIndex].quality}'
        : '清晰度';

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Row(
        children: [
          // 原版 YT 双联胶囊：[ ♥ 喜欢 | ⭐ 收藏(默认收藏歌单) ]
          _buildLikeAndCollectSplitPill(
            context: context,
            song: song,
            isFavorited: isFavorited,
            isOnline: isOnline,
          ),
          if (_isVideoMode) ...[
            const SizedBox(width: 10),
            _buildCapsuleButton(
              icon: Icons.cast_rounded,
              label: '投屏',
              onTap: () => showM3EModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Theme.of(context)
                    .colorScheme
                    .surfaceContainerLow,
                builder: (_) => DlnaCastSheet(
                  mvUrl: _currentVideoUrl,
                  mvTitle: '${song.displayName} - ${song.artist} (MV)',
                ),
              ),
            ),
            const SizedBox(width: 10),
            _buildCapsuleButton(
              icon: Icons.hd_outlined,
              label: currentQualityLabel,
              onTap: () => _showMvQualitySheet(context),
            ),
            const SizedBox(width: 10),
            _buildCapsuleButton(
              icon: Icons.fullscreen_rounded,
              label: '全屏',
              onTap: () {
                final url = _currentVideoUrl;
                _exitVideoMode(resumeAudio: false);
                final push = widget.onPushPage ?? Navigator.of(context).push;
                push(
                  MaterialPageRoute(
                    builder: (_) =>
                        MvPlayerPage(song: song, directVideoUrl: url),
                  ),
                );
              },
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
          ] else ...[
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
        borderRadius: BorderRadius.circular(22),
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
              left: Radius.circular(22),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(15.5, 8.5, 12.5, 8.5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isFavorited ? Icons.favorite : Icons.favorite_border,
                    size: 19.5,
                    color: isFavorited ? Colors.redAccent : Colors.white,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '喜欢',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            width: 1,
            height: 17,
            color: Colors.white.withValues(alpha: 0.22),
          ),
          InkWell(
            onTap: () => _toggleDefaultCollection(song),
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(22),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12.5, 8.5, 15.5, 8.5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _defaultStarred
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    size: 20.5,
                    color: _defaultStarred
                        ? const Color(0xFFFFD54F)
                        : Colors.white,
                  ),
                  const SizedBox(width: 5),
                  const Text(
                    '收藏',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
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
      borderRadius: BorderRadius.circular(22),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15.5, vertical: 8.5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 19.5, color: iconColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
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
      return ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: vCtrl,
        builder: (context, vVal, _) {
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
              _isSeekingVideo = true;
              _wasPlayingBeforeDrag = vCtrl.value.isPlaying;
              if (_wasPlayingBeforeDrag) {
                vCtrl.pause();
              }
            },
            onSeekEnd: (pos) async {
              AppHaptics.tick(HapticCategory.transport);
              try {
                await vCtrl.seekTo(pos);
                if (_wasPlayingBeforeDrag) {
                  await vCtrl.play();
                }
              } finally {
                _isSeekingVideo = false;
              }
            },
          );
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

        final IconData loopIcon = switch (loopMode) {
          AppLoopMode.one => Icons.repeat_one_rounded,
          AppLoopMode.all || AppLoopMode.off => Icons.repeat_rounded,
        };

        Widget playPauseCircle(bool isPlayingNow) {
          return Container(
            width: 78,
            height: 78,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: PlayPauseMorphIcon(
              isPlaying: isPlayingNow,
              size: 38,
              color: Colors.black,
            ),
          );
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
              tooltip: state.shuffleEnabled ? '随机播放：已开启' : '随机播放：已关闭',
              icon: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.shuffle_rounded,
                    size: 30,
                    color: state.shuffleEnabled ? Colors.white : Colors.white60,
                  ),
                  const SizedBox(height: 2),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: state.shuffleEnabled
                          ? Colors.white
                          : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              onPressed: () async {
                AppHaptics.lightImpact(HapticCategory.transport);
                final enabling = !state.shuffleEnabled;
                await playerProvider.toggleShuffle();
                _lastPagerIndex = playerProvider.currentIndex;
                // 开启随机播放时若处于单曲循环或不循环，自动联动切为列表循环，避免随机播放失效
                if (enabling && playerProvider.loopMode != AppLoopMode.all) {
                  await playerProvider.setLoopMode(AppLoopMode.all);
                  if (_isVideoMode &&
                      vCtrl != null &&
                      vCtrl.value.isInitialized) {
                    unawaited(vCtrl.setLooping(false));
                  }
                }
              },
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(
                Icons.skip_previous_rounded,
                size: 44,
                color: Colors.white,
              ),
              onPressed: () {
                AppHaptics.click(HapticCategory.transport);
                if (_isVideoMode) {
                  _autoReenterVideoOnNextSong = true;
                }
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
                    if (vCtrl.value.position >=
                        vCtrl.value.duration -
                            const Duration(milliseconds: 300)) {
                      vCtrl.seekTo(Duration.zero);
                    }
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
              child: (_isVideoMode && vCtrl != null && vCtrl.value.isInitialized)
                  ? ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: vCtrl,
                      builder: (context, vVal, _) =>
                          playPauseCircle(vVal.isPlaying),
                    )
                  : playPauseCircle(state.isPlaying),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(
                Icons.skip_next_rounded,
                size: 44,
                color: Colors.white,
              ),
              onPressed: () {
                AppHaptics.click(HapticCategory.transport);
                if (_isVideoMode) {
                  _autoReenterVideoOnNextSong = true;
                }
                playerProvider.next();
              },
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
              tooltip: switch (loopMode) {
                AppLoopMode.off => '循环关闭',
                AppLoopMode.all => '列表循环',
                AppLoopMode.one => '单曲循环',
              },
              icon: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    loopIcon,
                    size: 30,
                    color: loopMode != AppLoopMode.off
                        ? Colors.white
                        : Colors.white60,
                  ),
                  const SizedBox(height: 2),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: loopMode != AppLoopMode.off
                          ? Colors.white
                          : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              onPressed: () async {
                AppHaptics.lightImpact(HapticCategory.transport);
                await playerProvider.toggleLoopMode();
                if (_isVideoMode &&
                    vCtrl != null &&
                    vCtrl.value.isInitialized) {
                  unawaited(
                    vCtrl.setLooping(
                      playerProvider.loopMode == AppLoopMode.one,
                    ),
                  );
                }
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
    return Selector<PlayerProvider, String>(
      selector: (_, p) => (_pagerNeighborSong(p, 1) ?? currentSong).displayName,
      builder: (context, nextTitle, _) {
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
                      '接下来播放 · $nextTitle',
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
      },
    );
  }
}
