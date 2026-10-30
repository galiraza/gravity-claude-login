/// Stored OAuth credentials following Section 1 of ali-code.md:
/// {
///   accessToken, refreshToken,
///   expiresAt: Date.now() + (expires_in ?? 12*3600) * 1000,
///   refreshTokenExpiresAt: Date.now() + (refresh_expires_in ?? 21*24*3600) * 1000,
///   connectedAt: Date.now(),
///   email: null,
/// }
class ClaudeCredentials {
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final DateTime refreshTokenExpiresAt;
  final DateTime connectedAt;
  final String? email;

  ClaudeCredentials({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.refreshTokenExpiresAt,
    required this.connectedAt,
    this.email,
  });

  /// Check if access token is expired or within refresh skew (10 minutes)
  bool isExpiringSoon([Duration skew = const Duration(minutes: 10)]) {
    return DateTime.now().isAfter(expiresAt.subtract(skew));
  }

  /// Check if refresh token has hard-expired (~3 weeks, does not slide with use)
  bool isRefreshTokenExpired() {
    return DateTime.now().isAfter(refreshTokenExpiresAt);
  }

  ClaudeCredentials copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    DateTime? refreshTokenExpiresAt,
    DateTime? connectedAt,
    String? email,
  }) {
    return ClaudeCredentials(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      refreshTokenExpiresAt:
          refreshTokenExpiresAt ?? this.refreshTokenExpiresAt,
      connectedAt: connectedAt ?? this.connectedAt,
      email: email ?? this.email,
    );
  }

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt.millisecondsSinceEpoch,
        'refreshTokenExpiresAt': refreshTokenExpiresAt.millisecondsSinceEpoch,
        'connectedAt': connectedAt.millisecondsSinceEpoch,
        'email': email,
      };

  factory ClaudeCredentials.fromJson(Map<String, dynamic> json) {
    return ClaudeCredentials(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(json['expiresAt'] as int),
      refreshTokenExpiresAt: DateTime.fromMillisecondsSinceEpoch(
          json['refreshTokenExpiresAt'] as int),
      connectedAt:
          DateTime.fromMillisecondsSinceEpoch(json['connectedAt'] as int),
      email: json['email'] as String?,
    );
  }
}

/// Pending PKCE state stored while the user is authorizing in the browser.
/// Reject if older than 600s (10 minutes).
class PendingOAuthState {
  final String verifier;
  final String state;
  final DateTime createdAt;

  PendingOAuthState({
    required this.verifier,
    required this.state,
    required this.createdAt,
  });

  bool get isExpired =>
      DateTime.now().difference(createdAt).inSeconds > 600;

  Map<String, dynamic> toJson() => {
        'verifier': verifier,
        'state': state,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory PendingOAuthState.fromJson(Map<String, dynamic> json) {
    return PendingOAuthState(
      verifier: json['verifier'] as String,
      state: json['state'] as String,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
    );
  }
}
