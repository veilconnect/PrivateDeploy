import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';
import 'package:privatedeploy_mobile/main.dart' as app;
import 'package:privatedeploy_mobile/services/vpn_native_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('com.privatedeploy.vpn/native');
  late VpnProvider vpnProvider;
  late _NativeVpnHarness native;

  setUp(() {
    native = _NativeVpnHarness();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, native.handle);
    vpnProvider = VpnProvider(fetchEgressIp: () async => '203.0.113.42');
  });

  tearDown(() async {
    vpnProvider.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    await VpnNativeService.instance.dispose();
  });

  test('AutoCDN cold-connects rebuilt config when no tunnel is running',
      () async {
    final applied = await app.applyAutoCdnRebuiltConfig(
      vpnProvider: vpnProvider,
      rebuiltConfig: '{"outbounds":[{"type":"direct","tag":"rebuilt"}]}',
      profileName: 'Cloud: rebuilt',
    );

    expect(applied, isTrue);
    expect(native.stopCalls, 0);
    expect(native.startedConfigs, [
      '{"outbounds":[{"type":"direct","tag":"rebuilt"}]}',
    ]);
    expect(vpnProvider.activeProfile, 'Cloud: rebuilt');
  });

  test('AutoCDN swaps a connected tunnel before applying rebuilt config',
      () async {
    expect(
      await vpnProvider.connect(
        configJson: '{"outbounds":[{"type":"direct","tag":"old"}]}',
        profileName: 'Cloud: old',
      ),
      isTrue,
    );

    final applied = await app.applyAutoCdnRebuiltConfig(
      vpnProvider: vpnProvider,
      rebuiltConfig: '{"outbounds":[{"type":"direct","tag":"rebuilt-cdn"}]}',
      profileName: 'Cloud: rebuilt',
    );

    expect(applied, isTrue);
    expect(native.stopCalls, 1);
    expect(native.startedConfigs, [
      '{"outbounds":[{"type":"direct","tag":"old"}]}',
      '{"outbounds":[{"type":"direct","tag":"rebuilt-cdn"}]}',
    ]);
    expect(vpnProvider.activeProfile, 'Cloud: rebuilt');
  });

  test('AutoCDN reports failure when a connected tunnel cannot be swapped',
      () async {
    expect(
      await vpnProvider.connect(
        configJson: '{"outbounds":[{"type":"direct","tag":"old"}]}',
        profileName: 'Cloud: old',
      ),
      isTrue,
    );
    native.stopSucceeds = false;

    final applied = await app.applyAutoCdnRebuiltConfig(
      vpnProvider: vpnProvider,
      rebuiltConfig: '{"outbounds":[{"type":"direct","tag":"rebuilt-cdn"}]}',
      profileName: 'Cloud: rebuilt',
    );

    expect(applied, isFalse);
    expect(native.stopCalls, 1);
    expect(native.startedConfigs, [
      '{"outbounds":[{"type":"direct","tag":"old"}]}',
    ]);
    expect(vpnProvider.isConnected, isTrue);
    expect(vpnProvider.activeProfile, 'Cloud: old');
  });

  test('failed AutoCDN apply keeps the CDN guidance visible', () async {
    expect(
      await vpnProvider.connect(
        configJson: '{"outbounds":[{"type":"direct","tag":"old"}]}',
        profileName: 'Cloud: old',
      ),
      isTrue,
    );
    native.stopSucceeds = false;
    vpnProvider.setOnAutoCdnDeployRequest(
      (_) => app.applyAutoCdnRebuiltConfig(
        vpnProvider: vpnProvider,
        rebuiltConfig: '{"outbounds":[{"type":"direct","tag":"rebuilt-cdn"}]}',
        profileName: 'Cloud: old',
      ),
    );

    vpnProvider.debugApplyNativeStatus(VpnNativeStatus(
      running: true,
      status: 'connected',
      message: VpnProvider.cellularCarrierSynBlockMessage,
      connectedAt: 123,
      uptime: 5,
    ));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(native.stopCalls, 1);
    expect(vpnProvider.needsCdnGuidance, isTrue);
    expect(vpnProvider.isConnected, isTrue);
  });
}

class _NativeVpnHarness {
  bool running = false;
  bool stopSucceeds = true;
  int stopCalls = 0;
  final List<String> startedConfigs = [];

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'startVpn':
        final arguments = Map<Object?, Object?>.from(call.arguments as Map);
        startedConfigs.add(arguments['config']! as String);
        running = true;
        return true;
      case 'stopVpn':
        stopCalls += 1;
        if (stopSucceeds) {
          running = false;
        }
        return stopSucceeds;
      case 'getStatus':
        return <String, Object?>{
          'running': running,
          'status': running ? 'connected' : 'disconnected',
          'message': null,
          'connected_at': running ? 123 : 0,
          'uptime': running ? 5 : 0,
        };
      case 'isRunning':
        return running;
      case 'getStats':
        return <String, Object>{
          'upload_bytes': 0,
          'download_bytes': 0,
          'upload_speed': 0,
          'download_speed': 0,
        };
      case 'getRecentLogs':
        return const <Object>[];
      case 'getEgressIp':
        return <String, Object?>{
          'ip': '203.0.113.42',
          'source': 'test',
          'error': null,
        };
      default:
        return null;
    }
  }
}
