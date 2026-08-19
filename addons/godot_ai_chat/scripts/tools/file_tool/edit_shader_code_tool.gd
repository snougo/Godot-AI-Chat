@tool
extends AiTool

## 编辑 Shader Editor 中打开的着色器文件代码。
## 直接修改 Shader Editor 的 CodeEdit buffer（所见即所得），
## 修改会实时同步到 Shader 资源（script_changed → apply_shaders → shader.set_code）。
## 前置条件：目标 .gdshader 已通过 open_file 在 Shader Editor 中打开。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "edit_shader_code"
	tool_description = "Edits the shader code currently open in the Shader Editor. The shader file must be opened first . Replaces the entire shader code with new_code."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_path": {
				"type": "string",
				"description": "Full path to the .gdshader file (must be open in Shader Editor first)."
			},
			"new_code": {
				"type": "string",
				"description": "The complete new shader code to write into the Shader Editor."
			}
		},
		"required": ["file_path", "new_code"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var file_path: String = p_args.get("file_path", "")
	var new_code: String = p_args.get("new_code", "")
	
	if file_path.is_empty():
		return ToolResult.fail("Error: 'file_path' parameter is required.")
	if new_code.is_empty():
		return ToolResult.fail("Error: 'new_code' parameter is required.")
	
	# 安全校验
	var safety_err: String = validate_path_safety(file_path)
	if not safety_err.is_empty():
		return ToolResult.fail(safety_err)
	
	var shader: Shader = load(file_path) as Shader
	if shader == null:
		return ToolResult.fail("Error: not a shader file: %s" % file_path)
	
	# 在 Shader Editor 中定位该 shader 的 CodeEdit（内容匹配 + 自动激活标签）
	var code_edit: CodeEdit = ToolBox.find_shader_code_edit(shader)
	if code_edit == null:
		return ToolResult.fail(
			"Error: shader is not open in the Shader Editor. "
			+ "Use 'open_file' to open it in Shader Editor first: %s" % file_path)
	
	# 写入 CodeEdit buffer（Shader Editor 立即显示新代码）
	code_edit.text = new_code
	# 立即同步 shader 资源，避免依赖 idle Timer 异步同步导致内容不匹配
	if shader.get_code() != new_code:
		shader.set_code(new_code)
	
	# 返回带行号的当前代码视图
	var view := _format_with_line_numbers(code_edit)
	return ToolResult.ok("Shader code updated in Shader Editor.\n\nCurrent Shader Code:\n%s" % view)


# --- Private Functions ---

func _format_with_line_numbers(p_code_edit: CodeEdit) -> String:
	var result := ""
	var line_count: int = p_code_edit.get_line_count()
	var line_count_width: int = str(line_count).length()
	for i in range(line_count):
		result += "%*d | %s\n" % [line_count_width, i + 1, p_code_edit.get_line(i)]
	return result
