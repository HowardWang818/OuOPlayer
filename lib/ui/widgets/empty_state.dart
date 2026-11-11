import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

/// The one look for "nothing here" and "something went wrong": an icon in
/// the theme colour, a short title, an optional line of help and button.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action, this.onAction, this.compact = false});

  /// Couldn't load: the reason in plain words ([friendlyError]) and 重試.
  factory EmptyState.error(Object error, {VoidCallback? onRetry, bool compact = false}) => EmptyState(
        icon: isOffline(error) ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
        title: isOffline(error) ? '無網路連線' : friendlyError(error),
        action: onRetry == null ? null : '重試',
        onAction: onRetry,
        compact: compact,
      );

  final IconData icon;
  final String title;
  final String? message;
  final String? action;
  final VoidCallback? onAction;

  /// Smaller, for side panels and short lists.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(compact ? 16 : 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: compact ? 56 : 80,
            height: compact ? 56 : 80,
            decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Icon(icon, size: compact ? 28 : 40, color: cs.primary),
          ),
          SizedBox(height: compact ? 10 : 16),
          Text(title, textAlign: TextAlign.center, style: (compact ? t.titleSmall : t.titleMedium)?.copyWith(fontWeight: FontWeight.w600)),
          if (message != null) ...[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(message!, textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.4)),
            ),
          ],
          if (action != null && onAction != null) ...[
            SizedBox(height: compact ? 10 : 16),
            FilledButton.tonal(onPressed: onAction, child: Text(action!)),
          ],
        ]),
      ),
    );
  }
}

/// No connection (rather than a server or program error).
bool isOffline(Object e) =>
    e is SocketException ||
    e is TimeoutException ||
    (e is DioException &&
        (e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.error is SocketException));

/// An error in words a listener understands.
String friendlyError(Object e) {
  if (isOffline(e)) return '無網路連線';
  if (e is DioException) {
    final code = e.response?.statusCode;
    if (code == 404) return '找不到項目';
    if (code == 429) return '請稍後再試';
    if (code != null && code >= 500) return '請稍後再試';
    return '連線失敗，請稍後再試';
  }
  return '發生錯誤';
}
