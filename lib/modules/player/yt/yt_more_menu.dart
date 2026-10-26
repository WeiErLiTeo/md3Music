import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../../core/platform_capabilities.dart';
import '../../../core/services/equalizer_service.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/album.dart';
import '../../../data/models/song.dart';
import '../../../data/repositories/song_match_repository.dart';
import '../../../providers/player_provider.dart';
import '../../../services/kugou_api/kugou_api_client.dart';
import '../../../widgets/add_to_playlist_dialog.dart';
import '../../../widgets/apple_lyrics/layout/lyric_preferences_panel.dart';
import '../../../widgets/menu_action_cell.dart';
import '../../../widgets/player_volume_bar.dart';
import '../../album/album_detail_page.dart';
import '../../artist/artist_detail_page.dart';
import '../../library/song_match_sheet.dart';
import '../../settings/equalizer_settings_page.dart';
import '../../sheet/song_sheet_sheet.dart';
import '../../sound/sounds_page.dart';
import '../audio_quality_dialog.dart';
import '../dlna_cast_sheet.dart';
import '../mv_player_page.dart';
import '../sleep_timer_sheet.dart';
import '../song_info_page.dart';
import '../speed_picker_sheet.dart';

class YtMoreMenu {
  static final RegExp _kugouLowResPathRegex = RegExp(
    r'/(64|100|120|135|150|160|200|240|300|400|480|500|600|720)/',
  );

  /// 将酷狗封面 URL 中的低分辨率档位（如 400/240/150 或 {size}）升级为 1080p 超清原图档位
  static String? upgradeArtworkUri(String? uri) {
    if (uri == null || uri.isEmpty) return uri;
    var result = uri.replaceAll('{size}', '1080');
    if (result.contains('kugou.com') ||
        result.contains('kgimg.com') ||
        result.contains('/stdmusic/')) {
      result = result.replaceFirst(_kugouLowResPathRegex, '/1080/');
    }
    return result;
  }

  static Song resolveMatchedSong(Song song) {
    Song base = song;
    if (!song.isOnline) {
      final info = SongMatchRepository().get(song.id);
      if (info != null && info.isMatched) {
        base = info.toSong();
      }
    }
    final upgradedUri = upgradeArtworkUri(base.artworkUri);
    if (upgradedUri != base.artworkUri) {
      return base.copyWith(artworkUri: upgradedUri);
    }
    return base;
  }

  static void show(
    BuildContext rootContext,
    Song song, {
    void Function(Route<dynamic>)? onPushPage,
    void Function(Route<dynamic>)? onDismissAndPush,
  }) {
    final player = rootContext.read<PlayerProvider>();
    final resolvedSong = resolveMatchedSong(song);

    void pushOverPlayer(Route<dynamic> route) {
      if (onPushPage != null) {
        onPushPage(route);
      } else {
        Navigator.maybeOf(rootContext)?.push(route);
      }
    }

    void pushWithDismiss(Route<dynamic> route) {
      if (onDismissAndPush != null) {
        onDismissAndPush(route);
      } else {
        pushOverPlayer(route);
      }
    }

    showM3EModalBottomSheet(
      context: rootContext,
      isScrollControlled: true,
      backgroundColor: Theme.of(rootContext).colorScheme.surfaceContainerLow,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!song.isOnline && song.localPath != null)
                  ListTile(
                    leading: const Icon(Icons.manage_search),
                    title: const Text('匹配在线信息'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      showSongMatchSheet(rootContext, song);
                    },
                  ),
                if (song.isOnline)
                  ListTile(
                    leading: const Icon(Icons.playlist_add),
                    title: const Text('添加到歌单'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      showAddToPlaylistDialog(rootContext, song);
                    },
                  ),
                if (song.isOnline)
                  ListTile(
                    leading: const Icon(Icons.high_quality_outlined),
                    title: const Text('音质选择'),
                    trailing: Text(player.currentQualityLabel),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      showAudioQualityDialog(
                        context: rootContext,
                        qualities: kPlayerAudioQualities,
                        selected: player.audioQuality,
                        onSelected: player.setAudioQuality,
                      );
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('歌曲信息'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    pushOverPlayer(
                      MaterialPageRoute(builder: (_) => const SongInfoPage()),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.speed),
                  title: const Text('播放速度'),
                  trailing: Text('${formatPlaybackSpeed(player.speed)}x'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    showSpeedPickerDialog(
                      context: rootContext,
                      currentSpeed: player.speed,
                      onSelected: player.setSpeed,
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.lyrics_outlined),
                  title: const Text('歌词显示设置'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    showM3EModalBottomSheet(
                      context: rootContext,
                      isScrollControlled: true,
                      backgroundColor: Theme.of(rootContext)
                          .colorScheme
                          .surfaceContainerLow,
                      builder: (_) =>
                          const SafeArea(child: LyricPreferencesPanel()),
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: PlayerVolumeBar(amStyle: false),
                ),
                // 主分支同款两行四格宫格容器
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          if (resolvedSong.isOnline)
                            MenuActionCell(
                              icon: Icons.music_video_outlined,
                              label: 'MV',
                              active: false,
                              onTap: () {
                                Navigator.pop(sheetContext);
                                pushOverPlayer(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        MvPlayerPage(song: resolvedSong),
                                  ),
                                );
                              },
                            ),
                          MenuActionCell(
                            icon: Icons.album,
                            label: '专辑',
                            active: false,
                            onTap: () {
                              Navigator.pop(sheetContext);
                              navigateToAlbum(
                                rootContext,
                                resolvedSong,
                                pushWithDismiss,
                              );
                            },
                          ),
                          MenuActionCell(
                            icon: Icons.person,
                            label: '歌手',
                            active: false,
                            onTap: () {
                              Navigator.pop(sheetContext);
                              navigateToArtist(
                                rootContext,
                                resolvedSong,
                                pushWithDismiss,
                              );
                            },
                          ),
                          if (resolvedSong.albumAudioId != null &&
                              resolvedSong.albumAudioId!.isNotEmpty)
                            MenuActionCell(
                              icon: Icons.library_music_outlined,
                              label: '曲谱',
                              active: false,
                              onTap: () {
                                Navigator.pop(sheetContext);
                                showSongSheetSheet(rootContext, resolvedSong);
                              },
                            ),
                        ],
                      ),
                      Container(
                        height: 1,
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        color: colorScheme.outlineVariant.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      Row(
                        children: [
                          if (supportsSystemAudioEffects) ...[
                            ListenableBuilder(
                              listenable: EqualizerService.instance,
                              builder: (context, _) {
                                final eq = EqualizerService.instance;
                                return MenuActionCell(
                                  icon: Icons.graphic_eq,
                                  label: '均衡器',
                                  active: eq.enabled,
                                  enabled: !eq.systemEffectsDisabled,
                                  onTap: () {
                                    Navigator.pop(sheetContext);
                                    pushOverPlayer(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const EqualizerSettingsPage(),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                            ListenableBuilder(
                              listenable: EqualizerService.instance,
                              builder: (context, _) {
                                final eq = EqualizerService.instance;
                                return MenuActionCell(
                                  icon: Icons.spatial_audio_off,
                                  label: '音效',
                                  active: false,
                                  enabled: !eq.systemEffectsDisabled,
                                  onTap: () {
                                    Navigator.pop(sheetContext);
                                    pushOverPlayer(
                                      MaterialPageRoute(
                                        builder: (_) => const SoundsPage(),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ],
                          ListenableBuilder(
                            listenable: player,
                            builder: (context, _) {
                              return MenuActionCell(
                                icon: Icons.timer_outlined,
                                label: '定时关闭',
                                active: player.isSleepTimerActive,
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  showSleepTimerSheet(
                                    context: rootContext,
                                    player: player,
                                  );
                                },
                              );
                            },
                          ),
                          MenuActionCell(
                            icon: Icons.cast,
                            label: '投屏',
                            active: false,
                            onTap: () {
                              Navigator.pop(sheetContext);
                              showM3EModalBottomSheet(
                                context: rootContext,
                                isScrollControlled: true,
                                backgroundColor: Theme.of(rootContext)
                                    .colorScheme
                                    .surfaceContainerLow,
                                builder: (_) => const DlnaCastSheet(),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static void navigateToAlbum(
    BuildContext context,
    Song resolved,
    void Function(Route<dynamic>) pushPage,
  ) {
    final albumId = resolved.albumId;
    if (albumId == null || albumId.isEmpty) {
      showToast('暂无专辑信息', long: true);
      return;
    }
    final album = Album(
      id: albumId,
      name: resolved.album.isNotEmpty ? resolved.album : resolved.displayName,
      artist: resolved.artist,
      artworkUri: resolved.artworkUri,
      songCount: 0,
    );
    pushPage(MaterialPageRoute(builder: (_) => AlbumDetailPage(album: album)));
  }

  static void navigateToArtist(
    BuildContext context,
    Song resolved,
    void Function(Route<dynamic>) pushPage,
  ) {
    final artists = splitSongArtistNames(resolved.artist);
    if (artists.isEmpty) {
      showToast('暂无歌手信息', long: true);
      return;
    }
    if (artists.length == 1) {
      pushArtistPage(context, resolved.artistId, artists.first, pushPage);
      return;
    }
    showArtistSelector(context, resolved, artists, pushPage);
  }

  static void showArtistSelector(
    BuildContext context,
    Song song,
    List<String> artists,
    void Function(Route<dynamic>) pushPage,
  ) {
    showM3EModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '选择歌手',
                  style: Theme.of(sheetCtx).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              ...artists.map((name) {
                return ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(name),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    if (name == artists.first &&
                        song.artistId != null &&
                        song.artistId!.isNotEmpty) {
                      pushArtistPage(context, song.artistId, name, pushPage);
                    } else {
                      pushArtistPageByName(context, name, pushPage);
                    }
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  static Future<void> pushArtistPageByName(
    BuildContext context,
    String name,
    void Function(Route<dynamic>) pushPage,
  ) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final navigator = Navigator.of(context, rootNavigator: true);
    void Function()? pendingPush;
    try {
      final api = KugouApiClient();
      final result = await api.searchArtists(name, pagesize: 5);
      if (result == null || result.isEmpty) {
        showToast('未找到歌手「$name」', long: true);
        return;
      }
      final artist = result.first;
      if (!context.mounted) return;
      pendingPush = () =>
          pushArtistPage(context, artist.id, artist.name, pushPage);
    } catch (e) {
      showToast('搜索歌手失败：$e', long: true);
    } finally {
      navigator.pop();
    }
    pendingPush?.call();
  }

  static void pushArtistPage(
    BuildContext context,
    String? artistId,
    String artistName,
    void Function(Route<dynamic>) pushPage,
  ) {
    if (artistId == null || artistId.isEmpty) {
      pushArtistPageByName(context, artistName, pushPage);
      return;
    }
    pushPage(
      MaterialPageRoute(
        builder: (_) => ArtistDetailPage(
          artistId: artistId,
          artistName: artistName,
          avatarUrl: null,
        ),
      ),
    );
  }
}
