import 'dart:typed_data';

import 'constants.dart';

/// Zerlegt Frames in Chunks, die in eine BLE-Schreiboperation passen.
///
/// Chunk-Header: `seq(2) | total(2) | frameId(2)`, dann Nutzbytes.
class Chunker {
  Chunker({int startId = 0}) : _nextId = startId & 0xffff;

  static const int headerLength = 6;
  int _nextId;

  /// Teilt [frame] in Chunks mit maximal [maxChunkBytes] Byte (inkl. Header).
  List<Uint8List> split(Uint8List frame, int maxChunkBytes) {
    final payloadPerChunk = maxChunkBytes - headerLength;
    if (payloadPerChunk < 1) {
      throw ArgumentError('maxChunkBytes zu klein: $maxChunkBytes');
    }
    if (frame.length > ProtocolConstants.maxFrameBytes) {
      throw ArgumentError('Frame zu groß: ${frame.length}');
    }
    final total = frame.isEmpty ? 1 : (frame.length + payloadPerChunk - 1) ~/ payloadPerChunk;
    if (total > 0xffff) {
      throw ArgumentError('Zu viele Chunks: $total');
    }
    final id = _nextId;
    _nextId = (_nextId + 1) & 0xffff;

    final chunks = <Uint8List>[];
    for (var seq = 0; seq < total; seq++) {
      final start = seq * payloadPerChunk;
      final end = (start + payloadPerChunk).clamp(0, frame.length);
      final body = frame.sublist(start, end);
      final chunk = Uint8List(headerLength + body.length);
      chunk[0] = (seq >> 8) & 0xff;
      chunk[1] = seq & 0xff;
      chunk[2] = (total >> 8) & 0xff;
      chunk[3] = total & 0xff;
      chunk[4] = (id >> 8) & 0xff;
      chunk[5] = id & 0xff;
      chunk.setRange(headerLength, chunk.length, body);
      chunks.add(chunk);
    }
    return chunks;
  }
}

/// Setzt Chunks eines Absenders wieder zu Frames zusammen.
///
/// Pro Absender wird ein [Reassembler] gehalten. Unvollständige Frames
/// werden nach [ProtocolConstants.chunkTimeout] verworfen.
class Reassembler {
  Reassembler({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<int, _Partial> _partials = {};

  /// Verarbeitet einen Chunk. Gibt das vollständige Frame zurück, sobald
  /// alle Teile da sind, sonst `null`.
  Uint8List? accept(Uint8List chunk) {
    if (chunk.length < Chunker.headerLength) return null;
    final seq = (chunk[0] << 8) | chunk[1];
    final total = (chunk[2] << 8) | chunk[3];
    final id = (chunk[4] << 8) | chunk[5];
    if (total == 0 || seq >= total) return null;

    _evictStale();

    final now = _clock();
    var partial = _partials[id];
    if (partial == null || partial.total != total) {
      partial = _Partial(total, now);
      _partials[id] = partial;
    }
    partial.parts[seq] = Uint8List.sublistView(chunk, Chunker.headerLength);
    partial.lastUpdate = now;

    if (partial.parts.length < total) return null;
    _partials.remove(id);

    final size = partial.parts.values.fold<int>(0, (a, b) => a + b.length);
    if (size > ProtocolConstants.maxFrameBytes) return null;
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < total; i++) {
      out.add(partial.parts[i]!);
    }
    return out.takeBytes();
  }

  void _evictStale() {
    final now = _clock();
    _partials.removeWhere(
      (_, p) => now.difference(p.lastUpdate) > ProtocolConstants.chunkTimeout,
    );
  }

  int get pendingCount => _partials.length;
}

class _Partial {
  _Partial(this.total, this.lastUpdate);
  final int total;
  DateTime lastUpdate;
  final Map<int, Uint8List> parts = {};
}
