import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/widgets/resizable_splitter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows 双栏默认关闭，显式开启后可读回', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    expect(await repo.getWindowsTwoPaneEnabled(), isFalse);
    await repo.setWindowsTwoPaneEnabled(true);
    expect(await repo.getWindowsTwoPaneEnabled(), isTrue);
  });

  for (final responsive in [false, true]) {
    testWidgets('Windows responsive=$responsive 默认等分且关闭可保留详情栈',
        (tester) async {
      kWindowsTwoPaneEnabled.value = true;
      addTearDown(() => kWindowsTwoPaneEnabled.value = true);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 900);
      addTearDown(tester.view.reset);
      final detailKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        home: DesktopTwoPane(
          responsive: responsive,
          detailKey: detailKey,
          master: const SizedBox.expand(key: Key('windows-master')),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const Key('windows-master'))).width, 792);
      expect(tester.getSize(find.byKey(const ValueKey('responsive-detail'))).width,
          792);

      detailKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Center(child: Text('保留的详情')),
      ));
      await tester.pumpAndSettle();
      final navigator = detailKey.currentState;
      kWindowsTwoPaneEnabled.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(ResizableSplitter), findsNothing);
      expect(find.text('保留的详情'), findsOneWidget);
      expect(detailKey.currentState, same(navigator));
      expect(tester.getSize(find.byKey(const ValueKey('responsive-detail'))).width,
          1600);
      detailKey.currentState!.pop();
      await tester.pumpAndSettle();
      final masterBounds = tester.widget<Positioned>(find.ancestor(
        of: find.byKey(const Key('windows-master')),
        matching: find.byType(Positioned),
      ).first);
      expect(masterBounds.width, 1600);
      expect(find.text('从左侧选择一项查看详情'), findsNothing);

      kWindowsTwoPaneEnabled.value = true;
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const Key('windows-master'))).width, 792);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  testWidgets('Windows 关闭双栏不改变 Android 宽屏分栏', (tester) async {
    kWindowsTwoPaneEnabled.value = false;
    addTearDown(() => kWindowsTwoPaneEnabled.value = true);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: DesktopTwoPane(
        responsive: true,
        master: SizedBox.expand(key: Key('android-master')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('android-master'))).width, 544);
    expect(find.byType(ResizableSplitter), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
