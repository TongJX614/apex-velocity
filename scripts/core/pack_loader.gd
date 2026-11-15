extends Node
## Windows 安装版把重型场景资产拆到 APEX_VELOCITY_data.pck（安装包格式有 2GB 上限）。
## 必须是第一个 autoload：赶在任何场景/资产加载前合并数据包。
## 编辑器与 macOS 版没有外置数据包，此脚本自动跳过。

const DATA_PACK := "APEX_VELOCITY_data.pck"

func _init() -> void:
	var pack_path := OS.get_executable_path().get_base_dir().path_join(DATA_PACK)
	if not FileAccess.file_exists(pack_path):
		return
	if not ProjectSettings.load_resource_pack(pack_path):
		push_error("数据包加载失败：%s（请确认它与 exe 在同一目录）" % pack_path)