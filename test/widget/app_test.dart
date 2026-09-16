import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umkreis/app/app.dart';
import 'package:umkreis/app/bootstrap.dart';
import 'package:umkreis/core/ble/fake_transport.dart';
import 'package:umkreis/core/protocol/models.dart';
import 'package:umkreis/core/services/engine.dart';

/// Widget-Tests über eine FakeWorld: echte Engines, echte Screens.
///
/// Alles Asynchrone (DB, Krypto, Funk) läuft innerhalb der FakeAsync-Zone
/// des Testers und wird über [drive] mit Pump-Schritten vorangetrieben.
void main() {
  late FakeWorld world;
  late AppContext me;
  late AppContext other;

  setUp(() {
    world = FakeWorld(fakeMtu: 120);
  });

  /// Führt [action] aus und pumpt so lange, bis sie abgeschlossen ist.
  Future<void> drive(WidgetTester tester, Future<void> Function() action) async {
    var done = false;
    Object? error;
    action().then((_) => done = true, onError: (Object e) {
      error = e;
      done = true;
    });
    for (var i = 0; i < 200 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    if (error != null) throw error!;
    expect(done, true, reason: 'Aktion nicht abgeschlossen');
  }

  /// Engines müssen in derselben (Fake-)Zone entstehen wie der Test,
  /// sonst laufen ihre Futures im echten Event-Loop und der Tester wartet ewig.
  Future<void> setUpEngines(WidgetTester tester) => drive(tester, () async {
        me = await bootstrapForTest(world);
        other = await bootstrapForTest(world, id: 'other');
        world.moveTo('other', 3, 0);
      });

  Future<void> pumpWorld(WidgetTester tester, {int ticks = 8}) async {
    for (var i = 0; i < ticks; i++) {
      world.broadcast();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump();
  }

  /// Engines stoppen, damit keine Timer offen bleiben.
  Future<void> finish(WidgetTester tester) async {
    await drive(tester, () async {
      await me.engine.stop();
      await other.engine.stop();
    });
  }

  testWidgets('onboarding is shown first and leads to the radar', (tester) async {
    await setUpEngines(tester);
    await tester.pumpWidget(UmkreisApp(context: me));
    await tester.pumpAndSettle();
    expect(find.text('Leute in deiner Nähe'), findsOneWidget);

    await tester.tap(find.text('Weiter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weiter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bluetooth erlauben'));
    await tester.pumpAndSettle();
    expect(find.text('Du bist gerade'), findsOneWidget);
    expect(find.text(me.engine.identity.alias), findsOneWidget);

    await tester.tap(find.text('Erst mal anonym bleiben'));
    await tester.pumpAndSettle();
    expect(find.text('Niemand in Reichweite'), findsOneWidget);
    expect(me.engine.identity.onboardingDone, true);
    expect(me.engine.isRunning, true);
    await finish(tester);
  });

  testWidgets('radar lists a nearby peer with proximity and sends a request', (tester) async {
    await setUpEngines(tester);
    await drive(tester, () async {
      await me.engine.identity.completeOnboarding();
      await other.engine.identity.setStatus('Suche Mitfahrer nach Köln');
      await other.engine.identity.completeOnboarding();
      await other.engine.start();
    });

    await tester.pumpWidget(UmkreisApp(context: me));
    await tester.pumpAndSettle();
    await pumpWorld(tester);

    expect(find.text(other.engine.identity.alias), findsOneWidget);
    expect(find.text('Suche Mitfahrer nach Köln'), findsOneWidget);
    expect(find.text('sehr nah'), findsOneWidget);

    await tester.tap(find.text(other.engine.identity.alias));
    await tester.pumpAndSettle();
    expect(find.text('Nachricht senden'), findsWidgets);

    await tester.enterText(find.byType(TextField), 'Hallo!');
    await tester.tap(find.widgetWithText(FilledButton, 'Nachricht senden'));
    await pumpWorld(tester);
    await tester.pumpAndSettle();

    expect(other.engine.chats.requests.length, 1);
    expect(other.engine.chats.requests.single.visibleMessages.single.body, 'Hallo!');
    expect(me.engine.chats.active.length, 1);
    await finish(tester);
  });

  testWidgets('board shows posts from peers and can compose a post', (tester) async {
    await setUpEngines(tester);
    await drive(tester, () async {
      await me.engine.identity.completeOnboarding();
      await other.engine.identity.completeOnboarding();
      await other.engine.start();
      await other.engine.board.createPost(text: 'Hat jemand ein Ladekabel?', tag: 'frage');
    });

    await tester.pumpWidget(UmkreisApp(context: me));
    await tester.pumpAndSettle();
    await pumpWorld(tester);
    await tester.tap(find.text('Board'));
    await tester.pumpAndSettle();
    expect(find.text('Hat jemand ein Ladekabel?'), findsOneWidget);
    expect(find.text('#frage'), findsWidgets);

    await tester.tap(find.text('Neuer Post'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Ich habe eins, Wagen 3!');
    await tester.tap(find.widgetWithText(FilledButton, 'Posten'));
    await pumpWorld(tester);
    await tester.pumpAndSettle();
    expect(find.text('Ich habe eins, Wagen 3!'), findsOneWidget);
    expect(other.engine.board.posts.length, 2);
    await finish(tester);
  });

  testWidgets('mode switcher changes visibility and the invisible banner appears', (tester) async {
    await setUpEngines(tester);
    await drive(tester, () => me.engine.identity.completeOnboarding());
    await tester.pumpWidget(UmkreisApp(context: me));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ich'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unsichtbar'));
    await tester.pumpAndSettle();
    expect(me.engine.identity.mode, VisibilityMode.invisible);
    expect((me.engine.transport as FakeTransport).advertisedEid, isNull);
    await tester.tap(find.text('Radar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Du bist unsichtbar'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('english locale switches the strings', (tester) async {
    await setUpEngines(tester);
    await drive(tester, () async {
      await me.engine.identity.completeOnboarding();
      await me.engine.identity.setLanguage('en');
    });
    await tester.pumpWidget(UmkreisApp(context: me));
    await tester.pumpAndSettle();
    expect(find.text('Nobody in range'), findsOneWidget);
    expect(find.text('Me'), findsOneWidget);
    await finish(tester);
  });

  test('bootstrapForTest returns a stopped engine', () async {
    final ctx = await bootstrapForTest(world);
    expect(ctx.engine, isA<Engine>());
    expect(ctx.engine.isRunning, false);
  });
}
