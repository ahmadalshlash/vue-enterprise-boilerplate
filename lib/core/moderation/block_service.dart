import 'package:flutter/foundation.dart';

import '../crypto/random.dart';
import '../storage/app_database.dart';

/// Blockliste und lokale Meldungen. Blockiert werden Geräte-Fingerabdrücke
/// (nach Chat bekannt) und Post-Schlüssel (anonyme Poster, gültig für die
/// laufende Alias-Periode des Posters).
class BlockService extends ChangeNotifier {
  BlockService(this._repo);

  final BlockRepository _repo;
  final Set<String> _fingerprints = {};
  final Set<String> _postKeys = {};
  List<BlockEntry> _entries = [];
  List<Report> _reports = [];

  List<BlockEntry> get entries => List.unmodifiable(_entries);
  List<Report> get reports => List.unmodifiable(_reports);

  Future<void> load() async {
    _entries = await _repo.all();
    _reports = await _repo.reports();
    _fingerprints
      ..clear()
      ..addAll(_entries.where((e) => e.kind == BlockKind.fingerprint).map((e) => e.value));
    _postKeys
      ..clear()
      ..addAll(_entries.where((e) => e.kind == BlockKind.postKey).map((e) => e.value));
    notifyListeners();
  }

  bool isFingerprintBlocked(String fp) => _fingerprints.contains(fp);
  bool isPostKeyBlocked(String pubkeyHex) => _postKeys.contains(pubkeyHex);

  Future<void> blockFingerprint(String fp, {String label = ''}) async {
    if (_fingerprints.add(fp)) {
      final e = BlockEntry(kind: BlockKind.fingerprint, value: fp, at: DateTime.now(), label: label);
      _entries.add(e);
      await _repo.put(e);
      notifyListeners();
    }
  }

  Future<void> blockPostKey(String pubkeyHex, {String label = ''}) async {
    if (_postKeys.add(pubkeyHex)) {
      final e = BlockEntry(kind: BlockKind.postKey, value: pubkeyHex, at: DateTime.now(), label: label);
      _entries.add(e);
      await _repo.put(e);
      notifyListeners();
    }
  }

  Future<void> unblock(BlockEntry e) async {
    _entries.removeWhere((x) => x.kind == e.kind && x.value == e.value);
    if (e.kind == BlockKind.fingerprint) _fingerprints.remove(e.value);
    if (e.kind == BlockKind.postKey) _postKeys.remove(e.value);
    await _repo.remove(e.kind, e.value);
    notifyListeners();
  }

  /// Ohne Server heißt Melden: lokal festhalten (exportierbar) + blockieren.
  Future<Report> report({
    required String targetKind,
    required String target,
    required String reason,
    String snapshot = '',
  }) async {
    final r = Report(
      id: randomId(8),
      targetKind: targetKind,
      target: target,
      reason: reason,
      at: DateTime.now(),
      snapshot: snapshot,
    );
    _reports.add(r);
    await _repo.putReport(r);
    notifyListeners();
    return r;
  }

  /// Export der Meldungen als Text (z. B. zum Weiterleiten per Mail).
  String exportReports() => _reports
      .map((r) => '[${r.at.toIso8601String()}] ${r.targetKind} ${r.target}\n'
          'Grund: ${r.reason}\n${r.snapshot}\n')
      .join('\n');
}
