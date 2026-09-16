@tool
## Mapping Window（Active Converter）。
##
## 两种模式（mode）：
##  - "images" ：键 = TileExporter 文本里的 image id（int），行数据来自 tile 文本
##  - "objects"：键 = 反编译出来的 MFA Active 对象名（String），行数据来自 objects.json
##
## 与 addons/tile_converter/mapping_window.gd 同构，差别：
##  - 右侧不是 tileset 图块，而是【场景池】：点击场景 = 把当前选中的条目映射到它
##  - 中间多了一组 offset（X / Y）编辑器 —— 改的是“当前选中条目的那条映射”的偏移（用户拍板：偏移随映射走）
##  - 上半预览会画出映射场景的缩略图（按 offset 位移）与目标节点已有物品的 16px 去重圈
##
## 任何改动都会立刻写回 res://addons/active_converter/mapping.json（自动记忆，可手动清除）。
extends Window

const Placement := preload("res://addons/active_converter/active_placement.gd")
const PreviewScript := preload("res://addons/active_converter/active_preview.gd")
const PoolDropScript := preload("res://addons/active_converter/scene_pool_drop.gd")
const SceneThumb := preload("res://addons/active_converter/scene_thumb.gd")

## 单个场景按钮内缩略图的显示边长（随缩放滑条同比放大）
const MAX_TILE_PX := 128.0

const MODE_IMAGES := "images"
const MODE_OBJECTS := "objects"

var rows: Array = []
## 实例的父容器（目标节点）
var target: Node = null
## mapping_store 实例（本窗口直接在其上编辑，保证实时落盘）
var store = null
var on_apply := Callable()
## MODE_IMAGES（tile 的 image id）或 MODE_OBJECTS（MFA active 对象名）
## （注意：不能叫 mode —— Window 自带原生 mode 属性，会报 "Member mode redefined"）
var map_mode := MODE_IMAGES

## 与 store.mappings / store.object_mappings 是同一个字典（键 -> { "scene": String, "offset": Vector2 }）
var mapping: Dictionary = {}
## 与 store.scenes 是同一个数组
var pool: Array = []

## 当前选中的键（int image id 或 String 对象名）
var selected_key: Variant = null
var tile_scale := 1.0

# ---------------- 左侧
var left_list: VBoxContainer
var _left_buttons: Dictionary = {}
# ---------------- 中间
var current_selection_label: Label
var hint_label: Label
var offset_x_spin: SpinBox
var offset_y_spin: SpinBox
var mapping_list: VBoxContainer
# ---------------- 右侧（scene_pool_drop.gd 的 FlowContainer，带 files_dropped 信号）
var right_container
var pool_count_label: Label
var pool_zoom_slider: HSlider
var _pool_labels: Dictionary = {}
# ---------------- 预览（active_preview.gd 的 Control）
var preview_control
var preview_zoom_slider: HSlider
var target_label: Label


func init(p_rows: Array, p_target: Node, p_store, p_on_apply: Callable, p_mode: String = MODE_IMAGES) -> void:
	rows = p_rows
	target = p_target
	store = p_store
	on_apply = p_on_apply
	map_mode = MODE_OBJECTS if p_mode == MODE_OBJECTS else MODE_IMAGES
	mapping = store.object_mappings if map_mode == MODE_OBJECTS else store.mappings
	pool = store.scenes

	title = ("Active Object" if map_mode == MODE_OBJECTS else "Image") + " <-> Scene Mapping (Active Converter)"
	size = Vector2(1180, 820)
	min_size = Vector2(940, 640)
	close_requested.connect(_on_cancel)

	build_ui()
	populate_left()
	populate_right()
	populate_mapping_list()
	_update_pool_marks()
	_refresh_preview()
	_update_target_label()


# ---------------------------------------------------------------- 模式差异封装
# 两种模式的差别只在【键的类型】与【落点算法】，这里集中收口，其余 UI 逻辑完全共用。

func _store_scene(key: Variant) -> String:
	return store.get_object_scene(str(key)) if map_mode == MODE_OBJECTS else store.get_scene(int(key))


func _store_set_mapping(key: Variant, scene_path: String) -> void:
	if map_mode == MODE_OBJECTS:
		store.set_object_mapping(str(key), scene_path)
	else:
		store.set_mapping(int(key), scene_path)


func _store_set_offset(key: Variant, offset: Vector2) -> void:
	if map_mode == MODE_OBJECTS:
		store.set_object_offset(str(key), offset)
	else:
		store.set_offset(int(key), offset)


func _store_erase(key: Variant) -> void:
	if map_mode == MODE_OBJECTS:
		store.erase_object_mapping(str(key))
	else:
		store.erase_mapping(int(key))


## 行 -> 键计数（tile 用 image id，active 用对象名）
func _row_counts() -> Dictionary:
	var counts := {}
	for row in rows:
		var key: Variant = str(row["name"]) if map_mode == MODE_OBJECTS else int(row["image"])
		counts[key] = int(counts.get(key, 0)) + 1
	return counts


## 键排序：image id 按数值，对象名按字典序
func _sorted_keys(counts: Dictionary) -> Array:
	var keys: Array = counts.keys()
	if map_mode == MODE_OBJECTS:
		keys.sort_custom(func(a, b): return String(a) < String(b))
	else:
		keys.sort()
	return keys


## 左列表按钮文本
func _key_title(key: Variant, count: int) -> String:
	if map_mode == MODE_OBJECTS:
		return "%s (%d instances)" % [str(key), count]
	return "img %d (%d tiles)" % [int(key), count]


## 中间“当前选中”行的前缀
func _selected_prefix() -> String:
	return "Selected object: " if map_mode == MODE_OBJECTS else "Selected image: "


# ---------------------------------------------------------------- UI 构建

func build_ui() -> void:
	var main_vb := VBoxContainer.new()
	add_child(main_vb)
	main_vb.anchor_right = 1.0
	main_vb.anchor_bottom = 1.0

	var split := VSplitContainer.new()
	main_vb.add_child(split)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = int(size.y * 0.52)

	# ----- 上半：预览区（蓝色调） -----
	var top_panel := Panel.new()
	split.add_child(top_panel)
	var top_style := StyleBoxFlat.new()
	top_style.bg_color = Color(0.15, 0.18, 0.25, 1.0)
	top_panel.add_theme_stylebox_override("panel", top_style)

	var preview_vb := VBoxContainer.new()
	top_panel.add_child(preview_vb)
	preview_vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var preview_toolbar := HBoxContainer.new()
	preview_vb.add_child(preview_toolbar)

	var preview_label := Label.new()
	preview_label.text = "Active Preview (all instances)" if map_mode == MODE_OBJECTS else "Tile Preview (all tiles)"
	preview_toolbar.add_child(preview_label)

	target_label = Label.new()
	target_label.text = "Target: (none)"
	preview_toolbar.add_child(target_label)

	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh used items"
	refresh_btn.tooltip_text = "Re-scan the target node's children (used for the 16px duplicate check)."
	refresh_btn.pressed.connect(_refresh_existing)
	preview_toolbar.add_child(refresh_btn)

	var use_sel_btn := Button.new()
	use_sel_btn.text = "Use current selection"
	use_sel_btn.tooltip_text = "Take the node currently selected in the Scene dock as the target container."
	use_sel_btn.pressed.connect(_use_current_selection)
	preview_toolbar.add_child(use_sel_btn)

	var reset_view_btn := Button.new()
	reset_view_btn.text = "Reset view"
	reset_view_btn.pressed.connect(_on_reset_view)
	preview_toolbar.add_child(reset_view_btn)

	preview_toolbar.add_spacer(false)
	var zoom_label := Label.new()
	zoom_label.text = "Zoom:"
	preview_toolbar.add_child(zoom_label)

	preview_zoom_slider = HSlider.new()
	preview_zoom_slider.custom_minimum_size = Vector2(100, 0)
	preview_zoom_slider.min_value = 0.1
	preview_zoom_slider.max_value = 10.0
	preview_zoom_slider.step = 0.1
	preview_zoom_slider.value = 0.5
	preview_zoom_slider.value_changed.connect(_on_preview_zoom_changed)
	preview_toolbar.add_child(preview_zoom_slider)

	var preview_scroll := ScrollContainer.new()
	preview_vb.add_child(preview_scroll)
	preview_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	preview_control = PreviewScript.new()
	preview_scroll.add_child(preview_control)
	preview_control.set_zoom(0.5)
	preview_control.zoom_changed.connect(_on_preview_zoom_from_wheel)
	preview_control.key_clicked.connect(_on_key_selected)

	# ----- 下半：映射区（深灰） -----
	var bottom_panel := Panel.new()
	split.add_child(bottom_panel)
	var bottom_style := StyleBoxFlat.new()
	bottom_style.bg_color = Color(0.2, 0.2, 0.2, 1.0)
	bottom_panel.add_theme_stylebox_override("panel", bottom_style)

	var mapping_hb := HBoxContainer.new()
	bottom_panel.add_child(mapping_hb)
	mapping_hb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# 左侧：txt 里的 image id
	var left_vb := VBoxContainer.new()
	mapping_hb.add_child(left_vb)
	left_vb.custom_minimum_size = Vector2(220, 0)
	var left_label := Label.new()
	left_label.text = "MFA object names (from objects.json)" if map_mode == MODE_OBJECTS else "Image IDs (from txt)"
	left_vb.add_child(left_label)
	var left_scroll := ScrollContainer.new()
	left_vb.add_child(left_scroll)
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_list = VBoxContainer.new()
	left_scroll.add_child(left_list)

	# 中间：选中 image 的映射 + offset
	var mid_vb := VBoxContainer.new()
	mapping_hb.add_child(mid_vb)
	mid_vb.custom_minimum_size = Vector2(330, 0)

	current_selection_label = Label.new()
	current_selection_label.text = "Selected image: none"
	current_selection_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	mid_vb.add_child(current_selection_label)

	var offset_title := Label.new()
	offset_title.text = "Offset of this mapping (px):"
	mid_vb.add_child(offset_title)

	var offset_hb := HBoxContainer.new()
	mid_vb.add_child(offset_hb)
	var ox_label := Label.new()
	ox_label.text = "X"
	offset_hb.add_child(ox_label)
	offset_x_spin = SpinBox.new()
	offset_x_spin.min_value = -4096.0
	offset_x_spin.max_value = 4096.0
	offset_x_spin.step = 1.0
	offset_x_spin.allow_greater = true
	offset_x_spin.allow_lesser = true
	offset_x_spin.custom_minimum_size = Vector2(84, 0)
	offset_x_spin.value_changed.connect(_on_offset_changed)
	offset_hb.add_child(offset_x_spin)
	var oy_label := Label.new()
	oy_label.text = "Y"
	offset_hb.add_child(oy_label)
	offset_y_spin = SpinBox.new()
	offset_y_spin.min_value = -4096.0
	offset_y_spin.max_value = 4096.0
	offset_y_spin.step = 1.0
	offset_y_spin.allow_greater = true
	offset_y_spin.allow_lesser = true
	offset_y_spin.custom_minimum_size = Vector2(84, 0)
	offset_y_spin.value_changed.connect(_on_offset_changed)
	offset_hb.add_child(offset_y_spin)
	var reset_offset_btn := Button.new()
	reset_offset_btn.text = "0,0"
	reset_offset_btn.tooltip_text = "Reset this mapping's offset to (0, 0)."
	reset_offset_btn.pressed.connect(_on_reset_offset)
	offset_hb.add_child(reset_offset_btn)

	hint_label = Label.new()
	hint_label.text = ""
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	mid_vb.add_child(hint_label)

	var mapping_title := Label.new()
	mapping_title.text = "Current mapping:"
	mid_vb.add_child(mapping_title)
	var mapping_scroll := ScrollContainer.new()
	mid_vb.add_child(mapping_scroll)
	mapping_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mapping_list = VBoxContainer.new()
	mapping_scroll.add_child(mapping_list)

	# 右侧：场景池
	var right_vb := VBoxContainer.new()
	mapping_hb.add_child(right_vb)
	right_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var top_hb := HBoxContainer.new()
	right_vb.add_child(top_hb)
	var right_label := Label.new()
	right_label.text = "Scene pool (click = assign / right-click = remove)"
	top_hb.add_child(right_label)

	pool_count_label = Label.new()
	pool_count_label.text = "0 scenes"
	top_hb.add_child(pool_count_label)

	var add_scenes_btn := Button.new()
	add_scenes_btn.text = "Add Scenes..."
	add_scenes_btn.pressed.connect(_on_add_scenes_pressed)
	top_hb.add_child(add_scenes_btn)

	top_hb.add_spacer(false)
	var scale_label := Label.new()
	scale_label.text = "Zoom:"
	top_hb.add_child(scale_label)
	pool_zoom_slider = HSlider.new()
	pool_zoom_slider.custom_minimum_size = Vector2(100, 0)
	pool_zoom_slider.min_value = 0.5
	pool_zoom_slider.max_value = 4.0
	pool_zoom_slider.step = 0.25
	pool_zoom_slider.value = 1.0
	pool_zoom_slider.value_changed.connect(_on_pool_zoom_changed)
	top_hb.add_child(pool_zoom_slider)

	var pool_scroll := ScrollContainer.new()
	right_vb.add_child(pool_scroll)
	pool_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 禁用横向滚动，强制按视口宽度换行
	pool_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	right_container = PoolDropScript.new()
	right_container.add_theme_constant_override("h_separation", 4)
	right_container.add_theme_constant_override("v_separation", 4)
	right_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_container.files_dropped.connect(_on_files_dropped)
	pool_scroll.add_child(right_container)

	# ----- 底部按钮 -----
	var bottom_hb := HBoxContainer.new()
	main_vb.add_child(bottom_hb)
	var apply_btn := Button.new()
	apply_btn.text = "Generate Scene Instances"
	apply_btn.pressed.connect(_on_apply)
	bottom_hb.add_child(apply_btn)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_on_cancel)
	bottom_hb.add_child(cancel_btn)
	var save_hint := Label.new()
	save_hint.text = "Mapping is saved automatically to addons/active_converter/mapping.json"
	bottom_hb.add_child(save_hint)


# ---------------------------------------------------------------- 列表填充

func populate_left() -> void:
	for child in left_list.get_children():
		child.queue_free()
	_left_buttons.clear()

	var counts := _row_counts()
	for key in _sorted_keys(counts):
		var btn := Button.new()
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.clip_text = true
		btn.pressed.connect(_on_key_selected.bind(key))
		left_list.add_child(btn)
		_left_buttons[key] = btn
	_update_left_marks(counts)


func _update_left_marks(counts: Dictionary = {}) -> void:
	if counts.is_empty():
		counts = _row_counts()
	for key in _left_buttons.keys():
		var btn: Button = _left_buttons[key]
		var mark := "  [mapped]" if mapping.has(key) else ""
		btn.text = _key_title(key, int(counts.get(key, 0))) + mark
		btn.tooltip_text = _store_scene(key)


func _update_pool_marks() -> void:
	var current_scene: String = _store_scene(selected_key) if selected_key != null else ""
	var used := {}
	for key in mapping.keys():
		var scene_path := String(mapping[key].get("scene", ""))
		used[scene_path] = int(used.get(scene_path, 0)) + 1
	for path in _pool_labels.keys():
		var label: Label = _pool_labels[path]
		# ▶ 标记当前选中 image 映射到的场景；括号里是该场景被几个 image 用到
		var text := ("▶ " if path == current_scene else "") + String(path).get_file()
		if used.has(path):
			text += " (%d)" % int(used[path])
		label.text = text
	pool_count_label.text = "%d scenes / %d mappings" % [pool.size(), mapping.size()]


func populate_mapping_list() -> void:
	for child in mapping_list.get_children():
		child.queue_free()

	if mapping.is_empty():
		var empty_label := Label.new()
		empty_label.text = "(no mappings)"
		mapping_list.add_child(empty_label)
		return

	for key in _sorted_keys(mapping):
		var entry: Dictionary = mapping[key]
		var offset: Vector2 = entry.get("offset", Vector2.ZERO)
		var hb := HBoxContainer.new()
		mapping_list.add_child(hb)

		var info_btn := Button.new()
		info_btn.flat = true
		info_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		info_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info_btn.clip_text = true
		var offset_text := "" if offset == Vector2.ZERO else " (%d, %d)" % [int(offset.x), int(offset.y)]
		var key_text := str(key) if map_mode == MODE_OBJECTS else "img %d" % int(key)
		info_btn.text = "%s -> %s%s" % [key_text, String(entry.get("scene", "")).get_file(), offset_text]
		info_btn.tooltip_text = String(entry.get("scene", ""))
		info_btn.pressed.connect(_on_key_selected.bind(key))
		hb.add_child(info_btn)

		var del_btn := Button.new()
		del_btn.text = "×"
		del_btn.custom_minimum_size = Vector2(24, 24)
		del_btn.pressed.connect(_on_remove_mapping.bind(key))
		hb.add_child(del_btn)


func populate_right() -> void:
	for child in right_container.get_children():
		child.queue_free()
	_pool_labels.clear()

	if pool.is_empty():
		var lbl := Label.new()
		lbl.text = "(no scenes yet - use \"Add Scenes...\" or drag .tscn here)"
		right_container.add_child(lbl)
		_update_pool_marks()
		return

	for path in pool:
		var btn := Button.new()
		btn.tooltip_text = "%s\nLeft click = assign to the selected image\nRight click = remove from the pool" % path
		btn.pressed.connect(_on_pool_clicked.bind(path))
		btn.gui_input.connect(_on_pool_item_input.bind(path))

		var thumb := SceneThumb.get_thumb(path)
		var tex: Texture2D = thumb.get("texture")
		var box_size := clampi(int(72.0 * tile_scale), 24, int(MAX_TILE_PX))

		var vbox := VBoxContainer.new()
		vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(vbox)

		var box := TextureRect.new()
		box.texture = tex
		box.custom_minimum_size = Vector2(box_size, box_size)
		box.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		box.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		box.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if thumb.get("region", Rect2()).size.x > 0.0 and tex != null:
			# 只显示第一个精灵的那一块（精灵表场景只显示当前帧，避免糊成一团）
			var atlas := AtlasTexture.new()
			atlas.atlas = tex
			atlas.region = thumb["region"]
			box.texture = atlas
		vbox.add_child(box)

		var name_label := Label.new()
		name_label.text = String(path).get_file()
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.clip_text = true
		name_label.custom_minimum_size = Vector2(box_size, 0)
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(name_label)

		right_container.add_child(btn)
		_pool_labels[path] = name_label

	_update_pool_marks()


# ---------------------------------------------------------------- 交互

func _on_key_selected(key: Variant) -> void:
	selected_key = key
	current_selection_label.text = _selection_text()
	_sync_offset_widgets()
	_update_pool_marks()
	preview_control.set_selected_key(key)


## 当前选中键的显示文本（image id 显示数字，对象名原样显示）
func _key_text() -> String:
	if selected_key == null:
		return "-"
	return str(selected_key) if map_mode == MODE_OBJECTS else str(int(selected_key))


func _is_selected_mapped() -> bool:
	return selected_key != null and mapping.has(selected_key)


## 中间“当前选中”那行文本
func _selection_text() -> String:
	if selected_key == null:
		return _selected_prefix() + "none"
	var entry: Dictionary = mapping.get(selected_key, {})
	if entry.is_empty():
		return _selected_prefix() + "%s (not mapped)" % _key_text()
	var offset: Vector2 = entry.get("offset", Vector2.ZERO)
	return _selected_prefix() + "%s -> %s   offset (%d, %d)" % [
		_key_text(), String(entry.get("scene", "")).get_file(), int(offset.x), int(offset.y)]


func _sync_offset_widgets() -> void:
	var mapped := _is_selected_mapped()
	offset_x_spin.editable = mapped
	offset_y_spin.editable = mapped
	if not mapped:
		offset_x_spin.set_value_no_signal(0.0)
		offset_y_spin.set_value_no_signal(0.0)
		return
	var offset: Vector2 = mapping[selected_key].get("offset", Vector2.ZERO)
	offset_x_spin.set_value_no_signal(offset.x)
	offset_y_spin.set_value_no_signal(offset.y)


func _on_offset_changed(_value: float = 0.0) -> void:
	if not _is_selected_mapped():
		return
	_store_set_offset(selected_key, Vector2(offset_x_spin.value, offset_y_spin.value))
	_after_mapping_changed()


func _on_reset_offset() -> void:
	if not _is_selected_mapped():
		return
	_store_set_offset(selected_key, Vector2.ZERO)
	_sync_offset_widgets()
	_after_mapping_changed()


func _on_pool_clicked(path: String) -> void:
	if selected_key == null:
		_set_hint("Select an entry on the left first, then click a scene to assign it.")
		return
	_store_set_mapping(selected_key, path)
	_after_mapping_changed()


func _on_pool_item_input(event: InputEvent, path: String) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			store.remove_scene(path)
			populate_right()
			_set_hint("Removed from pool: %s" % String(path).get_file())


func _on_remove_mapping(key: Variant) -> void:
	_store_erase(key)
	if selected_key == key:
		current_selection_label.text = _selection_text()
	_sync_offset_widgets()
	_after_mapping_changed()


func _on_add_scenes_pressed() -> void:
	var fd := EditorFileDialog.new()
	fd.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILES
	fd.add_filter("*.tscn", "Godot Scene")
	fd.size = Vector2(1400, 1000)
	fd.canceled.connect(fd.queue_free)
	fd.files_selected.connect(func(paths: PackedStringArray) -> void:
		_on_scenes_selected(paths)
		fd.queue_free())
	add_child(fd)
	fd.popup_centered()


func _on_scenes_selected(paths: PackedStringArray) -> void:
	_on_files_dropped(paths)


func _on_files_dropped(paths: PackedStringArray) -> void:
	var added := 0
	for path in paths:
		if path.ends_with(".tscn") or path.ends_with(".scn"):
			if store.add_scene(path):
				added += 1
	populate_right()
	_set_hint("Added %d scene(s) to the pool." % added)


func _on_pool_zoom_changed(value: float) -> void:
	tile_scale = value
	populate_right()


func _on_preview_zoom_changed(value: float) -> void:
	if preview_control:
		preview_control.set_zoom(value)


func _on_preview_zoom_from_wheel(value: float) -> void:
	# set_value 相同值不会再触发 value_changed，不会造成循环
	preview_zoom_slider.set_value(value)


func _on_reset_view() -> void:
	if preview_control:
		preview_control.reset_view()


func _use_current_selection() -> void:
	var edited := EditorInterface.get_edited_scene_root()
	for node in EditorInterface.get_selection().get_selected_nodes():
		if edited != null and (node == edited or edited.is_ancestor_of(node)):
			target = node
			_update_target_label()
			_refresh_preview()
			_set_hint("Target is now: %s" % String(node.get_path()))
			return
	_set_hint("Nothing usable selected in the Scene dock (the node must belong to the edited scene).")


func _refresh_existing() -> void:
	_refresh_preview()
	_set_hint("Re-scanned existing items under the target node.")


func _update_target_label() -> void:
	if target == null or not is_instance_valid(target):
		target_label.text = "Target: (none)"
		return
	target_label.text = "Target: %s  (%d child nodes)" % [String(target.get_path()), target.get_child_count()]


func _refresh_preview() -> void:
	var thumbs := {}
	for key in mapping.keys():
		var scene_path := String(mapping[key].get("scene", ""))
		if not scene_path.is_empty():
			thumbs[key] = SceneThumb.get_thumb(scene_path)
	preview_control.set_data(rows, mapping, thumbs, Placement.collect_existing_items(target), map_mode)
	preview_control.set_selected_key(selected_key)


func _after_mapping_changed() -> void:
	_update_left_marks()
	_update_pool_marks()
	populate_mapping_list()
	_refresh_preview()
	if selected_key != null and mapping.has(selected_key):
		current_selection_label.text = _selection_text()
	_update_target_label()


func _set_hint(text: String) -> void:
	hint_label.text = text


# ---------------------------------------------------------------- 收尾

func _on_apply() -> void:
	if mapping.is_empty():
		_show_info("No mappings defined.\nAssign at least one entry to a scene first.")
		return
	if target == null or not is_instance_valid(target):
		_show_info("No target node.\nSelect the parent container in the Scene dock, then press \"Use current selection\".")
		return
	on_apply.call(mapping, target)
	queue_free()


func _on_cancel() -> void:
	queue_free()


func _show_info(msg: String) -> void:
	var win := Window.new()
	win.title = "Information"
	win.size = Vector2(420, 200)
	win.close_requested.connect(win.queue_free)
	add_child(win)
	win.popup_centered()

	var vb := VBoxContainer.new()
	win.add_child(vb)
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0

	var label := Label.new()
	label.text = msg
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(label)

	var close_btn := Button.new()
	close_btn.text = "OK"
	close_btn.pressed.connect(win.queue_free)
	vb.add_child(close_btn)
