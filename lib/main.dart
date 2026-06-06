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

const String _coreAudioAsset = 'audio/foundation_work/core.mp3';

const Map<String, String> _sectionLabels = {
  'core': 'Core',
  'practical': 'Practical',
  'trap': 'Trap',
  'exam': 'Exam',
};

const Map<String, String> _sectionTextPaths = {
  'core': 'assets/text/foundation_work/core.txt',
  'practical': 'assets/text/foundation_work/practical.txt',
  'trap': 'assets/text/foundation_work/trap.txt',
  'exam': 'assets/text/foundation_work/exam.txt',
};

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final AudioPlayer _player = AudioPlayer();

  String _selectedSection = 'core';
  String? _currentText;
  String? _textError;
  bool _isLoadingText = true;
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

    _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _position = Duration.zero;
        _seekValue = 0.0;
      });
    });

    _initPlayer();
    _loadSectionText(_selectedSection);
  }

  Future<void> _initPlayer() async {
    await _player.setReleaseMode(ReleaseMode.stop);
    await _player.setSource(AssetSource(_coreAudioAsset));
  }

  Future<void> _loadSectionText(String section) async {
    if (_textCache.containsKey(section)) {
      setState(() {
        _currentText = _textCache[section];
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
      final content =
          await rootBundle.loadString(_sectionTextPaths[section]!);
      _textCache[section] = content;
      if (!mounted || _selectedSection != section) return;
      setState(() {
        _currentText = content;
        _isLoadingText = false;
      });
    } catch (e) {
      if (!mounted || _selectedSection != section) return;
      setState(() {
        _textError = 'テキストを読み込めませんでした。';
        _isLoadingText = false;
      });
    }
  }

  Future<void> _selectSection(String section) async {
    if (_selectedSection == section) return;

    setState(() => _selectedSection = section);

    if (section != 'core' && _isPlaying) {
      await _pause();
    }

    await _loadSectionText(section);
  }

  @override
  void dispose() {
    _player.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    if (_playerState == PlayerState.paused) {
      await _player.resume();
    } else {
      if (_playerState == PlayerState.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play(AssetSource(_coreAudioAsset));
    }
    await _player.setPlaybackRate(_playbackRate);
  }

  Future<void> _changePlaybackRate(double rate) async {
    setState(() => _playbackRate = rate);
    await _player.setPlaybackRate(rate);
  }

  Future<void> _pause() async {
    await _player.pause();
  }

  Future<void> _stop() async {
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
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Text(
                'Foundation Work',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: CupertinoColors.label,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: CupertinoSlidingSegmentedControl<String>(
                groupValue: _selectedSection,
                children: {
                  for (final entry in _sectionLabels.entries)
                    entry.key: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      child: Text(
                        entry.value,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                },
                onValueChanged: (value) {
                  if (value != null) {
                    _selectSection(value);
                  }
                },
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_selectedSection == 'core') ...[
                      _buildPlayerCard(context),
                      const SizedBox(height: 20),
                    ],
                    _buildTextCard(context),
                  ],
                ),
              ),
            ),
          ],
        ),
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
            _sectionLabels[_selectedSection] ?? '',
            style: const TextStyle(
              fontSize: 17,
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
          const Text(
            'Core Audio',
            textAlign: TextAlign.center,
            style: TextStyle(
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
