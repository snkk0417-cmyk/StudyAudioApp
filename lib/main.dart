import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const StudyAudioApp());
}

class StudyAudioApp extends StatelessWidget {
  const StudyAudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const CupertinoApp(
      title: 'Study Audio',
      theme: CupertinoThemeData(
        brightness: Brightness.light,
        primaryColor: CupertinoColors.systemBlue,
      ),
      home: HomeScreen(),
    );
  }
}

// ── カリキュラム定義 ──────────────────────────────────────────

const List<String> _subjectOrder = [
  'architecture',
  'construction',
  'structure',
];

const Map<String, String> _subjectLabels = {
  'architecture': 'Architecture',
  'construction': 'Construction',
  'structure': 'Structure',
};

const Map<String, List<String>> _subjectTopics = {
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

const Map<String, String> _sectionLabels = {
  'core': 'Core',
  'practical': 'Practical',
  'trap': 'Trap',
  'exam': 'Exam',
};

const List<String> _sections = ['core', 'practical', 'trap', 'exam'];

const Map<String, String> _playbackScopeLabels = {
  'all': 'All Subjects',
  'architecture': 'Architecture',
  'construction': 'Construction',
  'structure': 'Structure',
};

const Map<String, String> _studyModeLabels = {
  'beginner': 'Beginner',
  'exam': 'Exam',
  'fullCourse': 'Full',
};

const Map<String, List<String>> _studyModeSections = {
  'beginner': ['core', 'practical', 'trap'],
  'exam': ['trap', 'exam'],
  'fullCourse': ['core', 'practical', 'trap', 'exam'],
};

// ── プレイリスト ──────────────────────────────────────────────

class PlaylistTrack {
  const PlaylistTrack({
    required this.subject,
    required this.topic,
    required this.section,
  });

  final String subject;
  final String topic;
  final String section;

  String get cacheKey => '$subject|$topic|$section';

  String label() {
    return '${_subjectLabels[subject]} / ${_formatLabel(topic)} / ${_sectionLabels[section]}';
  }
}

// ── ユーティリティ ────────────────────────────────────────────

String _formatLabel(String id) {
  return id
      .split('_')
      .map((word) =>
          word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}

String _audioFolderForSubject(String subject) {
  return subject == 'structure' ? 'sturucture' : subject;
}

String _textAssetPath(String subject, String topic, String section) {
  return 'assets/text/$subject/$topic/$section.txt';
}

String _audioAssetPath(String subject, String topic, String section) {
  final audioSubject = _audioFolderForSubject(subject);
  return 'audio/$audioSubject/$topic/$section.mp3';
}

String _audioBundlePath(String subject, String topic, String section) {
  final audioSubject = _audioFolderForSubject(subject);
  return 'assets/audio/$audioSubject/$topic/$section.mp3';
}

List<String> _subjectsForScope(String scope) {
  if (scope == 'all') return _subjectOrder;
  return [scope];
}

// ── 画面 ──────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final AudioPlayer _player = AudioPlayer();

  // デフォルト: All Subjects + Beginner Mode
  String _playbackScope = 'all';
  String _studyMode = 'beginner';

  String _selectedSubject = 'architecture';
  late String _selectedTopic;
  String _selectedSection = 'core';

  List<PlaylistTrack> _playlist = [];
  int _playlistIndex = 0;
  bool _isAutoPlaying = false;
  bool _isBuildingPlaylist = false;
  String? _playlistCacheKey;

  String? _currentText;
  String? _textError;
  bool _isLoadingText = true;
  bool _hasAudio = false;
  final Map<String, String> _textCache = {};

  PlayerState _playerState = PlayerState.stopped;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  double _playbackRate = 1.0;

  bool _isSeeking = false;
  double _seekValue = 0.0;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _selectedTopic = _subjectTopics[_selectedSubject]!.first;

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.07).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _playerState = state);
      if (state == PlayerState.playing) {
        _pulseController.repeat(reverse: true);
      } else {
        _pulseController.stop();
        _pulseController.reset();
      }
    });

    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });

    _player.onPositionChanged.listen((p) {
      if (mounted && !_isSeeking) setState(() => _position = p);
    });

    _player.onPlayerComplete.listen((_) async {
      if (!mounted) return;
      setState(() {
        _position = Duration.zero;
        _seekValue = 0.0;
      });
      if (_isAutoPlaying) {
        await _playNextInPlaylist();
      }
    });

    _loadCurrentContent();
    _ensurePlaylist();
  }

  String get _currentAudioAsset =>
      _audioAssetPath(_selectedSubject, _selectedTopic, _selectedSection);

  String get _playlistSettingsKey => '$_playbackScope|$_studyMode';

  PlaylistTrack? get _currentTrack =>
      _playlist.isEmpty || _playlistIndex >= _playlist.length
          ? null
          : _playlist[_playlistIndex];

  PlaylistTrack? get _nextTrack =>
      _playlist.isEmpty || _playlistIndex + 1 >= _playlist.length
          ? null
          : _playlist[_playlistIndex + 1];

  Future<bool> _bundleAssetExists(String bundlePath) async {
    try {
      await rootBundle.load(bundlePath);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidatePlaylist() {
    _playlist = [];
    _playlistCacheKey = null;
  }

  Future<void> _ensurePlaylist() async {
    final key = _playlistSettingsKey;
    if (_playlistCacheKey == key && _playlist.isNotEmpty) return;

    setState(() => _isBuildingPlaylist = true);

    final subjects = _subjectsForScope(_playbackScope);
    final sections = _studyModeSections[_studyMode]!;
    final tracks = <PlaylistTrack>[];

    for (final subject in subjects) {
      for (final topic in _subjectTopics[subject]!) {
        for (final section in sections) {
          final bundlePath = _audioBundlePath(subject, topic, section);
          if (await _bundleAssetExists(bundlePath)) {
            tracks.add(
              PlaylistTrack(
                subject: subject,
                topic: topic,
                section: section,
              ),
            );
          }
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _playlist = tracks;
      _playlistCacheKey = key;
      _isBuildingPlaylist = false;
      _playlistIndex = _indexInPlaylist(
        _selectedSubject,
        _selectedTopic,
        _selectedSection,
      );
      if (_playlistIndex < 0) _playlistIndex = 0;
    });
  }

  int _indexInPlaylist(String subject, String topic, String section) {
    return _playlist.indexWhere(
      (t) =>
          t.subject == subject &&
          t.topic == topic &&
          t.section == section,
    );
  }

  Future<void> _loadCurrentContent() async {
    await _loadSectionText();
    await _initPlayer();
    if (mounted) {
      setState(() {
        final idx = _indexInPlaylist(
          _selectedSubject,
          _selectedTopic,
          _selectedSection,
        );
        if (idx >= 0) _playlistIndex = idx;
      });
    }
  }

  Future<void> _initPlayer() async {
    final bundlePath = _audioBundlePath(
      _selectedSubject,
      _selectedTopic,
      _selectedSection,
    );
    final exists = await _bundleAssetExists(bundlePath);
    if (!exists) {
      if (!mounted) return;
      setState(() {
        _hasAudio = false;
        _position = Duration.zero;
        _seekValue = 0.0;
        _duration = Duration.zero;
      });
      return;
    }

    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setSource(AssetSource(_currentAudioAsset));
      if (!mounted) return;
      setState(() {
        _hasAudio = true;
        _position = Duration.zero;
        _seekValue = 0.0;
        _duration = Duration.zero;
      });
    } catch (_) {
      if (!mounted) return;
      if (_isPlaying) await _pause();
      setState(() {
        _hasAudio = false;
        _position = Duration.zero;
        _seekValue = 0.0;
        _duration = Duration.zero;
      });
    }
  }

  Future<void> _loadSectionText() async {
    final subject = _selectedSubject;
    final topic = _selectedTopic;
    final section = _selectedSection;
    final cacheKey = '$subject|$topic|$section';

    if (_textCache.containsKey(cacheKey)) {
      setState(() {
        _currentText = _textCache[cacheKey];
        _isLoadingText = false;
        _textError = null;
      });
      return;
    }

    setState(() {
      _isLoadingText = true;
      _textError = null;
    });

    final path = _textAssetPath(subject, topic, section);

    try {
      final content = await rootBundle.loadString(path);
      _textCache[cacheKey] = content;
      if (!mounted ||
          _selectedSubject != subject ||
          _selectedTopic != topic ||
          _selectedSection != section) {
        return;
      }
      setState(() {
        _currentText = content;
        _isLoadingText = false;
      });
    } catch (_) {
      if (!mounted ||
          _selectedSubject != subject ||
          _selectedTopic != topic ||
          _selectedSection != section) {
        return;
      }
      setState(() {
        _textError = 'テキストを読み込めませんでした。';
        _isLoadingText = false;
      });
    }
  }

  Future<void> _selectPlaybackScope(String scope) async {
    if (_playbackScope == scope) return;
    if (_isPlaying || _isAutoPlaying) await _stop();

    setState(() => _playbackScope = scope);
    _invalidatePlaylist();
    await _ensurePlaylist();
  }

  Future<void> _selectStudyMode(String mode) async {
    if (_studyMode == mode) return;
    if (_isPlaying || _isAutoPlaying) await _stop();

    setState(() => _studyMode = mode);
    _invalidatePlaylist();
    await _ensurePlaylist();
  }

  Future<void> _selectSubject(String subject) async {
    if (_selectedSubject == subject) return;
    if (_isPlaying || _isAutoPlaying) await _stop();

    setState(() {
      _selectedSubject = subject;
      _selectedTopic = _subjectTopics[subject]!.first;
      _selectedSection = 'core';
      _isAutoPlaying = false;
    });

    await _loadCurrentContent();
  }

  Future<void> _selectTopic(String topic) async {
    if (_selectedTopic == topic) return;
    if (_isPlaying || _isAutoPlaying) await _stop();

    setState(() {
      _selectedTopic = topic;
      _selectedSection = 'core';
      _isAutoPlaying = false;
    });

    await _loadCurrentContent();
  }

  Future<void> _selectSection(String section) async {
    if (_selectedSection == section) return;
    if (_isPlaying || _isAutoPlaying) await _stop();

    setState(() {
      _selectedSection = section;
      _isAutoPlaying = false;
    });

    await _loadCurrentContent();
  }

  Future<void> _playPlaylistAt(int index) async {
    if (index < 0 || index >= _playlist.length) {
      _isAutoPlaying = false;
      return;
    }

    _playlistIndex = index;
    final track = _playlist[index];

    setState(() {
      _selectedSubject = track.subject;
      _selectedTopic = track.topic;
      _selectedSection = track.section;
    });

    await _loadSectionText();
    await _initPlayer();

    if (!_hasAudio) {
      await _playNextInPlaylist();
      return;
    }

    await _player.play(AssetSource(_currentAudioAsset));
    await _player.setPlaybackRate(_playbackRate);
  }

  Future<void> _playNextInPlaylist() async {
    if (!_isAutoPlaying) return;
    await _playPlaylistAt(_playlistIndex + 1);
  }

  @override
  void dispose() {
    _player.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    await _ensurePlaylist();
    if (_playlist.isEmpty) return;

    if (_playerState == PlayerState.paused) {
      _isAutoPlaying = true;
      await _player.resume();
      await _player.setPlaybackRate(_playbackRate);
      return;
    }

    final index = _indexInPlaylist(
      _selectedSubject,
      _selectedTopic,
      _selectedSection,
    );
    _isAutoPlaying = true;
    await _playPlaylistAt(index >= 0 ? index : 0);
  }

  Future<void> _changePlaybackRate(double rate) async {
    setState(() => _playbackRate = rate);
    await _player.setPlaybackRate(rate);
  }

  Future<void> _pause() async {
    await _player.pause();
  }

  Future<void> _stop() async {
    _isAutoPlaying = false;
    await _player.stop();
    setState(() {
      _position = Duration.zero;
      _seekValue = 0.0;
    });
  }

  Future<void> _seekTo(double ratio) async {
    if (_duration == Duration.zero) return;
    final target = Duration(
      milliseconds: (ratio * _duration.inMilliseconds).round(),
    );
    await _player.seek(target);
    setState(() => _position = target);
  }

  bool get _isPlaying => _playerState == PlayerState.playing;
  bool get _isActive =>
      _playerState == PlayerState.playing ||
      _playerState == PlayerState.paused;

  double get _sliderValue {
    if (_isSeeking) return _seekValue;
    if (_duration.inMilliseconds == 0) return 0.0;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final topics = _subjectTopics[_selectedSubject]!;

    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                      child: Text(
                        'Study Audio',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          color: CupertinoColors.label,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                    _buildLabel('学習モード'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: CupertinoSlidingSegmentedControl<String>(
                        groupValue: _studyMode,
                        children: {
                          for (final entry in _studyModeLabels.entries)
                            entry.key: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 8,
                              ),
                              child: Text(
                                entry.value,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                        },
                        onValueChanged: (value) {
                          if (value != null) _selectStudyMode(value);
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    _buildLabel('再生範囲'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: CupertinoSlidingSegmentedControl<String>(
                        groupValue: _playbackScope,
                        children: {
                          for (final entry in _playbackScopeLabels.entries)
                            entry.key: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 8,
                              ),
                              child: Text(
                                entry.value,
                                style: const TextStyle(fontSize: 10),
                              ),
                            ),
                        },
                        onValueChanged: (value) {
                          if (value != null) _selectPlaybackScope(value);
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    _buildLabel('科目（テキスト閲覧）'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: CupertinoSlidingSegmentedControl<String>(
                        groupValue: _selectedSubject,
                        children: {
                          for (final entry in _subjectLabels.entries)
                            entry.key: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              child: Text(
                                entry.value,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        },
                        onValueChanged: (value) {
                          if (value != null) _selectSubject(value);
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 110,
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: topics.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (context, index) {
                          final topic = topics[index];
                          final isSelected = topic == _selectedTopic;

                          return GestureDetector(
                            onTap: () => _selectTopic(topic),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? const Color(0xFFF0F6FF)
                                    : CupertinoColors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected
                                      ? CupertinoColors.activeBlue
                                      : const Color(0xFFE5E5EA),
                                ),
                              ),
                              child: Text(
                                _formatLabel(topic),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isSelected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: isSelected
                                      ? CupertinoColors.activeBlue
                                      : CupertinoColors.label,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    _buildLabel('セクション（テキスト閲覧）'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: CupertinoSlidingSegmentedControl<String>(
                        groupValue: _selectedSection,
                        children: {
                          for (final section in _sections)
                            section: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              child: Text(
                                _sectionLabels[section]!,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        },
                        onValueChanged: (value) {
                          if (value != null) _selectSection(value);
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: _buildPlaybackStatusCard(),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_hasAudio) ...[
                            _buildPlayerCard(context),
                            const SizedBox(height: 16),
                          ],
                          _buildTextCard(context),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: CupertinoColors.secondaryLabel,
        ),
      ),
    );
  }

  Widget _buildPlaybackStatusCard() {
    final current = _isAutoPlaying && _currentTrack != null
        ? _currentTrack!.label()
        : '${_subjectLabels[_selectedSubject]} / ${_formatLabel(_selectedTopic)} / ${_sectionLabels[_selectedSection]}';

    final next = _isAutoPlaying && _nextTrack != null
        ? _nextTrack!.label()
        : (_isBuildingPlaylist ? 'プレイリスト構築中…' : 'なし（最後のトラック）');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CupertinoColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E5EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '再生中: $current',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '次: $next',
            style: const TextStyle(
              fontSize: 12,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
          if (_playlist.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'プレイリスト: ${_playlistIndex + 1} / ${_playlist.length}',
              style: const TextStyle(
                fontSize: 11,
                color: CupertinoColors.systemGrey,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTextCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      decoration: BoxDecoration(
        color: CupertinoColors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.systemGrey.withValues(alpha: 0.13),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_subjectLabels[_selectedSubject]} / ${_formatLabel(_selectedTopic)} / ${_sectionLabels[_selectedSection]}',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label,
            ),
          ),
          const SizedBox(height: 16),
          if (_isLoadingText)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: CupertinoActivityIndicator(),
              ),
            )
          else if (_textError != null)
            Text(
              _textError!,
              style: const TextStyle(
                fontSize: 15,
                color: CupertinoColors.destructiveRed,
                height: 1.6,
              ),
            )
          else
            Text(
              _currentText ?? '',
              style: const TextStyle(
                fontSize: 15,
                color: CupertinoColors.label,
                height: 1.7,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlayerCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
      decoration: BoxDecoration(
        color: CupertinoColors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.systemGrey.withValues(alpha: 0.13),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            '${_sectionLabels[_selectedSection]} Audio',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label,
            ),
          ),
          const SizedBox(height: 32),
          _buildMainPlayButton(),
          const SizedBox(height: 32),
          _buildSeekBar(context),
          const SizedBox(height: 20),
          _buildSpeedControl(),
          const SizedBox(height: 16),
          _buildStopButton(context),
        ],
      ),
    );
  }

  Widget _buildSpeedControl() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '再生速度',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: CupertinoColors.secondaryLabel,
          ),
        ),
        const SizedBox(height: 10),
        CupertinoSlidingSegmentedControl<double>(
          groupValue: _playbackRate,
          children: {
            1.0: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('1.0x'),
            ),
            1.5: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('1.5x'),
            ),
            2.0: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('2.0x'),
            ),
          },
          onValueChanged: (value) {
            if (value != null) {
              _changePlaybackRate(value);
            }
          },
        ),
      ],
    );
  }

  Widget _buildMainPlayButton() {
    return ScaleTransition(
      scale: _isPlaying ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
      child: GestureDetector(
        onTap: _isPlaying ? _pause : _play,
        child: Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: CupertinoColors.systemBlue,
            boxShadow: [
              BoxShadow(
                color: CupertinoColors.systemBlue.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Icon(
            _isPlaying ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
            color: CupertinoColors.white,
            size: 32,
          ),
        ),
      ),
    );
  }

  Widget _buildSeekBar(BuildContext context) {
    final textStyle = TextStyle(
      fontSize: 12,
      color: CupertinoColors.secondaryLabel.resolveFrom(context),
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Column(
      children: [
        CupertinoSlider(
          value: _sliderValue,
          min: 0.0,
          max: 1.0,
          onChangeStart: (v) {
            setState(() {
              _isSeeking = true;
              _seekValue = v;
            });
          },
          onChanged: (v) {
            setState(() => _seekValue = v);
          },
          onChangeEnd: (v) async {
            setState(() => _isSeeking = false);
            await _seekTo(v);
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _fmt(_isSeeking
                    ? Duration(
                        milliseconds:
                            (_seekValue * _duration.inMilliseconds).round(),
                      )
                    : _position),
                style: textStyle,
              ),
              Text(_fmt(_duration), style: textStyle),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStopButton(BuildContext context) {
    final active = _isActive;
    return GestureDetector(
      onTap: active ? _stop : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
        decoration: BoxDecoration(
          color: active
              ? CupertinoColors.systemRed.withValues(alpha: 0.10)
              : const Color(0xFFF2F2F7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? CupertinoColors.systemRed.withValues(alpha: 0.35)
                : const Color(0xFFE5E5EA),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.stop_fill,
              size: 16,
              color: active
                  ? CupertinoColors.systemRed
                  : CupertinoColors.systemGrey3,
            ),
            const SizedBox(width: 6),
            Text(
              '停止',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: active
                    ? CupertinoColors.systemRed
                    : CupertinoColors.systemGrey3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
