import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/theme_provider.dart';

void main() {
  test('PlayerStyle enum values test', () {
    expect(PlayerStyle.values.length, equals(3));
    expect(PlayerStyle.md3.name, equals('md3'));
    expect(PlayerStyle.appleMusic.name, equals('appleMusic'));
    expect(PlayerStyle.ytMusic.name, equals('ytMusic'));
  });
}
