@tool
extends AiTool

## 同步编译目标脚本并抓取编译错误（从编辑器输出日志）。
## 不依赖脚本编辑器 UI 的异步验证，结果即时可靠。
## 编译逻辑参考 run_editor_script 的已验证实现。
## 注意：检查的是磁盘上的文件内容，请先保存脚本再调用。

# --- Private Vars ---

## 最近一次编译错误文本（调试用）
var _last_compile_error: String = ""


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "check_script_compile"
	tool_description = "Synchronously compiles a GDScript file and captures compiler errors if exist."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Target script file full path."
			}
		},
		"required": ["path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Error: editor only tool.")
	
	var path: String = p_args.get("path", "")
	if path.is_empty():
		return ToolResult.fail("Error: 'path' parameter is required.")
	
	# 安全检查
	var safety_err: String = validate_path_safety(path)
	if not safety_err.is_empty():
		return ToolResult.fail(safety_err)
	if not path.ends_with(".gd"):
		return ToolResult.fail("Error: '%s' is not a GDScript file." % path)
	if not FileAccess.file_exists(path):
		return ToolResult.fail("Error: file not found: %s" % path)
	
	var source: String = FileAccess.get_file_as_string(path)
	if source.is_empty():
		return ToolResult.fail("Error: script source is empty: %s" % path)
	
	# 同步编译并捕获错误
	var error_text: String = _compile_and_capture(source, path)
	if error_text.is_empty():
		return ToolResult.ok("Script compiles cleanly: %s" % path)
	
	var lines: Array = _parse_error_lines(error_text)
	var msg: String = "**Script compilation failed:** `%s`\n\n" % path
	msg += "**Compiler errors (%d):**\n" % lines.size()
	for l in lines:
		msg += "- %s\n" % l
	return ToolResult.fail(msg)


# --- Private Functions ---

# 同步编译脚本并捕获错误文本。返回空字符串表示编译成功。
# [param p_path]: 真实文件路径，用于让错误消息显示 res:// 路径而非临时对象 ID。
func _compile_and_capture(p_source: String, p_path: String = "") -> String:
	_last_compile_error = ""
	var editor_log: RichTextLabel = EditorConsoleReader.output_label()
	var before_text: String = editor_log.get_parsed_text() if editor_log else ""
	var cleaned: String = _strip_class_name(p_source)
	var script := GDScript.new()
	if not p_path.is_empty():
		script.resource_path = p_path
	script.source_code = cleaned
	
	var err: Error = script.reload()
	if err != OK:
		if editor_log:
			var after_text: String = editor_log.get_parsed_text()
			var captured: String = EditorConsoleReader.capture_error_delta(before_text, after_text)
			if not captured.is_empty():
				_last_compile_error = captured
		printerr("[check_script_compile] Compilation error: ", err)
		return _last_compile_error
	
	return ""


# 移除 class_name 声明（避免 reload 时注册全局类造成冲突）
func _strip_class_name(p_code: String) -> String:
	var class_name_regex: RegEx = RegEx.create_from_string("(?m)^class_name\\s+\\w+\\s*$")
	return class_name_regex.sub(p_code, "", true)


# 解析错误文本为去空行数组
func _parse_error_lines(p_text: String) -> Array:
	var lines: Array = []
	if p_text.is_empty():
		return lines
	for line in p_text.split("\n"):
		line = line.strip_edges()
		if not line.is_empty():
			lines.append(line)
	return lines
