@tool
extends AiTool

func _init() -> void:
	tool_name = "smooth_animation_curve"
	tool_description = "Applies easing to ALL keyframes in a track. Supports standard & Bezier tracks (Linearize only for Bezier)."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"target_node_path": { 
				"type": "string",
				"description": "Path to the target node. Used for fuzzy matching track paths."
			},
			"animation_player_path": { "type": "string" },
			"animation_name": { "type": "string" },
			"property_name": { 
				"type": "string", 
				"enum": ["position", "rotation"],
				"description": "The property to smooth. Automatically handles split axis tracks (e.g. rotation:y)."
			},
			"easing_type": { 
				"type": "string", 
				"enum": ["Linear", "EaseIn", "EaseOut", "Instant"], 
				"description": "Linear=1.0. For Bezier tracks, currently only 'Linear' is fully supported (flattens handles)." 
			}
		},
		"required": ["animation_name", "property_name"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	var anim_player: AnimationPlayer = _get_anim_player(root, p_args.get("animation_player_path", ""))
	
	if not anim_player: 
		return {"success": false, "data": "AnimationPlayer not found."}
	
	var anim_name: StringName = p_args.get("animation_name", "")
	var library: AnimationLibrary = anim_player.get_animation_library("")
	if not library or not library.has_animation(anim_name):
		return {"success": false, "data": "Animation '%s' not found." % anim_name}
	
	var anim: Animation = library.get_animation(anim_name)
	var new_anim: Animation = anim.duplicate() # Undo safety
	
	var prop := p_args.get("property_name", "")
	var target_path := p_args.get("target_node_path", "")
	var easing_type := p_args.get("easing_type", "Linear")
	
	# --- 1. 查找所有相关轨道 (含子属性) ---
	var target_indices = []
	
	for i in range(new_anim.get_track_count()):
		var path: String = str(new_anim.track_get_path(i))
		
		# 检查属性名匹配
		# 匹配规则：路径结尾是 :prop 或 :prop:x, :prop:y, :prop:z
		var is_match := false
		if path.ends_with(":" + prop): is_match = true
		elif path.ends_with(":" + prop + ":x"): is_match = true
		elif path.ends_with(":" + prop + ":y"): is_match = true
		elif path.ends_with(":" + prop + ":z"): is_match = true
		
		if is_match:
			# 如果指定了 target_node，还需要验证节点部分
			if not target_path.is_empty():
				var target_node := root.get_node_or_null(target_path)
				if target_node:
					var relative_path: NodePath = anim_player.get_path_to(target_node)
					if not path.begins_with(str(relative_path)):
						continue # 节点不匹配，跳过
			
			target_indices.append(i)
	
	if target_indices.is_empty():
		return {"success": false, "data": "No tracks found for property '%s' (checked sub-properties too)." % prop}
	
	# --- 2. 应用平滑 ---
	var modified_count = 0
	
	for tid in target_indices:
		var t_type = new_anim.track_get_type(tid)
		var key_count: int = new_anim.track_get_key_count(tid)
		
		if t_type == Animation.TYPE_VALUE:
			# 标准值轨道：直接设置 Transition
			var transition = 1.0
			match easing_type:
				"Linear": transition = 1.0
				"EaseIn": transition = 2.0
				"EaseOut": transition = 0.5
				"Instant": transition = 0.0
			
			for k in range(key_count):
				new_anim.track_set_key_transition(tid, k, transition)
			modified_count += 1
			
		elif t_type == Animation.TYPE_BEZIER:
			# Bezier 轨道：操作句柄
			if easing_type == "Linear":
				# 线性化：将所有 Handle 设为 0 (或者极小值)，使其变为折线
				for k in range(key_count):
					new_anim.bezier_track_set_key_in_handle(tid, k, Vector2.ZERO)
					new_anim.bezier_track_set_key_out_handle(tid, k, Vector2.ZERO)
				modified_count += 1
			else:
				# 暂不支持复杂的 EaseIn/Out Bezier 计算，因为这需要根据时间差动态计算 Handle 长度
				# 我们只做有限支持：给个警告但尝试把 handle 归零作为 fallback
				for k in range(key_count):
					new_anim.bezier_track_set_key_in_handle(tid, k, Vector2.ZERO)
					new_anim.bezier_track_set_key_out_handle(tid, k, Vector2.ZERO)
				modified_count += 1
				# 可以在返回信息里加个备注
	
	# --- 3. 提交 Undo ---
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("Smooth Anim: %s (%s)" % [prop, easing_type])
	ur.add_do_method(library, "add_animation", anim_name, new_anim)
	ur.add_undo_method(library, "add_animation", anim_name, anim)
	ur.commit_action()
	
	var msg: String = "Applied '%s' to %d tracks for '%s'." % [easing_type, modified_count, prop]
	if easing_type != "Linear" and modified_count > 0:
		msg += " (Note: Bezier tracks were flattened to Linear as Auto-Ease is complex.)"
	
	return {"success": true, "data": msg}


func _get_anim_player(root: Node, path: String) -> AnimationPlayer:
	if not path.is_empty():
		return root.get_node_or_null(path) as AnimationPlayer
	if root is AnimationPlayer:
		return root
	if root.has_node("AnimationPlayer"):
		return root.get_node("AnimationPlayer")
	return null
