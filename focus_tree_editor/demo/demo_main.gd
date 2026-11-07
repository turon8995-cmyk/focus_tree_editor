extends Control

## 运行示例的入口脚本：把「加载树 → 点击研究 → 完成效果改变量 → 进度刷新」串起来。
##
## 想接进自己的游戏时，照着本文件的 _ready 抄即可：
##   1. 创建一个 FocusTreeManager 节点（或做成 Autoload）；
##   2. load_tree() 加载 .tres；
##   3. 连信号：focus_started / focus_progress / focus_completed / variable_changed；
##   4. 用 start_focus() 开始研究，用 get_focus_state() 给 UI 上色。
##
## Godot 默认主题字体不含中文字形，所以这里挂了一个 SystemFont 主题。

@onready var manager: FocusTreeManager = $FocusTreeManager
@onready var tree_canvas: FocusTreeUI = $FocusTreeCanvas
@onready var status_label: Label = $Status
@onready var stats_label: Label = $Stats
@onready var speed_label: Label = $SpeedLabel
@onready var speed_slider: HSlider = $SpeedSlider
@onready var reset_button: Button = $ResetButton

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


func _ready() -> void:
	_apply_cjk_theme()

	if manager.tree == null:
		manager.load_tree(TREE_PATH)

	tree_canvas.manager = manager
	tree_canvas.rebuild()

	manager.focus_started.connect(_on_focus_started)
	manager.focus_completed.connect(_on_focus_completed)
	manager.focus_progress.connect(_on_focus_progress)
	manager.variable_changed.connect(_on_variable_changed)
	reset_button.pressed.connect(_on_reset_pressed)

	# 时间流速：滑块直接改 seconds_per_day（1 秒 = 多少游戏天）
	speed_slider.value = manager.seconds_per_day
	speed_slider.value_changed.connect(_on_speed_changed)
	_update_speed_label()

	status_label.text = _default_status()
	_update_stats()


## 挂一个带中文回退的系统字体主题（继承给所有子节点，包括自绘的 FocusTreeUI）。
func _apply_cjk_theme() -> void:
	var system_font := SystemFont.new()
	system_font.font_names = PackedStringArray(CJK_FONT_NAMES)
	system_font.allow_system_fallback = true
	var ui_theme := Theme.new()
	ui_theme.default_font = system_font
	theme = ui_theme


func _update_stats() -> void:
	var parts: PackedStringArray = []
	for variable_key in HUD_VARIABLES:
		var label: String = manager.variable_labels.get(variable_key, variable_key)
		parts.append("%s %d" % [label, manager.get_variable(variable_key)])
	stats_label.text = "  ·  ".join(parts)


func _update_speed_label() -> void:
	speed_label.text = "时间流速：1 天 = %.2f 秒" % manager.seconds_per_day


func _default_status() -> String:
	var available := manager.get_available_ids()
	if available.is_empty():
		return "当前没有可研究的国策，先完成手头这个。"
	var titles: Array[String] = []
	for focus_id in available:
		var data := manager.get_focus(focus_id)
		titles.append(data.title if data != null else String(focus_id))
	return "点击金色边框的国策开始研究。当前可研究：" + "、".join(titles)


func _on_focus_started(focus_id: String) -> void:
	var data := manager.get_focus(focus_id)
	if data != null:
		status_label.text = "正在研究「%s」（%d 天）…" % [data.title, data.days]


func _on_focus_progress(focus_id: String, progress: float) -> void:
	var data := manager.get_focus(focus_id)
	if data == null:
		return
	status_label.text = "正在研究「%s」：%d%%" % [data.title, int(round(progress * 100.0))]


func _on_focus_completed(focus_id: String) -> void:
	var data := manager.get_focus(focus_id)
	var title := focus_id
	if data != null:
		title = data.title
	_update_stats()
	tree_canvas.queue_redraw()
	status_label.text = "已完成「%s」。%s" % [title, _default_status()]


func _on_variable_changed(_variable_key: String, _value: int) -> void:
	_update_stats()


func _on_speed_changed(value: float) -> void:
	manager.seconds_per_day = value
	_update_speed_label()


func _on_reset_pressed() -> void:
	manager.initialize()
	tree_canvas.rebuild()
	status_label.text = "进度已重置。" + _default_status()
