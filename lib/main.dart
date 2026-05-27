import 'package:flutter/cupertino.dart';
import 'package:audioplayers/audioplayers.dart';

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

// assets/audio/ 内のファイル一覧（追加したファイルをここに記述）
const List<String> _audioAssets = [
  'audio/Structure_Steel_Property.mp3',
];

String _trackTitle(String assetPath) {
  final name = assetPath.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot).replaceAll('_', ' ') : name;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final AudioPlayer _player = AudioPlayer();
  final TextEditingController _memoController = TextEditingController();

  final String _currentAsset = _audioAssets.first;
  PlayerState _playerState = PlayerState.stopped;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  // シーク中はスライダーの値を独立して保持する
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
        _playerState = PlayerState.stopped;
        _position = Duration.zero;
        _seekValue = 0.0;
      });
    });
  }

  @override
  void dispose() {
    _player.dispose();
    _memoController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  // ──────────────── 操作 ────────────────

  Future<void> _play() async {
    if (_playerState == PlayerState.paused) {
      await _player.resume();
    } else {
      await _player.play(AssetSource(_currentAsset));
    }
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

  // ──────────────── ヘルパー ────────────────

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

  // ──────────────── ビルド ────────────────

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      navigationBar: const CupertinoNavigationBar(
        middle: Text(
          'Study Audio',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: Color(0xFFF2F2F7),
        border: Border(bottom: BorderSide(color: Color(0x00000000))),
      ),
      child: SafeArea(
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildPlayerCard(context),
                const SizedBox(height: 20),
                _buildMemoCard(context),
              ],
            ),
          ),
        ),
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
          // トラック名
          Text(
            _trackTitle(_currentAsset),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label,
            ),
          ),
          const SizedBox(height: 32),

          // 再生ボタン（中央・大）
          _buildMainPlayButton(),
          const SizedBox(height: 32),

          // シークバー
          _buildSeekBar(context),
          const SizedBox(height: 20),

          // 停止ボタン
          _buildStopButton(context),
        ],
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
              Text(_fmt(_isSeeking
                  ? Duration(
                      milliseconds:
                          (_seekValue * _duration.inMilliseconds).round())
                  : _position), style: textStyle),
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

  Widget _buildMemoCard(BuildContext context) {
    return Container(
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Row(
              children: [
                const Icon(
                  CupertinoIcons.pencil,
                  size: 18,
                  color: CupertinoColors.systemBlue,
                ),
                const SizedBox(width: 8),
                const Text(
                  'メモ',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.label,
                  ),
                ),
                const Spacer(),
                if (_memoController.text.isNotEmpty)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    onPressed: () => setState(() => _memoController.clear()),
                    child: const Text(
                      '消去',
                      style: TextStyle(
                        fontSize: 14,
                        color: CupertinoColors.destructiveRed,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: CupertinoTextField(
              controller: _memoController,
              placeholder: '気づいたことをメモしてください…',
              maxLines: 8,
              minLines: 5,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF9F9FB),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE5E5EA)),
              ),
              style: const TextStyle(
                fontSize: 15,
                color: CupertinoColors.label,
                height: 1.5,
              ),
              placeholderStyle: TextStyle(
                fontSize: 15,
                color: CupertinoColors.placeholderText.resolveFrom(context),
                height: 1.5,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
