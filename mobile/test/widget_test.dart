import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/main.dart';

void main() {
  testWidgets('home shows brand and tagline', (tester) async {
    await tester.pumpWidget(const SixthSenseApp());
    expect(find.text('SixthSense'), findsOneWidget);
    expect(find.text('See the risk. Stop it early.'), findsOneWidget);
  });
}
