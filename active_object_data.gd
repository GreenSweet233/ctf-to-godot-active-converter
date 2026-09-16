@tool
## objects.json（MFSPLExporter 输出的 IR）解析：取出 Active 实例的位置清单。
##
## 数据来源：NebulaFD 的批量命令行 MFSPLCli（Nebula.Tools/MFSPLCli）导出的
## <mfspl_ir>/<关卡>/objects.json：
##   { "app": { "name":.., "width":.., "height":.. },
##     "objectTypes": { "<handle>": { "handle":int, "name":String, "type":int, "typeName":String, ... } },
##     "frames": [ { "name":String, "handle":int, "width":int, "height":int,
##                   "instances": [ { "objectInfo":int, "x":int, "y":int, "layer":int,
##                                    "instanceValue":int, "parentType":int, "parentHandle":int } ] } ] }
##
## 解析出的每一行（生成 / 预览共用同一个结构）：
##   { index:int, name:String, handle:int, objectInfo:int, type:int, typeName:String,
##     x:int, y:int, layer:int, parentType:int, frame:int, frameName:String }
##
## 口径（用户拍板）：
##   - 只取 type == 2（Active）；backdrop（type 0/1）继续走 tile_converter / TileExporter 文本
##   - 落点 = 实例 x/y（CTF 的 hot spot 坐标，与 IR 里的 x/y 1:1 对应）
##   - parentType != 0 的实例是 MFA 的「假实例（Fake Instance / CreateOnly）」——
##     对象在帧里被事件引用但没摆到场上，坐标恒为 0,0；Nebula.Core 自己的帧预览（Utilities.cs）
##     同样跳过它们 ⇒ 默认过滤，可用 include_fake 打开
extends RefCounted

const TileTxt := preload("res://addons/active_converter/active_tile_data.gd")
## CTF 对象类型：2 = Active
const ACTIVE_TYPE := 2


## 读取并解析 objects.json。
## include_fake = false 时跳过 parentType != 0 的假实例。
## 返回 { ok, error, rows, all_rows, objects, counts, frames, active_count, fake_count, other_count, warning, encoding, app }
static func parse_file(path: String, include_fake: bool = false) -> Dictionary:
	var result := {
		"ok": false,
		"error": "",
		"rows": [],
		"all_rows": [],
		"objects": [],
		"counts": {},
		"frames": [],
		"active_count": 0,
		"fake_count": 0,
		"other_count": 0,
		"warning": "",
		"encoding": "",
		"app": {},
	}
	if not FileAccess.file_exists(path):
		result["error"] = "File not found: %s" % path
		return result

	# 复用 tile 解析器里的编码自适应读取（UTF-8 / UTF-16LE / UTF-16BE）
	var read := TileTxt.read_text(path)
	if not bool(read["ok"]):
		result["error"] = String(read["error"])
		return result
	result["encoding"] = String(read["encoding"])

	var parsed: Variant = JSON.parse_string(String(read["text"]))
	if typeof(parsed) != TYPE_DICTIONARY:
		result["error"] = "Not a valid objects.json (expected a top-level JSON object)."
		return result
	var doc: Dictionary = parsed
	if typeof(doc.get("objectTypes")) != TYPE_DICTIONARY or typeof(doc.get("frames")) != TYPE_ARRAY:
		result["error"] = "Missing \"objectTypes\" / \"frames\" — is this an objects.json exported by MFSPLCli?"
		return result

	result["app"] = doc.get("app", {}) if typeof(doc.get("app")) == TYPE_DICTIONARY else {}

	# handle -> 类型定义（名字 / 类型号）
	var types: Dictionary = {}
	for key in (doc["objectTypes"] as Dictionary).keys():
		var type_def: Variant = (doc["objectTypes"] as Dictionary)[key]
		if typeof(type_def) != TYPE_DICTIONARY:
			continue
		types[int(str(key))] = type_def

	var all_rows: Array = []
	var frames_info: Array = []
	var other_count := 0
	var index := 0

	for frame_index in (doc["frames"] as Array).size():
		var frame_v: Variant = (doc["frames"] as Array)[frame_index]
		if typeof(frame_v) != TYPE_DICTIONARY:
			continue
		var frame: Dictionary = frame_v
		var frame_name := String(frame.get("name", ""))
		var instances: Array = frame.get("instances", []) if typeof(frame.get("instances")) == TYPE_ARRAY else []
		frames_info.append({
			"name": frame_name,
			"handle": int(frame.get("handle", 0)),
			"width": int(frame.get("width", 0)),
			"height": int(frame.get("height", 0)),
			"instances": instances.size(),
		})
		for inst_v in instances:
			if typeof(inst_v) != TYPE_DICTIONARY:
				continue
			var inst: Dictionary = inst_v
			var object_info := int(inst.get("objectInfo", -1))
			var type_def: Dictionary = types.get(object_info, {})
			if int(type_def.get("type", -1)) != ACTIVE_TYPE:
				other_count += 1
				continue
			all_rows.append({
				"index": index,
				"name": String(type_def.get("name", "obj_%d" % object_info)),
				"handle": int(type_def.get("handle", object_info)),
				"objectInfo": object_info,
				"type": ACTIVE_TYPE,
				"typeName": String(type_def.get("typeName", "Active")),
				"x": int(inst.get("x", 0)),
				"y": int(inst.get("y", 0)),
				"layer": int(inst.get("layer", 0)),
				"parentType": int(inst.get("parentType", 0)),
				"frame": frame_index,
				"frameName": frame_name,
			})
			index += 1

	var fake_count := 0
	for row in all_rows:
		if int(row["parentType"]) != 0:
			fake_count += 1

	var rows := filter_rows(all_rows, include_fake)
	if rows.is_empty():
		result["error"] = "No Active (type 2) instances found in this objects.json."
		result["all_rows"] = all_rows
		result["frames"] = frames_info
		result["active_count"] = all_rows.size()
		result["fake_count"] = fake_count
		result["other_count"] = other_count
		return result

	var warnings: Array = []
	if fake_count > 0:
		warnings.append("%d fake instance(s) (parentType != 0)%s" % [
			fake_count, " included" if include_fake else " skipped"])
	if frames_info.size() > 1:
		warnings.append("%d frames merged into one list" % frames_info.size())

	result["ok"] = true
	result["rows"] = rows
	result["all_rows"] = all_rows
	result["objects"] = unique_objects(rows)
	result["counts"] = object_counts(rows)
	result["frames"] = frames_info
	result["active_count"] = all_rows.size()
	result["fake_count"] = fake_count
	result["other_count"] = other_count
	result["warning"] = "; ".join(warnings)
	return result


## 按是否包含假实例过滤（切换勾选时用它重算，不必重新读盘）
static func filter_rows(all_rows: Array, include_fake: bool) -> Array:
	if include_fake:
		return all_rows.duplicate()
	var rows: Array = []
	for row in all_rows:
		if int(row["parentType"]) == 0:
			rows.append(row)
	return rows


## 实例落点：CTF 的 hot spot 坐标（与 IR 的 x/y 1:1）
static func anchor_position(row: Dictionary) -> Vector2:
	return Vector2(float(row["x"]), float(row["y"]))


## 出现过的对象名（升序，供左列表 / 统计使用）
static func unique_objects(rows: Array) -> Array:
	var seen := {}
	for row in rows:
		seen[String(row["name"])] = true
	var names: Array = seen.keys()
	names.sort()
	return names


## 对象名 -> 实例个数
static func object_counts(rows: Array) -> Dictionary:
	var counts := {}
	for row in rows:
		var name := String(row["name"])
		counts[name] = int(counts.get(name, 0)) + 1
	return counts
