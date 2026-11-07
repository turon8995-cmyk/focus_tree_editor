class_name FocusTreeUI
extends Control

## 最小可用的国策树运行时 UI（示例）。
##
## 用 _draw() 直接画节点框、连线、进度条，点击节点即开始研究。
## 数据全部来自 FocusTreeManager，所以编辑器里保存的 .tres 改完立刻生效。
## 想换成正式美术资源时，把这个脚本当作行为参考即可。

signal focus_clicked(focus_id: String)

@export var manager: FocusTreeManager = null
## 单个国策框的基准尺寸（整体会按可用空间缩放）。
@export var card_size := Vector2(240.0, 120.0)
## 画布留白。
@export var margin := 36.0
## 点击节点是否自动开始研究。
@export var click_starts_focus := true

const COL_BG_LOCKED := Color(0.11, 0.11, 0.13)
const COL_BG_AVAILABLE := Color(0.17, 0.15, 0.10)
const COL_BG_ACTIVE := Color(0.20, 0.18, 0.09)
const COL_BG_COMPLETED := Color(0.10, 0.18, 0.11)

const COL_BORDER_LOCKED := Color(0.34, 0.34, 0.40)
const COL_BORDER_AVAILABLE := Color(0.86, 0.70, 0.30)
const COL_BORDER_ACTIVE := Color(0.98, 0.84, 0.36)
const COL_BORDER_COMPLETED := Color(0.42, 0.78, 0.46)

const COL_TEXT := Color(0.93, 0.93, 0.95)
const COL_TEXT_DIM := Color(0.62, 0.62, 0.68)
## 卡片上的描述文字（比标题暗一档）。
const COL_DESC := Color(0.70, 0.71, 0.78, 0.9)
const COL_LINE := Color(0.42, 0.42, 0.48)
const COL_LINE_DONE := Color(0.42, 0.78, 0.46)
const COL_PROGRESS := Color(0.98, 0.80, 0.32)

var _rects: Dictionary = {}
var _hover_id := ""
var _scale := 1.0
var _connected := false


func _ready() -> void:
	if manager == null:
		manager = _find_manager()
	if manager == null:
		push_warning("[FocusTreeUI] 没有指定 FocusTreeManager，画不出国策树。")
		return
	_connect_manager()
	resized.connect(_on_resized)
	rebuild()


func _find_manager() -> FocusTreeManager:
	var sibling := get_node_or_null("../FocusTreeManager")
	if sibling is FocusTreeManager:
		return sibling as FocusTreeManager
	return null


## 数据变化后重新布局（保留公开方法，示例场景与游戏逻辑都可调用）。
func rebuild() -> void:
	if manager != null:
		_connect_manager()
	_update_layout()
	queue_redraw()


func _connect_manager() -> void:
	if manager == null or _connected:
		return
	_connected = true
	manager.focus_started.connect(_on_manager_state_changed)
	manager.focus_completed.connect(_on_manager_state_changed)
	manager.focus_unlocked.connect(_on_manager_state_changed)
	manager.focus_progress.connect(_on_manager_progress)


func _on_manager_state_changed(_focus_id: String) -> void:
	_update_layout()
	queue_redraw()


func _on_manager_progress(_focus_id: String, _progress: float) -> void:
	queue_redraw()


func _on_resized() -> void:
	_update_layout()
	queue_redraw()


# ---------------------------------------------------------------------------
# 布局
# ---------------------------------------------------------------------------

func _update_layout() -> void:
	_rects.clear()
	if manager == null or manager.tree == null or manager.tree.nodes.is_empty():
		return

	# 直接沿用编辑器里摆好的自由坐标，再整体缩放适配当前窗口
	var bounds := Rect2(Vector2.INF, Vector2.ZERO)
	var first := true
	for data in manager.tree.nodes:
		if data == null:
			continue
		var rect := Rect2(data.position, card_size)
		if first:
			bounds = rect
			first = false
		else:
			bounds = bounds.merge(rect)
	if first or bounds.size == Vector2.ZERO:
		return

	_scale = 1.0
	if bounds.size.x > 0.0 and bounds.size.y > 0.0 and size.x > margin * 2.0 and size.y > margin * 2.0:
		_scale = clampf(minf((size.x - margin * 2.0) / bounds.size.x, (size.y - margin * 2.0) / bounds.size.y), 0.35, 1.0)

	var total := bounds.size * _scale
	var offset := Vector2(
		maxf((size.x - total.x) * 0.5, margin * 0.4),
		maxf((size.y - total.y) * 0.5, margin * 0.4))

	for data in manager.tree.nodes:
		if data == null:
			continue
		var pos := offset + (data.position - bounds.position) * _scale
		_rects[data.id] = Rect2(pos, card_size * _scale)


# ---------------------------------------------------------------------------
# 绘制
# ---------------------------------------------------------------------------

func _draw() -> void:
	if manager == null or manager.tree == null:
		return
	var font := get_theme_default_font()
	if font == null:
		return

	# 先画连线，保证压在卡片下面
	for data in manager.tree.nodes:
		if data == null:
			continue
		var to_rect: Rect2 = _rects.get(data.id, Rect2())
		if to_rect.size == Vector2.ZERO:
			continue
		for prereq_id in data.prerequisites:
			var from_rect: Rect2 = _rects.get(prereq_id, Rect2())
			if from_rect.size == Vector2.ZERO:
				continue
			var start := Vector2(from_rect.end.x, from_rect.get_center().y)
			var end := Vector2(to_rect.position.x, to_rect.get_center().y)
			var line_color := COL_LINE_DONE if manager.is_completed(prereq_id) else COL_LINE
			draw_line(start, end, line_color, maxf(2.0 * _scale, 1.5), true)
			_draw_arrow(end, (end - start).normalized(), line_color)

	for data in manager.tree.nodes:
		if data == null:
			continue
		var rect: Rect2 = _rects.get(data.id, Rect2())
		if rect.size == Vector2.ZERO:
			continue
		_draw_card(font, data, rect)


func _draw_arrow(tip: Vector2, direction: Vector2, color: Color) -> void:
	if direction == Vector2.ZERO:
		return
	var side := direction.orthogonal()
	var size := maxf(7.0 * _scale, 5.0)
	var points := PackedVector2Array([
		tip,
		tip - direction * size + side * size * 0.55,
		tip - direction * size - side * size * 0.55,
	])
	draw_colored_polygon(points, color)


func _draw_card(font: Font, data: FocusNodeData, rect: Rect2) -> void:
	var state := manager.get_focus_state(data.id)
	var bg := COL_BG_LOCKED
	var border := COL_BORDER_LOCKED
	var title_color := COL_TEXT_DIM
	match state:
		"completed":
			bg = COL_BG_COMPLETED
			border = COL_BORDER_COMPLETED
			title_color = COL_TEXT
		"in_progress":
			bg = COL_BG_ACTIVE
			border = COL_BORDER_ACTIVE
			title_color = COL_TEXT
		"available":
			bg = COL_BG_AVAILABLE
			border = COL_BORDER_AVAILABLE
			title_color = COL_TEXT
	if data.id == _hover_id:
		border = border.lightened(0.18)

	draw_rect(rect, bg, true)
	draw_rect(rect, border, false, maxf(2.0 * _scale, 1.5))
	# 左侧状态色条，模仿 HOI4 国策框
	draw_rect(Rect2(rect.position, Vector2(maxf(4.0 * _scale, 2.0), rect.size.y)), border, true)

	var pad := maxf(12.0 * _scale, 8.0)
	var box_width := rect.size.x - pad * 2.0
	var title_size := int(clampf(15.0 * _scale, 10.0, 17.0))
	var desc_size := int(clampf(11.0 * _scale, 9.0, 13.0))
	var footer_size := int(clampf(11.0 * _scale, 9.0, 12.0))
	var title_height := font.get_height(title_size)
	var desc_height := font.get_height(desc_size)
	var footer_height := font.get_height(footer_size)
	var gap := maxf(2.0, 3.0 * _scale)

	# 标题：最多两行
	var title_text := data.display_title()
	var title_lines := 1
	if font.get_string_size(title_text, HORIZONTAL_ALIGNMENT_LEFT, -1, title_size).x > box_width:
		title_lines = 2
	var title_baseline := pad + title_height * 0.85
	draw_multiline_string(font, rect.position + Vector2(pad, title_baseline), title_text,
		HORIZONTAL_ALIGNMENT_LEFT, box_width, title_size, title_lines, title_color)

	# 底部：进度条（仅进行中）+ 天数
	var bar_height := maxf(4.0, 4.0 * _scale)
	var has_bar := manager.is_in_progress(data.id)
	var footer_baseline := rect.size.y - pad
	var bar_rect := Rect2(
		rect.position + Vector2(pad, footer_baseline - footer_height - gap - bar_height),
		Vector2(box_width, bar_height))
	var content_bottom := rect.size.y - pad - footer_height - gap
	if has_bar:
		content_bottom = bar_rect.position.y - gap

	# 描述：标题下面最多两行，超出省略
	var description := data.description.strip_edges()
	var desc_top := pad + title_height * title_lines + gap
	var desc_space := content_bottom - desc_top
	if not description.is_empty() and desc_space >= desc_height * 0.9:
		var desc_lines := clampi(int(floor(desc_space / (desc_height + 1.0))), 1, 2)
		draw_multiline_string(font, rect.position + Vector2(pad, desc_top + desc_height * 0.85),
			description, HORIZONTAL_ALIGNMENT_LEFT, box_width, desc_size, desc_lines, COL_DESC)

	var footer := "%d 天" % maxi(data.days, 1)
	if data.cost > 0:
		footer += "  ·  %d 政治点" % data.cost
	draw_string(font, rect.position + Vector2(pad, footer_baseline), footer,
		HORIZONTAL_ALIGNMENT_LEFT, box_width, footer_size, COL_TEXT_DIM)

	if has_bar:
		draw_rect(bar_rect, Color(0.0, 0.0, 0.0, 0.55), true)
		var progress := manager.get_progress(data.id)
		draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * progress, bar_rect.size.y)), COL_PROGRESS, true)


## 鼠标悬停在卡片上时弹出完整信息（Godot 4.6 的 Control 虚函数签名带 at_position）。
func _get_tooltip(at_position: Vector2) -> String:
	if manager == null or manager.tree == null:
		return ""
	var focus_id := _id_at(at_position)
	if focus_id.is_empty():
		return ""
	return _build_tooltip_text(focus_id)


func _build_tooltip_text(focus_id: String) -> String:
	var data := manager.get_focus(focus_id)
	if data == null:
		return ""
	var lines := PackedStringArray()
	lines.append("【%s】" % data.display_title())
	var description := data.description.strip_edges()
	if not description.is_empty():
		lines.append(description)
	lines.append("")
	lines.append("时长：%d 天" % maxi(data.days, 1))
	if data.cost > 0:
		lines.append("成本：%d 政治点" % data.cost)
	match manager.get_focus_state(focus_id):
		"completed":
			lines.append("状态：已完成")
		"in_progress":
			lines.append("状态：研究中 %d%%" % int(round(manager.get_progress(focus_id) * 100.0)))
		"available":
			lines.append("状态：可研究（点击开始）")
		"hidden":
			lines.append("状态：本分支不可见")
		_:
			lines.append("状态：未解锁")
	if not data.effects.is_empty():
		lines.append("")
		lines.append("效果：")
		for effect in data.effects:
			lines.append("  · " + effect)
	if not data.prerequisites.is_empty():
		lines.append("前置：" + "、".join(data.prerequisites))
	if not data.prerequisite_any_groups.is_empty():
		lines.append("任一前置：" + "；".join(data.prerequisite_any_groups))
	if not data.mutually_exclusive.is_empty():
		lines.append("互斥：" + "、".join(data.mutually_exclusive))
	return "\n".join(lines)


# ---------------------------------------------------------------------------
# 交互
# ---------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if manager == null:
		return
	if event is InputEventMouseMotion:
		var hovered := _id_at(event.position)
		if hovered != _hover_id:
			_hover_id = hovered
			queue_redraw()
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			var clicked := _id_at(button.position)
			if clicked.is_empty():
				return
			focus_clicked.emit(clicked)
			if click_starts_focus:
				manager.start_focus(clicked)
			accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		if not _hover_id.is_empty():
			_hover_id = ""
			queue_redraw()


func _id_at(local_position: Vector2) -> String:
	for focus_id in _rects.keys():
		var rect: Rect2 = _rects[focus_id]
		if rect.has_point(local_position):
			return String(focus_id)
	return ""
