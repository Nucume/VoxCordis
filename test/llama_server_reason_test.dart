import 'package:companion/services/runtime/llama_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a failed load names the first error, not the exit line', () {
    final e = LlamaServerException(
      'The runtime stopped while loading the model.',
      [
        'I srv    load_model: loading model',
        "E gguf_init_from_file: failed to open GGUF file 'x.gguf'",
        'E srv    load_model: failed to load model',
        'E srv  llama_server: exiting due to model loading error',
      ].join('\n'),
    );
    expect(e.reason, contains('failed to open GGUF file'));
    expect(e.toString(), isNot(contains('exiting due to')));
  });

  test('only the exit line is still better than nothing', () {
    final e = LlamaServerException(
      'Stopped.',
      'E srv  llama_server: exiting due to model loading error',
    );
    expect(e.reason, contains('exiting due to'));
    expect(LlamaServerException('Stopped.', '').toString(), 'Stopped.');
  });
}
