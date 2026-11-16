import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, TileMode;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/audio_service.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/utils/artwork_color_extractor.dart';
import '../../../data/models/song.dart';
import '../../../providers/theme_provider.dart';
import '../../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../../widgets/flowing_background.dart';
import '../../../widgets/player_artwork_image.dart';
import '../artist_photo_background.dart';

/// YouTube Music 播放页与内嵌抽屉（相关内容/歌词/歌手/队列/评论）背景渲染模式
enum YtBgRenderMode {
  /// 原版 YouTube Music：从封面提取主色与次要色，过滤脏暗/过曝色块，
  /// 在 HSL 空间压低明度并控制饱和度，合成深邃的径向+纵向双层氛围渐变
  ytOriginal,

  /// 混合柔光：在 YT 原版深色取色渐变基础上叠加一层低透明度超大模糊封面柔光
  ytHybrid,

  /// 传统封面高斯模糊（与 Apple Music 模糊背景一致）
  classicBlur,
}

/// YT 播放页与歌曲抽屉页面的实时色板
class YtSongPalette {
  final Color playerTopGlow;
  final Color playerMidTone;
  final Color playerBottomBase;
  final Color miniBarBg;
  final Color drawerTop;
  final Color drawerBottom;
  final Color drawerBorder;

  const YtSongPalette({
    required this.playerTopGlow,
    required this.playerMidTone,
    required this.playerBottomBase,
    required this.miniBarBg,
    required this.drawerTop,
    required this.drawerBottom,
    required this.drawerBorder,
  });

  static const YtSongPalette fallback = YtSongPalette(
    playerTopGlow: Color(0xFF1E1B2E),
    playerMidTone: Color(0xFF110F1B),
    playerBottomBase: Color(0xFF060609),
    miniBarBg: Color(0xFF0C0B12),
    drawerTop: Color(0xF7171522),
    drawerBottom: Color(0xFA0B0A11),
    drawerBorder: Color(0x22FFFFFF),
  );

  static YtSongPalette lerp(YtSongPalette a, YtSongPalette b, double t) {
    return YtSongPalette(
      playerTopGlow: Color.lerp(a.playerTopGlow, b.playerTopGlow, t)!,
      playerMidTone: Color.lerp(a.playerMidTone, b.playerMidTone, t)!,
      playerBottomBase: Color.lerp(a.playerBottomBase, b.playerBottomBase, t)!,
      miniBarBg: Color.lerp(a.miniBarBg, b.miniBarBg, t)!,
      drawerTop: Color.lerp(a.drawerTop, b.drawerTop, t)!,
      drawerBottom: Color.lerp(a.drawerBottom, b.drawerBottom, t)!,
      drawerBorder: Color.lerp(a.drawerBorder, b.drawerBorder, t)!,
    );
  }
}

/// 全局共享的 YT 背景取色与渲染配置中心（持久化到 SharedPreferences）
class YtPaletteTheme extends ChangeNotifier {
  YtPaletteTheme._() {
    _loadPrefs();
  }

  static final YtPaletteTheme instance = YtPaletteTheme._();

  static const String _keyRenderMode = 'yt_bg_render_mode';
  static const String _keySyncDrawers = 'yt_bg_sync_drawers';
  static const String _keyIntensity = 'yt_bg_color_intensity';

  YtBgRenderMode _renderMode = YtBgRenderMode.ytOriginal;
  bool _syncDrawers = true;
  double _intensity = 1.0;

  YtBgRenderMode get renderMode => _renderMode;
  bool get syncDrawers => _syncDrawers;
  double get intensity => _intensity;

  String? _currentKey;
  HSLColor? _rawPrimaryHsl;
  HSLColor? _rawSecondaryHsl;
  YtSongPalette _currentPalette = YtSongPalette.fallback;

  YtSongPalette get currentPalette => _currentPalette;

  static final Map<String, (HSLColor, HSLColor)> _hslCache =
      <String, (HSLColor, HSLColor)>{};

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeIdx = prefs.getInt(_keyRenderMode);
      if (modeIdx != null &&
          modeIdx >= 0 &&
          modeIdx < YtBgRenderMode.values.length) {
        _renderMode = YtBgRenderMode.values[modeIdx];
      }
      _syncDrawers = prefs.getBool(_keySyncDrawers) ?? true;
      _intensity = (prefs.getDouble(_keyIntensity) ?? 1.0).clamp(0.4, 1.4);
      _recomputeFromRaw();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setRenderMode(YtBgRenderMode mode) async {
    if (_renderMode == mode) return;
    _renderMode = mode;
    _recomputeFromRaw();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyRenderMode, mode.index);
    } catch (_) {}
  }

  Future<void> setSyncDrawers(bool value) async {
    if (_syncDrawers == value) return;
    _syncDrawers = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keySyncDrawers, value);
    } catch (_) {}
  }

  Future<void> setIntensity(double value) async {
    final clamped = value.clamp(0.4, 1.4);
    if ((_intensity - clamped).abs() < 0.005) return;
    _intensity = clamped;
    _recomputeFromRaw();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_keyIntensity, clamped);
    } catch (_) {}
  }

  /// 为抽屉（相关内容/歌曲百科/歌词/队列/歌手/评论/保存/音效）生成统一背景装饰
  static BoxDecoration drawerDecoration({double topRadius = 20.0}) {
    final theme = instance;
    if (!theme.syncDrawers) {
      return BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.78),
            Colors.black.withValues(alpha: 0.92),
          ],
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(topRadius)),
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.12),
            width: 0.5,
          ),
        ),
      );
    }
    final p = theme.currentPalette;
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: const [0.0, 0.45, 1.0],
        colors: [
          p.drawerTop,
          Color.lerp(p.drawerTop, p.drawerBottom, 0.58)!,
          p.drawerBottom,
        ],
      ),
      borderRadius: BorderRadius.vertical(top: Radius.circular(topRadius)),
      border: Border(
        top: BorderSide(color: p.drawerBorder, width: 0.6),
      ),
    );
  }

  Future<void> updateForSong(Song song) async {
    final url = (song.artworkUri != null && song.artworkUri!.isNotEmpty)
        ? song.artworkUri!
        : (song.localPath != null && song.localPath!.isNotEmpty
              ? 'local://${song.localPath}'
              : '');
    if (url.isEmpty) {
      _currentKey = '';
      _rawPrimaryHsl = null;
      _rawSecondaryHsl = null;
      _currentPalette = YtSongPalette.fallback;
      notifyListeners();
      return;
    }
    if (_currentKey == url && _rawPrimaryHsl != null) {
      return;
    }
    _currentKey = url;

    final cached = _hslCache[url];
    if (cached != null) {
      _rawPrimaryHsl = cached.$1;
      _rawSecondaryHsl = cached.$2;
      _recomputeFromRaw();
      notifyListeners();
      return;
    }

    final palette = await ArtworkColorExtractor.loadPalette(url);
    if (_currentKey != url) return;
    if (palette == null) {
      _rawPrimaryHsl = null;
      _rawSecondaryHsl = null;
      _currentPalette = YtSongPalette.fallback;
      notifyListeners();
      return;
    }

    final extracted = _extractYtPrimaryAndSecondaryHsl(palette);
    if (_hslCache.length > 160) {
      _hslCache.remove(_hslCache.keys.first);
    }
    _hslCache[url] = extracted;
    _rawPrimaryHsl = extracted.$1;
    _rawSecondaryHsl = extracted.$2;
    _recomputeFromRaw();
    notifyListeners();
  }

  /// YouTube Music 原版封面色筛选算法：
  /// 1. 收集 PaletteGenerator 全部色板样本，按像素占比归一化；
  /// 2. 剔除死黑 (L < 0.07)、刺眼纯白 (L > 0.91) 与灰浊无彩色 (S < 0.10)；
  /// 3. 对低饱和度土黄/浑浊橄榄色 (Hue 34°~68°, S < 0.52, L < 0.48) 降权，
  ///    避免暖黄封面压暗后变成泥汤色；
  /// 4. 综合「像素占比 50% + 饱和度表现力 35% + 适中明度 15%」选出主色调与次要氛围色。
  static (HSLColor, HSLColor) _extractYtPrimaryAndSecondaryHsl(
    PaletteGenerator palette,
  ) {
    final swatches = <PaletteColor>[
      ...palette.paletteColors,
      if (palette.vibrantColor != null) palette.vibrantColor!,
      if (palette.darkVibrantColor != null) palette.darkVibrantColor!,
      if (palette.mutedColor != null) palette.mutedColor!,
      if (palette.dominantColor != null) palette.dominantColor!,
    ];

    if (swatches.isEmpty) {
      const fallbackHsl = HSLColor.fromAHSL(1.0, 245.0, 0.35, 0.20);
      return (fallbackHsl, fallbackHsl);
    }

    int maxPop = 1;
    for (final s in swatches) {
      if (s.population > maxPop) maxPop = s.population;
    }

    final scored = <({HSLColor hsl, double score})>[];
    for (final s in swatches) {
      final hsl = HSLColor.fromColor(s.color);
      final l = hsl.lightness;
      final sat = hsl.saturation;
      if (l < 0.065 || l > 0.92) continue;
      if (sat < 0.09) continue;

      final popRatio = (s.population / maxPop).clamp(0.02, 1.0);
      final popScore = math.pow(popRatio, 0.60).toDouble();

      // 偏好中高饱和度（0.45~0.88），让深色背景有鲜明的色彩倾向而不发灰
      final satScore = 1.0 - ((sat - 0.68).abs() / 0.68).clamp(0.0, 1.0);
      // 偏好适中明度（0.25~0.70）
      final lightScore = 1.0 - ((l - 0.46).abs() / 0.46).clamp(0.0, 1.0);

      double penalty = 1.0;
      // 压暗后容易变成浑浊泥黄色的区间（34°~68°）：若不够鲜亮则显著降权，或向温暖琥珀/深红偏移
      if (hsl.hue >= 34.0 && hsl.hue <= 68.0 && (sat < 0.56 || l < 0.48)) {
        penalty = 0.42;
      }

      final total =
          (popScore * 0.50 + satScore * 0.35 + lightScore * 0.15) * penalty;
      scored.add((hsl: hsl, score: total));
    }

    if (scored.isEmpty) {
      // 纯黑白灰封面：使用极低饱和冷炭黑，呈现纯净深灰黑质感
      final dom = palette.dominantColor?.color ?? const Color(0xFF18181C);
      final domHsl = HSLColor.fromColor(dom);
      final mono = HSLColor.fromAHSL(
        1.0,
        domHsl.hue,
        domHsl.saturation.clamp(0.0, 0.08),
        0.14,
      );
      return (mono, mono);
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    var primary = scored.first.hsl;
    // 若最佳色仍落在容易显脏的黄绿区间（42°~66°），将色相温和向暖金/琥珀（28°）收敛
    if (primary.hue >= 42.0 && primary.hue <= 66.0) {
      primary = primary.withHue(28.0 + (primary.hue - 42.0) * 0.35);
    }

    HSLColor secondary = primary;
    for (int i = 1; i < scored.length; i++) {
      final cand = scored[i].hsl;
      final hueDiff = (cand.hue - primary.hue).abs();
      final wrappedDiff = hueDiff > 180.0 ? 360.0 - hueDiff : hueDiff;
      if (wrappedDiff >= 18.0 ||
          (cand.lightness - primary.lightness).abs() >= 0.15) {
        secondary = cand;
        if (secondary.hue >= 42.0 && secondary.hue <= 66.0) {
          secondary = secondary.withHue(26.0 + (secondary.hue - 42.0) * 0.35);
        }
        break;
      }
    }

    return (primary, secondary);
  }

  void _recomputeFromRaw() {
    final pHsl = _rawPrimaryHsl;
    final sHsl = _rawSecondaryHsl ?? pHsl;
    if (pHsl == null || sHsl == null) {
      _currentPalette = YtSongPalette.fallback;
      return;
    }

    final isMono = pHsl.saturation < 0.10;
    final k = _intensity;

    final topSat = isMono
        ? pHsl.saturation
        : (pHsl.saturation * 0.72 * k).clamp(0.22, 0.68).toDouble();
    final topLight = isMono
        ? (0.14 * k).clamp(0.08, 0.20).toDouble()
        : (0.21 * k).clamp(0.11, 0.28).toDouble();

    final midSat = isMono
        ? sHsl.saturation
        : (sHsl.saturation * 0.58 * k).clamp(0.16, 0.54).toDouble();
    final midLight = isMono
        ? (0.09 * k).clamp(0.05, 0.14).toDouble()
        : (0.125 * k).clamp(0.07, 0.18).toDouble();

    final botSat = isMono
        ? pHsl.saturation
        : (pHsl.saturation * 0.42 * k).clamp(0.10, 0.38).toDouble();
    const botLight = 0.042;

    final miniSat = isMono
        ? pHsl.saturation
        : (pHsl.saturation * 0.48 * k).clamp(0.14, 0.44).toDouble();
    final miniLight = (0.068 * k).clamp(0.045, 0.095).toDouble();

    final drawerTopSat = isMono
        ? pHsl.saturation
        : (pHsl.saturation * 0.48 * k).clamp(0.16, 0.46).toDouble();
    final drawerTopLight = (0.118 * k).clamp(0.08, 0.16).toDouble();

    final drawerBotSat = isMono
        ? sHsl.saturation
        : (sHsl.saturation * 0.38 * k).clamp(0.10, 0.36).toDouble();
    final drawerBotLight = (0.056 * k).clamp(0.038, 0.085).toDouble();

    final borderColor = HSLColor.fromAHSL(
      0.16,
      pHsl.hue,
      (topSat * 0.7).clamp(0.0, 0.5),
      0.65,
    ).toColor();

    _currentPalette = YtSongPalette(
      playerTopGlow: HSLColor.fromAHSL(
        1.0,
        pHsl.hue,
        topSat,
        topLight,
      ).toColor(),
      playerMidTone: HSLColor.fromAHSL(
        1.0,
        sHsl.hue,
        midSat,
        midLight,
      ).toColor(),
      playerBottomBase: HSLColor.fromAHSL(
        1.0,
        pHsl.hue,
        botSat,
        botLight,
      ).toColor(),
      miniBarBg: HSLColor.fromAHSL(
        1.0,
        pHsl.hue,
        miniSat,
        miniLight,
      ).toColor(),
      drawerTop: HSLColor.fromAHSL(
        0.97,
        pHsl.hue,
        drawerTopSat,
        drawerTopLight,
      ).toColor(),
      drawerBottom: HSLColor.fromAHSL(
        0.985,
        sHsl.hue,
        drawerBotSat,
        drawerBotLight,
      ).toColor(),
      drawerBorder: borderColor,
    );
  }
}

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

  YtSongPalette _fromPalette = YtSongPalette.fallback;
  YtSongPalette _toPalette = YtSongPalette.fallback;

  @override
  void initState() {
    super.initState();
    _currentArtworkUri = widget.song.artworkUri;
    _currentLocalPath = widget.song.localPath;
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      value: 1.0,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOutCubic,
    );
    YtPaletteTheme.instance.addListener(_onPaletteChanged);
    _fromPalette = YtPaletteTheme.instance.currentPalette;
    _toPalette = _fromPalette;
    unawaited(YtPaletteTheme.instance.updateForSong(widget.song));
  }

  void _onPaletteChanged() {
    if (!mounted) return;
    final next = YtPaletteTheme.instance.currentPalette;
    setState(() {
      _fromPalette = YtSongPalette.lerp(
        _fromPalette,
        _toPalette,
        _fadeAnimation.value,
      );
      _toPalette = next;
    });
    _fadeController.forward(from: 0.0);
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
      unawaited(YtPaletteTheme.instance.updateForSong(widget.song));
    }
  }

  @override
  void dispose() {
    YtPaletteTheme.instance.removeListener(_onPaletteChanged);
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
            key: ValueKey(
              'yt_bg_prev_${_previousArtworkUri}_$_previousLocalPath',
            ),
            artworkUri: _previousArtworkUri,
            fallbackFilePath: _previousLocalPath,
            isFill: true,
            fit: BoxFit.cover,
            backgroundColor: Colors.black,
            iconColor: Colors.white24,
          ),
        if (hasCurr)
          FadeTransition(
            opacity: hasPrev
                ? _fadeAnimation
                : const AlwaysStoppedAnimation(1.0),
            child: PlayerArtworkImage(
              key: ValueKey(
                'yt_bg_curr_${_currentArtworkUri}_$_currentLocalPath',
              ),
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

  Widget _buildYtOriginalGradientLayer(YtSongPalette palette) {
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.46, 0.82, 1.0],
              colors: [
                palette.playerTopGlow,
                palette.playerMidTone,
                Color.lerp(palette.playerMidTone, palette.playerBottomBase, 0.65)!,
                palette.playerBottomBase,
              ],
            ),
          ),
        ),
        // 封面中心偏上的柔和环境光晕，复刻原版 YT Music 封面四周的深色氛围扩散
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0.0, -0.28),
              radius: 0.92,
              colors: [
                palette.playerTopGlow.withValues(alpha: 0.58),
                palette.playerMidTone.withValues(alpha: 0.18),
                Colors.transparent,
              ],
              stops: const [0.0, 0.58, 1.0],
            ),
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
        listenable: Listenable.merge([
          LyricPreferences.instance,
          YtPaletteTheme.instance,
          _fadeAnimation,
        ]),
        builder: (context, _) {
          final useFlowing = LyricPreferences.instance.useFlowingBackground;
          final mode = YtPaletteTheme.instance.renderMode;
          final palette = YtSongPalette.lerp(
            _fromPalette,
            _toPalette,
            _fadeAnimation.value,
          );

          return Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF050508)),
              if (useFlowing)
                FlowingBackground(
                  artworkUrl: widget.song.artworkUri,
                  isPlaying: widget.isPlaying,
                  playingStream: AudioService().playingStream,
                )
              else if (mode == YtBgRenderMode.ytOriginal)
                _buildYtOriginalGradientLayer(palette)
              else if (mode == YtBgRenderMode.ytHybrid) ...[
                _buildYtOriginalGradientLayer(palette),
                Positioned.fill(
                  child: Opacity(
                    opacity: 0.24,
                    child: RepaintBoundary(
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(
                          sigmaX: math.max(55.0, blurSigma),
                          sigmaY: math.max(55.0, blurSigma),
                          tileMode: TileMode.clamp,
                        ),
                        child: _buildBlurredArtworkStack(),
                      ),
                    ),
                  ),
                ),
              ] else ...[
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
              ],
              if (widget.useArtistPhoto && widget.song.isOnline)
                ArtistPhotoBackground(hash: widget.song.id),
            ],
          );
        },
      ),
    );
  }
}

/// 设置页「YouTube Music 专属背景与色彩渲染」配置卡片
/// （挂在「设置 → 播放页样式」与「设置 → 播放页样式 → 播放页背景」中）
class YtPlayerBackgroundSettingsCard extends StatelessWidget {
  const YtPlayerBackgroundSettingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ListenableBuilder(
      listenable: YtPaletteTheme.instance,
      builder: (context, _) {
        final ytTheme = YtPaletteTheme.instance;
        final mode = ytTheme.renderMode;
        final syncDrawers = ytTheme.syncDrawers;
        final intensity = ytTheme.intensity;

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.6),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.palette_outlined,
                    size: 20,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'YouTube Music 专属背景渲染',
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '按原版 YT Music 逻辑从封面提取主色调，过滤脏暗与过曝色块并在 HSL 空间压暗生成深色氛围渐变',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildModeChip(
                    context: context,
                    label: 'YT 原版取色渐变',
                    selected: mode == YtBgRenderMode.ytOriginal,
                    onTap: () {
                      AppHaptics.lightImpact(HapticCategory.control);
                      ytTheme.setRenderMode(YtBgRenderMode.ytOriginal);
                    },
                  ),
                  _buildModeChip(
                    context: context,
                    label: '取色 + 柔光混合',
                    selected: mode == YtBgRenderMode.ytHybrid,
                    onTap: () {
                      AppHaptics.lightImpact(HapticCategory.control);
                      ytTheme.setRenderMode(YtBgRenderMode.ytHybrid);
                    },
                  ),
                  _buildModeChip(
                    context: context,
                    label: '传统封面模糊',
                    selected: mode == YtBgRenderMode.classicBlur,
                    onTap: () {
                      AppHaptics.lightImpact(HapticCategory.control);
                      ytTheme.setRenderMode(YtBgRenderMode.classicBlur);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '歌曲页与抽屉同步 YT 深色取色',
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '让相关内容、歌曲百科、歌词、歌手档案与接下来播放面板同步使用封面深色色板，防止亮色封面透出杂色',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                value: syncDrawers,
                onChanged: (v) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  ytTheme.setSyncDrawers(v);
                },
              ),
              if (mode != YtBgRenderMode.classicBlur || syncDrawers) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '取色氛围浓郁度',
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${(intensity * 100).round()}%',
                      style: textTheme.labelMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                M3ESlider(
                  decoration: const M3ESliderDecoration(
                    haptic: M3EHapticFeedback.light,
                    hapticConfig: M3EHapticConfig.discrete(),
                  ),
                  value: intensity,
                  min: 0.4,
                  max: 1.4,
                  divisions: 20,
                  label: '${(intensity * 100).round()}%',
                  onChanged: (v) => ytTheme.setIntensity(v),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildModeChip({
    required BuildContext context,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? colorScheme.primary : colorScheme.outlineVariant,
            width: selected ? 1.4 : 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
