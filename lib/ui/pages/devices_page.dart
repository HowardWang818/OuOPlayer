import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/bluetooth/bluetooth_service.dart';
import '../../theme/app_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/output_device_chip.dart';

/// Android-only: current output, paired devices and discovery.
class DevicesPage extends ConsumerStatefulWidget {
  const DevicesPage({super.key});

  @override
  ConsumerState<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends ConsumerState<DevicesPage> {
  List<BtDevice> _bonded = [];
  final Map<String, BtDevice> _found = {};
  bool _scanning = false;
  bool _enabled = true;
  bool _granted = false;
  String? _busy;
  final _subs = <StreamSubscription>[];

  BluetoothService get _bt => ref.read(bluetoothProvider);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (!_bt.supported) return;
    _granted = await _bt.ensurePermissions();
    if (!_granted) {
      if (mounted) setState(() {});
      return;
    }
    _subs
      ..add(_bt.found.listen((d) {
        // Unnamed results are BLE beacons (phones, tags, watches), not headphones.
        if (d.name == d.address) return;
        if (!_bonded.any((b) => b.address == d.address)) setState(() => _found[d.address] = d);
      }))
      ..add(_bt.scanning.listen((v) => setState(() => _scanning = v)))
      ..add(_bt.bondChanged.listen((_) => _reload()));
    await _reload();
  }

  Future<void> _reload() async {
    final enabled = await _bt.isEnabled();
    final bonded = enabled ? await _bt.bondedDevices() : <BtDevice>[];
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _bonded = bonded;
      for (final b in bonded) {
        _found.remove(b.address);
      }
    });
  }

  Future<void> _scan() async {
    if (!await _bt.ensurePermissions(scan: true)) {
      if (mounted) toast(context, '需要附近裝置權限才能掃描');
      return;
    }
    setState(() => _found.clear());
    await _bt.startScan();
  }

  Future<void> _connect(BtDevice d) async {
    setState(() => _busy = d.address);
    try {
      bool ok;
      if (!d.bonded) {
        ok = await _bt.pair(d.address);
        if (mounted) toast(context, ok ? '正在與 ${d.name} 配對，請在系統視窗確認' : '無法配對');
      } else if (d.connected) {
        ok = await _bt.disconnect(d.address);
      } else {
        ok = await _bt.connect(d.address);
        if (!ok && mounted) {
          final open = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('無法直接連線'),
              content: Text('系統不允許此 App 直接連接 ${d.name}。要開啟系統藍牙設定嗎？'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('開啟設定')),
              ],
            ),
          );
          if (open == true) await _bt.openSettings();
        }
      }
    } finally {
      if (mounted) setState(() => _busy = null);
      Future.delayed(const Duration(seconds: 2), _reload);
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    if (_scanning) _bt.stopScan();
    super.dispose();
  }

  Widget _deviceTile(BtDevice d) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListTile(
      leading: Icon(d.audio ? Icons.headphones : Icons.bluetooth, color: d.connected ? AppColors.accent : muted),
      title: Text(d.name, style: TextStyle(color: d.connected ? AppColors.accent : null)),
      subtitle: Text(d.connected ? '已連線' : (d.bonded ? '已配對' : d.address), style: TextStyle(color: muted)),
      trailing: _busy == d.address
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          // Paired non-audio devices (bands, PCs) can't be an audio output.
          : d.bonded && !d.audio
              ? null
              : TextButton(onPressed: () => _connect(d), child: Text(!d.bonded ? '配對' : (d.connected ? '中斷連線' : '連線'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final out = ref.watch(outputDeviceProvider).value ?? OutputDevice.speaker;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget header(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(t, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: muted)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('連接到裝置'), actions: [
        IconButton(icon: const Icon(Icons.settings_bluetooth), tooltip: '系統藍牙設定', onPressed: _bt.openSettings),
      ]),
      body: !_bt.supported
          ? const Center(child: Text('此平台不支援藍牙裝置管理'))
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(children: [
                header('目前的裝置'),
                ListTile(
                  leading: Icon(outputIcon(out.kind), color: AppColors.accent, size: 32),
                  title: Text(out.name, style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold)),
                  subtitle: const Text('音訊輸出'),
                ),
                if (!_granted)
                  ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: const Text('需要「附近的裝置」權限'),
                    trailing: TextButton(onPressed: _init, child: const Text('授權')),
                  )
                else if (!_enabled)
                  ListTile(
                    leading: const Icon(Icons.bluetooth_disabled),
                    title: const Text('藍牙已關閉'),
                    trailing: TextButton(
                      onPressed: () async {
                        await _bt.requestEnable();
                        Future.delayed(const Duration(seconds: 2), _reload);
                      },
                      child: const Text('開啟'),
                    ),
                  )
                else ...[
                  header('已配對的裝置'),
                  if (_bonded.isEmpty) ListTile(title: Text('沒有已配對的裝置', style: TextStyle(color: muted))),
                  for (final d in _bonded) _deviceTile(d),
                  Row(children: [
                    Expanded(child: header('附近的裝置')),
                    Padding(
                      padding: const EdgeInsets.only(right: 8, top: 12),
                      child: _scanning
                          ? TextButton.icon(
                              onPressed: _bt.stopScan,
                              icon: const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                              label: const Text('停止'),
                            )
                          : TextButton.icon(onPressed: _scan, icon: const Icon(Icons.radar), label: const Text('掃描')),
                    ),
                  ]),
                  if (_found.isEmpty)
                    ListTile(title: Text(_scanning ? '搜尋中…' : '按「掃描」尋找附近的藍牙耳機或喇叭', style: TextStyle(color: muted))),
                  for (final d in _found.values) _deviceTile(d),
                ],
              ]),
            ),
    );
  }
}
