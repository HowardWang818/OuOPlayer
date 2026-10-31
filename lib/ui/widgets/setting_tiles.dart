import 'dart:io';

import 'package:flutter/material.dart';

/// Windows: the rounded small button on the right of a settings row.
class SettingButton extends StatelessWidget {
  const SettingButton(this.label, {super.key, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return OutlinedButton(
      onPressed: onPressed,
      style: ButtonStyle(
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
        visualDensity: VisualDensity.compact,
        textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? cs.onSurfaceVariant : cs.onSurface),
        side: WidgetStateProperty.resolveWith((s) => BorderSide(color: s.contains(WidgetState.hovered) ? cs.onSurface : cs.onSurfaceVariant)),
      ),
      child: Text(label),
    );
  }
}

/// A settings row: tapped anywhere on the phone. On Windows the row itself
/// doesn't react; a button on its right ([action]) does what tapping did.
class SettingTile extends StatelessWidget {
  const SettingTile({super.key, this.leading, this.title, this.subtitle, this.trailing, this.onTap, this.action, this.enabled = true, this.isThreeLine = false});
  final Widget? leading, title, subtitle, trailing;
  final VoidCallback? onTap;
  final String? action;
  final bool enabled, isThreeLine;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) {
      return ListTile(leading: leading, title: title, subtitle: subtitle, trailing: trailing, onTap: onTap, enabled: enabled, isThreeLine: isThreeLine);
    }
    final keep = trailing is Icon ? null : trailing;
    // A row with its own button in [trailing] needs no second one.
    final label = action ?? (onTap != null && keep == null ? '開啟' : null);
    final button = label == null ? null : SettingButton(label, onPressed: enabled ? onTap : null);
    return ListTile(
      leading: leading,
      title: title,
      subtitle: subtitle,
      isThreeLine: isThreeLine,
      trailing: keep != null && button != null ? Row(mainAxisSize: MainAxisSize.min, children: [keep, const SizedBox(width: 8), button]) : (button ?? keep),
    );
  }
}

/// A switch in the settings. On Windows only the switch itself reacts.
class SettingSwitch extends StatelessWidget {
  const SettingSwitch({super.key, this.secondary, this.title, this.subtitle, required this.value, required this.onChanged});
  final Widget? secondary, title, subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Platform.isWindows
      ? ListTile(leading: secondary, title: title, subtitle: subtitle, trailing: Switch(value: value, onChanged: onChanged))
      : SwitchListTile(secondary: secondary, title: title, subtitle: subtitle, value: value, onChanged: onChanged);
}

/// A tick box in the settings. On Windows only the box itself reacts.
class SettingCheck extends StatelessWidget {
  const SettingCheck({super.key, this.secondary, this.title, required this.value, required this.onChanged});
  final Widget? secondary, title;
  final bool value;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) => Platform.isWindows
      ? ListTile(leading: secondary, title: title, trailing: Checkbox(value: value, onChanged: onChanged))
      : CheckboxListTile(secondary: secondary, title: title, value: value, onChanged: onChanged);
}
