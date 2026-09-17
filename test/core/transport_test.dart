import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umkreis/core/ble/fake_transport.dart';
import 'package:umkreis/core/ble/transport.dart';

void main() {
  test('FakeWorld delivers sightings with distance-based RSSI and chunked frames', () async {
    final world = FakeWorld(fakeMtu: 30);
    final a = world.createNode('a');
    final b = world.createNode('b', x: 2);
    final far = world.createNode('far', x: 500);
    await a.start();
    await b.start();
    await far.start();
    await a.setAdvertising(Uint8List.fromList(List.filled(8, 1)));
    await b.setAdvertising(Uint8List.fromList(List.filled(8, 2)));
    await far.setAdvertising(Uint8List.fromList(List.filled(8, 3)));

    final seenByA = <Sighting>[];
    a.sightings.listen(seenByA.add);
    world.broadcast();
    await Future<void>.delayed(Duration.zero);
    expect(seenByA.map((s) => s.peerId), ['f:b']);
    expect(seenByA.single.rssi, greaterThan(-65));

    b.setProviders(TransportProviders(
      presence: () => Uint8List.fromList([9, 9]),
      profile: () => Uint8List(0),
      board: () => Uint8List(0),
    ));
    expect(await a.read('f:b', ReadTarget.presence), [9, 9]);

    final received = <InboundFrame>[];
    b.inbound.listen(received.add);
    final big = Uint8List.fromList(List.generate(300, (i) => i % 256));
    await a.send('f:b', big);
    await Future<void>.delayed(Duration.zero);
    expect(received.single.peerId, 'f:a');
    expect(received.single.bytes, big);

    expect(() => a.send('f:far', big), throwsA(isA<TransportException>()));
  });
}
