import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../../core/services/equalizer_service.dart';
import '../../../core/services/viper_master_service.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/song.dart';
import '../../../services/kugou_api/kugou_api_client.dart';
import '../../../widgets/add_to_playlist_dialog.dart';
import '../../../widgets/player_artwork_image.dart';
import '../../../widgets/smart_artwork_image.dart';
import '../../settings/equalizer_settings_page.dart';
import '../../sheet/song_sheet_sheet.dart';
import '../../sound/sounds_page.dart' show KugouSoundItem, SoundsPage;
import 'yt_lyrics_drawer.dart';

/// YT 播放页内嵌操作抽屉类型：保存歌单 / 曲谱 / 蝰蛇音效
enum YtActionDrawerType { save, sheet, sound }

/// 1:1 复刻歌词与评论抽屉展开动画的全屏内嵌「保存 / 曲谱 / 音效」抽屉
/// （共用顶部 MiniBar + 悬浮封面飞行缩放 + 顶部下拉关闭手势）
class YtActionDrawer extends StatefulWidget {
  final Animation<double> expansion;
  final YtActionDrawerType type;
  final Song song;
  final bool isVideoMode;
  final VideoPlayerController? videoController;
  final VoidCallback onClose;
  final void Function(Route<dynamic>)? onPushPage;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const YtActionDrawer({
    super.key,
    required this.expansion,
    required this.type,
    required this.song,
    this.isVideoMode = false,
    this.videoController,
    required this.onClose,
    this.onPushPage,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  State<YtActionDrawer> createState() => _YtActionDrawerState();
}

class _YtActionDrawerState extends State<YtActionDrawer> {
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
  void didUpdateWidget(covariant YtActionDrawer oldWidget) {
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
            '${widget.type.name}_${widget.song.id}_${widget.song.albumAudioId}_${safeBottom.toStringAsFixed(1)}';
        if (_cachedSheet == null || _cachedSheetKey != sheetKey) {
          _cachedSheetKey = sheetKey;
          _cachedSheet = RepaintBoundary(
            child: _buildBodyByType(safeBottom),
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

  Widget _buildBodyByType(double safeBottom) {
    return switch (widget.type) {
      YtActionDrawerType.save => _YtSaveToPlaylistContent(
        song: widget.song,
        safeBottom: safeBottom,
        onClose: widget.onClose,
        onVerticalDragUpdate: widget.onVerticalDragUpdate,
        onVerticalDragEnd: widget.onVerticalDragEnd,
      ),
      YtActionDrawerType.sheet => _YtSongSheetContent(
        song: widget.song,
        safeBottom: safeBottom,
        onClose: widget.onClose,
        onVerticalDragUpdate: widget.onVerticalDragUpdate,
        onVerticalDragEnd: widget.onVerticalDragEnd,
      ),
      YtActionDrawerType.sound => _YtSoundEffectsContent(
        safeBottom: safeBottom,
        onClose: widget.onClose,
        onPushPage: widget.onPushPage,
        onVerticalDragUpdate: widget.onVerticalDragUpdate,
        onVerticalDragEnd: widget.onVerticalDragEnd,
      ),
    };
  }
}

// ============================================================================
// 1. 「保存到歌单」内嵌抽屉内容
// ============================================================================

class _YtSaveToPlaylistContent extends StatefulWidget {
  final Song song;
  final double safeBottom;
  final VoidCallback onClose;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const _YtSaveToPlaylistContent({
    required this.song,
    required this.safeBottom,
    required this.onClose,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  State<_YtSaveToPlaylistContent> createState() =>
      _YtSaveToPlaylistContentState();
}

class _YtSaveToPlaylistContentState extends State<_YtSaveToPlaylistContent> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _filterController = TextEditingController();
  double? _pointerStartY;
  bool _capturingPullDown = false;
  double _lastStepDy = 0.0;

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _playlists = const [];
  String _filterKeyword = '';
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _loadPlaylists(notify: false);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _loadPlaylists({bool notify = true}) async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      void setUnauth() {
        _loading = false;
        _error = '请先登录酷狗账号后再保存到云歌单';
        _playlists = const [];
      }

      if (notify && mounted) {
        setState(setUnauth);
      } else {
        setUnauth();
      }
      return;
    }

    if (notify && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      _loading = true;
      _error = null;
    }

    try {
      final list = await loadUserPlaylistsSorted(api);
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (list == null) {
          _error = '加载歌单失败，请稍后重试';
          _playlists = const [];
        } else {
          _playlists = list;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载歌单失败，请稍后重试';
      });
    }
  }

  Future<void> _promptCreatePlaylist() async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      showToast('请先登录', long: true);
      return;
    }
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          '新建歌单',
          style: TextStyle(color: Colors.white, fontSize: 17),
        ),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: '输入歌单名称',
            hintStyle: const TextStyle(color: Colors.white38),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.08),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.white60)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('创建并添加'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _creating = true);
    try {
      final res = await api.createPlaylist(name);
      if (!mounted) return;
      setState(() => _creating = false);
      if (res != null && (res['status'] == 1 || res['data'] != null)) {
        await _loadPlaylists();
        if (!mounted) return;
        final created = _playlists.cast<Map<String, dynamic>?>().firstWhere(
          (p) => (p?['name']?.toString() ?? '') == name,
          orElse: () => null,
        );
        if (created != null) {
          unawaited(addSongToPlaylist(widget.song, created));
          widget.onClose();
        } else {
          showToast('已创建歌单「$name」');
        }
      } else {
        showToast('创建歌单失败');
      }
    } catch (_) {
      if (mounted) setState(() => _creating = false);
      showToast('创建歌单失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final kw = _filterKeyword.trim().toLowerCase();
    final filtered = kw.isEmpty
        ? _playlists
        : _playlists.where((p) {
            final name = (p['name'] ?? p['specialname'] ?? '')
                .toString()
                .toLowerCase();
            return name.contains(kw);
          }).toList();

    return _YtDrawerShellContainer(
      child: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: widget.onVerticalDragUpdate,
            onVerticalDragEnd: widget.onVerticalDragEnd,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 10),
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
                      const Icon(
                        Icons.playlist_add_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '保存到歌单',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _creating ? null : _promptCreatePlaylist,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: Colors.white.withValues(alpha: 0.12),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text(
                          '新建歌单',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '关闭',
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: Colors.white70,
                          size: 26,
                        ),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 当前待保存歌曲信息条
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                        width: 0.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            width: 38,
                            height: 38,
                            child: PlayerArtworkImage(
                              artworkUri: widget.song.artworkUri,
                              fallbackFilePath: widget.song.localPath,
                              isFill: true,
                              fit: BoxFit.cover,
                              iconSize: 18,
                              backgroundColor: Colors.white12,
                              iconColor: Colors.white54,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.song.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                widget.song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_playlists.length > 4) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 38,
                      child: TextField(
                        controller: _filterController,
                        onChanged: (v) => setState(() => _filterKeyword = v),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                        ),
                        decoration: InputDecoration(
                          hintText: '搜索我的歌单…',
                          hintStyle: const TextStyle(
                            color: Colors.white38,
                            fontSize: 13,
                          ),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            color: Colors.white54,
                            size: 18,
                          ),
                          suffixIcon: _filterKeyword.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(
                                    Icons.clear_rounded,
                                    color: Colors.white54,
                                    size: 16,
                                  ),
                                  onPressed: () {
                                    _filterController.clear();
                                    setState(() => _filterKeyword = '');
                                  },
                                )
                              : null,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.08),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(19),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
          Expanded(
            child: _PullDownDragForwarder(
              scrollController: _scrollController,
              onVerticalDragUpdate: widget.onVerticalDragUpdate,
              onVerticalDragEnd: widget.onVerticalDragEnd,
              pointerStartY: _pointerStartY,
              capturingPullDown: _capturingPullDown,
              lastStepDy: _lastStepDy,
              onStateUpdate: (startY, capturing, stepDy) {
                _pointerStartY = startY;
                _capturingPullDown = capturing;
                _lastStepDy = stepDy;
              },
              child: _buildPlaylistList(filtered),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistList(List<Map<String, dynamic>> playlists) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
          color: Colors.white70,
          strokeWidth: 2.5,
        ),
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
                Icons.cloud_off_rounded,
                color: Colors.white38,
                size: 40,
              ),
              const SizedBox(height: 10),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _loadPlaylists,
                icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                label: const Text('重试', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      );
    }
    if (playlists.isEmpty) {
      return ListView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        children: [
          const SizedBox(height: 80),
          Center(
            child: Text(
              _filterKeyword.isNotEmpty ? '没有匹配的歌单' : '暂无自建歌单，点击右上角「新建歌单」创建',
              style: const TextStyle(color: Colors.white60, fontSize: 14),
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(14, 10, 14, widget.safeBottom + 24),
      itemCount: playlists.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final playlist = playlists[index];
        final name = (playlist['name'] ?? playlist['specialname'] ?? '未知歌单')
            .toString();
        final songCount =
            playlist['songCount'] ??
            playlist['songcount'] ??
            playlist['song_count'] ??
            playlist['count'] ??
            0;
        final coverUrl = playlist['coverUrl']?.toString();

        return Material(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              AppHaptics.lightImpact(HapticCategory.control);
              unawaited(addSongToPlaylist(widget.song, playlist));
              widget.onClose();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  SmartArtworkImage(
                    artworkUri: coverUrl,
                    size: 50,
                    borderRadius: 8,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '$songCount 首歌曲',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.10),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.add_rounded,
                      color: Colors.white,
                      size: 20,
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

// ============================================================================
// 2. 「曲谱」内嵌抽屉内容（复用 SongSheetView + YT 深色主题与顶部下拉收起手势）
// ============================================================================

class _YtSongSheetContent extends StatefulWidget {
  final Song song;
  final double safeBottom;
  final VoidCallback onClose;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const _YtSongSheetContent({
    required this.song,
    required this.safeBottom,
    required this.onClose,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  State<_YtSongSheetContent> createState() => _YtSongSheetContentState();
}

class _YtSongSheetContentState extends State<_YtSongSheetContent> {
  final ScrollController _scrollController = ScrollController();
  double? _pointerStartY;
  bool _capturingPullDown = false;
  double _lastStepDy = 0.0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final darkScheme = ColorScheme.fromSeed(
      seedColor: Colors.white,
      brightness: Brightness.dark,
      surface: const Color(0xFF121212),
      onSurface: Colors.white,
      onSurfaceVariant: Colors.white70,
      outline: Colors.white24,
      outlineVariant: Colors.white12,
      secondaryContainer: Colors.white.withValues(alpha: 0.20),
      onSecondaryContainer: Colors.white,
      surfaceContainerHighest: Colors.white.withValues(alpha: 0.10),
      surfaceContainerLow: const Color(0xFF181818),
    );

    return _YtDrawerShellContainer(
      child: Theme(
        data: baseTheme.copyWith(
          brightness: Brightness.dark,
          colorScheme: darkScheme,
          dividerColor: Colors.white12,
        ),
        child: Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: widget.onVerticalDragUpdate,
              onVerticalDragEnd: widget.onVerticalDragEnd,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
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
                        const Icon(
                          Icons.library_music_outlined,
                          color: Colors.white,
                          size: 21,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                '曲谱',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                '${widget.song.displayName} · ${widget.song.artist}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '关闭',
                          icon: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: Colors.white70,
                            size: 26,
                          ),
                          onPressed: widget.onClose,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
            Expanded(
              child: _PullDownDragForwarder(
                scrollController: _scrollController,
                onVerticalDragUpdate: widget.onVerticalDragUpdate,
                onVerticalDragEnd: widget.onVerticalDragEnd,
                pointerStartY: _pointerStartY,
                capturingPullDown: _capturingPullDown,
                lastStepDy: _lastStepDy,
                onStateUpdate: (startY, capturing, stepDy) {
                  _pointerStartY = startY;
                  _capturingPullDown = capturing;
                  _lastStepDy = stepDy;
                },
                child: Padding(
                  padding: EdgeInsets.only(bottom: widget.safeBottom),
                  child: SongSheetView(
                    key: ValueKey(
                      'yt_sheet_${widget.song.id}_${widget.song.albumAudioId}',
                    ),
                    song: widget.song,
                    scrollController: _scrollController,
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

// ============================================================================
// 3. 「音效」内嵌抽屉内容（零上游修改，完整支持社区/明星/耳机品牌音效与搜索应用）
// ============================================================================

enum _YtSoundCatalog { community, artist, earphone }

class _YtEffectBrand {
  final int id;
  final String name;
  final String? logo;

  const _YtEffectBrand({required this.id, required this.name, this.logo});
}

const List<String> _kYtSoundTagOrder = [
  '重低音',
  '设备模拟',
  '环绕',
  '人声',
  '趣味',
  '其他',
];

class _YtSoundEffectsContent extends StatefulWidget {
  final double safeBottom;
  final VoidCallback onClose;
  final void Function(Route<dynamic>)? onPushPage;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const _YtSoundEffectsContent({
    required this.safeBottom,
    required this.onClose,
    this.onPushPage,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  State<_YtSoundEffectsContent> createState() => _YtSoundEffectsContentState();
}

class _YtSoundEffectsContentState extends State<_YtSoundEffectsContent> {
  final KugouApiClient _api = KugouApiClient();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  double? _pointerStartY;
  bool _capturingPullDown = false;
  double _lastStepDy = 0.0;

  static const int _sort = 3; // 最热排序
  int? _classify; // null=全部, 2=官方, 3=社区
  String? _tag;
  _YtSoundCatalog _catalog = _YtSoundCatalog.community;
  List<_YtEffectBrand> _brands = const [];
  int? _selectedBrandId;

  List<KugouSoundItem> _items = const [];
  int _page = 1;
  bool _hasMore = true;
  bool _loading = true;
  bool _loadingMore = false;

  bool _searchMode = false;
  bool _searching = false;
  String _searchKeyword = '';
  List<KugouSoundItem> _searchResults = const [];

  int? _appliedId;
  String? _appliedName;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadLocalState();
    _refresh(notify: false);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadLocalState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final appliedId = prefs.getInt('sound_applied_id');
      final appliedName = prefs.getString('sound_applied_name');
      if (!mounted) return;
      setState(() {
        _appliedId = appliedId;
        _appliedName = appliedName;
      });
    } catch (_) {}
  }

  void _onScroll() {
    if (_searchMode || !_hasMore || _loadingMore || _loading) return;
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  String get _catalogLabel => switch (_catalog) {
    _YtSoundCatalog.community => '社区',
    _YtSoundCatalog.artist => '明星',
    _YtSoundCatalog.earphone => '耳机',
  };

  List<KugouSoundItem> _parseItems(Map<String, dynamic>? resp) {
    if (resp == null || resp['status'] != 1) return const [];
    final data = resp['data'];
    if (data is! List) return const [];
    return _parseList(data);
  }

  List<KugouSoundItem> _parseList(List<dynamic> data, {String? source}) {
    final out = <KugouSoundItem>[];
    for (final e in data) {
      final item = KugouSoundItem.fromJson(e, source: source ?? _catalogLabel);
      if (item != null && item.id > 0 && item.available && item.isFree) {
        out.add(item);
      }
    }
    return out;
  }

  List<_YtEffectBrand> _parseBrands(Map<String, dynamic>? resp) {
    final data = resp?['data'];
    final values = <dynamic>[];
    if (data is Map) {
      final hot = data['hot_list'];
      if (hot is List) values.addAll(hot);
      for (final entry in data.entries) {
        if (entry.key != 'hot_list' && entry.value is List) {
          values.addAll(entry.value as List);
        }
      }
    } else if (data is List) {
      values.addAll(data);
    }
    final seen = <int>{};
    final result = <_YtEffectBrand>[];
    for (final raw in values) {
      if (raw is! Map) continue;
      final id = int.tryParse('${raw['brand_id'] ?? raw['id'] ?? ''}') ?? 0;
      final name = '${raw['brand'] ?? raw['brand_name'] ?? raw['name'] ?? ''}';
      if (id > 0 && name.isNotEmpty && seen.add(id)) {
        result.add(
          _YtEffectBrand(
            id: id,
            name: name,
            logo: '${raw['logo'] ?? ''}'.trim().isEmpty
                ? null
                : '${raw['logo']}',
          ),
        );
      }
    }
    return result;
  }

  List<KugouSoundItem> _parseNestedBrandItems(
    Map<String, dynamic>? resp, {
    required String source,
  }) {
    final data = resp?['data'];
    if (data is! Map || data['list'] is! List) return const [];
    return _parseList(data['list'] as List<dynamic>, source: source);
  }

  List<KugouSoundItem> _parseMatchedItems(Map<String, dynamic>? resp) {
    final common = resp?['data'];
    if (common is! Map) return const [];
    final out = <KugouSoundItem>[];
    for (final key in ['common', 'earphone', 'brand']) {
      final item = common[key];
      final parsed = KugouSoundItem.fromJson(item, source: '耳机');
      if (parsed != null &&
          parsed.id > 0 &&
          parsed.available &&
          parsed.isFree) {
        out.add(parsed);
      }
    }
    return out;
  }

  Future<void> _refresh({bool notify = true}) async {
    if (notify && mounted) {
      setState(() {
        _loading = true;
        _page = 1;
        _hasMore = true;
        _selectedBrandId = null;
      });
    } else {
      _loading = true;
      _page = 1;
      _hasMore = true;
      _selectedBrandId = null;
    }

    List<KugouSoundItem> list = const [];
    List<_YtEffectBrand> brands = const [];
    bool hasMore = true;
    try {
      if (_catalog == _YtSoundCatalog.community) {
        list = _parseItems(
          await _api.getSoundModel(sort: _sort, page: 1, pagesize: 30),
        );
      } else if (_catalog == _YtSoundCatalog.artist) {
        list = _parseItems(await _api.getArtistEffects(page: 1, pagesize: 30));
      } else if (_catalog == _YtSoundCatalog.earphone) {
        final responses = await Future.wait([
          _api.getEffectBrands(pagesize: 100),
          _api.getEffectMatch(),
        ]);
        brands = _parseBrands(responses[0]);
        final matched = _parseMatchedItems(responses[1]);
        List<KugouSoundItem> firstBrandItems = const [];
        if (brands.isNotEmpty) {
          final firstResp = await _api.getEffectBrandDetail(
            brandId: brands.first.id,
            page: 1,
            pagesize: 40,
          );
          firstBrandItems = _parseNestedBrandItems(firstResp, source: '耳机');
        }
        final seen = <int>{};
        list = [
          ...matched,
          ...firstBrandItems,
        ].where((e) => seen.add(e.id)).toList();
        hasMore = false;
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _items = list;
      _brands = brands;
      _loading = false;
      _hasMore = hasMore && list.length >= 30;
    });
  }

  Future<void> _switchCatalog(_YtSoundCatalog catalog) async {
    if (_catalog == catalog) return;
    setState(() {
      _catalog = catalog;
      _classify = null;
      _tag = null;
      _items = const [];
      _brands = const [];
      _selectedBrandId = null;
    });
    await _refresh();
  }

  Future<void> _selectBrand(int? brandId) async {
    setState(() {
      _selectedBrandId = brandId;
      _loading = true;
      _page = 1;
      _hasMore = true;
    });
    List<KugouSoundItem> list = const [];
    try {
      if (brandId == null) {
        final matched = await _api.getEffectMatch();
        list = _parseMatchedItems(matched);
      } else {
        final resp = await _api.getEffectBrandDetail(
          brandId: brandId,
          page: 1,
          pagesize: 30,
        );
        list = _parseNestedBrandItems(resp, source: '耳机');
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
      _hasMore = brandId != null && list.length >= 30;
    });
  }

  Future<void> _loadMore() async {
    if (_catalog == _YtSoundCatalog.earphone && _selectedBrandId == null) {
      return;
    }
    setState(() => _loadingMore = true);
    final next = _page + 1;
    try {
      final resp = switch (_catalog) {
        _YtSoundCatalog.community => await _api.getSoundModel(
          sort: _sort,
          page: next,
          pagesize: 30,
        ),
        _YtSoundCatalog.artist => await _api.getArtistEffects(
          page: next,
          pagesize: 30,
        ),
        _YtSoundCatalog.earphone => await _api.getEffectBrandDetail(
          brandId: _selectedBrandId!,
          page: next,
          pagesize: 30,
        ),
      };
      final list = _catalog == _YtSoundCatalog.earphone
          ? _parseNestedBrandItems(resp, source: '耳机')
          : _parseItems(resp);
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        if (list.isEmpty) {
          _hasMore = false;
        } else {
          _page = next;
          final known = _items.map((e) => e.id).toSet();
          _items = [..._items, ...list.where((e) => !known.contains(e.id))];
          _hasMore = list.length >= 30;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  List<KugouSoundItem> get _filteredItems {
    var list = _items;
    if (_classify != null) {
      list = list.where((e) => e.classify == _classify).toList();
    }
    if (_tag != null) {
      list = list.where((e) => e.tagName == _tag).toList();
    }
    return list;
  }

  List<String> get _availableTags {
    final tags = _items
        .where((item) => _classify == null || item.classify == _classify)
        .map((item) => item.tagName)
        .where((tag) => tag.isNotEmpty)
        .toSet();
    return [
      ..._kYtSoundTagOrder.where(tags.contains),
      ...tags.where((tag) => !_kYtSoundTagOrder.contains(tag)),
    ];
  }

  bool _matches(KugouSoundItem it, String kw) {
    final k = kw.toLowerCase();
    final hay =
        '${it.name} ${it.author} ${it.tagName} ${it.labels.join(' ')} ${it.intro}'
            .toLowerCase();
    return hay.contains(k);
  }

  Future<void> _doSearch(String kw) async {
    final keyword = kw.trim();
    if (keyword.isEmpty) {
      showToast('请输入搜索关键词');
      return;
    }
    setState(() {
      _searching = true;
      _searchKeyword = keyword;
      _searchResults = const [];
    });
    final results = <int, KugouSoundItem>{};
    for (final it in _items) {
      if (_matches(it, keyword)) results.putIfAbsent(it.id, () => it);
    }
    try {
      for (int p = 1; p <= 4 && _catalog != _YtSoundCatalog.earphone; p++) {
        final resp = _catalog == _YtSoundCatalog.artist
            ? await _api.getArtistEffects(page: p, pagesize: 50)
            : await _api.getSoundModel(sort: _sort, page: p, pagesize: 50);
        final list = _parseItems(resp);
        if (list.isEmpty) break;
        for (final it in list) {
          if (_matches(it, keyword)) results.putIfAbsent(it.id, () => it);
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _searching = false;
      _searchResults = results.values.toList();
    });
  }

  Future<void> _apply(KugouSoundItem item) async {
    AppHaptics.lightImpact(HapticCategory.control);
    final preset = _mapPreset(item);
    String route;
    if (ViperMasterService.instance.enabled) {
      await ViperMasterService.instance.applyPreset(preset);
      route = '蝰蛇母带 10 段：$preset';
    } else {
      final eq = EqualizerService.instance;
      await eq.setEnabled(true);
      await eq.applyPreset(preset);
      route = '均衡器预设：$preset';
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('sound_applied_id', item.id);
    await prefs.setString('sound_applied_name', item.name);
    if (!mounted) return;
    setState(() {
      _appliedId = item.id;
      _appliedName = item.name;
    });
    showToast('已应用「${item.name}」· $route');
  }

  Future<void> _unapply() async {
    AppHaptics.lightImpact(HapticCategory.control);
    if (ViperMasterService.instance.enabled) {
      await ViperMasterService.instance.applyPreset('正常');
    } else {
      final eq = EqualizerService.instance;
      await eq.applyPreset('正常');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('sound_applied_id');
    await prefs.remove('sound_applied_name');
    if (!mounted) return;
    setState(() {
      _appliedId = null;
      _appliedName = null;
    });
    showToast('已取消应用音效');
  }

  static String _mapPreset(KugouSoundItem it) {
    final text = '${it.name} ${it.labels.join(' ')} ${it.intro}';
    bool has(List<String> kws) => kws.any((k) => text.contains(k));
    if (has(['重低音', '低音炮', 'bass', 'Bass', 'BASS'])) return '重低音';
    if (has(['人声', '女声', '男声', 'vocal'])) return '人声';
    if (has(['电音', '电子', 'DJ'])) return '电子';
    if (has(['摇滚', 'rock', 'Rock'])) return '摇滚';
    if (has(['高音', '解析', 'HiFi', 'HIFI', 'hifi', '清晰', '人耳'])) {
      return '高音增强';
    }
    if (has(['环绕', '3D', '现场', '影院', '声场'])) return '电子';
    switch (it.tagName) {
      case '重低音':
        return '重低音';
      case '人声':
        return '人声';
      case '环绕':
        return '电子';
      case '设备模拟':
        return '流行';
      case '趣味':
        return '电子';
      default:
        return '流行';
    }
  }

  String _formatCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final items = _searchMode ? _searchResults : _filteredItems;
    final tags = _availableTags;

    return _YtDrawerShellContainer(
      child: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: widget.onVerticalDragUpdate,
            onVerticalDragEnd: widget.onVerticalDragEnd,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
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
                      const Icon(
                        Icons.graphic_eq_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '音效库',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (_appliedId != null)
                              Text(
                                '当前已启用：${_appliedName ?? '自定义音效'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF8AB4F8),
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (_appliedId != null)
                        TextButton(
                          onPressed: _unapply,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white70,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            visualDensity: VisualDensity.compact,
                          ),
                          child: const Text(
                            '关闭音效',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '均衡器与母带',
                        icon: const Icon(
                          Icons.tune_rounded,
                          color: Colors.white70,
                          size: 20,
                        ),
                        onPressed: () {
                          final push =
                              widget.onPushPage ?? Navigator.of(context).push;
                          push(
                            MaterialPageRoute(
                              builder: (_) => const EqualizerSettingsPage(),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: _searchMode ? '退出搜索' : '搜索音效',
                        icon: Icon(
                          _searchMode
                              ? Icons.search_off_rounded
                              : Icons.search_rounded,
                          color: Colors.white70,
                          size: 21,
                        ),
                        onPressed: () {
                          setState(() {
                            _searchMode = !_searchMode;
                            if (!_searchMode) {
                              _searchController.clear();
                              _searchKeyword = '';
                              _searchResults = const [];
                            }
                          });
                        },
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '关闭',
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: Colors.white70,
                          size: 26,
                        ),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                  if (_searchMode) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 38,
                      child: TextField(
                        controller: _searchController,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        onSubmitted: _doSearch,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                        ),
                        decoration: InputDecoration(
                          hintText: '搜索音效名称、标签（如 重低音 / 人声 / 环绕）…',
                          hintStyle: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12.5,
                          ),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            color: Colors.white54,
                            size: 18,
                          ),
                          suffixIcon: IconButton(
                            icon: const Icon(
                              Icons.arrow_forward_rounded,
                              color: Colors.white70,
                              size: 18,
                            ),
                            onPressed: () => _doSearch(_searchController.text),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.08),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(19),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    // 三个主分类 Tab：社区 / 明星 / 耳机
                    Row(
                      children: [
                        _buildCatalogChip(_YtSoundCatalog.community, '社区音效'),
                        const SizedBox(width: 8),
                        _buildCatalogChip(_YtSoundCatalog.artist, '明星音效'),
                        const SizedBox(width: 8),
                        _buildCatalogChip(_YtSoundCatalog.earphone, '耳机联名'),
                        const Spacer(),
                        GestureDetector(
                          onTap: () {
                            final push =
                                widget.onPushPage ?? Navigator.of(context).push;
                            push(
                              MaterialPageRoute(
                                builder: (_) => const SoundsPage(),
                              ),
                            );
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            child: Text(
                              '全屏页',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_catalog == _YtSoundCatalog.community &&
                        tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 30,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            _buildTagChip('全部', _tag == null && _classify == null, () {
                              setState(() {
                                _tag = null;
                                _classify = null;
                              });
                            }),
                            const SizedBox(width: 6),
                            _buildTagChip('蝰蛇官方', _classify == 2, () {
                              setState(() {
                                _classify = _classify == 2 ? null : 2;
                              });
                            }),
                            for (final t in tags) ...[
                              const SizedBox(width: 6),
                              _buildTagChip(t, _tag == t, () {
                                setState(() {
                                  _tag = _tag == t ? null : t;
                                });
                              }),
                            ],
                          ],
                        ),
                      ),
                    ] else if (_catalog == _YtSoundCatalog.earphone &&
                        _brands.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 30,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _brands.length + 1,
                          separatorBuilder: (_, _) => const SizedBox(width: 6),
                          itemBuilder: (_, idx) {
                            if (idx == 0) {
                              return _buildTagChip(
                                '推荐',
                                _selectedBrandId == null,
                                () => _selectBrand(null),
                              );
                            }
                            final b = _brands[idx - 1];
                            return _buildTagChip(
                              b.name,
                              _selectedBrandId == b.id,
                              () => _selectBrand(b.id),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
          Expanded(
            child: _PullDownDragForwarder(
              scrollController: _scrollController,
              onVerticalDragUpdate: widget.onVerticalDragUpdate,
              onVerticalDragEnd: widget.onVerticalDragEnd,
              pointerStartY: _pointerStartY,
              capturingPullDown: _capturingPullDown,
              lastStepDy: _lastStepDy,
              onStateUpdate: (startY, capturing, stepDy) {
                _pointerStartY = startY;
                _capturingPullDown = capturing;
                _lastStepDy = stepDy;
              },
              child: _buildSoundList(items),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCatalogChip(_YtSoundCatalog cat, String label) {
    final selected = _catalog == cat;
    return GestureDetector(
      onTap: () => _switchCatalog(cat),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? Colors.white
              : Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildTagChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? Colors.white.withValues(alpha: 0.24)
              : Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: selected
                ? Colors.white.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.08),
            width: 0.6,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white70,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _buildSoundList(List<KugouSoundItem> items) {
    if (_loading || _searching) {
      return const Center(
        child: CircularProgressIndicator(
          color: Colors.white70,
          strokeWidth: 2.5,
        ),
      );
    }
    if (items.isEmpty) {
      return ListView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        children: [
          const SizedBox(height: 80),
          Center(
            child: Text(
              _searchMode
                  ? (_searchKeyword.isEmpty ? '输入关键词并回车搜索音效' : '未找到匹配的音效')
                  : '暂无可用音效',
              style: const TextStyle(color: Colors.white60, fontSize: 14),
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(14, 10, 14, widget.safeBottom + 24),
      itemCount: items.length + (_loadingMore ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index >= items.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: Colors.white54,
                  strokeWidth: 2,
                ),
              ),
            ),
          );
        }
        final item = items[index];
        final applied = _appliedId == item.id;

        return Material(
          color: applied
              ? Colors.white.withValues(alpha: 0.14)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => applied ? _unapply() : _apply(item),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: item.iconUrl != null && item.iconUrl!.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: item.iconUrl!,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => Container(
                                color: Colors.white12,
                                child: const Icon(
                                  Icons.graphic_eq_rounded,
                                  color: Colors.white54,
                                  size: 24,
                                ),
                              ),
                            )
                          : Container(
                              color: Colors.white12,
                              child: const Icon(
                                Icons.graphic_eq_rounded,
                                color: Colors.white54,
                                size: 24,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (item.isOfficial) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF8AB4F8)
                                      .withValues(alpha: 0.22),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  '官方',
                                  style: TextStyle(
                                    color: Color(0xFF8AB4F8),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                            if (item.tagName.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  item.tagName,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (item.intro.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            item.intro,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const SizedBox(height: 3),
                        Text(
                          [
                            if (item.author.isNotEmpty) item.author,
                            if (item.userCount > 0)
                              '${_formatCount(item.userCount)}人使用',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: applied
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      applied ? '已启用' : '使用',
                      style: TextStyle(
                        color: applied ? Colors.black : Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
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

// ============================================================================
// 公共深色玻璃抽屉外壳与下拉手势转发器
// ============================================================================

class _YtDrawerShellContainer extends StatelessWidget {
  final Widget child;

  const _YtDrawerShellContainer({required this.child});

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
              Colors.black.withValues(alpha: 0.34),
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
        child: child,
      ),
    );
  }
}

class _PullDownDragForwarder extends StatelessWidget {
  final ScrollController scrollController;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;
  final double? pointerStartY;
  final bool capturingPullDown;
  final double lastStepDy;
  final void Function(double? startY, bool capturing, double stepDy)
  onStateUpdate;
  final Widget child;

  const _PullDownDragForwarder({
    required this.scrollController,
    required this.onVerticalDragUpdate,
    required this.onVerticalDragEnd,
    required this.pointerStartY,
    required this.capturingPullDown,
    required this.lastStepDy,
    required this.onStateUpdate,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        onStateUpdate(e.position.dy, false, 0.0);
      },
      onPointerMove: (e) {
        final startY = pointerStartY;
        if (startY == null) return;
        final totalDy = e.position.dy - startY;
        final atTop =
            !scrollController.hasClients || scrollController.offset <= 1.0;
        var capturing = capturingPullDown;
        if (!capturing && totalDy > 8.0 && atTop) {
          capturing = true;
        }
        if (capturing) {
          if (scrollController.hasClients && scrollController.offset > 0) {
            scrollController.jumpTo(0);
          }
          onStateUpdate(startY, true, e.delta.dy);
          onVerticalDragUpdate?.call(
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
        if (capturingPullDown) {
          final velocity = lastStepDy * 55.0;
          onStateUpdate(null, false, 0.0);
          onVerticalDragEnd?.call(
            DragEndDetails(
              velocity: Velocity(pixelsPerSecond: Offset(0, velocity)),
              primaryVelocity: velocity,
            ),
          );
        } else {
          onStateUpdate(null, false, 0.0);
        }
      },
      onPointerCancel: (_) {
        if (capturingPullDown) {
          onStateUpdate(null, false, 0.0);
          onVerticalDragEnd?.call(DragEndDetails());
        } else {
          onStateUpdate(null, false, 0.0);
        }
      },
      child: child,
    );
  }
}
