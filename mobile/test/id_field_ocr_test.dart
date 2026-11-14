import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/features/verification/id_field_ocr.dart';

void main() {
  test('extracts only the selected ID number and labelled date of birth', () {
    final fields = IdFieldSuggestions.fromRecognizedText(
      'Name: Tanisha Jayabalan\n'
      'Passport No: A1234567\n'
      'Date of Birth: 25/12/2000\n'
      'Date of Issue: 01/01/2022\n'
      'Address: Bengaluru',
      idType: 'passport',
    );

    expect(fields.idNumber, 'A1234567');
    expect(fields.dateOfBirth, '2000-12-25');
    expect(fields.isEmpty, isFalse);
  });

  test(
    'keeps ID type selection separate when its matching pattern is absent',
    () {
      final fields = IdFieldSuggestions.fromRecognizedText(
        'Passport No: A1234567\nDate of Birth: 25/12/2000',
        idType: 'voter_id',
      );

      expect(fields.idNumber, isNull);
      expect(fields.dateOfBirth, '2000-12-25');
    },
  );

  test('ignores unlabeled dates and invalid calendar dates', () {
    final unlabeled = IdFieldSuggestions.fromRecognizedText(
      'Passport No: A1234567\nDate of Issue: 25/12/2000',
      idType: 'passport',
    );
    final invalid = IdFieldSuggestions.fromRecognizedText(
      'DOB: 31/02/2000',
      idType: 'passport',
    );

    expect(unlabeled.dateOfBirth, isNull);
    expect(invalid.dateOfBirth, isNull);
  });
}
