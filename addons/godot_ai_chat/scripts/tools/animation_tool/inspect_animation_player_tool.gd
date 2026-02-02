@tool
extends AiTool

func _init() -> void:
	tool_name = "inspect_animation_player"
	tool_description = "Lists all animations and tracks in an AnimationPlayer. Use this BEFORE modifying animations to get correct names."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"animation_player_path": { 
				"type": "string", 
				"description": "Path to the AnimationPlayer. If empty, tries to find one automatically." 
			},
			"animation_name": { 
				"type": "string", 
				"description": "Optional. If provided, lists detailed tracks for this specific animation." 
			}
		},
		"required": []
	}


func execute(p_args: Dictionary) -> Dictionary:
	var root = EditorInterface.get_edited_scene_root()
	if not root:
		return {"success": false, "data": "No active scene."}
	
	# 1. 智能查找 AnimationPlayer
	var path = p_args.get("animation_player_path", "")
	var anim_player: AnimationPlayer = null
	
	if not path.is_empty():
		anim_player = root.get_node_or_null(path) as AnimationPlayer
	
	if not anim_player:
		# 自动查找逻辑
		if root is AnimationPlayer:
			anim_player = root
		elif root.has_node("AnimationPlayer"):
			anim_player = root.get_node("AnimationPlayer")
		# 还可以尝试递归查找子节点，但为了性能暂时只查一层
	
	if not anim_player:
		return {"success": false, "data": "AnimationPlayer not found. Please specify 'animation_player_path'."}
	
	var result = "AnimationPlayer Found: '%s' (%s)\n" % [anim_player.name, anim_player.get_path()]
	
	# 2. 列出所有动画
	var libraries = anim_player.get_animation_library_list()
	var all_anims = []
	for lib_name in libraries:
		var lib = anim_player.get_animation_library(lib_name)
		for anim_name in lib.get_animation_list():
			all_anims.append(anim_name)
	
	if all_anims.is_empty():
		return {"success": true, "data": result + "No animations found in this player."}
		
	result += "Animations List (%d): %s\n" % [all_anims.size(), str(all_anims)]
	
	# 3. 列出指定动画的轨道详情
	var target_anim = p_args.get("animation_name", "")
	if not target_anim.is_empty():
		if not anim_player.has_animation(target_anim):
			result += "\nError: Animation '%s' NOT found in list." % target_anim
		else:
			result += "\nTracks in '%s':\n" % target_anim
			var anim = anim_player.get_animation(target_anim)
			if anim.get_track_count() == 0:
				result += "  (Empty Animation - No Tracks)\n"
			
			for i in range(anim.get_track_count()):
				var t_path = anim.track_get_path(i)
				var t_type = anim.track_get_type(i)
				var key_count = anim.track_get_key_count(i)
				var type_name = "Value"
				
				match t_type:
					Animation.TYPE_BEZIER: type_name = "Bezier"
					Animation.TYPE_METHOD: type_name = "Method"
					Animation.TYPE_AUDIO: type_name = "Audio"
				
				result += "- Track %d: '%s' [%s] (%d keys)\n" % [i, t_path, type_name, key_count]
				
				# 验证节点路径有效性 (Helping AI debug invalid paths)
				var node_path = str(t_path).split(":")[0]
				if not anim_player.has_node(node_path):
					result += "    (Warning: NodePath '%s' is invalid relative to AnimationPlayer)\n" % node_path
	
	return {"success": true, "data": result}
