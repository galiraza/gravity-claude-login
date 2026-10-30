import 'package:flutter/material.dart';
import 'screens/connected_screen.dart';
import 'screens/login_screen.dart';
import 'services/claude_oauth_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final oauthService = ClaudeOAuthService();
  await oauthService.initialize();

  runApp(GravityClaudeApp(oauthService: oauthService));
}

class GravityClaudeApp extends StatefulWidget {
  final ClaudeOAuthService oauthService;

  const GravityClaudeApp({super.key, required this.oauthService});

  @override
  State<GravityClaudeApp> createState() => _GravityClaudeAppState();
}

class _GravityClaudeAppState extends State<GravityClaudeApp> {
  late bool _isConnected;

  @override
  void initState() {
    super.initState();
    _isConnected = widget.oauthService.isConnected;
  }

  void _refreshAuthState() {
    setState(() {
      _isConnected = widget.oauthService.isConnected;
    });
  }

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFFD97706); // Warm Claude Amber / Terracotta
    final colorSchemeLight = ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: Brightness.light,
    );
    final colorSchemeDark = ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'Claude Gravity Login',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorSchemeLight,
        scaffoldBackgroundColor: const Color(0xFFFBFBFB),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            color: Color(0xFF1E1E1E),
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(color: Color(0xFF1E1E1E)),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: colorSchemeDark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(color: Colors.white),
        ),
      ),
      themeMode: ThemeMode.system,
      home: _isConnected
          ? ConnectedScreen(
              oauthService: widget.oauthService,
              onLogout: _refreshAuthState,
            )
          : LoginScreen(
              oauthService: widget.oauthService,
              onLoginSuccess: _refreshAuthState,
            ),
    );
  }
}
