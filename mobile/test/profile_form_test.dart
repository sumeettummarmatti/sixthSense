import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';
import 'package:sixthsense_app/core/theme/app_theme.dart';
import 'package:sixthsense_app/features/profile/profile_form.dart';
import 'package:sixthsense_app/features/profile/profile_screen.dart';

class _FakeProfileApi extends DemoApi {
  _FakeProfileApi(this.stored);

  Profile? stored;
  final saved = <Profile>[];

  @override
  Future<Profile?> profile() async => stored;

  @override
  Future<Profile> saveProfile(Profile profile) async {
    saved.add(profile);
    return stored = profile;
  }
}

/// A tall phone screen so long forms and sheets fit without scrolling.
void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('profile form needs a first name and saves every field', (
    tester,
  ) async {
    _tallScreen(tester);
    final saved = <Profile>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: ProfileForm(onSave: (p) async => saved.add(p))),
      ),
    );

    await tester.ensureVisible(find.byKey(const ValueKey('profile-save')));
    await tester.tap(find.byKey(const ValueKey('profile-save')));
    await tester.pump();
    expect(find.text('Add your first name.'), findsOneWidget);
    expect(saved, isEmpty);

    await tester.ensureVisible(
      find.byKey(const ValueKey('profile-first-name')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('profile-first-name')),
      '  Priya ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('profile-bio')),
      'I walk home from the library',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('strength-knows_the_area')),
    );
    await tester.tap(find.byKey(const ValueKey('strength-knows_the_area')));
    await tester.ensureVisible(
      find.byKey(const ValueKey('strength-speaks_kannada')),
    );
    await tester.tap(find.byKey(const ValueKey('strength-speaks_kannada')));
    await tester.ensureVisible(find.byKey(const ValueKey('language-Kannada')));
    await tester.tap(find.byKey(const ValueKey('language-Kannada')));
    await tester.ensureVisible(find.byKey(const ValueKey('profile-willing')));
    await tester.ensureVisible(find.byKey(const ValueKey('profile-gender')));
    await tester.tap(find.byKey(const ValueKey('profile-gender')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Woman').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('profile-willing')));
    await tester.tap(find.byKey(const ValueKey('profile-willing')));
    await tester.ensureVisible(find.byKey(const ValueKey('profile-save')));
    await tester.ensureVisible(find.byKey(const ValueKey('profile-save')));
    await tester.tap(find.byKey(const ValueKey('profile-save')));
    await tester.pumpAndSettle();

    final profile = saved.single;
    expect(profile.firstName, 'Priya');
    expect(profile.bio, 'I walk home from the library');
    expect(profile.strengths, ['knows_the_area', 'speaks_kannada']);
    expect(profile.languages, ['Kannada']);
    expect(profile.gender, 'woman');
    expect(profile.willingCompanion, isTrue);
  });

  testWidgets('bio is limited to 200 characters', (tester) async {
    _tallScreen(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: ProfileForm(onSave: (_) async {})),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('profile-bio')),
      'x' * 260,
    );
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('profile-bio')),
    );
    expect(field.controller!.text.length, 200);
  });

  testWidgets('Profile tab loads and edits the saved profile', (tester) async {
    _tallScreen(tester);
    final api = _FakeProfileApi(
      const Profile(
        firstName: 'Priya',
        strengths: ['first_aid_trained'],
        gender: null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ProfileScreen(api: api),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Priya'), findsOneWidget);
    final chip = tester.widget<FilterChip>(
      find.byKey(const ValueKey('strength-first_aid_trained')),
    );
    expect(chip.selected, isTrue);
    expect(find.text('Prefer not to say'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('profile-first-name')),
      'Priya S',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('profile-save')));
    await tester.ensureVisible(find.byKey(const ValueKey('profile-save')));
    await tester.tap(find.byKey(const ValueKey('profile-save')));
    await tester.pumpAndSettle();
    expect(api.saved.single.firstName, 'Priya S');
    expect(api.saved.single.strengths, ['first_aid_trained']);
    expect(find.text('Profile saved'), findsOneWidget);
  });
}
