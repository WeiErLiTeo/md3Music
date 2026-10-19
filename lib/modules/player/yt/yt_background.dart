import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../data/models/song.dart';
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
    return ListenableBuilder(
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
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(
                        sigmaX: 45.0,
                        sigmaY: 45.0,
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
                    ),
                  ),
                ),
              const Positioned.fill(
                child: ColoredBox(color: Color(0x59000000)),
              ),
              if (useArtistPhoto && song.isOnline)
                ArtistPhotoBackground(hash: song.id),
            ],
          ),
        );
      },
    );
  }
}
