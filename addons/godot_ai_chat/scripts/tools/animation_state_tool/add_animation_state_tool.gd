@tool
extends AiTool


func _init() -> void:
	tool_name = "add_animation_state"
	tool_description = "Adds or updates a State (Node) in an AnimationNodeStateMachine. Supports Undo/Redo."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_path": { "type": "string", "description": "Path to the .tres file." },
			"state_name": { "type": "string", "description": "Name of the state (e.g. 'Idle')." },
			"animation_name": { "type": "string", "description": "Name of the AnimationClip to link." },
			"position": { "type": "string", "description": "Optional visual position '(x, y)'." }
		},
		"required": ["file_path", "state_name", "animation_name"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var path = p_args.get("file_path", "")
	var state_name = p_args.get("state_name", "")
	var anim_name = p_args.get("animation_name", "")
	
	var sm = ResourceLoader.load(path, "AnimationNodeStateMachine", ResourceLoader.CACHE_MODE_REUSE) as AnimationNodeStateMachine
	if not sm:
		return {"success": false, "data": "Could not load StateMachine at: " + path}
	
	# 准备节点
	var anim_node = AnimationNodeAnimation.new()
	anim_node.animation = anim_name
	
	# 计算位置
	var pos = Vector2.ZERO
	var pos_str = p_args.get("position", "")
	if not pos_str.is_empty():
		var parts = pos_str.replace("(", "").replace(")", "").split(",")
		if parts.size() >= 2: pos = Vector2(parts[0].to_float(), parts[1].to_float())
	else:
		# 自动布局：向右下偏移
		var max_vec = Vector2(50, 50)
		for n in sm.get_node_list():
			var p = sm.get_node_position(n)
			max_vec = max_vec.max(p)
		pos = max_vec + Vector2(150, 0) # 往右排
	
	var undo_redo = EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Add State: " + state_name)
	
	if sm.has_node(state_name):
		# 修改现有
		var old_node = sm.get_node(state_name)
		if old_node is AnimationNodeAnimation:
			undo_redo.add_do_property(old_node, "animation", anim_name)
			undo_redo.add_undo_property(old_node, "animation", old_node.animation)
		else:
			# 替换节点类型暂不支持Undo，建议删除重来
			undo_redo.add_do_method(sm, "replace_node", state_name, anim_node)
	else:
		# 新增
		undo_redo.add_do_method(sm, "add_node", state_name, anim_node, pos)
		undo_redo.add_undo_method(sm, "remove_node", state_name)
		
		# 如果是第一个节点，通常 Godot 会自动设为 Start，但这属于副作用
	
	undo_redo.commit_action()
	return {"success": true, "data": "State '%s' set to animation '%s'." % [state_name, anim_name]}
