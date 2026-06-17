# Phase 3 — Audio engine: build & test checklist

The audio engine was migrated to **`just_audio` + `just_audio_background`** with
**`shared_preferences`** position persistence. Flutter is **not installed in the
development environment**, so the code could not be compiled or run there — it must be
built and verified on your machine. This checklist maps each mandatory requirement to a
concrete test.

## A. Build

```bash
cd C:\Projects\StudyAudioApp
flutter pub get          # resolves just_audio, just_audio_background, shared_preferences
flutter analyze          # static check — fix/report anything it flags
flutter run              # on a connected Android device (not just an emulator, for lock-screen)
```

> **If `flutter pub get` reports a version conflict** (possible, since I pinned versions
> without a live pub resolver): run `flutter pub get` and paste me the error. Most likely
> fix is bumping `just_audio` to `^0.10.0` — I'll adjust the one deprecated API call
> (`ConcatenatingAudioSource`) if so.

To produce the installable APK:
```bash
flutter build apk --release
# output: build/app/outputs/flutter-apk/app-release.apk
```

## B. Functional tests (map to the mandatory requirements)

| # | Requirement | How to test | Pass criteria |
|---|-------------|-------------|---------------|
| 1 | **Background playback** | Start playback, press Home to background the app | Audio keeps playing |
| 2 | **Screen-lock playback** | While playing, lock the phone | Audio keeps playing |
| 7 | **Lock-screen controls** | On the lock screen / notification shade | Play, Pause, **Next** controls appear and work |
| 6 | **Playlist continuity** | Let a track finish (set mode = Full so a topic has 2+ items) | Auto-advances to the next track; lock-screen "Next" skips correctly |
| 3a | **Resume after app close** | Play ~30s, fully close the app, reopen | Returns to the same track at ~the same position |
| 3b | **Resume after kill** | Play ~30s, swipe the app away from recents, reopen | Same track + position restored (within ~5s) |
| 3c | **Resume after reboot** | Play ~30s, reboot the phone, open the app | Same track + position restored |
| 4 | **UI preserved** | Compare against the previous layout | Same structure: mode / scope / subject / topic / section selectors, status card, player, text card |
| 5 | **Existing audio intact** | Browse all 12 topics | All audio plays (folder rename preserved every file) |

Notes on the persistence model (req 3): position is saved every ~5 seconds during
playback, on every pause/track-change, and whenever the app leaves the foreground — so an
accidental kill loses at most ~5 seconds. `shared_preferences` is on-disk, so it survives
reboot. On launch the app restores scope, study mode, the exact track, and its position
(it does **not** auto-play — it cues, you press play).

## C. Known design notes

- **Content types are discovered at runtime** from the bundled assets. Today the 12 topics
  still carry the legacy `core/practical/trap/exam` files, so the section selector shows
  those — this is intentional, so the engine is testable *now* with real audio. After
  Phase 4 regeneration, the same code will show `Deep Lecture` / `Exam Review` with no
  change.
- **Study mode** filters which content types enter the playlist: `Lecture` (everything
  except the exam recap), `Exam` (only the recap), `Full` (everything).
- Web (GitHub Pages) still compiles: `JustAudioBackground.init` is skipped on web.

## D. Report back

Tell me: which rows pass/fail, and paste any `flutter analyze` / `pub get` / runtime
errors. I will not start Phase 4 (mass content generation) until the engine passes —
per your instruction.
