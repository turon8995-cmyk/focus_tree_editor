@tool
class_name FocusTreeData
extends Resource

## 一整棵国策树的数据容器。
##
## 保存成一个 .tres：每个 FocusNodeData 会作为内嵌 sub_resource 写进同一个文件，
## 便于整体拷贝、整体版本管理。编辑器只修改这里的 nodes，图形节点只是它的视图。

## 树名（编辑器标题栏 / 运行时 UI 可用）。
@export var tree_name: String = "新建国策树"
## 所有国策节点。
@export var nodes: Array[FocusNodeData] = []


## 按 id 查节点，找不到返回 null。
func get_focus(focus_id: String) -> FocusNodeData:
	if focus_id.is_empty():
		return null
	for data in nodes:
		if data != null and data.id == focus_id:
			return data
	return null


func has_focus(focus_id: String) -> bool:
	return get_focus(focus_id) != null


## 所有合法 id（去掉空 id）。
func get_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for data in nodes:
		if data != null and not data.id.is_empty():
			out.append(data.id)
	return out


## 节点在画布上的位置（自由坐标，唯一的位置来源）。
func get_position(data: FocusNodeData) -> Vector2:
	if data == null:
		return Vector2.ZERO
	return data.position


## 拓扑深度：没有（已存在的）前置为 0，否则为“最长的前置链长度”。
## 自动整理布局用它决定节点放在第几列。
func get_dependency_depth() -> Dictionary:
	var memo := {}
	for data in nodes:
		if data != null and not data.id.is_empty():
			_depth_of(data.id, memo, {})
	return memo


func _depth_of(focus_id: String, memo: Dictionary, visiting: Dictionary) -> int:
	if memo.has(focus_id):
		return int(memo[focus_id])
	if visiting.has(focus_id):
		return 0
	visiting[focus_id] = true
	var data := get_focus(focus_id)
	var depth := 0
	if data != null:
		for dependency in get_dependencies(data):
			if has_focus(dependency):
				depth = maxi(depth, _depth_of(dependency, memo, visiting) + 1)
	visiting.erase(focus_id)
	memo[focus_id] = depth
	return depth


## 一个节点的全部“依赖来源”：普通前置 + 任一前置组里的成员。
## 依赖环、自动整理的列深都按这张图算（任一前置组内部的环同样会死锁）。
func get_dependencies(data: FocusNodeData) -> PackedStringArray:
	var deps := PackedStringArray()
	if data == null:
		return deps
	for prereq in data.prerequisites:
		if not deps.has(prereq):
			deps.append(prereq)
	for group in data.get_any_groups():
		for member in group:
			if not deps.has(member):
				deps.append(member)
	return deps


## 找出依赖环（前置关系成环），返回环上的 id 序列；空数组表示无环。
func find_cycle() -> Array[String]:
	var state := {}
	var result: Array[String] = []
	for data in nodes:
		if data == null or data.id.is_empty():
			continue
		state[data.id] = 0
	for data in nodes:
		if data == null or data.id.is_empty():
			continue
		if int(state.get(data.id, 0)) == 0:
			var stack: Array[String] = []
			if _visit_for_cycle(data.id, state, stack, result):
				return result
	return result


func _visit_for_cycle(focus_id: String, state: Dictionary, stack: Array[String], result: Array[String]) -> bool:
	state[focus_id] = 1
	stack.append(focus_id)
	var data := get_focus(focus_id)
	if data != null:
		for p in get_dependencies(data):
			if not has_focus(p):
				continue
			var st := int(state.get(p, 0))
			if st == 1:
				var start := stack.find(p)
				result.clear()
				var from_index := start if start >= 0 else 0
				for i in range(from_index, stack.size()):
					result.append(stack[i])
				result.append(p)
				return true
			elif st == 0:
				if _visit_for_cycle(p, state, stack, result):
					return true
	stack.pop_back()
	state[focus_id] = 2
	return false


## 数据层自检，返回人类可读的问题列表（英文，直接显示在编辑器报告里）。
func validate() -> Array[String]:
	var issues: Array[String] = []
	if nodes.is_empty():
		issues.append("国策树是空的：至少添加一个国策。")
		return issues

	var seen := {}
	for data in nodes:
		if data == null:
			issues.append("节点列表里有一个空（null）条目。")
			continue
		if data.id.is_empty():
			issues.append("有国策的 id 为空。")
		elif not FocusNodeData.is_valid_id(data.id):
			issues.append("国策 id「%s」包含非法字符（只能使用 A-Z、a-z、0-9、_）。" % data.id)
		if seen.has(data.id):
			issues.append("重复的国策 id「%s」。" % data.id)
		seen[data.id] = true
		if data.title.strip_edges().is_empty():
			issues.append("国策「%s」没有名称。" % data.id)

	for data in nodes:
		if data == null:
			continue
		for p in data.prerequisites:
			if p == data.id:
				issues.append("国策「%s」把自己列为前置。" % data.id)
			elif not has_focus(p):
				issues.append("国策「%s」引用了不存在的前置「%s」。" % [data.id, p])
		for m in data.mutually_exclusive:
			if m == data.id:
				issues.append("国策「%s」和自己互斥。" % data.id)
			elif not has_focus(m):
				issues.append("国策「%s」引用了不存在的互斥国策「%s」。" % [data.id, m])
		for group in data.get_any_groups():
			if group.size() == 1:
				issues.append("国策「%s」的「任一前置」组只有一个成员「%s」，等同于普通前置。" % [data.id, group[0]])
			for member in group:
				if member == data.id:
					issues.append("国策「%s」把自己放进了「任一前置」组。" % data.id)
				elif not has_focus(member):
					issues.append("国策「%s」的「任一前置」组里有不存在的国策「%s」。" % [data.id, member])

	var cycle := find_cycle()
	if not cycle.is_empty():
		issues.append("检测到依赖环：" + " -> ".join(cycle))
	return issues
