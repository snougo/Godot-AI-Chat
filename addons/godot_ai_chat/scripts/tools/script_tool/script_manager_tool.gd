@tool
extends BaseScriptTool

## 脚本管理工具
##
## 负责脚本文件的创建、打开和切换。
## 操作成功后，通常会返回带有行号的脚本内容，方便用户理解上下文。

# --- Init ---

func _init() -> void:
	tool_name = "script_manager"
	tool_description = "Manage script files: Create, Open, or Switch scripts. Returns structured code sliced by logic blocks."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["create", "open", "switch"],
				"description": "The action to perform."
			},
			"path": {
				"type": "string",
				"description": "The full script file path. Required."
			},
			"content": {
				"type": "string",
				"description": "Initial content for 'create'. Optional."
			}
		},
		"required": ["action", "path"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var action: String = p_args.get("action", "")
	var path: String = p_args.get("path", "")
	var content: String = p_args.get("content", "")

	if path.is_empty():
		return {"success": false, "data": "Path is required."}
	
	# Validation
	var safety_err: String = validate_path_safety(path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	var ext_err: String = validate_file_extension(path)
	if not ext_err.is_empty():
		return {"success": false, "data": ext_err}
	
	# --- Create ---
	if action == "create":
		if FileAccess.file_exists(path):
			return {"success": false, "data": "File already exists: %s" % path}
		
		var base_dir: String = path.get_base_dir()
		if not DirAccess.dir_exists_absolute(base_dir):
			return {"success": false, "data": "Directory does not exist: %s" % base_dir}
		
		var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if not file:
			return {"success": false, "data": "Failed to create file: %s" % path}
		
		if content.is_empty():
			content = "extends Node\n" 
		file.store_string(content)
		file.close()
		
		ToolBox.update_editor_filesystem(path)
		
		# Open it immediately to get the content
		var code_edit: CodeEdit = _get_code_edit(path)
		if code_edit:
			_focus_script_editor()
			# Use base class method
			var sliced_view: String = get_sliced_code_view(code_edit)
			return {"success": true, "data": "Created and opened %s. Structure:\n\n%s" % [path, sliced_view]}
		else:
			return {"success": true, "data": "Script created at: %s (Failed to open automatically)" % path}
	
	# --- Open / Switch ---
	elif action == "open" or action == "switch":
		if not FileAccess.file_exists(path):
			return {"success": false, "data": "File not found: %s" % path}
		
		var code_edit: CodeEdit = _get_code_edit(path)
		if code_edit:
			_focus_script_editor()
			# Use base class method
			var sliced_view: String = get_sliced_code_view(code_edit)
			return {"success": true, "data": "Opened %s. Structure:\n\n%s" % [path, sliced_view]}
		else:
			return {"success": false, "data": "Failed to open script editor for: %s" % path}

	return {"success": false, "data": "Unknown action: %s" % action}
