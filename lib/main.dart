import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'mirror_server.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PhoneWebMirrorApp());
}

class PhoneWebMirrorApp extends StatelessWidget {
  const PhoneWebMirrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phone Web Mirror',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2F6FED),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _method = MethodChannel('phone_web_mirror/capture');
  static const _frames = EventChannel('phone_web_mirror/frames');

  final _server = MirrorServer();
  StreamSubscription? _frameSub;
  String? _ip;
  String _status = 'Tap Start mirror';
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _refreshIp();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  Future<void> _refreshIp() async {
    final ip = await _localIp();
    if (!mounted) return;
    setState(() => _ip = ip);
  }

  Future<String?> _localIp() async {
    try {
      String? preferred;
      String? anyLan;
      for (final iface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      )) {
        for (final a in iface.addresses) {
          if (a.isLoopback) continue;
          final v = a.address;
          if (v.startsWith('192.168.') ||
              v.startsWith('10.') ||
              RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.').hasMatch(v)) {
            preferred ??= v;
            if (iface.name.toLowerCase().contains('wlan') ||
                iface.name.toLowerCase().contains('wifi') ||
                iface.name.toLowerCase().contains('ap')) {
              return v;
            }
            anyLan ??= v;
          }
        }
      }
      return preferred ?? anyLan;
    } catch (_) {
      return null;
    }
  }

  String get _url => 'https://${_ip ?? '…'}:8443';

  Future<void> _start() async {
    await _refreshIp();
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
    if (await Permission.microphone.isDenied) {
      await Permission.microphone.request();
    }
    setState(() => _status = 'Starting server…');
    try {
      _server.onStatus = (m) {
        if (mounted) setState(() => _status = m);
      };
      await _server.start();
      _frameSub?.cancel();
      _frameSub = _frames.receiveBroadcastStream().listen((event) {
        if (event is Uint8List) {
          _server.broadcast(event);
        } else if (event is List<int>) {
          _server.broadcast(Uint8List.fromList(event));
        }
      });
      setState(() => _status = 'Allow screen capture…');
      await _method.invokeMethod('startCast');
      await WakelockPlus.enable();
      setState(() {
        _running = true;
        _status = 'Live — open this on laptop Chrome/Edge:\n$_url';
      });
    } on PlatformException catch (e) {
      await _server.stop();
      setState(() {
        _running = false;
        _status = e.message ?? e.code;
      });
    } catch (e) {
      await _server.stop();
      setState(() {
        _running = false;
        _status = '$e';
      });
    }
  }

  Future<void> _stop() async {
    try {
      await _method.invokeMethod('stopCast');
    } catch (_) {}
    await _frameSub?.cancel();
    _frameSub = null;
    await _server.stop();
    await WakelockPlus.disable();
    if (mounted) {
      setState(() {
        _running = false;
        _status = 'Stopped';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF101820), Color(0xFF1B2A41), Color(0xFF101820)],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 28),
            children: [
              const Text(
                'Phone Web Mirror',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                'No Windows EXE. Open the address below in a laptop browser.',
                style: TextStyle(
                  fontSize: 15,
                  height: 1.35,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'On laptop Chrome/Edge type (must be https):',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _url,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF7EC8FF),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Certificate warning → Advanced → Proceed to site',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.orange.shade200,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _status,
                      style: TextStyle(
                        height: 1.35,
                        color: _running
                            ? const Color(0xFF3DD68C)
                            : Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                    if (_ip == null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'No WiFi IP — connect this device to WiFi.',
                        style: TextStyle(color: Colors.orange.shade200),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _running ? null : _start,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                child: const Text('Start mirror'),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _running ? _stop : _refreshIp,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      child: Text(_running ? 'Stop' : 'Refresh IP'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Text(
                'How to use',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: 0.92),
                ),
              ),
              const SizedBox(height: 10),
              _step('1', 'Install this APK on phone or Android TV.'),
              _step('2', 'Tap Start mirror → allow screen capture.'),
              _step('3', 'Open https://IP:8443 — if Chrome warns, Advanced → Proceed.'),
              _step('4', 'Fullscreen / Record in the browser (no Windows EXE).'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _step(String n, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF2F6FED).withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(n, style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                height: 1.4,
                color: Colors.white.withValues(alpha: 0.78),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
