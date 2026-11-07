@tool
class_name FocusFieldSchema
extends RefCounted

## 自定义字段的定义表（项目自己写的 JSON）。
##
## 文件默认放在项目根目录：res://focus_tree_custom_fields.json
## 格式：
## {
##   "fields": [
##     { "key": "faction",   "label": "派系",     "type": "string", "default": "" },
##     { "key": "ai_weight", "label": "AI 权重",  "type": "int",    "default": 10 },
##     { "key": "note",      "label": "备注",     "type": "text",   "default": "" },
##     { "key": "enabled",   "label": "启用",     "type": "bool",   "default": true }
##   ]
## }
##
## 值会存进 FocusNodeData.custom（一个 Dictionary），运行时代码用
## `data.custom.get("faction", "")` 读取。

const PROJECT_PATH := "res://focus_tree_custom_fields.json"
const SUPPORTED_TYPES := ["string", "text", "int", "float", "bool"]

## 读取字段定义；文件不存在或格式不对时返回空数组（编辑器里就不显示自定义字段区）。
static func load_fields(path: String = PROJECT_PATH) -> Array[Dictionary]:
	var fields: Array[Dictionary] = []
	if path.is_empty() or not FileAccess.file_exists(path):
		return fields
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_warning("[FocusFieldSchema] %s 不是合法的 JSON 对象。" % path)
		return fields
	var list: Variant = parsed.get("fields", [])
	if not (list is Array):
		push_warning("[FocusFieldSchema] %s 里缺少 fields 数组。" % path)
		return fields

	var seen := {}
	for entry in list:
		if not (entry is Dictionary):
			continue
		var key := String(entry.get("key", "")).strip_edges()
		if key.is_empty() or seen.has(key):
			continue
		var field_type := String(entry.get("type", "string")).to_lower()
		if not SUPPORTED_TYPES.has(field_type):
			field_type = "string"
		seen[key] = true
		fields.append({
			"key": key,
			"label": String(entry.get("label", key)),
			"type": field_type,
			"default": entry.get("default", default_for(field_type)),
		})
	return fields


## 给某个类型一个默认值。
static func default_for(field_type: String) -> Variant:
	match field_type:
		"int", "float":
			return 0
		"bool":
			return false
		_:
			return ""
