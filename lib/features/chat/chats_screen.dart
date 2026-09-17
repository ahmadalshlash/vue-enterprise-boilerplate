import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/l10n.dart';
import '../../core/protocol/models.dart';
import '../../core/services/chat_service.dart';
import '../shared/widgets.dart';
import 'chat_screen.dart';

class ChatsScreen extends StatelessWidget {
  const ChatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final chats = context.watch<ChatService>();
    final requests = chats.requests;
    final active = chats.active;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l.tabChats)),
      body: requests.isEmpty && active.isEmpty
          ? EmptyState(icon: Icons.chat_bubble_outline, title: l.chatsEmptyTitle, body: l.chatsEmptyBody)
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                if (requests.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text('${l.requests} (${requests.length})', style: theme.textTheme.titleSmall),
                  ),
                  for (final c in requests) _RequestCard(chat: c),
                  const Divider(height: 24),
                ],
                for (final c in active) _ChatTile(chat: c),
              ],
            ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.chat});
  final Chat chat;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final chats = context.read<ChatService>();
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                EmojiAvatar(emoji: chat.emoji),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(chat.alias, style: theme.textTheme.titleMedium),
                      Text(relativeTime(context, chat.stored.updatedAt), style: theme.textTheme.labelSmall),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(chat.lastMessage?.body ?? '', style: theme.textTheme.bodyLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: () async {
                    await chats.accept(chat.fingerprint);
                    if (context.mounted) {
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ChatScreen(fingerprint: chat.fingerprint)));
                    }
                  },
                  child: Text(l.accept),
                ),
                const SizedBox(width: 8),
                TextButton(onPressed: () => chats.reject(chat.fingerprint), child: Text(l.ignore)),
                const Spacer(),
                TextButton(
                  onPressed: () => chats.block(chat.fingerprint),
                  style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  child: Text(l.block),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.chat});
  final Chat chat;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final theme = Theme.of(context);
    final last = chat.lastMessage;
    return ListTile(
      leading: EmojiAvatar(emoji: chat.emoji),
      title: Row(
        children: [
          Expanded(child: Text(chat.alias, overflow: TextOverflow.ellipsis)),
          if (chat.stored.revealedProfile != null) Icon(Icons.badge_outlined, size: 16, color: theme.colorScheme.primary),
        ],
      ),
      subtitle: last == null
          ? null
          : Text(
              last.kind == MessageKind.reveal ? '${chat.alias} ${l.revealedProfile}' : '${last.outgoing ? '${l.you}: ' : ''}${last.body}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (last != null) Text(relativeTime(context, last.timestamp), style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          if (chat.unread > 0)
            Badge(label: Text('${chat.unread}'))
          else if (chat.hasPending)
            Icon(Icons.schedule, size: 16, color: theme.colorScheme.outline),
        ],
      ),
      onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ChatScreen(fingerprint: chat.fingerprint))),
    );
  }
}
