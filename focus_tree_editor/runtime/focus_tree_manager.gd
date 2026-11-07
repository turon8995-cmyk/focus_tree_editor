class_name FocusTreeManager
extends Node

## 国策树运行时管理器：解锁判定 + 研究进度 + 完成效果 + 状态存读。
##
## 最小用法：
##   var manager := FocusTreeManager.new()
##   add_child(manager)
##   manager.load_tree("res://addons/focus_tree_editor/demo/example_focus_tree.tres")
##   manager.start_focus("focus_001")          # 之后 _process 自动按秒推进
##
## 时间：默认 1 秒 = 1 天（seconds_per_day = 1.0）。游戏里有自己的时钟时，
## 关掉 auto_advance，每过一天调用一次 advance_days(1.0)。
##
## 条件表达式（available_if / allow_branch，每行一条）：
##   always / true               永远满足
##   never / false               永远不满足
##   has_completed_focus:<id>    该国策已完成
##   has_focus:<id>              已完成或正在研究
##   not_completed_focus:<id>    尚未完成
##   has_flag:<name>             已通过效果设置过该标记
##   stability>=60               变量比较（>= <= == > <，变量见 variables）
##   is_at_war                   处于战争状态
##   tag==GER                    国家 tag 匹配
##
## 完成效果（effects，每行一条）：
##   political_power += 100      变量加减
##   political_power -= 50
##   stability = 80              直接赋值
##   set_flag:rearmed            设置标记
##   clear_flag:rearmed          清除标记
##   complete_focus:focus_003    直接完成另一个国策（有递归保护）
## 想完全自定义：设 effect_resolver，或监听 focus_effect_triggered 信号。
##
## 变量表：默认读插件自带的变量表 JSON（variables.json），也可以用 variables_path
## 指向项目自己的文件；文件缺失/损坏时退回内置默认值，保证“装上就能用”。

signal focus_unlocked(focus_id: String)
signal focus_started(focus_id: String)
signal focus_progress(focus_id: String, progress: float)
signal focus_completed(focus_id: String)
## 每执行一条“完成效果”都会发一次（无论内置语法还是自定义解析器处理）。
signal focus_effect_triggered(focus_id: String, effect: String)
## 变量变化（做 HUD 时很方便）。
signal variable_changed(variable_key: String, value: int)

## 插件自带的变量表路径（搬家/改名后可以自己改 variables_path）。
const DEFAULT_VARIABLES_PATH := "res://addons/focus_tree_editor/variables.json"
## 变量表读不到时的兜底，保证没有 JSON 也能跑。
const FALLBACK_VARIABLES := {
	"political_power": {"default": 0, "label": "政治点"},
	"stability": {"default": 50, "label": "稳定度"},
	"war_support": {"default": 50, "label": "战争支持度"},
	"civilian_factories": {"default": 0, "label": "民用工厂"},
	"military_factories": {"default": 0, "label": "军用工厂"},
	"manpower": {"default": 0, "label": "人力"},
}

## 直接引用一棵树（优先于 tree_path）。
@export var tree: FocusTreeData = null
## 树资源路径；树为空时在 _ready 里按这个路径加载。
@export var tree_path: String = ""

@export_group("时间")
## 是否由 _process 自己推进研究进度（游戏有自己的时间轴时关掉它）。
@export var auto_advance: bool = true
## 现实里多少秒 = 游戏内一天。默认 1 秒 1 天，70 天的国策需要 70 秒。
@export var seconds_per_day: float = 1.0
## 暂停研究（不暂停已完成的国策）。
@export var paused: bool = false
## 是否限制同时只能研究一个国策（HOI4 默认是）。
@export var one_focus_at_a_time: bool = true

@export_group("世界状态")
## 国家 tag，供 "tag==GER" 条件使用。
@export var country_tag: String = ""
## 是否处于战争，供 "is_at_war" 条件使用。
@export var at_war: bool = false

## 自定义条件解析器：func(expression: String) -> bool，优先于内置解析。
var condition_resolver: Callable = Callable()
## 自定义效果解析器：func(effect: String, focus_id: String)，优先于内置语法。
var effect_resolver: Callable = Callable()

## 变量表 JSON 的路径（默认用插件自带的那份；项目里想改就指向自己的文件）。
@export_file("*.json") var variables_path: String = DEFAULT_VARIABLES_PATH

## 全局变量（当前值）。效果里的 "政治点 / 工厂 / 稳定度" 都在这里读写，游戏直接读它。
var variables: Dictionary = {}
## 变量默认值（来自 JSON，reset_variables() 用它恢复）。
var variable_defaults: Dictionary = {}
## 变量显示名（来自 JSON 的 label，给 HUD / 调试用）。
var variable_labels: Dictionary = {}
## 效果设置的标记（"set_flag:xxx"）。
var flags: Dictionary = {}

## id -> { "completed": bool, "days": float }
var _states: Dictionary = {}
## 已经广播过 focus_unlocked 的 id，避免重复发信号。
var _known_available: Dictionary = {}
var _active_id := ""
var _effect_depth := 0


func _ready() -> void:
	load_variable_definitions()
	if tree == null and not tree_path.is_empty():
		load_tree(tree_path)
	if tree != null:
		initialize()


func _process(delta: float) -> void:
	if paused or not auto_advance:
		return
	if seconds_per_day <= 0.0:
		return
	advance_days(delta / seconds_per_day)


# ---------------------------------------------------------------------------
# 时间推进
# ---------------------------------------------------------------------------

## 推进若干“游戏日”。游戏自带时钟时每帧/每天调用它即可。
func advance_days(days: float) -> void:
	if _active_id.is_empty() or days <= 0.0:
		return
	var data := get_focus(_active_id)
	if data == null:
		_active_id = ""
		return
	var state: Dictionary = _states.get(_active_id, {})
	state["days"] = float(state.get("days", 0.0)) + days
	_states[_active_id] = state

	var required := float(maxi(data.days, 1))
	var ratio := clampf(float(state["days"]) / required, 0.0, 1.0)
	focus_progress.emit(_active_id, ratio)
	if ratio >= 1.0:
		complete_focus(_active_id)


# ---------------------------------------------------------------------------
# 树的加载
# ---------------------------------------------------------------------------

## 按路径加载；失败时保留原来的树并 push_error。
func load_tree(path: String) -> bool:
	if path.is_empty():
		return false
	var res: Resource = ResourceLoader.load(path)
	if res == null:
		push_error("[FocusTreeManager] 加载国策树失败：%s。" % path)
		return false
	if not (res is FocusTreeData):
		push_error("[FocusTreeManager] %s 不是 FocusTreeData 资源。" % path)
		return false
	tree_path = path
	tree = res as FocusTreeData
	initialize()
	return true


## 直接指定一份树数据。
func set_tree(data: FocusTreeData) -> void:
	tree = data
	initialize()


## 重置所有进度（不动变量与标记），并广播一次初始可解锁状态。
func initialize() -> void:
	_states.clear()
	_known_available.clear()
	_active_id = ""
	if tree == null:
		return
	for data in tree.nodes:
		if data == null or data.id.is_empty():
			continue
		_states[data.id] = {"completed": false, "days": 0.0}
	_check_unlocks()


func get_focus(focus_id: String) -> FocusNodeData:
	if tree == null:
		return null
	return tree.get_focus(focus_id)


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

func is_completed(focus_id: String) -> bool:
	var state: Dictionary = _states.get(focus_id, {})
	return bool(state.get("completed", false))


func is_in_progress(focus_id: String) -> bool:
	return not _active_id.is_empty() and _active_id == focus_id


func get_active_focus() -> String:
	return _active_id


func get_progress(focus_id: String) -> float:
	if is_completed(focus_id):
		return 1.0
	if not is_in_progress(focus_id):
		return 0.0
	var data := get_focus(focus_id)
	if data == null:
		return 0.0
	var state: Dictionary = _states.get(focus_id, {})
	return clampf(float(state.get("days", 0.0)) / float(maxi(data.days, 1)), 0.0, 1.0)


## allow_branch 是否满足（决定运行时 UI 里这条分支是否可见）。
func is_visible(focus_id: String) -> bool:
	var data := get_focus(focus_id)
	if data == null:
		return false
	return _conditions_met(data.allow_branch)


## 前置条件是否满足（不考虑是否已完成 / 是否正在研究）。
func is_available(focus_id: String) -> bool:
	var data := get_focus(focus_id)
	if data == null:
		return false
	if is_completed(focus_id):
		return false
	if not is_visible(focus_id):
		return false
	for prereq in data.prerequisites:
		if not is_completed(prereq):
			return false
	# 「任一前置」组：每组至少有一个成员已完成；组与组之间是「与」
	for group in data.get_any_groups():
		var met := false
		for member in group:
			if is_completed(member):
				met = true
				break
		if not met:
			return false
	for other in data.mutually_exclusive:
		if is_completed(other) or is_in_progress(other):
			return false
	if not _conditions_met(data.available_if):
		return false
	return true


## 现在能不能开始研究。
func can_start(focus_id: String) -> bool:
	if not is_available(focus_id):
		return false
	if is_in_progress(focus_id):
		return false
	if one_focus_at_a_time and not _active_id.is_empty():
		return false
	return true


## 给 UI 用的粗粒度状态："completed" / "in_progress" / "available" / "locked" / "hidden"。
func get_focus_state(focus_id: String) -> String:
	if get_focus(focus_id) == null:
		return "hidden"
	if is_completed(focus_id):
		return "completed"
	if is_in_progress(focus_id):
		return "in_progress"
	if not is_visible(focus_id):
		return "hidden"
	return "available" if is_available(focus_id) else "locked"


func get_available_ids() -> PackedStringArray:
	var out := PackedStringArray()
	if tree == null:
		return out
	for data in tree.nodes:
		if data != null and can_start(data.id):
			out.append(data.id)
	return out


# ---------------------------------------------------------------------------
# 研究流程
# ---------------------------------------------------------------------------

## 开始研究；成功返回 true。
func start_focus(focus_id: String) -> bool:
	if not can_start(focus_id):
		push_warning("[FocusTreeManager] 国策 %s 现在还不能开始研究。" % focus_id)
		return false
	_active_id = focus_id
	_states[focus_id] = {"completed": false, "days": 0.0}
	focus_started.emit(focus_id)
	focus_progress.emit(focus_id, 0.0)
	return true


## 取消当前研究（进度清零）。
func cancel_focus() -> void:
	if _active_id.is_empty():
		return
	var cancelled := _active_id
	_active_id = ""
	_states[cancelled] = {"completed": false, "days": 0.0}
	focus_progress.emit(cancelled, 0.0)


## 立刻完成一个国策（含调试用）。
func complete_focus(focus_id: String) -> void:
	var data := get_focus(focus_id)
	if data == null or is_completed(focus_id):
		return
	_states[focus_id] = {"completed": true, "days": float(maxi(data.days, 1))}
	if _active_id == focus_id:
		_active_id = ""
	focus_completed.emit(focus_id)
	_apply_effects(data)
	_check_unlocks()


# ---------------------------------------------------------------------------
# 变量表（JSON） / 变量 / 标记
# ---------------------------------------------------------------------------

## 读取变量表 JSON。path 为空时用 variables_path；读不到就退回内置默认值。
## JSON 两种写法都支持：
##   { "political_power": { "default": 0, "label": "政治点" } }
##   { "political_power": 0 }
func load_variable_definitions(path: String = "") -> bool:
	var candidates := PackedStringArray()
	if not path.is_empty():
		candidates.append(path)
	if not variables_path.is_empty():
		candidates.append(variables_path)
	if not candidates.has(DEFAULT_VARIABLES_PATH):
		candidates.append(DEFAULT_VARIABLES_PATH)

	for candidate in candidates:
		if not FileAccess.file_exists(candidate):
			continue
		var text := FileAccess.get_file_as_string(candidate)
		if text.strip_edges().is_empty():
			continue
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			variables_path = candidate
			_apply_variable_definitions(parsed)
			return true

	push_warning("[FocusTreeManager] 变量表 JSON 读取失败（%s），使用内置默认变量。" % variables_path)
	_apply_variable_definitions(FALLBACK_VARIABLES)
	return false


func _apply_variable_definitions(definition: Dictionary) -> void:
	variables.clear()
	variable_defaults.clear()
	variable_labels.clear()
	for raw_key in definition.keys():
		var variable_key := String(raw_key)
		# 以下划线开头的键当注释用（例如 "_说明"）
		if variable_key.begins_with("_"):
			continue
		var entry: Variant = definition[raw_key]
		var default_value := 0
		var label := variable_key
		if entry is Dictionary:
			default_value = int(entry.get("default", 0))
			label = String(entry.get("label", variable_key))
		elif entry is int or entry is float:
			default_value = int(entry)
		variable_defaults[variable_key] = default_value
		variable_labels[variable_key] = label
		variables[variable_key] = default_value


## 把所有变量恢复成 JSON 里的默认值（新开一局时用）。
func reset_variables() -> void:
	for variable_key in variable_defaults.keys():
		variables[variable_key] = variable_defaults[variable_key]
		variable_changed.emit(String(variable_key), int(variables[variable_key]))


## 运行时补一个变量（不会写回 JSON；想在编辑器里维护就加进 variables.json）。
func add_variable(variable_key: String, default_value: int = 0, display_name: String = "") -> void:
	if variable_key.is_empty():
		return
	if not variable_defaults.has(variable_key):
		variable_defaults[variable_key] = default_value
	if not variables.has(variable_key):
		variables[variable_key] = default_value
	if not display_name.is_empty():
		variable_labels[variable_key] = display_name
	elif not variable_labels.has(variable_key):
		variable_labels[variable_key] = variable_key


func get_variable(variable_key: String) -> int:
	return int(variables.get(variable_key, 0))


func set_variable(variable_key: String, value: int) -> void:
	variables[variable_key] = value
	variable_changed.emit(variable_key, value)


func get_flag(flag_name: String) -> bool:
	return bool(flags.get(flag_name, false))


# ---------------------------------------------------------------------------
# 完成效果
# ---------------------------------------------------------------------------

## 逐条执行该节点的 effects。顺序：effect_resolver → 内置语法；每条都会发信号。
func _apply_effects(data: FocusNodeData) -> void:
	for raw_effect in data.effects:
		var effect := raw_effect.strip_edges()
		if effect.is_empty():
			continue
		if effect_resolver.is_valid():
			effect_resolver.call(effect, data.id)
		else:
			_apply_builtin_effect(effect, data.id)
		focus_effect_triggered.emit(data.id, effect)


## 内置效果语法，见文件头的说明。返回是否被识别。
func _apply_builtin_effect(effect: String, focus_id: String) -> bool:
	var compact := effect.replace(" ", "")
	if compact.begins_with("set_flag:"):
		flags[compact.substr("set_flag:".length()).strip_edges()] = true
		return true
	if compact.begins_with("clear_flag:"):
		flags.erase(compact.substr("clear_flag:".length()).strip_edges())
		return true
	if compact.begins_with("complete_focus:"):
		var target := compact.substr("complete_focus:".length())
		if target.is_empty() or target == focus_id:
			return false
		if _effect_depth >= 8:
			push_warning("[FocusTreeManager] complete_focus 嵌套过深，已忽略：%s。" % effect)
			return true
		_effect_depth += 1
		complete_focus(target)
		_effect_depth -= 1
		return true

	for op in ["+=", "-=", "="]:
		var index := compact.find(op)
		if index <= 0:
			continue
		var variable_key := compact.substr(0, index)
		var value_text := compact.substr(index + op.length())
		if not value_text.is_valid_int():
			return false
		if variable_key == "pp":
			variable_key = "political_power"
		if not variables.has(variable_key):
			variables[variable_key] = 0
		var amount := int(value_text)
		match op:
			"+=":
				set_variable(variable_key, get_variable(variable_key) + amount)
			"-=":
				set_variable(variable_key, get_variable(variable_key) - amount)
			_:
				set_variable(variable_key, amount)
		return true

	push_warning("[FocusTreeManager] 无法识别的完成效果「%s」（可用 effect_resolver 自定义）。" % effect)
	return false


# ---------------------------------------------------------------------------
# 条件表达式
# ---------------------------------------------------------------------------

## 解析一条条件表达式；未知表达式返回 false 并 warning（方便发现拼写错误）。
func evaluate_condition(expression: String) -> bool:
	if condition_resolver.is_valid():
		return bool(condition_resolver.call(expression))

	var expr := expression.strip_edges()
	if expr.is_empty() or expr == "always" or expr == "true":
		return true
	if expr == "never" or expr == "false":
		return false
	if expr.begins_with("has_completed_focus:"):
		return is_completed(expr.get_slice(":", 1).strip_edges())
	if expr.begins_with("not_completed_focus:"):
		return not is_completed(expr.get_slice(":", 1).strip_edges())
	if expr.begins_with("has_focus:"):
		var focus_id := expr.get_slice(":", 1).strip_edges()
		return is_completed(focus_id) or is_in_progress(focus_id)
	if expr.begins_with("has_flag:"):
		return get_flag(expr.get_slice(":", 1).strip_edges())
	if expr.begins_with("is_at_war"):
		return at_war
	if expr.begins_with("tag=="):
		return country_tag.to_lower() == expr.get_slice("==", 1).strip_edges().to_lower()

	# 变量比较：stability>=60 / pp<100 ...
	for op in [">=", "<=", "==", ">", "<"]:
		var index := expr.find(op)
		if index <= 0:
			continue
		var variable_key := expr.substr(0, index).strip_edges()
		var value_text := expr.substr(index + op.length()).strip_edges()
		if not value_text.is_valid_int():
			return false
		if variable_key == "pp":
			variable_key = "political_power"
		if not variables.has(variable_key):
			push_warning("[FocusTreeManager] 条件里的变量「%s」没有注册。" % variable_key)
			return false
		var current := get_variable(variable_key)
		var target := int(value_text)
		match op:
			">=":
				return current >= target
			"<=":
				return current <= target
			"==":
				return current == target
			">":
				return current > target
			_:
				return current < target

	push_warning("[FocusTreeManager] 未知的条件表达式「%s」（按 false 处理）。" % expression)
	return false


func _conditions_met(conditions: Array[String]) -> bool:
	for expression in conditions:
		if not evaluate_condition(expression):
			return false
	return true


func _check_unlocks() -> void:
	if tree == null:
		return
	for data in tree.nodes:
		if data == null or data.id.is_empty():
			continue
		if is_completed(data.id):
			continue
		if can_start(data.id) and not _known_available.has(data.id):
			_known_available[data.id] = true
			focus_unlocked.emit(data.id)


# ---------------------------------------------------------------------------
# 状态存读（进度 + 变量 + 标记）
# ---------------------------------------------------------------------------

## 导出可 JSON 化的存档数据。
func get_state() -> Dictionary:
	var completed := PackedStringArray()
	var days := {}
	for focus_id in _states.keys():
		var state: Dictionary = _states[focus_id]
		if bool(state.get("completed", false)):
			completed.append(focus_id)
		days[focus_id] = float(state.get("days", 0.0))
	return {
		"tree_path": tree_path,
		"active": _active_id,
		"completed": completed,
		"days": days,
		"variables": variables.duplicate(),
		"flags": flags.duplicate(),
	}


## 从 get_state() 的结果恢复。树必须先加载好。
func load_state(state: Dictionary) -> bool:
	if tree == null:
		push_error("[FocusTreeManager] 还没加载国策树，不能恢复状态。")
		return false
	_states.clear()
	for data in tree.nodes:
		if data == null or data.id.is_empty():
			continue
		_states[data.id] = {"completed": false, "days": 0.0}

	for focus_id in state.get("completed", []):
		if _states.has(focus_id):
			_states[focus_id]["completed"] = true

	var days: Dictionary = state.get("days", {})
	for focus_id in days.keys():
		if _states.has(focus_id):
			_states[focus_id]["days"] = float(days[focus_id])

	var saved_variables: Dictionary = state.get("variables", {})
	for variable_key in saved_variables.keys():
		variables[variable_key] = int(saved_variables[variable_key])

	var saved_flags: Dictionary = state.get("flags", {})
	flags.clear()
	for flag_name in saved_flags.keys():
		flags[flag_name] = bool(saved_flags[flag_name])

	_active_id = String(state.get("active", ""))
	if not _active_id.is_empty() and not _states.has(_active_id):
		_active_id = ""
	if not _active_id.is_empty():
		_states[_active_id]["completed"] = false

	_known_available.clear()
	_check_unlocks()
	return true
