@tool
## Active Converter 的映射表持久化：image id -> { 场景, offset } 与 对象名 -> { 场景, offset }。
##
## 存放在插件目录内（随工程走版本控制，做法与 addons/scene_favorites 一致）：
##   res://addons/active_converter/mapping.json
##
## 两张表分开存（"mappings" = tile 的 image id；"objectMappings" = mfa active 的对象名），
## 互不覆盖，共用同一个场景池 (scenes)。
##
## 打开插件时自动载入、每次改动自动落盘（原子写：先写 .tmp 再替换）。
extends RefCounted

const CONFIG_PATH := "res://addons/active_converter/mapping.json"
const CONFIG_VERSION := 2

## 场景池：Array[String]，用户加入过的场景路径（res:// 开头）
var scenes: Array = []
## 映射表（tile）：int(image id) -> { "scene": String, "offset": Vector2 }
var mappings: Dictionary = {}
## 映射表（active）：String(对象名) -> { "scene": String, "offset": Vector2 }
var object_mappings: Dictionary = {}

var _config_path := ""


func _init(p_load: bool = true) -> void:
	_config_path = ProjectSettings.globalize_path(CONFIG_PATH)
	if p_load:
		load_config()


# ---------------------------------------------------------------- 映射表读写

func has_mapping(image_id: int) -> bool:
	return mappings.has(image_id)


func get_entry(image_id: int) -> Dictionary:
	return mappings.get(image_id, {})


func get_scene(image_id: int) -> String:
	return String(mappings.get(image_id, {}).get("scene", ""))


func get_offset(image_id: int) -> Vector2:
	return mappings.get(image_id, {}).get("offset", Vector2.ZERO)


## 把某个 image 映射到场景（该场景会自动进入场景池）
func set_mapping(image_id: int, scene_path: String) -> void:
	if scene_path.is_empty():
		return
	var entry: Dictionary = mappings.get(image_id, {})
	entry["scene"] = scene_path
	if not entry.has("offset"):
		entry["offset"] = Vector2.ZERO
	mappings[image_id] = entry
	if not scenes.has(scene_path):
		scenes.append(scene_path)
	save()


## 只改 offset（未映射的 image 不写）
func set_offset(image_id: int, offset: Vector2) -> void:
	if not mappings.has(image_id):
		return
	mappings[image_id]["offset"] = offset
	save()


func erase_mapping(image_id: int) -> void:
	if mappings.erase(image_id):
		save()


func clear_mappings() -> void:
	if mappings.is_empty():
		return
	mappings.clear()
	save()


# ---------------------------------------------------------------- active 映射表（键 = 对象名）
# 与 tile 的 mappings 分开存放（互不覆盖），共用同一个场景池。

func has_object_mapping(object_name: String) -> bool:
	return object_mappings.has(object_name)


func get_object_entry(object_name: String) -> Dictionary:
	return object_mappings.get(object_name, {})


func get_object_scene(object_name: String) -> String:
	return String(object_mappings.get(object_name, {}).get("scene", ""))


func get_object_offset(object_name: String) -> Vector2:
	return object_mappings.get(object_name, {}).get("offset", Vector2.ZERO)


## 把某个对象名映射到场景（该场景会自动进入场景池）
func set_object_mapping(object_name: String, scene_path: String) -> void:
	if object_name.is_empty() or scene_path.is_empty():
		return
	var entry: Dictionary = object_mappings.get(object_name, {})
	entry["scene"] = scene_path
	if not entry.has("offset"):
		entry["offset"] = Vector2.ZERO
	object_mappings[object_name] = entry
	if not scenes.has(scene_path):
		scenes.append(scene_path)
	save()


## 只改 offset（未映射的对象名不写）
func set_object_offset(object_name: String, offset: Vector2) -> void:
	if not object_mappings.has(object_name):
		return
	object_mappings[object_name]["offset"] = offset
	save()


func erase_object_mapping(object_name: String) -> void:
	if object_mappings.erase(object_name):
		save()


func clear_object_mappings() -> void:
	if object_mappings.is_empty():
		return
	object_mappings.clear()
	save()


# ---------------------------------------------------------------- 场景池

func add_scene(path: String) -> bool:
	if path.is_empty() or scenes.has(path):
		return false
	scenes.append(path)
	save()
	return true


func remove_scene(path: String) -> void:
	var idx := scenes.find(path)
	if idx == -1:
		return
	scenes.remove_at(idx)
	save()


# ---------------------------------------------------------------- 磁盘读写

func load_config() -> void:
	scenes = []
	mappings = {}
	object_mappings = {}
	if not FileAccess.file_exists(_config_path):
		return
	var file := FileAccess.open(_config_path, FileAccess.READ)
	if file == null:
		push_error("ActiveConverter: cannot read config %s (error %d)" % [_config_path, FileAccess.get_open_error()])
		return
	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		# 不静默丢弃损坏文件：改名备份，避免手写的映射被清空
		var backup := "%s.corrupt-%d" % [_config_path, int(Time.get_unix_time_from_system())]
		DirAccess.rename_absolute(_config_path, backup)
		push_error("ActiveConverter: config is not valid JSON, moved to %s" % backup)
		return

	var data: Dictionary = parsed
	for path in data.get("scenes", []):
		if typeof(path) == TYPE_STRING and not String(path).is_empty() and not scenes.has(path):
			scenes.append(path)

	var raw: Dictionary = data.get("mappings", {})
	for key in raw.keys():
		var entry := _decode_entry(raw[key])
		if not entry.is_empty():
			mappings[int(str(key))] = entry

	var raw_objects: Dictionary = data.get("objectMappings", {})
	for key in raw_objects.keys():
		var entry := _decode_entry(raw_objects[key])
		if not entry.is_empty():
			object_mappings[str(key)] = entry


## 解码一条映射记录；不是合法记录时返回空字典
func _decode_entry(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	var scene_path := String((value as Dictionary).get("scene", ""))
	if scene_path.is_empty():
		return {}
	var offset := Vector2.ZERO
	var raw_offset: Variant = (value as Dictionary).get("offset", [0, 0])
	if typeof(raw_offset) == TYPE_ARRAY and (raw_offset as Array).size() >= 2:
		offset = Vector2(float(raw_offset[0]), float(raw_offset[1]))
	return {"scene": scene_path, "offset": offset}


func save() -> void:
	var out_mappings := {}
	for image_id in mappings.keys():
		var entry: Dictionary = mappings[image_id]
		var offset: Vector2 = entry.get("offset", Vector2.ZERO)
		out_mappings[str(image_id)] = {
			"scene": String(entry.get("scene", "")),
			"offset": [int(round(offset.x)), int(round(offset.y))],
		}
	var out_object_mappings := {}
	for object_name in object_mappings.keys():
		var entry: Dictionary = object_mappings[object_name]
		var offset: Vector2 = entry.get("offset", Vector2.ZERO)
		out_object_mappings[str(object_name)] = {
			"scene": String(entry.get("scene", "")),
			"offset": [int(round(offset.x)), int(round(offset.y))],
		}
	var data := {
		"version": CONFIG_VERSION,
		"scenes": scenes,
		"mappings": out_mappings,
		"objectMappings": out_object_mappings,
	}

	var tmp_path := _config_path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_error("ActiveConverter: cannot write config to %s" % tmp_path)
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.flush()
	file.close()
	if FileAccess.file_exists(_config_path):
		DirAccess.remove_absolute(_config_path)
	var err := DirAccess.rename_absolute(tmp_path, _config_path)
	if err != OK:
		push_error("ActiveConverter: cannot replace config (%s), temp kept at %s" % [error_string(err), tmp_path])
