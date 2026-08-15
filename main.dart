// =============================================================================
// TARCZOCIĄG BT – Aplikacja Flutter do sterowania bezprzewodowym
// tarczociągiem strzeleckim przez Bluetooth Classic (SPP / RFCOMM)
// =============================================================================
//
// WYMAGANE ZALEŻNOŚCI (dodaj do pubspec.yaml):
//
//   dependencies:
//     flutter:
//       sdk: flutter
//     flutter_bluetooth_serial: ^0.4.0
//     shared_preferences: ^2.2.2
//
// WYMAGANE UPRAWNIENIA (android/app/src/main/AndroidManifest.xml),
// wewnątrz <manifest ...> a przed <application ...>:
//
//   <uses-permission android:name="android.permission.BLUETOOTH" />
//   <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
//   <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
//   <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
//   <uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
//
// Minimalny minSdkVersion: 21 (android/app/build.gradle).
//
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TarczociagApp());
}

// =============================================================================
// MOTYW / KOLORY
// =============================================================================

class AppColors {
  static const background = Color(0xFF121212);
  static const surface = Color(0xFF1C1C1E);
  static const surfaceLight = Color(0xFF262629);
  static const card = Color(0xFF1E1E1E);
  static const accentBlue = Color(0xFF2196F3);
  static const accentGreen = Color(0xFF43D17A);
  static const accentOrange = Color(0xFFFF9800);
  static const accentRed = Color(0xFFFF5252);
  static const textPrimary = Color(0xFFF2F2F2);
  static const textSecondary = Color(0xFF9A9A9E);
  static const divider = Color(0xFF2E2E31);
}

class TarczociagApp extends StatelessWidget {
  const TarczociagApp({super.key});

  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tarczociąg BT',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messengerKey,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accentBlue,
          secondary: AppColors.accentGreen,
          surface: AppColors.surface,
          error: AppColors.accentRed,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.surface,
          elevation: 0,
          centerTitle: false,
          foregroundColor: AppColors.textPrimary,
          iconTheme: IconThemeData(color: AppColors.textPrimary),
        ),
        cardTheme: CardThemeData(
          color: AppColors.card,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: AppColors.divider),
          ),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: AppColors.textPrimary),
          bodyMedium: TextStyle(color: AppColors.textPrimary),
          titleLarge: TextStyle(
              color: AppColors.textPrimary, fontWeight: FontWeight.w600),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.surfaceLight,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accentBlue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        dividerColor: AppColors.divider,
      ),
      home: const RootShell(),
    );
  }
}

// =============================================================================
// WARSTWA BLUETOOTH
// =============================================================================

enum BtConnectionState { disconnected, connecting, connected }

/// Zarządza połączeniem SPP/RFCOMM: łączenie, rozłączanie, wysyłanie ramek
/// oraz bezpieczne parsowanie przychodzącego strumienia bajtów na linie
/// tekstowe zakończone znakiem '\n'.
class BluetoothManager extends ChangeNotifier {
  BluetoothConnection? _connection;
  BtConnectionState state = BtConnectionState.disconnected;
  BluetoothDevice? currentDevice;

  String _rxBuffer = '';
  final StreamController<String> _lineController =
      StreamController<String>.broadcast();

  /// Strumień pojedynczych, kompletnych linii odebranych po Bluetooth.
  Stream<String> get lines => _lineController.stream;

  Future<List<BluetoothDevice>> getBondedDevices() async {
    try {
      return await FlutterBluetoothSerial.instance.getBondedDevices();
    } catch (_) {
      return <BluetoothDevice>[];
    }
  }

  Future<bool> ensureBluetoothEnabled() async {
    try {
      bool? enabled = await FlutterBluetoothSerial.instance.isEnabled;
      if (enabled != true) {
        await FlutterBluetoothSerial.instance.requestEnable();
        enabled = await FlutterBluetoothSerial.instance.isEnabled;
      }
      return enabled ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> connect(BluetoothDevice device) async {
    if (state == BtConnectionState.connecting) return false;
    state = BtConnectionState.connecting;
    notifyListeners();

    try {
      final conn = await BluetoothConnection.toAddress(device.address);
      _connection = conn;
      currentDevice = device;
      state = BtConnectionState.connected;
      notifyListeners();

      conn.input!.listen(
        _onDataReceived,
        onDone: _handleRemoteDisconnect,
        onError: (_) => _handleRemoteDisconnect(),
        cancelOnError: true,
      );
      return true;
    } catch (_) {
      _connection = null;
      currentDevice = null;
      state = BtConnectionState.disconnected;
      notifyListeners();
      return false;
    }
  }

  void _onDataReceived(Uint8List data) {
    _rxBuffer += utf8.decode(data, allowMalformed: true);
    int idx;
    while ((idx = _rxBuffer.indexOf('\n')) != -1) {
      final rawLine = _rxBuffer.substring(0, idx);
      _rxBuffer = _rxBuffer.substring(idx + 1);
      final line = rawLine.replaceAll('\r', '').trim();
      if (line.isNotEmpty) {
        _lineController.add(line);
      }
    }
  }

  void _handleRemoteDisconnect() {
    _connection = null;
    currentDevice = null;
    state = BtConnectionState.disconnected;
    notifyListeners();
  }

  Future<void> disconnect() async {
    try {
      await _connection?.finish();
    } catch (_) {}
    try {
      _connection?.close();
    } catch (_) {}
    _connection = null;
    currentDevice = null;
    state = BtConnectionState.disconnected;
    notifyListeners();
  }

  /// Wysyła ramkę tekstową. Dopisuje '\n' jeśli go brakuje.
  bool send(String frame) {
    final conn = _connection;
    if (conn == null || !conn.isConnected) return false;
    try {
      final payload = frame.endsWith('\n') ? frame : '$frame\n';
      conn.output.add(Uint8List.fromList(utf8.encode(payload)));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _lineController.close();
    try {
      _connection?.dispose();
    } catch (_) {}
    super.dispose();
  }
}

// =============================================================================
// FORMATOWANIE LICZB DO RAMEK
// =============================================================================

String fmtNum(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(1);
}

// =============================================================================
// ROOT SHELL – trzyma stan aplikacji, PageView, BT, SharedPreferences
// =============================================================================

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final BluetoothManager _bt = BluetoothManager();
  final PageController _pageController = PageController();

  int _currentPage = 0;
  double? _position; // aktualna pozycja tarczy [m]
  String _lastStatusLine = '';

  Map<String, double> distances = {
    'd10': 10,
    'd25': 25,
    'd33': 33,
    'd50': 50,
  };

  int maxSpeed = 200; // PWM 50-255
  int ramp = 50; // impulsy rampy

  SharedPreferences? _prefs;
  StreamSubscription<String>? _linesSub;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _bt.addListener(_onBtChanged);
    _linesSub = _bt.lines.listen(_handleIncomingLine);
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _prefs = p;
      distances = {
        'd10': p.getDouble('d10') ?? 10,
        'd25': p.getDouble('d25') ?? 25,
        'd33': p.getDouble('d33') ?? 33,
        'd50': p.getDouble('d50') ?? 50,
      };
      maxSpeed = p.getInt('maxSpeed') ?? 200;
      ramp = p.getInt('ramp') ?? 50;
      _position = p.getDouble('lastPosition');
    });
  }

  Future<void> _persistDistancesAndMotor() async {
    final p = _prefs;
    if (p == null) return;
    await p.setDouble('d10', distances['d10']!);
    await p.setDouble('d25', distances['d25']!);
    await p.setDouble('d33', distances['d33']!);
    await p.setDouble('d50', distances['d50']!);
    await p.setInt('maxSpeed', maxSpeed);
    await p.setInt('ramp', ramp);
  }

  void _onBtChanged() {
    if (mounted) setState(() {});
  }

  void _handleIncomingLine(String line) {
    if (line.startsWith('POS:')) {
      final raw = line.substring(4).trim().replaceAll(',', '.');
      final value = double.tryParse(raw);
      if (value != null) {
        setState(() => _position = value);
        _prefs?.setDouble('lastPosition', value);
      }
    } else if (line.startsWith('STATUS:')) {
      final status = line.substring(7);
      setState(() => _lastStatusLine = status);
      _notify(_describeStatus(status));
    } else if (line.startsWith('CFG:')) {
      setState(() => _lastStatusLine = line);
      _notify('Konfiguracja potwierdzona: ${line.substring(4)}');
    }
  }

  String _describeStatus(String status) {
    if (status == 'HOME_OK') return 'Powrót do bazy zakończony';
    if (status.startsWith('ARRIVED:')) {
      return 'Dojazd do pozycji ${status.substring(8)} m';
    }
    return 'Status: $status';
  }

  void _notify(String message) {
    TarczociagApp.messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.surfaceLight,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _openConnectSheet() async {
    final enabled = await _bt.ensureBluetoothEnabled();
    if (!enabled) {
      _notify('Włącz Bluetooth w telefonie, aby kontynuować');
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DeviceListSheet(bt: _bt, onNotify: _notify),
    );
  }

  Future<void> _openSettings() async {
    final result = await Navigator.of(context).push<SettingsResult>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          initialDistances: distances,
          initialMaxSpeed: maxSpeed,
          initialRamp: ramp,
        ),
      ),
    );
    if (result == null) return;

    setState(() {
      distances = result.distances;
      maxSpeed = result.maxSpeed;
      ramp = result.ramp;
    });
    await _persistDistancesAndMotor();

    final distFrame = 'SET_DIST:'
        '${fmtNum(distances['d10']!)},'
        '${fmtNum(distances['d25']!)},'
        '${fmtNum(distances['d33']!)},'
        '${fmtNum(distances['d50']!)}';
    final motorFrame = 'SET_MOTOR:$maxSpeed,$ramp';

    final okDist = _bt.send(distFrame);
    final okMotor = _bt.send(motorFrame);
    if (okDist && okMotor) {
      _notify('Ustawienia wysłane do urządzenia');
    } else {
      _notify('Ustawienia zapisane lokalnie (brak połączenia BT)');
    }
  }

  void _sendPreset(String key) {
    final value = distances[key]!;
    final ok = _bt.send('JEDZ:${fmtNum(value)}');
    if (!ok) _notify('Brak połączenia z tarczociągiem');
  }

  void _sendHome() {
    final ok = _bt.send('HOME');
    if (!ok) _notify('Brak połączenia z tarczociągiem');
  }

  @override
  void dispose() {
    _linesSub?.cancel();
    _bt.removeListener(_onBtChanged);
    _bt.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentPage == 0 ? 'Puszka wykonawcza' : 'Pulpit CYD'),
        actions: [
          if (_currentPage == 0) ...[
            _ConnectionStatusChip(state: _bt.state, device: _bt.currentDevice),
            const SizedBox(width: 8),
            _ConnectButton(
              state: _bt.state,
              onConnect: _openConnectSheet,
              onDisconnect: _bt.disconnect,
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Ustawienia',
              onPressed: _openSettings,
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (i) => setState(() => _currentPage = i),
              children: [
                MainControlScreen(
                  position: _position,
                  distances: distances,
                  lastStatus: _lastStatusLine,
                  onPreset: _sendPreset,
                  onHome: _sendHome,
                ),
                const CydPlaceholderScreen(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(2, (i) {
                final active = i == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: active ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active
                        ? AppColors.accentBlue
                        : AppColors.surfaceLight,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// WIDGETY STATUSU POŁĄCZENIA (AppBar)
// =============================================================================

class _ConnectionStatusChip extends StatelessWidget {
  final BtConnectionState state;
  final BluetoothDevice? device;
  const _ConnectionStatusChip({required this.state, required this.device});

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    switch (state) {
      case BtConnectionState.connected:
        color = AppColors.accentGreen;
        label = 'Połączono';
        break;
      case BtConnectionState.connecting:
        color = AppColors.accentOrange;
        label = 'Łączenie…';
        break;
      case BtConnectionState.disconnected:
        color = AppColors.accentRed;
        label = 'Rozłączono';
        break;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _ConnectButton extends StatelessWidget {
  final BtConnectionState state;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  const _ConnectButton({
    required this.state,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final connected = state == BtConnectionState.connected;
    final connecting = state == BtConnectionState.connecting;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: TextButton.icon(
        onPressed: connecting ? null : (connected ? onDisconnect : onConnect),
        icon: Icon(
          connected ? Icons.bluetooth_connected : Icons.bluetooth,
          size: 18,
          color: connected ? AppColors.accentGreen : AppColors.accentBlue,
        ),
        label: Text(
          connected ? 'Rozłącz' : 'Połącz',
          style: TextStyle(
            color: connected ? AppColors.accentGreen : AppColors.accentBlue,
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// DIALOG WYBORU URZĄDZENIA (sparowane urządzenia BT)
// =============================================================================

class DeviceListSheet extends StatefulWidget {
  final BluetoothManager bt;
  final void Function(String) onNotify;
  const DeviceListSheet({super.key, required this.bt, required this.onNotify});

  @override
  State<DeviceListSheet> createState() => _DeviceListSheetState();
}

class _DeviceListSheetState extends State<DeviceListSheet> {
  List<BluetoothDevice> _devices = [];
  bool _loading = true;
  String? _connectingAddress;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final devices = await widget.bt.getBondedDevices();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _loading = false;
    });
  }

  Future<void> _connectTo(BluetoothDevice device) async {
    setState(() => _connectingAddress = device.address);
    final ok = await widget.bt.connect(device);
    if (!mounted) return;
    setState(() => _connectingAddress = null);
    if (ok) {
      widget.onNotify('Połączono z ${device.name ?? device.address}');
      Navigator.of(context).pop();
    } else {
      widget.onNotify('Nie udało się połączyć z ${device.name ?? device.address}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Sparowane urządzenia',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, color: AppColors.textSecondary),
                  onPressed: _loading ? null : _refresh,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_devices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Text(
                  'Brak sparowanych urządzeń. Sparuj tarczociąg w ustawieniach '
                  'Bluetooth systemu Android, a następnie odśwież listę.',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _devices.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: AppColors.divider),
                  itemBuilder: (context, i) {
                    final d = _devices[i];
                    final isConnecting = _connectingAddress == d.address;
                    return ListTile(
                      leading: const Icon(Icons.bluetooth, color: AppColors.accentBlue),
                      title: Text(d.name ?? 'Nieznane urządzenie'),
                      subtitle: Text(
                        d.address,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      trailing: isConnecting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_right,
                              color: AppColors.textSecondary),
                      onTap: isConnecting ? null : () => _connectTo(d),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// EKRAN 1 – PUSZKA WYKONAWCZA
// =============================================================================

class MainControlScreen extends StatelessWidget {
  final double? position;
  final Map<String, double> distances;
  final String lastStatus;
  final void Function(String presetKey) onPreset;
  final VoidCallback onHome;

  const MainControlScreen({
    super.key,
    required this.position,
    required this.distances,
    required this.lastStatus,
    required this.onPreset,
    required this.onHome,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          children: [
            _PositionDisplay(position: position, lastStatus: lastStatus),
            const SizedBox(height: 24),
            Text(
              'PRESETY DYSTANSÓW',
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 1.2,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 1.35,
              children: [
                PresetTile(
                  label: '${fmtNum(distances['d10']!)} m',
                  sublabel: 'Preset 1',
                  color: AppColors.accentBlue,
                  onTap: () => onPreset('d10'),
                ),
                PresetTile(
                  label: '${fmtNum(distances['d25']!)} m',
                  sublabel: 'Preset 2',
                  color: AppColors.accentGreen,
                  onTap: () => onPreset('d25'),
                ),
                PresetTile(
                  label: '${fmtNum(distances['d33']!)} m',
                  sublabel: 'Preset 3',
                  color: AppColors.accentOrange,
                  onTap: () => onPreset('d33'),
                ),
                PresetTile(
                  label: '${fmtNum(distances['d50']!)} m',
                  sublabel: 'Preset 4',
                  color: AppColors.accentBlue,
                  onTap: () => onPreset('d50'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 64,
              child: ElevatedButton.icon(
                onPressed: onHome,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentRed,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.home_filled, size: 26),
                label: const Text(
                  'POWRÓT (HOME)',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PositionDisplay extends StatelessWidget {
  final double? position;
  final String lastStatus;
  const _PositionDisplay({required this.position, required this.lastStatus});

  @override
  Widget build(BuildContext context) {
    final text = position != null ? '${position!.toStringAsFixed(1)}' : '--.-';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 30),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          const Text(
            'AKTUALNA POZYCJA',
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 1.2,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                text,
                style: const TextStyle(
                  fontSize: 64,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accentGreen,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  'm',
                  style: TextStyle(
                    fontSize: 22,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          if (lastStatus.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              lastStatus,
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

class PresetTile extends StatelessWidget {
  final String label;
  final String sublabel;
  final Color color;
  final VoidCallback onTap;

  const PresetTile({
    super.key,
    required this.label,
    required this.sublabel,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.my_location, color: color, size: 26),
              const SizedBox(height: 10),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                sublabel,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// EKRAN 2 – PLACEHOLDER PULPITU CYD
// =============================================================================

class CydPlaceholderScreen extends StatelessWidget {
  const CydPlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.divider),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLight,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.dashboard_customize_outlined,
                    color: AppColors.accentOrange,
                    size: 34,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Moduł Pulpitu CYD',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                const Text(
                  'Oczekiwanie na połączenie/konfigurację',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLight,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Rozbudowa: drugi moduł ESP32 + ekran dotykowy',
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// EKRAN USTAWIEŃ
// =============================================================================

class SettingsResult {
  final Map<String, double> distances;
  final int maxSpeed;
  final int ramp;
  SettingsResult({
    required this.distances,
    required this.maxSpeed,
    required this.ramp,
  });
}

class SettingsScreen extends StatefulWidget {
  final Map<String, double> initialDistances;
  final int initialMaxSpeed;
  final int initialRamp;

  const SettingsScreen({
    super.key,
    required this.initialDistances,
    required this.initialMaxSpeed,
    required this.initialRamp,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _d10;
  late final TextEditingController _d25;
  late final TextEditingController _d33;
  late final TextEditingController _d50;
  late final TextEditingController _maxSpeed;
  late final TextEditingController _ramp;

  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _d10 = TextEditingController(text: fmtNum(widget.initialDistances['d10']!));
    _d25 = TextEditingController(text: fmtNum(widget.initialDistances['d25']!));
    _d33 = TextEditingController(text: fmtNum(widget.initialDistances['d33']!));
    _d50 = TextEditingController(text: fmtNum(widget.initialDistances['d50']!));
    _maxSpeed = TextEditingController(text: widget.initialMaxSpeed.toString());
    _ramp = TextEditingController(text: widget.initialRamp.toString());
  }

  @override
  void dispose() {
    _d10.dispose();
    _d25.dispose();
    _d33.dispose();
    _d50.dispose();
    _maxSpeed.dispose();
    _ramp.dispose();
    super.dispose();
  }

  String? _validateDistance(String? value) {
    final v = double.tryParse((value ?? '').replaceAll(',', '.'));
    if (v == null || v <= 0) return 'Podaj wartość > 0';
    return null;
  }

  String? _validateSpeed(String? value) {
    final v = int.tryParse(value ?? '');
    if (v == null) return 'Podaj liczbę';
    if (v < 50 || v > 255) return 'Zakres 50–255';
    return null;
  }

  String? _validateRamp(String? value) {
    final v = int.tryParse(value ?? '');
    if (v == null || v < 0) return 'Podaj liczbę ≥ 0';
    return null;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final result = SettingsResult(
      distances: {
        'd10': double.parse(_d10.text.replaceAll(',', '.')),
        'd25': double.parse(_d25.text.replaceAll(',', '.')),
        'd33': double.parse(_d33.text.replaceAll(',', '.')),
        'd50': double.parse(_d50.text.replaceAll(',', '.')),
      },
      maxSpeed: int.parse(_maxSpeed.text),
      ramp: int.parse(_ramp.text),
    );
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ustawienia')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            _SectionHeader(title: 'DYSTANSE PRESETÓW', icon: Icons.straighten),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _NumberField(
                    label: 'Preset 1 (m)',
                    controller: _d10,
                    validator: _validateDistance,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _NumberField(
                    label: 'Preset 2 (m)',
                    controller: _d25,
                    validator: _validateDistance,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _NumberField(
                    label: 'Preset 3 (m)',
                    controller: _d33,
                    validator: _validateDistance,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _NumberField(
                    label: 'Preset 4 (m)',
                    controller: _d50,
                    validator: _validateDistance,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            _SectionHeader(title: 'SILNIK', icon: Icons.settings_input_component),
            const SizedBox(height: 12),
            _NumberField(
              label: 'Maks. prędkość PWM (50–255)',
              controller: _maxSpeed,
              validator: _validateSpeed,
            ),
            const SizedBox(height: 12),
            _NumberField(
              label: 'Rampa przyspieszania/hamowania (impulsy)',
              controller: _ramp,
              validator: _validateRamp,
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text(
                  'ZAPISZ I WYŚLIJ',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Ustawienia są zapisywane lokalnie na telefonie oraz wysyłane do '
              'urządzenia (SET_DIST / SET_MOTOR), jeśli jest ono połączone.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  const _SectionHeader({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.accentBlue),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _NumberField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? Function(String?) validator;

  const _NumberField({
    required this.label,
    required this.controller,
    required this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: const TextStyle(color: AppColors.textPrimary),
      decoration: InputDecoration(labelText: label),
      validator: validator,
    );
  }
}
