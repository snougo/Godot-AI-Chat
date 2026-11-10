extends AiTool

# 通用脚本文件创建工具。
# 支持创建 GDScript(.gd)、Godot Shader(.gdshader) 与 GLSL(.glsl) 文件。
# 文件类型由 file_name 的扩展名决定。
# 注意：目标文件夹必须已存在，不会自动创建。
# .gd 内容会在写盘前做静态编译检查：存在编译错误时不创建文件（可用 skip_compile_check 跳过）。
# 说明：本类为 RefCounted 工具，仅通过 new() 实例化，故无需 @tool。


# --- Constants ---

# 允许创建的脚本扩展名
const SCRIPT_EXTENSIONS: Array[String] = ["gd", "gdshader", "glsl"]

# GDScript 静态编译检查器（仅对 .gd 生效）
const GDScriptCompileChecker := preload("res://addons/godot_ai_chat/scripts/helper/gdscript_compile_checker.gd")


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_script_file"
	tool_description = "Creates a new script file. Support: gd, gdshader, glsl. `.gd` content is compile-checked before writing — on compile errors the file is not created."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Target folder path. The folder must already exist."
			},
			"file_name": {
				"type": "string",
				"description": "File name with one of these extensions: `.gd`, `.gdshader`, `.glsl`."
			},
			"content": {
				"type": "string",
				"description": "Initial file content."
			},
			"skip_compile_check": {
				"type": "boolean",
				"description": "Optional. Set true to skip the GDScript compile check for `.gd` content (e.g. the script preloads a file that does not exist yet, or you intentionally create an incomplete script). Default false."
			}
		},
		"required": ["path", "file_name", "content"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var folder_path: String = p_args.get("path", "")
	var file_name: String = p_args.get("file_name", "")
	var content: String = p_args.get("content", "")
	var skip_compile_check: bool = bool(p_args.get("skip_compile_check", false))
	
	if folder_path.is_empty() or file_name.is_empty() or content.is_empty():
		return ToolResult.fail("Error: 'path', 'file_name', and 'content' are required.")
	
	# 确保文件夹路径以 / 结尾
	if not folder_path.ends_with("/"):
		folder_path += "/"
	
	var full_path: String = folder_path + file_name
	
	# 安全校验
	var safety_err: String = validate_path_safety(full_path)
	if not safety_err.is_empty():
		return ToolResult.fail(safety_err)
	
	# 检查文件是否已存在
	if FileAccess.file_exists(full_path):
		return ToolResult.fail("Error: File already exists at %s. Overwriting is not allowed." % full_path)
	
	# 检查目标文件夹是否存在（禁止越权创建文件夹）
	if not DirAccess.dir_exists_absolute(folder_path):
		return ToolResult.fail("Error: Target folder '%s' does not exist. create folder first." % folder_path)
	
	# 强制校验扩展名
	var ext: String = full_path.get_extension().to_lower()
	if ext not in SCRIPT_EXTENSIONS:
		return ToolResult.fail("Error: Invalid extension '.%s'. Script files must use one of: .gd, .gdshader, .glsl." % ext)
	
	# .gd 静态编译检查：在写盘之前做，失败则不留任何文件
	var compile_note: String = ""
	if ext == "gd":
		if skip_compile_check:
			compile_note = "\nCompile check: skipped by request (`skip_compile_check = true`)."
		else:
			var outcome: GDScriptCompileChecker.Outcome = GDScriptCompileChecker.check(content, full_path)
			if not outcome.is_passed:
				return ToolResult.fail(GDScriptCompileChecker.format_failure(outcome, full_path, "created"))
			compile_note = "\n" + GDScriptCompileChecker.format_pass_note(outcome)
	
	var file := FileAccess.open(full_path, FileAccess.WRITE)
	if not file:
		return ToolResult.fail("Failed to create script file: " + str(FileAccess.get_open_error()))
	
	file.store_string(content)
	file.close()
	
	# .glsl 是「导入型资源」（importer = "glsl" → RDShaderFile）。
	# update_file() 只登记文件、不触发导入（官方文档明确说明），
	# 会导致该文件没有 .import，双击时 EditorNode::load_resource() 取到 null Resource
	# 并报 ERR_CANT_OPEN。因此先登记再触发一次（带节流的）全量扫描，让导入真正发生。
	# .gd / .gdshader 由 loader 直接读源文件，无需导入，仍走增量更新。
	if ext == "glsl":
		ToolBox.reimport_editor_file(full_path)
	else:
		ToolBox.update_editor_filesystem(full_path)
	
	return ToolResult.ok("Script created: %s%s" % [full_path, compile_note])
