import 'package:shared_preferences/shared_preferences.dart';

/// Persistence boundary for the pending-feedback queue.
///
/// [PendingFeedbackQueue] depends only on this interface, so the backing store
/// can migrate from SharedPreferences to Hive/SQLite later with no change to the
/// queue logic.
///
/// Contract: items are an ordered list of opaque strings (the queue stores
/// JSON-encoded payloads). [writeAll] replaces the whole list.
abstract class FeedbackQueueStorage {
  Future<List<String>> readAll();
  Future<void> writeAll(List<String> items);
}

/// MVP implementation backed by SharedPreferences (`setStringList`).
///
/// Reads the SharedPreferences singleton on demand, so it shares the same
/// instance the rest of the app already loaded — no injection or init ordering
/// to manage.
class SharedPreferencesFeedbackQueueStorage implements FeedbackQueueStorage {
  SharedPreferencesFeedbackQueueStorage({this.key = 'pending_feedback_queue'});

  /// SharedPreferences key holding the JSON-encoded queue entries.
  final String key;

  @override
  Future<List<String>> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(key) ?? const <String>[];
  }

  @override
  Future<void> writeAll(List<String> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(key, items);
  }
}
