package com.ouo.ouoplayer

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * In-app updates: which APK fits this phone, whether OuOPlayer may install
 * apps (「安裝不明應用程式」), and handing a downloaded APK to Android's installer.
 */
class UpdatePlugin(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    init {
        MethodChannel(messenger, "ouo/update").setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "abis" -> result.success(Build.SUPPORTED_ABIS.toList())
            // Split APKs add 1000 × ABI to the build number; Dart takes it modulo 1000.
            "version" -> {
                val info = context.packageManager.getPackageInfo(context.packageName, 0)
                @Suppress("DEPRECATION")
                val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()
                result.success(mapOf("name" to info.versionName, "code" to code))
            }
            "canInstall" -> result.success(
                Build.VERSION.SDK_INT < Build.VERSION_CODES.O || context.packageManager.canRequestPackageInstalls(),
            )
            "openInstallSettings" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return result.success(false)
                val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    context.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("settings", e.message, null)
                }
            }
            "install" -> {
                val path = call.argument<String>("path") ?: return result.error("args", "path missing", null)
                try {
                    val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", File(path))
                    val intent = Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("install", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }
}
