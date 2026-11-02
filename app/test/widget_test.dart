// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:activefriends/core/app.dart';

void main() {
  testWidgets('Shows the unconfigured backend state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ActiveFriendsApp());

    // With no Supabase config (the default under `flutter test`), the app shows
    // the unconfigured BootstrapScreen: the wordmark and the tagline.
    expect(find.text('OUTPACE'), findsOneWidget);
    expect(
      find.text('Our club. Our activity. Our pace.'),
      findsOneWidget,
    );
  });
}
