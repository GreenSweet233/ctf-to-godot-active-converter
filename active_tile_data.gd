@tool
## TileExporter v1.0 文本解析（格式与 addons/tile_converter 兼容，并对变体容错）。
##
## 完整格式：
##   第 1 行：TileExporter v1.0 - Godot Tile Data
##   （可选，新版才有）"Layer n" 行
##   "Total tiles: N"
##   "Tile i: x=.. y=.. w=.. h=.. obstacle=.. image=.."
##
## 裸列表格式（容错，例如手写/别的工具导出的对象清单）：没有头也没有 "Total tiles:"，
## 逐行只有 "Tile i: x=.. y=.. w=.. h=.. obstacle=.. image=.."。
##
## 解析出的每一行是 Dictionary：
##   { index:int, x:int, y:int, w:int, h:int, obstacle:int, image:int }
## parse_text / parse_file 返回：
##   { ok:bool, error:String, rows:Array, total:int, format:"full"|"bare"|"none", warning:String }
extends RefCounted

const HEADER_PREFIX := "TileExporter"
const TILE_PATTERN := "Tile (\\d+):\\s+x=(-?\\d+)\\s+y=(-?\\d+)\\s+w=(\\d+)\\s+h=(\\d+)\\s+obstacle=(\\d+)\\s+image=(\\d+)"


## 实例落点基准：图块矩形的【中心】（用户拍板）。
## 若日后要改成左上角/底边中点，只改这里即可。
static func anchor_position(row: Dictionary) -> Vector2:
	return Vector2(float(row["x"]) + float(row["w"]) * 0.5, float(row["y"]) + float(row["h"]) * 0.5)


## 图块矩形（世界/局部坐标，与 txt 中的 x/y/w/h 一致）
static func row_rect(row: Dictionary) -> Rect2:
	return Rect2(float(row["x"]), float(row["y"]), float(row["w"]), float(row["h"]))


static func parse_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "File not found: %s" % path, "rows": [], "total": 0, "format": "none", "warning": ""}
	var read := read_text(path)
	if not bool(read["ok"]):
		return {"ok": false, "error": String(read["error"]), "rows": [], "total": 0, "format": "none", "warning": ""}
	var result := parse_text(String(read["text"]))
	if bool(result["ok"]) and String(read["encoding"]) != "UTF-8":
		# 编码不是 UTF-8 时提示一句（例如 PowerShell 的 Out-File 会写成 UTF-16LE）
		var note := "decoded from %s" % String(read["encoding"])
		var existing := String(result["warning"])
		result["warning"] = note if existing.is_empty() else "%s; %s" % [note, existing]
	return result


## 读文本：UTF-8（含 BOM）与 UTF-16LE/BE 都能读。
## Windows PowerShell 的 `Out-File` / `>` 默认输出 UTF-16LE，手写清单常是这种编码。
static func read_text(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {
			"ok": false,
			"error": "Cannot open file (error %d): %s" % [FileAccess.get_open_error(), path],
			"text": "",
			"encoding": "",
		}
	var bytes := file.get_buffer(file.get_length())
	file.close()

	if bytes.size() >= 2 and bytes[0] == 0xFF and bytes[1] == 0xFE:
		return {"ok": true, "error": "", "text": _decode_utf16(bytes, 2, false), "encoding": "UTF-16LE"}
	if bytes.size() >= 2 and bytes[0] == 0xFE and bytes[1] == 0xFF:
		return {"ok": true, "error": "", "text": _decode_utf16(bytes, 2, true), "encoding": "UTF-16BE"}

	var text := bytes.get_string_from_utf8()
	# 去掉可能残留的 UTF-8 BOM，免得影响首行判断
	if text.begins_with("\uFEFF"):
		text = text.substr(1)
	return {"ok": true, "error": "", "text": text, "encoding": "UTF-8"}


## UTF-16 → String（只覆盖基本平面：本项目数据是 ASCII 数字，代理对不在支持范围）
static func _decode_utf16(bytes: PackedByteArray, offset: int, big_endian: bool) -> String:
	var count := int((bytes.size() - offset) / 2)
	if count <= 0:
		return ""
	var chars := PackedStringArray()
	chars.resize(count)
	for i in count:
		var at := offset + i * 2
		var unit := ((bytes[at] << 8) | bytes[at + 1]) if big_endian else bytes.decode_u16(at)
		chars[i] = String.chr(unit)
	return "".join(chars)


static func parse_text(content: String) -> Dictionary:
	var lines := content.split("\n")

	# 第一行非空内容决定格式：以 "TileExporter" 开头 = 完整格式，否则按裸列表格式解析。
	var header := ""
	for line in lines:
		var trimmed := line.strip_edges()
		if trimmed.is_empty():
			continue
		if trimmed.begins_with(HEADER_PREFIX):
			header = trimmed
		break

	# 新版 exporter 会额外输出 "Layer n" 行（当前不使用），向后搜索 "Total tiles:" 行，
	# 以同时兼容旧版（没有 Layer 行）的文件；裸列表格式没有这一行。
	var total_line := -1
	if not header.is_empty():
		for i in range(1, lines.size()):
			var line := lines[i].strip_edges()
			if line.is_empty() or line.begins_with("Layer "):
				continue
			if line.begins_with("Total tiles:"):
				total_line = i
				break

	var regex := RegEx.new()
	regex.compile(TILE_PATTERN)

	var rows: Array = []
	var start := total_line + 1 if total_line != -1 else 0
	for i in range(start, lines.size()):
		var line := lines[i].strip_edges()
		if line.is_empty():
			continue
		var result := regex.search(line)
		if result == null:
			continue
		rows.append({
			"index": int(result.get_string(1)),
			"x": int(result.get_string(2)),
			"y": int(result.get_string(3)),
			"w": int(result.get_string(4)),
			"h": int(result.get_string(5)),
			"obstacle": int(result.get_string(6)),
			"image": int(result.get_string(7)),
		})

	if rows.is_empty():
		return {
			"ok": false,
			"error": "No tile lines found. Expected lines like \"Tile 0: x=.. y=.. w=.. h=.. obstacle=.. image=..\".",
			"rows": [],
			"total": 0,
			"format": "none",
			"warning": "",
		}

	var total := rows.size()
	if total_line != -1:
		total = int(lines[total_line].split(":")[1].strip_edges())

	var warning := ""
	if header.is_empty():
		warning = "no \"TileExporter\" header (bare tile list)"
	elif total_line == -1:
		warning = "no \"Total tiles:\" line (counted %d)" % rows.size()
	elif rows.size() != total:
		warning = "file declares %d tiles but %d were parsed" % [total, rows.size()]

	return {
		"ok": true,
		"error": "",
		"rows": rows,
		"total": total,
		"format": "bare" if header.is_empty() else "full",
		"warning": warning,
	}


## 统计 txt 里出现过的 image id（升序）
static func unique_images(rows: Array) -> Array:
	var seen := {}
	for row in rows:
		seen[int(row["image"])] = true
	var keys := seen.keys()
	keys.sort()
	return keys
