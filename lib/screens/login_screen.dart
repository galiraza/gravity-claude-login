import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/credentials.dart';
import '../services/claude_oauth_service.dart';

class LoginScreen extends StatefulWidget {
  final ClaudeOAuthService oauthService;
  final VoidCallback onLoginSuccess;

  const LoginScreen({
    super.key,
    required this.oauthService,
    required this.onLoginSuccess,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _pasteController = TextEditingController();
  bool _isLoading = false;
  String? _authUrl;
  PendingOAuthState? _pendingState;
  Timer? _timer;
  int _remainingSeconds = 600;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _checkExistingPending();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _checkExistingPending() async {
    final pending = await widget.oauthService.getPendingState();
    if (pending != null && !pending.isExpired) {
      setState(() {
        _pendingState = pending;
        _remainingSeconds = 600 - DateTime.now().difference(pending.createdAt).inSeconds;
      });
      _startExpiryTimer();
    }
  }

  void _startExpiryTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingSeconds > 0) {
        setState(() {
          _remainingSeconds--;
        });
      } else {
        timer.cancel();
        setState(() {
          _pendingState = null;
          _errorMessage = 'Pending authorization expired (>600s). Please start again.';
        });
      }
    });
  }

  Future<void> _handleStartAuth() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final url = await widget.oauthService.startAuthorization();
      final pending = await widget.oauthService.getPendingState();

      setState(() {
        _authUrl = url;
        _pendingState = pending;
        _remainingSeconds = 600;
      });
      _startExpiryTimer();

      // Launch URL in external browser
      final uri = Uri.parse(url);
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        // Fallback: user can copy URL manually
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not open browser automatically. Use "Copy Link" below.'),
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to generate authorization URL: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handlePasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _pasteController.text = data!.text!.trim();
      setState(() {});
    }
  }

  Future<void> _handleExchange() async {
    final input = _pasteController.text.trim();
    if (input.isEmpty) {
      setState(() {
        _errorMessage = 'Please paste the code#state value from Claude.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await widget.oauthService.exchangeCode(input);
      _timer?.cancel();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.green,
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 8),
                Text('Successfully connected to Claude!'),
              ],
            ),
          ),
        );
        widget.onLoginSuccess();
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect Claude Account'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Hero Banner
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isDark
                        ? [const Color(0xFF3E2723), const Color(0xFF1E1E1E)]
                        : [const Color(0xFFFBE9E7), const Color(0xFFFFF3E0)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFFD97706).withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD97706).withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.shield_outlined,
                        color: Color(0xFFD97706),
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'OAuth + PKCE Login',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Runs on your personal Claude account with no API key needed.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Error Display
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50.withValues(alpha: isDark ? 0.15 : 0.9),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade400),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.red, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // STEP 1 CARD
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: _pendingState != null
                        ? const Color(0xFFD97706)
                        : theme.dividerColor,
                    width: _pendingState != null ? 1.5 : 1,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 13,
                            backgroundColor: theme.colorScheme.primary,
                            child: const Text('1',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Open Authorization Page',
                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          if (_pendingState != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.amber.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'Pending (${_remainingSeconds}s)',
                                style: const TextStyle(
                                    color: Colors.amber, fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Tap the button to open Claude in your browser, log in, and grant permissions.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _isLoading ? null : _handleStartAuth,
                              icon: const Icon(Icons.open_in_browser, size: 18),
                              label: Text(_pendingState != null ? 'Re-open Authorization' : 'Authorize in Claude'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFD97706),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                          if (_authUrl != null) ...[
                            const SizedBox(width: 8),
                            IconButton.outlined(
                              tooltip: 'Copy Auth URL',
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: _authUrl!));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Auth URL copied to clipboard!')),
                                );
                              },
                              icon: const Icon(Icons.copy, size: 18),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // STEP 2 CARD
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: theme.dividerColor,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 13,
                            backgroundColor: theme.colorScheme.primary,
                            child: const Text('2',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Paste Callback Code',
                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'After authorizing, Anthropic displays a value formatted as "code#state". Paste it below:',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _pasteController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          hintText: 'e.g. 4_wK9s...#N3x_8q...',
                          hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          suffixIcon: IconButton(
                            tooltip: 'Paste from clipboard',
                            icon: const Icon(Icons.paste_rounded),
                            onPressed: _handlePasteFromClipboard,
                          ),
                          contentPadding: const EdgeInsets.all(12),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Helper text for code#state format
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _pasteController,
                        builder: (context, value, _) {
                          final text = value.text.trim();
                          final hasHash = text.contains('#');
                          if (text.isEmpty) return const SizedBox.shrink();
                          return Row(
                            children: [
                              Icon(
                                hasHash ? Icons.check_circle_outline : Icons.info_outline,
                                size: 14,
                                color: hasHash ? Colors.green : Colors.orange,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                hasHash
                                    ? 'Valid code#state format detected'
                                    : 'Make sure the value contains the "#" separator',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: hasHash ? Colors.green : Colors.orange,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : _handleExchange,
                          icon: _isLoading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.login_rounded, size: 18),
                          label: Text(_isLoading ? 'Exchanging token...' : 'Complete Login'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // How it works Accordion / Info Box
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  'About this OAuth PKCE flow',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.8),
                  ),
                ),
                leading: const Icon(Icons.help_outline_rounded, size: 20),
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white10 : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '• Public Client: No client secret is embedded, secured by PKCE code_challenge (SHA-256).\n'
                      '• Callback: Since Anthropic uses platform.claude.com/oauth/code/callback, the code#state string is manually pasted.\n'
                      '• Tokens: Access token expires in ~12 hours and auto-refreshes. Refresh token hard-expires in ~3 weeks.\n'
                      '• Token Security: Your credentials stay local on your device.',
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
