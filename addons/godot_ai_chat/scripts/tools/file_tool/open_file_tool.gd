@tool
extends AiTool

## 在编辑器中打开指定文件。
## 根据文件扩展名自动选择打开方式（场景或脚本编辑器）。


# --- Enums / Constants ---

## 支持的文件类型映射
## key: 扩展名（小写）, value: 文件类别，用于路由打开方式
const SUPPORTED_EXTENSIONS: Dictionary = {
	"tscn": "scene",
	"scn": "scene",
	"gd": "script",
	"gdshader": "shader"
}


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "open_file"
	tool_description = "Opens a file in the Godot editor. Supports: .tscn/.scn (Scene Editor), .gd/.gdshader (Script Editor)."
	security_level = SecurityLevel.READ_ONLY


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_path": {
				"type": "string",
				"description": "Full path to the file (e.g., 'res://xxx/xxx.tscn')."
			}
		},
		"required": ["file_path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var file_path: String = p_args.get("file_path", "")
	if file_path.is_empty():
		return ToolResult.fail("Error: 'file_path' parameter is required.")
	
	# 安全校验
	var safety_err: String = validate_path_safety(file_path)
	if not safety_err.is_empty():
		return ToolResult.fail(safety_err)
	
	if not FileAccess.file_exists(file_path):
		return ToolResult.fail("Error: File not found at " + file_path)
	
	# 根据扩展名路由
	var ext: String = file_path.get_extension().to_lower()
	if not SUPPORTED_EXTENSIONS.has(ext):
		return ToolResult.fail("Error: Unsupported file extension '.%s'. Supported: %s" % [ext, ", ".join(SUPPORTED_EXTENSIONS.keys())])
	
	var file_type: String = SUPPORTED_EXTENSIONS[ext]
	match file_type:
		"scene":
			return _open_scene(file_path)
		"script", "shader":
			return _open_script(file_path)
		_:
			return ToolResult.fail("Internal Error: Unknown file type '%s'." % file_type)


# --- Private Functions ---

# 在场景编辑器中打开场景文件
func _open_scene(p_path: String) -> ToolResult:
	EditorInterface.open_scene_from_path(p_path)
	return ToolResult.ok("Opened/Switched to scene: %s" % p_path)


# 在脚本/着色器编辑器中打开脚本或着色器文件
func _open_script(p_path: String) -> ToolResult:
	var res = load(p_path)
	if res is Script:
		EditorInterface.edit_script(res)
	elif res is Shader:
		EditorInterface.edit_resource(res)
		EditorInterface.set_main_screen_editor("Script")
		return ToolResult.ok("Shader opened successfully: %s" % p_path)
	else:
		return ToolResult.fail("The specified file is not a valid script or shader: %s" % p_path)
	
	EditorInterface.set_main_screen_editor("Script")
	return ToolResult.ok("Script opened successfully: %s" % p_path)
