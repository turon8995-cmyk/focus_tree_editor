@tool
class_name FocusGraphEdit
extends GraphEdit

## 国策树画布：继承 GraphEdit，在原生连线之上再画一层“非前置关系”。
##
##   · 互斥（mutually_exclusive）      —— 红色实线，中点一个 ×（双向关系，只画一条）
##   · 任一前置组（prerequisite_any_groups）—— 红色虚线，箭头指向后继（组内任一完成即可）
##
## 原生连线的颜色跟随端口颜色、画法固定，无法表达这两种语义，
## 所以这里按节点矩形自己画；缩放 / 平移 / 拖动节点都会自动跟随（见 _process 的指纹对比）。

const MUTEX_COLOR := Color(0.93, 0.34, 0.30)
const ANY_COLOR := Color(0.93, 0.34, 0.30)
const LINE_BASE_WIDTH := 2.5
const DASH_BASE_LENGTH := 8.0
const ARROW_BASE_SIZE := 7.0

## 互斥对：Array[PackedStringArray]，每项 [id_a, id_b]，无方向。
var _mutex_pairs: Array = []
## 任一前置对：Array[PackedStringArray]，每项 [member_id, target_id]，方向是 member → target。
var _any_pairs: Array = []
var _last_signature := Vector2.INF


## 由 FocusTreeEditor 在数据变化后调用。
func set_relation_pairs(mutex_pairs: Array, any_pairs: Array) -> void:
	_mutex_pairs = mutex_pairs
	_any_pairs = any_pairs
	set_process(not (mutex_pairs.is_empty() and any_pairs.is_empty()))
	_last_signature = Vector2.INF
	queue_redraw()


func _process(_delta: float) -> void:
	# GraphEdit 没有 zoom_changed 信号，拖动节点时也不会逐帧通知，这里做个轻量轮询
	var signature := _signature()
	if signature != _last_signature:
		_last_signature = signature
		queue_redraw()


## 「滚动 + 缩放 + 所有相关节点位置」的指纹，变了才重画。
func _signature() -> Vector2:
	var acc := scroll_offset + Vector2(get_zoom(), get_zoom() * 0.5)
	for list in [_mutex_pairs, _any_pairs]:
		for pair in list:
			if pair.size() < 2:
				continue
			for i in 2:
				var node := get_node_or_null(NodePath(String(pair[i])))
				if node is Control:
					acc += (node as Control).position_offset
	return acc


func _draw() -> void:
	if _mutex_pairs.is_empty() and _any_pairs.is_empty():
		return
	var zoom := maxf(get_zoom(), 0.01)
	var width := maxf(LINE_BASE_WIDTH * zoom, 1.6)
	var dash := maxf(DASH_BASE_LENGTH * zoom, 4.0)

	# 互斥：红色实线 + 中点一个红圈 ×
	for pair in _mutex_pairs:
		var nodes := _pair_nodes(pair)
		if nodes.is_empty():
			continue
		var points := _connection_points(_local_rect(nodes[0]), _local_rect(nodes[1]))
		draw_line(points[0], points[1], MUTEX_COLOR, width, true)
		_draw_mutex_badge(points[0], points[1], zoom)

	# 任一前置：红色虚线 + 指向后继的箭头
	for pair in _any_pairs:
		var nodes := _pair_nodes(pair)
		if nodes.is_empty():
			continue
		var points := _connection_points(_local_rect(nodes[0]), _local_rect(nodes[1]))
		draw_dashed_line(points[0], points[1], ANY_COLOR, width, dash, true, true)
		_draw_arrow(points[1], (points[1] - points[0]).normalized(), zoom)


func _pair_nodes(pair: PackedStringArray) -> Array:
	if pair.size() < 2:
		return []
	var node_a := get_node_or_null(NodePath(String(pair[0])))
	var node_b := get_node_or_null(NodePath(String(pair[1])))
	if node_a is Control and node_b is Control:
		return [node_a as Control, node_b as Control]
	return []


## 互斥线中点的“红圈 ×”徽标，比单纯画一个字符清楚得多。
func _draw_mutex_badge(from_point: Vector2, to_point: Vector2, zoom: float) -> void:
	var mid: Vector2 = (from_point + to_point) * 0.5
	var radius := maxf(7.0 * zoom, 5.0)
	draw_circle(mid, radius, Color(0.09, 0.09, 0.11, 0.96))
	draw_arc(mid, radius, 0.0, TAU, 28, MUTEX_COLOR, maxf(1.6 * zoom, 1.0), true)
	var arm := radius * 0.46
	var stroke := maxf(2.0 * zoom, 1.4)
	draw_line(mid - Vector2(arm, arm), mid + Vector2(arm, arm), MUTEX_COLOR, stroke, true)
	draw_line(mid - Vector2(arm, -arm), mid + Vector2(arm, -arm), MUTEX_COLOR, stroke, true)


func _draw_arrow(tip: Vector2, direction: Vector2, zoom: float) -> void:
	if direction == Vector2.ZERO:
		return
	var side := direction.orthogonal()
	var size := maxf(ARROW_BASE_SIZE * zoom, 5.0)
	draw_colored_polygon(PackedVector2Array([
		tip,
		tip - direction * size + side * size * 0.55,
		tip - direction * size - side * size * 0.55,
	]), ANY_COLOR)


## 把节点的全局矩形换算到画布本地坐标（自动适配缩放和滚动）。
func _local_rect(node: Control) -> Rect2:
	var global_rect := node.get_global_rect()
	return Rect2(global_rect.position - get_global_position(), global_rect.size)


## 取两个矩形相对的两个边中点：横向为主走左右边，纵向为主走上下边。
func _connection_points(a: Rect2, b: Rect2) -> Array:
	var center_a := a.get_center()
	var center_b := b.get_center()
	var delta := center_b - center_a
	if absf(delta.x) >= absf(delta.y):
		if delta.x >= 0.0:
			return [Vector2(a.end.x, center_a.y), Vector2(b.position.x, center_b.y)]
		return [Vector2(a.position.x, center_a.y), Vector2(b.end.x, center_b.y)]
	if delta.y >= 0.0:
		return [Vector2(center_a.x, a.end.y), Vector2(center_b.x, b.position.y)]
	return [Vector2(center_a.x, a.position.y), Vector2(center_b.x, b.end.y)]
