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
                    "getColorCapabilities" -> {
                        val cameraName = call.argument<String>("cameraName")
                        result.success(readColorCapabilities(cameraName))
                    }
                    "getColorCalibration" -> {
                        val cameraName = call.argument<String>("cameraName")
                        result.success(readColorCalibration(cameraName))
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

    /// Reports what colour control this camera actually allows.
    ///
    /// Whether the white-balance problem can be solved properly depends
    /// entirely on facts only the device can answer: manual white balance needs
    /// AWB to be switchable off, and reading back the AWB gains needs the
    /// camera to be at least FULL hardware level. Both are read from static
    /// characteristics, so no capture session has to be opened.
    private fun readColorCapabilities(cameraName: String?): Map<String, Any?> {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = resolveCameraId(manager, cameraName)
            ?: return mapOf("error" to "no camera")
        val chars = manager.getCameraCharacteristics(id)

        val hardwareLevel = chars.get(
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL,
        )
        val awbModes = chars.get(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES)
            ?.toList()
            ?: emptyList()

        // The keys that would have to be readable per frame to recover the
        // illuminant without a user-supplied reference.
        val resultKeys = chars.availableCaptureResultKeys.map { it.name }
        val requestKeys = chars.availableCaptureRequestKeys.map { it.name }

        return hashMapOf(
            "cameraId" to id,
            "hardwareLevel" to hardwareLevel,
            "hardwareLevelName" to when (hardwareLevel) {
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "LEGACY"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "LIMITED"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "FULL"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "LEVEL_3"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "EXTERNAL"
                else -> "UNKNOWN"
            },
            "awbModes" to awbModes,
            // AWB_MODE_OFF == 0; without it, manual white balance is impossible
            // and the reference-patch approach is the only option.
            "canDisableAwb" to awbModes.contains(0),
            "canReadAwbGains" to
                resultKeys.contains("android.colorCorrection.gains"),
            "canReadColorTransform" to
                resultKeys.contains("android.colorCorrection.transform"),
            "canSetAwbMode" to
                requestKeys.contains("android.control.awbMode"),
            "canSetAwbGains" to
                requestKeys.contains("android.colorCorrection.gains"),
            "canReadNeutralPoint" to
                resultKeys.contains("android.sensor.neutralColorPoint"),
            "canReadGreenSplit" to
                resultKeys.contains("android.sensor.greenSplit"),
        )
    }

    /// Reads the sensor's DNG colour calibration.
    ///
    /// `SENSOR_NEUTRAL_COLOR_POINT` — the only white point the ISP reports that
    /// auto white balance has not already divided out — lives in the sensor's own
    /// raw space. Turning it into a colour temperature needs the matrices that
    /// map that space to CIE XYZ, which is what these keys carry. They are
    /// static characteristics, so this needs no capture session.
    ///
    /// Returns null when the sensor does not publish a calibration, which is
    /// common on LIMITED-level devices; the caller then has no way to interpret a
    /// raw white point and must fall back.
    private fun readColorCalibration(cameraName: String?): Map<String, Any?>? {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = resolveCameraId(manager, cameraName) ?: return null
        val chars = manager.getCameraCharacteristics(id)

        // Both illuminants and both colour transforms are required: the
        // conversion interpolates between them, so a single one is not enough.
        val illuminant1 = chars.get(CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT1)
            ?: return null
        val illuminant2 = chars.get(CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT2)
            ?: return null
        val colorTransform1 = chars.get(CameraCharacteristics.SENSOR_COLOR_TRANSFORM1)
            ?: return null
        val colorTransform2 = chars.get(CameraCharacteristics.SENSOR_COLOR_TRANSFORM2)
            ?: return null
        val calibration1 = chars.get(CameraCharacteristics.SENSOR_CALIBRATION_TRANSFORM1)
            ?: return null
        val calibration2 = chars.get(CameraCharacteristics.SENSOR_CALIBRATION_TRANSFORM2)
            ?: return null

        return hashMapOf(
            "cameraId" to id,
            // ColorSpaceTransform stores rationals; flatten row-major to doubles
            // so the Dart side does not have to know the Android type.
            "referenceIlluminant1" to illuminant1,
            "referenceIlluminant2" to illuminant2.toInt(),
            "colorTransform1" to flatten(colorTransform1),
            "colorTransform2" to flatten(colorTransform2),
            "calibrationTransform1" to flatten(calibration1),
            "calibrationTransform2" to flatten(calibration2),
            "forwardMatrix1" to
                chars.get(CameraCharacteristics.SENSOR_FORWARD_MATRIX1)?.let { flatten(it) },
            "forwardMatrix2" to
                chars.get(CameraCharacteristics.SENSOR_FORWARD_MATRIX2)?.let { flatten(it) },
        )
    }

    /// Flattens a 3×3 [ColorSpaceTransform] to nine doubles, row-major.
    private fun flatten(transform: android.hardware.camera2.params.ColorSpaceTransform): DoubleArray {
        val out = DoubleArray(9)
        for (row in 0 until 3) {
            for (col in 0 until 3) {
                val element = transform.getElement(col, row)
                val denominator = element.denominator
                out[row * 3 + col] =
                    if (denominator == 0) 0.0
                    else element.numerator.toDouble() / denominator.toDouble()
            }
        }
        return out
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
