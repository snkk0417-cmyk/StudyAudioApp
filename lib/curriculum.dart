import 'package:flutter/services.dart' show AssetManifest, rootBundle;

/// Curriculum data model + runtime asset discovery.
///
/// The content model is intentionally flexible (see docs/ARCHITECTURE.md §2):
/// a topic carries an open *list* of content types, not two hardwired fields.
/// New types (e.g. `advanced`, `review`) only need an entry in [kContentTypes]
/// plus the matching `<type>.txt` / `<type>.mp3` assets — no structural change.

// ── Subjects ──────────────────────────────────────────────────────────────

const List<String> kSubjectOrder = ['architecture', 'construction', 'structure'];

const Map<String, String> kSubjectLabels = {
  'architecture': 'Architecture',
  'construction': 'Construction',
  'structure': 'Structure',
};

// Declared topic lists. (Grows in Phase 4 as more PDFs are processed.)
const Map<String, List<String>> kSubjectTopics = {
  'architecture': [
    'educational_facilities',
    'elderly_and_medical_facilities',
    'library_museum_sports',
    'urban_planning',
  ],
  'construction': [
    'earthwork_and_shoring',
    'foundation_and_piling',
    'foundation_work',
    'temporary_work',
  ],
  'structure': [
    'buckling_and_beam_deflection',
    'column_base_and_seismic_design',
    'steel_connection',
    'steel_material_properties',
  ],
};

// ── Content types (flexible registry) ───────────────────────────────────────

class ContentType {
  const ContentType(this.id, this.label);
  final String id;
  final String label;
}

/// Known content types in display/priority order. New types append here.
/// Legacy types (`core`/`practical`/`trap`) are retained so the existing audio
/// stays playable for engine testing; they are auto-hidden when a topic has none.
const List<ContentType> kContentTypes = [
  ContentType('deep', 'Deep Lecture'),
  ContentType('exam', 'Exam Review'),
  ContentType('core', 'Core'),
  ContentType('practical', 'Practical'),
  ContentType('trap', 'Trap'),
];

List<String> get kContentTypeOrder => kContentTypes.map((c) => c.id).toList();

String contentTypeLabel(String id) {
  for (final c in kContentTypes) {
    if (c.id == id) return c.label;
  }
  return id;
}

// ── Study modes: filter which content types enter the playlist ──────────────

const Map<String, String> kStudyModeLabels = {
  'lecture': 'Lecture',
  'exam': 'Exam',
  'full': 'Full',
};

const List<String> kStudyModeOrder = ['lecture', 'exam', 'full'];

/// Whether a content type belongs in the playlist under the given study mode.
///   lecture → everything except the short exam recap (deep + legacy lectures)
///   exam    → only the exam recap
///   full    → everything
bool studyModeIncludes(String mode, String typeId) {
  switch (mode) {
    case 'exam':
      return typeId == 'exam';
    case 'lecture':
      return typeId != 'exam';
    case 'full':
    default:
      return true;
  }
}

// ── Playback scope ──────────────────────────────────────────────────────────

const Map<String, String> kScopeLabels = {
  'all': 'All',
  'architecture': 'Architecture',
  'construction': 'Construction',
  'structure': 'Structure',
};

const List<String> kScopeOrder = ['all', 'architecture', 'construction', 'structure'];

List<String> subjectsForScope(String scope) =>
    scope == 'all' ? kSubjectOrder : [scope];

// ── Asset paths ─────────────────────────────────────────────────────────────

String audioAssetPath(String subject, String topic, String type) =>
    'assets/audio/$subject/$topic/$type.mp3';

String textAssetPath(String subject, String topic, String type) =>
    'assets/text/$subject/$topic/$type.txt';

/// `educational_facilities` → `Educational Facilities`
String formatLabel(String id) => id
    .split('_')
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

// ── A single playable item ──────────────────────────────────────────────────

class PlaylistTrack {
  const PlaylistTrack(this.subject, this.topic, this.type);
  final String subject;
  final String topic;
  final String type;

  String get id => '$subject|$topic|$type';
  String get audioPath => audioAssetPath(subject, topic, type);
  String get mediaTitle => '${formatLabel(topic)} · ${contentTypeLabel(type)}';

  String label() =>
      '${kSubjectLabels[subject]} / ${formatLabel(topic)} / ${contentTypeLabel(type)}';
}

// ── Runtime asset discovery ─────────────────────────────────────────────────
//
// Discovers which `<type>.mp3` files are actually bundled, so the UI and
// playlist adapt to whatever content exists per topic (existing core/practical/
// trap/exam today; deep/exam after regeneration) with no code change.

class AssetCatalog {
  AssetCatalog._();

  static Set<String> _audio = <String>{};
  static bool _loaded = false;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      _audio = manifest
          .listAssets()
          .where((a) => a.startsWith('assets/audio/') && a.endsWith('.mp3'))
          .toSet();
    } catch (_) {
      _audio = <String>{};
    }
    _loaded = true;
  }

  /// Content types available for a topic, in registry order.
  static List<String> typesFor(String subject, String topic) => kContentTypeOrder
      .where((id) => _audio.contains(audioAssetPath(subject, topic, id)))
      .toList();

  static bool hasAudio(String subject, String topic, String type) =>
      _audio.contains(audioAssetPath(subject, topic, type));
}
