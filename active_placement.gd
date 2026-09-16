@tool
## 场景实例的落位与去重公共逻辑（用户拍板的规则）。
##
## - 落点 = 图块矩形中心 + 该映射自带的 offset（见 active_tile_data.anchor_position）
## - 去重 = 目标节点的【直接子节点】中，只要有节点的落点与待生成点距离 <= 16px（模糊检测），
##   就不再重复实例化；同一批已经生成的实例同样计入占用
## - 坐标一律按【目标节点的局部坐标】比对：txt 里的 x/y 与父容器的局部坐标 1:1 对应
extends RefCounted

## 模糊去重半径（px）
const DUP_RADIUS := 16.0
## 生成时打在实例根节点上的元数据键，记录来源 image id（供“清除本插件生成的实例”识别）
const META_IMAGE := "active_converter_image"
## 生成 active 实例时打在节点上的元数据键，记录来源对象名（同样供“清除本插件生成的实例”识别）
const META_OBJECT := "active_converter_object"


## 取节点可用于比对的落点；只有 Node2D / Control 有 position，其余返回 null
static func child_position(node: Node) -> Variant:
	if node is Node2D:
		return (node as Node2D).position
	if node is Control:
		return (node as Control).position
	return null


## 收集目标节点【直接子节点】的落点
static func collect_child_positions(target: Node) -> Array:
	var out: Array = []
	if target == null or not is_instance_valid(target):
		return out
	for child in target.get_children():
		var pos: Variant = child_position(child)
		if pos != null:
			out.append(pos)
	return out


## 目标点是否已被占用（occupied = 已有子节点落点，pending = 本批已排队的落点）
static func is_occupied(position: Vector2, occupied: Array, pending: Array, radius: float = DUP_RADIUS) -> bool:
	for p in occupied:
		if (p as Vector2).distance_to(position) <= radius:
			return true
	for p in pending:
		if (p as Vector2).distance_to(position) <= radius:
			return true
	return false


## 预览用：列出目标节点直接子节点（含名称），便于在预览图上标注已有物品
static func collect_existing_items(target: Node) -> Array:
	var out: Array = []
	if target == null or not is_instance_valid(target):
		return out
	for child in target.get_children():
		var pos: Variant = child_position(child)
		if pos == null:
			continue
		out.append({
			"position": pos,
			"name": String(child.name),
			"type": child.get_class(),
		})
	return out


## 生成计划（tile / active 两种模式共用）：
##   entries = [ { "key": int|String, "position": Vector2 } ]  —— position 是锚点（未叠 offset）
## 返回 { plan:[{node, position, key}], skipped_dup:int, unmapped:Dictionary, warnings:Array }
## plan 里的节点已经实例化但【未入树】，由调用方走一次 UndoRedo 提交（add_child / set_owner / 属性 / meta）。
static func build_plan(entries: Array, mapping: Dictionary, target: Node, meta_key: String = META_IMAGE) -> Dictionary:
	var occupied := collect_child_positions(target)
	var plan: Array = []
	var pending: Array = []
	var warnings: Array = []
	var unmapped := {}
	var skipped_dup := 0

	for entry in entries:
		var key: Variant = entry["key"]
		if not mapping.has(key):
			unmapped[key] = true
			continue
		var scene_path := String(mapping[key].get("scene", ""))
		if scene_path.is_empty():
			continue
		var packed: Resource = ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_REUSE)
		if not (packed is PackedScene):
			warnings.append("Failed to load scene (key=%s): %s" % [str(key), scene_path])
			continue
		var position: Vector2 = (entry["position"] as Vector2) + Vector2(mapping[key].get("offset", Vector2.ZERO))
		# 16px 模糊去重：目标节点直接子节点（含本批已生成的）里已有物品 → 跳过
		if is_occupied(position, occupied, pending):
			skipped_dup += 1
			continue
		var instance: Node = (packed as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		if instance == null:
			warnings.append("Failed to instantiate (key=%s): %s" % [str(key), scene_path])
			continue
		if not (instance is Node2D or instance is Control):
			warnings.append("Root node is neither Node2D nor Control, cannot place it (key=%s): %s" % [str(key), scene_path])
			instance.free()
			continue
		plan.append({"node": instance, "position": position, "key": key, "meta_key": meta_key})
		pending.append(position)

	return {
		"plan": plan,
		"skipped_dup": skipped_dup,
		"unmapped": unmapped,
		"warnings": warnings,
	}


## 把生成计划提交到编辑器（一次 Undo，可整批 Ctrl+Z）——tile / active 共用
static func commit_plan(plan: Array, target: Node) -> void:
	if plan.is_empty():
		return
	var edited := EditorInterface.get_edited_scene_root()
	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action("Active Converter: Place Scene Instances")
	for item in plan:
		var instance: Node = item["node"]
		undo.add_do_method(target, "add_child", instance, true)
		undo.add_do_method(instance, "set_owner", edited)
		undo.add_do_property(instance, "position", item["position"])
		undo.add_do_method(instance, "set_meta", String(item.get("meta_key", META_IMAGE)), item["key"])
		undo.add_do_reference(instance)
	undo.commit_action()


## 该节点是否由本插件生成（tile 或 active 任一来源）
static func is_generated(node: Node) -> bool:
	return node.has_meta(META_IMAGE) or node.has_meta(META_OBJECT)
