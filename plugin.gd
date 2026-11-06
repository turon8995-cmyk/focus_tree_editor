@tool
extends EditorPlugin

## 插件入口。
##
## Godot 4 的 EditorPlugin 没有 3.x 的 CONTAINER_MAIN_SCREEN，因此“独立主面板”用两种形式提供：
##   1. 默认注册成左侧 Dock（add_control_to_dock），随时可见；
##   2. 面板上的 “Pop Out” 按钮 / 顶部工具栏的 “Focus Tree” 按钮，把同一个面板实例搬进一个
##      约 1280x820 的大窗口，接近“主界面编辑器”的体验。
## 两处共用同一个 FocusTreeEditor 实例，所以不存在两份状态。
##
## 这里刻意用 load() + 无类型变量引用面板脚本：即使首次启用时全局 class 缓存还没扫描到
## FocusTreeEditor，本脚本也能正常解析，只是面板创建失败并打印一条明确的错误。

const EDITOR_SCRIPT_PATH := "res://addons/focus_tree_editor/focus_tree_editor.gd"

## Dock 槽位（左栏右上角，和场景树/导入面板同一列）。
const DOCK_SLOT := DOCK_SLOT_LEFT_UR
const WINDOW_TITLE := "国策树编辑器"
const WINDOW_MIN_SIZE := Vector2i(900, 560)
const WINDOW_SIZE := Vector2i(1280, 820)
const TOOL_MENU_ITEM := "国策树编辑器"

## FocusTreeEditor 实例（未标注类型，见文件头说明）。
var _editor
var _window: Window
var _toolbar_button: Button
var _in_window := false
var _tool_menu_added := false


func _enter_tree() -> void:
	var editor_script: Script = load(EDITOR_SCRIPT_PATH)
	if editor_script == null:
		push_error("[FocusTreeEditor] 无法加载 %s（编辑器可能还没扫描 addons 目录，试试重新启用插件）。" % EDITOR_SCRIPT_PATH)
		return

	_editor = editor_script.new()
	_editor.name = "FocusTreeEditor"
	_editor.popout_requested.connect(_on_popout_requested)
	_editor.status_changed.connect(_on_editor_status)
	add_control_to_dock(DOCK_SLOT, _editor)

	# 顶部工具栏按钮：在大窗口里打开同一个面板
	_toolbar_button = Button.new()
	_toolbar_button.text = "国策树"
	_toolbar_button.tooltip_text = "在大窗口中打开国策树编辑器"
	_toolbar_button.pressed.connect(_on_toolbar_pressed)
	add_control_to_container(CONTAINER_TOOLBAR, _toolbar_button)

	# 项目 -> 工具 菜单里也放一个入口，方便找回面板
	add_tool_menu_item(TOOL_MENU_ITEM, _on_toolbar_pressed)
	_tool_menu_added = true


func _exit_tree() -> void:
	if _tool_menu_added:
		remove_tool_menu_item(TOOL_MENU_ITEM)
		_tool_menu_added = false

	if _toolbar_button != null and is_instance_valid(_toolbar_button):
		remove_control_from_container(CONTAINER_TOOLBAR, _toolbar_button)
		_toolbar_button.queue_free()
		_toolbar_button = null

	# 面板若已被搬进窗口，会随窗口一起释放
	if _editor != null and is_instance_valid(_editor) and not _in_window:
		remove_control_from_docks(_editor)
		_editor.queue_free()

	if _window != null and is_instance_valid(_window):
		_window.queue_free()
	_window = null
	_editor = null
	_in_window = false


# ---------------------------------------------------------------------------
# Dock <-> 大窗口
# ---------------------------------------------------------------------------

func _on_toolbar_pressed() -> void:
	if _in_window:
		if _window != null and is_instance_valid(_window):
			_window.show()
			_window.grab_focus()
		return
	_move_to_window()


func _on_popout_requested() -> void:
	if _in_window:
		_move_to_dock()
	else:
		_move_to_window()


func _move_to_window() -> void:
	if _in_window or _editor == null or not is_instance_valid(_editor):
		return
	if _window == null:
		_create_window()
	if _editor.get_parent() != null:
		_editor.get_parent().remove_child(_editor)
	_window.add_child(_editor)
	_editor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_editor.set_in_window(true)
	_in_window = true
	_window.popup_centered()


func _move_to_dock() -> void:
	if not _in_window or _editor == null or not is_instance_valid(_editor):
		return
	if _editor.get_parent() != null:
		_editor.get_parent().remove_child(_editor)
	add_control_to_dock(DOCK_SLOT, _editor)
	_editor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_editor.set_in_window(false)
	_in_window = false
	if _window != null and is_instance_valid(_window):
		_window.hide()


func _create_window() -> void:
	_window = Window.new()
	_window.title = WINDOW_TITLE
	_window.min_size = WINDOW_MIN_SIZE
	_window.size = WINDOW_SIZE
	_window.visible = false
	_window.close_requested.connect(_on_window_close)
	# 挂到编辑器根 Control 下，Godot 会以“内嵌子窗口”的方式显示
	EditorInterface.get_base_control().add_child(_window)


func _on_window_close() -> void:
	_move_to_dock()


func _on_editor_status(message: String) -> void:
	print_verbose("[FocusTreeEditor] " + message)


## 供其它插件/脚本取到当前面板实例。
func get_editor() -> Node:
	return _editor
