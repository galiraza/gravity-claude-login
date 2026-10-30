import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/credentials.dart';

/// Service implementing OAuth + PKCE for Claude accounts as described in ali-code.md.
class ClaudeOAuthService {
  static const String clientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
  static const String authorizeUrl = 'https://claude.com/cai/oauth/authorize';
  static const String redirectUri = 'https://platform.claude.com/oauth/code/callback';
  static const String tokenUrl = 'https://api.anthropic.com/v1/oauth/token';
  static const String profileUrl = 'https://api.anthropic.com/api/oauth/profile';
  static const String scopes =
      'org:create_api_key user:profile user:inference user:sessions:claude_code '
      'user:mcp_servers user:file_upload';

  static const String _credsKey = 'claude_creds';
  static const String _pendingKey = 'claude_pending_oauth';
  static const int refreshSkewMs = 10 * 60 * 1000; // 10 minutes

  // In-memory cached credentials and async mutex to serialize refreshes
  ClaudeCredentials? _credentials;
  Completer<void>? _refreshLock;

  ClaudeCredentials? get credentials => _credentials;
  bool get isConnected => _credentials != null && !_credentials!.isRefreshTokenExpired();

  /// Initialize service and load saved credentials from persistent storage
  Future<ClaudeCredentials?> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_credsKey);
    if (raw != null) {
      try {
        _credentials = ClaudeCredentials.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (e) {
        // Corrupt storage, clear it
        await prefs.remove(_credsKey);
      }
    }
    return _credentials;
  }

  /// Helper to generate base64url encoded cryptographically secure random bytes
  String _randomB64([int length = 32]) {
    final rnd = Random.secure();
    final bytes = List<int>.generate(length, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Helper to calculate SHA-256 base64url string without padding
  String _sha256B64(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  /// Step 1: Start OAuth PKCE flow
  /// Generates verifier and state, stores pending state, and returns the authorize URL.
  Future<String> startAuthorization() async {
    final verifier = _randomB64(32);
    final state = _randomB64(32);
    final pending = PendingOAuthState(
      verifier: verifier,
      state: state,
      createdAt: DateTime.now(),
    );

    // Save pending state to SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingKey, jsonEncode(pending.toJson()));

    final codeChallenge = _sha256B64(verifier);

    final uri = Uri.parse(authorizeUrl).replace(queryParameters: {
      'code': 'true',
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'scope': scopes,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'state': state,
    });

    return uri.toString();
  }

  /// Get currently stored pending state, if any
  Future<PendingOAuthState?> getPendingState() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingKey);
    if (raw == null) return null;
    try {
      return PendingOAuthState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Step 2: Exchange callback string (code#state) for OAuth tokens
  /// The user is shown a value on Anthropic's page and pastes it back.
  /// It arrives as `code#state` - one string, #-joined.
  Future<ClaudeCredentials> exchangeCode(String pasted) async {
    final parts = pasted.trim().split('#');
    final code = parts.isNotEmpty ? parts[0].trim() : '';
    final state = parts.length > 1 ? parts[1].trim() : '';

    if (code.isEmpty) {
      throw Exception('Paste the code from the Claude authorization page.');
    }
    if (state.isEmpty) {
      throw Exception('The pasted value is missing its #state part.');
    }

    final prefs = await SharedPreferences.getInstance();
    final pendingRaw = prefs.getString(_pendingKey);
    if (pendingRaw == null) {
      throw Exception('No pending authorization request found. Please tap "Start Authorization" first.');
    }

    final pending = PendingOAuthState.fromJson(jsonDecode(pendingRaw) as Map<String, dynamic>);

    // Validate state match
    if (pending.state != state) {
      throw Exception('Security mismatch: returned state does not match the pending authorization session.');
    }

    // Reject if older than 600s (10 minutes)
    if (pending.isExpired) {
      await prefs.remove(_pendingKey);
      throw Exception('Authorization request expired (>600s). Please start authorization again.');
    }

    // Delete pending state (single use)
    await prefs.remove(_pendingKey);

    // POST TOKEN_URL as JSON (not form-encoded)
    final response = await http.post(
      Uri.parse(tokenUrl),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
        'client_id': clientId,
        'code_verifier': pending.verifier,
        'state': state,
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String errMsg = 'Failed to exchange token (${response.statusCode})';
      try {
        final errJson = jsonDecode(response.body);
        if (errJson is Map && errJson['error_description'] != null) {
          errMsg = errJson['error_description'].toString();
        } else if (errJson is Map && errJson['error'] != null) {
          errMsg = errJson['error'].toString();
        }
      } catch (_) {}
      throw Exception(errMsg);
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final accessToken = data['access_token'] as String;
    final refreshToken = data['refresh_token'] as String;
    final expiresIn = (data['expires_in'] as int?) ?? (12 * 3600);
    final refreshExpiresIn = (data['refresh_expires_in'] as int?) ?? (21 * 24 * 3600);

    final now = DateTime.now();
    final expiresAt = now.add(Duration(seconds: expiresIn));
    final refreshTokenExpiresAt = now.add(Duration(seconds: refreshExpiresIn));

    // Fetch display name / email (optional, must never cost the login)
    String? email;
    try {
      final profRes = await http.get(
        Uri.parse(profileUrl),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'anthropic-beta': 'oauth-2025-04-20',
        },
      );
      if (profRes.statusCode == 200) {
        final profJson = jsonDecode(profRes.body) as Map<String, dynamic>;
        email = profJson['account']?['email'] as String?;
      }
    } catch (_) {
      // the account still works without a display name
    }

    final creds = ClaudeCredentials(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      refreshTokenExpiresAt: refreshTokenExpiresAt,
      connectedAt: now,
      email: email,
    );

    await _saveCredentials(creds);
    return creds;
  }

  /// Serialized token refresh mechanism.
  /// Follows rules from ali-code.md:
  /// - Refresh ahead of expiry (10 min skew)
  /// - Never overwrite on a failed refresh
  /// - Serialise the refresh (mutex lock)
  Future<ClaudeCredentials?> getValidCredentials({bool forceRefresh = false}) async {
    if (_credentials == null) return null;

    // Refresh ahead of expiry so no request waits unnecessarily
    if (!forceRefresh && !_credentials!.isExpiringSoon(const Duration(milliseconds: refreshSkewMs))) {
      return _credentials;
    }

    // Refresh token is hard-expired (~3 weeks)
    if (_credentials!.isRefreshTokenExpired()) {
      return null;
    }

    // Serialise refresh with mutex to avoid concurrent rotation races
    while (_refreshLock != null) {
      await _refreshLock!.future;
    }

    // Re-check after waiting for lock
    if (!forceRefresh && !_credentials!.isExpiringSoon(const Duration(milliseconds: refreshSkewMs))) {
      return _credentials;
    }

    _refreshLock = Completer<void>();
    try {
      // Re-read fresh credentials from storage inside the lock
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_credsKey);
      if (raw != null) {
        _credentials = ClaudeCredentials.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }

      if (!forceRefresh && !_credentials!.isExpiringSoon(const Duration(milliseconds: refreshSkewMs))) {
        return _credentials;
      }

      final next = await _performTokenRefresh(_credentials!);
      if (next != null) {
        await _saveCredentials(next);
      }
      return _credentials;
    } finally {
      final lock = _refreshLock;
      _refreshLock = null;
      lock?.complete();
    }
  }

  /// Call TOKEN_URL with refresh_token grant
  Future<ClaudeCredentials?> _performTokenRefresh(ClaudeCredentials current) async {
    try {
      final res = await http.post(
        Uri.parse(tokenUrl),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'grant_type': 'refresh_token',
          'client_id': clientId,
          'refresh_token': current.refreshToken,
        }),
      );

      // Rule: Never overwrite on a failed refresh. if (!res.ok) return null;
      // a 5xx proves nothing about the old token, and clobbering it turns a blip into a disconnected account.
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return null;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final newAccessToken = data['access_token'] as String;
      final newRefreshToken = (data['refresh_token'] as String?) ?? current.refreshToken;
      final expiresIn = (data['expires_in'] as int?) ?? (12 * 3600);
      final refreshExpiresIn = data['refresh_expires_in'] as int?;

      final now = DateTime.now();
      final newExpiresAt = now.add(Duration(seconds: expiresIn));
      final newRefreshExpiresAt = refreshExpiresIn != null
          ? now.add(Duration(seconds: refreshExpiresIn))
          : current.refreshTokenExpiresAt; // Hard-expire does NOT slide unless specified

      return current.copyWith(
        accessToken: newAccessToken,
        refreshToken: newRefreshToken,
        expiresAt: newExpiresAt,
        refreshTokenExpiresAt: newRefreshExpiresAt,
      );
    } catch (_) {
      // Network failure, preserve existing token
      return null;
    }
  }

  /// Disconnect and clear credentials
  Future<void> disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_credsKey);
    await prefs.remove(_pendingKey);
    _credentials = null;
  }

  Future<void> _saveCredentials(ClaudeCredentials creds) async {
    _credentials = creds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_credsKey, jsonEncode(creds.toJson()));
  }
}
