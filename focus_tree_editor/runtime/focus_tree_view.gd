class_name FocusTreeView
extends Control

## 开箱即用的运行时国策树界面（一个节点 + show()/hide()）。
##
## 用法：
##   1. 把 `runtime/focus_tree_view.tscn` 实例化到游戏场景里（建议放在 CanvasLayer 下）；
##   2. 场景里有 FocusTreeManager 时自动找到它（也可以直接拖到 manager 属性上）；
##   3. 代码里 `view.open()` / `view.close()`（或 `show()` / `hide()`）即可。
##
## 卡片是真实场景节点（PanelContainer + Label + ProgressBar），
## 想改样式/换字体/加图标，直接编辑 `focus_card.tscn` 或本场景即可，不用改脚本。

signal focus_clicked(focus_id: String)

## 树的数据来源；留空会自动找场景里的 FocusTreeManager。
@export var manager: FocusTreeManager = null
## 卡片场景（想换外观就换这个 PackedScene）。
@export var card_scene: PackedScene = preload("res://addons/focus_tree_editor/runtime/focus_card.tscn")
## 卡片基准尺寸（会按可用空间整体缩放）。
@export var card_size := Vector2(240.0, 120.0)
## 节点进入场景时是否自动打开。
@export var open_on_ready := true
## 标题文字。
@export var tree_title := "国策树"

const LINE_COLOR := Color(0.45, 0.47, 0.52)
const LINE_DONE := Color(0.42, 0.78, 0.46)
const MUTEX_COLOR := Color(0.93, 0.34, 0.30)
const ANY_COLOR := Color(0.93, 0.34, 0.30)
const DASH_LENGTH := 9.0
const DASH_GAP := 6.0

var _cards: Dictionary = {}
var _bounds := Rect2()

@onready var _title: Label = $Panel/Margin/VBox/Header/Title
@onready var _slots: HBoxContainer = $Panel/Margin/VBox/Header/Slots
@onready var _close_button: Button = $Panel/Margin/VBox/Header/Close
@onready var _tree: Control = $Panel/Margin/VBox/Tree
@onready var _content: Control = $Panel/Margin/VBox/Tree/Content
@onready var _lines_root: Control = $Panel/Margin/VBox/Tree/Content/Lines
@onready var _cards_root: Control = $Panel/Margin/VBox/Tree/Content/Cards
@onready var _status: Label = $Panel/Margin/VBox/Status


func _ready() -> void:
	if manager == null:
		manager = get_tree().get_first_node_in_group("focus_tree_manager") as FocusTreeManager
	_title.text = tree_title
	_close_button.pressed.connect(close)
	_tree.resized.connect(_relayout)

	if manager == null:
		push_warning("[FocusTreeView] 没找到 FocusTreeManager：把管理器放进场景，或把节点拖到 manager 属性上。")
		visible = false
		return

	manager.focus_started.connect(_on_manager_changed)
	manager.focus_completed.connect(_on_manager_changed)
	manager.focus_unlocked.connect(_on_manager_changed)
	manager.focus_progress.connect(_on_focus_progress)
	manager.variable_changed.connect(_on_manager_changed)

	if open_on_ready:
		open()
	else:
		visible = false


# ---------------------------------------------------------------------------
# 对外 API
# ---------------------------------------------------------------------------

## 构建并显示国策树。
func open() -> void:
	if manager == null or manager.tree == null:
		push_warning("[FocusTreeView] 没有可显示的国策树：先 manager.load_tree(...) 或 set_tree(...)。")
		return
	_rebuild()
	visible = true
	_relayout()


func close() -> void:
	visible = false


func toggle() -> void:
	if visible:
		close()
	else:
		open()


## 数据/布局改过之后手动刷新（换树、改了节点位置等）。
func refresh() -> void:
	if not visible:
		return
	_rebuild()
	_relayout()


## 往标题栏右侧塞自己的控件（比如资源条、时间流速、关闭前的按钮）。
func add_header_control(control: Control) -> void:
	_slots.add_child(control)


## 底部状态文字；传空字符串会恢复默认提示。
func set_status(text: String) -> void:
	if text.is_empty():
		_status.text = _default_status()
	else:
		_status.text = text


# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------

func _rebuild() -> void:
	for child in _cards_root.get_children():
		child.queue_free()
	for child in _lines_root.get_children():
		child.queue_free()
	_cards.clear()

	if manager == null or manager.tree == null:
		return

	# 用编辑器里的自由坐标算包围盒
	var first := true
	for data in manager.tree.nodes:
		if data == null:
			continue
		var rect := Rect2(data.position, card_size)
		if first:
			_bounds = rect
			first = false
		else:
			_bounds = _bounds.merge(rect)
	if first:
		return

	for data in manager.tree.nodes:
		if data == null:
			continue
		var card := card_scene.instantiate() as FocusCard
		_cards_root.add_child(card)
		card.card_size = card_size
		card.setup(data)
		card.position = data.position - _bounds.position
		card.pressed.connect(_on_card_pressed)
		_cards[data.id] = card

	_content.position = Vector2.ZERO
	_content.size = _bounds.size
	_lines_root.size = _bounds.size
	_cards_root.size = _bounds.size

	_build_lines()
	_refresh_states()


func _build_lines() -> void:
	if manager == null or manager.tree == null:
		return
	var seen_mutex := {}
	var seen_any := {}
	for data in manager.tree.nodes:
		if data == null:
			continue
		var to_card: FocusCard = _cards.get(data.id)
		if to_card == null:
			continue
		# 普通前置：实线，前置已完成时变绿
		for prereq_id in data.prerequisites:
			var from_card: FocusCard = _cards.get(prereq_id)
			if from_card == null:
				continue
			var color := LINE_DONE if manager.is_completed(prereq_id) else LINE_COLOR
			_add_line(_connect_points(from_card, to_card), color, 2.0)
		# 互斥：红色实线
		for other_id in data.mutually_exclusive:
			if not _cards.has(other_id):
				continue
			var key := "%s|%s" % [data.id, other_id] if data.id < other_id else "%s|%s" % [other_id, data.id]
			if seen_mutex.has(key):
				continue
			seen_mutex[key] = true
			_add_line(_connect_points(_cards[other_id], to_card), MUTEX_COLOR, 2.5)
		# 任一前置：红色虚线 + 箭头
		for group in data.get_any_groups():
			for member_id in group:
				if not _cards.has(member_id):
					continue
				var any_key := "%s>%s" % [member_id, data.id]
				if seen_any.has(any_key):
					continue
				seen_any[any_key] = true
				var points := _connect_points(_cards[member_id], to_card)
				_add_dashed_line(points, ANY_COLOR, 2.2)
				var direction := (points[points.size() - 1] - points[0]).normalized()
				_add_arrow(points[points.size() - 1], direction, ANY_COLOR)


## 从卡片的相对边中点连出去：横向为主走左右，纵向为主走上下。
func _connect_points(from_card: Control, to_card: Control) -> PackedVector2Array:
	var a := Rect2(from_card.position, from_card.size)
	var b := Rect2(to_card.position, to_card.size)
	var center_a := a.get_center()
	var center_b := b.get_center()
	var delta := center_b - center_a
	if absf(delta.x) >= absf(delta.y):
		if delta.x >= 0.0:
			return PackedVector2Array([Vector2(a.end.x, center_a.y), Vector2(b.position.x, center_b.y)])
		return PackedVector2Array([Vector2(a.position.x, center_a.y), Vector2(b.end.x, center_b.y)])
	if delta.y >= 0.0:
		return PackedVector2Array([Vector2(center_a.x, a.end.y), Vector2(center_b.x, b.position.y)])
	return PackedVector2Array([Vector2(center_a.x, a.position.y), Vector2(center_b.x, b.end.y)])


func _add_line(points: PackedVector2Array, color: Color, width: float) -> void:
	var line := Line2D.new()
	line.points = points
	line.width = width
	line.default_color = color
	line.antialiased = true
	_lines_root.add_child(line)


func _add_dashed_line(points: PackedVector2Array, color: Color, width: float) -> void:
	if points.size() < 2:
		return
	var start := points[0]
	var end := points[points.size() - 1]
	var direction := (end - start).normalized()
	var length := start.distance_to(end)
	var travelled := 0.0
	while travelled < length:
		var segment_end := minf(travelled + DASH_LENGTH, length)
		var line := Line2D.new()
		line.points = PackedVector2Array([start + direction * travelled, start + direction * segment_end])
		line.width = width
		line.default_color = color
		line.antialiased = true
		_lines_root.add_child(line)
		travelled += DASH_LENGTH + DASH_GAP


func _add_arrow(tip: Vector2, direction: Vector2, color: Color) -> void:
	if direction == Vector2.ZERO:
		return
	var side := direction.orthogonal()
	var size := 8.0
	var arrow := Polygon2D.new()
	arrow.polygon = PackedVector2Array([
		tip,
		tip - direction * size + side * size * 0.5,
		tip - direction * size - side * size * 0.5,
	])
	arrow.color = color
	_lines_root.add_child(arrow)


# ---------------------------------------------------------------------------
# 布局与刷新
# ---------------------------------------------------------------------------

func _relayout() -> void:
	if _content.size.x <= 0.0 or _content.size.y <= 0.0:
		return
	var area := _tree.size
	if area.x <= 0.0 or area.y <= 0.0:
		return
	var fit := clampf(minf((area.x - 4.0) / _content.size.x, (area.y - 4.0) / _content.size.y), 0.35, 1.0)
	_content.scale = Vector2(fit, fit)
	_content.pivot_offset = Vector2.ZERO
	var offset := (area - _content.size * fit) * 0.5
	_content.position = Vector2(maxf(offset.x, 0.0), maxf(offset.y, 0.0))


func _refresh_states() -> void:
	if manager == null:
		return
	for focus_id in _cards.keys():
		var card: FocusCard = _cards[focus_id]
		card.apply_state(manager.get_focus_state(focus_id), manager.get_progress(focus_id))
	set_status("")


func _default_status() -> String:
	if manager == null or manager.tree == null:
		return ""
	if not manager.get_active_focus().is_empty():
		var active := manager.get_focus(manager.get_active_focus())
		var title := manager.get_active_focus()
		if active != null:
			title = active.title
		return "正在研究「%s」：%d%%" % [title, int(round(manager.get_progress(manager.get_active_focus()) * 100.0))]
	var available := manager.get_available_ids()
	if available.is_empty():
		return "当前没有可研究的国策。"
	return "点击金色的国策开始研究；金色 = 可研究，黄色 = 进行中，绿色 = 已完成。"


func _on_card_pressed(focus_id: String) -> void:
	focus_clicked.emit(focus_id)
	if manager == null:
		return
	manager.start_focus(focus_id)
	_refresh_states()


func _on_focus_progress(focus_id: String, ratio: float) -> void:
	if not visible:
		return
	var card: FocusCard = _cards.get(focus_id)
	if card != null:
		card.set_progress(ratio)
	set_status("")


func _on_manager_changed(_arg1: Variant = null, _arg2: Variant = null) -> void:
	if visible:
		_refresh_states()
