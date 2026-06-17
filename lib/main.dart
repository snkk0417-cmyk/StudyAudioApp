import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:just_audio_background/just_audio_background.dart';

import 'home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Background audio + lock-screen/notification controls (Android).
  // Guarded for web so the GitHub Pages build keeps compiling; background
  // playback is an Android feature and a no-op on the web target.
  if (!kIsWeb) {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.example.study_audio_app.audio',
      androidNotificationChannelName: 'Study Audio playback',
      androidNotificationOngoing: true,
    );
  }

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
