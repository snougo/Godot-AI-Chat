@tool
extends AiTool

## 保存编辑中的场景或脚本文件到磁盘。
## 服务于 Scene Builder 和 Script Editor 技能。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "save_edited_file"
	tool_description = "Saves the currently edited file (scene or script) to disk."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_type": {
				"type": "string",
				"enum": ["scene", "script", "shader"],
				"description": "Type of file to save: 'scene' for the currently open scene, 'script' for the currently open script, 'shader' for a shader file opened in the Shader Editor."
			},
			"file_path": {
				"type": "string",
				"description": "Full path to the file. Required when file_type is 'shader'."
			}
		},
		"required": ["file_type"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Error: editor only tool.")
	
	var file_type: String = p_args.get("file_type", "")
	
	match file_type:
		"scene":
			return _save_scene()
		"script":
			return _save_script()
		"shader":
			return _save_shader(p_args.get("file_path", ""))
		_:
			return ToolResult.fail("Invalid file_type '%s'. Must be 'scene', 'script' or 'shader'." % file_type)


# --- Private Functions ---

func _save_scene() -> ToolResult:
	var root: Node = EditorInterface.get_edited_scene_root()
	if not root:
		return ToolResult.fail("Error: no active scene to save.")
	
	var path: String = root.scene_file_path
	if path.is_empty():
		return ToolResult.fail("Error: scene has never been saved. Save it manually in the editor first, or use 'create_scene' tool.")
	
	var err: Error = EditorInterface.save_scene()
	if err == OK:
		return ToolResult.ok("Scene saved: %s" % path)
	
	return ToolResult.fail("Error: failed to save scene. Error: %d" % err)


func _save_script() -> ToolResult:
	var se: ScriptEditor = EditorInterface.get_script_editor()
	var current_script: Script = se.get_current_script()
	if not current_script:
		return ToolResult.fail("Error: no active script to save.")
	
	var path: String = current_script.resource_path
	if path.is_empty():
		return ToolResult.fail("Error: script has never been saved. Use 'create_script' first.")
	
	# ScriptEditor 原生保存 — 自动处理 CodeEdit→Script 同步并清除 dirty flag
	se.save_all_scripts()
	
	return ToolResult.ok("Script saved: %s" % path)


func _save_shader(p_path: String) -> ToolResult:
	if p_path.is_empty():
		return ToolResult.fail("Error: 'file_path' is required when file_type is 'shader'.")
	
	var safety_err: String = validate_path_safety(p_path)
	if not safety_err.is_empty():
		return ToolResult.fail(safety_err)
	
	var shader: Shader = load(p_path) as Shader
	if shader == null:
		return ToolResult.fail("Error: not a shader file: %s" % p_path)
	
	# 目标 shader 必须在 Shader Editor 中打开（保证保存的是编辑器 buffer 的内容）
	var code_edit: CodeEdit = ToolBox.find_shader_code_edit(shader)
	if code_edit == null:
		return ToolResult.fail("Error: shader is not open in Shader Editor. Use 'open_file' first: %s" % p_path)
	
	# 兜底同步：确保 CodeEdit buffer 内容已写入 shader 资源（实时同步通常已完成）
	if shader.get_code() != code_edit.text:
		shader.set_code(code_edit.text)
	
	var err: Error = ResourceSaver.save(shader, p_path)
	if err != OK:
		return ToolResult.fail("Error: failed to save shader. Error: %d" % err)
	
	# 清除 Shader Editor 标签的未保存标记（*）
	code_edit.tag_saved_version()
	ToolBox.update_editor_filesystem(p_path)
	
	return ToolResult.ok("Shader saved: %s" % p_path)
