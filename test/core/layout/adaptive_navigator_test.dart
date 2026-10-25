import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/widgets/resizable_splitter.dart';

void main() {
  group('DetailEmptyState', () {
    testWidgets('默认参数渲染桌面外壳原文案与图标（行为不变）', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: DetailEmptyState()));
      await tester.pumpAndSettle();

      expect(find.text('从左侧选择一项查看详情'), findsOneWidget);
      expect(find.byIcon(Icons.library_music_outlined), findsOneWidget);
    });

    testWidgets('自定义图标与文案（设置页空态复用）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DetailEmptyState(
            icon: Icons.tune,
            text: '从左侧选择分类进行配置',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('从左侧选择分类进行配置'), findsOneWidget);
      expect(find.byIcon(Icons.tune), findsOneWidget);
    });
  });

  testWidgets('Windows 自定义背景下空详情透明且不绘制分隔线', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    // 上游 2026-10-24 起 Windows 双栏默认关闭（kWindowsTwoPaneEnabled=false）；
    // 本用例验证的是「双栏空详情在自定义背景下的透明度契约」，需显式开启。
    final bool previousTwoPane = kWindowsTwoPaneEnabled.value;
    kWindowsTwoPaneEnabled.value = true;
    addTearDown(() => kWindowsTwoPaneEnabled.value = previousTwoPane);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(scaffoldBackgroundColor: Colors.transparent),
      home: DesktopTwoPane(responsive: true, master: const SizedBox()),
    ));
    await tester.pumpAndSettle();

    final empty = tester.widget<DetailEmptyState>(find.byType(DetailEmptyState));
    expect(empty.color, Colors.transparent);
    expect(tester.widget<ResizableSplitter>(find.byType(ResizableSplitter)).color,
        Colors.transparent);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android 分栏保持原有空详情背景和分隔线', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(scaffoldBackgroundColor: Colors.transparent),
      home: DesktopTwoPane(responsive: true, master: const SizedBox()),
    ));
    await tester.pumpAndSettle();

    final empty = tester.widget<DetailEmptyState>(find.byType(DetailEmptyState));
    expect(empty.color, isNull);
    expect(tester.widget<ResizableSplitter>(find.byType(ResizableSplitter)).color,
        isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
