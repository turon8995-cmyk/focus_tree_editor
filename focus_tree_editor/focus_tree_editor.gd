@tool
class_name FocusTreeEditor
extends Control

## 国策树编辑器主面板（纯 Control，不依赖 EditorInterface，方便单独实例化/测试）。
##
## 布局：顶部工具栏 + 左侧 GraphEdit 画布 + 右侧属性区 + 底部状态栏。
## 数据流：FocusTreeData（数据） <-> FocusGraphNode（视图）。所有编辑都先改数据，
## 然后统一通过 _rebuild_connections() / _apply_positions() / refresh() 回写视图。
## 节点位置是自由坐标（data.position 是唯一来源），工具栏的「吸附」可选开关负责对齐。

## 请求宿主（plugin.gd）把本面板在 Dock 与弹出大窗口之间切换。
signal popout_requested
## 状态栏文字变化（宿主可用来做日志）。
signal status_changed(message: String)

## 自动整理时的排布参数（只影响「自动整理」按钮，不限制手动拖拽）。
const LAYOUT_ORIGIN := Vector2(140.0, 120.0)
const LAYOUT_COLUMN_GAP := 330.0
const LAYOUT_ROW_GAP := 170.0
## 可选吸附的步长（工具栏「吸附」按钮打开时生效）。
const SNAP_STEP := Vector2(20.0, 20.0)
const DEFAULT_DAYS := 70
const GRAPH_MIN_WIDTH := 240.0
const PROP_MIN_WIDTH := 200.0
const MAX_ADD_SCAN := 400

## 当前树数据。
var tree_data: FocusTreeData = null
## 当前文件路径（res:// 或绝对路径），空表示尚未保存过。
var current_path := ""

var _dirty := false
var _selected: FocusNodeData = null
## id -> FocusGraphNode
var _nodes: Dictionary = {}
var _updating_ui := false
var _in_window := false
var _pending_action: Callable = Callable()
var _dialog_mode := "open"
var _icon_target: FocusNodeData = null
var _context_position := Vector2.ZERO
## 工具栏「吸附」开关：打开后拖拽结束会吸附到 SNAP_STEP 的格点。
var _snap_enabled := false
## 自定义字段定义（来自项目根目录的 focus_tree_custom_fields.json）。
var _custom_fields: Array = []
var _variables_window: Window
var _variables_editor: FocusVariablesEditor

## 按顺序尝试的系统字体；只有当宿主主题字体画不出中文时才启用。
const CJK_FONT_NAMES := [
	"Microsoft YaHei",
	"Microsoft YaHei UI",
	"Noto Sans CJK SC",
	"Source Han Sans SC",
	"PingFang SC",
	"Heiti SC",
	"WenQuanYi Micro Hei",
	"SimHei",
	"sans-serif",
]

var _split_initialized := false
var _graph: FocusGraphEdit
var _split: HSplitContainer
var _props_box: VBoxContainer
var _props_scroll: ScrollContainer
var _status_label: Label
var _header_label: Label
var _popout_button: Button
var _file_dialog: FileDialog
var _icon_dialog: FileDialog
var _confirm_dialog: ConfirmationDialog
var _report_dialog: Window
var _report_text: TextEdit
var _context_menu: PopupMenu


func _ready() -> void:
	_ensure_cjk_font()
	_reload_custom_fields()
	_build_ui()
	_connect_graph_signals()
	new_tree()
	resized.connect(_apply_default_split)
	_apply_default_split.call_deferred()


## 重新读取项目里的自定义字段定义（focus_tree_custom_fields.json）。
func _reload_custom_fields() -> void:
	_custom_fields = FocusFieldSchema.load_fields()


## 打开变量表可视化编辑器（写项目自己的 focus_tree_variables.json）。
func _open_variables_editor() -> void:
	if _variables_window == null:
		_variables_window = Window.new()
		_variables_window.title = "变量表"
		_variables_window.min_size = Vector2i(760, 520)
		_variables_window.size = Vector2i(840, 560)
		_variables_window.visible = false
		_variables_window.close_requested.connect(func() -> void: _variables_window.hide())

		var margin := MarginContainer.new()
		margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		margin.add_theme_constant_override("margin_left", 10)
		margin.add_theme_constant_override("margin_right", 10)
		margin.add_theme_constant_override("margin_top", 10)
		margin.add_theme_constant_override("margin_bottom", 10)
		_variables_window.add_child(margin)

		_variables_editor = FocusVariablesEditor.new()
		_variables_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_variables_editor.saved.connect(func(path: String) -> void:
			_status("变量表已保存：%s（游戏里用 FocusTreeManager 读同一个文件）" % path))
		margin.add_child(_variables_editor)
		add_child(_variables_window)

	_variables_editor.reload()
	if _can_popup():
		_variables_window.popup_centered()


## 第一次拿到真实宽度时把 62% 分给画布（Dock 窄的时候画布优先），之后用户手动拖分栏就不再干预。
func _apply_default_split() -> void:
	if _split == null or _split_initialized or size.x <= 0.0:
		return
	var min_left := GRAPH_MIN_WIDTH
	var max_left := maxf(min_left, size.x - PROP_MIN_WIDTH - 8.0)
	_split.split_offset = int(clampf(size.x * 0.62, min_left, max_left))
	_split_initialized = true


## 编辑器主题的默认字体不一定带中文字形（英文界面的编辑器就可能没有），
## 这里检测一下：画不出「国」字就挂一个系统 CJK 字体主题，保证面板文案不变成方框。
func _ensure_cjk_font() -> void:
	var base_font := get_theme_default_font()
	if base_font != null and base_font.has_char(0x56FD):
		return
	var system_font := SystemFont.new()
	system_font.font_names = PackedStringArray(CJK_FONT_NAMES)
	system_font.allow_system_fallback = true
	var ui_theme := Theme.new()
	ui_theme.default_font = system_font
	theme = ui_theme


# ---------------------------------------------------------------------------
# 对外 API（编辑器按钮与自动化测试都走这些方法）
# ---------------------------------------------------------------------------

func get_tree_data() -> FocusTreeData:
	return tree_data


func get_node_map() -> Dictionary:
	return _nodes


func get_selected_data() -> FocusNodeData:
	return _selected


func is_dirty() -> bool:
	return _dirty


## 在 Dock 与弹出窗口之间切换时由宿主调用，仅影响按钮文字。
func set_in_window(in_window: bool) -> void:
	_in_window = in_window
	if _popout_button != null:
		_popout_button.text = "停靠回侧栏" if _in_window else "弹出编辑"
		_popout_button.tooltip_text = "把编辑器放回左侧停靠栏" if _in_window else "把编辑器移到一个大窗口里"


## 新建一棵空树（会同样清理画布）。
func new_tree() -> void:
	var data := FocusTreeData.new()
	_apply_tree_data(data, "")
	_status("已新建一棵空国策树。")


## 从磁盘加载一棵树；加载失败时保留当前内容并 push_error。
func open_tree(path: String) -> bool:
	var normalized := _normalize_path(path)
	if not ResourceLoader.exists(normalized):
		push_error("[FocusTreeEditor] File not found: %s" % normalized)
		_status("找不到文件：" + normalized)
		return false
	var res: Resource = ResourceLoader.load(normalized, "", ResourceLoader.CACHE_MODE_REUSE)
	if res == null:
		push_error("[FocusTreeEditor] Failed to load '%s' (corrupted file or missing dependency)." % normalized)
		_status("加载失败：" + normalized)
		return false
	if not (res is FocusTreeData):
		push_error("[FocusTreeEditor] '%s' is not a FocusTreeData (got %s)." % [normalized, res.get_class()])
		_status("不是国策树资源：" + normalized)
		return false
	_apply_tree_data(res as FocusTreeData, normalized)
	_status("已打开 %s（%d 个国策）。" % [normalized, tree_data.nodes.size()])
	return true


## 保存到指定路径（空路径则使用当前路径）。
func save_tree_as(path: String) -> Error:
	if tree_data == null:
		tree_data = FocusTreeData.new()
	var target := _normalize_path(path)
	if target.is_empty():
		target = current_path
	if target.is_empty():
		push_error("[FocusTreeEditor] No save path given.")
		return ERR_UNCONFIGURED
	if not target.ends_with(".tres"):
		target += ".tres"
	# 保存前把内存里的节点引用全部同步一次，避免子资源丢失
	for node in _nodes.values():
		if node is FocusGraphNode:
			node.refresh()
	var err := ResourceSaver.save(tree_data, target)
	if err != OK:
		push_error("[FocusTreeEditor] Failed to save '%s': %s" % [target, error_string(err)])
		_status("保存失败：%s" % error_string(err))
		return err
	current_path = target
	_mark_dirty(false)
	_update_header()
	if tree_data.nodes.is_empty():
		_status("已保存空国策树到 %s。" % target)
	else:
		_status("已保存 %d 个国策到 %s。" % [tree_data.nodes.size(), target])
	return OK


## 新建一个国策。at_position 传 Vector2.INF（默认）表示自动找一个空位：
## 优先放在当前选中节点的右侧，没有选中就放画布中心；被占用就往下错开。
func add_focus(at_position: Vector2 = Vector2.INF) -> FocusNodeData:
	if tree_data == null:
		tree_data = FocusTreeData.new()
	var target := at_position
	if target == Vector2.INF:
		target = _find_free_position()
	target.x = maxf(target.x, 0.0)
	target.y = maxf(target.y, 0.0)

	var data := FocusNodeData.new()
	data.id = _next_focus_id()
	data.title = "新国策"
	data.days = DEFAULT_DAYS
	data.position = target
	# 自定义字段先填上默认值，面板里就能直接看到
	for field in _custom_fields:
		var field_key := String(field.get("key", ""))
		if field_key.is_empty() or data.custom.has(field_key):
			continue
		data.custom[field_key] = field.get("default", FocusFieldSchema.default_for(String(field.get("type", "string"))))
	tree_data.nodes.append(data)

	var node := FocusGraphNode.new()
	node.set_data(data)
	_graph.add_child(node)
	_nodes[data.id] = node

	_apply_positions()
	_select_only(node)
	_rebuild_properties()
	_mark_dirty()
	_status("已添加国策 %s。" % data.id)
	return data


## 删除一个国策，并清理别的节点里所有指向它的引用。
func delete_focus(focus_id: String) -> bool:
	var data := _find_data(focus_id)
	if data == null:
		return false
	for other in tree_data.nodes:
		if other != null and other != data:
			other.remove_reference_to(focus_id)
	tree_data.nodes.erase(data)
	var node: FocusGraphNode = _nodes.get(focus_id)
	_nodes.erase(focus_id)
	if node != null and is_instance_valid(node):
		_graph.remove_child(node)
		node.queue_free()
	if _selected == data:
		_selected = null
	_rebuild_connections()
	_apply_positions()
	_rebuild_properties()
	_mark_dirty()
	_status("已删除国策 %s。" % focus_id)
	return true


## 添加前置关系：from_id -> to_id（from 是前置，to 依赖 from）。
func connect_prerequisite(from_id: String, to_id: String) -> bool:
	var from_data := _find_data(from_id)
	var to_data := _find_data(to_id)
	if from_data == null or to_data == null:
		push_error("[FocusTreeEditor] connect_prerequisite: unknown focus (%s -> %s)." % [from_id, to_id])
		return false
	if from_id == to_id:
		_status("国策不能依赖自己。")
		return false
	if to_data.prerequisites.has(from_id):
		_rebuild_connections()
		return false
	if _depends_on(from_id, to_id):
		_show_report("无法连接", [
			"不能把 %s 设为 %s 的前置：" % [from_id, to_id],
			"%s 已经（直接或间接）依赖 %s，这样会形成依赖环。" % [from_id, to_id],
		])
		_status("已拒绝：这条连线会形成依赖环。")
		return false
	to_data.prerequisites.append(from_id)
	var from_node: FocusGraphNode = _nodes.get(from_id)
	var to_node: FocusGraphNode = _nodes.get(to_id)
	if from_node != null and to_node != null:
		_graph.connect_node(from_node.name, 0, to_node.name, 0)
	_refresh_node_visuals()
	_mark_dirty()
	if _selected == to_data:
		_rebuild_properties()
	_status("已连接 %s -> %s。" % [from_id, to_id])
	return true


## 删除前置关系：from_id -> to_id。
func disconnect_prerequisite(from_id: String, to_id: String) -> bool:
	var to_data := _find_data(to_id)
	if to_data == null:
		return false
	var idx := to_data.prerequisites.find(from_id)
	if idx == -1:
		return false
	to_data.prerequisites.remove_at(idx)
	var from_node: FocusGraphNode = _nodes.get(from_id)
	var to_node: FocusGraphNode = _nodes.get(to_id)
	if from_node != null and to_node != null:
		_graph.disconnect_node(from_node.name, 0, to_node.name, 0)
	_refresh_node_visuals()
	_mark_dirty()
	if _selected == to_data:
		_rebuild_properties()
	_status("已移除前置关系 %s -> %s。" % [from_id, to_id])
	return true


## 把 member_id 并入 target 的「任一前置」组（红色虚线；组内任一完成即可）。
## 没有组就新建一组；已有组就并进最后一组（这样连续 Alt 拖同一个目标会自动合并）。
func add_any_prerequisite(member_id: String, target_id: String) -> bool:
	var member := _find_data(member_id)
	var target := _find_data(target_id)
	if member == null or target == null:
		push_error("[FocusTreeEditor] add_any_prerequisite: 未知国策（%s -> %s）。" % [member_id, target_id])
		return false
	if member_id == target_id:
		_status("国策不能把自己放进「任一前置」组。")
		return false
	for group in target.get_any_groups():
		if group.has(member_id):
			_status("%s 已经在 %s 的「任一前置」组里了。" % [member_id, target_id])
			return false
	if _depends_on(member_id, target_id):
		_status("不能把 %s 放进 %s 的「任一前置」组：会形成依赖环。" % [member_id, target_id])
		return false

	if target.prerequisite_any_groups.is_empty():
		target.prerequisite_any_groups.append(member_id)
	else:
		var last_index := target.prerequisite_any_groups.size() - 1
		var last_line := target.prerequisite_any_groups[last_index].strip_edges()
		target.prerequisite_any_groups[last_index] = member_id if last_line.is_empty() else last_line + ", " + member_id

	_sync_relation_overlays()
	_mark_dirty()
	if _selected == target:
		_rebuild_properties()
	_status("已把 %s 加进 %s 的「任一前置」组。" % [member_id, target_id])
	return true


## 按依赖深度重新排布整棵树（自动整理按钮）。只算位置，不限制之后的手动拖拽。
func auto_arrange() -> void:
	if tree_data == null or tree_data.nodes.is_empty():
		_status("没有可整理的内容：国策树是空的。")
		return
	var depth := tree_data.get_dependency_depth()
	var columns := {}
	for data in tree_data.nodes:
		if data == null:
			continue
		var col := int(depth.get(data.id, 0))
		if not columns.has(col):
			columns[col] = []
		columns[col].append(data)

	var sorted_columns := columns.keys()
	sorted_columns.sort()
	for col in sorted_columns:
		var bucket: Array = columns[col]
		# 同列内保持原来的上下顺序，行号从 0 开始紧凑排列
		bucket.sort_custom(func(a: FocusNodeData, b: FocusNodeData) -> bool:
			if not is_equal_approx(a.position.y, b.position.y):
				return a.position.y < b.position.y
			return a.id < b.id)
		var row := 0
		for data in bucket:
			data.position = LAYOUT_ORIGIN + Vector2(float(col) * LAYOUT_COLUMN_GAP, float(row) * LAYOUT_ROW_GAP)
			row += 1

	_apply_positions()
	_mark_dirty()
	_fit_all()
	_rebuild_properties()
	_status("已按依赖深度整理 %d 个国策。" % tree_data.nodes.size())


## 数据层 + 布局层自检，返回问题列表（英文）。
func validate_tree() -> Array[String]:
	var issues: Array[String] = []
	if tree_data == null:
		issues.append("没有加载任何国策树。")
		return issues
	issues.append_array(tree_data.validate())

	# 画布上互相压住的节点（用实际矩形判断，自由布局下这个最容易出错）
	var rects: Array = []
	for data in tree_data.nodes:
		if data == null:
			continue
		var node: FocusGraphNode = _nodes.get(data.id)
		var rect := Rect2(data.position, FocusGraphNode.NODE_MIN_SIZE)
		if node != null:
			rect = Rect2(node.position_offset, node.size if node.size != Vector2.ZERO else FocusGraphNode.NODE_MIN_SIZE)
		if rect.size == Vector2.ZERO:
			rect.size = FocusGraphNode.NODE_MIN_SIZE
		rects.append([data.id, rect])
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if (rects[i][1] as Rect2).intersects(rects[j][1] as Rect2):
				issues.append("国策 %s 和 %s 在画布上重叠了。" % [rects[i][0], rects[j][0]])
	return issues


# ---------------------------------------------------------------------------
# UI 构建
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	custom_minimum_size = Vector2(GRAPH_MIN_WIDTH + PROP_MIN_WIDTH, 360.0)

	var root := VBoxContainer.new()
	root.name = "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	root.add_child(_build_toolbar())
	root.add_child(_build_main_area())
	root.add_child(_build_status_bar())
	_build_dialogs()


func _build_toolbar() -> HFlowContainer:
	# 用 HFlowContainer：Dock 变窄时按钮会自动换行，而不是被裁掉
	var bar := HFlowContainer.new()
	bar.name = "Toolbar"
	bar.add_theme_constant_override("h_separation", 4)
	bar.add_theme_constant_override("v_separation", 4)
	bar.add_child(_make_button("新建", _on_new_pressed, "新建一棵空国策树"))
	bar.add_child(_make_button("打开…", _on_open_pressed, "打开一个 .tres 国策树"))
	bar.add_child(_make_button("保存", _on_save_pressed, "保存到当前文件"))
	bar.add_child(_make_button("另存为…", _on_save_as_pressed, "另存为新的 .tres 文件"))
	bar.add_child(_make_button("添加国策", _on_add_pressed, "在画布中心添加一个国策"))
	bar.add_child(_make_button("删除国策", _on_delete_pressed, "删除选中的国策"))
	bar.add_child(_make_button("自动整理", auto_arrange, "按依赖深度重新排列国策"))
	bar.add_child(_make_button("检查", _on_validate_pressed, "检查 ID、引用、依赖环与节点重叠"))
	bar.add_child(_make_button("变量表", _open_variables_editor, "可视化编辑项目变量表（focus_tree_variables.json）"))

	var snap_toggle := CheckButton.new()
	snap_toggle.text = "吸附"
	snap_toggle.button_pressed = _snap_enabled
	snap_toggle.tooltip_text = "打开后，拖动结束时按 20×20 像素对齐；关闭时节点可任意摆放"
	snap_toggle.toggled.connect(func(pressed: bool) -> void:
		_snap_enabled = pressed
		_status("吸附已打开（20×20 像素）。" if pressed else "吸附已关闭，节点可自由摆放。"))
	bar.add_child(snap_toggle)

	_popout_button = _make_button("弹出编辑", func() -> void: popout_requested.emit(), "把编辑器移到一个大窗口里")
	bar.add_child(_popout_button)
	return bar


func _build_main_area() -> HSplitContainer:
	_split = HSplitContainer.new()
	_split.name = "MainArea"
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# 用自定义子类：原生连线之外再画一层互斥红色虚线
	_graph = FocusGraphEdit.new()
	_graph.name = "Graph"
	_graph.custom_minimum_size = Vector2(GRAPH_MIN_WIDTH, 240.0)
	_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph.show_grid = false
	_graph.snapping_enabled = false
	_graph.right_disconnects = true
	_graph.minimap_enabled = true
	_graph.minimap_size = Vector2(200.0, 130.0)
	_graph.connection_lines_curvature = 0.3
	_graph.connection_lines_thickness = 2.0
	_graph.connection_lines_antialiased = true
	_graph.zoom_min = 0.4
	_graph.zoom_max = 2.0
	_split.add_child(_graph)

	_props_scroll = ScrollContainer.new()
	_props_scroll.name = "Properties"
	_props_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_props_scroll.custom_minimum_size = Vector2(PROP_MIN_WIDTH, 0.0)
	_props_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_split.add_child(_props_scroll)

	var wrap := VBoxContainer.new()
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_props_scroll.add_child(wrap)

	# 左右留一点边距，字段不会贴着滚动条
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + str(side), 6)
	wrap.add_child(margin)

	_props_box = VBoxContainer.new()
	_props_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_props_box.add_theme_constant_override("separation", 3)
	margin.add_child(_props_box)
	return _split


func _build_status_bar() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.name = "StatusBar"
	bar.add_theme_constant_override("separation", 8)
	_status_label = Label.new()
	_status_label.text = "从国策右侧端口拖到另一个国策的左侧端口，即可添加前置关系。"
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.modulate = Color(1, 1, 1, 0.7)
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bar.add_child(_status_label)

	# 右下角显示「树名 | 路径 | 未保存标记」
	_header_label = Label.new()
	_header_label.name = "Header"
	_header_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	_header_label.add_theme_font_size_override("font_size", 11)
	_header_label.modulate = Color(1, 1, 1, 0.45)
	_header_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_header_label.custom_minimum_size = Vector2(180.0, 0.0)
	_header_label.text = "未命名"
	bar.add_child(_header_label)
	return bar


func _build_dialogs() -> void:
	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.use_native_dialog = false
	_file_dialog.filters = PackedStringArray(["*.tres ; 国策树资源"])
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.size = Vector2i(780, 520)
	_file_dialog.file_selected.connect(_on_tree_file_selected)
	add_child(_file_dialog)

	_icon_dialog = FileDialog.new()
	_icon_dialog.access = FileDialog.ACCESS_RESOURCES
	_icon_dialog.use_native_dialog = false
	_icon_dialog.filters = PackedStringArray(["*.png,*.jpg,*.jpeg,*.svg,*.webp ; Images"])
	_icon_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_icon_dialog.file_selected.connect(_on_icon_file_selected)
	add_child(_icon_dialog)

	_confirm_dialog = ConfirmationDialog.new()
	_confirm_dialog.title = "未保存的更改"
	_confirm_dialog.dialog_text = "放弃未保存的更改？"
	_confirm_dialog.confirmed.connect(_on_confirm_discard)
	add_child(_confirm_dialog)

	# 报告窗口用普通 Window + 只读 TextEdit，避免 AcceptDialog 自带的 OK 按钮压住文本
	var report_window := Window.new()
	report_window.title = "国策树报告"
	report_window.min_size = Vector2i(600, 380)
	report_window.size = Vector2i(720, 480)
	report_window.visible = false
	report_window.close_requested.connect(func() -> void: report_window.hide())
	add_child(report_window)
	_report_dialog = report_window

	var report_margin := MarginContainer.new()
	report_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	report_margin.add_theme_constant_override("margin_left", 10)
	report_margin.add_theme_constant_override("margin_right", 10)
	report_margin.add_theme_constant_override("margin_top", 10)
	report_margin.add_theme_constant_override("margin_bottom", 10)
	report_window.add_child(report_margin)

	var report_box := VBoxContainer.new()
	report_margin.add_child(report_box)

	_report_text = TextEdit.new()
	_report_text.editable = false
	_report_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_report_text.custom_minimum_size = Vector2(560, 280)
	report_box.add_child(_report_text)

	var close_row := HBoxContainer.new()
	close_row.alignment = BoxContainer.ALIGNMENT_END
	var close_button := Button.new()
	close_button.text = "关闭"
	close_button.pressed.connect(func() -> void: report_window.hide())
	close_row.add_child(close_button)
	report_box.add_child(close_row)

	_context_menu = PopupMenu.new()
	_context_menu.add_item("在此处添加国策", 0)
	_context_menu.add_item("删除选中的国策", 1)
	_context_menu.add_separator()
	_context_menu.add_item("自动整理", 2)
	_context_menu.add_item("显示全部", 3)
	_context_menu.id_pressed.connect(_on_context_menu_id)
	add_child(_context_menu)


func _make_button(text: String, callback: Callable, tooltip: String = "") -> Button:
	var button := Button.new()
	button.text = text
	if not tooltip.is_empty():
		button.tooltip_text = tooltip
	button.pressed.connect(callback)
	return button


func _connect_graph_signals() -> void:
	_graph.connection_request.connect(_on_connection_request)
	_graph.disconnection_request.connect(_on_disconnection_request)
	_graph.node_selected.connect(_on_graph_node_selected)
	_graph.node_deselected.connect(_on_graph_node_deselected)
	_graph.delete_nodes_request.connect(_on_delete_nodes_request)
	_graph.end_node_move.connect(_on_end_node_move)
	_graph.popup_request.connect(_on_popup_request)


# ---------------------------------------------------------------------------
# 数据 <-> 画布同步
# ---------------------------------------------------------------------------

func _apply_tree_data(data: FocusTreeData, path: String) -> void:
	tree_data = data
	current_path = path
	_reload_custom_fields()
	_sanitize_tree()
	_rebuild_graph_from_data()
	_rebuild_properties()
	_mark_dirty(false)
	_update_header()
	_fit_all.call_deferred()


## 清理损坏/重复数据：空节点、空 id、非法字符、重复 id。
func _sanitize_tree() -> void:
	if tree_data == null:
		tree_data = FocusTreeData.new()
	if tree_data.tree_name.strip_edges().is_empty():
		tree_data.tree_name = "新建国策树"

	var cleaned: Array[FocusNodeData] = []
	for data in tree_data.nodes:
		if data != null:
			cleaned.append(data)
	tree_data.nodes = cleaned

	var used := {}
	var renames: Array = []
	for data in tree_data.nodes:
		var original := data.id
		var new_id := FocusNodeData.sanitize_id(original)
		if new_id.is_empty():
			new_id = _make_unique_id(used)
		if used.has(new_id):
			var base := new_id
			var i := 2
			while used.has(new_id):
				new_id = "%s_%d" % [base, i]
				i += 1
			push_warning("[FocusTreeEditor] Duplicate focus id '%s' renamed to '%s'." % [original, new_id])
		elif original != new_id:
			push_warning("[FocusTreeEditor] Invalid focus id '%s' sanitized to '%s'." % [original, new_id])
			renames.append([original, new_id])
		data.id = new_id
		used[new_id] = true

	for pair in renames:
		for data in tree_data.nodes:
			data.replace_id_references(pair[0], pair[1])


func _rebuild_graph_from_data() -> void:
	_clear_graph()
	if tree_data == null:
		return
	for data in tree_data.nodes:
		if data == null:
			continue
		var node := FocusGraphNode.new()
		node.set_data(data)
		_graph.add_child(node)
		_nodes[data.id] = node
	_apply_positions()
	_rebuild_connections()


func _clear_graph() -> void:
	_graph.clear_connections()
	_clear_relation_overlays()
	for child in _graph.get_children():
		if child is FocusGraphNode:
			_graph.remove_child(child)
			child.queue_free()
	_nodes.clear()
	_selected = null


## 用数据重建所有连线（比逐条增删更不容易和画布状态脱节）。
func _rebuild_connections() -> void:
	_graph.clear_connections()
	if tree_data == null:
		_sync_relation_overlays()
		return
	for data in tree_data.nodes:
		if data == null:
			continue
		var to_node: FocusGraphNode = _nodes.get(data.id)
		if to_node == null:
			continue
		for prereq_id in data.prerequisites:
			var from_node: FocusGraphNode = _nodes.get(prereq_id)
			if from_node == null:
				continue
			_graph.connect_node(from_node.name, 0, to_node.name, 0)
	_sync_relation_overlays()


## 把互斥对（红色实线）和任一前置组（红色虚线）一起交给画布。
func _sync_relation_overlays() -> void:
	if _graph == null:
		return
	var mutex_pairs: Array = []
	var any_pairs: Array = []
	if tree_data != null:
		var seen_mutex := {}
		var seen_any := {}
		for data in tree_data.nodes:
			if data == null:
				continue
			for other_id in data.mutually_exclusive:
				if not _nodes.has(other_id):
					continue
				var key := "%s|%s" % [data.id, other_id] if data.id < other_id else "%s|%s" % [other_id, data.id]
				if seen_mutex.has(key):
					continue
				seen_mutex[key] = true
				mutex_pairs.append(PackedStringArray([data.id, other_id]))
			# 任一前置：方向是「组成员 → 本节点」，箭头指向本节点
			for group in data.get_any_groups():
				for member_id in group:
					if not _nodes.has(member_id) or member_id == data.id:
						continue
					var any_key := "%s>%s" % [member_id, data.id]
					if seen_any.has(any_key):
						continue
					seen_any[any_key] = true
					any_pairs.append(PackedStringArray([member_id, data.id]))
	_graph.set_relation_pairs(mutex_pairs, any_pairs)


func _clear_relation_overlays() -> void:
	if _graph != null:
		_graph.set_relation_pairs([], [])


## 把数据里的自由坐标同步到画布节点（数据是唯一来源）。
func _apply_positions() -> void:
	if tree_data == null:
		return
	for data in tree_data.nodes:
		if data == null:
			continue
		var node: FocusGraphNode = _nodes.get(data.id)
		if node == null:
			continue
		data.position.x = maxf(data.position.x, 0.0)
		data.position.y = maxf(data.position.y, 0.0)
		node.position_offset = data.position


func _refresh_node_visuals() -> void:
	for node in _nodes.values():
		if node is FocusGraphNode:
			node.refresh()


## 让整棵树居中显示（打开文件 / 自动整理后调用）。
func _fit_all() -> void:
	if _nodes.is_empty():
		return
	var bounds := Rect2()
	var first := true
	for node in _nodes.values():
		if not (node is FocusGraphNode):
			continue
		var node_size: Vector2 = node.size
		if node_size.x <= 0.0 or node_size.y <= 0.0:
			node_size = node.get_combined_minimum_size()
		var rect := Rect2(node.position_offset, node_size)
		if first:
			bounds = rect
			first = false
		else:
			bounds = bounds.merge(rect)
	if first:
		return
	bounds = bounds.grow(80.0)
	var view := _graph.size
	if view.x <= 0.0 or view.y <= 0.0 or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	var zoom := clampf(minf(view.x / bounds.size.x, view.y / bounds.size.y), _graph.zoom_min, _graph.zoom_max)
	_graph.zoom = zoom
	_graph.scroll_offset = bounds.position


# ---------------------------------------------------------------------------
# GraphEdit 交互
# ---------------------------------------------------------------------------

func _on_connection_request(from_node: StringName, _from_port: int, to_node: StringName, _to_port: int) -> void:
	# 按住 Alt 拖：把起点并入终点的「任一前置」组（红色虚线），而不是普通前置
	if Input.is_key_pressed(KEY_ALT):
		add_any_prerequisite(String(from_node), String(to_node))
		return
	connect_prerequisite(String(from_node), String(to_node))


func _on_disconnection_request(from_node: StringName, _from_port: int, to_node: StringName, _to_port: int) -> void:
	disconnect_prerequisite(String(from_node), String(to_node))


func _on_graph_node_selected(node: Node) -> void:
	if node is FocusGraphNode:
		_set_selected((node as FocusGraphNode).get_data())


func _on_graph_node_deselected(node: Node) -> void:
	if node is FocusGraphNode and _selected == (node as FocusGraphNode).get_data():
		_set_selected(null)


func _on_delete_nodes_request(nodes: Array) -> void:
	var ids := PackedStringArray()
	for node in nodes:
		if node is FocusGraphNode:
			var data: FocusNodeData = (node as FocusGraphNode).get_data()
			if data != null:
				ids.append(data.id)
	for focus_id in ids:
		delete_focus(focus_id)


## 拖动结束：把画布位置写回数据；开了「吸附」就按 SNAP_STEP 对齐。
func _on_end_node_move() -> void:
	if tree_data == null:
		return
	for data in tree_data.nodes:
		if data == null:
			continue
		var node: FocusGraphNode = _nodes.get(data.id)
		if node == null:
			continue
		var pos := node.position_offset
		if _snap_enabled:
			pos = Vector2(
				roundf(pos.x / SNAP_STEP.x) * SNAP_STEP.x,
				roundf(pos.y / SNAP_STEP.y) * SNAP_STEP.y)
		data.position = pos

	_apply_positions()
	_mark_dirty()
	if _snap_enabled:
		_status("位置已更新（已吸附到 %d×%d 像素）。" % [int(SNAP_STEP.x), int(SNAP_STEP.y)])
	else:
		_status("位置已更新。")


func _on_popup_request(at_position: Vector2) -> void:
	var zoom := maxf(_graph.zoom, 0.01)
	_context_position = _graph.scroll_offset + at_position / zoom
	if not _can_popup():
		return
	var local := _graph.position + at_position
	_context_menu.popup_on_parent(Rect2i(Vector2i(local), Vector2i.ZERO))


func _on_context_menu_id(id: int) -> void:
	match id:
		0:
			add_focus(_context_position)
		1:
			if _selected != null:
				delete_focus(_selected.id)
			else:
				_status("没有选中任何国策。")
		2:
			auto_arrange()
		3:
			_fit_all()


# ---------------------------------------------------------------------------
# 工具栏回调
# ---------------------------------------------------------------------------

func _on_new_pressed() -> void:
	_request_action(new_tree)


func _on_open_pressed() -> void:
	_request_action(_open_tree_dialog)


func _on_save_pressed() -> void:
	if current_path.is_empty():
		_open_save_dialog()
	else:
		save_tree_as(current_path)


func _on_save_as_pressed() -> void:
	_open_save_dialog()


func _on_add_pressed() -> void:
	add_focus()


func _on_delete_pressed() -> void:
	if _selected == null:
		_status("没有选中任何国策。")
		return
	delete_focus(_selected.id)


func _on_validate_pressed() -> void:
	var issues := validate_tree()
	if issues.is_empty():
		_status("检查通过：没有发现问题。")
		return
	for issue in issues:
		push_warning("[FocusTreeEditor] " + issue)
	_status("检查发现 %d 个问题。" % issues.size())
	_show_report("检查报告", issues)


# ---------------------------------------------------------------------------
# 文件对话框
# ---------------------------------------------------------------------------

func _open_tree_dialog() -> void:
	if not _can_popup():
		_status("无头模式下无法弹出文件对话框。")
		return
	_dialog_mode = "open"
	_file_dialog.title = "打开国策树"
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.current_path = current_path if not current_path.is_empty() else "res://"
	_file_dialog.popup_centered(Vector2i(820, 560))


func _open_save_dialog() -> void:
	if not _can_popup():
		_status("无头模式下无法弹出文件对话框。")
		return
	_dialog_mode = "save"
	_file_dialog.title = "国策树另存为"
	_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.current_path = current_path if not current_path.is_empty() else "res://focus_tree.tres"
	_file_dialog.popup_centered(Vector2i(820, 560))


func _on_tree_file_selected(path: String) -> void:
	match _dialog_mode:
		"open":
			open_tree(path)
		"save":
			save_tree_as(path)


func _open_icon_dialog() -> void:
	if _selected == null or not _can_popup():
		return
	_icon_target = _selected
	_icon_dialog.title = "选择国策图标"
	_icon_dialog.current_path = "res://"
	_icon_dialog.popup_centered(Vector2i(820, 560))


func _on_icon_file_selected(path: String) -> void:
	if _icon_target == null:
		return
	var texture := ResourceLoader.load(path) as Texture2D
	if texture == null:
		push_error("[FocusTreeEditor] '%s' is not a loadable Texture2D." % path)
		_status("图标无效：" + path)
		return
	_icon_target.icon = texture
	_refresh_node_visuals()
	_rebuild_properties()
	_mark_dirty()
	_status("图标已设为 " + path.get_file())


func _request_action(action: Callable) -> void:
	if not _dirty:
		action.call()
		return
	if not _can_popup():
		action.call()
		return
	_pending_action = action
	_confirm_dialog.dialog_text = "放弃未保存的更改并继续？"
	_confirm_dialog.popup_centered()


func _on_confirm_discard() -> void:
	if not _pending_action.is_valid():
		return
	var action := _pending_action
	_pending_action = Callable()
	action.call()


# ---------------------------------------------------------------------------
# 属性面板
# ---------------------------------------------------------------------------

func _set_selected(data: FocusNodeData) -> void:
	if _selected == data:
		return
	_selected = data
	_rebuild_properties()


func _select_only(node: FocusGraphNode) -> void:
	for other in _nodes.values():
		if other is FocusGraphNode:
			(other as FocusGraphNode).selected = other == node
	_selected = node.get_data()


func _rebuild_properties() -> void:
	if _props_box == null:
		return
	_updating_ui = true
	for child in _props_box.get_children():
		_props_box.remove_child(child)
		child.queue_free()

	if _selected == null or tree_data == null or not tree_data.nodes.has(_selected):
		var hint := Label.new()
		hint.text = "在画布上选中一个国策后即可编辑。"
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.modulate = Color(1, 1, 1, 0.5)
		_props_box.add_child(hint)
		_updating_ui = false
		return

	var data := _selected

	_section("基础信息")
	var id_edit := _line_field("ID", data.id)
	id_edit.tooltip_text = "唯一标识（A-Z、a-z、0-9、_）。改名会同步更新所有引用。"
	id_edit.text_submitted.connect(func(text: String) -> void: _commit_id_edit(id_edit, text))
	id_edit.focus_exited.connect(func() -> void: _commit_id_edit(id_edit, id_edit.text))

	var title_edit := _line_field("名称", data.title)
	title_edit.placeholder_text = "国策名称"
	title_edit.text_changed.connect(func(text: String) -> void:
		if _updating_ui:
			return
		data.title = text
		_refresh_node_visuals()
		_mark_dirty())

	var desc_edit := _text_field("说明", data.description, 84.0)
	desc_edit.placeholder_text = "显示在国策的悬浮提示里。"
	desc_edit.text_changed.connect(func() -> void:
		if _updating_ui:
			return
		data.description = desc_edit.text
		_refresh_node_visuals()
		_mark_dirty())

	var icon_row := _row("图标")
	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(36, 36)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture = data.icon
	icon_row.add_child(preview)
	var pick_icon := Button.new()
	pick_icon.text = "选择…"
	pick_icon.pressed.connect(_open_icon_dialog)
	icon_row.add_child(pick_icon)
	var clear_icon := Button.new()
	clear_icon.text = "清除"
	clear_icon.pressed.connect(func() -> void:
		data.icon = null
		_refresh_node_visuals()
		_rebuild_properties()
		_mark_dirty())
	icon_row.add_child(clear_icon)

	_section("进度")
	var days_spin := _spin_field("天数", data.days, 1, 9999, 1)
	days_spin.value_changed.connect(func(value: float) -> void:
		if _updating_ui:
			return
		data.days = int(value)
		_refresh_node_visuals()
		_mark_dirty())
	var cost_spin := _spin_field("政治点成本", data.cost, 0, 99999, 1)
	cost_spin.value_changed.connect(func(value: float) -> void:
		if _updating_ui:
			return
		data.cost = int(value)
		_refresh_node_visuals()
		_mark_dirty())

	_section("布局")
	var pos_row := _row("位置")
	var pos_label := Label.new()
	pos_label.text = "(%d, %d)" % [int(data.position.x), int(data.position.y)]
	pos_label.add_theme_font_size_override("font_size", 11)
	pos_label.modulate = Color(1, 1, 1, 0.55)
	pos_row.add_child(pos_label)
	_add_hint("直接拖动节点即可；工具栏「吸附」打开后会按 20×20 像素对齐。")

	_section("前置国策")
	_build_reference_list(data.prerequisites,
		func(target_id: String) -> void: _add_prerequisite_to(data, target_id),
		func(target_id: String) -> void: _remove_prerequisite_from(data, target_id))

	_section("任一前置（每行一组）")
	var any_edit := _text_field("组内用逗号分隔，例：focus_001, focus_002", "\n".join(data.prerequisite_any_groups), 56.0)
	any_edit.placeholder_text = "focus_001, focus_002"
	any_edit.text_changed.connect(func() -> void:
		_assign_lines(data, "prerequisite_any_groups", any_edit.text)
		_sync_relation_overlays())
	_add_hint("组内任意一个完成即可满足这一组；组与组之间、以及普通前置之间是「与」。画布上是红色虚线；按住 Alt 从 A 拖到 B 也能把 A 加进 B 的最后一组。")

	_section("互斥国策")
	_build_reference_list(data.mutually_exclusive,
		func(target_id: String) -> void: _add_mutex_to(data, target_id),
		func(target_id: String) -> void: _remove_mutex_from(data, target_id))
	_add_hint("画布上是红色实线（中点标 ×）；完成其中一个，另一个就永远锁死。")

	_section("条件")
	var available_edit := _text_field("额外解锁条件（每行一条）", "\n".join(data.available_if), 60.0)
	available_edit.placeholder_text = "has_completed_focus:focus_001"
	available_edit.text_changed.connect(func() -> void:
		_assign_lines(data, "available_if", available_edit.text))
	var branch_edit := _text_field("分支显示条件（每行一条）", "\n".join(data.allow_branch), 60.0)
	branch_edit.placeholder_text = "tag==GER"
	branch_edit.text_changed.connect(func() -> void:
		_assign_lines(data, "allow_branch", branch_edit.text))

	_section("完成效果")
	var effects_edit := _text_field("（每行一条）", "\n".join(data.effects), 64.0)
	effects_edit.placeholder_text = "political_power += 100"
	effects_edit.text_changed.connect(func() -> void:
		_assign_lines(data, "effects", effects_edit.text))
	_add_hint("内置支持 political_power（或 pp）的加减；其它写法会通过 FocusTreeManager.focus_effect_triggered 信号 / effect_resolver 交给游戏自己处理。")

	# 自定义字段：由项目根目录的 focus_tree_custom_fields.json 定义
	if not _custom_fields.is_empty():
		_section("自定义字段")
		for field in _custom_fields:
			_add_custom_field_editor(data, field)
		_add_hint("字段定义在 res://focus_tree_custom_fields.json；值存在 FocusNodeData.custom 里。")

	var delete_button := Button.new()
	delete_button.text = "删除此国策"
	delete_button.pressed.connect(func() -> void: delete_focus(data.id))
	_props_box.add_child(delete_button)

	_updating_ui = false


## 按 FocusFieldSchema 的定义渲染一个自定义字段控件。
func _add_custom_field_editor(data: FocusNodeData, field: Dictionary) -> void:
	var key := String(field.get("key", ""))
	if key.is_empty():
		return
	var label_text := String(field.get("label", key))
	var field_type := String(field.get("type", "string"))
	var value: Variant = data.custom.get(key, field.get("default", FocusFieldSchema.default_for(field_type)))

	match field_type:
		"bool":
			var row := _row(label_text)
			var check := CheckBox.new()
			check.button_pressed = bool(value)
			check.toggled.connect(func(pressed: bool) -> void:
				_set_custom_value(data, key, pressed))
			row.add_child(check)
		"int":
			var spin := _spin_field(label_text, float(int(value)), -999999.0, 999999.0, 1.0)
			spin.value_changed.connect(func(new_value: float) -> void:
				_set_custom_value(data, key, int(new_value)))
		"float":
			var spin := _spin_field(label_text, float(value), -999999.0, 999999.0, 0.1)
			spin.value_changed.connect(func(new_value: float) -> void:
				_set_custom_value(data, key, new_value))
		"text":
			var edit := _text_field(label_text, String(value), 56.0)
			edit.text_changed.connect(func() -> void:
				_set_custom_value(data, key, edit.text))
		_:
			var edit := _line_field(label_text, String(value))
			edit.text_changed.connect(func(text: String) -> void:
				_set_custom_value(data, key, text))


func _set_custom_value(data: FocusNodeData, key: String, value: Variant) -> void:
	if _updating_ui or data == null:
		return
	data.custom[key] = value
	_mark_dirty()


func _section(text: String) -> void:
	_props_box.add_child(HSeparator.new())
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.modulate = Color(0.72, 0.84, 1.0, 1.0)
	_props_box.add_child(label)


## 属性区里的灰色小字说明。
func _add_hint(text: String) -> void:
	var hint := Label.new()
	hint.text = text
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 10)
	hint.modulate = Color(1, 1, 1, 0.42)
	_props_box.add_child(hint)


func _row(label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(84.0, 0.0)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.add_theme_font_size_override("font_size", 11)
	row.add_child(label)
	_props_box.add_child(row)
	return row


func _line_field(label_text: String, value: String) -> LineEdit:
	var row := _row(label_text)
	var edit := LineEdit.new()
	edit.text = value
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(edit)
	return edit


func _text_field(label_text: String, value: String, height: float) -> TextEdit:
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 11)
	label.modulate = Color(1, 1, 1, 0.6)
	_props_box.add_child(label)

	var edit := TextEdit.new()
	edit.text = value
	edit.custom_minimum_size = Vector2(0.0, height)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_props_box.add_child(edit)
	return edit


func _spin_field(label_text: String, value: float, min_value: float, max_value: float, step: float) -> SpinBox:
	var row := _row(label_text)
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.rounded = is_equal_approx(step, roundf(step))
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spin)
	return spin


## 通用的“id 列表”编辑器：列表 + 删除按钮 + 下拉候选 + 添加按钮。
func _build_reference_list(ids: Array[String], on_add: Callable, on_remove: Callable) -> void:
	var list := ItemList.new()
	if ids.is_empty():
		var none := Label.new()
		none.text = "  （无）"
		none.add_theme_font_size_override("font_size", 11)
		none.modulate = Color(1, 1, 1, 0.35)
		_props_box.add_child(none)
	else:
		list.custom_minimum_size = Vector2(0.0, minf(26.0 * ids.size() + 10.0, 120.0))
		for focus_id in ids:
			list.add_item(focus_id)
		_props_box.add_child(list)
		var remove_button := Button.new()
		remove_button.text = "移除选中"
		remove_button.pressed.connect(func() -> void:
			var selected := list.get_selected_items()
			if selected.is_empty():
				return
			var index: int = selected[0]
			if index >= 0 and index < ids.size():
				on_remove.call(ids[index]))
		_props_box.add_child(remove_button)

	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 4)
	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var candidates := 0
	for other in tree_data.nodes:
		if other == null or other == _selected or ids.has(other.id):
			continue
		option.add_item(other.id)
		candidates += 1
	if candidates == 0:
		option.disabled = true
	else:
		option.select(0)
	var add_button := Button.new()
	add_button.text = "添加"
	add_button.disabled = candidates == 0
	add_button.pressed.connect(func() -> void:
		if option.item_count == 0 or option.selected < 0:
			return
		on_add.call(option.get_item_text(option.selected)))
	add_row.add_child(option)
	add_row.add_child(add_button)
	_props_box.add_child(add_row)


# ---------------------------------------------------------------------------
# 属性编辑回调
# ---------------------------------------------------------------------------

func _commit_id_edit(edit: LineEdit, text: String) -> void:
	if _updating_ui or _selected == null or not is_instance_valid(edit):
		return
	if text.strip_edges() == _selected.id:
		return
	rename_focus(_selected.id, text)


## 修改国策 id，并同步更新所有引用（连线、互斥、条件表达式、相对定位）。
## 返回是否成功；失败原因写在状态栏。
func rename_focus(old_id: String, raw_new_id: String) -> bool:
	var data := _find_data(old_id)
	if data == null:
		return false
	var trimmed := raw_new_id.strip_edges()
	var new_id := FocusNodeData.sanitize_id(trimmed)
	# 手工改名要求“原样合法”，不做静默清洗，避免策划输入中文后得到一个莫名其妙的 id
	if new_id.is_empty() or new_id != trimmed:
		_status("ID 无效：%s。只能使用字母、数字和下划线，且不能以数字开头。" % raw_new_id)
		_rebuild_properties()
		return false
	if new_id == old_id:
		return false
	if _find_data(new_id) != null:
		_status("ID %s 已存在。" % new_id)
		_rebuild_properties()
		return false

	data.id = new_id
	var node: FocusGraphNode = _nodes.get(old_id)
	_nodes.erase(old_id)
	if node != null and is_instance_valid(node):
		node.name = new_id
		_nodes[new_id] = node
	for other in tree_data.nodes:
		if other != null:
			other.replace_id_references(old_id, new_id)
	_rebuild_connections()
	_refresh_node_visuals()
	_rebuild_properties()
	_mark_dirty()
	_status("已把 %s 改名为 %s（引用已同步）。" % [old_id, new_id])
	return true


func _add_prerequisite_to(data: FocusNodeData, target_id: String) -> void:
	if data == null or target_id.is_empty():
		return
	if _depends_on(target_id, data.id):
		_status("不能添加 %s：会形成依赖环。" % target_id)
		return
	if data.prerequisites.has(target_id):
		return
	data.prerequisites.append(target_id)
	_rebuild_connections()
	_refresh_node_visuals()
	_mark_dirty()
	if _selected == data:
		_rebuild_properties()


func _remove_prerequisite_from(data: FocusNodeData, target_id: String) -> void:
	if data == null:
		return
	var idx := data.prerequisites.find(target_id)
	if idx == -1:
		return
	data.prerequisites.remove_at(idx)
	_rebuild_connections()
	_refresh_node_visuals()
	_mark_dirty()
	if _selected == data:
		_rebuild_properties()


func _add_mutex_to(data: FocusNodeData, target_id: String) -> void:
	if data == null or target_id.is_empty() or target_id == data.id:
		return
	if data.mutually_exclusive.has(target_id):
		return
	data.mutually_exclusive.append(target_id)
	# 互斥关系自动保持双向，避免只写一半
	var other := _find_data(target_id)
	if other != null and not other.mutually_exclusive.has(data.id):
		other.mutually_exclusive.append(data.id)
	_sync_relation_overlays()
	_mark_dirty()
	if _selected == data:
		_rebuild_properties()


func _remove_mutex_from(data: FocusNodeData, target_id: String) -> void:
	if data == null:
		return
	var idx := data.mutually_exclusive.find(target_id)
	if idx == -1:
		return
	data.mutually_exclusive.remove_at(idx)
	var other := _find_data(target_id)
	if other != null:
		other.mutually_exclusive.erase(data.id)
	_sync_relation_overlays()
	_mark_dirty()
	if _selected == data:
		_rebuild_properties()


func _assign_lines(data: FocusNodeData, field: String, text: String) -> void:
	if _updating_ui or data == null:
		return
	var lines: Array[String] = []
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if not trimmed.is_empty():
			lines.append(trimmed)
	data.set(field, lines)
	_mark_dirty()


# ---------------------------------------------------------------------------
# 位置 / id 辅助
# ---------------------------------------------------------------------------

## 画布可见区域的中心（图坐标）。
func _visible_center() -> Vector2:
	var zoom := maxf(_graph.zoom, 0.01)
	return _graph.scroll_offset + _graph.size / (2.0 * zoom)


## 为新节点找一个不压住别人的位置：
## 有选中节点就放它右边，否则放画布中心；重叠就一格格往下 / 往右错开。
func _find_free_position() -> Vector2:
	var start := _visible_center()
	if _selected != null:
		var selected_node: FocusGraphNode = _nodes.get(_selected.id)
		if selected_node != null:
			start = selected_node.position_offset + Vector2(LAYOUT_COLUMN_GAP, 0.0)
	start.x = maxf(start.x, 0.0)
	start.y = maxf(start.y, 0.0)

	var candidate := start
	for i in MAX_ADD_SCAN:
		if not _position_is_taken(candidate):
			return candidate
		candidate.y += LAYOUT_ROW_GAP
		if i % 8 == 7:
			# 一列放满就换列
			candidate.x += LAYOUT_COLUMN_GAP
			candidate.y = start.y
	return Vector2(LAYOUT_ORIGIN.x, LAYOUT_ORIGIN.y + (tree_data.nodes.size() * LAYOUT_ROW_GAP))


## 该位置是否与已有节点重叠（用节点实际尺寸判断）。
func _position_is_taken(candidate: Vector2) -> bool:
	var probe := Rect2(candidate, FocusGraphNode.NODE_MIN_SIZE)
	for node in _nodes.values():
		if not (node is FocusGraphNode):
			continue
		var rect := Rect2((node as Control).position_offset, (node as Control).size)
		if rect.size == Vector2.ZERO:
			rect.size = FocusGraphNode.NODE_MIN_SIZE
		if probe.intersects(rect):
			return true
	return false


func _find_data(focus_id: String) -> FocusNodeData:
	if tree_data == null or focus_id.is_empty():
		return null
	return tree_data.get_focus(focus_id)


func _next_focus_id() -> String:
	var highest := 0
	var pattern := RegEx.create_from_string("^focus_(\\d+)$")
	if tree_data != null:
		for data in tree_data.nodes:
			if data == null:
				continue
			var found := pattern.search(data.id)
			if found != null:
				highest = maxi(highest, int(found.get_string(1)))
	var candidate := "focus_%03d" % (highest + 1)
	var attempt := highest + 1
	while _find_data(candidate) != null:
		attempt += 1
		candidate = "focus_%03d" % attempt
	return candidate


func _make_unique_id(used: Dictionary) -> String:
	var index := 1
	var candidate := "focus_%03d" % index
	while used.has(candidate):
		index += 1
		candidate = "focus_%03d" % index
	return candidate


## from_id 是否（直接或间接）依赖 target_id（普通前置和「任一前置」组都算依赖边）。
func _depends_on(from_id: String, target_id: String) -> bool:
	var stack: Array[String] = [from_id]
	var visited := {}
	while not stack.is_empty():
		var current: String = stack.pop_back()
		if current == target_id:
			return true
		if visited.has(current):
			continue
		visited[current] = true
		var data := _find_data(current)
		if data == null or tree_data == null:
			continue
		for dependency in tree_data.get_dependencies(data):
			if not visited.has(dependency):
				stack.append(dependency)
	return false


func _selected_id_or_none() -> String:
	return _selected.id if _selected != null else "<none>"


# ---------------------------------------------------------------------------
# 状态 / 报告 / 杂项
# ---------------------------------------------------------------------------

func _mark_dirty(value: bool = true) -> void:
	_dirty = value
	_update_header()


func _update_header() -> void:
	if _header_label == null:
		return
	var tree_name := "未命名"
	if tree_data != null and not tree_data.tree_name.strip_edges().is_empty():
		tree_name = tree_data.tree_name.strip_edges()
	var path := current_path if not current_path.is_empty() else "（未保存）"
	var dirty_mark := " *" if _dirty else ""
	_header_label.text = "%s  |  %s%s" % [tree_name, path, dirty_mark]
	_header_label.tooltip_text = "%s\n%s" % [tree_name, path]


func _status(message: String) -> void:
	if _status_label != null:
		_status_label.text = message
	status_changed.emit(message)


func _show_report(title: String, lines: Array) -> void:
	var text := "\n".join(PackedStringArray(lines))
	if not _can_popup():
		push_warning("[FocusTreeEditor] %s:\n%s" % [title, text])
		return
	_report_dialog.title = title
	_report_text.text = text
	_report_dialog.popup_centered()


func _can_popup() -> bool:
	return DisplayServer.get_name() != "headless"


func _normalize_path(path: String) -> String:
	if path.is_empty():
		return ""
	var normalized := path.replace("\\", "/")
	var project_root := ProjectSettings.globalize_path("res://").replace("\\", "/")
	if normalized.begins_with(project_root):
		normalized = "res://" + normalized.substr(project_root.length())
	if normalized.ends_with("/"):
		normalized = normalized.substr(0, normalized.length() - 1)
	return normalized
