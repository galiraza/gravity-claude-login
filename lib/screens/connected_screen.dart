import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/claude_oauth_service.dart';
import '../services/claude_chat_service.dart';

class ConnectedScreen extends StatefulWidget {
  final ClaudeOAuthService oauthService;
  final VoidCallback onLogout;

  const ConnectedScreen({
    super.key,
    required this.oauthService,
    required this.onLogout,
  });

  @override
  State<ConnectedScreen> createState() => _ConnectedScreenState();
}

class _ConnectedScreenState extends State<ConnectedScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late ClaudeChatService _chatService;
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final List<ChatMessage> _messages = [];
  bool _isSending = false;
  bool _isRefreshing = false;
  String _selectedModel = ClaudeChatService.availableModels.first; // Defaults to claude-haiku-4-5
  bool _enableThinking = false;

  Timer? _countdownTimer;
  Duration _accessTokenRemaining = Duration.zero;
  Duration _refreshTokenRemaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this, initialIndex: 1); // Start on chat tab
    _chatService = ClaudeChatService(oauthService: widget.oauthService);
    _updateCountdowns();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateCountdowns());
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _tabController.dispose();
    _promptController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _updateCountdowns() {
    final creds = widget.oauthService.credentials;
    if (creds == null) return;

    final now = DateTime.now();
    setState(() {
      _accessTokenRemaining = creds.expiresAt.isAfter(now)
          ? creds.expiresAt.difference(now)
          : Duration.zero;
      _refreshTokenRemaining = creds.refreshTokenExpiresAt.isAfter(now)
          ? creds.refreshTokenExpiresAt.difference(now)
          : Duration.zero;
    });
  }

  String _formatDuration(Duration d) {
    if (d == Duration.zero) return 'Expired';
    final days = d.inDays;
    final hours = d.inHours % 24;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;

    if (days > 0) return '${days}d ${hours}h ${minutes}m';
    if (hours > 0) return '${hours}h ${minutes}m ${seconds}s';
    return '${minutes}m ${seconds}s';
  }

  Future<void> _handleManualRefresh() async {
    setState(() => _isRefreshing = true);
    try {
      final creds = await widget.oauthService.getValidCredentials(forceRefresh: true);
      if (creds != null && mounted) {
        _updateCountdowns();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.green,
            content: Text('Token rotated successfully! New expiry times saved.'),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.red,
            content: Text('Token refresh was rejected or returned an error.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red,
            content: Text('Refresh failed: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> _handleDisconnect() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect Account?'),
        content: const Text(
          'This will clear stored OAuth credentials from your device. You will need to log in again to use Claude.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await widget.oauthService.disconnect();
      widget.onLogout();
    }
  }

  Future<void> _sendMessage([String? presetText]) async {
    final text = presetText ?? _promptController.text.trim();
    if (text.isEmpty || _isSending) return;

    _promptController.clear();
    FocusScope.of(context).unfocus(); // Dismiss keyboard so user sees full response

    final userMsg = ChatMessage(role: 'user', content: text);
    final assistantMsg = ChatMessage(role: 'assistant', content: '', isStreaming: true);

    setState(() {
      _messages.add(userMsg);
      _messages.add(assistantMsg);
      _isSending = true;
    });

    _scrollToBottom();

    try {
      // Send only preceding messages up to the user's latest query
      final history = _messages.where((m) => m != assistantMsg && m.role != 'error').toList();

      final stream = _chatService.sendMessageStream(
        conversation: history,
        model: _selectedModel,
        enableThinking: _enableThinking,
      );

      await for (final streamedMsg in stream) {
        if (mounted) {
          setState(() {
            assistantMsg.content = streamedMsg.content;
            assistantMsg.thinking = streamedMsg.thinking;
            assistantMsg.isStreaming = streamedMsg.isStreaming;
          });
          _scrollToBottom();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          assistantMsg.isStreaming = false;
          _messages.remove(assistantMsg);
          _messages.add(ChatMessage(
            role: 'error',
            content: e.toString().replaceAll('Exception: ', ''),
          ));
        });
        _scrollToBottom();
      }
    } finally {
      if (mounted) {
        setState(() {
          assistantMsg.isStreaming = false;
          _isSending = false;
        });
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final creds = widget.oauthService.credentials;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Claude Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.logout_rounded),
            onPressed: _handleDisconnect,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.shield_outlined), text: 'OAuth & Token'),
            Tab(icon: Icon(Icons.chat_bubble_outline), text: 'Chat with Claude'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // TAB 1: OAuth & Token Status
          SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Account Identity Card
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: theme.dividerColor),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(18.0),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 26,
                              backgroundColor: const Color(0xFFD97706).withValues(alpha: 0.15),
                              child: const Icon(Icons.account_circle, color: Color(0xFFD97706), size: 36),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    creds?.email ?? 'Claude Connected User',
                                    style: theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.green.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: const Text(
                                      '● Active PKCE Session',
                                      style: TextStyle(
                                        color: Colors.green,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (creds != null) ...[
                          const Divider(height: 24),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Connected since:', style: theme.textTheme.bodySmall),
                              Text(
                                DateFormat('MMM d, y • HH:mm').format(creds.connectedAt),
                                style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Access Token Card
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: theme.dividerColor),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(18.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.key, color: Colors.blueAccent, size: 20),
                            const SizedBox(width: 8),
                            Text('Access Token Expiry',
                                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(_accessTokenRemaining),
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.blueAccent,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.blueAccent.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                'Auto-refreshes (10m skew)',
                                style: TextStyle(fontSize: 11, color: Colors.blueAccent),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (creds != null)
                          Text(
                            'Expires at: ${DateFormat('MMM d, y • HH:mm:ss').format(creds.expiresAt)}',
                            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                          ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Refresh Token Expiry Notice Card (Crucial point from doc)
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: _refreshTokenRemaining.inDays < 3 ? Colors.red : Colors.orange.shade300,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(18.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.timelapse_rounded, color: Colors.orange, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              'Refresh Token Hard Expiry',
                              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _formatDuration(_refreshTokenRemaining),
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: _refreshTokenRemaining.inDays < 3 ? Colors.red : Colors.orange,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (creds != null)
                          Text(
                            'Hard expires on: ${DateFormat('MMM d, y • HH:mm').format(creds.refreshTokenExpiresAt)}',
                            style: theme.textTheme.bodySmall,
                          ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orange),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Per Anthropic OAuth spec, refresh tokens hard-expire (~3 weeks) and do NOT slide with use.',
                                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Manual Token Refresh Action
                OutlinedButton.icon(
                  onPressed: _isRefreshing ? null : _handleManualRefresh,
                  icon: _isRefreshing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_rounded),
                  label: Text(_isRefreshing ? 'Refreshing Token...' : 'Test Token Rotation (Refresh Now)'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ),

          // TAB 2: Live Claude Chat & Streaming Test
          Column(
            children: [
              // Chat Settings Bar (Model selector & Thinking switch)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
                  border: Border(bottom: BorderSide(color: theme.dividerColor)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.model_training, size: 18, color: Color(0xFFD97706)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedModel,
                          isDense: true,
                          isExpanded: true,
                          items: ClaudeChatService.availableModels
                              .map((m) => DropdownMenuItem(
                                    value: m,
                                    child: Text(
                                      m == 'claude-haiku-4-5' ? '$m (Default)' : m,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: m == 'claude-haiku-4-5' ? FontWeight.bold : FontWeight.normal,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ))
                              .toList(),
                          onChanged: (val) {
                            if (val != null) setState(() => _selectedModel = val);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Thinking', style: TextStyle(fontSize: 12)),
                        Switch(
                          value: _enableThinking,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          onChanged: (val) => setState(() => _enableThinking = val),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Messages List
              Expanded(
                child: _messages.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.smart_toy_outlined, size: 48, color: theme.hintColor),
                              const SizedBox(height: 12),
                              Text(
                                'Chat with Claude',
                                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Authenticated via OAuth (claude-haiku-4-5 ready)',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall,
                              ),
                              const SizedBox(height: 18),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                alignment: WrapAlignment.center,
                                children: [
                                  ActionChip(
                                    label: const Text('Say Hello'),
                                    onPressed: () => _sendMessage('Hello Claude! Introduce yourself.'),
                                  ),
                                  ActionChip(
                                    label: const Text('Tell a joke'),
                                    onPressed: () => _sendMessage('Tell me a short programmer joke!'),
                                  ),
                                  ActionChip(
                                    label: const Text('Write Flutter code'),
                                    onPressed: () => _sendMessage('Give me a simple Flutter widget example.'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (context, idx) {
                          final msg = _messages[idx];
                          final isUser = msg.role == 'user';
                          final isError = msg.role == 'error';

                          if (isError) {
                            return Container(
                              margin: const EdgeInsets.only(bottom: 14),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: Colors.red.shade50.withValues(alpha: isDark ? 0.15 : 0.9),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.red.shade400),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Row(
                                    children: [
                                      Icon(Icons.error_outline, color: Colors.red, size: 20),
                                      SizedBox(width: 8),
                                      Text(
                                        'Request Error',
                                        style: TextStyle(
                                          color: Colors.red,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    msg.content,
                                    style: TextStyle(
                                      color: isDark ? Colors.red.shade200 : Colors.red.shade900,
                                      fontSize: 13,
                                    ),
                                  ),
                                  if (_selectedModel != 'claude-haiku-4-5') ...[
                                    const SizedBox(height: 10),
                                    ElevatedButton.icon(
                                      icon: const Icon(Icons.swap_horiz, size: 16),
                                      label: const Text('Switch to claude-haiku-4-5'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFFD97706),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        textStyle: const TextStyle(fontSize: 12),
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _selectedModel = 'claude-haiku-4-5';
                                        });
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Switched to claude-haiku-4-5. Try sending your message again!')),
                                        );
                                      },
                                    ),
                                  ],
                                ],
                              ),
                            );
                          }

                          return Container(
                            margin: const EdgeInsets.only(bottom: 14),
                            child: Column(
                              crossAxisAlignment:
                                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      isUser ? Icons.person : Icons.auto_awesome,
                                      size: 14,
                                      color: isUser ? Colors.blue : const Color(0xFFD97706),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      isUser ? 'You' : 'Claude',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isUser ? Colors.blue : const Color(0xFFD97706),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                // Thinking Block (if present)
                                if (msg.thinking.isNotEmpty) ...[
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: isDark ? Colors.grey.shade900 : Colors.amber.shade50,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Row(
                                          children: [
                                            Icon(Icons.psychology, size: 14, color: Colors.amber),
                                            SizedBox(width: 4),
                                            Text(
                                              'Thinking process',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.amber,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          msg.thinking,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontStyle: FontStyle.italic,
                                            color: isDark ? Colors.grey.shade400 : Colors.grey.shade800,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                // Content Bubble
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: isUser
                                        ? theme.colorScheme.primary
                                        : (isDark ? Colors.grey.shade800 : Colors.grey.shade200),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: SelectableText(
                                    msg.content.isEmpty && msg.isStreaming
                                        ? 'Claude is thinking...'
                                        : msg.content,
                                    style: TextStyle(
                                      color: isUser
                                          ? Colors.white
                                          : (isDark ? Colors.white : Colors.black87),
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),

              // Chat Input Bar
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.scaffoldBackgroundColor,
                  border: Border(top: BorderSide(color: theme.dividerColor)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _promptController,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: 'Ask Claude something...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      style: IconButton.styleFrom(backgroundColor: const Color(0xFFD97706)),
                      icon: _isSending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.send_rounded, color: Colors.white),
                      onPressed: _isSending ? null : () => _sendMessage(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
