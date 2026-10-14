import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const PlayerDemoApp());

/// 可直接将本文件复制到一个新 Flutter 项目的 lib/main.dart。
class PlayerDemoApp extends StatelessWidget {
  const PlayerDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Music Player',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          onPrimary: Colors.black,
          surface: Color(0xFF121212),
          onSurface: Colors.white,
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(foregroundColor: Colors.white),
        ),
        splashFactory: InkRipple.splashFactory,
      ),
      home: const YoutubeMusicPlayerPage(),
    );
  }
}

/// 独立的 UI 示例，不初始化音频引擎，也不会实际播放音频或视频。
/// 外部可以传入 AssetImage / NetworkImage 替换内置封面占位图。
class YoutubeMusicPlayerPage extends StatefulWidget {
  const YoutubeMusicPlayerPage({
    super.key,
    this.title = '夜空中最亮的星',
    this.artist = '逃跑计划',
    this.source = '赞过的音乐',
    this.coverImage,
  });

  final String title;
  final String artist;
  final String source;
  final ImageProvider<Object>? coverImage;

  @override
  State<YoutubeMusicPlayerPage> createState() => _YoutubeMusicPlayerPageState();
}

class _YoutubeMusicPlayerPageState extends State<YoutubeMusicPlayerPage> {
  static const _background = Color(0xFF121212);
  static const _secondary = Color(0xFFAAAAAA);
  static const _pillColor = Color(0x14FFFFFF);
  static const _duration = 240.0;

  bool _video = false;
  bool _playing = true;
  bool _shuffle = false;
  bool _repeat = false;
  bool _saved = false;
  int _rating = 0;
  double _position = 7;

  String _time(double seconds) {
    final value = seconds.round();
    return '${value ~/ 60}:${(value % 60).toString().padLeft(2, '0')}';
  }

  void _notice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showPanel(String title, String content) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF222222),
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 22)),
              const SizedBox(height: 16),
              Text(
                content,
                style: const TextStyle(color: _secondary, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: _background,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: _background,
        body: SafeArea(
          child: Center(
            // 平板/桌面保持移动端比例，不将封面拉满整个窗口。
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 常规手机一屏展示；短屏优先保留正方形封面和触控区域，
                  // 再允许纵向滚动。大字体不裁切，也不强制关闭系统文字缩放。
                  final coverSize = math.min(
                    math.max(0.0, constraints.maxWidth - 48),
                    math.max(216.0, constraints.maxHeight - 508),
                  );
                  return SingleChildScrollView(
                    key: const ValueKey('player-scroll'),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: IntrinsicHeight(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildTopBar(),
                              const SizedBox(height: 16),
                              Center(child: _buildCover(coverSize)),
                              const SizedBox(height: 24),
                              _buildSongInfo(),
                              const SizedBox(height: 16),
                              _buildActions(),
                              const SizedBox(height: 12),
                              _buildProgress(),
                              const SizedBox(height: 8),
                              _buildControls(),
                              const SizedBox(height: 16),
                              const Spacer(),
                              _buildSource(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return SizedBox(
      height: 48,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            tooltip: '收起播放器',
            icon: const Icon(Icons.keyboard_arrow_down, size: 30),
            onPressed: () async {
              final navigator = Navigator.of(context);
              if (navigator.canPop()) {
                await navigator.maybePop();
              } else {
                _notice('当前为独立播放页，无可返回的页面');
              }
            },
          ),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xFF202020),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              children: [
                _modeButton(false, Icons.headphones, '音频'),
                _modeButton(true, Icons.videocam_outlined, '视频'),
              ],
            ),
          ),
          IconButton(
            tooltip: '更多操作',
            icon: const Icon(Icons.more_vert, size: 26),
            onPressed: () => _showPanel(
              '更多操作',
              '${widget.title}\n${widget.artist}\n\n这是独立 UI 示例，尚未连接音频服务。',
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeButton(bool video, IconData icon, String label) {
    final selected = _video == video;
    return Semantics(
      selected: selected,
      child: Material(
        color: selected ? const Color(0xFF414141) : Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _video = video),
          child: Tooltip(
            message: label,
            child: SizedBox(
              width: 56,
              height: 36,
              child: Icon(
                icon,
                size: 22,
                color: selected ? Colors.white : _secondary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCover(double size) {
    const placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF414C59), Color(0xFF252A35), Color(0xFF171B24)],
        ),
      ),
      child: Center(
        child: Icon(Icons.music_note_rounded, size: 88, color: Color(0xFF949BA6)),
      ),
    );
    return Semantics(
      image: true,
      label: '${widget.title}，专辑封面',
      child: ClipRRect(
        key: const ValueKey('album-cover'),
        borderRadius: BorderRadius.circular(16),
        child: SizedBox.square(
          dimension: size,
          child: widget.coverImage == null
              ? placeholder
              : Image(
                  image: widget.coverImage!,
                  fit: BoxFit.cover,
                  excludeFromSemantics: true,
                  errorBuilder: (context, error, stackTrace) => placeholder,
                ),
        ),
      ),
    );
  }

  Widget _buildSongInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.chevron_right, size: 24, color: Color(0xFFCCCCCC)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          widget.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, height: 1.1, color: _secondary),
        ),
      ],
    );
  }

  Widget _buildActions() {
    return SingleChildScrollView(
      key: const ValueKey('action-scroll'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          Material(
            color: _pillColor,
            borderRadius: BorderRadius.circular(24),
            clipBehavior: Clip.antiAlias,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _pillContent(
                  icon: _rating == 1 ? Icons.thumb_up : Icons.thumb_up_outlined,
                  label: _rating == 1 ? '1.2万 +1' : '1.2万',
                  tooltip: '点赞',
                  selected: _rating == 1,
                  onTap: () => setState(() => _rating = _rating == 1 ? 0 : 1),
                ),
                Container(width: 1, height: 18, color: const Color(0xFF555555)),
                _pillContent(
                  icon: _rating == -1 ? Icons.thumb_down : Icons.thumb_down_outlined,
                  tooltip: '点踩',
                  selected: _rating == -1,
                  onTap: () => setState(() => _rating = _rating == -1 ? 0 : -1),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _pill(
            Icons.lyrics_outlined,
            '歌词',
            () => _showPanel('歌词', '尚未提供歌词数据。'),
          ),
          const SizedBox(width: 8),
          _pill(
            _saved ? Icons.playlist_add_check : Icons.playlist_add,
            _saved ? '已保存' : '保存到歌单',
            () => setState(() => _saved = !_saved),
          ),
          const SizedBox(width: 8),
          _pill(Icons.share_outlined, '分享', () async {
            await Clipboard.setData(
              ClipboardData(text: '${widget.title} — ${widget.artist}'),
            );
            if (mounted) _notice('歌曲信息已复制，可粘贴分享');
          }),
        ],
      ),
    );
  }

  Widget _pill(IconData icon, String label, VoidCallback onTap) {
    return Material(
      color: _pillColor,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: _pillContent(icon: icon, label: label, tooltip: label, onTap: onTap),
    );
  }

  Widget _pillContent({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    String? label,
    bool? selected,
  }) {
    return Semantics(
      selected: selected,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40, minWidth: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 19, color: Colors.white),
                  if (label != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgress() {
    return Column(
      children: [
        SizedBox(
          height: 24,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              activeTrackColor: Colors.white,
              inactiveTrackColor: const Color(0xFF454545),
              thumbColor: Colors.white,
              overlayColor: const Color(0x1FFFFFFF),
              trackShape: const RectangularSliderTrackShape(),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 3),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              showValueIndicator: ShowValueIndicator.never,
            ),
            child: Slider(
              value: _position,
              min: 0,
              max: _duration,
              semanticFormatterCallback: (value) => '已播放 ${_time(value)}，共 4:00',
              onChanged: (value) => setState(() => _position = value),
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _time(_position),
              style: const TextStyle(
                color: _secondary,
                fontSize: 11,
                height: 1.4,
              ),
            ),
            Text(
              _time(_duration),
              style: const TextStyle(
                color: _secondary,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _toggleControl(
          Icons.shuffle,
          '随机播放',
          _shuffle,
          () => setState(() => _shuffle = !_shuffle),
        ),
        IconButton(
          tooltip: '上一首',
          icon: const Icon(Icons.skip_previous, size: 36),
          onPressed: () => _notice('示例只有一首歌曲，暂无上一首'),
        ),
        Semantics(
          button: true,
          label: _playing ? '暂停' : '播放',
          child: Tooltip(
            message: _playing ? '暂停' : '播放',
            child: Material(
              color: Colors.white,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => setState(() => _playing = !_playing),
                child: SizedBox.square(
                  dimension: 72,
                  child: Icon(
                    _playing ? Icons.pause : Icons.play_arrow,
                    size: 38,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: '下一首',
          icon: const Icon(Icons.skip_next, size: 36),
          onPressed: () => _notice('示例只有一首歌曲，暂无下一首'),
        ),
        _toggleControl(
          Icons.repeat,
          '循环播放',
          _repeat,
          () => setState(() => _repeat = !_repeat),
        ),
      ],
    );
  }

  Widget _toggleControl(
    IconData icon,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    return Semantics(
      toggled: selected,
      child: IconButton(
        tooltip: label,
        onPressed: onTap,
        icon: SizedBox.square(
          dimension: 24,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(icon, size: 24, color: selected ? Colors.white : _secondary),
              Positioned(
                bottom: -5,
                left: 10.5,
                child: Container(
                  width: 3,
                  height: 3,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? Colors.white : Colors.transparent,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSource() {
    return Semantics(
      button: true,
      label: '播放列表：${widget.source}',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showPanel(widget.source, '${widget.title} — ${widget.artist}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF666666),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                widget.source,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _secondary, fontSize: 12, height: 1.3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
