import 'package:flutter_test/flutter_test.dart';

import 'package:study_audio_app/main.dart';

void main() {
  testWidgets('StudyAudioApp renders home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const StudyAudioApp());

    expect(find.text('Study Audio'), findsOneWidget);
    expect(find.text('Architecture'), findsOneWidget);
  });
}
