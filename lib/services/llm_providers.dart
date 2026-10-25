/// Cloud services the Server-hosted brain can talk to without the human
/// looking up their address. Everything else, local servers included, is
/// [custom].
enum LlmProvider {
  openRouter(
    label: 'OpenRouter',
    endpoint: 'https://openrouter.ai/api/v1',
    host: 'openrouter.ai',
    keyUrl: 'https://openrouter.ai/settings/keys',
    blurb:
        'Hundreds of models from many makers with one key, '
        'open-weight ones included.',
  ),
  openAi(
    label: 'OpenAI',
    endpoint: 'https://api.openai.com/v1',
    host: 'api.openai.com',
    keyUrl: 'https://platform.openai.com/api-keys',
    blurb: "OpenAI's GPT models.",
  ),
  anthropic(
    label: 'Anthropic',
    endpoint: 'https://api.anthropic.com/v1',
    host: 'api.anthropic.com',
    keyUrl: 'https://platform.claude.com/settings/keys',
    blurb: "Anthropic's Claude models.",
    suggestedModels: [
      'claude-sonnet-5-5',
      'claude-haiku-5-5',
      'claude-opus-5-5',
    ],
  ),
  custom(
    label: 'Custom',
    endpoint: 'http://localhost:11434/v1',
    host: '',
    keyUrl: '',
    blurb:
        'Ollama, LM Studio, llama.cpp, or any OpenAI-compatible API, on '
        'this computer or another one.',
  );

  const LlmProvider({
    required this.label,
    required this.endpoint,
    required this.host,
    required this.keyUrl,
    required this.blurb,
    this.suggestedModels = const [],
  });

  final String label;

  /// The base URL the chat requests go to.
  final String endpoint;
  final String host;

  /// Where the human makes an API key.
  final String keyUrl;
  final String blurb;

  /// Offered before the human has fetched the real list, which needs a key.
  final List<String> suggestedModels;

  /// The provider whose address [endpoint] is, or [custom].
  static LlmProvider forEndpoint(String endpoint) {
    final host = Uri.tryParse(endpoint.trim())?.host.toLowerCase() ?? '';
    for (final p in values) {
      if (p != custom && host == p.host) return p;
    }
    return custom;
  }
}
