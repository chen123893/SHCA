import 'package:flutter_test/flutter_test.dart';
import 'package:shca/services/medication_image_service.dart';
import 'package:shca/services/medication_service.dart';

void main() {
  for (final entry in {
    'Sebelum makan': 'Before Meal',
    'SELEPAS MAKAN': 'After Meal',
    'sesudah makanan': 'After Meal',
    'lepas makan': 'After Meal',
    'bersama makanan': 'With Food',
    'bersama dengan makanan': 'With Food',
    'semasa makan': 'With Food',
  }.entries) {
    test('recognises Malay meal instruction: ${entry.key}', () {
      final result = medicationSuggestionsFromText(
        'METFORMIN\n500 mg\n${entry.key}',
      );
      expect(result.name, 'METFORMIN');
      expect(result.dose, '500 mg');
      expect(result.instruction, entry.value);
      expect(result.reviewNotes, isEmpty);
    });
  }

  test(
    'reads Malay quantities and frequency while preserving strength separately',
    () {
      final result = medicationSuggestionsFromText(
        'PARACETAMOL\n500 mg\nMakan 2 biji selepas makan\n3 kali sehari',
      );
      expect(result.name, 'PARACETAMOL');
      expect(result.dose, '500 mg');
      expect(result.quantity, 2);
      expect(result.instruction, 'After Meal; Three Times Daily');
    },
  );

  test('Malay whole-number words and capsule units are recognised', () {
    final result = medicationSuggestionsFromText(
      'AMOXICILLIN\n250 mg\nMakan dua kapsul sebelum makan\ndua kali sehari',
    );
    expect(result.quantity, 2);
    expect(result.visual, 'capsule');
    expect(result.instruction, 'Before Meal; Twice Daily');
    expect(medicationQuantityFromText('2 Biji'), 2);
    expect(medicationQuantityFromText('satu pil'), 1);
    expect(medicationQuantityFromText('tiga kapsul'), 3);
    expect(medicationStrengthFromText('2 biji'), isEmpty);
    expect(medicationStrengthFromText('500 mg'), '500 mg');
  });

  test(
    'Malay once-daily and every-day phrases retain their different wording',
    () {
      expect(
        medicationSuggestionsFromText('METFORMIN\nsekali sehari').instruction,
        'Once Daily',
      );
      expect(
        medicationSuggestionsFromText(
          'METFORMIN\nsatu kali sehari',
        ).instruction,
        'Once Daily',
      );
      expect(
        medicationSuggestionsFromText('METFORMIN\nsetiap hari').instruction,
        'Every Day',
      );
    },
  );

  test(
    'bilingual duplicates do not create duplicate or conflicting instructions',
    () {
      final result = medicationSuggestionsFromText(
        'METFORMIN\nSelepas makan / After food\n2 kali sehari / twice daily',
      );
      expect(result.instruction, 'After Food; Twice Daily');
      expect(result.reviewNotes, isEmpty);
    },
  );

  for (final phrase in [
    'Sebelum / Selepas Makan',
    'Sebelum atau selepas makan',
    'Sebelum makan / Selepas makan',
    'Before / After food',
    'Sebelum makan / After food',
  ]) {
    test('does not choose an unselected meal option: $phrase', () {
      final result = medicationSuggestionsFromText('METFORMIN\n$phrase');
      expect(result.instruction, isNull);
      expect(result.reviewNotes, contains(contains('meal-timing')));
    });
  }

  test(
    'explicit frequency survives an ambiguous meal template, with review required',
    () {
      final result = medicationSuggestionsFromText(
        'METFORMIN\nSebelum / Selepas Makan\n1 kali sehari',
      );
      expect(result.instruction, 'Once Daily');
      expect(result.reviewNotes, contains(contains('meal-timing')));
    },
  );

  test(
    'actual phone OCR from the supplied photo yields the handwritten description without inventing missing numbers',
    () {
      const raw = '''
Nama:
Makan / Minum
Tarikh: 29Mar2026 40:13 AM
KALI SEHARI
Sebelum / Selepas Makan
AN7I - CHoles7Ro4 RM
GONCANG SEBELUM MINUM / ) % HR
Controlled Medicine
''';
      final result = medicationSuggestionsFromText(raw);
      expect(result.name, 'ANTI-CHOLESTROL');
      expect(result.dose, isNull);
      expect(result.quantity, isNull);
      expect(result.instruction, isNull);
      expect(result.visual, 'tablet');
      expect(result.reviewNotes, contains(contains('handwritten')));
      expect(result.reviewNotes, contains(contains('meal-timing')));
    },
  );

  test(
    'a generic Makan/Minum or shake footer does not imply a liquid or meal instruction',
    () {
      final result = medicationSuggestionsFromText(
        'Nama:\nMakan / Minum\nGONCANG SEBELUM MINUM\nControlled Medicine',
      );
      expect(result.name, isNull);
      expect(result.quantity, isNull);
      expect(result.instruction, isNull);
      expect(result.visual, 'tablet');
    },
  );

  test(
    'Malay syrup and explicit shake instructions can be copied together',
    () {
      final result = medicationSuggestionsFromText(
        'BATUK SIRAP\n5 ml\nSelepas makan\nGoncang baik sebelum minum',
      );
      expect(result.visual, 'liquid');
      expect(result.dose, '5 ml');
      expect(result.instruction, 'After Meal; Shake Before Use');
    },
  );

  test(
    'fractions, negatives, ranges and oversized quantities are not turned into whole doses',
    () {
      for (final dose in [
        '1/2 biji',
        '1-2 tablet',
        '1 atau 2 biji',
        'satu atau dua biji',
        '-1 tablet',
        '0.5 tablet',
        '100 biji',
      ]) {
        final result = medicationSuggestionsFromText('PARACETAMOL\n$dose');
        expect(result.quantity, isNull, reason: dose);
        expect(result.reviewNotes, isNotEmpty, reason: dose);
      }
      expect(medicationQuantityFromText('1/2 biji'), isNull);
    },
  );

  test(
    'conflicting dose quantities require review without losing the printed strength',
    () {
      final result = medicationSuggestionsFromText(
        'PARACETAMOL\n500 mg\n1 biji\n2 biji',
      );
      expect(result.quantity, isNull);
      expect(result.dose, '500 mg');
      expect(result.reviewNotes, contains(contains('Several dose')));
    },
  );

  test('frequency ranges and alternatives are not silently selected', () {
    for (final frequency in [
      '1 / 2 kali sehari',
      '1-2 kali sehari',
      '1 atau 2 kali sehari',
      '-2 kali sehari',
      'once / twice daily',
      'satu atau dua kali sehari',
      '1 kali sehari\n2 kali sehari',
    ]) {
      final result = medicationSuggestionsFromText('METFORMIN\n$frequency');
      expect(result.instruction, isNull, reason: frequency);
      expect(result.reviewNotes, isNotEmpty, reason: frequency);
    }
  });

  test('negated instructions cannot become affirmative meal instructions', () {
    for (final phrase in [
      'Jangan ambil sebelum makan',
      'Do not take before meals',
      'Jangan ambil 2 kali sehari',
      'Do not take twice daily',
    ]) {
      final result = medicationSuggestionsFromText('METFORMIN\n$phrase');
      expect(result.instruction, isNull);
      expect(result.reviewNotes, contains(contains('negated')));
    }
  });

  test('mixed case, extra spaces and line breaks are accepted', () {
    expect(
      medicationSuggestionsFromText(
        'METFORMIN\nSeLePaS   makan\n2 kali   sehari',
      ).instruction,
      'After Meal; Twice Daily',
    );
    expect(
      medicationSuggestionsFromText('METFORMIN\nSEBELUM\nMAKAN').instruction,
      'Before Meal',
    );
  });
}
