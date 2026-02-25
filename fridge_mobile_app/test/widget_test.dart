import 'package:flutter_test/flutter_test.dart';

import 'package:fridge_mobile_app/main.dart';

void main() {
  testWidgets('냉장고 앱 기본 화면이 렌더링된다', (WidgetTester tester) async {
    await tester.pumpWidget(const FridgeMasterApp());
    await tester.pumpAndSettle();

    expect(find.text('냉장고를 부탁해'), findsWidgets);
    expect(find.text('홈'), findsOneWidget);
    expect(find.text('냉장고'), findsOneWidget);
    expect(find.text('추천'), findsOneWidget);
    expect(find.text('장보기'), findsOneWidget);
    expect(find.text('설정'), findsOneWidget);
  });
}
