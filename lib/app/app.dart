import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import '../core/services/board_service.dart';
import '../core/services/chat_service.dart';
import '../core/services/engine.dart';
import '../core/services/identity_service.dart';
import '../core/services/radar_service.dart';
import '../core/moderation/block_service.dart';
import '../features/board/board_screen.dart';
import '../features/chat/chats_screen.dart';
import '../features/me/me_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/radar/radar_screen.dart';
import 'bootstrap.dart';
import 'l10n.dart';
import 'theme.dart';

class UmkreisApp extends StatelessWidget {
  const UmkreisApp({super.key, required this.context});

  final AppContext context;

  @override
  Widget build(BuildContext _) {
    final engine = context.engine;
    return MultiProvider(
      providers: [
        Provider<AppContext>.value(value: context),
        ChangeNotifierProvider<Engine>.value(value: engine),
        ChangeNotifierProvider<IdentityService>.value(value: engine.identity),
        ChangeNotifierProvider<RadarService>.value(value: engine.radar),
        ChangeNotifierProvider<ChatService>.value(value: engine.chats),
        ChangeNotifierProvider<BoardService>.value(value: engine.board),
        ChangeNotifierProvider<BlockService>.value(value: engine.blocks),
      ],
      child: Consumer<IdentityService>(
        builder: (context, identity, _) => MaterialApp(
          title: 'Umkreis',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          locale: Locale(identity.language),
          supportedLocales: const [Locale('de'), Locale('en')],
          localizationsDelegates: [
            L10nDelegate(identity.language),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: identity.onboardingDone ? const HomeShell() : const OnboardingScreen(),
        ),
      ),
    );
  }
}

/// Tab-Leiste: Radar, Board, Chats, Ich.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final engine = context.read<Engine>();
      if (!engine.isRunning) engine.start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final unread = context.watch<ChatService>().unreadTotal;
    final nearby = context.watch<RadarService>().count;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [RadarScreen(), BoardScreen(), ChatsScreen(), MeScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: nearby > 0,
              label: Text('$nearby'),
              child: const Icon(Icons.radar_outlined),
            ),
            selectedIcon: const Icon(Icons.radar),
            label: l.tabRadar,
          ),
          NavigationDestination(
            icon: const Icon(Icons.dashboard_outlined),
            selectedIcon: const Icon(Icons.dashboard),
            label: l.tabBoard,
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.chat_bubble_outline),
            ),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: l.tabChats,
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline),
            selectedIcon: const Icon(Icons.person),
            label: l.tabMe,
          ),
        ],
      ),
    );
  }
}
