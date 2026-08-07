package com.example.aperture_diary

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.sqrt

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

        // Prefer the primary wide lens, not the ultra-wide: taking the shortest
        // focal overstates the preview FOV and makes every simulation too wide.
        val primaryFocal = selectPrimaryFocal(focals, sensorWidth, sensorHeight)
            ?: return null

        var equivalent35: Double? = null
        if (sensorWidth != null && sensorHeight != null && primaryFocal > 0) {
            // Diagonal crop factor vs full-frame (43.27 mm), matching EXIF /
            // FocalLengthIn35mmFilm and the Dart FilmOptics helper.
            val diagonal = sqrt(
                sensorWidth * sensorWidth + sensorHeight * sensorHeight,
            )
            val fullFrameDiagonal = 43.266615
            if (diagonal > 0) {
                equivalent35 = primaryFocal * fullFrameDiagonal / diagonal
            }
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

    /// Picks the main (≈24–30 mm-eq) wide focal when a camera lists several.
    private fun selectPrimaryFocal(
        focals: List<Double>,
        sensorWidth: Double?,
        sensorHeight: Double?,
    ): Double? {
        val positive = focals.filter { it > 0 }.sorted()
        if (positive.isEmpty()) return null
        if (positive.size == 1) return positive.first()

        if (sensorWidth != null && sensorHeight != null && sensorWidth > 0 && sensorHeight > 0) {
            val diagonal = sqrt(sensorWidth * sensorWidth + sensorHeight * sensorHeight)
            val fullFrameDiagonal = 43.266615
            // Prefer the focal whose 35 mm-eq is closest to a "normal wide" 26 mm.
            return positive.minBy { focal ->
                val eq = focal * fullFrameDiagonal / diagonal
                kotlin.math.abs(eq - 26.0)
            }
        }

        // No sensor size: skip the shortest (often UW) when multiple exist.
        return positive.getOrElse(1) { positive.first() }
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
