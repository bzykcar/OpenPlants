import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Supported cloud AI providers for photo-based plant diagnosis.
enum AiProvider { gemini, claude }

extension AiProviderX on AiProvider {
  String get id => name;

  String get displayName => switch (this) {
        AiProvider.gemini => 'Google Gemini',
        AiProvider.claude => 'Anthropic Claude',
      };

  String get defaultModel => switch (this) {
        AiProvider.gemini => 'gemini-flash-latest',
        AiProvider.claude => 'claude-sonnet-5-5',
      };

  String get apiKeyUrl => switch (this) {
        AiProvider.gemini => 'https://aistudio.google.com/apikey',
        AiProvider.claude => 'https://console.anthropic.com/settings/keys',
      };

  static AiProvider? fromId(String? id) {
    for (final provider in AiProvider.values) {
      if (provider.id == id) return provider;
    }
    return null;
  }
}

/// Error raised when the AI request fails. [message] is safe to show to the user.
class AiDiagnosisException implements Exception {
  final String message;
  final int? statusCode;

  const AiDiagnosisException(this.message, {this.statusCode});

  @override
  String toString() => 'AiDiagnosisException($statusCode): $message';
}

/// Everything the model needs to know about the plant besides the photo.
class AiDiagnosisRequest {
  final Uint8List? imageJpeg;
  final String languageCode;
  final String? plantName;
  final String? speciesName;
  final String? room;
  final String? userDescription;
  final String? questionnaireSummary;

  const AiDiagnosisRequest({
    required this.languageCode,
    this.imageJpeg,
    this.plantName,
    this.speciesName,
    this.room,
    this.userDescription,
    this.questionnaireSummary,
  });
}

/// Care schedule suggested by the cloud model. Intervals are in days; 0 means "skip".
class AiCarePlan {
  final String species;
  final int wateringDays;
  final int fertilizingDays;
  final int mistingDays;
  final int repottingDays;
  final String summary;

  const AiCarePlan({
    required this.species,
    required this.wateringDays,
    required this.fertilizingDays,
    required this.mistingDays,
    required this.repottingDays,
    required this.summary,
  });

  static AiCarePlan parse(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const AiDiagnosisException('AI nie zwróciło planu w oczekiwanym formacie. Spróbuj ponownie.');
    }
    final Object? value;
    try {
      value = jsonDecode(raw.substring(start, end + 1));
    } catch (_) {
      throw const AiDiagnosisException('AI nie zwróciło planu w oczekiwanym formacie. Spróbuj ponownie.');
    }
    if (value is! Map) {
      throw const AiDiagnosisException('AI nie zwróciło planu w oczekiwanym formacie. Spróbuj ponownie.');
    }

    final Map<dynamic, dynamic> map = value;

    int days(String key, {required int max}) {
      final v = map[key];
      final n = v is num ? v.round() : int.tryParse('$v') ?? 0;
      return n < 0 ? 0 : (n > max ? max : n);
    }

    final watering = days('watering_days', max: 60);
    if (watering <= 0) {
      throw const AiDiagnosisException('AI nie podało częstotliwości podlewania. Spróbuj ponownie.');
    }
    return AiCarePlan(
      species: map['species'] is String ? (map['species'] as String).trim() : '',
      wateringDays: watering,
      fertilizingDays: days('fertilizing_days', max: 180),
      mistingDays: days('misting_days', max: 60),
      repottingDays: days('repotting_days', max: 1460),
      summary: map['summary'] is String ? (map['summary'] as String).trim() : '',
    );
  }
}

/// Species identified by the cloud model.
class AiSpeciesResult {
  final String scientific;
  final String common;
  final String confidence;
  final String note;

  const AiSpeciesResult({
    required this.scientific,
    required this.common,
    required this.confidence,
    required this.note,
  });

  bool get isEmpty => scientific.isEmpty && common.isEmpty;

  /// Text for the species field, e.g. "Peperomia obtusifolia (Peperomia tępolistna)".
  String get speciesLabel {
    if (scientific.isEmpty) return common;
    if (common.isEmpty || common.toLowerCase() == scientific.toLowerCase()) return scientific;
    return '$scientific ($common)';
  }

  static AiSpeciesResult parse(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final value = jsonDecode(raw.substring(start, end + 1));
        if (value is Map) {
          String field(String key) => (value[key] is String) ? (value[key] as String).trim() : '';
          return AiSpeciesResult(
            scientific: field('scientific'),
            common: field('common'),
            confidence: field('confidence'),
            note: field('note'),
          );
        }
      } catch (_) {
        // Fall through to the plain-text fallback below.
      }
    }
    final firstLine = raw.trim().split('\n').first.trim();
    return AiSpeciesResult(scientific: firstLine, common: '', confidence: '', note: '');
  }
}

/// Sends a plant photo plus context to Gemini or Claude and returns the diagnosis text.
///
/// Uses `dart:io` [HttpClient] directly so no extra package is needed.
class AiDiagnosisService {
  static const Duration _timeout = Duration(seconds: 90);
  static const int _maxImageSide = 1280;

  const AiDiagnosisService();

  /// Reads an image file and re-encodes it as a JPEG no larger than [_maxImageSide] px.
  ///
  /// Runs in a background isolate so the UI stays responsive.
  static Future<Uint8List> prepareImage(String path) {
    return Isolate.run(() {
      final bytes = File(path).readAsBytesSync();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw const AiDiagnosisException('Nie udało się odczytać zdjęcia.');
      final oriented = img.bakeOrientation(decoded);
      final longest = oriented.width > oriented.height ? oriented.width : oriented.height;
      final resized = longest > _maxImageSide
          ? (oriented.width >= oriented.height
              ? img.copyResize(oriented, width: _maxImageSide)
              : img.copyResize(oriented, height: _maxImageSide))
          : oriented;
      return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
    });
  }

  Future<String> diagnose({
    required AiProvider provider,
    required String apiKey,
    required AiDiagnosisRequest request,
    String? model,
  }) async {
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isEmpty) throw const AiDiagnosisException('Brak klucza API.');
    final effectiveModel = (model == null || model.trim().isEmpty) ? provider.defaultModel : model.trim();
    final prompt = buildPrompt(request);

    return switch (provider) {
      AiProvider.gemini => _callGemini(trimmedKey, effectiveModel, prompt, request.imageJpeg),
      AiProvider.claude => _callClaude(trimmedKey, effectiveModel, prompt, request.imageJpeg),
    };
  }

  /// Sends a tiny text-only request to verify the key and model. Returns the model's reply.
  Future<String> testConnection({
    required AiProvider provider,
    required String apiKey,
    String? model,
  }) {
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isEmpty) throw const AiDiagnosisException('Brak klucza API.');
    final effectiveModel = (model == null || model.trim().isEmpty) ? provider.defaultModel : model.trim();
    const prompt = 'Reply with the single word OK.';
    return switch (provider) {
      AiProvider.gemini => _callGemini(trimmedKey, effectiveModel, prompt, null),
      AiProvider.claude => _callClaude(trimmedKey, effectiveModel, prompt, null),
    };
  }

  /// Identifies the plant species in [imageJpeg]. Uses the app language for the common name.
  Future<AiSpeciesResult> identifySpecies({
    required AiProvider provider,
    required String apiKey,
    required Uint8List imageJpeg,
    required String languageCode,
    String? model,
  }) async {
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isEmpty) throw const AiDiagnosisException('Brak klucza API.');
    final effectiveModel = (model == null || model.trim().isEmpty) ? provider.defaultModel : model.trim();
    final language = _languageName(languageCode);
    final prompt = 'Identify the plant in the photo. Reply with ONLY a JSON object, no markdown, with keys: '
        '"scientific" (Latin binomial, plus cultivar in quotes if clearly visible, e.g. "Peperomia obtusifolia \'Variegata\'"), '
        '"common" (the most common $language name, or empty string if none), '
        '"confidence" ("high", "medium" or "low"), '
        '"note" (one short $language sentence: key care tip and toxicity to pets/children if relevant). '
        'If the photo does not show a plant, return {"scientific":"","common":"","confidence":"low","note":"<explain in $language>"}.';

    final raw = await switch (provider) {
      AiProvider.gemini => _callGemini(trimmedKey, effectiveModel, prompt, imageJpeg),
      AiProvider.claude => _callClaude(trimmedKey, effectiveModel, prompt, imageJpeg),
    };
    return AiSpeciesResult.parse(raw);
  }

  /// Asks the model for a care schedule (intervals in days) for the current season.
  Future<AiCarePlan> suggestCarePlan({
    required AiProvider provider,
    required String apiKey,
    required String languageCode,
    String? speciesName,
    String? plantName,
    String? room,
    String? lightLevel,
    Uint8List? imageJpeg,
    String? model,
  }) async {
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isEmpty) throw const AiDiagnosisException('Brak klucza API.');
    final effectiveModel = (model == null || model.trim().isEmpty) ? provider.defaultModel : model.trim();
    final language = _languageName(languageCode);
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June', //
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final month = months[DateTime.now().month - 1];

    final context = StringBuffer();
    void line(String label, String? value) {
      if (value != null && value.trim().isNotEmpty) context.writeln('- $label: ${value.trim()}');
    }

    line('Species', speciesName);
    line('Plant name given by owner', plantName);
    line('Room', room);
    line('Light level at its spot', lightLevel);
    line('Current month', '$month (Central Europe, indoor, heated home)');

    final prompt = 'You are a houseplant care expert. Build a care schedule for this indoor plant.\n'
        '${imageJpeg != null ? 'A photo of the plant is attached; use it to identify the species if unknown.\n' : ''}'
        '$context\n'
        'Reply with ONLY a JSON object, no markdown, with keys:\n'
        '"species" (Latin name you assumed),\n'
        '"watering_days" (integer, typical interval for the CURRENT season),\n'
        '"fertilizing_days" (integer, 0 if the plant should not be fertilized in the current season),\n'
        '"misting_days" (integer, 0 if misting is not recommended),\n'
        '"repotting_days" (integer, typical interval, e.g. 365 or 730),\n'
        '"summary" ($language, 3-5 short sentences: how to check if it needs water, how the schedule '
        'changes between summer and winter, fertilizer type, one common mistake to avoid).\n'
        'Be conservative with watering: overwatering is the most common cause of houseplant death.';

    final raw = await switch (provider) {
      AiProvider.gemini => _callGemini(trimmedKey, effectiveModel, prompt, imageJpeg),
      AiProvider.claude => _callClaude(trimmedKey, effectiveModel, prompt, imageJpeg),
    };
    return AiCarePlan.parse(raw);
  }

  /// Builds the instruction text sent alongside the photo.
  static String buildPrompt(AiDiagnosisRequest request) {
    final language = _languageName(request.languageCode);
    final buffer = StringBuffer()
      ..writeln('You are an experienced houseplant doctor helping a home gardener.')
      ..writeln(
        request.imageJpeg != null
            ? 'Look carefully at the attached photo of the plant and diagnose any health problems.'
            : 'No photo is attached. Diagnose based on the description only and say that a photo would help.',
      )
      ..writeln()
      ..writeln('What the owner told us:');

    void line(String label, String? value) {
      if (value != null && value.trim().isNotEmpty) buffer.writeln('- $label: ${value.trim()}');
    }

    line('Plant name', request.plantName);
    line('Species', request.speciesName);
    line('Room', request.room);
    line('Owner description', request.userDescription);
    line("Result of the app's rule-based questionnaire", request.questionnaireSummary);

    buffer
      ..writeln()
      ..writeln('Answer in $language, in plain text without markdown tables or headings with #.')
      ..writeln('Use exactly these sections, each starting on a new line with the label followed by a colon:')
      ..writeln('1. Species (only if you can tell, with how sure you are)')
      ..writeln('2. What I see (visible symptoms in the photo)')
      ..writeln('3. Most likely causes (max 3, most likely first, each with confidence: high/medium/low)')
      ..writeln('4. What to do now (concrete steps)')
      ..writeln('5. What to check in a week')
      ..writeln('6. When to worry (signs that need faster action, e.g. spreading pests)')
      ..writeln()
      ..writeln(
        'Be honest about uncertainty. If the photo is unclear or not a plant, say so and ask for a better photo. '
        'If a pest or disease could spread, tell the owner to isolate the plant. '
        'Mention toxicity to pets or children only if relevant to the species. Keep it under 350 words.',
      );
    return buffer.toString();
  }

  static String _languageName(String code) => switch (code) {
        'pl' => 'Polish',
        'de' => 'German',
        'es' => 'Spanish',
        _ => 'English',
      };

  Future<String> _callGemini(String apiKey, String model, String prompt, Uint8List? image) async {
    final uri = Uri.https('generativelanguage.googleapis.com', '/v1beta/models/$model:generateContent');
    final parts = <Map<String, dynamic>>[
      if (image != null)
        {
          'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(image)},
        },
      {'text': prompt},
    ];
    final body = {
      'contents': [
        {'role': 'user', 'parts': parts},
      ],
      'generationConfig': {'temperature': 0.3},
    };

    final json = await _postJson(uri, {'x-goog-api-key': apiKey}, body);
    final candidates = json['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final content = (candidates.first as Map)['content'];
      final responseParts = content is Map ? content['parts'] : null;
      if (responseParts is List) {
        final text = responseParts
            .whereType<Map>()
            .map((part) => part['text'])
            .whereType<String>()
            .join('\n')
            .trim();
        if (text.isNotEmpty) return text;
      }
      final reason = (candidates.first as Map)['finishReason'];
      if (reason != null) throw AiDiagnosisException('Model nie zwrócił odpowiedzi (powód: $reason).');
    }
    final blockReason = (json['promptFeedback'] is Map) ? (json['promptFeedback'] as Map)['blockReason'] : null;
    if (blockReason != null) throw AiDiagnosisException('Zapytanie zablokowane przez Gemini ($blockReason).');
    throw const AiDiagnosisException('Pusta odpowiedź od Gemini.');
  }

  Future<String> _callClaude(String apiKey, String model, String prompt, Uint8List? image) async {
    final uri = Uri.https('api.anthropic.com', '/v1/messages');
    final content = <Map<String, dynamic>>[
      if (image != null)
        {
          'type': 'image',
          'source': {'type': 'base64', 'media_type': 'image/jpeg', 'data': base64Encode(image)},
        },
      {'type': 'text', 'text': prompt},
    ];
    final body = {
      'model': model,
      'max_tokens': 1500,
      'messages': [
        {'role': 'user', 'content': content},
      ],
    };

    final json = await _postJson(
      uri,
      {'x-api-key': apiKey, 'anthropic-version': '2023-06-01'},
      body,
    );
    final blocks = json['content'];
    if (blocks is List) {
      final text = blocks
          .whereType<Map>()
          .where((block) => block['type'] == 'text')
          .map((block) => block['text'])
          .whereType<String>()
          .join('\n')
          .trim();
      if (text.isNotEmpty) return text;
    }
    throw const AiDiagnosisException('Pusta odpowiedź od Claude.');
  }

  Future<Map<String, dynamic>> _postJson(Uri uri, Map<String, String> headers, Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.postUrl(uri).timeout(_timeout);
      request.headers.contentType = ContentType.json;
      headers.forEach(request.headers.set);
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(_timeout);
      final raw = await response.transform(utf8.decoder).join().timeout(_timeout);

      Map<String, dynamic>? decoded;
      try {
        final value = jsonDecode(raw);
        if (value is Map) decoded = Map<String, dynamic>.from(value);
      } catch (_) {
        decoded = null;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiDiagnosisException(
          _friendlyHttpError(response.statusCode, _extractApiError(decoded)),
          statusCode: response.statusCode,
        );
      }
      if (decoded == null) throw const AiDiagnosisException('Nieprawidłowa odpowiedź serwera.');
      return decoded;
    } on AiDiagnosisException {
      rethrow;
    } on TimeoutException {
      throw const AiDiagnosisException('Przekroczono czas oczekiwania. Sprawdź internet i spróbuj ponownie.');
    } on SocketException {
      throw const AiDiagnosisException('Brak połączenia z internetem.');
    } on HandshakeException {
      throw const AiDiagnosisException('Nie udało się nawiązać bezpiecznego połączenia.');
    } finally {
      client.close(force: true);
    }
  }

  static String? _extractApiError(Map<String, dynamic>? json) {
    final error = json?['error'];
    if (error is Map && error['message'] is String) return error['message'] as String;
    return null;
  }

  static String _friendlyHttpError(int status, String? apiMessage) {
    final base = switch (status) {
      400 => 'Nieprawidłowe zapytanie (sprawdź nazwę modelu).',
      401 || 403 => 'Klucz API jest nieprawidłowy albo nie ma uprawnień.',
      404 => 'Nie znaleziono modelu. Sprawdź nazwę modelu w ustawieniach AI.',
      429 => 'Przekroczono limit zapytań. Odczekaj chwilę i spróbuj ponownie.',
      529 || 503 => 'Serwer AI jest chwilowo przeciążony. Spróbuj za chwilę.',
      _ => 'Błąd serwera AI (kod $status).',
    };
    return apiMessage == null ? base : '$base\n\n$apiMessage';
  }
}
