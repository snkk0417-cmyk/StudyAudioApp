package com.example.study_audio_app

import com.ryanheise.audioservice.AudioServiceActivity

// Must extend AudioServiceActivity (not FlutterActivity) so audio_service /
// just_audio_background can bind to the correct cached FlutterEngine for
// background playback and lock-screen controls.
class MainActivity : AudioServiceActivity()
