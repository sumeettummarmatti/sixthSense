import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../core/api/device_identity.dart';

typedef IdPhotoTextReader = Future<String> Function(String imagePath);

/// Runs OCR locally and returns only the two fields used by this flow.
class OnDeviceIdOcr {
  OnDeviceIdOcr({this._readText});

  final IdPhotoTextReader? _readText;

  Future<IdFieldSuggestions> readFields(
    VerificationImage image, {
    required String idType,
  }) async => IdFieldSuggestions.fromRecognizedText(
    await _recognize(image),
    idType: idType,
  );

  Future<String> _recognize(VerificationImage image) async {
    final injectedReader = _readText;
    if (injectedReader != null) return injectedReader('');
    final directory = await Directory.systemTemp.createTemp(
      'sixthsense_id_ocr_',
    );
    final extension = switch (image.mimeType) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
    final file = File('${directory.path}/id-photo.$extension');
    try {
      await file.writeAsBytes(image.bytes, flush: true);
      return await _readWithMlKit(file.path);
    } finally {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // The recognition result is still usable if best-effort cleanup fails.
      }
    }
  }

  static Future<String> _readWithMlKit(String path) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(path),
      );
      return recognized.text;
    } finally {
      await recognizer.close();
    }
  }
}

/// Only the ID number and date of birth survive parsing; raw OCR text is discarded.
class IdFieldSuggestions {
  const IdFieldSuggestions({this.idNumber, this.dateOfBirth});

  final String? idNumber;
  final String? dateOfBirth;

  bool get isEmpty => idNumber == null && dateOfBirth == null;

  factory IdFieldSuggestions.fromRecognizedText(
    String recognizedText, {
    required String idType,
  }) => IdFieldSuggestions(
    idNumber: _extractIdNumber(recognizedText, idType),
    dateOfBirth: _extractDateOfBirth(recognizedText),
  );
}

String? _extractIdNumber(String text, String idType) {
  final pattern = switch (idType) {
    'passport' => RegExp(r'\b[A-Z]\s*\d{7}\b', caseSensitive: false),
    'voter_id' => RegExp(r'\b[A-Z]{3}[\s-]?\d{7}\b', caseSensitive: false),
    _ => RegExp(
      r'\b[A-Z]{2}[\s/-]?\d{1,3}[\s/-]?\d{4}[\s/-]?\d{4,7}\b',
      caseSensitive: false,
    ),
  };
  final match = pattern.firstMatch(text);
  return match?.group(0)?.replaceAll(RegExp(r'\s+'), '').toUpperCase();
}

String? _extractDateOfBirth(String text) {
  final lines = text.split(RegExp(r'[\r\n]+'));
  final birthLabel = RegExp(
    r'\b(?:DATE\s+OF\s+BIRTH|BIRTH\s+DATE|D\.?O\.?B\.?)\b',
    caseSensitive: false,
  );
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    final label = birthLabel.firstMatch(line);
    if (label == null) continue;
    final sameLineDate = _dateIn(line.substring(label.end));
    if (sameLineDate != null) return sameLineDate;
    if (index + 1 < lines.length) {
      final nextLineDate = _dateIn(lines[index + 1]);
      if (nextLineDate != null) return nextLineDate;
    }
  }
  return null;
}

String? _dateIn(String text) {
  final match = RegExp(
    r'\b(\d{4}-\d{1,2}-\d{1,2}|\d{1,2}[./-]\d{1,2}[./-]\d{4})\b',
  ).firstMatch(text);
  if (match == null) return null;
  final raw = match.group(1)!;
  final parts = raw.split(RegExp(r'[./-]')).map(int.tryParse).toList();
  if (parts.any((part) => part == null)) return null;
  final yearFirst = raw.startsWith(RegExp(r'\d{4}'));
  final year = yearFirst ? parts[0]! : parts[2]!;
  final month = parts[yearFirst ? 1 : 1]!;
  final day = yearFirst ? parts[2]! : parts[0]!;
  final date = DateTime(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return null;
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
