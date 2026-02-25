import 'package:flutter_test/flutter_test.dart';

import 'package:fridge_mobile_app/main.dart';

void main() {
  testWidgets('냉장고 앱 기본 화면이 렌더링된다', (WidgetTester tester) async {
    await tester.pumpWidget(const FridgeMasterApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.text('냉장고를 부탁해'), findsWidgets);

    final showsMainTabs = find.text('홈').evaluate().isNotEmpty;
    final showsHydrationState = find
        .text('데이터를 불러오는 중입니다...')
        .evaluate()
        .isNotEmpty;

    expect(showsMainTabs || showsHydrationState, isTrue);
  });
}
