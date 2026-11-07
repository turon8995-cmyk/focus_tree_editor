extends SceneTree

## 示例脚本（可当模板复制）：用代码生成一棵最小国策树并保存成 .tres。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://addons/focus_tree_editor/examples/build_example_tree.gd
##
## 也可以先运行它，再在编辑器里打开生成的 .tres 看看效果。

const OUTPUT_PATH := "res://addons/focus_tree_editor/demo/example_focus_tree.tres"


func _initialize() -> void:
	var tree := FocusTreeData.new()
	tree.tree_name = "示例国策树"

	# 国策 1：根节点，没有前置。位置就是画布像素坐标，随便摆。
	var rearmament := FocusNodeData.new()
	rearmament.id = "focus_001"
	rearmament.title = "重整军备"
	rearmament.description = "重建军队，为即将到来的战争做准备。"
	rearmament.days = 70
	rearmament.position = Vector2(160.0, 140.0)
	rearmament.effects = ["political_power += 100", "civilian_factories += 1"]

	# 国策 2：前置是国策 1
	var army_reform := FocusNodeData.new()
	army_reform.id = "focus_002"
	army_reform.title = "军队改革"
	army_reform.description = "推进军队指挥体系与装备的现代化。"
	army_reform.days = 90
	army_reform.position = Vector2(520.0, 140.0)
	army_reform.prerequisites = ["focus_001"]
	army_reform.effects = ["political_power += 50", "military_factories += 1", "stability += 5"]

	tree.nodes.append(rearmament)
	tree.nodes.append(army_reform)

	var issues := tree.validate()
	if not issues.is_empty():
		for issue in issues:
			printerr("[build_example_tree] " + issue)
		quit(1)
		return

	var output_path := _resolve_output_path()
	var dir := output_path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var err := ResourceSaver.save(tree, output_path)
	if err != OK:
		printerr("[build_example_tree] 保存失败：%s" % error_string(err))
		quit(1)
		return
	print("[build_example_tree] 已保存 %d 个国策到 %s" % [tree.nodes.size(), output_path])
	quit()


## 允许命令行覆盖输出路径：-- <path>
func _resolve_output_path() -> String:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return OUTPUT_PATH
	return args[0]
