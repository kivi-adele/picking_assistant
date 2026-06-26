import 'package:shared_preferences/shared_preferences.dart';

/// 应用设置：服务器地址和 API Token，持久化到 SharedPreferences。
class AppSettings {
  static const _keyServerUrl = 'server_url';
  static const _keyApiToken  = 'api_token';

  static const defaultServerUrl = 'http://192.168.2.178:8080';
  static const defaultApiToken  = 'anxin-pick-2026';

  static late SharedPreferences _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static String get serverUrl => _prefs.getString(_keyServerUrl) ?? defaultServerUrl;
  static String get apiToken  => _prefs.getString(_keyApiToken)  ?? defaultApiToken;

  static Future<void> save({required String serverUrl, required String apiToken}) async {
    await _prefs.setString(_keyServerUrl, serverUrl.trim());
    await _prefs.setString(_keyApiToken,  apiToken.trim());
  }
}
