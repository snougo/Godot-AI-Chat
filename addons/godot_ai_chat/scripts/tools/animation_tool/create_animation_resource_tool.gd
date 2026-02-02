@tool
extends AiTool


func _init() -> void:
	tool_name = "create_animation_resource"
	tool_description = "Creates or resets an Animation resource within an AnimationPlayer."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"animation_player_path": { "type": "string", "description": "Path to the AnimationPlayer node." },
			"animation_name": { "type": "string", "description": "Name of the new animation (e.g. 'idle', 'attack')." },
			"duration": { "type": "number", "description": "Duration in seconds (default: 1.0)." },
			"loop": { "type": "boolean", "description": "Enable looping." }
		},
		"required": ["animation_player_path", "animation_name"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var root = EditorInterface.get_edited_scene_root()
	if not root: return {"success": false, "data": "No active scene."}
	
	var anim_player = root.get_node_or_null(p_args.get("animation_player_path", "")) as AnimationPlayer
	if not anim_player: return {"success": false, "data": "AnimationPlayer not found."}
	
	var anim_name = p_args.get("animation_name", "")
	var duration = float(p_args.get("duration", 1.0))
	var loop = p_args.get("loop", false)
	
	var library = anim_player.get_animation_library("")
	if not library: return {"success": false, "data": "No animation library found."}
	
	var undo_redo = EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Create Anim: " + anim_name)
	
	var new_anim = Animation.new()
	new_anim.length = duration
	new_anim.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	
	if library.has_animation(anim_name):
		# 如果存在，替换
		var old_anim = library.get_animation(anim_name)
		undo_redo.add_do_method(library, "add_animation", anim_name, new_anim)
		undo_redo.add_undo_method(library, "add_animation", anim_name, old_anim)
	else:
		# 如果不存在，新建
		undo_redo.add_do_method(library, "add_animation", anim_name, new_anim)
		undo_redo.add_undo_method(library, "remove_animation", anim_name)
	
	undo_redo.commit_action()
	return {"success": true, "data": "Created animation '%s' (%.1fs)." % [anim_name, duration]}
