import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:http/http.dart' as http;
import 'settings.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.init();
  runApp(const MyApp());
}

@pragma('vm:entry-point')
void overlayMain() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(color: Colors.transparent, child: OverlayBall()),
    ),
  );
}

class OverlayBall extends StatefulWidget {
  const OverlayBall({super.key});

  @override
  State<OverlayBall> createState() => _OverlayBallState();
}

/// 悬浮球的四种状态：待机（蓝色）、准备中（橙色，正在扫单号/扫设备验证）、
/// 录像中（红色，已确认开始录制）、二次确认（放大显示确认卡片）
enum _BallMode { idle, preparing, recording, confirming }

class _OverlayBallState extends State<OverlayBall> {
  // 悬浮球和主 App 运行在两个独立的 Flutter engine/isolate 里，
  // FlutterOverlayWindow.shareData/overlayListener 在跨 engine 时并不可靠，
  // 官方示例推荐用 dart:isolate 的 IsolateNameServer 做端口通信。
  static const String _portNameUI = 'UI';
  SendPort? _uiPort;

  // 球本身的尺寸，以及二次确认卡片的尺寸（点击球后临时放大悬浮窗显示确认提示）
  static const int _ballSize = 100;
  static const int _confirmWidth = 260;
  static const int _confirmHeight = 160;

  _BallMode _mode = _BallMode.idle;

  // 接收主 App 发来的"录像已开始/已结束"通知，用于切换 准备中(橙)/录像中(红)/待机(蓝)
  static const String _portNameOverlay = 'OverlayBall';
  final ReceivePort _overlayReceivePort = ReceivePort();

  @override
  void initState() {
    super.initState();
    IsolateNameServer.removePortNameMapping(_portNameOverlay);
    IsolateNameServer.registerPortWithName(
      _overlayReceivePort.sendPort,
      _portNameOverlay,
    );
    _overlayReceivePort.listen((message) {
      if (message is! Map) return;
      final data = Map<String, dynamic>.from(message);
      switch (data['type']) {
        case 'recording_started':
          setState(() => _mode = _BallMode.recording);
          break;
        case 'recording_stopped':
          if (_mode == _BallMode.confirming) {
            FlutterOverlayWindow.resizeOverlay(_ballSize, _ballSize, true);
          }
          setState(() => _mode = _BallMode.idle);
          break;
      }
    });
  }

  @override
  void dispose() {
    _overlayReceivePort.close();
    IsolateNameServer.removePortNameMapping(_portNameOverlay);
    super.dispose();
  }

  /// 点击悬浮球：
  /// - idle（待机）：切到准备中状态，并通知主 App 开始拣货流程（扫单号/扫设备）
  /// - preparing（准备中）：扫码验证阶段，球本身不可点
  /// - recording（录像中）：不直接停止，而是放大悬浮窗显示二次确认卡片，防止误触
  /// - confirming（确认中）：球本身不可点，由下方"是/否"按钮处理
  Future<void> _onBallTap() async {
    _uiPort ??= IsolateNameServer.lookupPortByName(_portNameUI);
    switch (_mode) {
      case _BallMode.idle:
        // 把状态广播给主 App，用 Map 而不是裸 bool，方便以后扩展条码内容、错误提示等字段
        setState(() => _mode = _BallMode.preparing);
        _uiPort?.send({'type': 'status', 'isActive': true});
        break;
      case _BallMode.preparing:
        break;
      case _BallMode.recording:
        setState(() => _mode = _BallMode.confirming);
        await FlutterOverlayWindow.resizeOverlay(
          _confirmWidth,
          _confirmHeight,
          false,
        );
        break;
      case _BallMode.confirming:
        break;
    }
  }

  /// 确认结束录制：通知主 App 发送停止录像信号，悬浮窗缩回原来的球
  Future<void> _confirmStop() async {
    _uiPort?.send({'type': 'stop_recording'});
    setState(() => _mode = _BallMode.idle);
    await FlutterOverlayWindow.resizeOverlay(_ballSize, _ballSize, true);
  }

  /// 取消：悬浮窗缩回球，继续录像，不发任何信号
  Future<void> _cancelStop() async {
    setState(() => _mode = _BallMode.recording);
    await FlutterOverlayWindow.resizeOverlay(_ballSize, _ballSize, true);
  }

  @override
  Widget build(BuildContext context) {
    if (_mode == _BallMode.confirming) {
      return _buildConfirmCard();
    }

    final (Color color, IconData icon) = switch (_mode) {
      _BallMode.idle => (Colors.blue, Icons.touch_app),
      _BallMode.preparing => (Colors.orange, Icons.hourglass_top),
      _BallMode.recording || _BallMode.confirming => (
        Colors.red,
        Icons.fiber_manual_record,
      ),
    };

    return Center(
      child: GestureDetector(
        onTap: _onBallTap,
        child: CircleAvatar(
          radius: 30,
          backgroundColor: color,
          child: Icon(icon, color: Colors.white),
        ),
      ),
    );
  }

  /// 二次确认卡片：放大后的悬浮窗里显示"是否确认结束录制？" + 是/否按钮
  Widget _buildConfirmCard() {
    return Center(
      child: Container(
        width: _confirmWidth.toDouble(),
        height: _confirmHeight.toDouble(),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 8, spreadRadius: 1),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              '是否确认结束录制？',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: _confirmStop,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('是'),
                ),
                ElevatedButton(
                  onPressed: _cancelStop,
                  child: const Text('否'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // 主 App 用固定名字注册一个端口，悬浮球那边通过 IsolateNameServer.lookupPortByName
  // 找到这个端口并 send() 过来；这是跨 engine 通信官方推荐且可靠的方式
  // （FlutterOverlayWindow.shareData/overlayListener 跨 engine 时经常收不到消息）。
  static const String _portNameUI = 'UI';
  final ReceivePort _receivePort = ReceivePort();

  bool _isPicking = false;

  // 全局 Key 用于访问 ScanFlowPageState
  final GlobalKey<_ScanFlowPageState> _scanFlowPageKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 热重启时旧的端口映射可能还在，先移除避免注册失败
    IsolateNameServer.removePortNameMapping(_portNameUI);
    IsolateNameServer.registerPortWithName(_receivePort.sendPort, _portNameUI);

    // 监听悬浮球广播过来的状态，决定是否开始/停止监听扫码枪
    _receivePort.listen((message) {
      if (message is! Map) return;
      final data = Map<String, dynamic>.from(message);
      switch (data['type']) {
        case 'status':
          final isActive = data['isActive'] == true;
          setState(() {
            _isPicking = isActive;
          });
          if (isActive) {
            _startScannerListening();
          } else {
            _stopScannerListening();
          }
          break;
        case 'stop_recording':
          // 悬浮球发来的停止录像信号
          _scanFlowPageKey.currentState?._handleStopSignalFromOverlay();
          break;
        // TODO: 后续可以在这里处理 'barcode'（扫码内容）、'error'（错误提示）等类型
      }
    });
  }

  @override
  void dispose() {
    _receivePort.close();
    IsolateNameServer.removePortNameMapping(_portNameUI);
    super.dispose();
  }

  void _startScannerListening() {
    // TODO: 在这里接入扫码枪数据源（例如键盘事件 / USB HID 监听）
    debugPrint('开始监听扫码枪数据');
  }

  void _stopScannerListening() {
    // TODO: 停止监听扫码枪数据源，释放相关资源
    debugPrint('停止监听扫码枪数据');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text("拣货助手"),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: '服务器设置',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              ),
            ),
          ],
        ),
        body: _isPicking
            ? ScanFlowPage(key: _scanFlowPageKey)
            : Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("状态：待机"),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () async {
                        bool status =
                            await FlutterOverlayWindow.isPermissionGranted();
                        if (!status) {
                          await FlutterOverlayWindow.requestPermission();
                          return;
                        }
                        await FlutterOverlayWindow.showOverlay(
                          enableDrag: true,
                          overlayContent:
                              'overlayMain', // 必须对应下面 overlay_entry 的名字
                          // 不传 height/width 时默认是 matchParent（全屏），
                          // 整个透明区域都会拦截触摸事件，导致“看不见的大触摸区域”。
                          // 显式给一个只比悬浮球（直径 60）略大的尺寸，
                          // 让原生 overlay 窗口本身就只有这么大，触摸区域自然收紧到球上。
                          height: 100,
                          width: 100,
                        );
                      },
                      child: const Text("点击开启悬浮球"),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// 拣货扫码流程的三个阶段：先扫订单，校验通过后再扫设备，最后进入录像状态
enum ScanStage { scanOrder, scanDevice, recording }

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _urlController;
  late TextEditingController _tokenController;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: AppSettings.serverUrl);
    _tokenController = TextEditingController(text: AppSettings.apiToken);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();
    if (url.isEmpty || token.isEmpty) return;
    await AppSettings.save(serverUrl: url, apiToken: token);
    if (!mounted) return;
    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('服务器设置')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('服务器地址'),
            const SizedBox(height: 8),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                hintText: 'http://192.168.2.178:8080',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 24),
            const Text('API Token'),
            const SizedBox(height: 8),
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(
                hintText: 'anxin-pick-2026',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _save,
              child: const Text('保存'),
            ),
            if (_saved) ...[
              const SizedBox(height: 16),
              const Text(
                '✓ 已保存',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ScanFlowPage extends StatefulWidget {
  const ScanFlowPage({Key? key}) : super(key: key);

  @override
  State<ScanFlowPage> createState() => _ScanFlowPageState();
}

class _ScanFlowPageState extends State<ScanFlowPage> with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  ScanStage _stage = ScanStage.scanOrder;
  String? _orderId;
  String? _deviceId;
  bool _isSubmitting = false;
  String? _feedback;
  bool _feedbackIsError = false;
  
  // 录像相关变量
  Timer? _recordingTimer;
  Timer? _autoStopTimer;
  int _recordingSeconds = 0;
  DateTime? _recordingStartTime;
  static const int _maxRecordingSeconds = 4 * 60 * 60; // 4小时

  // 防止"结束录像"被重复触发（例如悬浮球确认 + 应用内按钮几乎同时点击），
  // 导致重复发送停止信号
  bool _isStopping = false;

  // 悬浮球所在的独立 engine 通过这个端口名注册接收端，主 App 在录像
  // 真正开始/结束时通过它通知悬浮球切换 准备中(橙)/录像中(红)/待机(蓝)
  static const String _portNameOverlay = 'OverlayBall';
  SendPort? _overlayPort;

  /// 通知悬浮球切换显示状态
  void _notifyOverlay(Map<String, dynamic> message) {
    _overlayPort ??= IsolateNameServer.lookupPortByName(_portNameOverlay);
    _overlayPort?.send(message);
  }
  
  // 生命周期管理：防止后台 ANR
  AppLifecycleState _lastLifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    // 注册生命周期观察
    WidgetsBinding.instance.addObserver(this);
    _requestFocus();
  }

  @override
  void dispose() {
    // 注销生命周期观察
    WidgetsBinding.instance.removeObserver(this);
    _recordingTimer?.cancel();
    _autoStopTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lastLifecycleState = state;
    if (_stage != ScanStage.recording) return;

    if (state == AppLifecycleState.resumed) {
      // 回到前台：按真实流逝时间校正已录像时长，并恢复每秒刷新
      _resumeRecordingTimer();
    } else {
      // 进入后台：界面不可见，停止每秒 setState，避免无意义刷新
      _recordingTimer?.cancel();
      _recordingTimer = null;
    }
  }

  /// 扫码枪本质是"键盘 + 回车"，所以始终把焦点保持在 TextField 上，
  /// 这样扫码内容会自动输入并触发 onSubmitted，不需要手动弹软键盘或拦截系统按键。
  void _requestFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  Future<void> _handleSubmitted(String rawValue) async {
    final code = rawValue.trim();
    // 防重复提交：正在请求中或者输入为空都直接忽略
    if (_isSubmitting || code.isEmpty) {
      _controller.clear();
      _requestFocus();
      return;
    }

    setState(() {
      _isSubmitting = true;
      _feedback = null;
    });

    try {
      if (_stage == ScanStage.scanOrder) {
        await _handleOrderScanned(code);
      } else {
        await _handleDeviceScanned(code);
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
        _controller.clear();
        _requestFocus();
      }
    }
  }

  Future<void> _handleOrderScanned(String orderId) async {
    final ok = await _validateOrder(orderId);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _orderId = orderId;
        _stage = ScanStage.scanDevice;
        _feedback = '订单 $orderId 校验通过，请扫描设备条码';
        _feedbackIsError = false;
      });
    } else {
      setState(() {
        _feedback = '订单 $orderId 校验失败，请重新扫描';
        _feedbackIsError = true;
      });
    }
  }

  Future<void> _handleDeviceScanned(String deviceId) async {
    final orderId = _orderId;
    if (orderId == null) {
      // 状态机异常兜底：没有订单号就不应该停留在 scanDevice 阶段
      setState(() {
        _stage = ScanStage.scanOrder;
        _feedback = '未检测到订单号，请重新扫描订单';
        _feedbackIsError = true;
      });
      return;
    }

    final ok = await _submitPicking(orderId: orderId, deviceId: deviceId);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _deviceId = deviceId;
        _stage = ScanStage.recording;
        _recordingSeconds = 0;
        _feedback = '录像已开始';
        _feedbackIsError = false;
      });
      // 启动计时器
      _startRecordingTimer();
      // 真正开始录制：震动提示 + 通知悬浮球切换为录像中(红)
      HapticFeedback.mediumImpact();
      _notifyOverlay({'type': 'recording_started'});
    } else {
      setState(() {
        _feedback = '设备 $deviceId 提交失败，请重新扫描';
        _feedbackIsError = true;
      });
    }
  }

  /// 启动录像计时器和自动停止定时器（录像开始时调用一次）
  void _startRecordingTimer() {
    _recordingStartTime = DateTime.now();
    _startTickingTimer();

    // 设置4小时后自动停止：基于墙钟时间，与前台 UI 计时器无关，
    // 即使应用在后台被冻结，恢复前台后也能按真实时长触发
    _autoStopTimer?.cancel();
    _autoStopTimer = Timer(const Duration(hours: 4), () {
      if (mounted && _stage == ScanStage.recording) {
        _stopRecordingAuto();
      }
    });
  }

  /// 启动每秒刷新 UI 的计时器：仅在前台可见时运行，
  /// 时长始终按 _recordingStartTime 与当前时间的差值计算，避免漏 tick 导致偏差
  void _startTickingTimer() {
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final start = _recordingStartTime;
      if (start == null) return;
      final elapsed = DateTime.now().difference(start).inSeconds;
      if (elapsed >= _maxRecordingSeconds) {
        _stopRecordingAuto();
        return;
      }
      setState(() {
        _recordingSeconds = elapsed;
      });
    });
  }

  /// 从后台恢复到前台时：按真实流逝时间校正显示并恢复每秒刷新；
  /// 若后台期间已超过4小时上限，直接触发自动停止
  void _resumeRecordingTimer() {
    final start = _recordingStartTime;
    if (start == null) return;
    final elapsed = DateTime.now().difference(start).inSeconds;
    if (elapsed >= _maxRecordingSeconds) {
      _stopRecordingAuto();
      return;
    }
    setState(() {
      _recordingSeconds = elapsed;
    });
    _startTickingTimer();
  }

  /// 停止录像计时器
  void _stopRecordingTimer() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
    _recordingStartTime = null;
  }

  /// 结束录像：发送停止信号到后端
  Future<void> _stopRecording() async {
    await _performStop('录像已结束，请扫描下一个订单');
  }

  /// 自动停止录像（4小时到期）
  Future<void> _stopRecordingAuto() async {
    await _performStop('录像时间已达上限（4小时），已自动结束，请扫描下一个订单');
  }

  /// 实际执行停止录像的逻辑，带防重入保护：
  /// 应用内"结束录像"按钮、悬浮球二次确认、4小时自动停止都会调用到这里，
  /// 加上 _isStopping 避免短时间内重复触发导致重复发送停止信号。
  Future<void> _performStop(String feedbackMessage) async {
    if (_isStopping) return;
    _isStopping = true;
    try {
      _stopRecordingTimer();
      await _sendStopSignal();
      // 录像结束：震动提示 + 通知悬浮球切换回待机(蓝)
      HapticFeedback.mediumImpact();
      _notifyOverlay({'type': 'recording_stopped'});
      if (mounted) {
        setState(() {
          _stage = ScanStage.scanOrder;
          _orderId = null;
          _deviceId = null;
          _recordingSeconds = 0;
          _feedback = feedbackMessage;
          _feedbackIsError = false;
        });
      }
    } finally {
      _isStopping = false;
    }
  }

  /// 发送停止录像信号到后端
  Future<void> _sendStopSignal() async {
    try {
      final response = await http.post(
        Uri.parse('${AppSettings.serverUrl}/api/v1/record/stop'),
        headers: {
          'Content-Type': 'application/json',
          'X-API-Token': AppSettings.apiToken,
        },
        body: jsonEncode({'order_id': _orderId, 'camera_id': _deviceId}),
      );
      debugPrint('停止录像信号已发送，状态码: ${response.statusCode}');
    } catch (e) {
      debugPrint('发送停止录像信号失败: $e');
    }
  }

  /// 处理来自悬浮球的停止信号
  void _handleStopSignalFromOverlay() {
    if (_stage == ScanStage.recording) {
      _stopRecording();
    }
  }

  /// TODO: 替换成真实的订单校验接口
  Future<bool> _validateOrder(String orderId) async {
    await Future.delayed(const Duration(milliseconds: 500));
    return orderId.isNotEmpty;
  }

  /// 提交拣货数据到服务器
  Future<bool> _submitPicking({
    required String orderId,
    required String deviceId,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('${AppSettings.serverUrl}/api/v1/record/scan'),
        headers: {
          'Content-Type': 'application/json',
          'X-API-Token': AppSettings.apiToken,
        },
        body: jsonEncode({'order_id': orderId, 'camera_id': deviceId}),
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('提交拣货数据失败: $e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_stage == ScanStage.recording) {
      return _buildRecordingPage();
    }

    final isScanOrder = _stage == ScanStage.scanOrder;
    final hint = isScanOrder ? '请扫描订单条码' : '请扫描设备条码';
    final stepLabel = isScanOrder ? '步骤 1/2：扫描订单' : '步骤 2/2：扫描设备';

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) {
          // 最小化应用到后台
          SystemNavigator.pop();
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(stepLabel, style: Theme.of(context).textTheme.titleMedium),
            if (!isScanOrder && _orderId != null) ...[
              const SizedBox(height: 4),
              Text(
                '当前订单：$_orderId',
                style: const TextStyle(color: Colors.grey),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              enabled: !_isSubmitting,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                hintText: hint,
                border: const OutlineInputBorder(),
                suffixIcon: _isSubmitting
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : null,
              ),
              // 提交期间禁用输入，避免扫码枪连续触发造成重复提交
              onSubmitted: _isSubmitting ? null : _handleSubmitted,
              // 防止焦点被意外移走（例如误触屏幕其他位置）
              onTapOutside: (_) => _requestFocus(),
            ),
            const SizedBox(height: 16),
            if (_feedback != null)
              Text(
                _feedback!,
                style: TextStyle(
                  color: _feedbackIsError ? Colors.red : Colors.green,
                  fontWeight: FontWeight.bold,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 构建录像界面
  Widget _buildRecordingPage() {
    // 格式化录像时长
    final minutes = _recordingSeconds ~/ 60;
    final seconds = _recordingSeconds % 60;
    final timeDisplay =
        '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

    // 计算剩余时间
    final remainingSeconds = _maxRecordingSeconds - _recordingSeconds;
    final remainingHours = remainingSeconds ~/ 3600;
    final remainingMinutes = (remainingSeconds % 3600) ~/ 60;
    final remainingSecs = remainingSeconds % 60;
    final remainingDisplay =
        '${remainingHours.toString().padLeft(2, '0')}:${remainingMinutes.toString().padLeft(2, '0')}:${remainingSecs.toString().padLeft(2, '0')}';

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) {
          // 最小化应用到后台
          SystemNavigator.pop();
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '正在录像',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(color: Colors.red),
            ),
            const SizedBox(height: 8),
            if (_orderId != null)
              Text('订单号：$_orderId', style: const TextStyle(color: Colors.grey)),
            if (_deviceId != null)
              Text(
                '设备号：$_deviceId',
                style: const TextStyle(color: Colors.grey),
              ),
            const SizedBox(height: 24),
            // 显示已录像时长
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.red, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  Text('已录像时长', style: Theme.of(context).textTheme.labelMedium),
                  const SizedBox(height: 8),
                  Text(
                    timeDisplay,
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // 显示剩余时间（倒计时）
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.orange, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  Text(
                    '剩余时间（自动停止）',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    remainingDisplay,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.orange,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // 结束录像按钮
            ElevatedButton.icon(
              onPressed: _stopRecording,
              icon: const Icon(Icons.stop_circle),
              label: const Text('结束录像'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
            const SizedBox(height: 16),
            if (_feedback != null)
              Text(
                _feedback!,
                style: TextStyle(
                  color: _feedbackIsError ? Colors.red : Colors.green,
                  fontWeight: FontWeight.bold,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
