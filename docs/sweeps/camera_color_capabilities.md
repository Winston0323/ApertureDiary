# vivo V2505A — 相机色彩能力诊断

来源：`adb shell dumpsys media.camera`，Camera 0（后置主摄），Android 16 / API 36。
完整转储见 `camera_dump_raw.txt`（24874 行）。

## 关键结果

| 能力 | 值 | 判定 |
| --- | --- | --- |
| `INFO_SUPPORTED_HARDWARE_LEVEL` | `3` | **LEVEL_3 — 最高级别** |
| `CONTROL_AWB_AVAILABLE_MODES` | `[1 2 3 4 5 6 7 8 0]` | **含 0 = AWB_MODE_OFF，可关闭自动白平衡** |
| `COLOR_CORRECTION_COLOR_TEMPERATURE_RANGE` | `[1500, 10000]` | **支持直接设定色温（API 35+）** |
| `availableRequestKeys` | 含 `awbMode`、`colorTemperature`、`colorTint`、`colorCorrection.mode` | 可写 |
| `availableResultKeys` | 含 `sensor.neutralColorPoint` (917522) | **可读传感器原生白点** |
| `SENSOR_REFERENCE_ILLUMINANT1` | `D65` | 标定基准已知 |
| `SENSOR_REFERENCE_ILLUMINANT2` | `17` (= Standard Illuminant A, 2856 K) | 双光源标定 |
| `SENSOR_CALIBRATION_TRANSFORM1/2` | `rational[9]` | 存在 |
| `SENSOR_COLOR_TRANSFORM1/2` | `rational[9]` | 存在 |
| `SENSOR_FORWARD_MATRIX1/2` | `rational[9]` | 存在 |

## 意义

三件事同时成立，这在中端国产 ROM 上并不常见：

1. **AWB 可关闭。** 原先最大的未知项 —— 很多 ROM 不给 `AWB_MODE_OFF`。这台给了。
2. **可直接读传感器白点。** `SENSOR_NEUTRAL_COLOR_POINT` 是 ISP 判定的原始白点，位于传感器 RAW 空间。它不受 AWB 增益影响，因此读它**不需要关闭 AWB，也不改变预览外观** —— 比"读 AWB 增益再除掉"更干净。
3. **完整的 DNG 色彩标定链可用。** `referenceIlluminant1/2` + `calibrationTransform1/2` + `colorTransform1/2` 齐备，意味着可以把 RAW 空间的白点严格映射到 CIE XYZ，再交给现有的黑体轨迹搜索得到色温。这是 Adobe DNG 规范里的标准做法，不是估算。

## 从白点到色温的路径

```
SENSOR_NEUTRAL_COLOR_POINT        (RAW 空间白点, rational[3])
  ↓  以 referenceIlluminant1/2 为端点，按白点插值两组标定矩阵
CM = interp(colorTransform1, colorTransform2)
CC = interp(calibrationTransform1, calibrationTransform2)
  ↓  XYZ→RAW 为 (CC · CM)，取逆
XYZ = (CC · CM)⁻¹ · neutralColorPoint
  ↓  现有实现
ColorTemperatureMath.fromLinearRgb / fromUv  →  Kelvin + Duv
```

插值需要迭代（矩阵依赖白点，白点又依赖矩阵），DNG 规范的做法是迭代 2–3 次即收敛。

## 仍然存在的瓶颈

设备侧全绿，卡点完全在软件层：

- 项目走 `camera_android_camerax 0.6.30`（CameraX 1.5.3），**不是 Camera2**。
- 插件原生侧已有 `Camera2CameraControlProxyApi` / `CaptureRequestOptionsProxyApi` / `Camera2CameraInfoProxyApi`。
- Dart 侧有 `Camera2CameraControl.addCaptureRequestOptions()` 与
  `Camera2CameraInfo.getCameraCharacteristic()`。
- **但 `CaptureRequestKey` 只有 `pigeon_detached` 构造函数**，原生侧也未暴露任何具体键的工厂方法。Dart 无法构造出 `CONTROL_AWB_MODE` 之类的键。
- 更关键：`getCameraCharacteristic` 只能读**静态** characteristics。
  `SENSOR_NEUTRAL_COLOR_POINT` 属于 **CaptureResult**（每帧变化），插件完全没有暴露 CaptureResult 的通道。

即：读白点必须让插件把 `CaptureResult` 推给 Dart，这是当前 API 面里缺的那一块。

## 结论

评估结论从「先别做，设备可能不支持」修正为「设备完全支持，值得做，但要改插件」。

需要的改动是给 `camera_android_camerax` 加一个 CaptureResult 的 EventChannel：
在原生侧通过 `Camera2Interop.Extender.setSessionCaptureCallback` 挂回调，
把 `SENSOR_NEUTRAL_COLOR_POINT`（以及顺带的 `SENSOR_EXPOSURE_TIME` /
`SENSOR_SENSITIVITY` / `LENS_APERTURE`）推送到 Dart。

顺带解决的问题：曝光参数同源。当前 EV 测量从 `takePicture` 的 EXIF 取曝光，
与预览像素来自两条不同管线；改为读预览帧自己的 CaptureResult 后，
先前记录的 P0-1 双管线问题一并消失，且每次测光不必再拍一张照。

一处限制：iOS 无此路径。`AVCaptureDevice` 侧另有
`deviceWhiteBalanceGains` / `temperatureAndTintValues(for:)` 可直接给出色温，
需要对 `camera_avfoundation` 做类似改动（工作量更小，苹果 API 更稳定）。
