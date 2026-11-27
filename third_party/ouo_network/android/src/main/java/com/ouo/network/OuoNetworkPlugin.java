package com.ouo.network;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Whether the phone is on mobile data, and its model. Needs no activity. */
public class OuoNetworkPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private MethodChannel channel;
    private Context context;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "ouo/network");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        if (call.method.equals("model")) {
            result.success(android.os.Build.MODEL);
            return;
        }
        if (!call.method.equals("mobileData")) {
            result.notImplemented();
            return;
        }
        ConnectivityManager cm = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (cm == null) {
            result.success(null);
            return;
        }
        try {
            NetworkCapabilities caps = cm.getNetworkCapabilities(cm.getActiveNetwork());
            result.success(caps != null
                    && caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
                    && !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                    && !caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET));
        } catch (RuntimeException e) {
            result.success(null);
        }
    }
}
