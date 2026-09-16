@tool
## Active Converter 的底部面板 dock。
##
## 两种数据来源（二选一载入，载入后按同一套流程走 2~4 步）：
##   A. TileExporter v1.0 文本（tile / backdrop 层）：Open TXT file
##   B. 反编译出来的 objects.json（MFA 的 Active 实例位置）：Open objects.json
##
## 流程（与 Tile Converter 对齐的 1~4 步）：
##   1.  Open TXT file / Open objects.json —— 载入上面两种数据之一
##   2.  Preview                          —— 整关示意预览（含映射缩略图与已有物品去重圈）
##   3.  Add scenes to pool               —— 把 .tscn 加入场景池（Mapping Window 右侧可点击的场景列表）
##   4.  Map & Generate                   —— 开 Mapping Window 配 键 -> 场景 + 每条映射的 offset，然后生成
##
## 生成逻辑（用户拍板）：
##   - 在【场景树里选中的节点】下实例化场景
##       · tile 模式：落点 = 图块矩形中心 + 该映射的 offset
##       · active 模式：落点 = 实例 x/y（CTF 的 hot spot 坐标）+ 该映射的 offset
##   - 目标节点直接子节点中若已有落点距离 16px 以内的物品（模糊检测），则跳过不重复生成
##   - 整批生成走 EditorUndoRedoManager，可一次性 Ctrl+Z 撤销；实例上打 meta 便于整体清除
extends Control

const TileTxt := preload("res://addons/active_converter/active_tile_data.gd")
const ObjectData := preload("res://addons/active_converter/active_object_data.gd")
const Placement := preload("res://addons/active_converter/active_placement.gd")
const StoreScript := preload("res://addons/active_converter/mapping_store.gd")
const PreviewScript := preload("res://addons/active_converter/active_preview.gd")
const WindowScript := preload("res://addons/active_converter/active_mapping_window.gd")
const SceneThumb := preload("res://addons/active_converter/scene_thumb.gd")

## 数据来源：SOURCE_TILES（TileExporter 文本）或 SOURCE_OBJECTS（objects.json）
const SOURCE_TILES := "tiles"
const SOURCE_OBJECTS := "objects"

var plugin: EditorPlugin = null
var store = null

## 当前生效的行（tile 行 / active 行），供预览与生成使用
var rows: Array = []
## 数据来源（SOURCE_TILES / SOURCE_OBJECTS）
var source_kind := SOURCE_TILES
## 最后一次解析结果（切换“包含假实例”勾选时按它重算 rows）
var object_result: Dictionary = {}
var txt_path := ""
## 打开 Mapping Window 时锁定的目标节点（4. 按下时取当前选中）
var target: Node = null

var open_btn: Button
var open_objects_btn: Button
var include_fake_check: CheckBox
var preview_btn: Button
var pool_btn: Button
var map_btn: Button
var clear_generated_btn: Button
var clear_mapping_btn: Button
var status_label: Label
var info_label: Label
var target_label: Label


func setup(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin


func _ready() -> void:
	store = StoreScript.new()
	create_ui()
	EditorInterface.get_selection().selection_changed.connect(_update_target_label)
	_update_labels()


func create_ui() -> void:
	var vb := VBoxContainer.new()
	vb.name = "VBoxContainer"
	add_child(vb)

	var row1 := HBoxContainer.new()
	vb.add_child(row1)

	open_btn = Button.new()
	open_btn.text = "1a. Open TXT file (tiles)"
	open_btn.tooltip_text = "TileExporter v1.0 text: one line per backdrop tile (x= y= w= h= obstacle= image=)."
	open_btn.pressed.connect(_on_open_pressed)
	row1.add_child(open_btn)

	open_objects_btn = Button.new()
	open_objects_btn.text = "1b. Open objects.json (actives)"
	open_objects_btn.tooltip_text = "IR objects.json exported by MFSPLCli: every MFA Active instance with its CTF x/y position."
	open_objects_btn.pressed.connect(_on_open_objects_pressed)
	row1.add_child(open_objects_btn)

	preview_btn = Button.new()
	preview_btn.text = "2. Preview all tiles"
	preview_btn.disabled = true
	preview_btn.pressed.connect(_on_preview_pressed)
	row1.add_child(preview_btn)

	pool_btn = Button.new()
	pool_btn.text = "3. Add scenes to pool (.tscn)"
	pool_btn.pressed.connect(_on_pool_pressed)
	row1.add_child(pool_btn)

	var row1b := HBoxContainer.new()
	vb.add_child(row1b)

	include_fake_check = CheckBox.new()
	include_fake_check.text = "Include fake instances (parentType != 0)"
	include_fake_check.tooltip_text = "MFA fake instances: objects referenced by the frame but not placed on the field (their x/y are 0,0). Off by default."
	include_fake_check.button_pressed = false
	include_fake_check.disabled = true
	include_fake_check.toggled.connect(_on_include_fake_toggled)
	row1b.add_child(include_fake_check)

	var row2 := HBoxContainer.new()
	vb.add_child(row2)

	map_btn = Button.new()
	map_btn.text = "4. Map images & Generate Scene Instances"
	map_btn.disabled = true
	map_btn.pressed.connect(_on_map_pressed)
	row2.add_child(map_btn)

	clear_generated_btn = Button.new()
	clear_generated_btn.text = "Remove generated instances (selected node)"
	clear_generated_btn.tooltip_text = "Remove the direct children that were created by this plugin's meta tag (undoable)."
	clear_generated_btn.pressed.connect(_on_clear_generated_pressed)
	row2.add_child(clear_generated_btn)

	clear_mapping_btn = Button.new()
	clear_mapping_btn.text = "Clear saved mapping"
	clear_mapping_btn.tooltip_text = "Delete every image -> scene entry in addons/active_converter/mapping.json."
	clear_mapping_btn.pressed.connect(_on_clear_mapping_pressed)
	row2.add_child(clear_mapping_btn)

	status_label = Label.new()
	status_label.text = "No file loaded"
	vb.add_child(status_label)

	info_label = Label.new()
	info_label.text = ""
	vb.add_child(info_label)

	target_label = Label.new()
	target_label.text = ""
	vb.add_child(target_label)


# ---------------------------------------------------------------- 1. 打开 txt

func _on_open_pressed() -> void:
	var fd := EditorFileDialog.new()
	fd.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	fd.add_filter("*.txt", "TileExporter TXT")
	fd.size = Vector2(1400, 1000)
	fd.canceled.connect(fd.queue_free)
	fd.file_selected.connect(func(path: String) -> void:
		_on_file_selected(path)
		fd.queue_free())
	add_child(fd)
	fd.popup_centered()


func _on_file_selected(path: String) -> void:
	var result := TileTxt.parse_file(path)
	if not bool(result["ok"]):
		status_label.text = "Failed to load: %s" % path.get_file()
		_show_info_window("Cannot parse this file:\n%s" % String(result["error"]))
		return
	txt_path = path
	source_kind = SOURCE_TILES
	object_result = {}
	rows = result["rows"]
	# format: full（带 TileExporter 头与 Total tiles: 行）/ bare list（只有 Tile 行的裸列表）
	var format_name := "full" if String(result.get("format", "")) == "full" else "bare list"
	status_label.text = "Loaded: %s — %d tiles (%s format)" % [path.get_file(), rows.size(), format_name]
	var warning := String(result.get("warning", ""))
	if not warning.is_empty():
		status_label.text += "   (%s)" % warning
	_after_source_changed()


# ---------------------------------------------------------------- 1b. 打开 objects.json（MFA active 位置）

func _on_open_objects_pressed() -> void:
	var fd := EditorFileDialog.new()
	fd.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	fd.add_filter("*.json", "MFSPLCli objects.json")
	fd.size = Vector2(1400, 1000)
	fd.canceled.connect(fd.queue_free)
	fd.file_selected.connect(func(path: String) -> void:
		_on_objects_file_selected(path)
		fd.queue_free())
	add_child(fd)
	fd.popup_centered()


func _on_objects_file_selected(path: String) -> void:
	var result := ObjectData.parse_file(path, include_fake_check.button_pressed)
	if not bool(result["ok"]):
		status_label.text = "Failed to load: %s" % path.get_file()
		_show_info_window("Cannot use this objects.json:\n%s\n\n(Expected the IR produced by MFSPLCli: Nebula.Tools/MFSPLCli.)" % String(result["error"]))
		return
	txt_path = path
	source_kind = SOURCE_OBJECTS
	object_result = result
	rows = result["rows"]
	_after_source_changed()


## 切换“包含假实例”勾选：不重新读盘，按最后一次解析结果重算行
func _on_include_fake_toggled(pressed: bool) -> void:
	if source_kind != SOURCE_OBJECTS or object_result.is_empty():
		return
	rows = ObjectData.filter_rows(object_result["all_rows"], pressed)
	_after_source_changed()


## 载入数据 / 切换过滤后统一刷新界面状态
func _after_source_changed() -> void:
	include_fake_check.disabled = source_kind != SOURCE_OBJECTS
	preview_btn.disabled = rows.is_empty()
	map_btn.disabled = rows.is_empty()

	if source_kind == SOURCE_OBJECTS:
		var frames: Array = object_result.get("frames", [])
		var frame_name := "" if frames.is_empty() else String((frames[0] as Dictionary).get("name", ""))
		status_label.text = "Loaded: %s — %d Active instance(s) in %d object type(s), %d frame(s)" % [
			txt_path.get_file(), rows.size(), _unique_key_count(), frames.size()]
		if not frame_name.is_empty():
			status_label.text += "  [frame: %s]" % frame_name
		var warning := String(object_result.get("warning", ""))
		if not warning.is_empty():
			status_label.text += "   (%s)" % warning
	_update_labels()


# ---------------------------------------------------------------- 2. 预览

func _on_preview_pressed() -> void:
	var objects_mode := source_kind == SOURCE_OBJECTS
	var title_text := "Active Preview (all instances)" if objects_mode else "Tile Preview (all tiles)"
	var win := Window.new()
	win.title = title_text
	win.size = Vector2(1200, 800)
	win.min_size = Vector2(600, 400)
	win.close_requested.connect(win.queue_free)
	add_child(win)
	win.popup_centered()

	var vb := VBoxContainer.new()
	win.add_child(vb)
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0

	var toolbar := HBoxContainer.new()
	vb.add_child(toolbar)

	var title := Label.new()
	title.text = title_text
	toolbar.add_child(title)

	var info := Label.new()
	var info_text := "tiles: %d / images: %d / mapped: %d"
	if objects_mode:
		info_text = "instances: %d / objects: %d / mapped: %d"
	info.text = info_text % [rows.size(), _unique_key_count(), _mapping().size()]
	toolbar.add_child(info)

	toolbar.add_spacer(false)
	var zoom_label := Label.new()
	zoom_label.text = "Zoom:"
	toolbar.add_child(zoom_label)

	var zoom_slider := HSlider.new()
	zoom_slider.custom_minimum_size = Vector2(100, 0)
	zoom_slider.min_value = 0.1
	zoom_slider.max_value = 10.0
	zoom_slider.step = 0.1
	zoom_slider.value = 0.5
	toolbar.add_child(zoom_slider)

	var scroll := ScrollContainer.new()
	vb.add_child(scroll)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var preview := PreviewScript.new()
	scroll.add_child(preview)
	zoom_slider.value_changed.connect(func(value: float) -> void: preview.set_zoom(value))
	preview.zoom_changed.connect(func(value: float) -> void: zoom_slider.set_value(value))
	preview.set_zoom(0.5)
	preview.set_data(rows, _mapping(), _build_thumbs(), Placement.collect_existing_items(_current_target()), source_kind)


# ---------------------------------------------------------------- 3. 场景池

func _on_pool_pressed() -> void:
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
	var added := 0
	for path in paths:
		if store.add_scene(path):
			added += 1
	status_label.text = "Added %d scene(s) to the pool (%d total)." % [added, store.scenes.size()]
	_update_labels()


# ---------------------------------------------------------------- 4. 映射 + 生成

func _on_map_pressed() -> void:
	var t := _current_target()
	if t == null:
		_show_info_window("Select the parent container node in the Scene dock first, then press this button again.")
		return
	target = t
	var win := WindowScript.new()
	win.init(rows, target, store, _on_mapping_confirmed, source_kind)
	add_child(win)
	win.popup_centered()


func _on_mapping_confirmed(mapping: Dictionary, p_target: Node) -> void:
	if EditorInterface.get_edited_scene_root() == null:
		_show_info_window("No scene is currently opened.")
		return
	if p_target == null or not is_instance_valid(p_target):
		_show_info_window("The target node is no longer valid. Select the parent container again.")
		return

	# 行 -> 生成条目（键 + 锚点）：两种来源共用同一套 offset / 16px 去重 / 类型校验逻辑
	var meta_key := Placement.META_IMAGE
	var entries: Array = []
	if source_kind == SOURCE_OBJECTS:
		meta_key = Placement.META_OBJECT
		for row in rows:
			entries.append({"key": String(row["name"]), "position": ObjectData.anchor_position(row)})
	else:
		for row in rows:
			entries.append({"key": int(row["image"]), "position": TileTxt.anchor_position(row)})

	var built := Placement.build_plan(entries, mapping, p_target, meta_key)
	var plan: Array = built["plan"]
	if not plan.is_empty():
		Placement.commit_plan(plan, p_target)

	_report(plan.size(), int(built["skipped_dup"]), built["unmapped"], built["warnings"])


func _report(placed: int, skipped_dup: int, unmapped: Dictionary, warnings: Array) -> void:
	var kind := _key_kind_name()
	status_label.text = "Placed %d instance(s); skipped %d duplicate(s); %d %s(s) unmapped." % [
		placed, skipped_dup, unmapped.size(), kind]

	var lines: Array = []
	lines.append("Placed scene instances: %d" % placed)
	lines.append("Skipped (an item is already within 16px): %d" % skipped_dup)
	if not unmapped.is_empty():
		var ids: Array = unmapped.keys()
		ids.sort()
		var id_texts: Array = []
		for id in ids:
			id_texts.append(str(id))
		lines.append("Unmapped %s(s) (%d): %s" % [kind, ids.size(), ", ".join(id_texts)])
	if not warnings.is_empty():
		lines.append("")
		lines.append("Warnings:")
		for warning in warnings:
			lines.append("  - %s" % String(warning))
	print("[ActiveConverter] ", " | ".join(lines))

	# 只有真出问题时才弹窗（未映射的 image 属正常情况，只在状态栏给个数）
	if not warnings.is_empty():
		_show_text_window("Generation result (with warnings)", "\n".join(lines))
	_update_labels()


# ---------------------------------------------------------------- 清除

func _on_clear_generated_pressed() -> void:
	var t := _current_target()
	if t == null:
		_show_info_window("Select the parent container node in the Scene dock first.")
		return
	var victims: Array = []
	for child in t.get_children():
		if Placement.is_generated(child):
			victims.append(child)
	if victims.is_empty():
		status_label.text = "No instance generated by this plugin under '%s'." % t.name
		return

	var dialog := ConfirmationDialog.new()
	dialog.title = "Active Converter"
	dialog.dialog_text = "Remove %d instance(s) generated by this plugin under '%s'?\nThis can be undone with Ctrl+Z." % [victims.size(), t.name]
	dialog.ok_button_text = "Remove"
	dialog.cancel_button_text = "Cancel"
	dialog.confirmed.connect(_remove_instances.bind(t, victims))
	add_child(dialog)
	dialog.popup_centered()


func _remove_instances(t: Node, victims: Array) -> void:
	var edited := EditorInterface.get_edited_scene_root()
	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action("Active Converter: Remove Generated Instances")
	for node in victims:
		undo.add_do_method(t, "remove_child", node)
		undo.add_undo_method(t, "add_child", node, true)
		# remove_child 会清掉 owner，撤销时要重新指回编辑场景根，否则节点不会被写进场景文件
		undo.add_undo_method(node, "set_owner", edited)
		undo.add_undo_reference(node)
	undo.commit_action()
	status_label.text = "Removed %d instance(s) (undoable)." % victims.size()


func _on_clear_mapping_pressed() -> void:
	var total: int = store.mappings.size() + store.object_mappings.size()
	if total == 0:
		status_label.text = "No saved mapping to clear."
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Active Converter"
	dialog.dialog_text = "Delete all %d saved mapping(s) (%d image, %d object name)?\n(res://addons/active_converter/mapping.json)" % [
		total, store.mappings.size(), store.object_mappings.size()]
	dialog.ok_button_text = "Delete"
	dialog.cancel_button_text = "Cancel"
	dialog.confirmed.connect(_do_clear_mapping)
	add_child(dialog)
	dialog.popup_centered()


func _do_clear_mapping() -> void:
	store.clear_mappings()
	store.clear_object_mappings()
	status_label.text = "Saved mapping cleared."
	_update_labels()


# ---------------------------------------------------------------- 工具方法

func _current_target() -> Node:
	var edited := EditorInterface.get_edited_scene_root()
	for node in EditorInterface.get_selection().get_selected_nodes():
		if edited != null and (node == edited or edited.is_ancestor_of(node)):
			return node
	return null


## 当前来源对应的映射表（与 store 内部是同一个字典）
func _mapping() -> Dictionary:
	return store.object_mappings if source_kind == SOURCE_OBJECTS else store.mappings


## 键的类别名（用于汇报文案）
func _key_kind_name() -> String:
	return "object name" if source_kind == SOURCE_OBJECTS else "image id"


func _unique_key_count() -> int:
	if source_kind == SOURCE_OBJECTS:
		return ObjectData.unique_objects(rows).size()
	return TileTxt.unique_images(rows).size()


func _build_thumbs() -> Dictionary:
	var thumbs := {}
	var current := _mapping()
	for key in current.keys():
		var scene_path := String(current[key].get("scene", ""))
		if not scene_path.is_empty():
			thumbs[key] = SceneThumb.get_thumb(scene_path)
	return thumbs


func _update_labels() -> void:
	var mapping_count := _mapping().size()
	if source_kind == SOURCE_OBJECTS:
		info_label.text = "Instances: %d | Objects: %d | Pool: %d scenes | Object mappings: %d entries (auto-saved)" % [
			rows.size(), _unique_key_count(), store.scenes.size(), mapping_count]
	else:
		info_label.text = "Tiles: %d | Images: %d | Pool: %d scenes | Image mappings: %d entries (auto-saved)" % [
			rows.size(), _unique_key_count(), store.scenes.size(), mapping_count]
	include_fake_check.disabled = source_kind != SOURCE_OBJECTS
	preview_btn.text = "2. Preview all actives" if source_kind == SOURCE_OBJECTS else "2. Preview all tiles"
	_update_target_label()


func _update_target_label() -> void:
	var t := _current_target()
	if t == null:
		target_label.text = "Selected node (target): (none)"
		return
	var text := "Selected node (target): %s" % String(t.get_path())
	if target != null and is_instance_valid(target) and target != t:
		text += "   [locked for the opened Mapping Window: %s]" % target.name
	target_label.text = text


func _show_info_window(msg: String) -> void:
	_show_text_window("Information", msg)


func _show_text_window(window_title: String, msg: String) -> void:
	var win := Window.new()
	win.title = window_title
	win.size = Vector2(520, 360)
	win.min_size = Vector2(360, 240)
	win.close_requested.connect(win.queue_free)
	add_child(win)
	win.popup_centered()

	var vb := VBoxContainer.new()
	win.add_child(vb)
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0

	var text_edit := TextEdit.new()
	text_edit.text = msg
	text_edit.editable = false
	text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	vb.add_child(text_edit)
	text_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(win.queue_free)
	vb.add_child(close_btn)
