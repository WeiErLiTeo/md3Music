import 'dart:ui' show ImageFilter, TileMode;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../data/models/song.dart';
import '../../../providers/theme_provider.dart';
import '../../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../../widgets/flowing_background.dart';
import '../../../widgets/player_artwork_image.dart';
import '../artist_photo_background.dart';

class YtBackground extends StatelessWidget {
  final Song song;
  final bool isPlaying;
  final bool useArtistPhoto;

  const YtBackground({
    super.key,
    required this.song,
    required this.isPlaying,
    required this.useArtistPhoto,
  });

  @override
  Widget build(BuildContext context) {
    final blurSigma = context.select<ThemeProvider, double>(
      (p) => p.amPlayerBlur,
    );

    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: LyricPreferences.instance,
        builder: (context, _) {
          final useFlowing = LyricPreferences.instance.useFlowingBackground;

          return Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              if (useFlowing)
                FlowingBackground(
                  artworkUrl: song.artworkUri,
                  isPlaying: isPlaying,
                )
              else if (song.artworkUri != null && song.artworkUri!.isNotEmpty)
                Positioned.fill(
                  child: RepaintBoundary(
                    child: blurSigma > 0
                        ? ImageFiltered(
                            imageFilter: ImageFilter.blur(
                              sigmaX: blurSigma,
                              sigmaY: blurSigma,
                              tileMode: TileMode.clamp,
                            ),
                            child: PlayerArtworkImage(
                              artworkUri: song.artworkUri,
                              fallbackFilePath: song.localPath,
                              isFill: true,
                              fit: BoxFit.cover,
                              backgroundColor: Colors.black,
                              iconColor: Colors.white24,
                            ),
                          )
                        : PlayerArtworkImage(
                            artworkUri: song.artworkUri,
                            fallbackFilePath: song.localPath,
                            isFill: true,
                            fit: BoxFit.cover,
                            backgroundColor: Colors.black,
                            iconColor: Colors.white24,
                          ),
                  ),
                ),
              const Positioned.fill(
                child: ColoredBox(color: Color(0x59000000)),
              ),
              if (useArtistPhoto && song.isOnline)
                ArtistPhotoBackground(hash: song.id),
            ],
          );
        },
      ),
    );
  }
}
