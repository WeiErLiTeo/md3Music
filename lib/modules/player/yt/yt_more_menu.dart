import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/app_toast.dart';
import '../../../data/models/album.dart';
import '../../../data/models/song.dart';
import '../../../data/repositories/song_match_repository.dart';
import '../../../providers/player_provider.dart';
import '../../../services/kugou_api/kugou_api_client.dart';
import '../../../widgets/add_to_playlist_dialog.dart';
import '../../album/album_detail_page.dart';
import '../../artist/artist_detail_page.dart';
import '../../library/song_match_sheet.dart';
import '../../settings/equalizer_settings_page.dart';
import '../dlna_cast_sheet.dart';
import '../mv_player_page.dart';
import '../sleep_timer_sheet.dart';
import '../song_info_page.dart';
import '../speed_picker_sheet.dart';

class YtMoreMenu {
  static Song resolveMatchedSong(Song song) {
    if (song.isOnline) return song;
    final info = SongMatchRepository().get(song.id);
    return (info != null && info.isMatched) ? info.toSong() : song;
  }

  static void show(
    BuildContext rootContext,
    Song song, {
    void Function(Route<dynamic>)? onPushPage,
    void Function(Route<dynamic>)? onDismissAndPush,
  }) {
    final player = rootContext.read<PlayerProvider>();
    final resolvedSong = resolveMatchedSong(song);

    final albumTitle = resolvedSong.album.isEmpty
        ? '查看专辑'
        : '查看专辑：${resolvedSong.album}';
    final artistTitle = resolvedSong.artist.isEmpty
        ? '查看歌手'
        : '查看歌手：${resolvedSong.artist}';

    void pushOverPlayer(Route<dynamic> route) {
      if (onPushPage != null) {
        onPushPage(route);
      } else {
        Navigator.of(rootContext).push(route);
      }
    }

    void pushWithDismiss(Route<dynamic> route) {
      if (onDismissAndPush != null) {
        onDismissAndPush(route);
      } else {
        pushOverPlayer(route);
      }
    }

    showModalBottomSheet(
      context: rootContext,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF212121),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (song.isOnline == true)
                  ListTile(
                    leading: const Icon(
                      Icons.music_video_outlined,
                      color: Colors.white70,
                    ),
                    title: const Text('查看 MV', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      Future.delayed(const Duration(milliseconds: 150), () {
                        if (rootContext.mounted) {
                          pushOverPlayer(
                            MaterialPageRoute(
                              builder: (_) => MvPlayerPage(song: song),
                            ),
                          );
                        }
                      });
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.album, color: Colors.white70),
                  title: Text(
                    albumTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Future.delayed(const Duration(milliseconds: 150), () {
                      if (rootContext.mounted) {
                        navigateToAlbum(rootContext, resolvedSong, pushWithDismiss);
                      }
                    });
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.person, color: Colors.white70),
                  title: Text(
                    artistTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Future.delayed(const Duration(milliseconds: 150), () {
                      if (rootContext.mounted) {
                        navigateToArtist(rootContext, resolvedSong, pushWithDismiss);
                      }
                    });
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add, color: Colors.white70),
                  title: const Text('添加到歌单', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      showAddToPlaylistDialog(rootContext, song);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.cast, color: Colors.white70),
                  title: const Text('投屏 (DLNA)', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      showModalBottomSheet(
                        context: rootContext,
                        isScrollControlled: true,
                        backgroundColor: const Color(0xFF212121),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                        ),
                        builder: (_) => const DlnaCastSheet(),
                      );
                    }
                  },
                ),
                if (!song.isOnline)
                  ListTile(
                    leading: const Icon(Icons.sync, color: Colors.white70),
                    title: const Text('匹配歌曲信息', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      if (rootContext.mounted) {
                        showSongMatchSheet(rootContext, song);
                      }
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.graphic_eq, color: Colors.white70),
                  title: const Text('均衡器与音效设置', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Future.delayed(const Duration(milliseconds: 150), () {
                      if (rootContext.mounted) {
                        pushOverPlayer(
                          MaterialPageRoute(
                            builder: (_) => const EqualizerSettingsPage(),
                          ),
                        );
                      }
                    });
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.speed, color: Colors.white70),
                  title: const Text('播放速度', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      showSpeedPickerDialog(
                        context: rootContext,
                        currentSpeed: player.speed,
                        onSelected: (speed) => player.setSpeed(speed),
                      );
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.timer_outlined, color: Colors.white70),
                  title: const Text('睡眠定时', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (rootContext.mounted) {
                      showSleepTimerSheet(
                        context: rootContext,
                        player: player,
                      );
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline, color: Colors.white70),
                  title: const Text('歌曲信息', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Future.delayed(const Duration(milliseconds: 150), () {
                      if (rootContext.mounted) {
                        pushOverPlayer(
                          MaterialPageRoute(builder: (_) => const SongInfoPage()),
                        );
                      }
                    });
                  },
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
    pushPage(
      MaterialPageRoute(builder: (_) => AlbumDetailPage(album: album)),
    );
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
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF212121),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '选择歌手',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ...artists.map((name) {
                return ListTile(
                  leading: const Icon(Icons.person, color: Colors.white70),
                  title: Text(name, style: const TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    Future.delayed(const Duration(milliseconds: 150), () {
                      if (!context.mounted) return;
                      if (name == artists.first &&
                          song.artistId != null &&
                          song.artistId!.isNotEmpty) {
                        pushArtistPage(context, song.artistId, name, pushPage);
                      } else {
                        pushArtistPageByName(context, name, pushPage);
                      }
                    });
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
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
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
      pendingPush = () => pushArtistPage(context, artist.id, artist.name, pushPage);
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
