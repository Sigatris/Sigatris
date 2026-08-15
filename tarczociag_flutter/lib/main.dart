import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const TarczociagApp());
}

class TarczociagApp extends StatefulWidget {
  const TarczociagApp({super.key});

  @override
  State<TarczociagApp> createState() => _TarczociagAppState();
}

class _TarczociagAppState extends State<TarczociagApp>
    with TickerProviderStateMixin {
  final PageController _pageController = PageController();

  BluetoothConnection? _connection;
  List<BluetoothDevice> _pairedDevices = [];
  bool _isConnected = false;
  bool _isConnecting = false;

  double _positionValue = 0.0;
  String _positionText = '0.0 m';
  String _statusMessage = 'Rozłączono';
  StringBuffer _rxBuffer = StringBuffer();

  List<double> _presetDistances = [10, 25, 33, 50];
  int _maxMotorSpeed = 200;
  int _accelRamp = 60;

  double _targetDistance = 0.0;
  int _selectedPresetIndex = -1;
  bool _targetReached = false;
  bool _timerRunning = false;
  int _elapsedSeconds = 0;
  DateTime _now = DateTime.now();

  Timer? _clockTimer;
  Timer? _targetTimer;
  Timer? _longPressResetTimer;

  late final AnimationController _pulseController;
  late final AnimationController _targetGlowController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _targetGlowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
      lowerBound: 0.0,
      upperBound: 1.0,
    )..repeat(reverse: true);

    _loadPreferences();
    _refreshBondedDevices();
    _startClock();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _connection?.finish();
    _clockTimer?.cancel();
    _targetTimer?.cancel();
    _longPressResetTimer?.cancel();
    _pulseController.dispose();
    _targetGlowController.dispose();
    super.dispose();
  }

  void _startClock() {
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _now = DateTime.now();
        });
      }
    });
  }

  void _startTargetTimer() {
    if (_timerRunning) return;

    _timerRunning = true;
    _elapsedSeconds = 0;

    _targetTimer?.cancel();
    _targetTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsedSeconds++;
      });
    });
  }

  void _stopTargetTimer() {
    _targetTimer?.cancel();
    _targetTimer = null;
    _timerRunning = false;
  }

  void _resetTargetTimer() {
    _stopTargetTimer();
    setState(() {
      _elapsedSeconds = 0;
      _statusMessage = 'Timer zresetowany';
    });
  }

  String _formatElapsedTime() {
    final minutes = (_elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _formatClock() {
    return '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();

    if (!mounted) return;

    final savedDistances = prefs.getStringList('preset_distances');
    final maxSpeed = prefs.getInt('max_motor_speed') ?? 200;
    final ramp = prefs.getInt('motor_ramp') ?? 60;

    setState(() {
      if (savedDistances != null && savedDistances.length == 4) {
        _presetDistances = savedDistances.map((v) {
          final parsed = double.tryParse(v);
          return parsed ?? 0.0;
        }).toList();
      }

      _maxMotorSpeed = maxSpeed;
      _accelRamp = ramp;
    });
  }

  Future<void> _persistPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'preset_distances',
      _presetDistances.map((value) => value.toString()).toList(),
    );
    await prefs.setInt('max_motor_speed', _maxMotorSpeed);
    await prefs.setInt('motor_ramp', _accelRamp);
  }

  Future<void> _refreshBondedDevices() async {
    try {
      final devices = await FlutterBluetoothSerial.instance.getBondedDevices();
      if (mounted) {
        setState(() {
          _pairedDevices = devices;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _pairedDevices = [];
        });
      }
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_isConnecting) return;

    try {
      setState(() {
        _isConnecting = true;
        _statusMessage = 'Nawiązywanie połączenia...';
      });

      if (_connection != null) {
        await _connection!.finish();
      }

      final conn = await BluetoothConnection.toAddress(device.address);
      _connection = conn;

      _connection!.input!.listen(
        _handleIncomingData,
        onDone: () {
          if (mounted) {
            setState(() {
              _isConnected = false;
              _statusMessage = 'Rozłączono';
            });
          }
        },
        onError: (_) {
          if (mounted) {
            setState(() {
              _isConnected = false;
              _statusMessage = 'Błąd połączenia';
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _isConnected = true;
          _statusMessage = 'Połączono: ${device.name ?? device.address}';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isConnected = false;
          _statusMessage = 'Nie udało się połączyć';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  Future<void> _disconnect() async {
    try {
      await _connection?.finish();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _connection = null;
        _isConnected = false;
        _statusMessage = 'Rozłączono';
      });
    }
  }

  void _handleIncomingData(Uint8List data) {
    final text = utf8.decode(data, allowMalformed: true);
    if (text.isEmpty) return;

    _rxBuffer.write(text);

    String remaining = _rxBuffer.toString();
    while (remaining.contains('\n')) {
      final lineEnd = remaining.indexOf('\n');
      final line = remaining.substring(0, lineEnd).trim();
      remaining = remaining.substring(lineEnd + 1);
      _processFrame(line);
    }

    _rxBuffer = StringBuffer(remaining);
  }

  void _processFrame(String frame) {
    if (frame.isEmpty) return;

    if (frame.startsWith('POS:')) {
      final raw = frame.substring(4).trim();
      final parsed = double.tryParse(raw);
      if (parsed != null) {
        setState(() {
          _positionValue = parsed;
          _positionText = '${parsed.toStringAsFixed(1)} m';
        });

        _evaluateTargetStatus(parsed);
      }
      return;
    }

    if (frame == 'STATUS:HOME_OK') {
      setState(() {
        _statusMessage = 'Powrót zakończony';
        _targetReached = false;
      });
      _stopTargetTimer();
      return;
    }

    if (frame.startsWith('STATUS:ARRIVED:')) {
      final raw = frame.substring('STATUS:ARRIVED:'.length).trim();
      final targetValue = double.tryParse(raw);
      if (targetValue != null) {
        setState(() {
          _targetDistance = targetValue;
          _targetReached = true;
          _statusMessage = 'Cel osiągnięty: ${targetValue.toStringAsFixed(1)} m';
        });
        _startTargetTimer();
      } else {
        setState(() {
          _targetReached = true;
          _statusMessage = 'Cel osiągnięty';
        });
        _startTargetTimer();
      }
      return;
    }

    if (frame == 'CFG:OK') {
      setState(() {
        _statusMessage = 'Konfiguracja zapisana';
      });
      return;
    }

    if (frame.startsWith('STATUS:')) {
      setState(() {
        _statusMessage = frame;
      });
    }
  }

  void _evaluateTargetStatus(double currentPosition) {
    if (_targetDistance <= 0) return;

    final diff = (currentPosition - _targetDistance).abs();
    if (diff <= 0.5 && !_targetReached) {
      setState(() {
        _targetReached = true;
        _statusMessage = 'Cel osiągnięty: ${_targetDistance.toStringAsFixed(1)} m';
      });
      _startTargetTimer();
    }
  }

  Future<void> _sendCommand(String command) async {
    if (_connection == null || !_isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Najpierw połącz urządzenie Bluetooth.'),
          ),
        );
      }
      return;
    }

    try {
      _connection!.output.add(Uint8List.fromList(utf8.encode(command)));
      await _connection!.output.allSent;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nie udało się wysłać komendy do urządzenia.'),
          ),
        );
      }
    }
  }

  void _activatePreset(int index) {
    final value = _presetDistances[index].toInt();
    setState(() {
      _selectedPresetIndex = index;
      _targetDistance = value.toDouble();
      _targetReached = false;
      _timerRunning = false;
      _elapsedSeconds = 0;
      _statusMessage = 'Wybrano cel: ${value}m';
    });
    _stopTargetTimer();
    _pulseController.forward(from: 0.0);

    _sendCommand('JEDZ:$value\n');
  }

  void _sendHome() {
    setState(() {
      _targetReached = false;
      _statusMessage = 'Powrót do pozycji home';
    });
    _stopTargetTimer();
    _sendCommand('HOME\n');
  }

  void _showDevicePicker() async {
    await _refreshBondedDevices();

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1E1E1E),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  const Text(
                    'Wybierz urządzenie Bluetooth',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_pairedDevices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'Brak sparowanych urządzeń Bluetooth.',
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _pairedDevices.length,
                        separatorBuilder: (_, __) => const Divider(
                          color: Color(0xFF2B2B2B),
                        ),
                        itemBuilder: (context, index) {
                          final device = _pairedDevices[index];
                          return ListTile(
                            leading: const Icon(
                              Icons.bluetooth,
                              color: Color(0xFF5DA9E9),
                            ),
                            title: Text(
                              device.name ?? 'Nieznane urządzenie',
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              device.address,
                              style: const TextStyle(color: Colors.white70),
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              _connectToDevice(device);
                            },
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _refreshBondedDevices();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Odśwież listę'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: const Color(0xFF2B2B2B),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showSettingsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SettingsSheet(
        initialDistances: _presetDistances,
        initialMaxSpeed: _maxMotorSpeed,
        initialRamp: _accelRamp,
        onSave: (distances, maxSpeed, ramp) async {
          setState(() {
            _presetDistances = distances;
            _maxMotorSpeed = maxSpeed;
            _accelRamp = ramp;
          });

          await _persistPreferences();

          if (_isConnected) {
            _sendCommand('SET_DIST:${_distanceCommandString()}\n');
            _sendCommand('SET_MOTOR:${_maxMotorSpeed},${_accelRamp}\n');
          }
        },
      ),
    );
  }

  String _distanceCommandString() {
    return _presetDistances.map((value) => value.toInt()).join(',');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tarczociąg BT',
      debugShowCheckedModeBanner: false,
      theme: _buildDarkTheme(),
      home: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: _isConnected ? Colors.green : Colors.red,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: (_isConnected ? Colors.green : Colors.red).withOpacity(0.5),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _isConnected ? 'Połączono' : 'Rozłączono',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          actions: [
            if (_isConnecting)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
              )
            else
              TextButton.icon(
                onPressed: _showDevicePicker,
                icon: const Icon(Icons.bluetooth_connected_rounded),
                label: const Text('Połącz'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: const Color(0xFF2D3F5C),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            IconButton(
              onPressed: _showSettingsSheet,
              icon: const Icon(Icons.settings),
              tooltip: 'Ustawienia',
            ),
          ],
        ),
        body: PageView(
          controller: _pageController,
          children: [
            _buildMainPage(),
            _buildCydPage(),
          ],
        ),
      ),
    );
  }

  Widget _buildMainPage() {
    return SafeArea(
      child: Stack(
        children: [
          Positioned(
            top: 14,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF2A2A2A)),
              ),
              child: Text(
                _formatClock(),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 60, 16, 16),
            child: Column(
              children: [
                const SizedBox(height: 8),
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    final scale = 0.94 + (_pulseController.value * 0.14);
                    return Transform.scale(
                      scale: scale,
                      child: child,
                    );
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1D1D1D),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF2A2A2A)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.blue.withOpacity(0.18 + (_pulseController.value * 0.2)),
                          blurRadius: 20,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'Pozycja',
                          style: TextStyle(fontSize: 18, color: Colors.white70),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _positionText,
                          style: const TextStyle(
                            fontSize: 42,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (_targetDistance > 0)
                          Text(
                            'Cel: ${_targetDistance.toStringAsFixed(0)} m',
                            style: const TextStyle(
                              fontSize: 15,
                              color: Color(0xFF86C9FF),
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        else
                          const Text(
                            'Brak celu',
                            style: TextStyle(
                              fontSize: 15,
                              color: Colors.white38,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                GestureDetector(
                  onLongPressStart: (_) {
                    _longPressResetTimer?.cancel();
                    _longPressResetTimer = Timer(const Duration(seconds: 3), () {
                      _resetTargetTimer();
                    });
                  },
                  onLongPressEnd: (_) {
                    _longPressResetTimer?.cancel();
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFF2A2A2A)),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'Czas od celu',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white60,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _formatElapsedTime(),
                          style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w800,
                            color: _timerRunning
                                ? const Color(0xFF7EE8A6)
                                : Colors.white38,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Przytrzymaj 3s, aby zresetować',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white38,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: GridView.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 1.3,
                    children: List.generate(4, (index) {
                      final distance = _presetDistances[index];
                      final isSelected = _selectedPresetIndex == index;

                      return AnimatedScale(
                        scale: isSelected ? 1.05 : 1.0,
                        duration: const Duration(milliseconds: 220),
                        child: Material(
                          color: _tileColor(index),
                          borderRadius: BorderRadius.circular(18),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () => _activatePreset(index),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${distance.toInt()} m',
                                    style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                  if (isSelected)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 8),
                                      child: Icon(
                                        Icons.check_circle_rounded,
                                        color: Colors.white,
                                        size: 22,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: ElevatedButton.icon(
                    onPressed: _sendHome,
                    icon: const Icon(Icons.home_rounded, size: 28),
                    label: const Text(
                      'POWRÓT (HOME)',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFEE8E28),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCydPage() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1B1B),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFF2B2B2B)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.smart_screen_rounded,
                  size: 56,
                  color: Color(0xFF5DA9E9),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Moduł Pulpitu CYD',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Oczekiwanie na połączenie / konfigurację',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.white70,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF121212),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF2A2A2A)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.info_outline, color: Colors.orange),
                      SizedBox(width: 10),
                      Text(
                        'Przygotowane do przyszłej integracji z modułem ESP32',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _tileColor(int index) {
    final colors = [
      const Color(0xFF3A6EA5),
      const Color(0xFF2B8C6D),
      const Color(0xFFd97706),
      const Color(0xFF5A4FCF),
    ];
    return colors[index % colors.length];
  }

  ThemeData _buildDarkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF121212),
      primaryColor: const Color(0xFF5DA9E9),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF5DA9E9),
        secondary: Color(0xFF3DDC97),
        surface: Color(0xFF1E1E1E),
        background: Color(0xFF121212),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1D1D1D),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardColor: const Color(0xFF1E1E1E),
      dialogBackgroundColor: const Color(0xFF1E1E1E),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: Colors.white),
        bodyMedium: TextStyle(color: Colors.white),
      ),
    );
  }
}

class SettingsSheet extends StatefulWidget {
  final List<double> initialDistances;
  final int initialMaxSpeed;
  final int initialRamp;
  final Function(List<double>, int, int) onSave;

  const SettingsSheet({
    super.key,
    required this.initialDistances,
    required this.initialMaxSpeed,
    required this.initialRamp,
    required this.onSave,
  });

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late final List<TextEditingController> _distanceControllers;
  late final TextEditingController _maxSpeedController;
  late final TextEditingController _rampController;

  @override
  void initState() {
    super.initState();
    _distanceControllers = List.generate(
      4,
      (index) => TextEditingController(
        text: widget.initialDistances[index].toStringAsFixed(0),
      ),
    );
    _maxSpeedController =
        TextEditingController(text: widget.initialMaxSpeed.toString());
    _rampController = TextEditingController(text: widget.initialRamp.toString());
  }

  @override
  void dispose() {
    for (final controller in _distanceControllers) {
      controller.dispose();
    }
    _maxSpeedController.dispose();
    _rampController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 56,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Ustawienia',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Dystansy',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: List.generate(4, (index) {
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: TextField(
                      controller: _distanceControllers[index],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'D${index + 1}',
                        labelStyle: const TextStyle(color: Colors.white70),
                        filled: true,
                        fillColor: const Color(0xFF262626),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 20),
            const Text(
              'Silnik',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _maxSpeedController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Maks. prędkość PWM (50-255)',
                labelStyle: const TextStyle(color: Colors.white70),
                filled: true,
                fillColor: const Color(0xFF262626),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _rampController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Rampa przysp./ham. (impulsy)',
                labelStyle: const TextStyle(color: Colors.white70),
                filled: true,
                fillColor: const Color(0xFF262626),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  final distances = List.generate(4, (index) {
                    final parsed = double.tryParse(_distanceControllers[index].text);
                    return parsed ?? 0.0;
                  });

                  final maxSpeed = int.tryParse(_maxSpeedController.text) ?? 200;
                  final ramp = int.tryParse(_rampController.text) ?? 60;

                  widget.onSave(distances, maxSpeed.clamp(50, 255), ramp);
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF3A6EA5),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'Zapisz ustawienia',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
