import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/l10n.dart';
import '../../core/protocol/models.dart';
import '../../core/services/board_service.dart';
import '../../core/services/identity_service.dart';
import '../shared/widgets.dart';

class BoardScreen extends StatelessWidget {
  const BoardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final board = context.watch<BoardService>();
    final posts = board.posts;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.tabBoard),
        actions: [
          IconButton(
            tooltip: l.showHidden,
            icon: Icon(board.showHidden ? Icons.visibility : Icons.visibility_off_outlined),
            onPressed: () {
              board.showHidden = !board.showHidden;
              board.setTagFilter(board.tagFilter);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(l.allTags),
                    selected: board.tagFilter == null,
                    onSelected: (_) => board.setTagFilter(null),
                  ),
                ),
                for (final t in boardTags)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(l.tag(t)),
                      selected: board.tagFilter == t,
                      onSelected: (_) => board.setTagFilter(board.tagFilter == t ? null : t),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: posts.isEmpty
                ? EmptyState(icon: Icons.dashboard_outlined, title: l.boardEmptyTitle, body: l.boardEmptyBody)
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 4, bottom: 96),
                    itemCount: posts.length,
                    itemBuilder: (context, i) => PostCard(post: posts[i]),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showComposeSheet(context),
        icon: const Icon(Icons.edit_outlined),
        label: Text(l.newPost),
      ),
    );
  }
}

class PostCard extends StatelessWidget {
  const PostCard({super.key, required this.post, this.showReplies = true});
  final BoardPost post;
  final bool showReplies;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final theme = Theme.of(context);
    final board = context.watch<BoardService>();
    final p = post.post;
    final replies = showReplies ? board.repliesTo(p.id) : const <BoardPost>[];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                EmojiAvatar(emoji: p.emoji, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(child: Text(post.mine ? '${p.alias} (${l.you})' : p.alias, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis)),
                          if (p.isProfilePost) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.badge_outlined, size: 14, color: theme.colorScheme.primary),
                          ],
                        ],
                      ),
                      Text(
                        '${relativeTime(context, p.timestamp)} · ${l.expiresIn} ${durationLabel(context, p.expiresAt.difference(DateTime.now()))}',
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                ),
                if (p.tag.isNotEmpty)
                  Chip(
                    label: Text(l.tag(p.tag)),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    backgroundColor: p.tag == 'notfall' ? theme.colorScheme.errorContainer : null,
                  ),
                PopupMenuButton<String>(
                  onSelected: (v) => _onMenu(context, v),
                  itemBuilder: (_) => [
                    if (post.mine)
                      PopupMenuItem(value: 'delete', child: Text(l.delete))
                    else ...[
                      PopupMenuItem(value: 'hide', child: Text(l.hide)),
                      PopupMenuItem(value: 'block', child: Text(l.blockAuthor)),
                      PopupMenuItem(value: 'report', child: Text(l.report)),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (post.hidden)
              Text('(${l.hide})', style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic))
            else
              Text(p.text, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final r in const ['👍', '❤️', '🙋'])
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ActionChip(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: post.myReactions.contains(r) ? theme.colorScheme.primaryContainer : null,
                      label: Text('$r ${post.reactions[r] ?? 0}'),
                      onPressed: post.mine ? null : () => board.react(p.id, r),
                    ),
                  ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => showComposeSheet(context, replyTo: p),
                  icon: const Icon(Icons.reply, size: 18),
                  label: Text(replies.isEmpty ? l.reply : '${replies.length} ${l.replies}'),
                ),
              ],
            ),
            if (replies.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final r in replies.take(3))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r.post.emoji),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text.rich(TextSpan(children: [
                                TextSpan(text: '${r.post.alias}: ', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                                TextSpan(text: r.post.text, style: theme.textTheme.bodySmall),
                              ])),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _onMenu(BuildContext context, String action) async {
    final l = L10n.of(context);
    final board = context.read<BoardService>();
    final messenger = ScaffoldMessenger.of(context);
    switch (action) {
      case 'delete':
        await board.deleteOwn(post.post.id);
      case 'hide':
        await board.hide(post.post.id);
      case 'block':
        await board.blockAuthor(post.post.id);
      case 'report':
        final reason = await _askReason(context, l);
        if (reason == null) return;
        await board.report(post.post.id, reason);
        messenger.showSnackBar(SnackBar(content: Text(l.reported)));
    }
  }

  Future<String?> _askReason(BuildContext context, L10n l) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.report),
        content: TextField(controller: ctrl, autofocus: true, decoration: InputDecoration(hintText: l.reportReasonHint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isEmpty ? '-' : ctrl.text.trim()), child: Text(l.report)),
        ],
      ),
    );
  }
}

Future<void> showComposeSheet(BuildContext context, {Post? replyTo}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ComposePostSheet(replyTo: replyTo),
  );
}

class ComposePostSheet extends StatefulWidget {
  const ComposePostSheet({super.key, this.replyTo});
  final Post? replyTo;

  @override
  State<ComposePostSheet> createState() => _ComposePostSheetState();
}

class _ComposePostSheetState extends State<ComposePostSheet> {
  final _text = TextEditingController();
  String _tag = 'sonstiges';
  Duration _ttl = const Duration(hours: 6);
  bool _asProfile = false;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    if (widget.replyTo != null) _tag = widget.replyTo!.tag;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final identity = context.watch<IdentityService>();
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.replyTo == null ? l.newPost : l.reply, style: theme.textTheme.titleLarge),
            if (widget.replyTo != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('${widget.replyTo!.alias}: ${widget.replyTo!.text}',
                    style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              maxLength: 500,
              decoration: InputDecoration(hintText: l.postHint),
            ),
            if (widget.replyTo == null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final t in boardTags)
                    ChoiceChip(label: Text(l.tag(t)), selected: _tag == t, onSelected: (_) => setState(() => _tag = t)),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('${l.expiresIn}:', style: theme.textTheme.labelLarge),
                  const SizedBox(width: 8),
                  for (final d in const [Duration(hours: 1), Duration(hours: 6), Duration(hours: 24)])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(durationLabel(context, d)),
                        selected: _ttl == d,
                        onSelected: (_) => setState(() => _ttl = d),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Text('${l.postAs}:', style: theme.textTheme.labelLarge),
                const SizedBox(width: 8),
                ChoiceChip(
                  avatar: Text(identity.emoji),
                  label: Text('${l.postAsAnonymous} · ${identity.alias}'),
                  selected: !_asProfile,
                  onSelected: (_) => setState(() => _asProfile = false),
                ),
                const SizedBox(width: 6),
                if (identity.hasProfile)
                  ChoiceChip(
                    avatar: Text(identity.profile!.emoji),
                    label: Text(identity.profile!.name),
                    selected: _asProfile,
                    onSelected: (_) => setState(() => _asProfile = true),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _posting ? null : _post,
              icon: const Icon(Icons.send),
              label: Text(l.post),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _post() async {
    if (_text.text.trim().isEmpty) return;
    setState(() => _posting = true);
    final nav = Navigator.of(context);
    await context.read<BoardService>().createPost(
          text: _text.text,
          tag: _tag,
          ttl: widget.replyTo?.ttl ?? _ttl,
          asProfile: _asProfile,
          replyTo: widget.replyTo?.id,
        );
    nav.pop();
  }
}
