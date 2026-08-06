# Light Meter

An Android spot light meter for film photography. Point the camera, tap the
point you want to meter, and read off the shutter speed or aperture for the
film you have loaded. Includes a guide-number flash calculator.

## Running

```bash
flutter pub get
flutter run          # with an Android device attached via USB debugging
flutter test
```

## How the EV reading works

Pixel brightness on its own says nothing about how bright a scene is: the
camera's auto-exposure adjusts until whatever it is pointed at renders as a
mid-tone, so a white wall and a grey wall produce nearly the same pixel values.
An absolute EV needs the exposure the camera actually used.

Each measurement therefore:

1. Points auto-exposure at the tapped spot (`setExposurePoint`) and lets it
   settle, so the spot is exposed near middle grey where the sensor response is
   most trustworthy.
2. Locks exposure, so the preview stream and the still capture share one
   exposure and the reading stays valid while panning.
3. Captures a frame and reads the real aperture, shutter time, and ISO from its
   EXIF metadata.
4. Converts those to the EV the camera metered for:

   ```
   EV₁₀₀ = log₂(N² / t) − log₂(S / 100)
   ```

5. Samples a small patch of the live frame at the crosshair, linearizes it out
   of its sRGB gamma encoding, and offsets the EV by how far that patch sits
   from 18% middle grey:

   ```
   EV_spot = EV₁₀₀ + log₂(L_linear / 0.18)
   ```

With exposure locked, step 5 runs on every frame, so the reading tracks live as
you move the phone. Once the patch clips or crushes the tone curve is no longer
invertible, so the app re-meters automatically.

## Flash mode

Guide number is defined as `GN = aperture × distance`, so flash power cannot be
derived from GN, ISO, and aperture alone — the distance to the subject is the
fourth term. Enter the guide number as the manufacturer rates it (ISO 100), the
flash-to-subject distance, your film ISO, and your aperture; the app returns the
power setting to dial in.

Light output scales with power and sensitivity scales with the square root of
ISO, so:

```
GN_working = GN₁₀₀ × √(ISO / 100)
power      = (aperture × distance / GN_working)²
```

The result is snapped to the settings a manual flash actually has
(1/1 … 1/128), with the rounding error reported in stops. The panel also shows
how far full power reaches, and — when an ambient reading exists — the shutter
speed the ambient light alone would need, so you can tell whether the
background will register. Shutter speed never affects the flash exposure itself,
as the burst is shorter than any sync speed.

If the subject is out of reach even at full power, the app says how many stops
short it is and which aperture would cover the distance.

Below the answer is a vertical axis of every setting from 1/128 up to 1/1 with
the distance each one covers at the current aperture and ISO. Steps are one stop
apart, so distances change by √2 between neighbours; the recommended setting is
marked, and the subject distance is shown in the header for reference.

## Focal simulation

A format bar above the preview selects **Off**, **36×24**, **645**, or **6×6**.
With a format selected, pick a focal length and the live viewfinder crops to that
film's aspect ratio and field of view. The app reads the phone's native focal
length and sensor size (Camera2 on Android, EXIF as fallback). Zoom is taken
into account. Saved frames use the same crop and stamp the format + focal
length on the border.

| Format | Frame | Default lens |
| --- | --- | --- |
| 36×24 | 36×24 mm (full frame) | 50 mm |
| 645 | 56×41.5 mm | 75 mm |
| 6×6 | 60×60 mm | 80 mm |

The white shutter button on the preview captures the current frame, wraps it in
a film-style border stamped with the shutter, aperture, and ISO from the
calculator (plus EV when a reading exists), and saves it to a **Light Meter**
album in the device gallery.

- Readings are only as good as the phone's reported exposure metadata and its
  JPEG tone curve. Use **Cal** to offset every reading to match a meter you
  trust; the offset persists across launches.
- The metered patch is exactly the circle drawn on screen, averaged in linear
  light.
- Devices that omit exposure data from EXIF cannot produce an absolute EV; the
  app says so rather than showing an invented number.

## Layout

| File | Purpose |
| --- | --- |
| `lib/exposure.dart` | APEX exposure math, sRGB linearization, formatting |
| `lib/metering.dart` | EXIF exposure parsing, spot → sensor mapping, patch sampling |
| `lib/film_format.dart` | Film formats + FOV / crop math |
| `lib/lens_info.dart` | Android Camera2 / EXIF lens info |
| `lib/flash_scale.dart` | Vertical power → distance axis |
| `lib/units.dart` | Metre/foot conversion and number formatting |
| `lib/number_input_dialog.dart` | Numeric entry dialog |
| `lib/calibration.dart` | Persists the EV calibration offset |
| `lib/main.dart` | Camera preview, metering flow, calculator UI |
