import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart' show MediaItem;
import 'package:shared_preferences/shared_preferences.dart';

import 'curriculum.dart';

/// Home screen. Owns the audio engine (just_audio + just_audio_background) and
/// persists playback position so it survives app close / kill / reboot.
///
/// UI layout is preserved from the original Cupertino design; only the playback
/// layer and content-type model changed.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final AudioPlayer _player = AudioPlayer();
  SharedPreferences? _prefs;

  // Persisted preference keys.
  static const _kScope = 'scope';
  static const _kMode = 'mode';
  static const _kSubject = 'subject';
  static const _kTopic = 'topic';
  static const _kType = 'type';
  static const _kSpeed = 'speed';
  static const _kPositionMs = 'positionMs';
  static const _kTrackId = 'trackId';

  // Selection / settings.
  String _scope = 'all';
  String _mode = 'full';
  String _selectedSubject = 'architecture';
  String _selectedTopic = 'educational_facilities';
  String _selectedType = 'deep';
  List<String> _availableTypes = const [];

  // Playlist (whole list is loaded into the player for gapless continuity +
  // lock-screen next).
  List<PlaylistTrack> _playlist = const [];

  // Player state mirrors.
  bool _playing = false;
  ProcessingState _processing = ProcessingState.idle;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;

  // Seek-drag handling.
  bool _isSeeking = false;
  double _seekValue = 0.0;

  // Text view.
  String? _currentText;
  String? _textError;
  bool _isLoadingText = true;
  final Map<String, String> _textCache = {};

  int _lastPersistSecond = -1;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.07).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _wirePlayerStreams();
    _bootstrap();
  }

  void _wirePlayerStreams() {
    _player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _playing = state.playing;
        _processing = state.processingState;
      });
      if (state.playing) {
        _pulseController.repeat(reverse: true);
      } else {
        _pulseController.stop();
        _pulseController.reset();
      }
    });

    _player.positionStream.listen((p) {
      if (!mounted) return;
      if (!_isSeeking) setState(() => _position = p);
      _maybePersistPosition(p);
    });

    _player.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _duration = d);
    });

    // When the player advances to the next track (autoplay or lock-screen
    // "next"), follow it in the UI and load its text.
    _player.currentIndexStream.listen((index) {
      if (!mounted || index == null || index < 0 || index >= _playlist.length) {
        return;
      }
      final track = _playlist[index];
      setState(() {
        _selectedSubject = track.subject;
        _selectedTopic = track.topic;
        _availableTypes = AssetCatalog.typesFor(track.subject, track.topic);
        _selectedType = track.type;
      });
      _loadText();
      _persist();
    });
  }

  // ── Bootstrap: discover assets, restore saved state, load playlist ─────────

  Future<void> _bootstrap() async {
    await AssetCatalog.ensureLoaded();
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;

    _scope = prefs.getString(_kScope) ?? 'all';
    _mode = prefs.getString(_kMode) ?? 'full';
    _speed = prefs.getDouble(_kSpeed) ?? 1.0;

    final savedSubject = prefs.getString(_kSubject);
    final savedTopic = prefs.getString(_kTopic);
    final savedType = prefs.getString(_kType);
    final savedTrackId = prefs.getString(_kTrackId);
    final savedPosMs = prefs.getInt(_kPositionMs) ?? 0;

    _selectedSubject = (savedSubject != null && kSubjectTopics.containsKey(savedSubject))
        ? savedSubject
        : kSubjectOrder.first;
    final topics = kSubjectTopics[_selectedSubject]!;
    _selectedTopic =
        (savedTopic != null && topics.contains(savedTopic)) ? savedTopic : topics.first;
    _availableTypes = AssetCatalog.typesFor(_selectedSubject, _selectedTopic);
    _selectedType = (savedType != null && _availableTypes.contains(savedType))
        ? savedType
        : (_availableTypes.isNotEmpty ? _availableTypes.first : 'deep');

    await _rebuildPlaylist(
      restoreTrackId: savedTrackId,
      initialPositionMs: savedPosMs,
    );
    await _loadText();

    if (mounted) setState(() {});
  }

  // ── Playlist building ──────────────────────────────────────────────────────

  List<PlaylistTrack> _buildTracks() {
    final tracks = <PlaylistTrack>[];
    for (final subject in subjectsForScope(_scope)) {
      for (final topic in kSubjectTopics[subject]!) {
        for (final type in AssetCatalog.typesFor(subject, topic)) {
          if (studyModeIncludes(_mode, type)) {
            tracks.add(PlaylistTrack(subject, topic, type));
          }
        }
      }
    }
    return tracks;
  }

  int _indexOf(String subject, String topic, String type) =>
      _playlist.indexWhere(
        (t) => t.subject == subject && t.topic == topic && t.type == type,
      );

  /// Rebuilds the player's audio source from the current scope + study mode.
  Future<void> _rebuildPlaylist({
    String? restoreTrackId,
    int initialPositionMs = 0,
    bool autoplay = false,
  }) async {
    final tracks = _buildTracks();
    _playlist = tracks;

    if (tracks.isEmpty) {
      await _safeStop();
      return;
    }

    // Pick the start index: explicit restore id wins, else current selection.
    int idx = -1;
    if (restoreTrackId != null) {
      idx = tracks.indexWhere((t) => t.id == restoreTrackId);
    }
    if (idx < 0) idx = _indexOf(_selectedSubject, _selectedTopic, _selectedType);
    if (idx < 0) idx = 0;

    final source = ConcatenatingAudioSource(
      children: [
        for (final t in tracks)
          AudioSource.asset(
            t.audioPath,
            tag: MediaItem(
              id: t.id,
              album: kSubjectLabels[t.subject] ?? 'Study Audio',
              title: t.mediaTitle,
            ),
          ),
      ],
    );

    try {
      await _player.setAudioSource(
        source,
        initialIndex: idx,
        initialPosition: Duration(milliseconds: initialPositionMs),
      );
      await _player.setSpeed(_speed);
      if (autoplay) _player.play();
    } catch (_) {
      // Stability first: a load failure must never crash the UI.
    }
  }

  // ── Selection handlers ─────────────────────────────────────────────────────

  Future<void> _selectScope(String scope) async {
    if (_scope == scope) return;
    setState(() {
      _scope = scope;
      // Keep the browsed subject consistent with a single-subject scope.
      if (scope != 'all' && _selectedSubject != scope) {
        _selectedSubject = scope;
        _selectedTopic = kSubjectTopics[scope]!.first;
        _availableTypes = AssetCatalog.typesFor(_selectedSubject, _selectedTopic);
        _selectedType = _firstTypeOrKeep();
      }
    });
    await _rebuildPlaylist();
    await _loadText();
    _persist();
  }

  Future<void> _selectMode(String mode) async {
    if (_mode == mode) return;
    setState(() => _mode = mode);
    await _rebuildPlaylist();
    await _loadText();
    _persist();
  }

  Future<void> _selectSubject(String subject) async {
    if (_selectedSubject == subject) return;
    setState(() {
      _selectedSubject = subject;
      _selectedTopic = kSubjectTopics[subject]!.first;
      _availableTypes = AssetCatalog.typesFor(_selectedSubject, _selectedTopic);
      _selectedType = _firstTypeOrKeep();
    });
    await _cueSelection();
  }

  Future<void> _selectTopic(String topic) async {
    if (_selectedTopic == topic) return;
    setState(() {
      _selectedTopic = topic;
      _availableTypes = AssetCatalog.typesFor(_selectedSubject, _selectedTopic);
      _selectedType = _firstTypeOrKeep();
    });
    await _cueSelection();
  }

  Future<void> _selectType(String type) async {
    if (_selectedType == type) return;
    setState(() => _selectedType = type);
    await _cueSelection();
  }

  String _firstTypeOrKeep() {
    if (_availableTypes.contains(_selectedType)) return _selectedType;
    return _availableTypes.isNotEmpty ? _availableTypes.first : _selectedType;
  }

  /// Cue the player to the current selection (without auto-playing). If the
  /// selection is outside the current playlist (scope/mode filter), rebuild.
  Future<void> _cueSelection() async {
    final idx = _indexOf(_selectedSubject, _selectedTopic, _selectedType);
    if (idx >= 0) {
      try {
        await _player.seek(Duration.zero, index: idx);
      } catch (_) {}
    } else {
      await _rebuildPlaylist();
    }
    await _loadText();
    _persist();
  }

  // ── Transport ──────────────────────────────────────────────────────────────

  Future<void> _play() async {
    if (_playlist.isEmpty) return;
    try {
      await _player.play();
      await _player.setSpeed(_speed);
    } catch (_) {}
  }

  Future<void> _pause() async {
    try {
      await _player.pause();
    } catch (_) {}
    _persist();
  }

  Future<void> _stop() async {
    await _safeStop();
    _persist();
  }

  Future<void> _safeStop() async {
    // "Stop" = pause and rewind the current track, keeping the source loaded
    // (reliable; avoids reloading on the next play).
    try {
      await _player.pause();
      await _player.seek(Duration.zero, index: _player.currentIndex ?? 0);
      if (mounted) setState(() => _position = Duration.zero);
    } catch (_) {}
  }

  Future<void> _seekTo(double ratio) async {
    if (_duration == Duration.zero) return;
    final target =
        Duration(milliseconds: (ratio * _duration.inMilliseconds).round());
    try {
      await _player.seek(target);
    } catch (_) {}
    if (mounted) setState(() => _position = target);
  }

  Future<void> _changeSpeed(double rate) async {
    setState(() => _speed = rate);
    try {
      await _player.setSpeed(rate);
    } catch (_) {}
    _persist();
  }

  // ── Text loading ────────────────────────────────────────────────────────────

  Future<void> _loadText() async {
    final subject = _selectedSubject;
    final topic = _selectedTopic;
    final type = _selectedType;
    final key = '$subject|$topic|$type';

    if (_textCache.containsKey(key)) {
      setState(() {
        _currentText = _textCache[key];
        _isLoadingText = false;
        _textError = null;
      });
      return;
    }

    setState(() {
      _isLoadingText = true;
      _textError = null;
    });

    try {
      final content = await rootBundle.loadString(textAssetPath(subject, topic, type));
      _textCache[key] = content;
      if (!mounted ||
          _selectedSubject != subject ||
          _selectedTopic != topic ||
          _selectedType != type) {
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
          _selectedType != type) {
        return;
      }
      setState(() {
        _textError = 'テキストを読み込めませんでした。';
        _isLoadingText = false;
      });
    }
  }

  // ── Persistence ──────────────────────────────────────────────────────────────

  void _maybePersistPosition(Duration p) {
    final sec = p.inSeconds;
    if (sec != _lastPersistSecond && sec % 5 == 0) {
      _lastPersistSecond = sec;
      _persist();
    }
  }

  void _persist() {
    final prefs = _prefs;
    if (prefs == null) return;
    prefs.setString(_kScope, _scope);
    prefs.setString(_kMode, _mode);
    prefs.setString(_kSubject, _selectedSubject);
    prefs.setString(_kTopic, _selectedTopic);
    prefs.setString(_kType, _selectedType);
    prefs.setDouble(_kSpeed, _speed);
    prefs.setInt(_kPositionMs, _player.position.inMilliseconds);
    final idx = _player.currentIndex;
    if (idx != null && idx >= 0 && idx < _playlist.length) {
      prefs.setString(_kTrackId, _playlist[idx].id);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Save aggressively whenever the app leaves the foreground, so an OS kill
    // or reboot still resumes at the right spot.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _persist();
    }
  }

  @override
  void dispose() {
    _persist();
    WidgetsBinding.instance.removeObserver(this);
    _player.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  // ── Derived getters ──────────────────────────────────────────────────────────

  bool get _isPlaying => _playing;
  bool get _isActive => _playing || _processing == ProcessingState.ready;
  bool get _hasAudio => _playlist.isNotEmpty;

  PlaylistTrack? get _currentTrack {
    final i = _player.currentIndex;
    if (i == null || i < 0 || i >= _playlist.length) return null;
    return _playlist[i];
  }

  PlaylistTrack? get _nextTrack {
    final i = _player.currentIndex;
    if (i == null) return null;
    final n = i + 1;
    return n < _playlist.length ? _playlist[n] : null;
  }

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

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final topics = kSubjectTopics[_selectedSubject]!;

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
                    _buildSegmented<String>(
                      groupValue: _mode,
                      items: kStudyModeOrder,
                      labelFor: (m) => kStudyModeLabels[m]!,
                      onChanged: _selectMode,
                      fontSize: 11,
                    ),
                    const SizedBox(height: 10),
                    _buildLabel('再生範囲'),
                    _buildSegmented<String>(
                      groupValue: _scope,
                      items: kScopeOrder,
                      labelFor: (s) => kScopeLabels[s]!,
                      onChanged: _selectScope,
                      fontSize: 10,
                      hPad: 4,
                    ),
                    const SizedBox(height: 10),
                    _buildLabel('科目（テキスト閲覧）'),
                    _buildSegmented<String>(
                      groupValue: _selectedSubject,
                      items: kSubjectOrder,
                      labelFor: (s) => kSubjectLabels[s]!,
                      onChanged: _selectSubject,
                      fontSize: 12,
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
                                formatLabel(topic),
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
                    _buildSectionSelector(),
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

  Widget _buildSegmented<T extends Object>({
    required T groupValue,
    required List<T> items,
    required String Function(T) labelFor,
    required ValueChanged<T> onChanged,
    double fontSize = 12,
    double hPad = 8,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: CupertinoSlidingSegmentedControl<T>(
        groupValue: groupValue,
        children: {
          for (final item in items)
            item: Padding(
              padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 8),
              child: Text(labelFor(item), style: TextStyle(fontSize: fontSize)),
            ),
        },
        onValueChanged: (value) {
          if (value != null) onChanged(value);
        },
      ),
    );
  }

  Widget _buildSectionSelector() {
    if (_availableTypes.isEmpty) {
      return _buildLabel('（音声なし）');
    }
    if (_availableTypes.length == 1) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(
          contentTypeLabel(_availableTypes.first),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      );
    }
    return _buildSegmented<String>(
      groupValue: _availableTypes.contains(_selectedType)
          ? _selectedType
          : _availableTypes.first,
      items: _availableTypes,
      labelFor: contentTypeLabel,
      onChanged: _selectType,
      fontSize: 12,
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
    final current = _currentTrack?.label() ??
        '${kSubjectLabels[_selectedSubject]} / ${formatLabel(_selectedTopic)} / ${contentTypeLabel(_selectedType)}';
    final next = _nextTrack?.label() ?? 'なし（最後のトラック）';

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
              'プレイリスト: ${(_player.currentIndex ?? 0) + 1} / ${_playlist.length}',
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
            '${kSubjectLabels[_selectedSubject]} / ${formatLabel(_selectedTopic)} / ${contentTypeLabel(_selectedType)}',
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
            '${contentTypeLabel(_selectedType)} Audio',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label,
            ),
          ),
          const SizedBox(height: 28),
          _buildTransportRow(),
          const SizedBox(height: 28),
          _buildSeekBar(context),
          const SizedBox(height: 20),
          _buildSpeedControl(),
          const SizedBox(height: 16),
          _buildStopButton(context),
        ],
      ),
    );
  }

  Widget _buildTransportRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildSkipButton(
          icon: CupertinoIcons.backward_fill,
          onTap: () async {
            try {
              await _player.seekToPrevious();
            } catch (_) {}
          },
        ),
        const SizedBox(width: 28),
        _buildMainPlayButton(),
        const SizedBox(width: 28),
        _buildSkipButton(
          icon: CupertinoIcons.forward_fill,
          onTap: () async {
            try {
              await _player.seekToNext();
            } catch (_) {}
          },
        ),
      ],
    );
  }

  Widget _buildSkipButton({required IconData icon, required VoidCallback onTap}) {
    final enabled = _hasAudio;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Icon(
        icon,
        size: 28,
        color: enabled ? CupertinoColors.systemBlue : CupertinoColors.systemGrey3,
      ),
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
          groupValue: _speed,
          children: <double, Widget>{
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
            if (value != null) _changeSpeed(value);
          },
        ),
      ],
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
          onChanged: (v) => setState(() => _seekValue = v),
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
                            (_seekValue * _duration.inMilliseconds).round())
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
