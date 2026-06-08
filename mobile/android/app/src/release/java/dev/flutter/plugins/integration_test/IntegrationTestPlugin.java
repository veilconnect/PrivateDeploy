// Release-only stub. Flutter 3.35.7's tool generates an unconditional
// registerWith() call for integration_test even though it is marked
// dev_dependency=true and excluded from the release classpath by the
// Flutter Gradle plugin. Provide a no-op stub so release builds compile;
// debug builds pick up the real plugin from the integration_test package.
package dev.flutter.plugins.integration_test;

import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;

public final class IntegrationTestPlugin implements FlutterPlugin {
    @Override
    public void onAttachedToEngine(@NonNull FlutterPlugin.FlutterPluginBinding binding) {}

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPlugin.FlutterPluginBinding binding) {}
}
