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

// Topics are NOT hardcoded. They are discovered at runtime from the bundled
// audio assets (see [AssetCatalog]); a topic exists for a subject when
// assets/audio/<subject>/<topic>/deep.mp3 is bundled. Use
// `AssetCatalog.topicsFor(subject)` / `AssetCatalog.hasSubject(subject)`.

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

// ── Japanese topic display names ─────────────────────────────────────────────
//
// UI-only label map. Internal keys (and all asset/folder paths) stay English;
// this maps each topic key to its Japanese display name. Missing keys fall back
// to the humanized English label via [topicLabel]. Keep keys in sync with the
// bundled `assets/audio/<subject>/<topic>/` folders — do NOT rename folders.
const Map<String, String> kTopicLabelsJa = {
  // architecture
  'accessibility_design': 'バリアフリー設計',
  'dimensional_planning': '寸法計画',
  'educational_facilities': '教育施設',
  'elderly_and_medical_facilities': '高齢者・医療施設',
  'glazing_and_roofing': 'ガラス・屋根',
  'japanese_architecture_history': '日本建築史',
  'library_museum_sports': '図書館・博物館・スポーツ施設',
  'office_and_theater': '事務所・劇場',
  'retail_buildings': '商業施設',
  'urban_planning': '都市計画',
  'western_eastern_architecture_history': '西洋・東洋建築史',
  'windows_and_hardware': '窓・建具金物',
  // construction
  'concrete_mix_and_quality': 'コンクリートの調合・品質',
  'concrete_placing': 'コンクリートの打込み',
  'concrete_types': 'コンクリートの種類',
  'earthwork_and_shoring': '土工事・山留め',
  'equipment_work': '設備工事',
  'formwork': '型枠工事',
  'foundation_and_piling': '基礎・杭工事',
  'foundation_work': '基礎工事',
  'glass_and_fittings': 'ガラス・建具工事',
  'interior_exterior_finishing': '内外装仕上げ',
  'plastering_and_tile': '左官・タイル工事',
  'precast_concrete': 'プレキャストコンクリート',
  'reinforcement_work': '鉄筋工事',
  'renovation_works': '改修工事',
  'seismic_retrofit': '耐震改修',
  'site_and_ground_survey': '敷地・地盤調査',
  'steel_frame_bolts': '鉄骨ボルト接合',
  'steel_frame_erection': '鉄骨建方',
  'steel_frame_materials': '鉄骨材料',
  'temporary_work': '仮設工事',
  'terminology': '用語',
  'waterproofing': '防水工事',
  'wood_work': '木工事',
  // structure
  'buckling_and_beam_deflection': '座屈・梁のたわみ',
  'column_base_and_seismic_design': '柱脚・耐震設計',
  'concrete_material': 'コンクリート材料',
  'foundation_structural_design': '基礎構造設計',
  'ground_and_soil': '地盤・土質',
  'metal_materials': '金属材料',
  'other_structures': 'その他の構造',
  'rc_beams': 'RC梁',
  'rc_columns': 'RC柱',
  'rc_other': 'RCその他',
  'rc_seismic_design': 'RC耐震設計',
  'rc_shear_walls': 'RC耐力壁',
  'src_structure': 'SRC構造',
  'steel_connection': '鉄骨接合',
  'steel_material_properties': '鋼材の性質',
  'wood_material': '木質材料',
  'wood_structure': '木構造',
};

/// Japanese display name for a topic key, falling back to the humanized English
/// label when no translation exists. Use this everywhere a topic is shown.
String topicLabel(String topic) => kTopicLabelsJa[topic] ?? formatLabel(topic);

// ── A single playable item ──────────────────────────────────────────────────

class PlaylistTrack {
  const PlaylistTrack(this.subject, this.topic, this.type);
  final String subject;
  final String topic;
  final String type;

  String get id => '$subject|$topic|$type';
  String get audioPath => audioAssetPath(subject, topic, type);
  String get mediaTitle => '${topicLabel(topic)} · ${contentTypeLabel(type)}';

  String label() =>
      '${kSubjectLabels[subject]} / ${topicLabel(topic)} / ${contentTypeLabel(type)}';
}

// ── Runtime asset discovery ─────────────────────────────────────────────────
//
// Discovers which `<type>.mp3` files are actually bundled, so the UI and
// playlist adapt to whatever content exists per topic (existing core/practical/
// trap/exam today; deep/exam after regeneration) with no code change.

class AssetCatalog {
  AssetCatalog._();

  static Set<String> _audio = <String>{};
  static Map<String, List<String>> _topics = <String, List<String>>{};
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
    _topics = _discoverTopics(_audio);
    _loaded = true;
  }

  /// Builds `{subject: [topics...]}` from bundled
  /// `assets/audio/<subject>/<topic>/deep.mp3` paths. A topic is included only
  /// when its deep lecture is present; topics are sorted for stable ordering.
  static Map<String, List<String>> _discoverTopics(Set<String> audio) {
    final bySubject = <String, List<String>>{};
    for (final path in audio) {
      // assets/audio/<subject>/<topic>/<type>.mp3
      //   -> parts: [assets, audio, subject, topic, file]
      final parts = path.split('/');
      if (parts.length != 5 || parts[4] != 'deep.mp3') continue;
      (bySubject[parts[2]] ??= <String>[]).add(parts[3]);
    }
    for (final list in bySubject.values) {
      list.sort();
    }
    return bySubject;
  }

  /// Runtime-discovered topics for a subject, in stable sorted order.
  static List<String> topicsFor(String subject) =>
      _topics[subject] ?? const <String>[];

  /// Whether any bundled topic exists for this subject.
  static bool hasSubject(String subject) => _topics.containsKey(subject);

  /// Content types available for a topic, in registry order.
  static List<String> typesFor(String subject, String topic) => kContentTypeOrder
      .where((id) => _audio.contains(audioAssetPath(subject, topic, id)))
      .toList();

  static bool hasAudio(String subject, String topic, String type) =>
      _audio.contains(audioAssetPath(subject, topic, type));
}
