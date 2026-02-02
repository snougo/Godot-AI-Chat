@tool
extends AiTool


func _init() -> void:
	tool_name = "animate_position"
	tool_description = "Generates position keyframes (sine wave, shake, or linear move) for a node."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"target_node_path": { "type": "string" },
			"animation_player_path": { "type": "string" },
			"animation_name": { "type": "string", "description": "Must exist." },
			"pattern": { "type": "string", "enum": ["sine_wave", "shake", "offset"], "description": "Algorithm." },
			"axis": { "type": "string", "enum": ["x", "y", "z", "all"] },
			"amount": { "type": "number", "description": "Amplitude (for wave/shake) or Offset distance." },
			"frequency": { "type": "number", "description": "Hz (only for wave)." }
		},
		"required": ["target_node_path", "animation_name", "pattern", "amount"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	return _apply_anim(p_args, "position")


# --- Logic ---
func _apply_anim(p_args: Dictionary, prop_type: String) -> Dictionary:
	var root = EditorInterface.get_edited_scene_root()
	var target = root.get_node_or_null(p_args.get("target_node_path", ""))
	var anim_player = root.get_node_or_null(p_args.get("animation_player_path", "")) as AnimationPlayer
	
	if not target or not anim_player: return {"success": false, "data": "Nodes not found."}
	
	var anim_name = p_args.get("animation_name", "")
	var library = anim_player.get_animation_library("")
	if not library or not library.has_animation(anim_name):
		return {"success": false, "data": "Animation '%s' does not exist. Create it first." % anim_name}
	
	var anim = library.get_animation(anim_name)
	# 必须复制一份来修改，然后通过Undo提交
	var new_anim = anim.duplicate()
	
	# 清理旧轨道
	var track_path = "%s:%s" % [anim_player.get_path_to(target), prop_type]
	var tid = new_anim.find_track(track_path, Animation.TYPE_VALUE)
	if tid != -1: new_anim.remove_track(tid)
	
	tid = new_anim.add_track(Animation.TYPE_VALUE)
	new_anim.track_set_path(tid, track_path)
	
	# 参数
	var pattern = p_args.get("pattern", "sine_wave")
	var axis = p_args.get("axis", "y")
	var amount = float(p_args.get("amount", 0.0))
	var freq = float(p_args.get("frequency", 1.0))
	var dur = new_anim.length
	var base_val = target.get(prop_type) # 读取当前值作为基准
	
	# 生成关键帧
	var fps = 30.0
	var time = 0.0
	while time <= dur + 0.001:
		var offset = 0.0
		if pattern == "sine_wave":
			offset = sin(time * freq * TAU) * amount
		elif pattern == "shake":
			offset = randf_range(-1.0, 1.0) * amount
		elif pattern == "offset":
			# 简单的线性移动：从 base 到 base+amount
			offset = lerp(0.0, amount, time / dur)
			
		var val = _calc_vec(base_val, axis, offset)
		new_anim.track_insert_key(tid, time, val)
		
		# 平滑处理
		if pattern == "sine_wave" or pattern == "offset":
			var k = new_anim.track_find_key(tid, time, Animation.FIND_MODE_EXACT)
			new_anim.track_set_key_transition(tid, k, 1.0)
			
		time += 1.0 / fps
	
	# 提交 Undo
	var ur = EditorInterface.get_editor_undo_redo()
	ur.create_action("Anim %s: %s" % [prop_type, pattern])
	ur.add_do_method(library, "add_animation", anim_name, new_anim)
	ur.add_undo_method(library, "add_animation", anim_name, anim) # 恢复旧动画对象
	ur.commit_action()
	
	return {"success": true, "data": "Added %s track (%s)." % [prop_type, pattern]}


func _calc_vec(base, axis, offset):
	var v = base
	if base is Vector2:
		if axis == "x" or axis == "all": v.x += offset
		if axis == "y" or axis == "all": v.y += offset
	elif base is Vector3:
		if axis == "x" or axis == "all": v.x += offset
		if axis == "y" or axis == "all": v.y += offset
		if axis == "z" or axis == "all": v.z += offset
	return v
