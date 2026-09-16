@tool
## Active Converter —— 编辑器插件入口。
##
## 与 Tile Converter（addons/tile_converter）读同一份 TileExporter v1.0 文本，
## 但目标不是往 TileMapLayer 里画格子，而是把 image 映射成【场景】后，
## 在选中节点下实例化场景（带每条映射各自的 offset，并按 16px 模糊检测去重）。
extends EditorPlugin

const DOCK_SCRIPT := preload("res://addons/active_converter/active_converter_dock.gd")

var dock: Control


func _enter_tree() -> void:
	dock = DOCK_SCRIPT.new()
	dock.setup(self)
	add_control_to_bottom_panel(dock, "Active Converter")


func _exit_tree() -> void:
	if dock:
		remove_control_from_bottom_panel(dock)
		dock.queue_free()
		dock = null
