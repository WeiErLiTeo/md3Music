import '../../core/layout/adaptive_navigator.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../data/models/album.dart';
import '../../core/remote/tv_card_focus.dart';
import '../../core/remote/tv_scroll_region.dart';
import 'search_section_header.dart';
import '../../core/theme/app_dimens.dart';
import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/album_card.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/playlist_cover_hero.dart';
import '../playlist/playlist_page.dart';
import '../charts/charts_page.dart';

/// 搜索空态的「探索音乐」内容段（改版计划：五段精简为单段）。
///
/// 仅保留主题歌单横滑带；场景音乐（不可点假 Chip）/ 热门歌单 / 排行榜 /
/// 新碟上架四段的大网格已删除。完整浏览入口收敛为段头 trailing 的两个
/// 紧凑入口：「热门歌单」→ [PlaylistBrowsePage]、「排行榜」→ [ChartsPage]
/// （排行榜全 App 只有这里可进，删除即成孤岛，见 2026-10-25 回归）。
/// 复用 [KugouProvider] 已有数据与缓存，仅在数据为空时补一次请求。
class MusicExploreSections extends StatefulWidget {
  const MusicExploreSections({super.key});

  @override
  State<MusicExploreSections> createState() => _MusicExploreSectionsState();
}

class _MusicExploreSectionsState extends State<MusicExploreSections> {
  /// 主题卡宽度（=1:1 封面边长）。口径沿用原搜索空态横滑带，未另调。
  static const double _themeCardExtent = 130;

  /// 横滑带高度 = 封面 [_themeCardExtent] + 文本区 36
  /// （titleSmall 行高 20 + 上下内衬 AppSpacing.sm 各 8，恰好填满）。
  static const double _themeBandHeight = 166;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoaded());
  }

  /// 仅在数据缺失时补拉；forceRefresh=false 命中 5 分钟缓存即不重复请求，
  /// 与其它页面共享同一份 KugouProvider 数据。
  void _ensureLoaded() {
    if (!mounted) return;
    final kugou = context.read<KugouProvider>();
    if (kugou.themePlaylistData.isEmpty) kugou.getThemePlaylist();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildThemeSection(),
        const Gap(AppSpacing.sm),
      ],
    );
  }

  /// 主题歌单：横滑方卡（展示态，无逐卡点击目标），
  /// 完整浏览走段头 trailing「探索更多」。
  Widget _buildThemeSection() {
    return Selector<KugouProvider, List<KugouThemeInfo>>(
      selector: (_, kugou) => kugou.themePlaylistData,
      builder: (context, themes, _) {
        if (themes.isEmpty) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 与搜索历史/热搜段共用同一套段落头与动作规格(见 SearchSectionHeader)。
            SearchSectionHeader(
              title: '探索音乐',
              actions: [
                TvCardFocus(
                  onSelect: () => AdaptiveNav.openDetail(
                    context,
                    (_) => const PlaylistBrowsePage(),
                  ),
                  debugLabel: 'explore-entry-热门歌单',
                  child: SearchSectionAction(
                    icon: Icons.queue_music,
                    label: '热门歌单',
                    onTap: () => AdaptiveNav.openDetail(
                      context,
                      (_) => const PlaylistBrowsePage(),
                    ),
                  ),
                ),
                TvCardFocus(
                  onSelect: () => AdaptiveNav.openDetail(
                    context,
                    (_) => const ChartsPage(),
                  ),
                  debugLabel: 'explore-entry-排行榜',
                  child: SearchSectionAction(
                    icon: Icons.leaderboard,
                    label: '排行榜',
                    onTap: () => AdaptiveNav.openDetail(
                      context,
                      (_) => const ChartsPage(),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(
              height: _themeBandHeight,
              child: TvScrollRegion(
                memoryKey: 'tv/explore-themes-row',
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  itemCount: themes.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.md),
                    child: SizedBox(
                      width: _themeCardExtent,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: AppRadius.lgAll,
                          color: cs.surfaceContainerLow,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AspectRatio(
                              aspectRatio: 1,
                              child: CachedNetworkImage(
                                imageUrl: themes[i].coverUrl ?? '',
                                memCacheWidth: 390,
                                memCacheHeight: 390,
                                fit: BoxFit.cover,
                                placeholder: (_, _) => _coverPlaceholder(cs),
                                errorWidget: (_, _, _) => _coverPlaceholder(cs),
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.all(AppSpacing.sm),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    themes[i].name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        Theme.of(context).textTheme.titleSmall,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static Widget _coverPlaceholder(ColorScheme cs) => Container(
        color: cs.surfaceContainerHighest,
        child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
      );
}

/// 热门歌单浏览页（从发现页迁移）：完整歌单网格，
/// 也是探索段段头「探索更多」的目标页。
class PlaylistBrowsePage extends StatefulWidget {
  const PlaylistBrowsePage({super.key});
  @override
  State<PlaylistBrowsePage> createState() => _PlaylistBrowsePageState();
}

class _PlaylistBrowsePageState extends State<PlaylistBrowsePage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // 完整列表与其它页面共用同一份 Provider 数据：从「探索更多」进来时通常已
    // 加载完毕。转场首帧必须就有网格上的 Hero 端点（区块小封面 → 完整列表大
    // 封面的衔接）——先按现有数据渲染，后台只做一次补拉刷新。
    _isLoading = context.read<KugouProvider>().playlistList.isEmpty;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<KugouProvider>().getPlaylist();
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('热门歌单')),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : Selector<KugouProvider, List<KugouPlaylistBrief>>(
              selector: (_, kugou) => kugou.playlistList,
              builder: (context, list, _) {
                if (list.isEmpty) return const Center(child: Text('暂无数据'));
                // Hero tag 唯一性防护：完整列表来自服务端，可能出现重复 gid；
                // 只给每个 id 首次出现的卡片挂 Hero（tag 口径与引用方一致，
                // 推入/返回时封面成对飞行）。
                final firstGid = firstIndexById(
                  [for (final p in list) p.globalCollectionId ?? p.id],
                );
                return TvScrollRegion(
                  memoryKey: 'tv/browse-playlists',
                  horizontalEdge: DpadEdgeBehavior.leave,
                  child: PinchableGridView(
                    padding: EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.lg, AppSpacing.lg,
                      AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
                    ),
                    // 0.8 与搜索结果卡、专辑浏览卡统一（浏览页已验证值）。
                    childAspectRatio: 0.8,
                    spacing: 12,
                    itemCount: list.length,
                    itemBuilder: (context, i) => AlbumCard(
                      album: Album(
                        id: list[i].id,
                        name: list[i].name,
                        artist: '',
                        artworkUri: list[i].coverUrl,
                        songCount: list[i].songCount,
                      ),
                      heroTag:
                          firstGid[list[i].globalCollectionId ?? list[i].id] == i
                              ? playlistCoverHeroTag(
                                  list[i].globalCollectionId ?? list[i].id,
                                )
                              : null,
                      onTap: () => AdaptiveNav.openDetail(context,
                        (_) =>
                              PlaylistPage(playlist: list[i].toPlaylist()),
                        ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
