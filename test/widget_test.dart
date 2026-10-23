import 'package:flutter_test/flutter_test.dart';
import 'package:phone_web_mirror/main.dart';

void main() {
  testWidgets('shows brand', (tester) async {
    await tester.pumpWidget(const PhoneWebMirrorApp());
    expect(find.text('Phone Web Mirror'), findsOneWidget);
  });
}
