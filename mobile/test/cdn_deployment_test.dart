import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cdn/cdn_provider.dart';

void main() {
  test('legacy deployment without revision requires Worker upgrade', () {
    final deployment = CdnDeployment.fromJson({
      'nodeId': 'node-1',
      'scriptName': 'pd-relay-node-1',
      'workerHost': 'pd-relay-node-1.example.workers.dev',
      'backend': '192.0.2.1:24444',
      'deployedAt': '2026-07-01T00:00:00Z',
    });

    expect(deployment.workerTemplateRevision, 0);
    expect(deployment.needsWorkerTemplateUpgrade, isTrue);
  });

  test('current Worker revision survives deployment serialization', () {
    final original = CdnDeployment(
      nodeId: 'node-1',
      scriptName: 'pd-relay-node-1',
      workerHost: 'pd-relay-node-1.example.workers.dev',
      backend: '192.0.2.1:24444',
      deployedAt: DateTime.utc(2026, 7, 14),
      workerTemplateRevision: CdnProvider.currentWorkerTemplateRevision,
    );

    final restored = CdnDeployment.fromJson(original.toJson());
    expect(
      restored.workerTemplateRevision,
      CdnProvider.currentWorkerTemplateRevision,
    );
    expect(restored.needsWorkerTemplateUpgrade, isFalse);
  });
}
