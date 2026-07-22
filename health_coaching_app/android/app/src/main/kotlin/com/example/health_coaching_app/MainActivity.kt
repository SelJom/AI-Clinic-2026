package com.example.health_coaching_app

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity (not FlutterActivity) is required by the `health`
// plugin's Health Connect permissions-rationale flow on Android 14+ - see
// the "Wiring HealthService to real device data" note in the main README.
class MainActivity : FlutterFragmentActivity()
