extends AiTool

# 读取指定文件的内容（支持场景、脚本、资源、文本、图片元数据等）。
# 文件类型根据扩展名自动推断，无需手动指定。
# 单次输出受字符预算限制：超出后原位省略数值块 / 截断尾部，并可用 start_line、line_count 分段续读。
# 不包含文件夹结构读取功能（该功能已移至 manage_folder_tool）。


# --- Constants ---

const FileContentReader := preload("res://addons/godot_ai_chat/scripts/helper/file_content_reader.gd")

# 上下文类型与允许的扩展名映射
const EXTENSION_MAP: Dictionary = {
	"scene":      ["tscn", "scn"],
	"script":     ["gd", "gdshader", "glsl"],
	"text":       ["md", "json", "cfg", "txt", "godot", "uid", "import"],
	"resource":   ["tres", "res"],
	"image_meta": ["png", "jpg", "jpeg"]
}

# 支持按行续读的文件类型（其余类型返回的是结构摘要，没有文件行概念）
const LINE_WINDOW_FILE_TYPES: Dictionary = {
	"scene":    ["tscn"],
	"script":   ["gd", "gdshader", "glsl"],
	"text":     ["md", "json", "cfg", "txt", "godot", "uid", "import"],
	"resource": ["tres"]
}


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "read_file"
	tool_description = "Reads a file. Support: tscn, scn, gd, gdshader, glsl, md, json, cfg, txt, godot, uid, import, tres, res, and image_meta(jpg/jpeg/png)."


# --- Public Functions ---

# 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the file."
			},
			"start_line": {
				"type": "integer",
				"description": "1-based first line to return. Default 1."
			},
			"line_count": {
				"type": "integer",
				"description": "How many lines to return starting at 'start_line'. 0 = to end of file. Default 0"
			}
		},
		"required": ["path"]
	}


# 执行文件读取
# [param p_args]: 包含 path / start_line / line_count 的参数字典
# [return]: 包含成功状态和文件内容的字典
func execute(p_args: Dictionary) -> ToolResult:
	var path: String = p_args.get("path", "")
	
	if path.is_empty():
		return ToolResult.fail("Missing parameter: path")
	
	var validation_result: String = _validate_path(path)
	if not validation_result.is_empty():
		return ToolResult.fail(validation_result)
	
	var start_line: int = int(p_args.get("start_line", 1))
	var line_count: int = int(p_args.get("line_count", 0))
	
	# 自动检测文件类型
	var file_type: String = _auto_detect_file_type(path)
	if file_type.is_empty():
		var supported := ""
		for ft in EXTENSION_MAP.keys():
			supported += ft + ": [" + ", ".join(EXTENSION_MAP[ft]) + "]\n"
		return ToolResult.fail("Error: Could not auto-detect file type. Unsupported extension.\nSupported types:\n" + supported)
	
	# 安全拦截：禁止读取指定的敏感资源文件
	if file_type == "resource" and (
		path == PluginPaths.SETTINGS_PATH or
		path == PluginPaths.SKILL_AGENT_CONFIG_PATH or
		path == PluginPaths.COMPRESSION_CONFIG_PATH
	):
		return ToolResult.fail("Error: Due to security reasons, reading this file is prohibited. Please do not attempt again.")
	
	var result: ToolResult = _read_file_content(file_type, path, start_line, line_count)
	
	# 二进制 / 摘要类内容没有"文件行"概念：显式说明参数被忽略，避免"以为读到了后续内容"
	if result.is_ok() and (start_line > 1 or line_count > 0) and not _supports_line_window(file_type, path):
		return ToolResult.ok(result.get_data() + "\n[NOTE] start_line / line_count had no effect: this file is returned as a structural summary, not as raw text lines.")
	
	return result


# --- Private Functions ---

# 验证路径安全性
# [param p_path]: 要验证的路径
# [return]: 空字符串表示安全，否则返回错误信息
func _validate_path(p_path: String) -> String:
	if not p_path.begins_with("res://"):
		return "Error: Path must start with 'res://'."
	if ".." in p_path:
		return "Error: Path traversal ('..') is not allowed."
	return ""


# 根据文件扩展名自动推断文件类型
# [param p_path]: 文件路径
# [return]: 推断出的文件类型字符串，如果无法识别则返回空字符串
static func _auto_detect_file_type(p_path: String) -> String:
	var ext: String = p_path.get_extension().to_lower()
	for file_type in EXTENSION_MAP:
		if ext in EXTENSION_MAP[file_type]:
			return file_type
	return ""


# 该文件是否支持 start_line / line_count 续读
# [param p_file_type]: 文件类型
# [param p_path]: 文件路径
func _supports_line_window(p_file_type: String, p_path: String) -> bool:
	if not LINE_WINDOW_FILE_TYPES.has(p_file_type):
		return false
	return p_path.get_extension().to_lower() in LINE_WINDOW_FILE_TYPES[p_file_type]


# 执行文件内容读取
# [param p_file_type]: 上下文类型
# [param p_path]: 文件路径
# [param p_start_line]: 起始行（1-based）
# [param p_line_count]: 读取行数（0 表示读到末尾）
# [return]: 读取结果字典
func _read_file_content(p_file_type: String, p_path: String, p_start_line: int, p_line_count: int) -> ToolResult:
	if not FileAccess.file_exists(p_path):
		return ToolResult.fail("Error: File not found: " + p_path)
	
	match p_file_type:
		"scene":
			return _wrap_reader_result(FileContentReader.read_scene_content(p_path, p_start_line, p_line_count))
		"script":
			return _wrap_reader_result(FileContentReader.read_script_content(p_path, p_start_line, p_line_count))
		"text":
			return _wrap_reader_result(FileContentReader.read_text_content(p_path, p_start_line, p_line_count))
		"resource":
			return _wrap_reader_result(FileContentReader.read_resource_content(p_path, p_start_line, p_line_count))
		"image_meta":
			return _wrap_reader_result(FileContentReader.read_image_metadata(p_path))
		_:
			return ToolResult.fail("File Type Error: Unsupport file type.")


func _wrap_reader_result(p_dict: Dictionary) -> ToolResult:
	var img_data: PackedByteArray = p_dict.get("image_data", PackedByteArray())
	if not img_data.is_empty():
		return ToolResult.ok_with_image(p_dict.get("data", ""), img_data, p_dict.get("mime", "image/png"))
	elif p_dict.get("success", false):
		return ToolResult.ok(p_dict.get("data", ""))
	else:
		return ToolResult.fail(p_dict.get("data", "Unknown error"))
