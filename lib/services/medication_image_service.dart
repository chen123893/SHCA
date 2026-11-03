import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';

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
    this.visual = 'tablet',
  });

  final String? name;
  final String? dose;
  final String? instruction;
  final String? category;
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
  final dosePattern = RegExp(
    r'\b\d+(?:\.\d+)?\s*(?:mg|mcg|µg|g|ml|tablet(?:s)?|capsule(?:s)?|pill(?:s)?|biji)\b',
    caseSensitive: false,
  );

  String? dose;
  for (final line in lines) {
    final match = dosePattern.firstMatch(line);
    if (match != null) {
      dose = match.group(0);
      break;
    }
  }

  final administrativeText = RegExp(
    r'\b(?:clinic|klinik|hospital|pharmacy|farmasi|patient|pesakit|prescription|doctor|doktor|dosage|expiry|batch|address|alamat|telephone|telefon|phone|date|tarikh|nama|jalan|taman|floor|penang|commercial|square|sdn|bhd|indication|indikasi)\b',
    caseSensitive: false,
  );
  final instructionText = RegExp(
    r'\b(?:take|before|after|food|meal|once|twice|times|daily|morning|night|makan|minum|sebelum|selepas|kali|sehari|setiap|goncang)\b',
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

    // Handwritten cholesterol labels are commonly read with "$" for S and
    // "7" for T. Correct only this recognisable medicine fragment so numbers
    // elsewhere on the package remain untouched.
    final cholesterolCandidate = cleaned.replaceAll(r'$', 'S');
    if (RegExp(
      r'^ANTI-?CHOLE',
      caseSensitive: false,
    ).hasMatch(cholesterolCandidate)) {
      cleaned = cholesterolCandidate.replaceAllMapped(
        RegExp(r'([A-Za-z])7([A-Za-z])'),
        (match) => '${match.group(1)}T${match.group(2)}',
      );
      cleaned = cleaned.replaceFirst(
        RegExp(r'^ANTI-CHOLESTRO$', caseSensitive: false),
        'ANTI-CHOLESTROL',
      );
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

  const instructionPhrases = <String>[
    'before meal',
    'after meal',
    'with food',
    'before food',
    'after food',
    'once daily',
    'twice daily',
    'three times daily',
    'every day',
    'at night',
    'in the morning',
  ];
  String? instruction;
  for (final phrase in instructionPhrases) {
    if (!searchable.contains(phrase)) continue;
    instruction = phrase
        .split(' ')
        .map(
          (word) => word.isEmpty
              ? word
              : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
    break;
  }

  final visual =
      searchable.contains('syrup') ||
          searchable.contains('suspension') ||
          searchable.contains('solution') ||
          searchable.contains(' ml')
      ? 'liquid'
      : searchable.contains('capsule')
      ? 'capsule'
      : searchable.contains('vitamin') || searchable.contains('supplement')
      ? 'vitamin'
      : 'tablet';
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
    visual: visual,
  );
}
