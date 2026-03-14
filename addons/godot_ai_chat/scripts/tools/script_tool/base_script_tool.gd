@tool
class_name BaseScriptTool
extends AiTool

## 脚本工具的基类 (v4: Removed Slicing Concept)

# --- Enums / Constants ---

const DEFAULT_ALLOWED_EXTENSIONS: Array[String] = ["gd", "gdshader"]


# --- Public Functions ---

## 验证文件扩展名
func validate_file_extension(p_path: String, p_allowed_extensions: Array = []) -> String:
	if p_allowed_extensions.is_empty():
		p_allowed_extensions = DEFAULT_ALLOWED_EXTENSIONS
	var extension: String = p_path.get_extension().to_lower()
	if extension not in p_allowed_extensions:
		return "Error: File extension '%s' is not allowed. Allowed: %s" % [extension, str(p_allowed_extensions)]
	return ""


## 生成带行号的完整脚本内容
## [param p_editor]: CodeEdit 编辑器实例
func get_full_script_with_line_numbers(p_editor: CodeEdit) -> String:
	var result := ""
	var line_count := p_editor.get_line_count()
	var line_count_width := str(line_count).length()
	
	for i in range(line_count):
		var line_content := p_editor.get_line(i)
		result += "%*d | %s\n" % [line_count_width, i + 1, line_content]
	
	return result


# --- Protected Helper Functions ---

func _get_code_edit(p_path: String) -> CodeEdit:
	# [Security Check 1]: 防止主动打开受限路径
	if not p_path.is_empty():
		var safety_err := validate_path_safety(p_path)
		if not safety_err.is_empty():
			AIChatLogger.error("[BaseScriptTool] Security Error: " + safety_err)
			return null
	
	var script_editor := EditorInterface.get_script_editor()
	
	# 尝试加载并切换到指定脚本
	if not p_path.is_empty() and FileAccess.file_exists(p_path):
		var res = load(p_path)
		if res is Script: 
			EditorInterface.edit_script(res)
	
	EditorInterface.set_main_screen_editor("Script")
	
	# [Security Check 2]: 防止操作当前已打开的受限文件
	var current_script := script_editor.get_current_script()
	if current_script:
		var current_path := current_script.resource_path
		var safety_err := validate_path_safety(current_path)
		if not safety_err.is_empty():
			AIChatLogger.error("[BaseScriptTool] Security Block: Cannot edit file in restricted path: " + current_path)
			return null
	
	# 获取 CodeEdit 实例
	var editor_base = script_editor.get_current_editor()
	if editor_base:
		return editor_base.get_base_editor() as CodeEdit
	
	return null


func _focus_script_editor() -> void:
	EditorInterface.set_main_screen_editor("Script")


# 获取当前已打开脚本的 CodeEdit 实例（不打开新脚本）
func _get_current_code_edit() -> CodeEdit:
	var script_editor := EditorInterface.get_script_editor()
	
	# 确保当前有打开的脚本
	var current_script := script_editor.get_current_script()
	if not current_script:
		return null
	
	var current_path := current_script.resource_path
	
	# [Security Check] 防止操作受限路径的文件
	var safety_err := validate_path_safety(current_path)
	if not safety_err.is_empty():
		AIChatLogger.warn("[BaseScriptTool] Security Block: Cannot edit file in restricted path: " + current_path)
		return null
	
	EditorInterface.set_main_screen_editor("Script")
	
	# 获取 CodeEdit 实例
	var editor_base = script_editor.get_current_editor()
	if editor_base:
		return editor_base.get_base_editor() as CodeEdit
	
	return null
