import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class OutputDevice {
  final String name;
  final String kind; // speaker | wired | bluetooth | usb | other
  const OutputDevice(this.name, this.kind);
  static const speaker = OutputDevice('這台裝置', 'speaker');
}

class BtDevice {
  final String name;
  final String address;
  final bool bonded;
  final bool connected;
  final bool audio;
  const BtDevice({required this.name, required this.address, this.bonded = false, this.connected = false, this.audio = true});

  factory BtDevice.fromMap(Map m) => BtDevice(
        name: (m['name'] as String?)?.isNotEmpty == true ? m['name'] as String : (m['address'] as String),
        address: m['address'] as String,
        bonded: m['bonded'] == true,
        connected: m['connected'] == true,
        audio: m['audio'] != false,
      );
}

/// Android-only bridge to BluetoothPlugin.kt. On other platforms every call is a no-op.
class BluetoothService {
  static const _method = MethodChannel('ouo/bluetooth');
  static const _events = EventChannel('ouo/bluetooth/events');

  bool get supported => Platform.isAndroid;

  Stream<Map>? _stream;
  Stream<Map> get events => supported ? (_stream ??= _events.receiveBroadcastStream().cast<Map>().asBroadcastStream()) : const Stream.empty();

  Stream<OutputDevice> get outputDevice =>
      events.where((e) => e['type'] == 'output').map((e) => OutputDevice(e['name'] as String? ?? '', e['kind'] as String? ?? 'other'));

  /// Fires when a Bluetooth audio device finishes connecting (A2DP).
  Stream<BtDevice> get audioConnected =>
      events.where((e) => e['type'] == 'a2dp' && e['connected'] == true).map(BtDevice.fromMap);

  Stream<BtDevice> get found => events.where((e) => e['type'] == 'found').map(BtDevice.fromMap);

  Stream<bool> get scanning => events.where((e) => e['type'] == 'scan').map((e) => e['running'] == true);

  Stream<void> get bondChanged => events.where((e) => e['type'] == 'bond' || e['type'] == 'a2dp');

  Future<bool> ensurePermissions({bool scan = false}) async {
    if (!supported) return false;
    final perms = [Permission.bluetoothConnect, if (scan) Permission.bluetoothScan, if (scan) Permission.locationWhenInUse];
    final res = await perms.request();
    return res[Permission.bluetoothConnect]?.isGranted != false;
  }

  Future<OutputDevice> currentOutput() async {
    if (!supported) return OutputDevice.speaker;
    final m = await _method.invokeMethod<Map>('currentOutput');
    if (m == null) return OutputDevice.speaker;
    return OutputDevice(m['name'] as String? ?? '', m['kind'] as String? ?? 'speaker');
  }

  Future<bool> isEnabled() async => supported && ((await _method.invokeMethod<bool>('isEnabled')) ?? false);

  Future<void> requestEnable() => _method.invokeMethod('requestEnable');

  Future<List<BtDevice>> bondedDevices() async {
    if (!supported) return [];
    final list = await _method.invokeMethod<List>('bondedDevices') ?? [];
    return list.cast<Map>().map(BtDevice.fromMap).toList();
  }

  Future<void> startScan() => _method.invokeMethod('startScan');
  Future<void> stopScan() => _method.invokeMethod('stopScan');
  Future<bool> pair(String address) async => (await _method.invokeMethod<bool>('pair', {'address': address})) ?? false;

  /// Connect an A2DP audio device. Returns false if the system refused, in which
  /// case the UI offers to open the system Bluetooth settings.
  Future<bool> connect(String address) async => (await _method.invokeMethod<bool>('connect', {'address': address})) ?? false;
  Future<bool> disconnect(String address) async => (await _method.invokeMethod<bool>('disconnect', {'address': address})) ?? false;
  Future<void> openSettings() => _method.invokeMethod('openSettings');
}
