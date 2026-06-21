import 'dart:async';
import 'dart:convert';

import 'feedback_queue_storage.dart';
import 'feedback_service.dart';

/// Outcome of a submit attempt.
///   sent   → POSTed to the backend immediately
///   queued → backend unreachable; persisted locally for automatic retry
enum FeedbackResult { sent, queued }

/// Offline-first feedback submission with a durable retry queue.
///
/// On [submit], it tries to POST immediately; on ANY failure the payload is
/// persisted (never discarded) and retried later via [flush] (on next launch,
/// or right after the next successful send). An item leaves the queue ONLY after
/// its POST succeeds. Persistence is delegated to a [FeedbackQueueStorage], so
/// the storage engine (SharedPreferences today, Hive/SQLite later) is swappable.
class PendingFeedbackQueue {
  PendingFeedbackQueue({
    required FeedbackService service,
    required FeedbackQueueStorage storage,
    this.maxItems = 100,
    // Private fields can't be named initializing formals (`this._service`), so
    // they're assigned via the initializer list below.
  })  : _service = service, // ignore: prefer_initializing_formals
        _storage = storage; // ignore: prefer_initializing_formals

  final FeedbackService _service;
  final FeedbackQueueStorage _storage;

  /// Soft cap so a long offline streak can't grow storage unbounded; the oldest
  /// entries are dropped first.
  final int maxItems;

  // Serializes mutations of the stored list so an on-launch flush and a user
  // submit can't race or double-write.
  Future<void> _lock = Future.value();

  /// Submit a payload: POST now, or persist for later if that fails.
  Future<FeedbackResult> submit(Map<String, dynamic> payload) async {
    if (await _service.post(payload)) {
      // Connectivity just proven — opportunistically drain any backlog.
      unawaited(flush());
      return FeedbackResult.sent;
    }
    await _enqueue(payload);
    return FeedbackResult.queued;
  }

  /// Attempt to send everything queued, in FIFO order. Stops at the first
  /// failure (still offline). Each item is removed and persisted only AFTER its
  /// POST succeeds, so a crash mid-flush never drops or double-sends.
  Future<void> flush() {
    return _serialized(() async {
      var items = await _storage.readAll();
      while (items.isNotEmpty) {
        final Map<String, dynamic> payload;
        try {
          payload = jsonDecode(items.first) as Map<String, dynamic>;
        } catch (_) {
          // Corrupt entry — drop it so it can't wedge the queue forever.
          items = items.sublist(1);
          await _storage.writeAll(items);
          continue;
        }
        final ok = await _service.post(payload);
        if (!ok) break;
        items = items.sublist(1);
        await _storage.writeAll(items);
      }
    });
  }

  Future<void> _enqueue(Map<String, dynamic> payload) {
    return _serialized(() async {
      final items = List<String>.of(await _storage.readAll())
        ..add(jsonEncode(payload));
      final trimmed = items.length > maxItems
          ? items.sublist(items.length - maxItems)
          : items;
      await _storage.writeAll(trimmed);
    });
  }

  /// Chains [action] after any in-flight queue operation completes.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }
}
