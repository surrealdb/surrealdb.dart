import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

void main() {
  test('each connect and close is published once', () async {
    final db = Surreal();
    final statuses = <ConnectionStatus>[];
    final subscription = db.statusChanges.listen(statuses.add);

    for (var i = 0; i < 2; i++) {
      // The HTTP engine does not reach the server until the first request.
      await db.connect('http://127.0.0.1:9/rpc',
          options: const ConnectOptions(versionCheck: false));
      await db.close();
    }
    await Future<void>.delayed(Duration.zero);

    expect(statuses, [
      ConnectionStatus.connected,
      ConnectionStatus.disconnected,
      ConnectionStatus.connected,
      ConnectionStatus.disconnected,
    ]);
    await subscription.cancel();
  });
}
