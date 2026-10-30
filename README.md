# Claude Gravity Login & Assistant (Flutter)

A Flutter application implementing user-backed Claude account authentication via **OAuth 2.0 + PKCE** (without requiring an API key) alongside real-time streaming chat over Anthropic's Messages API with model-dependent thinking support.

---

## 🌟 Features

- **OAuth + PKCE Authentication**:
  - Secure authorization flow using a public client (`9d1c250a-e61b-44d9-88ed-5944d1962f5e`) and SHA-256 PKCE challenges.
  - Seamless manual-paste exchange for `code#state` values from Anthropic's callback page (`https://platform.claude.com/oauth/code/callback`).
  - Stored pending sessions with strict 600-second TTL security verification.
- **Token Health & Serialized Rotation**:
  - Serialized token refresh mechanism preventing race conditions during refresh token rotation.
  - Refresh skew margin (10 minutes) to refresh tokens ahead of expiration.
  - Real-time countdown tracking for access tokens and Anthropic's ~3-week hard-expiring refresh tokens.
- **Claude Assistant & Real-Time SSE Streaming**:
  - Direct integration with `https://api.anthropic.com/v1/messages?beta=true`.
  - Dynamic, computed betas based on features (`claude-code-20250219`, `oauth-2025-04-20`, `interleaved-thinking-2025-05-14`, etc.).
  - Support for `claude-haiku-4-5`, `claude-sonnet-4-5`, `claude-sonnet-5`, and `claude-opus-5`.
  - Live Server-Sent Events (SSE) parsing supporting incremental text streams and expandable thinking process blocks.

---

## 🚀 Getting Started

### Prerequisites

- Flutter SDK (3.x or higher)
- Dart SDK (3.x or higher)
- Android SDK (for mobile execution)

### Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/galiraza/gravity-claude-login.git
   cd gravity-claude-login
   ```

2. Install dependencies:
   ```bash
   flutter pub get
   ```

3. Run the app:
   ```bash
   flutter run
   ```

---

## 📁 Architecture Overview

```
lib/
├── main.dart                          # Application bootstrap and Material 3 theme configuration
├── models/
│   └── credentials.dart               # ClaudeCredentials and PendingOAuthState data models
├── services/
│   ├── claude_oauth_service.dart      # PKCE generation, token exchange, and serialized rotation
│   └── claude_chat_service.dart       # Anthropic Messages API contract, headers, and SSE stream parser
└── screens/
    ├── login_screen.dart              # Step 1 (Browser Auth) & Step 2 (Paste code#state)
    └── connected_screen.dart          # Token validity monitor, rotation test, and chat console
```

---

## 🔒 Security & Privacy

- All credentials (`accessToken`, `refreshToken`, and expiry metadata) are stored locally on the device using Android's encrypted local storage via `SharedPreferences`.
- Tokens are never logged or exposed in public routes.
