extends Control

## 示例：把「管理器 + 一个 FocusTreeView 节点」接起来。
##
## 迁移到自己的项目时，最小只需要：
##   1. 场景里放一个 FocusTreeManager（设好 tree_path）；
##   2. 实例化 focus_tree_view.tscn；
##   3. 代码里 view.open() / view.close()。
##
## 这里额外演示了往标题栏塞 HUD（变量 / 时间流速），以及关掉后重新打开。

@onready var manager: FocusTreeManager = $FocusTreeManager
@onready var view: FocusTreeView = $FocusTreeView
@onready var open_button: Button = $OpenButton

const TREE_PATH := "res://addons/focus_tree_editor/demo/example_focus_tree.tres"
## HUD 上展示的变量（顺序即显示顺序）。
const HUD_VARIABLES := ["political_power", "stability", "war_support", "civilian_factories", "military_factories"]
## 按顺序尝试的系统字体；最后用通用族名兜底。
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

var _stats_label: Label
var _speed_label: Label
var _speed_slider: HSlider


func _ready() -> void:
	_apply_cjk_theme()

	if manager.tree == null:
		manager.load_tree(TREE_PATH)

	_build_header_controls()
	open_button.pressed.connect(_on_open_pressed)
	manager.variable_changed.connect(_on_variable_changed)
	manager.focus_completed.connect(_on_focus_completed)
	view.visibility_changed.connect(_on_view_visibility_changed)
	_on_view_visibility_changed()

	_update_stats()
	_update_speed_label()


## 面板开着的时候把「打开」按钮藏起来，避免透过半透明面板看到。
func _on_view_visibility_changed() -> void:
	open_button.visible = not view.visible


## 挂一个带中文回退的系统字体主题（继承给所有子节点，包括运行时卡片）。
func _apply_cjk_theme() -> void:
	var system_font := SystemFont.new()
	system_font.font_names = PackedStringArray(CJK_FONT_NAMES)
	system_font.allow_system_fallback = true
	var ui_theme := Theme.new()
	ui_theme.default_font = system_font
	theme = ui_theme


func _build_header_controls() -> void:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 12)

	_stats_label = Label.new()
	_stats_label.add_theme_font_size_override("font_size", 12)
	_stats_label.add_theme_color_override("font_color", Color(0.78, 0.80, 0.86))
	box.add_child(_stats_label)

	_speed_label = Label.new()
	_speed_label.add_theme_font_size_override("font_size", 12)
	_speed_label.add_theme_color_override("font_color", Color(0.62, 0.64, 0.70))
	box.add_child(_speed_label)

	_speed_slider = HSlider.new()
	_speed_slider.min_value = 0.05
	_speed_slider.max_value = 2.0
	_speed_slider.step = 0.05
	_speed_slider.value = clampf(manager.seconds_per_day, 0.05, 2.0)
	_speed_slider.custom_minimum_size = Vector2(120.0, 0.0)
	_speed_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_speed_slider.value_changed.connect(_on_speed_changed)
	box.add_child(_speed_slider)

	view.add_header_control(box)


func _update_stats() -> void:
	if _stats_label == null:
		return
	var parts: PackedStringArray = []
	for variable_key in HUD_VARIABLES:
		var label: String = manager.variable_labels.get(variable_key, variable_key)
		parts.append("%s %d" % [label, manager.get_variable(variable_key)])
	_stats_label.text = "  ·  ".join(parts)


func _update_speed_label() -> void:
	if _speed_label == null:
		return
	_speed_label.text = "1 天 = %.2f 秒" % manager.seconds_per_day


func _on_speed_changed(value: float) -> void:
	manager.seconds_per_day = value
	_update_speed_label()


func _on_variable_changed(_variable_key: String, _value: int) -> void:
	_update_stats()


func _on_focus_completed(_focus_id: String) -> void:
	_update_stats()


func _on_open_pressed() -> void:
	view.open()
