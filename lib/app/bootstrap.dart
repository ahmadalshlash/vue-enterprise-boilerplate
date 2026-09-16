import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/ble/ble_transport.dart';
import '../core/ble/fake_transport.dart';
import '../core/ble/transport.dart';
import '../core/crypto/key_store.dart';
import '../core/services/engine.dart';
import '../core/storage/app_database.dart';
import '../demo/demo_world.dart';
import 'permissions.dart';

/// Demo-Modus: `flutter run --dart-define=UMKREIS_DEMO=true`. Im Web immer an,
/// weil Browser kein BLE-Peripheral können.
const bool kDemoFlag = bool.fromEnvironment('UMKREIS_DEMO', defaultValue: false);
bool get isDemoMode => kIsWeb || kDemoFlag;

/// Alles, was die App zum Laufen braucht.
class AppContext {
  AppContext({required this.engine, required this.keyStore, this.demo});
  final Engine engine;
  final KeyStore keyStore;
  final DemoWorld? demo;
}

Future<AppContext> bootstrap() async {
  if (isDemoMode) {
    final demo = DemoWorld();
    final transport = demo.createUserTransport();
    final keyStore = InMemoryKeyStore();
    final engine = await Engine.create(
      transport: transport,
      db: await AppDatabase.openMemory(),
      keyStore: keyStore,
    );
    await demo.start();
    return AppContext(engine: engine, keyStore: keyStore, demo: demo);
  }

  final dir = await getApplicationSupportDirectory();
  final db = await AppDatabase.openFile('${dir.path}/umkreis.db');
  final keyStore = SecureKeyStore();
  final NearbyTransport transport = BleTransport();
  final engine = await Engine.create(transport: transport, db: db, keyStore: keyStore);
  return AppContext(engine: engine, keyStore: keyStore);
}

/// Für Tests: Engine über eine FakeWorld.
Future<AppContext> bootstrapForTest(FakeWorld world, {String id = 'me'}) async {
  BluetoothPermissions.requestOverride = () async => true;
  final keyStore = InMemoryKeyStore();
  final engine = await Engine.create(
    transport: world.createNode(id),
    db: await AppDatabase.openMemory(),
    keyStore: keyStore,
  );
  return AppContext(engine: engine, keyStore: keyStore);
}
