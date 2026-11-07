@tool
class_name FocusVariablesEditor
extends VBoxContainer

## 变量表可视化编辑器（工具面板）。
##
## 负责编辑项目自己的变量表 JSON：每个变量一行（key / 默认值 / 显示名）。
## 默认写 res://focus_tree_variables.json；项目里还没有这个文件时，
## 会先把插件自带的模板载进来，点「保存」后才真正生成项目变量表。

const TEMPLATE_PATH := "res://addons/focus_tree_editor/variables.json"

signal saved(path: String)

@export_file("*.json") var variables_path := "res://focus_tree_variables.json"

var _path_edit: LineEdit
var _rows_box: VBoxContainer
var _status: Label
var _updating := false


func _ready() -> void:
	_build_ui()
	reload()


func _build_ui() -> void:
	# 顶部：文件路径 + 操作按钮
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	var path_label := Label.new()
	path_label.text = "变量表"
	top.add_child(path_label)
	_path_edit = LineEdit.new()
	_path_edit.text = variables_path
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_path_edit)

	var import_button := Button.new()
	import_button.text = "导入插件模板"
	import_button.tooltip_text = "把插件自带的变量表填到下面（不会立刻写盘）"
	import_button.pressed.connect(_on_import_pressed)
	top.add_child(import_button)

	var reload_button := Button.new()
	reload_button.text = "重新加载"
	reload_button.pressed.connect(_on_reload_pressed)
	top.add_child(reload_button)

	var save_button := Button.new()
	save_button.text = "保存"
	save_button.pressed.connect(_on_save_pressed)
	top.add_child(save_button)
	add_child(top)

	# 表头
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	header.add_child(_make_header("变量 key（英文）", 220))
	header.add_child(_make_header("默认值", 110))
	header.add_child(_make_header("显示名", 160))
	header.add_child(_make_header("", 60))
	add_child(header)

	# 行区域
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var wrap := VBoxContainer.new()
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(wrap)

	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 4)
	wrap.add_child(_rows_box)

	var add_button := Button.new()
	add_button.text = "添加变量"
	add_button.pressed.connect(func() -> void: add_row("", 0, ""))
	add_child(add_button)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	_status.modulate = Color(1, 1, 1, 0.6)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)


func _make_header(text: String, width: int) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(width, 0)
	label.add_theme_font_size_override("font_size", 11)
	label.modulate = Color(1, 1, 1, 0.6)
	return label


func add_row(key: String, default_value: int, label_text: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var key_edit := LineEdit.new()
	key_edit.text = key
	key_edit.placeholder_text = "如 political_power"
	key_edit.custom_minimum_size = Vector2(220, 0)
	key_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(key_edit)

	var default_spin := SpinBox.new()
	default_spin.min_value = -999999
	default_spin.max_value = 999999
	default_spin.step = 1
	default_spin.rounded = true
	default_spin.value = default_value
	default_spin.custom_minimum_size = Vector2(110, 0)
	row.add_child(default_spin)

	var label_edit := LineEdit.new()
	label_edit.text = label_text
	label_edit.placeholder_text = "显示名"
	label_edit.custom_minimum_size = Vector2(160, 0)
	label_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label_edit)

	var remove_button := Button.new()
	remove_button.text = "删除"
	remove_button.custom_minimum_size = Vector2(60, 0)
	remove_button.pressed.connect(func() -> void:
		row.queue_free()
		_set_status("已删除一行，记得点「保存」。"))
	row.add_child(remove_button)

	_rows_box.add_child(row)


# ---------------------------------------------------------------------------
# 读写
# ---------------------------------------------------------------------------

func reload() -> void:
	_updating = true
	for child in _rows_box.get_children():
		child.queue_free()

	var path := _current_path()
	if not FileAccess.file_exists(path):
		_updating = false
		_fill_from_file(TEMPLATE_PATH)
		_set_status("还没有 %s，已载入插件模板；点「保存」生成项目自己的变量表。" % path)
		return

	if not _fill_from_file(path):
		_updating = false
		_set_status("读取失败：%s（检查 JSON 格式）。" % path)
		return
	_updating = false
	_set_status("已加载 %d 个变量：%s" % [_rows_box.get_child_count(), path])


func _fill_from_file(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return false

	for key in parsed.keys():
		var variable_key := String(key)
		if variable_key.begins_with("_"):
			continue
		var entry: Variant = parsed[key]
		var default_value := 0
		var label := variable_key
		if entry is Dictionary:
			default_value = int(entry.get("default", 0))
			label = String(entry.get("label", variable_key))
		elif entry is int or entry is float:
			default_value = int(entry)
		add_row(variable_key, default_value, label)
	return true


func _collect() -> Dictionary:
	var data := {}
	for row in _rows_box.get_children():
		if row.get_child_count() < 4:
			continue
		var key_edit := row.get_child(0) as LineEdit
		var default_spin := row.get_child(1) as SpinBox
		var label_edit := row.get_child(2) as LineEdit
		if key_edit == null or default_spin == null or label_edit == null:
			continue
		var key := key_edit.text.strip_edges()
		if key.is_empty():
			continue
		var label := label_edit.text.strip_edges()
		if label.is_empty():
			label = key
		data[key] = {"default": int(default_spin.value), "label": label}
	return data


## 当前编辑结果（key -> { default, label }）。
func get_definitions() -> Dictionary:
	return _collect()


## 保存到指定路径；返回是否成功。
func save_to(path: String) -> bool:
	if path.is_empty():
		path = _current_path()
	var data := _collect()
	if data.is_empty():
		_set_status("变量表是空的，没有保存。")
		return false

	var dir := path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[FocusVariablesEditor] 无法写入 %s。" % path)
		_set_status("写入失败：%s" % path)
		return false
	file.store_string(JSON.stringify(data, "\t", false) + "\n")
	file.close()

	variables_path = path
	_path_edit.text = path
	_set_status("已保存 %d 个变量到 %s" % [data.size(), path])
	saved.emit(path)
	return true


func _current_path() -> String:
	if _path_edit != null and not _path_edit.text.strip_edges().is_empty():
		return _path_edit.text.strip_edges()
	if variables_path.is_empty():
		return "res://focus_tree_variables.json"
	return variables_path


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text


# ---------------------------------------------------------------------------
# 按钮回调
# ---------------------------------------------------------------------------

func _on_import_pressed() -> void:
	for child in _rows_box.get_children():
		child.queue_free()
	if not _fill_from_file(TEMPLATE_PATH):
		_set_status("插件模板读取失败：%s" % TEMPLATE_PATH)
		return
	_set_status("已导入插件模板，点「保存」写到 %s。" % _current_path())


func _on_reload_pressed() -> void:
	reload()


func _on_save_pressed() -> void:
	save_to(_current_path())
