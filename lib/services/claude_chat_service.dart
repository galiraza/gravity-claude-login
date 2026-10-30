import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'claude_oauth_service.dart';

class ChatMessage {
  final String role; // 'user', 'assistant', or 'error'
  String content;
  String thinking;
  bool isStreaming;

  ChatMessage({
    required this.role,
    required this.content,
    this.thinking = '',
    this.isStreaming = false,
  });

  Map<String, dynamic> toApiMessage() => {
        'role': role,
        'content': content,
      };
}

/// Service implementing Claude Messages API contract as described in ali-code.md
class ClaudeChatService {
  final ClaudeOAuthService oauthService;
  final String sessionId = _generateSessionId();

  static const String apiUrl = 'https://api.anthropic.com/v1/messages?beta=true';

  ClaudeChatService({required this.oauthService});

  static String _generateSessionId() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Available Claude models following Section 9 of ali-code.md
  /// Note: claude-haiku-4-5 is default because it is universally available
  /// across standard and subscriber Claude account tiers.
  static const List<String> availableModels = [
    'claude-haiku-4-5',
    'claude-sonnet-4-5',
    'claude-sonnet-5',
    'claude-opus-5',
    'claude-fable-5',
  ];

  /// Betas are computed, not constant (Section 4 of ali-code.md):
  /// "A beta is sent only when the request actually uses the feature it gates."
  List<String> _betasFor(String model, bool thinkingOn) {
    final b = <String>['claude-code-20250219', 'oauth-2025-04-20'];
    if (RegExp(r'opus-4-').hasMatch(model)) {
      b.add('context-1m-2025-08-07');
    }

    if (thinkingOn) {
      b.add('interleaved-thinking-2025-05-14');
      b.add('redact-thinking-2026-02-12');
      b.add('thinking-token-count-2026-05-13');
    }
    return b;
  }

  /// Thinking is model-dependent (Section 4)
  Map<String, dynamic>? _thinkingFor(String model, bool enabled) {
    if (!enabled) return null;
    final isLegacy = RegExp(r'haiku|sonnet-4-5|opus-4-5|opus-4-1|3-\d').hasMatch(model);
    return isLegacy
        ? {'type': 'enabled', 'budget_tokens': 1024, 'display': 'summarized'}
        : {'type': 'adaptive', 'display': 'summarized'};
  }

  /// Send a message stream, handling SSE events and thinking blocks
  Stream<ChatMessage> sendMessageStream({
    required List<ChatMessage> conversation,
    required String model,
    bool enableThinking = false,
  }) async* {
    final creds = await oauthService.getValidCredentials();
    if (creds == null) {
      throw Exception('Not connected or authorization has expired. Please sign in again.');
    }

    final betas = _betasFor(model, enableThinking);
    final headers = {
      'content-type': 'application/json',
      'authorization': 'Bearer ${creds.accessToken}',
      'anthropic-beta': betas.join(','),
      'accept': 'application/json',
      'anthropic-version': '2023-06-01',
      'anthropic-dangerous-direct-browser-access': 'true',
      'user-agent': 'claude-cli/1.0.0 (external, cli)',
      'x-app': 'cli',
      'x-claude-code-session-id': sessionId,
    };

    final cleanMessages = conversation
        .where((m) => m.role == 'user' || m.role == 'assistant')
        .map((m) => m.toApiMessage())
        .toList();

    final bodyMap = <String, dynamic>{
      'model': model,
      'messages': cleanMessages,
      'max_tokens': enableThinking ? 3072 : 2048,
      'stream': true,
    };

    final thinkingConfig = _thinkingFor(model, enableThinking);
    if (thinkingConfig != null) {
      bodyMap['thinking'] = thinkingConfig;
    }

    debugPrint('ClaudeChat: POST $apiUrl with model $model');

    final client = http.Client();
    final request = http.Request('POST', Uri.parse(apiUrl));
    headers.forEach((k, v) => request.headers[k] = v);
    request.body = jsonEncode(bodyMap);

    http.StreamedResponse streamedResponse;
    try {
      streamedResponse = await client.send(request);
    } catch (e) {
      client.close();
      throw Exception('Network connection error: $e');
    }

    final ctype = streamedResponse.headers['content-type'] ?? '';
    debugPrint('ClaudeChat: response status ${streamedResponse.statusCode}, ctype: $ctype');

    // Handle non-200 responses (Section 6: Non-2xx on stream:true is JSON)
    if (streamedResponse.statusCode != 200 || !ctype.contains('text/event-stream')) {
      final errBody = await streamedResponse.stream.bytesToString();
      client.close();

      debugPrint('ClaudeChat: Error body: $errBody');
      String msg = 'API error (${streamedResponse.statusCode})';
      try {
        final errJson = jsonDecode(errBody) as Map<String, dynamic>;
        final errType = errJson['error']?['type'];
        final errMsg = errJson['error']?['message'];

        if (streamedResponse.statusCode == 429 || errType == 'rate_limit_error') {
          msg = 'Rate limit reached (429) for $model on your Claude account tier. '
              'Please select "claude-haiku-4-5" from the dropdown above to continue chatting.';
        } else if (errMsg != null) {
          msg = errMsg.toString();
        }
      } catch (_) {}
      throw Exception(msg);
    }

    final assistantMsg = ChatMessage(role: 'assistant', content: '', isStreaming: true);
    yield assistantMsg;

    // Parse SSE frames
    String buffer = '';
    try {
      await for (final chunk in streamedResponse.stream.transform(utf8.decoder)) {
        buffer += chunk;
        while (buffer.contains('\n\n')) {
          final splitIndex = buffer.indexOf('\n\n');
          final frame = buffer.substring(0, splitIndex).trim();
          buffer = buffer.substring(splitIndex + 2);

          if (frame.isEmpty) continue;

          for (final rawLine in frame.split('\n')) {
            final line = rawLine.trim();
            if (line.startsWith('data:')) {
              final dataStr = line.substring(5).trim();
              if (dataStr == '[DONE]') continue;
              try {
                final d = jsonDecode(dataStr) as Map<String, dynamic>;
                final type = d['type'] as String?;

                if (type == 'content_block_delta') {
                  final delta = d['delta'] as Map<String, dynamic>?;
                  final deltaType = delta?['type'] as String?;

                  if (deltaType == 'text_delta') {
                    assistantMsg.content += delta?['text'] ?? '';
                    yield assistantMsg;
                  } else if (deltaType == 'thinking_delta') {
                    assistantMsg.thinking += delta?['thinking'] ?? '';
                    yield assistantMsg;
                  }
                }
              } catch (_) {
                // Ignore malformed/unparseable frames
              }
            }
          }
        }
      }
    } finally {
      assistantMsg.isStreaming = false;
      yield assistantMsg;
      client.close();
      debugPrint('ClaudeChat: stream finished, content length: ${assistantMsg.content.length}');
    }
  }
}
