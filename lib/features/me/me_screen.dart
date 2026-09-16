import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/bootstrap.dart';
import '../../app/l10n.dart';
import '../../core/moderation/block_service.dart';
import '../../core/services/engine.dart';
import '../../core/services/identity_service.dart';
import '../shared/widgets.dart';
import 'profile_editor.dart';

class MeScreen extends StatelessWidget {
  const MeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final theme = Theme.of(context);
    final identity = context.watch<IdentityService>();
    final engine = context.read<Engine>();
    final blocks = context.watch<BlockService>();

    return Scaffold(
      appBar: AppBar(title: Text(l.tabMe)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Row(
            children: [
              EmojiAvatar(emoji: identity.displayEmoji, size: 64),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(identity.displayName, style: theme.textTheme.headlineSmall),
                    Text(
                      identity.status.isEmpty ? l.statusHint : identity.status,
                      style: theme.textTheme.bodyMedium?.copyWith(color: identity.status.isEmpty ? theme.colorScheme.outline : null),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const ModeSwitcher(showHint: true),
          const SizedBox(height: 24),

          _Section(title: l.yourAlias),
          Card(
            child: ListTile(
              leading: Text(identity.emoji, style: const TextStyle(fontSize: 28)),
              title: Text(identity.alias),
              subtitle: Text(l.aliasChanges),
              trailing: IconButton(
                tooltip: l.rerollAlias,
                icon: const Icon(Icons.casino_outlined),
                onPressed: engine.rerollAlias,
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.short_text),
              title: Text(l.statusLine),
              subtitle: Text(identity.status.isEmpty ? l.statusHint : identity.status),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => _editStatus(context, identity),
            ),
          ),
          const SizedBox(height: 16),

          _Section(title: l.profile),
          Card(
            child: ListTile(
              leading: Text(identity.profile?.emoji ?? '🙂', style: const TextStyle(fontSize: 28)),
              title: Text(identity.hasProfile ? identity.profile!.name : l.createProfile),
              subtitle: identity.hasProfile
                  ? Text([identity.profile!.bio, identity.profile!.tags.map((t) => '#$t').join(' ')].where((s) => s.isNotEmpty).join(' · '))
                  : Text(l.modeProfileHint),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => showProfileEditor(context),
            ),
          ),
          const SizedBox(height: 16),

          _Section(title: l.privacy),
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.shield_outlined),
              title: Text(l.privacy),
              children: [
                Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Text(l.privacyBody)),
              ],
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.block),
              title: Text(l.blocklist),
              subtitle: Text(blocks.entries.isEmpty ? l.blocklistEmpty : '${blocks.entries.length}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const BlocklistScreen())),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: Text(l.reports),
              subtitle: Text('${blocks.reports.length}'),
              trailing: const Icon(Icons.copy_outlined),
              onTap: blocks.reports.isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: blocks.exportReports()));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.exportReports)));
                      }
                    },
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.fingerprint),
              title: Text(l.fingerprint),
              subtitle: Text(identity.identity.fingerprint, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          ),
          const SizedBox(height: 16),

          _Section(title: l.language),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'de', label: Text('Deutsch')),
                  ButtonSegment(value: 'en', label: Text('English')),
                ],
                selected: {identity.language},
                onSelectionChanged: (s) => identity.setLanguage(s.first),
              ),
            ),
          ),
          const SizedBox(height: 16),

          _Section(title: l.about),
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l.about),
              subtitle: Text('${l.aboutBody}${isDemoMode ? '\n${l.demoModeNote}' : ''}'),
            ),
          ),
          Card(
            child: ListTile(
              leading: Icon(Icons.delete_forever_outlined, color: theme.colorScheme.error),
              title: Text(l.resetApp, style: TextStyle(color: theme.colorScheme.error)),
              subtitle: Text(l.resetAppBody),
              onTap: () => _confirmReset(context),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editStatus(BuildContext context, IdentityService identity) async {
    final l = L10n.of(context);
    final ctrl = TextEditingController(text: identity.status);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.statusLine),
        content: TextField(controller: ctrl, autofocus: true, maxLength: 80, decoration: InputDecoration(hintText: l.statusHint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(l.save)),
        ],
      ),
    );
    if (result != null) await identity.setStatus(result);
  }

  Future<void> _confirmReset(BuildContext context) async {
    final l = L10n.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.resetApp),
        content: Text(l.resetAppBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.resetConfirm),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final app = context.read<AppContext>();
    await app.engine.resetAll(app.keyStore);
    // Nach dem Reset ist ein Neustart der App der sauberste Weg.
    if (context.mounted) SystemNavigator.pop();
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

class BlocklistScreen extends StatelessWidget {
  const BlocklistScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final blocks = context.watch<BlockService>();
    return Scaffold(
      appBar: AppBar(title: Text(l.blocklist)),
      body: blocks.entries.isEmpty
          ? EmptyState(icon: Icons.block, title: l.blocklist, body: l.blocklistEmpty)
          : ListView(
              children: [
                for (final e in blocks.entries)
                  ListTile(
                    leading: const Icon(Icons.block),
                    title: Text(e.label.isEmpty ? e.value.substring(0, 12) : e.label),
                    subtitle: Text('${e.kind.name} · ${relativeTime(context, e.at)}'),
                    trailing: TextButton(onPressed: () => blocks.unblock(e), child: Text(l.unblock)),
                  ),
              ],
            ),
    );
  }
}
