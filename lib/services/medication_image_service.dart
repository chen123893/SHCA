import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shca/services/medication_service.dart'
    show medicationQuantityFromText;

const String medicationImageUserAgent = 'SHCA-Mobile/1.0';

class MedicationImageException implements Exception {
  const MedicationImageException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MedicationImageRequest {
  const MedicationImageRequest({required this.uri, required this.headers});

  final Uri uri;
  final Map<String, String> headers;
}

/// Sends medicine-package photos only to the private SHCA Cloudflare Worker.
/// The Worker validates the Firebase ID token before reading or writing R2.
class MedicationImageStorageService {
  const MedicationImageStorageService({
    this.baseUrl = const String.fromEnvironment(
      'MEDICATION_IMAGE_API_URL',
      defaultValue:
          'https://shca-medication-images.shca-medication-images.workers.dev',
    ),
  });

  final String baseUrl;

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  Future<String> upload({
    required XFile image,
    required String elderlyId,
    required String medicationId,
  }) async {
    final token = await _idToken();
    final bytes = await image.readAsBytes();
    final contentType = medicationImageContentType(
      declaredType: image.mimeType,
      filename: image.name,
      bytes: bytes,
    );
    final request = http.MultipartRequest('POST', _endpoint())
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['User-Agent'] = medicationImageUserAgent
      ..headers['Accept'] = 'application/json'
      ..fields['elderlyId'] = elderlyId
      ..fields['medicationId'] = medicationId
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: image.name,
          contentType: MediaType.parse(contentType),
        ),
      );
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MedicationImageException(
        _errorMessage(response.body, response.statusCode),
      );
    }
    final decoded = jsonDecode(response.body);
    final imageKey = decoded is Map<String, dynamic>
        ? decoded['imageKey'] as String?
        : null;
    if (imageKey == null || imageKey.trim().isEmpty) {
      throw const MedicationImageException(
        'The image service did not return a private image reference.',
      );
    }
    return imageKey;
  }

  Future<MedicationImageRequest> authorisedDownload({
    required String imageKey,
    required String elderlyId,
  }) async {
    final token = await _idToken();
    final uri = _endpoint().replace(
      queryParameters: <String, String>{
        'imageKey': imageKey,
        'elderlyId': elderlyId,
      },
    );
    return MedicationImageRequest(
      uri: uri,
      headers: <String, String>{
        'Authorization': 'Bearer $token',
        'User-Agent': medicationImageUserAgent,
      },
    );
  }

  Future<void> delete({
    required String imageKey,
    required String elderlyId,
  }) async {
    if (imageKey.trim().isEmpty) return;
    final token = await _idToken();
    final response = await http.delete(
      _endpoint().replace(
        queryParameters: <String, String>{
          'imageKey': imageKey,
          'elderlyId': elderlyId,
        },
      ),
      headers: <String, String>{
        'Authorization': 'Bearer $token',
        'User-Agent': medicationImageUserAgent,
        'Accept': 'application/json',
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MedicationImageException(
        _errorMessage(response.body, response.statusCode),
      );
    }
  }

  Uri _endpoint() {
    if (!isConfigured) {
      throw const MedicationImageException(
        'Private medicine image storage is not configured.',
      );
    }
    final trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$trimmed/v1/medication-images');
  }

  Future<String> _idToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const MedicationImageException(
        'Please sign in again before accessing a medicine photo.',
      );
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw const MedicationImageException(
        'A secure sign-in token could not be created.',
      );
    }
    return token;
  }

  String _errorMessage(String body, int statusCode) {
    try {
      final decoded = jsonDecode(body);
      final message = decoded is Map<String, dynamic>
          ? decoded['error'] as String?
          : null;
      if (message != null && message.trim().isNotEmpty) return message;
    } catch (_) {
      // Use the safe generic response below.
    }
    return 'Medicine photo request failed ($statusCode). Please try again.';
  }
}

@visibleForTesting
String medicationImageContentType({
  String? declaredType,
  required String filename,
  Uint8List? bytes,
}) {
  final normalized = declaredType?.trim().toLowerCase();
  if (normalized == 'image/jpeg' ||
      normalized == 'image/png' ||
      normalized == 'image/webp') {
    return normalized!;
  }
  if (bytes != null) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
      return 'image/webp';
    }
  }
  final extension = filename.toLowerCase().split('.').last;
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    _ => throw const MedicationImageException(
      'Use a JPEG, PNG, or WebP medicine photo.',
    ),
  };
}

class MedicationTextRecognitionService {
  const MedicationTextRecognitionService();

  Future<String> recognise(XFile image) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(
        InputImage.fromFilePath(image.path),
      );
      return result.text.trim();
    } finally {
      await recognizer.close();
    }
  }
}

class MedicationScanSuggestions {
  const MedicationScanSuggestions({
    this.name,
    this.dose,
    this.instruction,
    this.category,
    this.quantity,
    this.reviewNotes = const [],
    this.visual = 'tablet',
  });

  final String? name;
  final String? dose;
  final String? instruction;
  final String? category;
  final int? quantity;
  final List<String> reviewNotes;
  final String visual;
}

/// Conservatively proposes editable fields from OCR text. It never saves or
/// interprets the raw scan as a medical instruction.
MedicationScanSuggestions medicationSuggestionsFromText(String rawText) {
  final lines = rawText
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  final searchable = lines.join(' ').toLowerCase();
  final reviewNotes = <String>{};
  final correctedNames = <String>{};
  final dosePattern = RegExp(
    r'\b(\d+(?:[.,]\d+)?|satu|dua|tiga|empat|lima|enam|tujuh|lapan|sembilan|sepuluh)\s*(mg|mcg|µg|g|ml|iu|tablet(?:s)?|capsule(?:s)?|pill(?:s)?|biji|pil|kapsul)\b',
    caseSensitive: false,
  );
  String? strength, quantityText;
  final quantities = <int>{};
  for (final line in lines) {
    for (final match in dosePattern.allMatches(line)) {
      // Never turn the denominator/end of a dose range into a whole dose.
      final prefix = line.substring(0, match.start);
      if (_ambiguousLabelAmountPrefix(prefix)) {
        reviewNotes.add(
          'The dose contains a fraction or range. Confirm it manually.',
        );
        continue;
      }
      final text = match.group(0)!.replaceAll(',', '.');
      final unit = match.group(2)!.toLowerCase();
      if (const {'mg', 'mcg', 'µg', 'g', 'ml', 'iu'}.contains(unit)) {
        strength ??= text;
      } else {
        final value = medicationQuantityFromText(text);
        if (value == null || value < 1 || value > 99) {
          reviewNotes.add('The dose quantity needs manual confirmation.');
        } else {
          quantities.add(value);
          quantityText ??= text;
        }
      }
    }
  }
  if (quantities.length > 1) {
    reviewNotes.add(
      'Several dose quantities were found. Confirm the quantity manually.',
    );
  }
  final quantity = quantities.length == 1 ? quantities.single : null;
  final dose = strength ?? (quantities.length == 1 ? quantityText : null);

  final administrativeText = RegExp(
    r'\b(?:clinic|klinik|hospital|pharmacy|farmasi|patient|pesakit|prescription|doctor|doktor|dosage|expiry|batch|address|alamat|telephone|telefon|phone|date|tarikh|nama|jalan|taman|floor|penang|commercial|square|sdn|bhd|indication|indikasi)\b',
    caseSensitive: false,
  );
  final instructionText = RegExp(
    r'\b(?:take|before|after|food|meal|once|twice|times|daily|morning|night|makan|makanan|minum|sebelum|selepas|sesudah|lepas|bersama|semasa|kali|sehari|setiap|goncang|pagi|malam|biji|pil|kapsul)\b',
    caseSensitive: false,
  );
  final genericLabelText = RegExp(
    r'^(?:controlled\s+medicine|medicine|medication|ubat|name|nama|directions?|instructions?)$',
    caseSensitive: false,
  );
  final warningText = RegExp(
    r'\b(?:ubat\s+terkawal|controlled\s+(?:medicine|drug)|prescription\s+only|keep\s+out\s+of\s+reach)\b',
    caseSensitive: false,
  );
  final medicineNameLabel = RegExp(
    r'^\s*(?:(?:nama|name)\s+(?:ubat|medicine|medication|drug)|(?:ubat|medicine|medication|drug)\s+(?:nama|name))\s*[:\-]?\s*(.*)$',
    caseSensitive: false,
  );
  final likelyMedicineText = RegExp(
    r'\b(?:anti[\s-]*cholest(?:e)?rol|vitamin|paracetamol|metformin|amoxicillin|[a-z]+(?:formin|statin|sartan|pril|olol|cillin|cycline|mycin|azole|vir|gliptin|semide|dipine|coxib))\b',
    caseSensitive: false,
  );

  String cleanName(String value) {
    var cleaned = value
        .replaceFirst(
          RegExp(
            r'^\s*(?:(?:medicine|medication|product|drug|ubat)(?:\s+(?:name|nama))?|(?:name|nama)\s+(?:medicine|medication|product|drug|ubat))\s*[:\-]?\s*',
            caseSensitive: false,
          ),
          '',
        )
        .replaceFirst(
          RegExp(
            r'\s+(?:indication|indikasi)\s*[:\-].*$',
            caseSensitive: false,
          ),
          '',
        )
        // Malaysian clinic labels often have a separate price box marked RM
        // immediately after the handwritten medicine description.
        .replaceFirst(
          RegExp(r'\s+RM(?:\s*\d+(?:[.]\d{1,2})?)?\s*$', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'^[\s:;,_|]+|[\s:;,_|]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'\s*-\s*'), '-')
        .trim();

    // Correct only this complete handwritten description, never drug names,
    // strengths or quantities in general. It is a label description, not an
    // identification of a particular cholesterol medicine.
    final candidate = cleaned
        .toUpperCase()
        .replaceAll(r'$', 'S')
        .replaceAll(RegExp(r'[\s-]'), '');
    final handwritten = RegExp(
      r'^AN[T7][I1L]CHOLE[S5][T7](E?)R[O0][L14]?$',
    ).firstMatch(candidate);
    if (handwritten != null) {
      final corrected = handwritten.group(1) == 'E'
          ? 'ANTI-CHOLESTEROL'
          : 'ANTI-CHOLESTROL';
      if (RegExp(r'[01745$]').hasMatch(candidate)) {
        correctedNames.add(corrected);
      }
      cleaned = corrected;
    }
    return cleaned;
  }

  int? nameScore(String original) {
    final line = cleanName(original);
    if (line.length < 3 || line.length > 60) return null;
    if (administrativeText.hasMatch(line) ||
        instructionText.hasMatch(line) ||
        genericLabelText.hasMatch(line) ||
        warningText.hasMatch(line) ||
        dosePattern.hasMatch(line) ||
        !RegExp(r'[A-Za-z]').hasMatch(line)) {
      return null;
    }
    final letters = RegExp(r'[A-Za-z]').allMatches(line).length;
    final upper = RegExp(r'[A-Z]').allMatches(line).length;
    final digits = RegExp(r'\d').allMatches(line).length;
    if (letters < 3 || digits > letters) return null;
    var score = 0;
    if (likelyMedicineText.hasMatch(line)) score += 12;
    if (upper / letters >= .75) score += 4;
    if (line.split(' ').length <= 4) score += 2;
    if (digits == 0) score += 1;
    return score;
  }

  String? name;
  var bestNameScore = -1;
  // Pharmacy labels commonly identify the correct field as "Nama Ubat".
  // Prefer its inline value or a nearby following OCR line before applying
  // the generic visual-text heuristic. Plain "Nama" is deliberately excluded
  // because that row normally contains the patient's name.
  for (var index = 0; index < lines.length && name == null; index++) {
    final labelMatch = medicineNameLabel.firstMatch(lines[index]);
    if (labelMatch == null) continue;
    final nearby = <String>[
      if (labelMatch.group(1)?.trim().isNotEmpty == true)
        labelMatch.group(1)!.trim(),
      for (
        var next = index + 1;
        next < lines.length && next <= index + 5;
        next++
      )
        lines[next],
    ];
    for (final candidate in nearby) {
      final score = nameScore(candidate);
      if (score == null) continue;
      name = cleanName(candidate);
      bestNameScore = score + 100;
      break;
    }
  }
  for (final line in lines) {
    final score = nameScore(line);
    if (score == null || score <= bestNameScore) continue;
    bestNameScore = score;
    name = cleanName(line);
  }
  // A weak mixed-case line could be a patient's name or clinic slogan.
  // Returning no suggestion is safer than silently saving the wrong drug.
  if (bestNameScore < 3) name = null;

  final visual =
      RegExp(
            r'\b(?:syrup|sirap|suspension|suspensi|solution|larutan)\b',
          ).hasMatch(searchable) ||
          searchable.contains(' ml')
      ? 'liquid'
      : RegExp(r'\b(?:capsules?|kapsul)\b').hasMatch(searchable)
      ? 'capsule'
      : searchable.contains('vitamin') ||
            searchable.contains('supplement') ||
            searchable.contains('suplemen')
      ? 'vitamin'
      : 'tablet';
  final instruction = _medicationLabelInstructions(
    lines.join('\n'),
    visual == 'liquid',
    reviewNotes,
  );
  if (name != null && correctedNames.contains(name)) {
    reviewNotes.add(
      'Check the handwritten medicine description against the label.',
    );
  }

  final category = visual == 'vitamin'
      ? 'Supplement'
      : visual == 'liquid'
      ? 'Liquid medicine'
      : null;

  return MedicationScanSuggestions(
    name: name,
    dose: dose,
    instruction: instruction,
    category: category,
    quantity: quantity,
    reviewNotes: List.unmodifiable(reviewNotes),
    visual: visual,
  );
}

String? _medicationLabelInstructions(
  String text,
  bool liquid,
  Set<String> notes,
) {
  final lower = text.toLowerCase();
  final meals = <String, String>{};
  String title(String value) => value
      .split(RegExp(r'\s+'))
      .map(
        (word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1)}',
      )
      .join(' ');
  bool negated(int start) {
    final prefix = lower.substring(0, start).split('\n').last;
    if (!RegExp(r'\b(?:jangan|tidak|not|without)\b').hasMatch(prefix)) {
      return false;
    }
    notes.add('A negated instruction was found. Confirm it manually.');
    return true;
  }

  void meal(
    String kind,
    String pattern,
    String canonical, {
    bool english = false,
  }) {
    for (final match in RegExp(
      pattern,
      caseSensitive: false,
    ).allMatches(lower)) {
      if (negated(match.start)) continue;
      meals.putIfAbsent(
        kind,
        () => english ? title(match.group(0)!) : canonical,
      );
    }
  }

  meal(
    'before',
    r'\bbefore\s+(?:meals?|food|eating)\b',
    'Before Meal',
    english: true,
  );
  meal(
    'after',
    r'\bafter\s+(?:meals?|food|eating)\b',
    'After Meal',
    english: true,
  );
  meal(
    'with',
    r'\b(?:with\s+(?:food|meals?)|during\s+meals?)\b',
    'With Food',
    english: true,
  );
  meal('before', r'\bsebelum\s+(?:makan|makanan)\b', 'Before Meal');
  meal(
    'after',
    r'\b(?:selepas|sesudah|lepas)\s+(?:makan|makanan)\b',
    'After Meal',
  );
  meal(
    'with',
    r'\b(?:bersama(?:\s+dengan)?|semasa|ketika)\s+(?:makan|makanan)\b',
    'With Food',
  );
  final alternatives = RegExp(
    r'\b(?:sebelum\s*(?:/|atau)\s*(?:selepas|sesudah|lepas)|(?:selepas|sesudah|lepas)\s*(?:/|atau)\s*sebelum)\s+(?:makan|makanan)\b|\b(?:before\s*(?:/|or)\s*after|after\s*(?:/|or)\s*before)\s+(?:meals?|food|eating)\b',
  ).hasMatch(lower);
  final parts = <String>[];
  if (alternatives || meals.length > 1) {
    notes.add(
      'Both meal-timing options were found. Choose before or after meals manually.',
    );
  } else if (meals.isNotEmpty) {
    parts.add(meals.values.single);
  }

  const numbers = {
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
    'satu': 1,
    'dua': 2,
    'tiga': 3,
    'empat': 4,
  };
  final frequencies = <int>{};
  for (final match in RegExp(
    r'\b(?:once\s+daily|sekali\s+sehari)\b',
  ).allMatches(lower)) {
    if (!negated(match.start)) frequencies.add(1);
  }
  for (final match in RegExp(r'\btwice\s+daily\b').allMatches(lower)) {
    if (!negated(match.start)) frequencies.add(2);
  }
  for (final match in RegExp(
    r'\b(\d+|one|two|three|four|satu|dua|tiga|empat)\s*(?:kali|times?)\s*(?:sehari|daily|(?:a|per)\s+day)\b',
  ).allMatches(lower)) {
    if (negated(match.start)) continue;
    final prefix = lower.substring(0, match.start);
    if (_ambiguousLabelAmountPrefix(prefix)) {
      notes.add('A frequency range was found. Confirm it manually.');
      continue;
    }
    final number = int.tryParse(match.group(1)!) ?? numbers[match.group(1)!];
    if (number != null && number > 0 && number <= 24) frequencies.add(number);
  }
  // Preprinted alternatives such as "1 / 2 kali sehari" are not prescriptions.
  if (RegExp(
        r'\b(?:once|twice|\d+|satu|dua|tiga|empat|sekali)\s*(?:/|or|atau|[-–—])\s*(?:once|twice|\d+|satu|dua|tiga|empat|sekali)\s*(?:kali|times?)?\s*(?:daily|sehari|a\s+day)\b',
      ).hasMatch(lower) ||
      frequencies.length > 1) {
    notes.add(
      'Several daily-frequency options were found. Confirm them manually.',
    );
  } else if (frequencies.isNotEmpty) {
    final value = frequencies.single;
    parts.add(switch (value) {
      1 => 'Once Daily',
      2 => 'Twice Daily',
      3 => 'Three Times Daily',
      _ => '$value Times Daily',
    });
  } else if (RegExp(r'\b(?:every\s+day|setiap\s+hari)\b').hasMatch(lower)) {
    parts.add('Every Day');
  }
  if (RegExp(
    r'\b(?:at\s+night|pada\s+waktu\s+malam|waktu\s+malam)\b',
  ).hasMatch(lower)) {
    parts.add('At Night');
  }
  if (RegExp(
    r'\b(?:in\s+the\s+morning|pada\s+waktu\s+pagi|waktu\s+pagi)\b',
  ).hasMatch(lower)) {
    parts.add('In The Morning');
  }
  if (liquid &&
      RegExp(
        r'\bgoncang\s+(?:(?:dengan\s+)?baik\s+)?sebelum\s+(?:minum|guna|digunakan)\b',
      ).hasMatch(lower)) {
    parts.add('Shake Before Use');
  }
  return parts.isEmpty ? null : parts.toSet().join('; ');
}

bool _ambiguousLabelAmountPrefix(String prefix) =>
    RegExp(
      r'(?:\d+(?:[.,]\d+)?|satu|dua|tiga|empat|lima|enam|tujuh|lapan|sembilan|sepuluh)\s*(?:/|[-–—]|to|hingga|atau|or)\s*$',
      caseSensitive: false,
    ).hasMatch(prefix) ||
    RegExp(r'[-–—/]\s*$').hasMatch(prefix);
