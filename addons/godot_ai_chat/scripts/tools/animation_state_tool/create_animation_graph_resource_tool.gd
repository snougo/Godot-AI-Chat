@tool
extends AiTool


func _init() -> void:
	tool_name = "create_animation_graph_resource"
	tool_description = "Creates a new empty AnimationNodeStateMachine resource (.tres file)."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_path": {
				"type": "string",
				"description": "Full path to create (e.g. 'res://resources/player_asm.tres')."
			}
		},
		"required": ["file_path"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var path = p_args.get("file_path", "")
	if not path.begins_with("res://"):
		return {"success": false, "data": "Path must start with 'res://'."}
	
	if FileAccess.file_exists(path):
		return {"success": false, "data": "File already exists."}
	
	var dir = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		return {"success": false, "data": "Directory does not exist: " + dir}
	
	var sm = AnimationNodeStateMachine.new()
	var err = ResourceSaver.save(sm, path)
	
	if err == OK:
		ToolBox.update_editor_filesystem(path)
		return {"success": true, "data": "Created AnimationNodeStateMachine at: " + path}
	
	return {"success": false, "data": "Failed to save: " + str(err)}
