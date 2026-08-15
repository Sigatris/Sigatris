import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();

  runApp(
    TargetPullerApp(
      prefs: prefs,
    ),
  );
}

class TargetPullerApp extends StatelessWidget {
  final SharedPreferences prefs;

  const TargetPullerApp({
    super.key,
    required this.prefs,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Tarczociąg',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        cardTheme: const CardThemeData(
          color: Color(0xFF1E1E1E),
          elevation: 3,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1B1B1B),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(
              color: Color(0xFF383838),
            ),
          ),
        ),
      ),
      home: TargetPullerHome(
        prefs: prefs,
      ),
    );
  }
}

class TargetPullerHome extends StatefulWidget {
  final SharedPreferences prefs;

  const TargetPullerHome({
    super.key,
    required this.prefs,
  });

  @override
  State<TargetPullerHome> createState() => _TargetPullerHomeState();
}

class _TargetPullerHomeState extends State<TargetPullerHome> {
  final PageController _pageController = PageController();

  BluetoothConnection? _connection;
  StreamSubscription<Uint8List>? _inputSubscription;

  bool _connecting = false;
  bool _connected = false;

  String _connectionStatus = 'Rozłączono';
  String _deviceName = '';

  double? _position;
  String _deviceStatus = 'Brak danych';

  // Bufor odbieranych danych.
  String _receiveBuffer = '';

  // Presety dystansów.
  late double _distance10;
  late double _distance25;
  late double _distance33;
  late double _distance50;

  // Parametry silnika.
  late int _maxSpeed;
  late int _ramp;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() {
    _distance10 = widget.prefs.getDouble('distance10') ?? 10.0;
    _distance25 = widget.prefs.getDouble('distance25') ?? 25.0;
    _distance33 = widget.prefs.getDouble('distance33') ?? 33.0;
    _distance50 = widget.prefs.getDouble('distance50') ?? 50.0;

    _maxSpeed = widget.prefs.getInt('maxSpeed') ?? 200;
    _ramp = widget.prefs.getInt('ramp') ?? 100;
  }

  @override
  void dispose() {
    _pageController.dispose();
    _disconnect();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // BLUETOOTH
  // ---------------------------------------------------------------------------

  Future<void> _showBluetoothDevices() async {
    if (_connecting) return;

    try {
      final bluetoothState =
          await FlutterBluetoothSerial.instance.state;

      if (bluetoothState != BluetoothState.STATE_ON) {
        if (!mounted) return;

        await showDialog<void>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Bluetooth wyłączony'),
              content: const Text(
                'Włącz Bluetooth w telefonie, a następnie spróbuj ponownie.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );

        return;
      }

      final devices =
          await FlutterBluetoothSerial.instance.getBondedDevices();

      if (!mounted) return;

      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: const Color(0xFF1A1A1A),
        isScrollControlled: true,
        builder: (context) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Sparowane urządzenia',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (devices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(30),
                      child: Text(
                        'Brak sparowanych urządzeń Bluetooth.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: devices.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final device = devices[index];

                          return ListTile(
                            leading: const CircleAvatar(
                              child: Icon(Icons.bluetooth),
                            ),
                            title: Text(
                              device.name?.isNotEmpty == true
                                  ? device.name!
                                  : 'Nieznane urządzenie',
                            ),
                            subtitle: Text(device.address),
                            trailing: const Icon(
                              Icons.chevron_right,
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              _connectToDevice(device);
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      );
    } catch (e) {
      _showMessage('Błąd Bluetooth: $e');
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_connecting) return;

    await _disconnect();

    if (!mounted) return;

    setState(() {
      _connecting = true;
      _connectionStatus = 'Łączenie...';
      _deviceName = device.name?.isNotEmpty == true
          ? device.name!
          : device.address;
    });

    try {
      final connection =
          await BluetoothConnection.toAddress(device.address);

      if (!mounted) {
        connection.dispose();
        return;
      }

      _connection = connection;

      setState(() {
        _connecting = false;
        _connected = true;
        _connectionStatus = 'Połączono';
      });

      _startListening();

      _showMessage(
        'Połączono z ${_deviceName.isNotEmpty ? _deviceName : device.address}',
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _connecting = false;
        _connected = false;
        _connectionStatus = 'Rozłączono';
      });

      _showMessage('Nie udało się połączyć: $e');
    }
  }

  void _startListening() {
    final input = _connection?.input;

    if (input == null) {
      return;
    }

    _inputSubscription?.cancel();

    _inputSubscription = input.listen(
      _onBluetoothData,
      onError: (error) {
        _handleConnectionLost('Błąd odbioru: $error');
      },
      onDone: () {
        _handleConnectionLost('Połączenie zostało zamknięte.');
      },
      cancelOnError: false,
    );
  }

  void _onBluetoothData(Uint8List data) {
    try {
      final text = utf8.decode(
        data,
        allowMalformed: true,
      );

      _receiveBuffer += text;

      // ESP32 wysyła ramki zakończone \n.
      while (_receiveBuffer.contains('\n')) {
        final newlineIndex = _receiveBuffer.indexOf('\n');

        String frame =
            _receiveBuffer.substring(0, newlineIndex);

        _receiveBuffer =
            _receiveBuffer.substring(newlineIndex + 1);

        frame = frame.trim();

        if (frame.isEmpty) {
          continue;
        }

        _processFrame(frame);
      }

      // Zabezpieczenie przed niekontrolowanym wzrostem bufora
      // w przypadku uszkodzonych danych.
      if (_receiveBuffer.length > 4096) {
        _receiveBuffer =
            _receiveBuffer.substring(_receiveBuffer.length - 1024);
      }
    } catch (e) {
      debugPrint('Bluetooth parser error: $e');
    }
  }

  void _processFrame(String frame) {
    debugPrint('BT RX: $frame');

    // POS:18.4
    if (frame.startsWith('POS:')) {
      final value = double.tryParse(
        frame.substring(4).trim(),
      );

      if (value != null && mounted) {
        setState(() {
          _position = value;
        });
      }

      return;
    }

    // STATUS:HOME_OK
    if (frame == 'STATUS:HOME_OK') {
      if (mounted) {
        setState(() {
          _deviceStatus = 'HOME OK';
          _position = 0.0;
        });
      }

      return;
    }

    // STATUS:ARRIVED:X
    if (frame.startsWith('STATUS:ARRIVED:')) {
      final value =
          frame.substring('STATUS:ARRIVED:'.length);

      if (mounted) {
        setState(() {
          _deviceStatus = 'Osiągnięto $value m';
        });
      }

      return;
    }

    // CFG:OK
    if (frame == 'CFG:OK') {
      if (mounted) {
        setState(() {
          _deviceStatus = 'Konfiguracja OK';
        });
      }

      _showMessage('Urządzenie potwierdziło konfigurację.');
      return;
    }

    // Można łatwo rozszerzyć o kolejne ramki.
    if (mounted) {
      setState(() {
        _deviceStatus = frame;
      });
    }
  }

  Future<void> _sendCommand(String command) async {
    if (!_connected || _connection == null) {
      _showMessage('Brak połączenia z tarczociągiem.');
      return;
    }

    try {
      final bytes = Uint8List.fromList(
        utf8.encode(command),
      );

      _connection!.output.add(bytes);

      await _connection!.output.allSent;

      debugPrint('BT TX: ${command.trim()}');
    } catch (e) {
      _handleConnectionLost(
        'Nie udało się wysłać polecenia: $e',
      );
    }
  }

  Future<void> _disconnect() async {
    final subscription = _inputSubscription;
    _inputSubscription = null;

    await subscription?.cancel();

    final connection = _connection;
    _connection = null;

    try {
      await connection?.finish();
    } catch (_) {
      try {
        connection?.dispose();
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _connected = false;
        _connecting = false;
        _connectionStatus = 'Rozłączono';
      });
    }
  }

  void _handleConnectionLost(String reason) {
    _inputSubscription?.cancel();
    _inputSubscription = null;

    try {
      _connection?.dispose();
    } catch (_) {}

    _connection = null;

    if (mounted) {
      setState(() {
        _connected = false;
        _connecting = false;
        _connectionStatus = 'Rozłączono';
        _deviceStatus = 'Brak połączenia';
      });

      _showMessage(reason);
    }
  }

  // ---------------------------------------------------------------------------
  // SETTINGS
  // ---------------------------------------------------------------------------

  Future<void> _saveDistances({
    required double d10,
    required double d25,
    required double d33,
    required double d50,
  }) async {
    await widget.prefs.setDouble('distance10', d10);
    await widget.prefs.setDouble('distance25', d25);
    await widget.prefs.setDouble('distance33', d33);
    await widget.prefs.setDouble('distance50', d50);

    if (mounted) {
      setState(() {
        _distance10 = d10;
        _distance25 = d25;
        _distance33 = d33;
        _distance50 = d50;
      });
    }

    await _sendCommand(
      'SET_DIST:${_formatNumber(d10)},'
      '${_formatNumber(d25)},'
      '${_formatNumber(d33)},'
      '${_formatNumber(d50)}\n',
    );
  }

  Future<void> _saveMotorSettings({
    required int maxSpeed,
    required int ramp,
  }) async {
    await widget.prefs.setInt('maxSpeed', maxSpeed);
    await widget.prefs.setInt('ramp', ramp);

    if (mounted) {
      setState(() {
        _maxSpeed = maxSpeed;
        _ramp = ramp;
      });
    }

    await _sendCommand(
      'SET_MOTOR:$maxSpeed,$ramp\n',
    );
  }

  String _formatNumber(double value) {
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }

    return value
        .toStringAsFixed(1)
        .replaceAll(RegExp(r'\.?0+$'), '');
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          distance10: _distance10,
          distance25: _distance25,
          distance33: _distance33,
          distance50: _distance50,
          maxSpeed: _maxSpeed,
          ramp: _ramp,
          onSaveDistances: _saveDistances,
          onSaveMotorSettings: _saveMotorSettings,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: PageView(
          controller: _pageController,
          physics: const BouncingScrollPhysics(),
          children: [
            _buildMainPage(),
            _buildCydPlaceholder(),
          ],
        ),
      ),
    );
  }

  Widget _buildMainPage() {
    return Column(
      children: [
        _buildAppBar(),

        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              16,
              8,
              16,
              16,
            ),
            child: Column(
              children: [
                _buildPositionCard(),

                const SizedBox(height: 16),

                _buildPresetGrid(),

                const SizedBox(height: 18),

                _buildHomeButton(),

                const SizedBox(height: 10),

                _buildDeviceStatus(),
              ],
            ),
          ),
        ),

        _buildPageIndicator(),
      ],
    );
  }

  Widget _buildAppBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF181818),
        border: Border(
          bottom: BorderSide(
            color: Color(0xFF2A2A2A),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _connected
                        ? Colors.greenAccent
                        : Colors.redAccent,
                    boxShadow: [
                      BoxShadow(
                        color: (_connected
                                ? Colors.greenAccent
                                : Colors.redAccent)
                            .withValues(alpha: 0.4),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 9),
                Flexible(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        _connectionStatus,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_deviceName.isNotEmpty)
                        Text(
                          _deviceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          if (_connecting)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                ),
              ),
            )
          else
            FilledButton.icon(
              onPressed: _connected
                  ? _disconnect
                  : _showBluetoothDevices,
              icon: Icon(
                _connected
                    ? Icons.bluetooth_disabled
                    : Icons.bluetooth,
                size: 18,
              ),
              label: Text(
                _connected ? 'Rozłącz' : 'Połącz',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _connected
                    ? Colors.red.shade800
                    : Colors.blue.shade700,
              ),
            ),

          const SizedBox(width: 4),

          IconButton(
            tooltip: 'Ustawienia',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
    );
  }

  Widget _buildPositionCard() {
    final positionText = _position == null
        ? '--.-'
        : _position!.toStringAsFixed(1);

    return Card(
      margin: EdgeInsets.zero,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          vertical: 28,
          horizontal: 16,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF202020),
              Color(0xFF181818),
            ],
          ),
        ),
        child: Column(
          children: [
            Text(
              'AKTUALNA POZYCJA',
              style: TextStyle(
                color: Colors.grey.shade500,
                letterSpacing: 1.8,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            FittedBox(
              child: Text(
                '$positionText m',
                style: const TextStyle(
                  fontSize: 58,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _connected
                  ? 'Dane z tarczociągu'
                  : 'Oczekiwanie na połączenie',
              style: TextStyle(
                color: _connected
                    ? Colors.greenAccent
                    : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetGrid() {
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.55,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _buildPresetTile(
          label: '10 m',
          value: _distance10,
          color: Colors.blue,
        ),
        _buildPresetTile(
          label: '25 m',
          value: _distance25,
          color: Colors.green,
        ),
        _buildPresetTile(
          label: '33 m',
          value: _distance33,
          color: Colors.orange,
        ),
        _buildPresetTile(
          label: '50 m',
          value: _distance50,
          color: Colors.deepPurple,
        ),
      ],
    );
  }

  Widget _buildPresetTile({
    required String label,
    required double value,
    required MaterialColor color,
  }) {
    return Material(
      color: color.shade900.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          _sendCommand(
            'JEDZ:${_formatNumber(value)}\n',
          );

          if (mounted) {
            setState(() {
              _deviceStatus =
                  'Jazda do ${_formatNumber(value)} m';
            });
          }
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: color.shade700.withValues(alpha: 0.6),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.straighten,
                color: color.shade200,
                size: 25,
              ),
              const SizedBox(height: 7),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'JEDŹ',
                style: TextStyle(
                  color: color.shade200,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomeButton() {
    return SizedBox(
      width: double.infinity,
      height: 76,
      child: FilledButton.icon(
        onPressed: () {
          _sendCommand('HOME\n');

          if (mounted) {
            setState(() {
              _deviceStatus = 'Powrót do HOME...';
            });
          }
        },
        icon: const Icon(
          Icons.home,
          size: 31,
        ),
        label: const Text(
          'POWRÓT  •  HOME',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
          ),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.red.shade800,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceStatus() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 11,
        ),
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              color: Colors.grey.shade500,
              size: 20,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                _deviceStatus,
                style: TextStyle(
                  color: Colors.grey.shade400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCydPlaceholder() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: Card(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.touch_app,
                  size: 64,
                  color: Colors.blue.shade300,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Moduł Pulpitu CYD',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Oczekiwanie na połączenie/konfigurację',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF151515),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'CYD • ESP32 • PRZYSZŁY MODUŁ',
                    style: TextStyle(
                      color: Colors.blueAccent,
                      fontSize: 11,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPageIndicator() {
    return Container(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _indicator(true),
          const SizedBox(width: 7),
          _indicator(false),
        ],
      ),
    );
  }

  Widget _indicator(bool active) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: active ? 24 : 7,
      height: 7,
      decoration: BoxDecoration(
        color: active
            ? Colors.blueAccent
            : Colors.grey.shade700,
        borderRadius: BorderRadius.circular(10),
      ),
    );
  }
}

// ============================================================================
// SETTINGS PAGE
// ============================================================================

class SettingsPage extends StatefulWidget {
  final double distance10;
  final double distance25;
  final double distance33;
  final double distance50;

  final int maxSpeed;
  final int ramp;

  final Future<void> Function({
    required double d10,
    required double d25,
    required double d33,
    required double d50,
  }) onSaveDistances;

  final Future<void> Function({
    required int maxSpeed,
    required int ramp,
  }) onSaveMotorSettings;

  const SettingsPage({
    super.key,
    required this.distance10,
    required this.distance25,
    required this.distance33,
    required this.distance50,
    required this.maxSpeed,
    required this.ramp,
    required this.onSaveDistances,
    required this.onSaveMotorSettings,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _d10;
  late final TextEditingController _d25;
  late final TextEditingController _d33;
  late final TextEditingController _d50;

  late final TextEditingController _maxSpeed;
  late final TextEditingController _ramp;

  bool _savingDistances = false;
  bool _savingMotor = false;

  @override
  void initState() {
    super.initState();

    _d10 = TextEditingController(
      text: _formatNumber(widget.distance10),
    );
    _d25 = TextEditingController(
      text: _formatNumber(widget.distance25),
    );
    _d33 = TextEditingController(
      text: _formatNumber(widget.distance33),
    );
    _d50 = TextEditingController(
      text: _formatNumber(widget.distance50),
    );

    _maxSpeed = TextEditingController(
      text: widget.maxSpeed.toString(),
    );
    _ramp = TextEditingController(
      text: widget.ramp.toString(),
    );
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

  String _formatNumber(double value) {
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }

    return value.toString();
  }

  double? _parseDistance(
    TextEditingController controller,
  ) {
    return double.tryParse(
      controller.text.trim().replaceAll(',', '.'),
    );
  }

  int? _parseInt(
    TextEditingController controller,
  ) {
    return int.tryParse(
      controller.text.trim(),
    );
  }

  Future<void> _saveDistances() async {
    final d10 = _parseDistance(_d10);
    final d25 = _parseDistance(_d25);
    final d33 = _parseDistance(_d33);
    final d50 = _parseDistance(_d50);

    if (d10 == null ||
        d25 == null ||
        d33 == null ||
        d50 == null ||
        d10 <= 0 ||
        d25 <= 0 ||
        d33 <= 0 ||
        d50 <= 0) {
      _showError(
        'Wszystkie dystanse muszą być poprawnymi liczbami większymi od 0.',
      );
      return;
    }

    setState(() {
      _savingDistances = true;
    });

    try {
      await widget.onSaveDistances(
        d10: d10,
        d25: d25,
        d33: d33,
        d50: d50,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Dystanse zapisane. Wysłano SET_DIST.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingDistances = false;
        });
      }
    }
  }

  Future<void> _saveMotor() async {
    final maxSpeed = _parseInt(_maxSpeed);
    final ramp = _parseInt(_ramp);

    if (maxSpeed == null ||
        maxSpeed < 50 ||
        maxSpeed > 255) {
      _showError(
        'Maksymalna prędkość PWM musi być w zakresie 50–255.',
      );
      return;
    }

    if (ramp == null || ramp < 0) {
      _showError(
        'Rampa musi być liczbą całkowitą 0 lub większą.',
      );
      return;
    }

    setState(() {
      _savingMotor = true;
    });

    try {
      await widget.onSaveMotorSettings(
        maxSpeed: maxSpeed,
        ramp: ramp,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Parametry silnika zapisane. Wysłano SET_MOTOR.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingMotor = false;
        });
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade800,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ustawienia'),
        backgroundColor: const Color(0xFF181818),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSectionTitle(
            icon: Icons.straighten,
            title: 'Dystanse',
          ),

          const SizedBox(height: 10),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildDistanceField(
                    controller: _d10,
                    label: 'Preset 10 m',
                  ),
                  const SizedBox(height: 12),
                  _buildDistanceField(
                    controller: _d25,
                    label: 'Preset 25 m',
                  ),
                  const SizedBox(height: 12),
                  _buildDistanceField(
                    controller: _d33,
                    label: 'Preset 33 m',
                  ),
                  const SizedBox(height: 12),
                  _buildDistanceField(
                    controller: _d50,
                    label: 'Preset 50 m',
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: _savingDistances
                          ? null
                          : _saveDistances,
                      icon: _savingDistances
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.save),
                      label: const Text(
                        'ZAPISZ DYSTANSE',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 28),

          _buildSectionTitle(
            icon: Icons.speed,
            title: 'Silnik',
          ),

          const SizedBox(height: 10),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _maxSpeed,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Maksymalna prędkość PWM',
                      helperText: 'Dozwolony zakres: 50–255',
                      prefixIcon: Icon(Icons.speed),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _ramp,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Rampa przyspieszania/hamowania',
                      helperText: 'W impulsach',
                      prefixIcon: Icon(
                        Icons.trending_up,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      onPressed:
                          _savingMotor ? null : _saveMotor,
                      icon: _savingMotor
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.save),
                      label: const Text(
                        'ZAPISZ PARAMETRY SILNIKA',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 28),

          _buildSectionTitle(
            icon: Icons.bluetooth,
            title: 'Protokół Bluetooth',
          ),

          const SizedBox(height: 10),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  _protocolRow(
                    'Pozycja',
                    'POS:18.4',
                  ),
                  _protocolRow(
                    'Home',
                    'STATUS:HOME_OK',
                  ),
                  _protocolRow(
                    'Dojazd',
                    'STATUS:ARRIVED:X',
                  ),
                  _protocolRow(
                    'Konfiguracja',
                    'CFG:OK',
                  ),
                  _protocolRow(
                    'Jazda',
                    'JEDZ:X',
                  ),
                  _protocolRow(
                    'Home',
                    'HOME',
                  ),
                  _protocolRow(
                    'Dystanse',
                    'SET_DIST:d10,d25,d33,d50',
                  ),
                  _protocolRow(
                    'Silnik',
                    'SET_MOTOR:maxSpd,rampa',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle({
    required IconData icon,
    required String title,
  }) {
    return Row(
      children: [
        Icon(
          icon,
          color: Colors.blueAccent,
        ),
        const SizedBox(width: 9),
        Text(
          title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildDistanceField({
    required TextEditingController controller,
    required String label,
  }) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
      ),
      decoration: InputDecoration(
        labelText: label,
        suffixText: 'm',
        prefixIcon: const Icon(
          Icons.route,
        ),
      ),
    );
  }

  Widget _protocolRow(
    String name,
    String command,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: 7,
      ),
      child: Row(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 105,
            child: Text(
              name,
              style: TextStyle(
                color: Colors.grey.shade500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              command,
              style: const TextStyle(
                fontFamily: 'monospace',
                color: Colors.greenAccent,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
