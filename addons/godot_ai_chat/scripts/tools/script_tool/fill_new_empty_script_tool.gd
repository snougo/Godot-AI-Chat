@tool
extends AiTool

const PATH_BLACKLIST = [
	"/.git/", 
	"/.import/", 
	"/.godot/",
	"/android/", 
	"/addons/"
]


func _init() -> void:
	tool_name = "fill_new_empty_script"
	tool_description = "Only for filling a new empty script file with code content."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The path to the empty script (e.g., 'res://scripts/my_script.gd')."
			},
			"code_content": {
				"type": "string",
				"description": "The GDScript code to write."
			}
		},
		"required": ["path", "code_content"]
	}


func execute(args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path = args.get("path", "")
	var content = args.get("code_content", "")
	
	# 黑名单路径检查
	for blocked_pattern in PATH_BLACKLIST:
		if blocked_pattern in path:
			return {
				"success": false, 
				"data": "Error: The path contains a blacklisted pattern '%s'. Modifying scripts in this location is not allowed." % blocked_pattern
			}
	
	# 基础检查：文件必须存在
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "Error: File not found: " + path + ". Please use 'create_script' tool first."}
	
	var res: Resource = load(path)
	if not res is Script:
		return {"success": false, "data": "Error: Resource at path is not a script."}
	
	var script = res as Script
	
	# 确保在编辑器中打开并激活
	# 这一步至关重要，它确保我们即将操作的是正确的编辑器 tab
	EditorInterface.edit_resource(script)
	
	# 获取编辑器控件
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	var current_editor: ScriptEditorBase = script_editor.get_current_editor() # 返回 ScriptEditorBase
	
	if not current_editor:
		return {"success": false, "data": "Error: Could not access script editor."}
	
	var base_editor: Control = current_editor.get_base_editor() # 通常是 CodeEdit
	if not base_editor:
		return {"success": false, "data": "Error: Could not access text editor control."}
	
	# 安全检查：检查【编辑器内的实时内容】是否为空
	# 优先检查编辑器状态而不是磁盘状态 (script.source_code)，防止覆盖用户已输入但未保存的代码
	if base_editor.text.strip_edges().length() > 0:
		return {
			"success": false, 
			"data": "Error: The script is not empty in the editor. To prevent losing your unsaved changes, this tool will not proceed."
		}
			
	
	# 写入内容
	# 直接设置文本，触发脏标记(*)，但不保存
	base_editor.text = content
	
	return {
		"success": true, 
		"data": "Successfully populated '" + path + "'. The file is now in an unsaved state (*). Please review and save manually."
	}
