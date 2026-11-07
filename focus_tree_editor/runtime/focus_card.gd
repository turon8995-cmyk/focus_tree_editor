class_name FocusCard
extends PanelContainer

## 运行时国策卡片（场景节点，不是自绘）。
## 由 FocusTreeView 实例化并 setup()，点击时发 pressed 信号。

signal pressed(focus_id: String)

## 卡片的默认尺寸（FocusTreeView 会覆盖）。
@export var card_size := Vector2(240.0, 120.0)

const STATE_COLORS := {
	"locked": {"bg": Color(0.11, 0.11, 0.13), "border": Color(0.34, 0.34, 0.40), "text": Color(0.62, 0.62, 0.68)},
	"available": {"bg": Color(0.17, 0.15, 0.10), "border": Color(0.86, 0.70, 0.30), "text": Color(0.93, 0.93, 0.95)},
	"in_progress": {"bg": Color(0.20, 0.18, 0.09), "border": Color(0.98, 0.84, 0.36), "text": Color(0.93, 0.93, 0.95)},
	"completed": {"bg": Color(0.10, 0.18, 0.11), "border": Color(0.42, 0.78, 0.46), "text": Color(0.93, 0.93, 0.95)},
	"hidden": {"bg": Color(0.10, 0.10, 0.12), "border": Color(0.28, 0.28, 0.32), "text": Color(0.55, 0.55, 0.60)},
}

var data: FocusNodeData = null

@onready var _title_label: Label = $Margin/VBox/Title
@onready var _desc_label: Label = $Margin/VBox/Description
@onready var _footer_label: Label = $Margin/VBox/Footer
@onready var _progress: ProgressBar = $Margin/VBox/Progress

var _state := ""
var _hovering := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(func() -> void:
		_hovering = true
		_apply_style())
	mouse_exited.connect(func() -> void:
		_hovering = false
		_apply_style())

	# 进度条也换成金色，和状态色一致
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	bar_bg.set_corner_radius_all(3)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = Color(0.98, 0.80, 0.32)
	bar_fill.set_corner_radius_all(3)
	_progress.add_theme_stylebox_override("background", bar_bg)
	_progress.add_theme_stylebox_override("fill", bar_fill)


## 绑定数据（只做一次）。
func setup(node_data: FocusNodeData) -> void:
	data = node_data
	custom_minimum_size = card_size
	size = card_size
	pivot_offset = Vector2.ZERO
	_title_label.text = data.display_title()
	var description := data.description.strip_edges()
	_desc_label.text = description
	_desc_label.visible = not description.is_empty()
	_footer_label.text = _footer_text()
	tooltip_text = _tooltip_text()
	_apply_style()


## 根据管理器状态刷新外观。
func apply_state(state: String, progress: float) -> void:
	_state = state
	_progress.visible = state == "in_progress"
	_progress.value = progress * 100.0
	_apply_style()


## 只更新进度条（研究过程中每帧调用，不重刷样式）。
func set_progress(ratio: float) -> void:
	if _state != "in_progress":
		return
	_progress.visible = true
	_progress.value = clampf(ratio, 0.0, 1.0) * 100.0


func _footer_text() -> String:
	var text := "%d 天" % maxi(data.days, 1)
	if data.cost > 0:
		text += "  ·  %d 政治点" % data.cost
	return text


func _tooltip_text() -> String:
	var lines := PackedStringArray()
	lines.append("【%s】" % data.display_title())
	var description := data.description.strip_edges()
	if not description.is_empty():
		lines.append(description)
		lines.append("")
	lines.append(_footer_text())
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


func _apply_style() -> void:
	var colors: Dictionary = STATE_COLORS.get(_state, STATE_COLORS["locked"])
	var border: Color = colors["border"]
	if _hovering:
		border = border.lightened(0.25)
	var style := StyleBoxFlat.new()
	style.bg_color = colors["bg"]
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.content_margin_left = 0.0
	style.content_margin_right = 0.0
	add_theme_stylebox_override("panel", style)
	_title_label.add_theme_color_override("font_color", colors["text"])
	_desc_label.add_theme_color_override("font_color", Color(colors["text"], 0.72))
	_footer_label.add_theme_color_override("font_color", Color(colors["text"], 0.55))


func _gui_input(event: InputEvent) -> void:
	if data == null:
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			pressed.emit(data.id)
			accept_event()
