package com.example.aperture_diary

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.atan
import kotlin.math.tan

class MainActivity : FlutterActivity() {
    private val channelName = "com.example.aperture_diary/lens"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getLensInfo" -> {
                        val cameraName = call.argument<String>("cameraName")
                        val info = readLensInfo(cameraName)
                        if (info == null) {
                            result.success(null)
                        } else {
                            result.success(info)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun readLensInfo(cameraName: String?): Map<String, Any?>? {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = resolveCameraId(manager, cameraName) ?: return null
        val chars = manager.getCameraCharacteristics(id)

        val focals =
            chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                ?.map { it.toDouble() }
                ?: emptyList()

        val sensor = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val sensorWidth = sensor?.width?.toDouble()
        val sensorHeight = sensor?.height?.toDouble()

        val primaryFocal = focals.minOrNull()
            ?: focals.firstOrNull()
            ?: return null

        var equivalent35: Double? = null
        if (sensorWidth != null && sensorHeight != null && primaryFocal > 0) {
            // Match the shorter side to a square crop, then express as 35 mm-eq
            // via diagonal FOV against full-frame.
            val short = minOf(sensorWidth, sensorHeight)
            val phoneFov = 2.0 * atan((short / 2.0) / primaryFocal)
            // Full-frame short side is 24 mm.
            equivalent35 = (24.0 / 2.0) / tan(phoneFov / 2.0)
        }

        return hashMapOf(
            "focalLengthsMm" to focals,
            "focalLengthMm" to primaryFocal,
            "sensorWidthMm" to sensorWidth,
            "sensorHeightMm" to sensorHeight,
            "equivalent35mm" to equivalent35,
            "cameraId" to id,
            "api" to Build.VERSION.SDK_INT,
        )
    }

    private fun resolveCameraId(manager: CameraManager, cameraName: String?): String? {
        val ids = manager.cameraIdList
        if (ids.isEmpty()) return null

        // Flutter's CameraDescription.name is typically the Camera2 id on Android.
        if (cameraName != null && ids.contains(cameraName)) {
            return cameraName
        }

        for (id in ids) {
            val facing = manager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING)
            if (facing == CameraCharacteristics.LENS_FACING_BACK) {
                return id
            }
        }
        return ids.first()
    }
}
