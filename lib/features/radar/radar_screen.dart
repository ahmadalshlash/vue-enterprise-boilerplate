import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/bootstrap.dart';
import '../../app/l10n.dart';
import '../../app/permissions.dart';
import '../../core/ble/transport.dart';
import '../../core/protocol/models.dart';
import '../../core/services/chat_service.dart';
import '../../core/services/engine.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/radar_service.dart';
import '../chat/chat_screen.dart';
import '../shared/widgets.dart';

class RadarScreen extends StatelessWidget {
  const RadarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final radar = context.watch<RadarService>();
    final identity = context.watch<IdentityService>();
    final engine = context.watch<Engine>();
    final peers = radar.resolvedPeers;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(l.appName),
            const SizedBox(width: 8),
            if (peers.isNotEmpty)
              Text('${peers.length} ${l.peopleNearby}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _ModeButton(identity: identity),
          ),
        ],
      ),
      body: Column(
        children: [
          if (isDemoMode) InfoBanner(text: l.radarDemoBanner, icon: Icons.science_outlined),
          if (!isDemoMode && defaultTargetPlatform == TargetPlatform.iOS)
            InfoBanner(text: l.iosBackgroundNote, icon: Icons.phone_iphone),
          if (!identity.isVisible) InfoBanner(text: l.radarInvisibleBanner, icon: Icons.visibility_off_outlined),
          ..._statusBanners(context, engine.transportStatus, l),
          Expanded(
            child: peers.isEmpty
                ? EmptyState(icon: Icons.radar, title: l.radarEmptyTitle, body: l.radarEmptyBody)
                : RefreshIndicator(
                    onRefresh: radar.refresh,
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: peers.length,
                      itemBuilder: (context, i) => _PeerTile(peer: peers[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  List<Widget> _statusBanners(BuildContext context, TransportStatus s, L10n l) {
    if (isDemoMode) return const [];
    return switch (s) {
      TransportStatus.poweredOff => [InfoBanner(text: l.radarBluetoothOff, icon: Icons.bluetooth_disabled, warning: true)],
      TransportStatus.unauthorized => [
          InfoBanner(
            text: l.radarUnauthorized,
            icon: Icons.lock_outline,
            warning: true,
            action: TextButton(onPressed: BluetoothPermissions.openSettings, child: const Icon(Icons.settings)),
          ),
        ],
      TransportStatus.unsupported => [InfoBanner(text: l.radarUnsupported, icon: Icons.error_outline, warning: true)],
      _ => const [],
    };
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.identity});
  final IdentityService identity;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final (icon, label) = switch (identity.mode) {
      VisibilityMode.invisible => (Icons.visibility_off_outlined, l.modeInvisible),
      VisibilityMode.anonymous => (Icons.theater_comedy_outlined, l.modeAnonymous),
      VisibilityMode.profile => (Icons.badge_outlined, l.modeProfile),
    };
    return ActionChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  EmojiAvatar(emoji: identity.displayEmoji, size: 40),
                  const SizedBox(width: 12),
                  Text(identity.displayName, style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 16),
              const ModeSwitcher(showHint: true),
            ],
          ),
        ),
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer});
  final RadarPeer peer;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: EmojiAvatar(emoji: peer.emoji),
        title: Row(
          children: [
            Flexible(child: Text(peer.displayName, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            if (peer.hasProfile)
              Icon(Icons.badge_outlined, size: 16, color: theme.colorScheme.primary)
            else
              Text(l.anonymousPerson, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
        subtitle: peer.needsUpdate
            ? Text(l.updateNeeded, style: TextStyle(color: theme.colorScheme.error))
            : peer.status.isNotEmpty
                ? Text(peer.status, maxLines: 1, overflow: TextOverflow.ellipsis)
                : null,
        trailing: ProximityChip(proximity: peer.proximity, compact: true),
        onTap: peer.needsUpdate ? null : () => showPeerSheet(context, peer),
      ),
    );
  }
}

/// Detail-Sheet einer Person mit Nachrichten-Eingabe.
Future<void> showPeerSheet(BuildContext context, RadarPeer peer) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PeerSheet(peer: peer),
  );
}

class _PeerSheet extends StatefulWidget {
  const _PeerSheet({required this.peer});
  final RadarPeer peer;

  @override
  State<_PeerSheet> createState() => _PeerSheetState();
}

class _PeerSheetState extends State<_PeerSheet> {
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final theme = Theme.of(context);
    final peer = widget.peer;
    final chats = context.watch<ChatService>();
    // Existiert schon ein aktiver Chat mit dieser Person (gleicher Alias)? Dann dorthin.
    final existing = chats.active.where((c) => c.route == peer.peerId).firstOrNull;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              EmojiAvatar(emoji: peer.emoji, size: 56),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(peer.displayName, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        ProximityChip(proximity: peer.proximity, compact: true),
                        const SizedBox(width: 8),
                        Text(peer.hasProfile ? l.hasProfile : l.anonymousPerson, style: theme.textTheme.labelMedium),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (peer.status.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(peer.status, style: theme.textTheme.bodyLarge),
          ],
          const SizedBox(height: 20),
          if (existing != null)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ChatScreen(fingerprint: existing.fingerprint)));
              },
              icon: const Icon(Icons.chat_bubble_outline),
              label: Text(l.tabChats),
            )
          else ...[
            TextField(
              controller: _text,
              maxLines: 3,
              minLines: 1,
              maxLength: 500,
              decoration: InputDecoration(hintText: l.messageHint, labelText: l.sendMessage),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text(l.sendMessage),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _send() async {
    final l = L10n.of(context);
    final text = _text.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      await context.read<ChatService>().sendRequest(widget.peer, text);
      messenger.showSnackBar(SnackBar(content: Text(l.requestSent)));
      nav.pop();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.requestFailed)));
      if (mounted) setState(() => _sending = false);
    }
  }
}
