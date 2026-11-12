import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 不受省電限制 (Android): off the battery optimisation list, so power saving
/// doesn't cut the network in the background — sync and 接續播放 then reach
/// Drive while the screen is off. Re-checks when the user comes back.
class PowerTile extends StatefulWidget {
  const PowerTile({super.key});

  static const _ch = MethodChannel('ouo/power');

  static Future<bool> unrestricted() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _ch.invokeMethod<bool>('unrestricted') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  State<PowerTile> createState() => _PowerTileState();
}

class _PowerTileState extends State<PowerTile> {
  late final AppLifecycleListener _lifecycle;
  bool? _on;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _check);
    _check();
  }

  Future<void> _check() async {
    final v = await PowerTile.unrestricted();
    if (mounted) setState(() => _on = v);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(_on == true ? Icons.battery_charging_full_rounded : Icons.battery_saver_outlined),
        title: const Text('不受省電限制'),
        subtitle: _on == null ? null : Text(_on! ? '已開啟' : '開啟後，省電模式下仍可在背景同步與接續播放'),
        trailing: Icon(_on == true ? Icons.check_circle : Icons.open_in_new),
        onTap: _on == true ? null : () => PowerTile._ch.invokeMethod('ask').catchError((_) => null),
      );
}
