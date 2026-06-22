import 'dart:convert';

import 'package:http/http.dart' as http;

/// App version stamped into EVERY feedback payload, so a generated GitHub issue
/// can be traced to the release that produced it. Keep this in sync with the
/// `version:` field in pubspec.yaml (currently `1.0.0+1`).
const String kAppVersion = '1.0.0';

/// A selectable feedback category.
///
/// [key] is the stable, language-neutral identifier sent in the payload (so the
/// Worker can map it to a GitHub label); [labelJa] is the UI text. When
/// [lectureLinked] is true the feedback is about the currently playing lecture
/// and the playing-track metadata is attached automatically.
class FeedbackCategory {
  const FeedbackCategory(
    this.key,
    this.labelJa, {
    required this.lectureLinked,
    required this.priority,
  });

  final String key;
  final String labelJa;
  final bool lectureLinked;

  /// Triage priority derived from the category — 'high' | 'medium' | 'low'.
  /// Stamped into every payload so issues can be auto-prioritized; never entered
  /// by the user.
  final String priority;
}

/// Feedback categories in display order. The first three are about a specific
/// lecture; the last two are general app feedback.
const List<FeedbackCategory> kFeedbackCategories = [
  FeedbackCategory('reading_mistake', '読み間違い',
      lectureLinked: true, priority: 'high'),
  FeedbackCategory('content_error', '内容の誤り',
      lectureLinked: true, priority: 'high'),
  FeedbackCategory('explanation_unclear', '説明がわかりにくい',
      lectureLinked: true, priority: 'low'),
  FeedbackCategory('app_bug', 'アプリ不具合',
      lectureLinked: false, priority: 'medium'),
  FeedbackCategory('suggestion', '要望',
      lectureLinked: false, priority: 'low'),
];

/// Priority for a category key, derived from [kFeedbackCategories]. Falls back to
/// 'low' for an unknown key (e.g. a payload queued by a newer build).
String priorityForCategory(String categoryKey) {
  for (final c in kFeedbackCategories) {
    if (c.key == categoryKey) return c.priority;
  }
  return 'low';
}

/// Transport for user feedback.
///
/// This class holds NO secrets, does NO persistence and never touches the GitHub
/// API. It only POSTs a JSON payload to the Cloudflare Worker, which owns the
/// token and opens the issue server-side. Durable retry lives in
/// [PendingFeedbackQueue]; payload shapes are built by the static builders here
/// so `app_version` is injected in exactly one place.
class FeedbackService {
  FeedbackService({http.Client? client, String? endpoint})
      : _client = client ?? http.Client(),
        endpoint = endpoint ?? defaultEndpoint;

  /// Deployed Cloudflare Worker endpoint. Replace with the real URL before
  /// release. No secret material lives here — the Worker holds the GitHub token.
  static const String defaultEndpoint =
      'https://studyaudioapp-feedback.snkk0417.workers.dev/feedback';

  static const Duration _timeout = Duration(seconds: 10);

  final http.Client _client;
  final String endpoint;

  /// Feedback tied to a specific lecture track. Caller passes the ACTUAL playing
  /// track's metadata (see HomeScreen), not the browsed UI selection.
  static Map<String, dynamic> lecturePayload({
    required String category,
    required String subject,
    required String topic,
    required String topicJp,
    required String contentType,
    required int positionSeconds,
    required String comment,
    String? transcriptExcerpt,
  }) {
    return {
      'type': 'lecture',
      'category': category,
      'priority': priorityForCategory(category),
      'app_version': kAppVersion,
      'subject': subject,
      'topic': topic,
      'topic_jp': topicJp,
      // Which audio variant produced the issue (deep/exam/core/practical/trap).
      'content_type': contentType,
      // Both forms: precise seconds for machines, mm:ss for the issue body.
      'position_seconds': positionSeconds,
      'timestamp': _formatTimestamp(positionSeconds),
      // Approximate source-text context near the playback position, so the issue
      // shows what was being read. Omitted when the track has no bundled text.
      if (transcriptExcerpt != null && transcriptExcerpt.isNotEmpty)
        'transcript_excerpt': transcriptExcerpt,
      'comment': comment,
    };
  }

  /// Formats a playback position as `m:ss` (minutes not wrapped at 60, so long
  /// tracks read correctly — e.g. 3700s → `61:40`).
  static String _formatTimestamp(int seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// General app feedback with no lecture context.
  static Map<String, dynamic> generalPayload({
    required String category,
    required String comment,
  }) {
    return {
      'type': 'general',
      'category': category,
      'priority': priorityForCategory(category),
      'app_version': kAppVersion,
      'comment': comment,
    };
  }

  /// POSTs one payload and reports success. Network errors, timeouts and non-2xx
  /// responses all resolve to `false` (never throws) so the caller can persist
  /// and retry.
  Future<bool> post(Map<String, dynamic> payload) async {
    try {
      final response = await _client
          .post(
            Uri.parse(endpoint),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(_timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  void dispose() => _client.close();
}
