import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca/screens/auth/caregiver_shared.dart';

void main() {
  testWidgets('caregiver bottom navigation exposes all five main sections', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: CaregiverBottomNavigation(
            selectedIndex: 0,
            onHome: () => selected.add('home'),
            onStatus: () => selected.add('status'),
            onMedicine: () => selected.add('medicine'),
            onProfile: () => selected.add('profile'),
            onStatistics: () => selected.add('statistics'),
          ),
        ),
      ),
    );

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('Medicine'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Statistics'), findsOneWidget);

    await tester.tap(find.byKey(const Key('caregiver-nav-status')));
    await tester.tap(find.byKey(const Key('caregiver-nav-medicine')));
    await tester.tap(find.byKey(const Key('caregiver-nav-profile')));
    await tester.tap(find.byKey(const Key('caregiver-nav-statistics')));
    expect(selected, <String>['status', 'medicine', 'profile', 'statistics']);
  });

  testWidgets('linked elderly selector changes the active account', (
    tester,
  ) async {
    String selectedId = 'elderly-1';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Padding(
              padding: const EdgeInsets.all(20),
              child: CaregiverElderlySelector(
                people: const [
                  (id: 'elderly-1', name: 'George Tan'),
                  (id: 'elderly-2', name: 'Mary Lim'),
                ],
                selectedId: selectedId,
                onChanged: (id) => setState(() => selectedId = id),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('caregiver-elderly-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mary Lim').last);
    await tester.pumpAndSettle();

    expect(selectedId, 'elderly-2');
    expect(find.text('Mary Lim'), findsOneWidget);
  });
}
