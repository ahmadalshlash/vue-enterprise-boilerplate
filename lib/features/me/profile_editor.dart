import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/l10n.dart';
import '../../core/protocol/models.dart';
import '../../core/services/identity_service.dart';

const _emojis = ['🙂', '😎', '🎸', '🚴', '📚', '☕', '🎨', '⚽', '🌱', '🎧', '🧗', '🍕', '🐶', '✈️', '🎮', '🌊'];

/// Öffnet den Profil-Editor. Gibt `true` zurück, wenn gespeichert wurde.
Future<bool> showProfileEditor(BuildContext context) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const ProfileEditorSheet(),
  );
  return result ?? false;
}

class ProfileEditorSheet extends StatefulWidget {
  const ProfileEditorSheet({super.key});

  @override
  State<ProfileEditorSheet> createState() => _ProfileEditorSheetState();
}

class _ProfileEditorSheetState extends State<ProfileEditorSheet> {
  late final TextEditingController _name;
  late final TextEditingController _bio;
  late final TextEditingController _tags;
  late String _emoji;

  @override
  void initState() {
    super.initState();
    final p = context.read<IdentityService>().profile;
    _name = TextEditingController(text: p?.name ?? '');
    _bio = TextEditingController(text: p?.bio ?? '');
    _tags = TextEditingController(text: p?.tags.join(', ') ?? '');
    _emoji = p?.emoji ?? '🙂';
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _tags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final identity = context.read<IdentityService>();
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(identity.hasProfile ? l.editProfile : l.createProfile, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Text(l.emoji, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in _emojis)
                  ChoiceChip(label: Text(e, style: const TextStyle(fontSize: 20)), selected: _emoji == e, onSelected: (_) => setState(() => _emoji = e)),
              ],
            ),
            const SizedBox(height: 16),
            TextField(controller: _name, maxLength: 30, decoration: InputDecoration(labelText: l.name)),
            const SizedBox(height: 12),
            TextField(controller: _bio, maxLength: 120, maxLines: 2, decoration: InputDecoration(labelText: l.bio)),
            const SizedBox(height: 12),
            TextField(controller: _tags, decoration: InputDecoration(labelText: l.tags, hintText: l.tagsHint)),
            const SizedBox(height: 16),
            Row(
              children: [
                if (identity.hasProfile)
                  TextButton(
                    onPressed: () async {
                      final nav = Navigator.of(context);
                      await identity.setProfile(null);
                      nav.pop(false);
                    },
                    style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                    child: Text(l.removeProfile),
                  ),
                const Spacer(),
                TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    final name = _name.text.trim();
                    if (name.isEmpty) return;
                    final nav = Navigator.of(context);
                    final tags = _tags.text
                        .split(',')
                        .map((t) => t.trim().replaceAll('#', '').toLowerCase())
                        .where((t) => t.isNotEmpty)
                        .take(5)
                        .toList();
                    await identity.setProfile(Profile(name: name, bio: _bio.text.trim(), tags: tags, emoji: _emoji));
                    await identity.setMode(VisibilityMode.profile);
                    nav.pop(true);
                  },
                  child: Text(l.save),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
