import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dialogs.dart';

/// Opens [url] in the matching app (Apple Music, store…) or the browser.
Future<void> openExternal(BuildContext context, String url) async {
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).catchError((_) => false);
  if (!ok && context.mounted) toast(context, '無法開啟連結');
}
