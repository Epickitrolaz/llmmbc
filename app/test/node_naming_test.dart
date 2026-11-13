import 'package:app/services/node_naming.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveNodeName', () {
    test('prefers the Android device model', () {
      expect(resolveNodeName(deviceName: 'Pixel 8', hostname: 'localhost'), 'Pixel 8');
      expect(resolveNodeName(deviceName: 'sdk_gphone64_x86_64', hostname: 'emulator'), 'sdk_gphone64_x86_64');
    });

    test('falls back to a real hostname', () {
      expect(resolveNodeName(deviceName: null, hostname: 'studio-pc'), 'studio-pc');
      expect(resolveNodeName(deviceName: '  ', hostname: 'pi5'), 'pi5');
    });

    test('never returns a generic name', () {
      expect(resolveNodeName(deviceName: 'localhost', hostname: 'localhost'), 'LLMMBC node');
      expect(resolveNodeName(deviceName: null, hostname: null), 'LLMMBC node');
      expect(resolveNodeName(deviceName: 'unknown', hostname: 'unset'), 'LLMMBC node');
    });
  });

  group('isGenericNodeName', () {
    test('flags localhost-like defaults only', () {
      expect(isGenericNodeName('localhost'), isTrue);
      expect(isGenericNodeName(' LOCALHOST '), isTrue);
      expect(isGenericNodeName(''), isTrue);
      expect(isGenericNodeName('llmmbc-node'), isTrue);
      expect(isGenericNodeName('Poco X6 Pro'), isFalse);
      expect(isGenericNodeName('studio-pc'), isFalse);
    });
  });
}
