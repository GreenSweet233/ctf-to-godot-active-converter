@tool
## 取一个 .tscn 的“缩略图”：实例化场景（不进场景树）后，取其中第一个可见精灵的贴图与区域。
##
## 返回 Dictionary：{ "texture": Texture2D 或 null, "region": Rect2 }
## 结果按路径缓存在编辑器会话内（同一场景只会被实例化一次）。
extends RefCounted

## 每个场景最多检查的节点数（防止病态场景拖慢编辑器）
const MAX_VISITED := 512

static var _cache: Dictionary = {}


static func clear_cache() -> void:
	_cache.clear()


static func get_thumb(scene_path: String) -> Dictionary:
	if _cache.has(scene_path):
		return _cache[scene_path]

	var result := {"texture": null, "region": Rect2()}
	if not scene_path.is_empty() and FileAccess.file_exists(scene_path):
		var res: Resource = ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_REUSE)
		if res is PackedScene:
			var inst: Node = (res as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
			if inst != null:
				var found := _find_texture(inst)
				if not found.is_empty():
					result = found
				inst.free()

	_cache[scene_path] = result
	return result


## 广度优先找第一个有贴图的可见精灵（层数越浅越可能是主体贴图）
static func _find_texture(root: Node) -> Dictionary:
	var queue: Array = [root]
	var visited := 0
	while not queue.is_empty() and visited < MAX_VISITED:
		var node: Node = queue.pop_front()
		visited += 1
		if node is CanvasItem and not (node as CanvasItem).visible:
			continue
		var found := _texture_of(node)
		if not found.is_empty():
			return found
		for child in node.get_children():
			queue.append(child)
	return {}


static func _texture_of(node: Node) -> Dictionary:
	if node is Sprite2D:
		var sprite := node as Sprite2D
		var tex := sprite.texture
		if tex == null:
			return {}
		var region := Rect2(Vector2.ZERO, Vector2(tex.get_size()))
		if sprite.region_enabled:
			region = sprite.region_rect
		elif sprite.hframes > 1 or sprite.vframes > 1:
			var frame_size := Vector2(
				float(tex.get_size().x) / float(sprite.hframes),
				float(tex.get_size().y) / float(sprite.vframes))
			region = Rect2(Vector2(sprite.frame_coords) * frame_size, frame_size)
		return {"texture": tex, "region": region}

	if node is AnimatedSprite2D:
		var anim := node as AnimatedSprite2D
		var frames := anim.sprite_frames
		if frames == null:
			return {}
		var anim_names := frames.get_animation_names()
		var anim_name := anim.animation
		if anim_name.is_empty() or not frames.has_animation(anim_name):
			if anim_names.is_empty():
				return {}
			anim_name = anim_names[0]
		var count := frames.get_frame_count(anim_name)
		if count <= 0:
			return {}
		var frame_tex := frames.get_frame_texture(anim_name, clampi(anim.frame, 0, count - 1))
		if frame_tex == null:
			return {}
		return {"texture": frame_tex, "region": Rect2(Vector2.ZERO, Vector2(frame_tex.get_size()))}

	if node is TextureRect:
		var rect := node as TextureRect
		var tex := rect.texture
		if tex == null:
			return {}
		var region := Rect2(Vector2.ZERO, Vector2(tex.get_size()))
		if rect.region_enabled:
			region = rect.region_rect
		return {"texture": tex, "region": region}

	return {}
