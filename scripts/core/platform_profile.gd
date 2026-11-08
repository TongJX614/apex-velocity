extends RefCounted
## 平台 / GPU 能力探测：让渲染策略跟着系统走，而不是一套写死。
##
## macOS 用 Metal 原生驱动（Apple GPU 直连显存），可用 MetalFX 时间升频；
## Windows / Linux 用 Vulkan + FSR2。纹理均由 .import 生成 VRAM 压缩 +
## mipmap，采样与过滤全部在 GPU 上完成，CPU 不参与逐帧图像处理。


static func driver_name() -> String:
	if RenderingServer.has_method("get_current_rendering_driver_name"):
		return String(RenderingServer.call("get_current_rendering_driver_name"))
	return String(ProjectSettings.get_setting("rendering/rendering_device/driver", "vulkan"))


static func method_name() -> String:
	if RenderingServer.has_method("get_current_rendering_method"):
		return String(RenderingServer.call("get_current_rendering_method"))
	return "forward_plus"


static func gpu_present() -> bool:
	return not RenderingServer.get_video_adapter_name().is_empty()


static func supports_metalfx() -> bool:
	return driver_name() == "metal" \
		and (OS.get_name() == "macOS" or OS.get_name() == "iOS") \
		and gpu_present()


static func supports_fsr2() -> bool:
	return method_name() == "forward_plus" and gpu_present() \
		and driver_name() != "metal"


static func screen_scale() -> float:
	if DisplayServer.get_name() == "headless":
		return 1.0
	return float(DisplayServer.screen_get_scale())


## 首次启动（没有存档）时按平台推荐画质档：Apple Silicon + Metal 直接上超高。
static func recommended_quality() -> int:
	if not gpu_present():
		return 2
	var adapter := RenderingServer.get_video_adapter_name()
	if supports_metalfx() and (adapter.contains("Apple M") or adapter.contains("Apple GPU")):
		return 3
	return 2


static func info() -> Dictionary:
	return {
		"os": OS.get_name(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"driver": driver_name(),
		"method": method_name(),
		"scale": screen_scale(),
		"metalfx": supports_metalfx(),
		"fsr2": supports_fsr2(),
		"recommended": recommended_quality(),
	}


static func summary() -> String:
	var d := info()
	var gpu := String(d["gpu"])
	if gpu.is_empty():
		gpu = "无 GPU（无头模式）"
	return "%s   ·   %s   ·   %s / %s   ·   HiDPI %.1fx" % [
		String(d["os"]), gpu, String(d["driver"]), String(d["method"]), float(d["scale"])]
