package com.privatedeploy.mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * MainActivity for PrivateDeploy
 *
 * 主 Activity，负责注册平台插件
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 注册 VPN Plugin
        flutterEngine.plugins.add(VpnPlugin())
    }
}
