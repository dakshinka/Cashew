import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Smoke test rendering basic widget tree', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text('Cashew Test Smoke'),
          ),
        ),
      ),
    );

    expect(find.text('Cashew Test Smoke'), findsOneWidget);
  });
}
