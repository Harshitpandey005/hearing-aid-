import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const svcUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const ctlUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
const lvlUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a9';
const bands = [250, 500, 1000, 2000, 4000, 6000];
String bandLabel(int f) => f >= 1000 ? '${f ~/ 1000} kHz' : '$f Hz';

const presets = <String, Map<String, dynamic>>{
  'Flat': {'nr': 20, 'low': 100, 'high': 7000, 'comp': 30, 'eq': [0, 0, 0, 0, 0, 0]},
  'Speech': {'nr': 40, 'low': 150, 'high': 7000, 'comp': 40, 'eq': [-4, -2, 2, 6, 8, 4]},
  'High-pitch loss': {'nr': 30, 'low': 100, 'high': 8000, 'comp': 50, 'eq': [0, 2, 6, 12, 18, 18]},
  'Noisy place': {'nr': 80, 'low': 300, 'high': 5000, 'comp': 60, 'eq': [-8, -4, 2, 6, 6, 0]},
  'Music': {'nr': 0, 'low': 60, 'high': 8000, 'comp': 20, 'eq': [2, 0, 0, 0, 2, 3]},
};

void main() => runApp(const HearingApp());

class HearingApp extends StatelessWidget {
  const HearingApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Hearing Aid',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF0B7A75), useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFF0B7A75), brightness: Brightness.dark, useMaterial3: true),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  BluetoothDevice? dev;
  BluetoothCharacteristic? ctl;
  StreamSubscription? lvSub, connSub;
  Timer? debounce;
  String status = 'Not connected';
  bool busy = false, mute = false;
  int level = 0;
  double gain = 0, limit = 100, nr = 20, low = 100, high = 7000, comp = 30;
  List<double> eq = List.filled(6, 0.0);

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    lvSub?.cancel();
    connSub?.cancel();
    debounce?.cancel();
    dev?.disconnect();
    super.dispose();
  }

  void applyMap(Map m) {
    gain = (m['gain'] ?? gain).toDouble();
    limit = (m['limit'] ?? limit).toDouble();
    nr = (m['nr'] ?? nr).toDouble();
    low = (m['low'] ?? low).toDouble();
    high = (m['high'] ?? high).toDouble();
    comp = (m['comp'] ?? comp).toDouble();
    if (m['eq'] != null) eq = List<double>.from((m['eq'] as List).map((e) => (e as num).toDouble()));
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString('settings');
    if (s == null) return;
    try {
      setState(() => applyMap(jsonDecode(s)));
    } catch (_) {}
  }

  Future<void> connect() async {
    setState(() {
      busy = true;
      status = 'Searching…';
    });
    try {
      await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        setState(() => status = 'Turn Bluetooth on, then try again.');
        return;
      }
      ScanResult? found;
      final sub = FlutterBluePlus.scanResults.listen((list) {
        if (list.isNotEmpty && found == null) {
          found = list.first;
          FlutterBluePlus.stopScan();
        }
      });
      await FlutterBluePlus.startScan(withNames: ['HearingAid-ESP32'], timeout: const Duration(seconds: 10));
      await FlutterBluePlus.isScanning.where((s) => !s).first;
      await sub.cancel();
      if (found == null) {
        setState(() => status = 'HearingAid-ESP32 not found. Is the ESP32 powered on?');
        return;
      }
      final d = found!.device;
      await d.connect();
      dev = d;
      connSub = d.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && mounted) {
          setState(() {
            ctl = null;
            status = 'Connection lost. Tap Connect to try again.';
          });
        }
      });
      final services = await d.discoverServices();
      final svc = services.firstWhere((s) => s.uuid == Guid(svcUuid));
      for (final c in svc.characteristics) {
        if (c.uuid == Guid(ctlUuid)) ctl = c;
        if (c.uuid == Guid(lvlUuid)) {
          await c.setNotifyValue(true);
          lvSub = c.onValueReceived.listen((v) {
            if (v.isNotEmpty && mounted) setState(() => level = v[0]);
          });
        }
      }
      setState(() => status = 'Connected to ${d.platformName}');
      await send();
    } catch (e) {
      setState(() => status = 'Not connected: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> disconnect() async {
    await dev?.disconnect();
  }

  void touch() {
    setState(() {});
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 60), send);
  }

  Future<void> send() async {
    final map = {'gain': gain, 'limit': limit, 'nr': nr, 'low': low, 'high': high, 'comp': comp, 'eq': eq};
    SharedPreferences.getInstance().then((p) => p.setString('settings', jsonEncode(map)));
    final c = ctl;
    if (c == null) return;
    final d = Uint8List(13);
    d[0] = mute ? 1 : 0;
    d[1] = gain.round();
    d[2] = limit.round();
    d[3] = nr.round();
    d[4] = (low / 10).round();
    d[5] = (high / 100).round();
    d[6] = comp.round();
    for (var i = 0; i < 6; i++) {
      d[7 + i] = eq[i].round() & 255;
    }
    try {
      await c.write(d, withoutResponse: true);
    } catch (e) {
      if (mounted) setState(() => status = 'Could not send settings: $e');
    }
  }

  Widget slider(String label, double v, double min, double max, int div, String Function(double) fmt,
      void Function(double) on, {String? hint}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(fmt(v)),
          ]),
          Slider(
              value: v.clamp(min, max),
              min: min,
              max: max,
              divisions: div,
              onChanged: (x) {
                on(x);
                touch();
              }),
          if (hint != null) Text(hint, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }

  Widget heading(String t) =>
      Padding(padding: const EdgeInsets.fromLTRB(4, 18, 4, 6), child: Text(t, style: Theme.of(context).textTheme.titleMedium));

  Future<void> hearingTestDialog() async {
    final cs = List.generate(6, (_) => TextEditingController());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Fit from my hearing test'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Enter your hearing loss in dB at each pitch (from an audiogram). '
                'The equalizer is set to about half of each loss. An audiologist’s fitting is more accurate.'),
            for (var i = 0; i < 6; i++)
              TextField(
                  controller: cs[i],
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: '${bandLabel(bands[i])} loss (dB)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
        ],
      ),
    );
    if (ok == true) {
      setState(() => eq = [for (final c in cs) ((double.tryParse(c.text) ?? 0) * 0.5).clamp(0, 24).roundToDouble()]);
      touch();
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = ctl != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Hearing aid')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Text(status, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        if (!connected)
          FilledButton(
              onPressed: busy ? null : connect,
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(busy ? 'Connecting…' : 'Connect to HearingAid-ESP32')))
        else ...[
          LinearProgressIndicator(value: level / 100, minHeight: 10),
          heading('Quick settings'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final n in presets.keys)
              ActionChip(
                  label: Text(n),
                  onPressed: () {
                    final m = presets[n]!;
                    setState(() => applyMap(m));
                    touch();
                  }),
          ]),
          heading('Volume'),
          slider('Volume boost', gain, 0, 30, 30, (v) => '+${v.round()} dB', (x) => gain = x,
              hint: 'Raise slowly. Stop if sound feels uncomfortable.'),
          slider('Maximum loudness', limit, 10, 160, 150, (v) => '${(v / 1.6).round()}%', (x) => limit = x,
              hint: 'Hard cap on the loudest sound sent to the earbuds.'),
          slider('Loud-sound comfort', comp, 0, 100, 20, (v) => '${v.round()}%', (x) => comp = x,
              hint: 'Softens sudden loud sounds.'),
          heading('Noise reduction'),
          slider('Reduce background noise', nr, 0, 100, 20, (v) => v == 0 ? 'Off' : '${v.round()}%', (x) => nr = x,
              hint: 'Too high can cut soft speech.'),
          heading('Frequency range'),
          slider('Cut low rumble below', low, 50, 1000, 95, (v) => '${v.round()} Hz', (x) => low = x),
          slider('Cut high hiss above', high, 2000, 8000, 60, (v) => '${(v / 1000).toStringAsFixed(1)} kHz', (x) => high = x),
          heading('Equalizer'),
          for (var i = 0; i < 6; i++)
            slider(bandLabel(bands[i]), eq[i], -12, 24, 36, (v) => '${v > 0 ? '+' : ''}${v.round()} dB',
                (x) => eq[i] = x),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: hearingTestDialog, child: const Text('Fit from my hearing test')),
          const SizedBox(height: 12),
          FilledButton.tonal(
              onPressed: () {
                setState(() => mute = !mute);
                touch();
              },
              child: Text(mute ? 'Unmute' : 'Mute')),
          TextButton(onPressed: disconnect, child: const Text('Disconnect')),
        ],
        const SizedBox(height: 20),
        Text('Hobby prototype, not a medical device. Keep volume low at first.',
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
