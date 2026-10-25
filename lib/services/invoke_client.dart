import 'dart:io';

import 'package:http/http.dart' as http;

/// Adapter for a local InvokeAI server. Invoke's REST API changes between
/// versions, so everything Invoke-specific stays behind this class.
///
/// v1 shell: only [ping] works. [generate] lands in Phase 2 once the user's
/// Invoke version is pinned (queue a graph, poll the session, download).
class InvokeClient {
  InvokeClient(this.baseUrl, {http.Client? client})
    : _http = client ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  /// The `generate_image` tool offered to the model once [generate] works.
  static const toolDefinition = <String, Object?>{
    'type': 'function',
    'function': {
      'name': 'generate_image',
      'description': 'Paint a picture with the local image generator.',
      'parameters': {
        'type': 'object',
        'properties': {
          'prompt': {'type': 'string'},
          'file_name': {
            'type': 'string',
            'description': 'Short kebab-case name, without extension.',
          },
        },
        'required': ['prompt'],
      },
    },
  };

  /// Returns Invoke's version string, or null if it can't be reached.
  Future<String?> ping() async {
    try {
      final res = await _http
          .get(Uri.parse('$baseUrl/api/v1/app/version'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200 ? res.body : null;
    } catch (_) {
      return null;
    }
  }

  /// Generates an image and saves it into [imagesDir]. Not implemented yet.
  Future<File> generate({
    required String prompt,
    required Directory imagesDir,
    String? fileName,
  }) {
    throw UnimplementedError('Invoke generation arrives in Phase 2.');
  }
}
