@tool
class_name FocusNodeData
extends Resource

## 单个国策节点（Focus）的数据模型。
##
## 只负责存数据，不引用任何 UI；编辑器面板与游戏运行时读的是同一份数据。
## 字段参照《钢铁雄心 4》国策树 focus 块里的常见条目，并额外保留画布位置信息。
## 注意：id 同时会被用作 GraphNode 的节点名，必须是合法的、唯一的名字。

const ID_PATTERN := "^[A-Za-z0-9_]+$"
static var _id_regex: RegEx = RegEx.create_from_string(ID_PATTERN)

@export_group("基础信息")
## 唯一标识，例如 "focus_001"。只允许字母、数字、下划线。
@export var id: String = ""
## 国策名（GraphNode 标题栏显示的文字）。
@export var title: String = ""
## 国策说明，用于节点 tooltip 与运行时 UI。
@export_multiline var description: String = ""
## 国策图标。
@export var icon: Texture2D = null

@export_group("进度")
## 完成所需天数。
@export var days: int = 70
## 额外的政治点数成本（HOI4 的 cost 字段，0 表示无额外成本）。
@export var cost: int = 0

@export_group("前置关系")
## 前置国策 id 列表（全部完成才可解锁，对应 HOI4 的 prerequisite 交集语义）。
@export var prerequisites: Array[String] = []
## 互斥国策：其中任意一个已研究 / 正在研究，本节点就不可解锁（画布上是红色实线）。
@export var mutually_exclusive: Array[String] = []
## 「任一前置」组：每个元素是一组，组内用逗号分隔的国策 id。
## 语义：组内任意一个完成即可满足这一组；组与组之间、以及与 prerequisites 之间是「与」。
## 例：["focus_001, focus_002", "focus_003"] 表示 (focus_001 或 focus_002) 且 focus_003。
## 画布上是红色虚线（带箭头，指向本节点）。
@export var prerequisite_any_groups: Array[String] = []
## 额外的解锁条件表达式，例如 "has_completed_focus:focus_001"、"stability>=60"。
## 由 FocusTreeManager.evaluate_condition 解析，见运行时代码注释。
@export var available_if: Array[String] = []
## 分支显示条件：任意一条不满足，运行时 UI 里整条分支会被隐藏（HOI4 的 allow_branch）。
@export var allow_branch: Array[String] = []

@export_group("完成效果")
## 完成效果，每行一条。支持变量加减（"political_power += 100"）、
## 标记（"set_flag:rearmed"）、直接完成别的国策（"complete_focus:focus_003"）。
@export var effects: Array[String] = []

@export_group("布局")
## 画布上的像素位置（自由拖拽，唯一的位置来源）。
@export var position: Vector2 = Vector2.ZERO

@export_group("自定义")
## 自定义字段的值（key -> 值）。
## 字段的 key / 类型 / 显示名由项目根目录的 focus_tree_custom_fields.json 定义，
## 运行时代码直接读：data.custom.get("faction", "")。
@export var custom: Dictionary = {}


## id 是否合法（非空、只含字母数字下划线）。
static func is_valid_id(value: String) -> bool:
	if value.is_empty():
		return false
	return _id_regex.search(value) != null


## 把任意字符串清洗成合法 id；无法清洗时返回空字符串。
static func sanitize_id(raw: String) -> String:
	var out := ""
	for ch in raw.strip_edges():
		var is_lower := ch >= "a" and ch <= "z"
		var is_upper := ch >= "A" and ch <= "Z"
		var is_digit := ch >= "0" and ch <= "9"
		if is_lower or is_upper or is_digit or ch == "_":
			out += ch
		else:
			out += "_"
	if out.is_empty():
		return ""
	# 以数字开头虽然可以做 Node 名，但条件表达式里容易歧义，统一补前缀
	if out[0] >= "0" and out[0] <= "9":
		out = "f_" + out
	return out


## 用于显示的标题：title 为空时退回 id。
func display_title() -> String:
	var shown := title.strip_edges()
	if not shown.is_empty():
		return shown
	return id


## 复制一份数据（不复制 icon 以外的资源，icon 共享引用即可）。
func duplicate_data() -> FocusNodeData:
	var copy := FocusNodeData.new()
	copy.id = id
	copy.title = title
	copy.description = description
	copy.icon = icon
	copy.days = days
	copy.cost = cost
	copy.prerequisites = prerequisites.duplicate()
	copy.mutually_exclusive = mutually_exclusive.duplicate()
	copy.prerequisite_any_groups = prerequisite_any_groups.duplicate()
	copy.available_if = available_if.duplicate()
	copy.allow_branch = allow_branch.duplicate()
	copy.effects = effects.duplicate()
	copy.position = position
	copy.custom = custom.duplicate(true)
	return copy


## 把 prerequisite_any_groups 解析成 [[id, id], [id], ...]（去空行、去重、保序）。
func get_any_groups() -> Array[PackedStringArray]:
	var groups: Array[PackedStringArray] = []
	for line in prerequisite_any_groups:
		var group := PackedStringArray()
		for token in line.split(","):
			var member := token.strip_edges()
			if member.is_empty() or group.has(member):
				continue
			group.append(member)
		if not group.is_empty():
			groups.append(group)
	return groups


## 删除对某个国策的全部引用（删除节点时调用）。
## 返回是否发生过修改。
func remove_reference_to(target_id: String) -> bool:
	if target_id.is_empty():
		return false
	var changed := false
	changed = _erase_all(prerequisites, target_id) or changed
	changed = _erase_all(mutually_exclusive, target_id) or changed
	changed = _erase_group_member(target_id) or changed
	changed = _erase_all_contains(available_if, target_id) or changed
	changed = _erase_all_contains(allow_branch, target_id) or changed
	return changed


## 国策 id 改名后，同步更新所有引用它的地方（前置 / 互斥 / 任一前置 / 条件表达式）。
func replace_id_references(old_id: String, new_id: String) -> bool:
	if old_id.is_empty() or new_id.is_empty() or old_id == new_id:
		return false
	var changed := false
	for i in prerequisites.size():
		if prerequisites[i] == old_id:
			prerequisites[i] = new_id
			changed = true
	for i in mutually_exclusive.size():
		if mutually_exclusive[i] == old_id:
			mutually_exclusive[i] = new_id
			changed = true
	for i in prerequisite_any_groups.size():
		var line := prerequisite_any_groups[i]
		if not line.contains(old_id):
			continue
		var rebuilt := PackedStringArray()
		for token in line.split(","):
			var member := token.strip_edges()
			if member.is_empty():
				continue
			if member == old_id:
				member = new_id
			if not rebuilt.has(member):
				rebuilt.append(member)
		prerequisite_any_groups[i] = ", ".join(rebuilt)
		changed = true
	changed = _replace_in_conditions(available_if, old_id, new_id) or changed
	changed = _replace_in_conditions(allow_branch, old_id, new_id) or changed
	return changed


## 兼容旧存档：旧版把「列/行/相对定位」存在节点里，现在改成自由坐标，
## 这些属性直接吞掉，避免加载旧 .tres 时报 “property not found”。
func _set(property: StringName, _value: Variant) -> bool:
	if property == &"grid_column" or property == &"grid_row" or property == &"relative_position_id":
		return true
	return false


func _erase_all(list: Array[String], value: String) -> bool:
	var changed := false
	var idx := list.find(value)
	while idx != -1:
		list.remove_at(idx)
		changed = true
		idx = list.find(value)
	return changed


## 从「任一前置」组里删掉某个国策，空掉的组整行移除。
func _erase_group_member(target_id: String) -> bool:
	var changed := false
	var rebuilt_lines: Array[String] = []
	for line in prerequisite_any_groups:
		var kept := PackedStringArray()
		for token in line.split(","):
			var member := token.strip_edges()
			if member.is_empty():
				continue
			if member == target_id:
				changed = true
				continue
			if not kept.has(member):
				kept.append(member)
		if not kept.is_empty():
			rebuilt_lines.append(", ".join(kept))
		elif not line.strip_edges().is_empty():
			changed = true
	if changed:
		prerequisite_any_groups = rebuilt_lines
	return changed


## 条件表达式里也可能引用 id（"has_completed_focus:xxx"），按整词删除。
func _erase_all_contains(list: Array[String], value: String) -> bool:
	var pattern := RegEx.create_from_string("\\b" + value + "\\b")
	var changed := false
	for i in range(list.size() - 1, -1, -1):
		if pattern.search(list[i]) != null:
			list.remove_at(i)
			changed = true
	return changed


func _replace_in_conditions(list: Array[String], old_id: String, new_id: String) -> bool:
	var pattern := RegEx.create_from_string("\\b" + old_id + "\\b")
	var changed := false
	for i in list.size():
		if pattern.search(list[i]) != null:
			list[i] = pattern.sub(list[i], new_id, true)
			changed = true
	return changed
