// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraMetadata;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.CaptureResult;
import android.hardware.camera2.TotalCaptureResult;
import android.hardware.camera2.params.RggbChannelVector;
import android.os.SystemClock;
import android.util.Log;
import android.util.Rational;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;
import java.util.HashMap;
import java.util.Map;

/**
 * Streams per-frame Camera2 capture metadata to Dart.
 *
 * <p>CameraX does not surface the underlying {@link CaptureResult}, so the exposure and colour
 * decisions the camera made for a frame are not otherwise reachable. Two measurements need them:
 *
 * <ul>
 *   <li><b>Exposure.</b> Reading exposure from a still capture instead means the numbers describe a
 *       different pipeline from the pixels being sampled — stills go through HDR and multi-frame
 *       processing the preview stream does not. Taking both from the preview removes that mismatch,
 *       and removes the need to take a photograph just to meter.
 *   <li><b>Colour.</b> {@code SENSOR_NEUTRAL_COLOR_POINT} is the white point the ISP settled on, in
 *       raw sensor space. Unlike the rendered pixels it is unaffected by auto white balance, so it
 *       describes the illuminant rather than what is left once the illuminant was divided out.
 * </ul>
 *
 * <p>The metadata is taken from a {@link CameraCaptureSession.CaptureCallback} attached to the
 * Preview use case through {@code Camera2Interop}. An earlier attempt read it from analysed frames
 * instead, via {@code CameraCaptureResults.retrieveCameraCaptureResult}; that returns null here,
 * because the {@code ImageInfo} CameraX attaches to analysis output is an {@code
 * ImmutableImageInfo}, which carries no capture result. Only {@code CameraCaptureResultImageInfo}
 * does, and analysis does not produce one. The interop callback is both supported API and the only
 * thing that actually works.
 *
 * <p>Delivery is best-effort and lossy by design: metering is not frame-accurate, and dropping an
 * update is preferable to holding up the camera's callback thread.
 */
final class CaptureMetadataBroadcaster {
  private static final String TAG = "CaptureMetadata";

  static final String CHANNEL_NAME =
      "plugins.flutter.io/camera_android_camerax/capture_metadata";

  /**
   * Synchronous handshake channel.
   *
   * <p>Needed to tell two very different failures apart: this class never being constructed, versus
   * it being constructed but unable to report anything. A method call either returns or throws
   * {@code MissingPluginException}, which settles the question — unlike a log line on a ROM that
   * filters logging, or a file write that can fail for its own reasons.
   */
  static final String PROBE_CHANNEL_NAME =
      "plugins.flutter.io/camera_android_camerax/capture_metadata_probe";

  /** Bumped whenever the fork's behaviour changes, so the app can tell versions apart. */
  private static final int FORK_REVISION = 2;

  /**
   * Trace file, written alongside the app's other diagnostics.
   *
   * <p>Some vendor ROMs — vivo's among them — drop third-party {@code Log} output entirely, so
   * logcat cannot show whether this path works. The file is a convenience; {@link
   * #PROBE_CHANNEL_NAME} is the authoritative signal.
   */
  private static final String TRACE_PATH =
      "/sdcard/Download/ApertureDiary/capture_metadata_trace.txt";

  /**
   * Minimum gap between events.
   *
   * <p>Capture results arrive at preview rate. Forwarding every one would cost far more in channel
   * traffic than metering can use, so updates are thinned to roughly 10 Hz — still several times
   * faster than a user can re-aim.
   */
  private static final long MIN_INTERVAL_MS = 100;

  @Nullable private volatile EventChannel.EventSink sink;
  private long lastSentUptimeMs;

  /** Capture results seen, whether or not anything was published. */
  private volatile long resultsSeen;

  /** Events actually delivered to Dart. */
  private volatile long publishedCount;

  /** Most recent failure, kept for the probe to report. */
  @Nullable private volatile String lastError;

  private boolean tracedFirstResult;
  private boolean tracedFirstSend;
  private boolean tracedNoKeys;

  @NonNull private final ProxyApiRegistrar registrar;

  @NonNull
  private final CameraCaptureSession.CaptureCallback sessionCaptureCallback =
      new CameraCaptureSession.CaptureCallback() {
        @Override
        public void onCaptureCompleted(
            @NonNull CameraCaptureSession session,
            @NonNull CaptureRequest request,
            @NonNull TotalCaptureResult result) {
          onCaptureResult(result);
        }
      };

  CaptureMetadataBroadcaster(
      @NonNull BinaryMessenger binaryMessenger, @NonNull ProxyApiRegistrar registrar) {
    this.registrar = registrar;
    trace("registered channel " + CHANNEL_NAME);

    new EventChannel(binaryMessenger, CHANNEL_NAME)
        .setStreamHandler(
            new EventChannel.StreamHandler() {
              @Override
              public void onListen(Object arguments, EventChannel.EventSink events) {
                trace("dart attached");
                sink = events;
              }

              @Override
              public void onCancel(Object arguments) {
                trace("dart detached");
                sink = null;
              }
            });

    new MethodChannel(binaryMessenger, PROBE_CHANNEL_NAME)
        .setMethodCallHandler(
            (call, result) -> {
              if ("status".equals(call.method)) {
                final Map<String, Object> status = new HashMap<>();
                status.put("forkRevision", FORK_REVISION);
                status.put("resultsSeen", resultsSeen);
                status.put("publishedCount", publishedCount);
                status.put("hasListener", sink != null);
                if (lastError != null) {
                  status.put("lastError", lastError);
                }
                result.success(status);
              } else {
                result.notImplemented();
              }
            });
  }

  /** The callback to hand to {@code Camera2Interop.Extender.setSessionCaptureCallback}. */
  @NonNull
  CameraCaptureSession.CaptureCallback getSessionCaptureCallback() {
    return sessionCaptureCallback;
  }

  /**
   * Publishes metadata for one capture result.
   *
   * <p>Called on a camera thread, so the hop to the main thread is required before touching the
   * channel.
   */
  private void onCaptureResult(@NonNull TotalCaptureResult result) {
    resultsSeen++;
    if (!tracedFirstResult) {
      tracedFirstResult = true;
      trace("first capture result");
    }

    if (sink == null) {
      return;
    }

    final long now = SystemClock.uptimeMillis();
    if (now - lastSentUptimeMs < MIN_INTERVAL_MS) {
      return;
    }

    final Map<String, Object> payload;
    try {
      payload = describe(result);
    } catch (Throwable throwable) {
      lastError = throwable.getClass().getSimpleName() + ": " + throwable.getMessage();
      trace("describe failed: " + throwable);
      return;
    }

    if (payload.isEmpty()) {
      if (!tracedNoKeys) {
        tracedNoKeys = true;
        lastError = "capture result carried none of the wanted keys";
        trace(lastError);
      }
      return;
    }

    lastSentUptimeMs = now;

    if (!tracedFirstSend) {
      tracedFirstSend = true;
      trace("publishing; keys=" + payload.keySet());
    }

    registrar.runOnMainThread(
        new ProxyApiRegistrar.FlutterMethodRunnable() {
          @Override
          public void run() {
            final EventChannel.EventSink target = sink;
            if (target == null) {
              return;
            }
            publishedCount++;
            target.success(payload);
          }
        });
  }

  /** Appends a diagnostic line to logcat and to the trace file. */
  private static void trace(@NonNull String message) {
    Log.i(TAG, message);
    try {
      final java.io.File file = new java.io.File(TRACE_PATH);
      final java.io.File parent = file.getParentFile();
      if (parent != null && !parent.exists() && !parent.mkdirs()) {
        return;
      }
      try (java.io.FileWriter writer = new java.io.FileWriter(file, true)) {
        writer.write(System.currentTimeMillis() + " " + message + "\n");
      }
    } catch (Throwable ignored) {
      // Tracing must never affect the camera path.
    }
  }

  /** Copies the keys metering needs into a channel-safe map, skipping absent ones. */
  @NonNull
  private static Map<String, Object> describe(@NonNull CaptureResult result) {
    final Map<String, Object> out = new HashMap<>();

    // --- Exposure, from the same frame the pixels came from. -----------------
    final Long exposureNs = result.get(CaptureResult.SENSOR_EXPOSURE_TIME);
    if (exposureNs != null) {
      out.put("exposureTimeNs", exposureNs);
    }
    final Integer iso = result.get(CaptureResult.SENSOR_SENSITIVITY);
    if (iso != null) {
      out.put("sensitivityIso", iso);
    }
    final Float aperture = result.get(CaptureResult.LENS_APERTURE);
    if (aperture != null) {
      out.put("aperture", aperture.doubleValue());
    }
    // Sensitivity applied after the raw stage. Ignoring it understates ISO, and
    // so overstates the scene, on devices that use it.
    final Integer boost = result.get(CaptureResult.CONTROL_POST_RAW_SENSITIVITY_BOOST);
    if (boost != null) {
      out.put("postRawSensitivityBoost", boost);
    }
    final Float focalLength = result.get(CaptureResult.LENS_FOCAL_LENGTH);
    if (focalLength != null) {
      out.put("focalLengthMm", focalLength.doubleValue());
    }

    // Whether auto-exposure has settled, so a reading need not rely on a fixed
    // wait being long enough.
    final Integer aeState = result.get(CaptureResult.CONTROL_AE_STATE);
    if (aeState != null) {
      out.put("aeState", aeState);
      out.put(
          "aeConverged",
          aeState == CameraMetadata.CONTROL_AE_STATE_CONVERGED
              || aeState == CameraMetadata.CONTROL_AE_STATE_LOCKED
              || aeState == CameraMetadata.CONTROL_AE_STATE_FLASH_REQUIRED);
    }
    final Integer aeCompensation = result.get(CaptureResult.CONTROL_AE_EXPOSURE_COMPENSATION);
    if (aeCompensation != null) {
      out.put("aeExposureCompensation", aeCompensation);
    }

    // --- Colour, in raw sensor space and so free of the AWB correction. ------
    final Rational[] neutral = result.get(CaptureResult.SENSOR_NEUTRAL_COLOR_POINT);
    if (neutral != null && neutral.length == 3) {
      final double[] values = new double[3];
      boolean usable = true;
      for (int i = 0; i < 3; i++) {
        if (neutral[i] == null || neutral[i].getDenominator() == 0) {
          usable = false;
          break;
        }
        values[i] = neutral[i].doubleValue();
      }
      if (usable) {
        out.put("neutralColorPoint", values);
      }
    }

    final Integer awbState = result.get(CaptureResult.CONTROL_AWB_STATE);
    if (awbState != null) {
      out.put("awbState", awbState);
      out.put(
          "awbConverged",
          awbState == CameraMetadata.CONTROL_AWB_STATE_CONVERGED
              || awbState == CameraMetadata.CONTROL_AWB_STATE_LOCKED);
    }
    final Integer awbMode = result.get(CaptureResult.CONTROL_AWB_MODE);
    if (awbMode != null) {
      out.put("awbMode", awbMode);
    }

    // The gains AWB applied. Not needed to read the illuminant, but they are
    // what makes the rendered pixels disagree with it, so worth reporting.
    final RggbChannelVector gains = result.get(CaptureResult.COLOR_CORRECTION_GAINS);
    if (gains != null) {
      out.put(
          "colorCorrectionGains",
          new double[] {
            gains.getRed(), gains.getGreenEven(), gains.getGreenOdd(), gains.getBlue()
          });
    }

    final Long frameDuration = result.get(CaptureResult.SENSOR_FRAME_DURATION);
    if (frameDuration != null) {
      out.put("frameDurationNs", frameDuration);
    }

    return out;
  }
}
