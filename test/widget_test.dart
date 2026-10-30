import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_login/models/credentials.dart';

void main() {
  group('Claude Credentials & PKCE tests', () {
    test('Credentials expiration logic', () {
      final now = DateTime.now();
      final creds = ClaudeCredentials(
        accessToken: 'test_access_token',
        refreshToken: 'test_refresh_token',
        expiresAt: now.add(const Duration(minutes: 5)),
        refreshTokenExpiresAt: now.add(const Duration(days: 21)),
        connectedAt: now,
        email: 'test@anthropic.com',
      );

      // Within 10 min refresh skew, isExpiringSoon should be true
      expect(creds.isExpiringSoon(const Duration(minutes: 10)), isTrue);
      // Not yet expired for 3 min skew
      expect(creds.isExpiringSoon(const Duration(minutes: 3)), isFalse);
      // Refresh token is valid
      expect(creds.isRefreshTokenExpired(), isFalse);
    });

    test('PendingOAuthState expiration logic', () {
      final pendingOld = PendingOAuthState(
        verifier: 'abc',
        state: 'xyz',
        createdAt: DateTime.now().subtract(const Duration(seconds: 601)),
      );
      expect(pendingOld.isExpired, isTrue);

      final pendingFresh = PendingOAuthState(
        verifier: 'abc',
        state: 'xyz',
        createdAt: DateTime.now().subtract(const Duration(seconds: 50)),
      );
      expect(pendingFresh.isExpired, isFalse);
    });
  });
}
