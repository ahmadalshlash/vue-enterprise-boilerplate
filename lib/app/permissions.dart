import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Laufzeit-Berechtigungen für Bluetooth. iOS fragt selbst über
/// CoreBluetooth; Android braucht explizite Anfragen (ab 12: Scan,
/// Advertise, Connect; darunter: Standort für BLE-Scan).
class BluetoothPermissions {
  BluetoothPermissions._();

  /// Für Tests/Demo: ersetzt den Plugin-Aufruf.
  static Future<bool> Function()? requestOverride;

  static Future<bool> request() async {
    final override = requestOverride;
    if (override != null) return override();
    if (kIsWeb) return true;
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _requestAndroid();
    } catch (e) {
      // Plugin nicht verfügbar (z. B. in Tests) → wie „abgelehnt“ behandeln.
      debugPrint('Permissions: $e');
      return false;
    }
  }

  static Future<bool> _requestAndroid() async {
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ].request();
    var ok = results.values.every((s) => s.isGranted || s.isLimited);
    if (!ok) {
      // Android < 12 kennt die neuen Berechtigungen nicht und meldet sie
      // als „restricted/permanentlyDenied“; dort zählt nur der Standort.
      final loc = await Permission.locationWhenInUse.request();
      ok = loc.isGranted || results.values.any((s) => s.isGranted);
    }
    return ok;
  }

  static Future<bool> granted() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _grantedAndroid();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _grantedAndroid() async {
    final scan = await Permission.bluetoothScan.status;
    final adv = await Permission.bluetoothAdvertise.status;
    final con = await Permission.bluetoothConnect.status;
    if (scan.isGranted && adv.isGranted && con.isGranted) return true;
    return (await Permission.locationWhenInUse.status).isGranted;
  }

  static Future<void> openSettings() => openAppSettings();
}
