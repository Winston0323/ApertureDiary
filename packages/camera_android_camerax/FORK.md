# Fork of `camera_android_camerax` 0.6.30

## Why

CameraX does not surface the Camera2 `CaptureResult`. One measurement is
impossible without it, and a second is needlessly slow without it.

### Colour temperature cannot be measured from rendered pixels

Auto white balance exists to divide the illuminant's colour out. Measured on a
vivo V2505A, it was applying gains of **1.85 on red and 1.74 on blue** — close to
a stop. By the time pixels are rendered, a white wall under tungsten looks
neutral, so a temperature derived from them reads as daylight regardless of the
actual light.

`SENSOR_NEUTRAL_COLOR_POINT` is the white point the ISP determined, stated in
raw sensor space *before* that correction. It is the only value on this platform
that still describes the illuminant. Combined with the sensor's DNG calibration
matrices — read separately through the app's own channel, since those are static
characteristics — it converts to CIE XYZ and then to a real temperature.

### Exposure no longer needs a photograph

The app used to read exposure from a still capture's EXIF. That meant taking a
photograph on every measurement, stopping and restarting the analysis stream each
time.

Measured on the same device, the preview frame's own exposure and the still
capture's EXIF agreed to **0.00014 EV**. The photograph bought nothing, so it is
now skipped whenever frame metadata is available.

> This corrected an earlier assumption. The 2.31 EV of measurement spread found
> on this device had been attributed partly to the stills and preview pipelines
> disagreeing; that turned out not to happen here at all. The spread was entirely
> the tone curve, which the closed-loop servo addresses separately.

`CONTROL_AE_STATE` additionally lets metering wait for auto-exposure to actually
converge rather than guessing with a fixed delay.

## The change

Three files. Everything else is upstream, byte for byte.

| File | Change |
| --- | --- |
| `CaptureMetadataBroadcaster.java` | **New.** Holds a `CameraCaptureSession.CaptureCallback`, extracts the wanted keys, streams them over an `EventChannel` thinned to ~10 Hz. Also exposes a `MethodChannel` handshake. |
| `PreviewProxyApi.java` | Passes that callback to `Camera2Interop.Extender.setSessionCaptureCallback` when building the Preview use case. **+10 lines.** |
| `ProxyApiRegistrar.java` | Constructs the broadcaster and exposes a getter. **+10 lines.** |

Channels:

- `plugins.flutter.io/camera_android_camerax/capture_metadata` — event stream
- `plugins.flutter.io/camera_android_camerax/capture_metadata_probe` — status

## A dead end worth recording

The first attempt read the metadata from analysed frames:

```java
CameraCaptureResults.retrieveCameraCaptureResult(imageProxy.getImageInfo())
```

It returns null, on every frame, always. Disassembling `camera-core` shows why:

```
instanceof androidx/camera/core/internal/CameraCaptureResultImageInfo
```

Only that one implementation carries a capture result, and `ImageAnalysis`
attaches an `ImmutableImageInfo`, which does not. **This path cannot work for
analysis output** — it is not a matter of getting the cast right.

`Camera2Interop.Extender.setSessionCaptureCallback` is public, supported API and
delivers `TotalCaptureResult` directly. It is both the correct route and the only
one that works. The fork therefore touches **no** internal or `@RestrictTo` API.

## Diagnosing this fork on a device

Two vendor behaviours made the first investigation much harder than it should
have been, and both are worth knowing about:

1. **vivo's ROM drops third-party `Log` output entirely.** The app's own PID
   showed only system event logs — not even Flutter's engine startup lines. Any
   diagnosis that depends on logcat will silently show nothing.
2. **R8 rewrites class names**, so searching a release APK's dex for a class name
   finds nothing even when the class is present. Only string constants survive.
   This briefly looked like proof the fork had not been packaged at all.

Hence the two deliberate escape hatches:

- The **probe channel** answers "is the fork running?" definitively: a
  `MissingPluginException` means no, anything else means yes. No ROM can filter
  a method call.
- A **trace file** at `/sdcard/Download/ApertureDiary/capture_metadata_trace.txt`
  records progress through the path, one line per state, so a failure names its
  own cause.

A healthy run looks like:

```
… registered channel plugins.flutter.io/camera_android_camerax/capture_metadata
… dart attached
… first capture result
… publishing; keys=[neutralColorPoint, exposureTimeNs, sensitivityIso, aperture, …]
```

## Verified against

- `camera_android_camerax` 0.6.30, `androidx.camera:*` 1.5.3
- vivo V2505A, Android 16 / API 36, `INFO_SUPPORTED_HARDWARE_LEVEL = 3` (LEVEL_3)
- 14 keys delivered, 43 events published over 149 capture results

## Upgrading

Copy `CaptureMetadataBroadcaster.java` across and re-make the two hooks; both are
a few lines at well-known places. Then confirm on device via the probe channel —
silent degradation is the designed failure mode, so nothing will announce itself
if it breaks.

If upstream ever exposes capture metadata itself, delete this fork and the
`dependency_overrides` entry with it.
