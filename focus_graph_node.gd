@tool
class_name FocusGraphNode
extends GraphNode

## 国策树的图形节点：GraphNode 子类，持有一个 FocusNodeData 引用。
##
## 只负责“显示”这份数据；数据本身由 FocusTreeEditor 修改，改完调用 refresh() 重绘。
## 节点上只开一个 slot：左边是前置入口，右边是后继出口，看起来像 HOI4 的一条横向汇流。

const PORT_COLOR_IN := Color(0.42, 0.72, 1.0)
const PORT_COLOR_OUT := Color(1.0, 0.72, 0.35)
const NODE_MIN_SIZE := Vector2(252.0, 116.0)
const ICON_BOX := Vector2(52.0, 52.0)

## 该图形节点显示的数据（不要直接改它的字段，改完请调 refresh()）。
var data: FocusNodeData = null

var _icon_rect: TextureRect
var _icon_placeholder: Label
var _id_label: Label
var _meta_label: Label
var _built := false


func _ready() -> void:
	_ensure_built()
	refresh()


## 绑定/更换数据。会同时把节点名同步成 data.id（GraphEdit 的连线是按节点名索引的）。
func set_data(p_data: FocusNodeData) -> void:
	data = p_data
	_ensure_built()
	if data != null and not data.id.is_empty():
		name = data.id
	refresh()


func get_data() -> FocusNodeData:
	return data


## 根据 data 刷新标题、图标、说明与 tooltip。
func refresh() -> void:
	if not _built:
		return
	if data == null:
		title = "<无数据>"
		_icon_rect.texture = null
		_icon_placeholder.visible = true
		_id_label.text = ""
		_meta_label.text = ""
		tooltip_text = ""
		return
	title = data.display_title()
	_icon_rect.texture = data.icon
	_icon_placeholder.visible = data.icon == null
	_id_label.text = data.id
	_meta_label.text = _build_meta_text()
	tooltip_text = _build_tooltip()


func _ensure_built() -> void:
	if _built:
		return
	_built = true

	custom_minimum_size = NODE_MIN_SIZE
	resizable = false
	draggable = true
	selectable = true
	# 单 slot 同时开左右端口：连线可以从右边拖出、也可从左边的点接收
	set_slot(0, true, 0, PORT_COLOR_IN, true, 0, PORT_COLOR_OUT)

	var margin := MarginContainer.new()
	margin.name = "Body"
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 6)
	add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	margin.add_child(box)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	box.add_child(top)

	# 图标位（没有图标时显示占位问号）
	var icon_slot := Control.new()
	icon_slot.custom_minimum_size = ICON_BOX
	icon_slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(icon_slot)

	_icon_rect = TextureRect.new()
	_icon_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_slot.add_child(_icon_rect)

	_icon_placeholder = Label.new()
	_icon_placeholder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_icon_placeholder.text = "?"
	_icon_placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_icon_placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_icon_placeholder.modulate = Color(1, 1, 1, 0.28)
	icon_slot.add_child(_icon_placeholder)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	info.add_theme_constant_override("separation", 1)
	top.add_child(info)

	_id_label = Label.new()
	_id_label.add_theme_font_size_override("font_size", 11)
	_id_label.modulate = Color(1, 1, 1, 0.5)
	_id_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(_id_label)

	_meta_label = Label.new()
	_meta_label.add_theme_font_size_override("font_size", 12)
	_meta_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(_meta_label)


func _build_meta_text() -> String:
	# 只放最关键的“天数 / 政治点”；前置数量看连线即可，避免文本被裁掉
	var parts := PackedStringArray()
	parts.append("%d 天" % maxi(data.days, 1))
	if data.cost > 0:
		parts.append("%d 政治点" % data.cost)
	return " · ".join(parts)


func _build_tooltip() -> String:
	var lines := PackedStringArray()
	var desc := data.description.strip_edges()
	if not desc.is_empty():
		lines.append(desc)
		lines.append("")
	lines.append("ID：%s" % data.id)
	lines.append("位置：（%d, %d）" % [int(data.position.x), int(data.position.y)])
	if not data.prerequisites.is_empty():
		lines.append("前置：%s" % ", ".join(data.prerequisites))
	if not data.prerequisite_any_groups.is_empty():
		lines.append("任一前置：%s" % "；".join(data.prerequisite_any_groups))
	if not data.mutually_exclusive.is_empty():
		lines.append("互斥：%s" % ", ".join(data.mutually_exclusive))
	if not data.effects.is_empty():
		lines.append("效果：")
		for effect in data.effects:
			lines.append("  - " + effect)
	return "\n".join(lines)
