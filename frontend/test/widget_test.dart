// Basic smoke test — 앱 빌드가 올바르게 시작되는지만 확인합니다.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:receiptocr/main.dart';
import 'package:receiptocr/services/rest_api_service.dart';

void main() {
  testWidgets('앱 시작 smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      MyApp(apiService: RestApiService()),
    );
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
