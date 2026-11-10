@tool
extends BaseSceneTool

# 一次提交多步编辑。每条 op 走与单步工具完全相同的实现与校验，所以不会出现"批量版和单步版行为不同"。
#
# 回退语义（明确写在这里，因为做不到"零成本原子"）：
# - 每条成功执行的 op = 一个独立的 UndoRedo 步骤；
# - 出错且 rollback_on_error=true 时，会把已成功的那几步连续 undo 掉（用的还是编辑器自己的撤销栈）；
# - 回执里给出 applied / failed_index / rolled_back，调用方不用猜。


func _init() -> void:
	tool_name = "apply_scene_edits"
	tool_description = "Applies an ordered list of scene edits (add / delete / move / rename / set) in one call."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"ops": {
				"type": "array",
				"items": {"type": "object"},
				"description": "Ordered operations. Each is an object with \"op\" plus that op's own fields: "
					+ "{\"op\":\"add\",\"parent_path\":\".\",\"node_type\":\"Sprite2D\",\"node_name\":\"Icon\"}, "
					+ "{\"op\":\"delete\",\"node_path\":\"Old\"}, "
					+ "{\"op\":\"move\",\"node_path\":\"A\",\"parent_path\":\"B\"}, "
					+ "{\"op\":\"rename\",\"node_path\":\"A\",\"new_name\":\"B\"}, "
					+ "{\"op\":\"set\",\"node_path\":\"A\",\"property\":\"position\",\"value\":\"[0,1,0]\"}. "
					+ "Entries are executed in order, so a later op may reference a node an earlier op created."
			},
			"stop_on_error": {
				"type": "boolean",
				"description": "Stop at the first failing op. Default true."
			},
			"rollback_on_error": {
				"type": "boolean",
				"description": "Undo the ops that already succeeded when one fails. Default true."
			},
			"save": {
				"type": "boolean",
				"description": "Write the scene to disk when every op succeeded. Default false."
			},
			"verbose": {
				"type": "boolean",
				"description": "Include the whole scene tree in the reply. Default false."
			}
		},
		"required": ["ops"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var root: Node = get_active_scene_root()
	if root == null:
		return ToolResult.fail("No active scene in the editor. Open one with `open_file` first.")
	
	var unknown: String = check_params(p_args, ["ops", "stop_on_error", "rollback_on_error", "save", "verbose"])
	if not unknown.is_empty():
		return ToolResult.fail(unknown)
	
	var ops: Variant = p_args.get("ops")
	if not (ops is Array) or (ops as Array).is_empty():
		return ToolResult.fail("'ops' must be a non-empty array of operation objects.")
	
	var stop_on_error: bool = flag_with_default(p_args, "stop_on_error", true)
	var rollback: bool = flag_with_default(p_args, "rollback_on_error", true)
	
	var list: Array = ops
	var results: Array = []
	var applied: int = 0
	var failed_index: int = -1
	
	for index in range(list.size()):
		var entry: Variant = list[index]
		if typeof(entry) != TYPE_DICTIONARY:
			results.append({"ok": false, "index": index, "error": "each op must be an object with an \"op\" field"})
			failed_index = index
			break
		
		var op_args: Dictionary = (entry as Dictionary).duplicate()
		var op_name: String = str(op_args.get("op", "")).strip_edges()
		op_args.erase("op")
		var out: Dictionary = {}
		
		match op_name:
			"add":
				out = do_add_node(root, op_args)
			"delete":
				out = do_delete_node(root, op_args)
			"move":
				out = do_move_node(root, op_args)
			"rename":
				out = do_rename_node(root, op_args)
			"set":
				out = do_set_property(root, op_args)
			_:
				out = {"ok": false, "op": op_name, "error": "unknown op '%s' (supported: add, delete, move, rename, set)" % op_name}
		
		out["index"] = index
		results.append(out)
		
		if bool(out.get("ok", false)):
			applied += 1
		else:
			failed_index = index
			if stop_on_error:
				break
	
	var rolled_back: bool = false
	if failed_index >= 0 and rollback and applied > 0:
		rolled_back = _undo_last(root, applied)
	
	var summary: Dictionary = {
		"ok": failed_index < 0,
		"op": "batch",
		"scene": scene_path_of(root),
		"ops_total": list.size(),
		"applied": applied,
		"failed_index": failed_index,
		"rolled_back": rolled_back,
		"results": results,
	}
	
	if failed_index < 0:
		var save_error: String = save_if_requested(root, p_args)
		var saved: bool = flag_of(p_args, "save") and save_error.is_empty()
		summary["saved"] = saved
		summary["unsaved"] = not saved
		if not save_error.is_empty():
			summary["save_error"] = save_error
	
	var output: String = JSON.stringify(summary, "\t")
	if flag_of(p_args, "verbose"):
		output += "\n\nScene tree (%s):\n```\n%s\n```" % [scene_label(root), get_scene_tree_string(root)]
	elif failed_index < 0 and not bool(summary.get("saved", false)):
		output += "\n\n" + SAVE_HINT
	
	if failed_index >= 0:
		return ToolResult.fail(output)
	
	return ToolResult.ok(output)


# 连续撤销最后 p_count 个动作（每步都是编辑器自己的 UndoRedo 记录）。
#
# [为什么不能直接 ur.undo()] EditorUndoRedoManager 继承的是 Object，不是 UndoRedo，
# 它的方法表里只有 create_action / commit_action / get_history_undo_redo 等，没有 undo()。
# 旧写法 `ur.has_method("undo")` 恒为 false，于是回滚恒不执行、rolled_back 恒为 false。
# 必须先按对象取到"该场景所属的那条 UndoRedo"，再调它自己的 undo()。
func _undo_last(p_root: Node, p_count: int) -> bool:
	if p_count <= 0:
		return false
	
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	if ur == null:
		return false
	
	var history: UndoRedo = ur.get_history_undo_redo(ur.get_object_history_id(p_root))
	if history == null:
		return false
	
	var undone: int = 0
	for _index in range(p_count):
		if not history.undo():
			break
		undone += 1
	
	return undone == p_count
