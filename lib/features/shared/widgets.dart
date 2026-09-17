import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/l10n.dart';
import '../../app/theme.dart';
import '../../core/ble/rssi.dart';
import '../../core/protocol/models.dart';
import '../../core/services/identity_service.dart';

/// Emoji-Avatar in einem farbigen Kreis.
class EmojiAvatar extends StatelessWidget {
  const EmojiAvatar({super.key, required this.emoji, this.size = 44, this.color});
  final String emoji;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color ?? scheme.secondaryContainer, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(emoji, style: TextStyle(fontSize: size * 0.5)),
    );
  }
}

/// Nähe-Stufe als farbiger Chip mit Punkt.
class ProximityChip extends StatelessWidget {
  const ProximityChip({super.key, required this.proximity, this.compact = false});
  final Proximity proximity;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final color = AppTheme.proximityColor(proximity, scheme);
    final label = switch (proximity) {
      Proximity.veryNear => l.veryNear,
      Proximity.near => l.near,
      Proximity.inRange => l.inRange,
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: compact ? 2 : 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
        ],
      ),
    );
  }
}

/// Leerer Zustand mit Icon, Titel und Text.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(body, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// Umschalter Unsichtbar / Anonym / Profil.
class ModeSwitcher extends StatelessWidget {
  const ModeSwitcher({super.key, this.showHint = false});
  final bool showHint;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final identity = context.watch<IdentityService>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<VisibilityMode>(
          segments: [
            ButtonSegment(value: VisibilityMode.invisible, icon: const Icon(Icons.visibility_off_outlined), label: Text(l.modeInvisible)),
            ButtonSegment(value: VisibilityMode.anonymous, icon: const Icon(Icons.theater_comedy_outlined), label: Text(l.modeAnonymous)),
            ButtonSegment(value: VisibilityMode.profile, icon: const Icon(Icons.badge_outlined), label: Text(l.modeProfile)),
          ],
          selected: {identity.mode},
          onSelectionChanged: (s) async {
            final m = s.first;
            if (m == VisibilityMode.profile && !identity.hasProfile) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.noProfileYet)));
              return;
            }
            await identity.setMode(m);
          },
        ),
        if (showHint) ...[
          const SizedBox(height: 8),
          Text(
            switch (identity.mode) {
              VisibilityMode.invisible => l.modeInvisibleHint,
              VisibilityMode.anonymous => l.modeAnonymousHint,
              VisibilityMode.profile => l.modeProfileHint,
            },
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// Hinweisleiste (Info/Warnung) oberhalb einer Liste.
class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.text, this.icon = Icons.info_outline, this.action, this.warning = false});
  final String text;
  final IconData icon;
  final Widget? action;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: warning ? scheme.errorContainer : scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: warning ? scheme.onErrorContainer : scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
            ?action,
          ],
        ),
      ),
    );
  }
}

String relativeTime(BuildContext context, DateTime t) {
  final l = L10n.of(context);
  final d = DateTime.now().difference(t);
  final de = l.code == 'de';
  if (d.inMinutes < 1) return de ? 'gerade eben' : 'just now';
  if (d.inMinutes < 60) return de ? 'vor ${d.inMinutes} Min.' : '${d.inMinutes} min ago';
  if (d.inHours < 24) return de ? 'vor ${d.inHours} Std.' : '${d.inHours} h ago';
  return de ? 'vor ${d.inDays} Tagen' : '${d.inDays} d ago';
}

String durationLabel(BuildContext context, Duration d) {
  final de = L10n.of(context).code == 'de';
  if (d.inMinutes < 60) return de ? '${d.inMinutes} Min.' : '${d.inMinutes} min';
  if (d.inHours < 48) return de ? '${d.inHours} Std.' : '${d.inHours} h';
  return de ? '${d.inDays} Tage' : '${d.inDays} d';
}
