@tool
extends AiTool

## 逻辑与 Position 工具高度相似，但针对 Rotation 做了特殊处理（支持 Node2D float 和 Node3D Vector3）


func _init() -> void:
	tool_name = "animate_rotation"
	tool_description = "Generates rotation keyframes (sine wave, spin, shake) for a node."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"target_node_path": { "type": "string" },
			"animation_player_path": { "type": "string" },
			"animation_name": { "type": "string" },
			"pattern": { "type": "string", "enum": ["sine_wave", "shake", "spin"], "description": "Spin means continuous rotation." },
			"axis": { "type": "string", "enum": ["x", "y", "z"], "description": "Ignored for Node2D." },
			"amount": { "type": "number", "description": "Angle in Radians (e.g. 3.14 for 180 deg)." },
			"frequency": { "type": "number", "description": "Hz or Speed multiplier." }
		},
		"required": ["target_node_path", "animation_name", "pattern", "amount"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	return _apply_anim(p_args)


func _apply_anim(p_args: Dictionary) -> Dictionary:
	var root = EditorInterface.get_edited_scene_root()
	var target = root.get_node_or_null(p_args.get("target_node_path", ""))
	var anim_player = root.get_node_or_null(p_args.get("animation_player_path", "")) as AnimationPlayer
	
	if not target or not anim_player: return {"success": false, "data": "Nodes not found."}
	
	var anim_name = p_args.get("animation_name", "")
	var library = anim_player.get_animation_library("")
	if not library or not library.has_animation(anim_name):
		return {"success": false, "data": "Animation not found."}
	
	var anim = library.get_animation(anim_name)
	var new_anim = anim.duplicate()
	
	var prop_type = "rotation"
	var track_path = "%s:%s" % [anim_player.get_path_to(target), prop_type]
	var tid = new_anim.find_track(track_path, Animation.TYPE_VALUE)
	if tid != -1: new_anim.remove_track(tid)
	
	tid = new_anim.add_track(Animation.TYPE_VALUE)
	new_anim.track_set_path(tid, track_path)
	
	var pattern = p_args.get("pattern", "sine_wave")
	var axis = p_args.get("axis", "z")
	var amount = float(p_args.get("amount", 0.0))
	var freq = float(p_args.get("frequency", 1.0))
	var dur = new_anim.length
	var base_val = target.get("rotation")
	
	var fps = 30.0
	var time = 0.0
	while time <= dur + 0.001:
		var offset = 0.0
		if pattern == "sine_wave":
			offset = sin(time * freq * TAU) * amount
		elif pattern == "shake":
			offset = randf_range(-1.0, 1.0) * amount
		elif pattern == "spin":
			# 持续旋转: amount 是总旋转量
			offset = lerp(0.0, amount, time / dur)
			
		var val = _calc_rot(target, base_val, axis, offset)
		new_anim.track_insert_key(tid, time, val)
		
		if pattern != "shake":
			var k = new_anim.track_find_key(tid, time, Animation.FIND_MODE_EXACT)
			new_anim.track_set_key_transition(tid, k, 1.0)
			
		time += 1.0 / fps
	
	var ur = EditorInterface.get_editor_undo_redo()
	ur.create_action("Anim Rot: " + pattern)
	ur.add_do_method(library, "add_animation", anim_name, new_anim)
	ur.add_undo_method(library, "add_animation", anim_name, anim)
	ur.commit_action()
	
	return {"success": true, "data": "Added rotation track (%s)." % pattern}


func _calc_rot(node, base, axis, offset):
	if node is Node2D or node is Control:
		return base + offset
	elif node is Node3D:
		var v = base
		if axis == "x": v.x += offset
		elif axis == "y": v.y += offset
		elif axis == "z": v.z += offset
		return v
	return base
