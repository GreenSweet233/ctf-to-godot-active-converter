@tool
## 预览控件：把整关的 tile / active 数据画成俯视示意图（左键选中条目，滚轮缩放，中键拖动）。
##
## 两种模式：
##  - "tiles"（默认，数据来自 TileExporter 文本）：每个 tile 画成矩形；已映射的 image 直接画出
##    映射场景的缩略图，并按该条映射的 offset 位移（缩略图中心 = 图块矩形中心 + offset）
##  - "objects"（数据来自 MFSPLCli 的 objects.json）：每个 Active 实例画成一个锚点（实例 x/y），
##    已映射的对象名同样画出映射场景缩略图（居中在锚点上，按该条映射的 offset 位移）
##
## 两种模式都会叠加显示目标节点【已有直接子节点】的位置与 16px 去重圈；落在圈内的会被标红并加
## "SKIP" —— 生成时该处不会重复实例化。
## 相比 addons/tile_converter/tile_preview.gd 的差别即上述缩略图 / offset / 去重圈。
extends Control

signal zoom_changed(value: float)
## 预览里点中的条目：tiles 模式给 int(image id)，objects 模式给 String(对象名)
signal key_clicked(key: Variant)

const TileTxt := preload("res://addons/active_converter/active_tile_data.gd")
const ObjectData := preload("res://addons/active_converter/active_object_data.gd")
const Placement := preload("res://addons/active_converter/active_placement.gd")

const PAD := 10.0
const DUP_RADIUS := Placement.DUP_RADIUS
## objects 模式下未映射实例的锚点方框半边长（世界像素），用于取景与点选
const OBJECT_BOX_HALF := 12.0

## "tiles" 或 "objects"
var mode := "tiles"
var tiles_to_draw: Array = []
## tile 模式：image id -> { "scene": String, "offset": Vector2 }
## objects 模式：对象名 -> { "scene": String, "offset": Vector2 }
var mapping: Dictionary = {}
## 同上键 -> { "texture": Texture2D, "region": Rect2 }
var thumbs: Dictionary = {}
## [ { "position": Vector2, "name": String } ] —— 目标节点已有直接子节点
var existing_items: Array = []
var occupied_positions: Array = []

## 当前选中的条目（tile = int image id，active = String 对象名）
var selected_key: Variant = -1
var zoom := 1.0
var pan_offset := Vector2.ZERO

var min_x := 0.0
var min_y := 0.0
var max_x := 0.0
var max_y := 0.0

# 用于给每个 32x32 的 image 生成独有的绿色
var _image_colors: Dictionary = {}
# 用于给每个对象名生成独有的暖色（objects 模式未映射实例）
var _object_colors: Dictionary = {}
# 中键拖动平移状态
var _dragging := false


func _ready() -> void:
	# 视口式预览：铺满父 ScrollContainer，不依赖滚动条
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(320, 240)
	# 像素风：放大预览时用最近邻过滤，避免发糊
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func set_data(p_tiles: Array, p_mapping: Dictionary, p_thumbs: Dictionary, p_existing: Array, p_mode: String = "tiles") -> void:
	mode = p_mode if p_mode == "objects" else "tiles"
	tiles_to_draw = p_tiles
	mapping = p_mapping
	thumbs = p_thumbs
	existing_items = p_existing
	occupied_positions = []
	for item in existing_items:
		occupied_positions.append(item["position"])
	_calculate_bounds()
	queue_redraw()


func set_selected_key(key: Variant) -> void:
	selected_key = key
	queue_redraw()


func set_zoom(value: float) -> void:
	zoom = clampf(value, 0.1, 10.0)
	queue_redraw()
	zoom_changed.emit(zoom)


func reset_view() -> void:
	zoom = 1.0
	pan_offset = Vector2.ZERO
	queue_redraw()
	zoom_changed.emit(zoom)


# ---------------------------------------------------------------- 坐标换算

func _to_screen(p: Vector2) -> Vector2:
	return (p - Vector2(min_x, min_y) + Vector2(PAD, PAD)) * zoom + pan_offset


func _rect_to_screen(r: Rect2) -> Rect2:
	return Rect2(_to_screen(r.position), r.size * zoom)


func _offset_of(key: Variant) -> Vector2:
	var entry: Dictionary = mapping.get(key, {})
	return entry.get("offset", Vector2.ZERO)


## 映射缩略图在世界坐标下的矩形：等比缩放到原图块矩形内，再按 offset 位移（中心对齐锚点）
func _thumb_world_rect(row: Dictionary) -> Rect2:
	var tile_rect := TileTxt.row_rect(row)
	var offset := _offset_of(int(row["image"]))
	var thumb: Dictionary = thumbs.get(int(row["image"]), {})
	var tex: Texture2D = thumb.get("texture")
	var region: Rect2 = thumb.get("region", Rect2())
	if tex == null or region.size.x <= 0.0 or region.size.y <= 0.0:
		return Rect2(tile_rect.position + offset, tile_rect.size)
	var scale := minf(tile_rect.size.x / region.size.x, tile_rect.size.y / region.size.y)
	var size := region.size * scale
	return Rect2(tile_rect.get_center() + offset - size * 0.5, size)


# ---------------------------------------------------------------- objects 模式几何

## 实例锚点（CTF 的 x/y）世界坐标：已叠加上该对象名映射的 offset
func _object_anchor(row: Dictionary) -> Vector2:
	return ObjectData.anchor_position(row) + _offset_of(String(row["name"]))


## 未映射实例的锚点方框（世界坐标，仅用于取景/点选）
func _object_box_world_rect(row: Dictionary) -> Rect2:
	var anchor := _object_anchor(row)
	return Rect2(anchor - Vector2(OBJECT_BOX_HALF, OBJECT_BOX_HALF),
		Vector2(OBJECT_BOX_HALF, OBJECT_BOX_HALF) * 2.0)


## 已映射实例：缩略图按原帧尺寸居中在锚点上（就是场景根节点的落点）
func _object_thumb_world_rect(row: Dictionary) -> Rect2:
	var anchor := _object_anchor(row)
	var thumb: Dictionary = thumbs.get(String(row["name"]), {})
	var tex: Texture2D = thumb.get("texture")
	var region: Rect2 = thumb.get("region", Rect2())
	if tex == null or region.size.x <= 0.0 or region.size.y <= 0.0:
		return _object_box_world_rect(row)
	return Rect2(anchor - region.size * 0.5, region.size)


func _calculate_bounds() -> void:
	var rects: Array = []
	if mode == "objects":
		for row in tiles_to_draw:
			if mapping.has(String(row["name"])):
				rects.append(_object_thumb_world_rect(row))
			else:
				rects.append(_object_box_world_rect(row))
	else:
		for row in tiles_to_draw:
			rects.append(TileTxt.row_rect(row))
			if mapping.has(int(row["image"])):
				rects.append(_thumb_world_rect(row))
	for item in existing_items:
		var pos: Vector2 = item["position"]
		rects.append(Rect2(pos - Vector2(DUP_RADIUS, DUP_RADIUS), Vector2(DUP_RADIUS, DUP_RADIUS) * 2.0))
	if rects.is_empty():
		min_x = 0.0
		min_y = 0.0
		max_x = 100.0
		max_y = 100.0
		return
	var bounds: Rect2 = rects[0]
	for r in rects:
		bounds = bounds.merge(r)
	min_x = bounds.position.x
	min_y = bounds.position.y
	max_x = bounds.end.x
	max_y = bounds.end.y


# ---------------------------------------------------------------- 输入

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_on_view_click(mb.position)
			accept_event()
			return
		match mb.button_index:
			MOUSE_BUTTON_MIDDLE:
				_dragging = mb.pressed
				accept_event()
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				var factor := 1.1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.1
				_zoom_at(mb.position, factor)
				accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging:
			pan_offset += mm.relative
			queue_redraw()
			accept_event()


## 点击命中：tiles 模式取最上层（绘制顺序靠后）的图块；objects 模式取最近的实例锚点
func _on_view_click(screen_pos: Vector2) -> void:
	var hit: Variant = null
	if mode == "objects":
		var best := INF
		for row in tiles_to_draw:
			var center := _to_screen(_object_anchor(row))
			var dist := center.distance_to(screen_pos)
			if dist <= maxf(6.0, 10.0 * zoom) and dist < best:
				best = dist
				hit = String(row["name"])
	else:
		for row in tiles_to_draw:
			if _rect_to_screen(TileTxt.row_rect(row)).has_point(screen_pos):
				hit = int(row["image"])
	if hit != null:
		selected_key = hit
		queue_redraw()
		key_clicked.emit(hit)


## 以鼠标屏幕位置为锚点缩放（与 Godot 编辑器一致）
func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var new_zoom := clampf(zoom * factor, 0.1, 10.0)
	if is_equal_approx(new_zoom, zoom):
		return
	var world := (screen_pos - pan_offset) / zoom
	zoom = new_zoom
	pan_offset = screen_pos - world * zoom
	queue_redraw()
	zoom_changed.emit(zoom)


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	if tiles_to_draw.is_empty() and existing_items.is_empty():
		return

	var font := ThemeDB.get_fallback_font()
	var font_size := int(maxf(5.0, 8.0 * zoom))

	if mode == "objects":
		_draw_objects(font, font_size)
	else:
		_draw_tiles(font, font_size)
	_draw_existing_items(font, font_size)


## tiles 模式：图块 / 场景缩略图 + 标签 + 选中高亮
func _draw_tiles(font: Font, font_size: int) -> void:
	# ---------- 第一阶段：图块 / 场景缩略图 ----------
	for row in tiles_to_draw:
		var image_id := int(row["image"])
		var tile_rect := _rect_to_screen(TileTxt.row_rect(row))
		if mapping.has(image_id):
			var anchor := TileTxt.anchor_position(row) + _offset_of(image_id)
			var dup := Placement.is_occupied(anchor, occupied_positions, [])
			# 原格位参考框（缩略图被 offset 推开后，还能看出它原本占哪一格）
			draw_rect(tile_rect, Color(1, 1, 1, 0.15), false, 1.0)
			var dest := _rect_to_screen(_thumb_world_rect(row))
			var thumb: Dictionary = thumbs.get(image_id, {})
			var tex: Texture2D = thumb.get("texture")
			if tex != null:
				var region: Rect2 = thumb.get("region", Rect2())
				if region.size.x <= 0.0 or region.size.y <= 0.0:
					region = Rect2(Vector2.ZERO, Vector2(tex.get_size()))
				draw_texture_rect_region(tex, dest, region)
			else:
				draw_rect(dest, Color(0.9, 0.45, 0.1, 0.55), true)
			draw_rect(dest, Color(1, 1, 1, 0.9), false, maxf(1.0, zoom))
			# 实例原点 = 图块中心 + offset
			draw_circle(_to_screen(anchor), maxf(1.5, 1.5 * zoom), Color(1.0, 1.0, 0.2))
			if dup:
				draw_rect(dest, Color(1.0, 0.25, 0.2), false, maxf(2.0, 2.0 * zoom))
		else:
			var color := _get_tile_color(row)
			color.a = clampf(color.a, 0.2, 1.0)
			draw_rect(tile_rect, color, true)
			draw_rect(tile_rect, Color.BLACK, false, maxf(1.0, zoom))

	# ---------- 标签（最上层，不被图块覆盖） ----------
	for row in tiles_to_draw:
		var image_id := int(row["image"])
		var rect := _rect_to_screen(TileTxt.row_rect(row))
		if mapping.has(image_id):
			var offset := _offset_of(image_id)
			var dup := Placement.is_occupied(
				TileTxt.anchor_position(row) + offset, occupied_positions, [])
			_draw_label_with_bg(font, Vector2(rect.position.x, rect.end.y + 2),
				"img%d" % image_id, font_size, Color.WHITE)
			var text := String(mapping[image_id].get("scene", "")).get_file()
			if offset != Vector2.ZERO:
				text += " (%d,%d)" % [int(offset.x), int(offset.y)]
			if dup:
				text += "  · SKIP"
			_draw_label_with_bg(font, Vector2(rect.position.x, rect.end.y + font_size + 3),
				text, font_size, Color(1.0, 0.35, 0.3) if dup else Color.YELLOW)
		else:
			var text := "img%d" % image_id
			var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
			var center := rect.get_center()
			_draw_label_with_bg(font, center + Vector2(-text_size.x * 0.5, font_size * 0.5),
				text, font_size, Color.WHITE)

	# 选中的 image：高亮边框（最上层）
	if typeof(selected_key) == TYPE_INT and int(selected_key) != -1:
		for row in tiles_to_draw:
			if int(row["image"]) == int(selected_key):
				draw_rect(_rect_to_screen(TileTxt.row_rect(row)), Color.YELLOW, false, maxf(2.0, 2.0 * zoom))


## objects 模式：实例锚点（或映射缩略图）+ 标签 + 选中高亮
func _draw_objects(font: Font, font_size: int) -> void:
	# ---------- 第一阶段：锚点 / 缩略图 ----------
	for row in tiles_to_draw:
		var object_name := String(row["name"])
		var anchor := _object_anchor(row)
		var anchor_screen := _to_screen(anchor)
		var box_rect := _rect_to_screen(_object_box_world_rect(row))
		var dup := Placement.is_occupied(anchor, occupied_positions, [])
		if mapping.has(object_name):
			# 锚点参考框（缩略图被 offset 推开后，还能看出实例原本落在哪）
			draw_rect(box_rect, Color(1, 1, 1, 0.15), false, 1.0)
			var dest := _rect_to_screen(_object_thumb_world_rect(row))
			var thumb: Dictionary = thumbs.get(object_name, {})
			var tex: Texture2D = thumb.get("texture")
			if tex != null:
				var region: Rect2 = thumb.get("region", Rect2())
				if region.size.x <= 0.0 or region.size.y <= 0.0:
					region = Rect2(Vector2.ZERO, Vector2(tex.get_size()))
				draw_texture_rect_region(tex, dest, region)
			else:
				draw_rect(dest, Color(0.9, 0.45, 0.1, 0.55), true)
			draw_rect(dest, Color(1, 1, 1, 0.9), false, maxf(1.0, zoom))
			# 实例原点 = CTF 的 x/y + offset
			draw_circle(anchor_screen, maxf(1.5, 1.5 * zoom), Color(1.0, 1.0, 0.2))
			if dup:
				draw_rect(dest, Color(1.0, 0.25, 0.2), false, maxf(2.0, 2.0 * zoom))
		else:
			var color := _get_object_color(object_name)
			draw_rect(box_rect, color, false, maxf(1.0, zoom))
			draw_circle(anchor_screen, maxf(1.5, 1.8 * zoom), color)

	# ---------- 标签 ----------
	for row in tiles_to_draw:
		var object_name := String(row["name"])
		var anchor := _object_anchor(row)
		var anchor_screen := _to_screen(anchor)
		var label_pos := Vector2(anchor_screen.x + OBJECT_BOX_HALF * zoom, anchor_screen.y - 2.0)
		if mapping.has(object_name):
			var offset := _offset_of(object_name)
			var dup := Placement.is_occupied(anchor, occupied_positions, [])
			var text := "%s -> %s" % [object_name, String(mapping[object_name].get("scene", "")).get_file()]
			if offset != Vector2.ZERO:
				text += " (%d,%d)" % [int(offset.x), int(offset.y)]
			if dup:
				text += "  · SKIP"
			_draw_label_with_bg(font, label_pos, text, font_size,
				Color(1.0, 0.35, 0.3) if dup else Color.YELLOW)
		else:
			_draw_label_with_bg(font, label_pos, object_name, font_size, Color.WHITE)

	# 选中的对象名：所有实例加黄框
	if typeof(selected_key) == TYPE_STRING and not String(selected_key).is_empty():
		for row in tiles_to_draw:
			if String(row["name"]) == String(selected_key):
				draw_rect(_rect_to_screen(_object_box_world_rect(row)), Color.YELLOW, false, maxf(2.0, 2.0 * zoom))


## 两种模式共用：目标节点已有子节点的去重圈 + 名称标签
func _draw_existing_items(font: Font, font_size: int) -> void:
	for item in existing_items:
		var center := _to_screen(item["position"])
		var radius := DUP_RADIUS * zoom
		draw_arc(center, radius, 0.0, TAU, 28, Color(0.3, 0.9, 1.0, 0.9), maxf(1.0, zoom))
		draw_line(center - Vector2(radius, 0.0), center + Vector2(radius, 0.0), Color(0.3, 0.9, 1.0, 0.5), maxf(1.0, zoom))
		draw_circle(center, maxf(1.5, 1.8 * zoom), Color(0.3, 0.9, 1.0))
		_draw_label_with_bg(font, Vector2(center.x + 4.0, center.y - 4.0),
			String(item.get("name", "?")), font_size, Color(0.6, 0.95, 1.0))


## 根据对象名生成一个唯一的暖色调（objects 模式未映射实例用，与图块的绿色区分开）
func _get_object_color(object_name: String) -> Color:
	if _object_colors.has(object_name):
		return _object_colors[object_name]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(object_name)
	var color := Color.from_hsv(
		rng.randf_range(0.03, 0.14),
		rng.randf_range(0.55, 1.0),
		rng.randf_range(0.65, 1.0),
		1.0)
	_object_colors[object_name] = color
	return color


## 根据 image 生成一个唯一的绿色调（32x32 的图块用）
func _get_image_green(img_id: int) -> Color:
	if _image_colors.has(img_id):
		return _image_colors[img_id]
	var rng := RandomNumberGenerator.new()
	rng.seed = img_id
	var color := Color.from_hsv(
		rng.randf_range(0.22, 0.42),
		rng.randf_range(0.6, 1.0),
		rng.randf_range(0.5, 0.9),
		1.0)
	_image_colors[img_id] = color
	return color


## 未映射图块按尺寸区分底色（沿用 tile_converter 的配色规则）
func _get_tile_color(row: Dictionary) -> Color:
	var w := float(row["w"])
	var h := float(row["h"])
	if w == 32.0 and h == 32.0:
		return _get_image_green(int(row["image"]))
	if (w > 32.0 and w <= 64.0) or (h > 32.0 and h <= 64.0):
		return Color.ORANGE
	if (w > 96.0 and w <= 160.0) or (h > 96.0 and h <= 160.0):
		return Color.BLUE
	if (w > 160.0 and w <= 320.0) or (h > 160.0 and h <= 320.0):
		var c := Color.PURPLE
		c.a = 0.3
		return c
	if w > 320.0 or h > 320.0:
		var c := Color.WHITE
		c.a = 0.3
		return c
	return Color.GRAY


## 绘制带半透明黑底的文字（黑底保证任何背景下都能读清）
func _draw_label_with_bg(font: Font, baseline_pos: Vector2, text: String, font_size: int, color: Color) -> void:
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	draw_rect(Rect2(baseline_pos.x, baseline_pos.y - font_size, text_size.x, font_size + 2), Color(0, 0, 0, 0.55))
	draw_string(font, baseline_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
