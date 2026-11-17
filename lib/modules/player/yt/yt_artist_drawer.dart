import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../../core/utils/app_haptics.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/song.dart';
import '../../../providers/player_provider.dart';
import '../../../services/kugou_api/kugou_api_client.dart';
import '../../../services/kugou_api/kugou_models.dart';
import '../../album/album_detail_page.dart';
import '../../artist/artist_detail_page.dart';
import '../../artist/artist_photo_banner.dart';
import '../artist_photo_service.dart';
import 'yt_lyrics_drawer.dart';
import 'yt_more_menu.dart';

/// 1:1 复刻歌词与评论抽屉展开动画的全屏内嵌「歌手信息」抽屉
/// （共用顶部 MiniBar + 悬浮封面飞行缩放 + 顶部下拉关闭手势 + 正方形大专辑卡片）
class YtArtistDrawer extends StatefulWidget {
  final Animation<double> expansion;
  final Song song;
  final String? initialArtistName;
  final bool isVideoMode;
  final VideoPlayerController? videoController;
  final VoidCallback onClose;
  final void Function(Route<dynamic>)? onPushPage;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const YtArtistDrawer({
    super.key,
    required this.expansion,
    required this.song,
    this.initialArtistName,
    this.isVideoMode = false,
    this.videoController,
    required this.onClose,
    this.onPushPage,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  State<YtArtistDrawer> createState() => _YtArtistDrawerState();
}

class _YtArtistDrawerState extends State<YtArtistDrawer> {
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
  void didUpdateWidget(covariant YtArtistDrawer oldWidget) {
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
            '${widget.song.id}_${widget.song.artist}_${widget.song.artistId}_${widget.initialArtistName}_${safeBottom.toStringAsFixed(1)}';
        if (_cachedSheet == null || _cachedSheetKey != sheetKey) {
          _cachedSheetKey = sheetKey;
          _cachedSheet = RepaintBoundary(
            child: _YtArtistDrawerContent(
              song: widget.song,
              initialArtistName: widget.initialArtistName,
              safeBottom: safeBottom,
              onClose: widget.onClose,
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

enum _ArtistDrawerTab { hotSongs, albums }

class _YtArtistDrawerContent extends StatefulWidget {
  final Song song;
  final String? initialArtistName;
  final double safeBottom;
  final VoidCallback onClose;
  final void Function(Route<dynamic>)? onPushPage;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const _YtArtistDrawerContent({
    required this.song,
    this.initialArtistName,
    required this.safeBottom,
    required this.onClose,
    this.onPushPage,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  State<_YtArtistDrawerContent> createState() => _YtArtistDrawerContentState();
}

class _YtArtistDrawerContentState extends State<_YtArtistDrawerContent> {
  final ScrollController _scrollController = ScrollController();
  double? _pointerStartY;
  bool _capturingPullDown = false;
  double _lastStepDy = 0.0;

  List<String> _artistNames = const [];
  int _selectedArtistIndex = 0;

  int _requestToken = 0;
  bool _loading = true;
  String? _error;
  String? _resolvedArtistId;
  String _resolvedArtistName = '';
  KugouArtistDetail? _detail;
  List<String> _photoUrls = const [];
  List<Song> _hotSongs = const [];
  bool _isFollowing = false;
  bool _followSubmitting = false;
  bool _bioExpanded = false;

  _ArtistDrawerTab _tab = _ArtistDrawerTab.hotSongs;
  bool _albumsLoading = false;
  bool _albumsLoaded = false;
  List<KugouAlbumBrief> _albums = const [];

  @override
  void initState() {
    super.initState();
    _initArtistSelection(notify: false);
  }

  @override
  void didUpdateWidget(covariant _YtArtistDrawerContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id ||
        oldWidget.song.artist != widget.song.artist ||
        oldWidget.initialArtistName != widget.initialArtistName) {
      _initArtistSelection();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _initArtistSelection({bool notify = true}) {
    final split = splitSongArtistNames(widget.song.artist);
    final wantRaw = widget.initialArtistName?.trim();
    if (wantRaw != null &&
        wantRaw.isNotEmpty &&
        !split.any((a) => a.toLowerCase() == wantRaw.toLowerCase())) {
      _artistNames = <String>[wantRaw, ...split];
    } else {
      _artistNames = split.isNotEmpty
          ? split
          : (isUnknownArtist(widget.song.artist)
                ? const <String>[]
                : <String>[widget.song.artist.trim()]);
    }
    int targetIdx = 0;
    final want = wantRaw?.toLowerCase();
    if (want != null && want.isNotEmpty && _artistNames.isNotEmpty) {
      final found = _artistNames.indexWhere((a) => a.toLowerCase() == want);
      if (found >= 0) targetIdx = found;
    }
    _selectedArtistIndex = targetIdx;
    _loadCurrentArtist(notify: notify);
  }

  Future<void> _loadCurrentArtist({bool notify = true}) async {
    final token = ++_requestToken;
    if (_artistNames.isEmpty) {
      void applyEmpty() {
        _loading = false;
        _error = '当前歌曲暂无歌手信息';
        _resolvedArtistId = null;
        _resolvedArtistName = '';
        _detail = null;
        _photoUrls = const [];
        _hotSongs = const [];
        _albums = const [];
        _albumsLoaded = false;
      }
      if (notify) {
        setState(applyEmpty);
      } else {
        applyEmpty();
      }
      return;
    }

    final artistName = _artistNames[_selectedArtistIndex];
    void applyReset() {
      _loading = true;
      _error = null;
      _resolvedArtistName = artistName;
      _detail = null;
      _photoUrls = const [];
      _hotSongs = const [];
      _albums = const [];
      _albumsLoaded = false;
      _albumsLoading = false;
      _tab = _ArtistDrawerTab.hotSongs;
      _bioExpanded = false;
    }
    if (notify) {
      setState(applyReset);
    } else {
      applyReset();
    }

    try {
      final api = KugouApiClient();
      final primarySongArtist = splitSongArtistNames(widget.song.artist);
      final isSongPrimaryArtist =
          primarySongArtist.isNotEmpty &&
          primarySongArtist.first.toLowerCase() == artistName.toLowerCase();
      String? artistId =
          (isSongPrimaryArtist &&
              widget.song.artistId != null &&
              widget.song.artistId!.isNotEmpty)
          ? widget.song.artistId
          : null;
      String? fallbackAvatar;

      if (artistId == null || artistId.isEmpty) {
        final hits = await api.searchArtists(artistName, pagesize: 5);
        if (!mounted || token != _requestToken) return;
        if (hits != null && hits.isNotEmpty) {
          KugouArtistBrief picked = hits.first;
          final lowerTarget = artistName.toLowerCase();
          for (final h in hits) {
            if (h.name.trim().toLowerCase() == lowerTarget) {
              picked = h;
              break;
            }
          }
          artistId = picked.id;
          fallbackAvatar = picked.avatarUrl;
        }
      }

      if (artistId == null || artistId.isEmpty) {
        setState(() {
          _loading = false;
          _error = '未找到歌手「$artistName」的资料';
        });
        return;
      }

      _resolvedArtistId = artistId;

      final results = await Future.wait([
        api.getArtistDetail(artistId).catchError((_) => null),
        api
            .getArtistAudios(artistId, page: 1, pagesize: 30, sort: 'hot')
            .catchError((_) => null),
        api
            .getArtistAlbums(artistId, page: 1, pagesize: 30, sort: 'hot')
            .catchError((_) => null),
      ]);
      if (!mounted || token != _requestToken) return;

      final detail = results[0] as KugouArtistDetail?;
      final audios = results[1] as KugouArtistAudios?;
      final albumsRes = results[2] as KugouArtistAlbums?;
      final hotSongs = (audios?.songs ?? const <KugouSongDetail>[])
          .map((e) => e.toSong().copyWith(artistId: e.artistId ?? artistId))
          .toList();
      final albums = albumsRes?.albums ?? const <KugouAlbumBrief>[];

      // 如接口缺头像则保留搜索头像
      final effectiveAvatar = YtMoreMenu.upgradeArtworkUri(
        (detail?.avatarUrl != null && detail!.avatarUrl!.isNotEmpty)
            ? detail.avatarUrl
            : fallbackAvatar,
      );

      final updatedDetail = detail ??
          KugouArtistDetail(
            id: artistId,
            name: artistName,
            avatarUrl: effectiveAvatar,
          );

      setState(() {
        _detail = KugouArtistDetail(
          id: updatedDetail.id.isNotEmpty ? updatedDetail.id : artistId!,
          name: updatedDetail.name.isNotEmpty ? updatedDetail.name : artistName,
          avatarUrl: effectiveAvatar,
          description: updatedDetail.description,
          songCount: updatedDetail.songCount,
          albumCount: updatedDetail.albumCount > 0
              ? updatedDetail.albumCount
              : albums.length,
          isFollowed: updatedDetail.isFollowed,
          hasFollowStatus: updatedDetail.hasFollowStatus,
        );
        if (updatedDetail.hasFollowStatus) {
          _isFollowing = updatedDetail.isFollowed;
        } else {
          _isFollowing = false;
        }
        _hotSongs = hotSongs;
        _albums = albums;
        _albumsLoaded = true;
        _loading = false;
      });

      // 异步拉取歌手写真作为 Hero 背景图（不阻塞首包信息与热歌列表渲染）
      final soloPick = pickArtistPhotoHash(
        hotSongs,
        artistId: artistId,
        artistName: artistName,
      );
      final photoHash =
          soloPick.hash ??
          (_artistNames.length == 1 && widget.song.isOnline
              ? widget.song.id
              : null);
      if (photoHash != null && photoHash.isNotEmpty) {
        final photos = await ArtistPhotoService.instance.load(
          hash: photoHash,
          count: 10,
          artistId: artistId,
          artistName: artistName,
        );
        if (!mounted || token != _requestToken) return;
        if (photos.isNotEmpty) {
          setState(() {
            _photoUrls = photos;
          });
        }
      }
    } catch (_) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _loading = false;
        _error = '加载歌手信息失败，请稍后重试';
      });
    }
  }

  Future<void> _loadAlbumsIfNeeded() async {
    final artistId = _resolvedArtistId;
    if (artistId == null ||
        artistId.isEmpty ||
        _albumsLoaded ||
        _albumsLoading) {
      return;
    }
    final token = _requestToken;
    setState(() => _albumsLoading = true);
    try {
      final res = await KugouApiClient().getArtistAlbums(
        artistId,
        page: 1,
        pagesize: 30,
        sort: 'hot',
      );
      if (!mounted || token != _requestToken) return;
      setState(() {
        _albums = res?.albums ?? const <KugouAlbumBrief>[];
        _albumsLoaded = true;
        _albumsLoading = false;
      });
    } catch (_) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _albumsLoaded = true;
        _albumsLoading = false;
      });
    }
  }

  Future<void> _toggleFollow() async {
    final artistId = _resolvedArtistId;
    if (artistId == null || artistId.isEmpty || _followSubmitting) return;
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      showToast('请先登录酷狗账号');
      return;
    }
    AppHaptics.lightImpact(HapticCategory.control);
    final prev = _isFollowing;
    setState(() {
      _followSubmitting = true;
      _isFollowing = !prev;
    });
    try {
      final resp = prev
          ? await api.unfollowArtist(artistId)
          : await api.followArtist(artistId);
      if (!mounted) return;
      final status = resp?['status'];
      final errCode = resp?['error_code'];
      final failed =
          resp == null ||
          (status != null && status != 1) ||
          (errCode != null && errCode != 0);
      if (failed) {
        setState(() => _isFollowing = prev);
        showToast(
          resp?['msg']?.toString() ?? resp?['message']?.toString() ?? '操作失败',
        );
      } else {
        showToast(prev ? '已取消关注' : '已关注歌手');
      }
    } catch (_) {
      if (mounted) setState(() => _isFollowing = prev);
      showToast('操作失败，请检查网络');
    } finally {
      if (mounted) setState(() => _followSubmitting = false);
    }
  }

  void _pushFullArtistPage() {
    final artistId = _resolvedArtistId;
    if (artistId == null || artistId.isEmpty) return;
    final push = widget.onPushPage ?? Navigator.of(context).push;
    push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailPage(
          artistId: artistId,
          artistName: _resolvedArtistName,
          avatarUrl: _detail?.avatarUrl,
          initialIsFollowed: _isFollowing,
        ),
      ),
    );
  }

  void _openAlbum(KugouAlbumBrief albumBrief) {
    final push = widget.onPushPage ?? Navigator.of(context).push;
    push(
      MaterialPageRoute(
        builder: (_) => AlbumDetailPage(album: albumBrief.toAlbum()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentSongId = context.select<PlayerProvider, String?>(
      (p) => p.currentSong?.id,
    );

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0A0A0A).withValues(alpha: 0.72),
          border: Border(
            top: BorderSide(
              color: Colors.white.withValues(alpha: 0.10),
              width: 0.6,
            ),
          ),
        ),
        child: Column(
          children: [
            _buildTopBar(),
            if (_artistNames.length > 1) _buildArtistSwitcherChips(),
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
                child: _buildBody(currentSongId),
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
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
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
                        '歌手档案',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 11.5,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        _resolvedArtistName.isNotEmpty
                            ? _resolvedArtistName
                            : widget.song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_resolvedArtistId != null && _resolvedArtistId!.isNotEmpty)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      minimumSize: const Size(0, 34),
                    ),
                    onPressed: _pushFullArtistPage,
                    icon: const Icon(Icons.open_in_new_rounded, size: 15),
                    label: const Text(
                      '完整主页',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArtistSwitcherChips() {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _artistNames.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final selected = index == _selectedArtistIndex;
          return GestureDetector(
            onTap: () {
              if (index == _selectedArtistIndex) return;
              AppHaptics.lightImpact(HapticCategory.control);
              setState(() => _selectedArtistIndex = index);
              _loadCurrentArtist();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withValues(alpha: 0.24)
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.45)
                      : Colors.white.withValues(alpha: 0.10),
                  width: 0.8,
                ),
              ),
              child: Center(
                child: Text(
                  _artistNames[index],
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white70,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(String? currentSongId) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 2),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.person_off_outlined,
                color: Colors.white38,
                size: 42,
              ),
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white30),
                ),
                onPressed: _loadCurrentArtist,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return CustomScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverToBoxAdapter(child: _buildHeroCard()),
        if (_detail?.description != null &&
            _detail!.description!.trim().isNotEmpty)
          SliverToBoxAdapter(child: _buildBioCard(_detail!.description!.trim())),
        SliverToBoxAdapter(child: _buildTabRow()),
        if (_tab == _ArtistDrawerTab.hotSongs)
          ..._buildHotSongsSlivers(currentSongId)
        else
          ..._buildAlbumsSlivers(),
        SliverToBoxAdapter(
          child: SizedBox(height: widget.safeBottom + 24),
        ),
      ],
    );
  }

  Widget _buildHeroCard() {
    final bgImage = _photoUrls.isNotEmpty
        ? _photoUrls.first
        : _detail?.avatarUrl;
    final avatar =
        _detail?.avatarUrl ?? (_photoUrls.isNotEmpty ? _photoUrls.first : null);
    final stats = <String>[
      if ((_detail?.songCount ?? 0) > 0) '${_detail!.songCount} 首单曲',
      if ((_detail?.albumCount ?? 0) > 0) '${_detail!.albumCount} 张专辑',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 204,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 0.7,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (bgImage != null && bgImage.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: bgImage,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  fadeInDuration: const Duration(milliseconds: 280),
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.42, 1.0],
                    colors: [
                      Colors.black.withValues(alpha: 0.14),
                      Colors.black.withValues(alpha: 0.45),
                      Colors.black.withValues(alpha: 0.88),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 14,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    ClipOval(
                      child: Container(
                        width: 62,
                        height: 62,
                        color: Colors.white12,
                        child: (avatar != null && avatar.isNotEmpty)
                            ? CachedNetworkImage(
                                imageUrl: avatar,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => const Icon(
                                  Icons.person_rounded,
                                  color: Colors.white54,
                                  size: 30,
                                ),
                              )
                            : const Icon(
                                Icons.person_rounded,
                                color: Colors.white54,
                                size: 30,
                              ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _detail?.name.isNotEmpty == true
                                ? _detail!.name
                                : _resolvedArtistName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          ),
                          if (stats.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              stats.join(' · '),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    InkWell(
                      onTap: _toggleFollow,
                      borderRadius: BorderRadius.circular(20),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: _isFollowing
                              ? Colors.white.withValues(alpha: 0.16)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: _isFollowing
                                ? Colors.white.withValues(alpha: 0.35)
                                : Colors.white,
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _isFollowing
                                  ? Icons.check_rounded
                                  : Icons.add_rounded,
                              size: 16,
                              color: _isFollowing ? Colors.white : Colors.black,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _isFollowing ? '已关注' : '关注',
                              style: TextStyle(
                                color: _isFollowing
                                    ? Colors.white
                                    : Colors.black,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
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
        ),
      ),
    );
  }

  Widget _buildBioCard(String bio) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _bioExpanded = !_bioExpanded),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
              width: 0.6,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '歌手简介',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _bioExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: Colors.white54,
                    size: 18,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                bio,
                maxLines: _bioExpanded ? null : 3,
                overflow: _bioExpanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12.8,
                  height: 1.48,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Row(
        children: [
          _buildTabPill(
            label:
                '热门歌曲${_hotSongs.isNotEmpty ? ' · ${_hotSongs.length}' : ''}',
            selected: _tab == _ArtistDrawerTab.hotSongs,
            onTap: () {
              if (_tab != _ArtistDrawerTab.hotSongs) {
                setState(() => _tab = _ArtistDrawerTab.hotSongs);
              }
            },
          ),
          const SizedBox(width: 8),
          _buildTabPill(
            label:
                '专辑${_albumsLoaded && _albums.isNotEmpty ? ' · ${_albums.length}' : ''}',
            selected: _tab == _ArtistDrawerTab.albums,
            onTap: () {
              if (_tab != _ArtistDrawerTab.albums) {
                setState(() => _tab = _ArtistDrawerTab.albums);
                _loadAlbumsIfNeeded();
              }
            },
          ),
          const Spacer(),
          if (_tab == _ArtistDrawerTab.hotSongs && _hotSongs.isNotEmpty)
            InkWell(
              onTap: () {
                AppHaptics.click(HapticCategory.transport);
                context.read<PlayerProvider>().playOnlinePlaylist(_hotSongs, 0);
              },
              borderRadius: BorderRadius.circular(18),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 17,
                    ),
                    SizedBox(width: 4),
                    Text(
                      '播放全部',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
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

  Widget _buildTabPill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? Colors.white.withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? Colors.white.withValues(alpha: 0.36)
                : Colors.white.withValues(alpha: 0.08),
            width: 0.7,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white60,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildHotSongsSlivers(String? currentSongId) {
    if (_hotSongs.isEmpty && _albums.isEmpty) {
      return [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 42),
            child: Center(
              child: Text(
                '暂无热门歌曲',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ),
          ),
        ),
      ];
    }

    return [
      if (_hotSongs.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 18,
              crossAxisSpacing: 14,
              childAspectRatio: 0.74,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final song = _hotSongs[index];
                final playing =
                    currentSongId != null &&
                    currentSongId.toLowerCase() == song.id.toLowerCase();
                return _buildSquareSongTile(
                  song: song,
                  index: index,
                  playing: playing,
                );
              },
              childCount: _hotSongs.length,
            ),
          ),
        ),
      if (_albums.isNotEmpty)
        SliverToBoxAdapter(child: _buildSquareAlbumCarouselSection()),
    ];
  }

  /// 1:1 复刻「专辑」双列大正方形网格卡片的「热门歌曲」方形卡片
  Widget _buildSquareSongTile({
    required Song song,
    required int index,
    required bool playing,
  }) {
    final cover = YtMoreMenu.upgradeArtworkUri(song.artworkUri);
    final subtitleParts = <String>[
      '单曲',
      if (!isUnknownAlbum(song.album) && song.album != song.displayName)
        song.album
      else if (!isUnknownArtist(song.artist))
        song.artist,
    ];

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        AppHaptics.click(HapticCategory.transport);
        context.read<PlayerProvider>().playOnlinePlaylist(_hotSongs, index);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1.0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: Colors.white.withValues(alpha: 0.08),
                    child: (cover != null && cover.isNotEmpty)
                        ? CachedNetworkImage(
                            imageUrl: cover,
                            memCacheWidth: 420,
                            memCacheHeight: 420,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => const Center(
                              child: Icon(
                                Icons.music_note_rounded,
                                color: Colors.white38,
                                size: 38,
                              ),
                            ),
                          )
                        : const Center(
                            child: Icon(
                              Icons.music_note_rounded,
                              color: Colors.white38,
                              size: 38,
                            ),
                          ),
                  ),
                  if (playing)
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.34),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.65),
                            width: 1.6,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.graphic_eq_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        AppHaptics.lightImpact(HapticCategory.control);
                        context.read<PlayerProvider>().insertAfterCurrent([
                          song,
                        ]);
                        showToast('已加入下一首播放');
                      },
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.56),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.18),
                            width: 0.6,
                          ),
                        ),
                        child: const Icon(
                          Icons.playlist_play_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            song.displayName,
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
    );
  }

  /// YT Music 风格「专辑」大号正方形横向画廊（1:1 复刻图 3 效果）
  Widget _buildSquareAlbumCarouselSection() {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '专辑',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                InkWell(
                  onTap: () {
                    AppHaptics.lightImpact(HapticCategory.control);
                    setState(() => _tab = _ArtistDrawerTab.albums);
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '全部 ${_albums.length} 张',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: Colors.white60,
                          size: 18,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 214,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _albums.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final albumBrief = _albums[index];
                return SizedBox(
                  width: 156,
                  child: _buildSquareAlbumTile(albumBrief),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildAlbumsSlivers() {
    if (_albumsLoading) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 42),
            child: Center(
              child: CircularProgressIndicator(
                color: Colors.white70,
                strokeWidth: 2,
              ),
            ),
          ),
        ),
      ];
    }
    if (_albums.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 42),
            child: Center(
              child: Text(
                '暂无专辑',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ),
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 18,
            crossAxisSpacing: 14,
            childAspectRatio: 0.74,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildSquareAlbumTile(_albums[index]),
            childCount: _albums.length,
          ),
        ),
      ),
    ];
  }

  Widget _buildSquareAlbumTile(KugouAlbumBrief albumBrief) {
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
        _openAlbum(albumBrief);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1.0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
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
    );
  }
}
