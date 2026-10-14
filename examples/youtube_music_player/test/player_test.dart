import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_music_player_example/main.dart';

Future<void> pumpPlayer(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  String title = '夜空中最亮的星',
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 24, bottom: 24),
            textScaler: TextScaler.linear(textScale),
          ),
          child: YoutubeMusicPlayerPage(title: title),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('默认显示音频、暂停、初始时间和正方形圆角封面', (tester) async {
    await pumpPlayer(tester);
    expect(find.text('夜空中最亮的星'), findsOneWidget);
    expect(find.text('逃跑计划'), findsOneWidget);
    expect(find.text('0:07'), findsOneWidget);
    expect(find.text('4:00'), findsOneWidget);
    expect(find.text('赞过的音乐'), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    final cover = find.byKey(const ValueKey('album-cover'));
    final size = tester.getSize(cover);
    expect(size.width, size.height);
    expect(tester.widget<ClipRRect>(cover).borderRadius, BorderRadius.circular(16));
    final audioMaterial = tester.widget<Material>(
      find.ancestor(
        of: find.byTooltip('音频'),
        matching: find.byType(Material),
      ).first,
    );
    expect(audioMaterial.color, const Color(0xFF414141));
    expect(tester.takeException(), isNull);
  });

  testWidgets('暂停/播放切换，赞踩互斥且可取消', (tester) async {
    await pumpPlayer(tester);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    await tester.tap(find.byTooltip('播放'));
    await tester.pump();
    expect(find.byIcon(Icons.pause), findsOneWidget);

    await tester.tap(find.byTooltip('点赞'));
    await tester.pump();
    expect(find.byIcon(Icons.thumb_up), findsOneWidget);
    expect(find.text('1.2万 +1'), findsOneWidget);
    await tester.tap(find.byTooltip('点踩'));
    await tester.pump();
    expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
    expect(find.byIcon(Icons.thumb_down), findsOneWidget);
    await tester.tap(find.byTooltip('点踩'));
    await tester.pump();
    expect(find.byIcon(Icons.thumb_down_outlined), findsOneWidget);
  });

  testWidgets('进度可拖动，视频切换和随机/循环保留选中状态', (tester) async {
    await pumpPlayer(tester);
    final slider = find.byType(Slider);
    await tester.tapAt(tester.getCenter(slider));
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, closeTo(120, 1));

    await tester.tap(find.byTooltip('视频'));
    await tester.tap(find.byTooltip('随机播放'));
    await tester.tap(find.byTooltip('循环播放'));
    await tester.pump();
    final videoMaterial = tester.widget<Material>(
      find.ancestor(of: find.byTooltip('视频'), matching: find.byType(Material)).first,
    );
    expect(videoMaterial.color, const Color(0xFF414141));
    for (final icon in [Icons.shuffle, Icons.repeat]) {
      expect(tester.widget<Icon>(find.byIcon(icon)).color, Colors.white);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('胶囊横向滚动后可保存，歌词面板可打开', (tester) async {
    await pumpPlayer(tester);
    await tester.tap(find.text('歌词'));
    await tester.pumpAndSettle();
    expect(find.text('尚未提供歌词数据。'), findsOneWidget);
    // 点击 modal barrier，关闭歌词面板。
    await tester.tapAt(const Offset(10, 60));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('action-scroll')), const Offset(-220, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存到歌单'));
    await tester.pump();
    expect(find.text('已保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(430, 932),
    const Size(844, 390),
  ]) {
    testWidgets('$size 安全区、短屏/横屏无布局溢出且底部可达', (tester) async {
      await pumpPlayer(tester, size: size);
      final cover = tester.getSize(find.byKey(const ValueKey('album-cover')));
      expect(cover.width, cover.height);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('赞过的音乐'));
      await tester.pumpAndSettle();
      expect(find.text('赞过的音乐').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('长标题和两倍字号不溢出', (tester) async {
    await pumpPlayer(
      tester,
      textScale: 2,
      title: '这是一首具有非常长标题的歌曲，验证标题不会挤出边界',
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('赞过的音乐'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
