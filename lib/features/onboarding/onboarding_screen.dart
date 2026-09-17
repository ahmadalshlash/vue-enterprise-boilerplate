import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/bootstrap.dart';
import '../../app/l10n.dart';
import '../../app/permissions.dart';
import '../../core/services/identity_service.dart';
import '../me/profile_editor.dart';
import '../shared/widgets.dart';

/// Drei Erklär-Seiten → Bluetooth-Berechtigung → Alias → Start.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;
  bool _requesting = false;
  bool? _granted;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final pages = [
      _Page(icon: Icons.radar, title: l.onboardingTitle1, body: l.onboardingBody1),
      _Page(icon: Icons.bluetooth_searching, title: l.onboardingTitle2, body: l.onboardingBody2),
      _Page(icon: Icons.shield_outlined, title: l.onboardingTitle3, body: l.onboardingBody3),
      _AliasPage(granted: _granted),
    ];
    final last = _page == pages.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _controller,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _page = i),
                children: pages,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      pages.length,
                      (i) => Container(
                        width: i == _page ? 20 : 8,
                        height: 8,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: i == _page ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (!last)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _requesting ? null : _next,
                        child: Text(_page == 2 ? l.allowBluetooth : l.next),
                      ),
                    )
                  else ...[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => _finish(context),
                        child: Text(l.stayAnonymous),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () async {
                          final saved = await showProfileEditor(context);
                          if (saved && context.mounted) await _finish(context);
                        },
                        child: Text(l.setupProfile),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _next() async {
    if (_page == 2) {
      setState(() => _requesting = true);
      final ok = isDemoMode ? true : await BluetoothPermissions.request();
      if (!mounted) return;
      setState(() {
        _requesting = false;
        _granted = ok;
      });
    }
    await _controller.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  Future<void> _finish(BuildContext context) async {
    await context.read<IdentityService>().completeOnboarding();
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Icon(icon, size: 56, color: theme.colorScheme.onPrimaryContainer),
          ),
          const SizedBox(height: 32),
          Text(title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Text(body, style: theme.textTheme.bodyLarge, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _AliasPage extends StatelessWidget {
  const _AliasPage({required this.granted});
  final bool? granted;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final identity = context.watch<IdentityService>();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (granted == false)
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: InfoBanner(text: l.permissionDenied, icon: Icons.bluetooth_disabled, warning: true),
            ),
          Text(l.youAreNow, style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          EmojiAvatar(emoji: identity.emoji, size: 96),
          const SizedBox(height: 16),
          Text(identity.alias, style: theme.textTheme.headlineMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(l.aliasChanges, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => identity.rerollAlias(),
            icon: const Icon(Icons.casino_outlined),
            label: Text(l.rerollAlias),
          ),
        ],
      ),
    );
  }
}
