@tool
## 场景池容器：除“Add Scenes...”按钮外，也支持从 FileSystem 面板直接拖入 .tscn / .scn。
extends FlowContainer

signal files_dropped(paths: PackedStringArray)


func _ready() -> void:
	# PASS：空处可以接收拖放，同时不挡住 ScrollContainer 的滚轮滚动
	mouse_filter = Control.MOUSE_FILTER_PASS


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var dict: Dictionary = data
	if String(dict.get("type", "")) != "files":
		return false
	for file in PackedStringArray(dict.get("files", PackedStringArray())):
		if file.ends_with(".tscn") or file.ends_with(".scn"):
			return true
	return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var dict: Dictionary = data
	files_dropped.emit(PackedStringArray(dict.get("files", PackedStringArray())))
