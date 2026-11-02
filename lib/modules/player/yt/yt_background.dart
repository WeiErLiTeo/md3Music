import 'dart:ui' show ImageFilter, TileMode;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/services/audio_service.dart';
import '../../../data/models/song.dart';
import '../../../providers/theme_provider.dart';
import '../../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../../widgets/flowing_background.dart';
import '../../../widgets/player_artwork_image.dart';
import '../artist_photo_background.dart';

class YtBackground extends StatefulWidget {
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
  State<YtBackground> createState() => _YtBackgroundState();
}

class _YtBackgroundState extends State<YtBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  String? _currentArtworkUri;
  String? _currentLocalPath;
  String? _previousArtworkUri;
  String? _previousLocalPath;

  @override
  void initState() {
    super.initState();
    _currentArtworkUri = widget.song.artworkUri;
    _currentLocalPath = widget.song.localPath;
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      value: 1.0,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void didUpdateWidget(covariant YtBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newUri = widget.song.artworkUri;
    final newLocal = widget.song.localPath;
    if (newUri != _currentArtworkUri || newLocal != _currentLocalPath) {
      if ((_currentArtworkUri != null && _currentArtworkUri!.isNotEmpty) ||
          (_currentLocalPath != null && _currentLocalPath!.isNotEmpty)) {
        _previousArtworkUri = _currentArtworkUri;
        _previousLocalPath = _currentLocalPath;
      }
      _currentArtworkUri = newUri;
      _currentLocalPath = newLocal;
      _fadeController.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  Widget _buildBlurredArtworkStack() {
    final hasPrev =
        (_previousArtworkUri != null && _previousArtworkUri!.isNotEmpty) ||
        (_previousLocalPath != null && _previousLocalPath!.isNotEmpty);
    final hasCurr =
        (_currentArtworkUri != null && _currentArtworkUri!.isNotEmpty) ||
        (_currentLocalPath != null && _currentLocalPath!.isNotEmpty);

    if (!hasCurr && !hasPrev) {
      return const SizedBox.shrink();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasPrev)
          PlayerArtworkImage(
            key: ValueKey('yt_bg_prev_${_previousArtworkUri}_$_previousLocalPath'),
            artworkUri: _previousArtworkUri,
            fallbackFilePath: _previousLocalPath,
            isFill: true,
            fit: BoxFit.cover,
            backgroundColor: Colors.black,
            iconColor: Colors.white24,
          ),
        if (hasCurr)
          FadeTransition(
            opacity: hasPrev ? _fadeAnimation : const AlwaysStoppedAnimation(1.0),
            child: PlayerArtworkImage(
              key: ValueKey('yt_bg_curr_${_currentArtworkUri}_$_currentLocalPath'),
              artworkUri: _currentArtworkUri,
              fallbackFilePath: _currentLocalPath,
              isFill: true,
              fit: BoxFit.cover,
              backgroundColor: hasPrev ? Colors.transparent : Colors.black,
              iconColor: hasPrev ? Colors.transparent : Colors.white24,
            ),
          ),
      ],
    );
  }

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
                  artworkUrl: widget.song.artworkUri,
                  isPlaying: widget.isPlaying,
                  playingStream: AudioService().playingStream,
                )
              else
                Positioned.fill(
                  child: RepaintBoundary(
                    child: blurSigma > 0
                        ? ImageFiltered(
                            imageFilter: ImageFilter.blur(
                              sigmaX: blurSigma,
                              sigmaY: blurSigma,
                              tileMode: TileMode.clamp,
                            ),
                            child: _buildBlurredArtworkStack(),
                          )
                        : _buildBlurredArtworkStack(),
                  ),
                ),
              const Positioned.fill(
                child: ColoredBox(color: Color(0x59000000)),
              ),
              if (widget.useArtistPhoto && widget.song.isOnline)
                ArtistPhotoBackground(hash: widget.song.id),
            ],
          );
        },
      ),
    );
  }
}
