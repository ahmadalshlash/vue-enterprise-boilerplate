import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/l10n.dart';
import '../../core/protocol/models.dart';
import '../../core/services/chat_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/storage/app_database.dart';
import '../shared/widgets.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.fingerprint});
  final String fingerprint;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<ChatService>().markRead(widget.fingerprint));
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final theme = Theme.of(context);
    final chats = context.watch<ChatService>();
    final identity = context.watch<IdentityService>();
    final chat = chats.byFingerprint(widget.fingerprint);
    if (chat == null) {
      return Scaffold(appBar: AppBar(), body: EmptyState(icon: Icons.chat_bubble_outline, title: l.chatsEmptyTitle, body: ''));
    }
    if (chat.unread > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => chats.markRead(widget.fingerprint));
    }
    final messages = chat.visibleMessages;
    final blocked = chat.state == ChatState.blocked;
    final revealed = chat.stored.revealedProfile;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            EmojiAvatar(emoji: chat.emoji, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(chat.alias, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                  Text(
                    blocked
                        ? l.blocked
                        : chat.route != null
                            ? l.inRange
                            : l.waitingForProximity,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'reveal':
                  if (!identity.hasProfile) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.noProfileYet)));
                    return;
                  }
                  await chats.reveal(chat.fingerprint);
                case 'block':
                  await chats.block(chat.fingerprint);
                case 'delete':
                  final nav = Navigator.of(context);
                  await chats.delete(chat.fingerprint);
                  nav.pop();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'reveal', child: Text(l.revealProfile)),
              PopupMenuItem(value: 'block', child: Text(l.block)),
              PopupMenuItem(value: 'delete', child: Text(l.delete)),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (revealed != null)
            InfoBanner(
              icon: Icons.badge_outlined,
              text: '${revealed.emoji} ${revealed.name}${revealed.bio.isNotEmpty ? ' · ${revealed.bio}' : ''}'
                  '${revealed.tags.isNotEmpty ? ' · ${revealed.tags.map((t) => '#$t').join(' ')}' : ''}',
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              reverse: true,
              padding: const EdgeInsets.all(12),
              itemCount: messages.length,
              itemBuilder: (context, i) {
                final m = messages[messages.length - 1 - i];
                return _Bubble(message: m, peerName: chat.alias);
              },
            ),
          ),
          if (!blocked)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _text,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          hintText: l.typeMessage,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    await context.read<ChatService>().sendMessage(widget.fingerprint, t);
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.peerName});
  final StoredMessage message;
  final String peerName;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mine = message.outgoing;

    if (message.kind == MessageKind.reveal) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            mine ? '${l.you}: ${l.revealProfile}' : '$peerName ${l.revealedProfile}',
            style: theme.textTheme.labelSmall?.copyWith(fontStyle: FontStyle.italic),
          ),
        ),
      );
    }

    final statusIcon = switch (message.status) {
      MessageStatus.pending => Icons.schedule,
      MessageStatus.sent => Icons.done,
      MessageStatus.delivered => Icons.done_all,
      MessageStatus.received => null,
    };
    final statusLabel = switch (message.status) {
      MessageStatus.pending => l.waitingForProximity,
      MessageStatus.sent => l.sent,
      MessageStatus.delivered => l.delivered,
      MessageStatus.received => '',
    };

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
        decoration: BoxDecoration(
          color: mine ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 4),
            bottomRight: Radius.circular(mine ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message.body, style: TextStyle(color: mine ? scheme.onPrimary : scheme.onSurface)),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  TimeOfDay.fromDateTime(message.timestamp).format(context),
                  style: theme.textTheme.labelSmall?.copyWith(color: mine ? scheme.onPrimary.withValues(alpha: 0.8) : scheme.outline),
                ),
                if (mine && statusIcon != null) ...[
                  const SizedBox(width: 4),
                  Tooltip(
                    message: statusLabel,
                    child: Icon(statusIcon, size: 14, color: scheme.onPrimary.withValues(alpha: 0.8)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
