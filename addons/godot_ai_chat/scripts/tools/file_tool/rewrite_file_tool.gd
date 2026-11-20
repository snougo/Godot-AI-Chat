extends AiTool

# 文本文件覆盖工具（整文件重写）。
#
# 用途：把磁盘上已存在的文本文件整体替换为新内容，无需经过脚本编辑器。
# 与 edit_file 的分工：edit_file 做局部精确替换，本工具只做整文件覆盖。
# 只想改一两处却调用本工具，等于把「未在 content 里提及的全部内容」一并重写，
# 因此仅在确实需要重写全文（大范围重构、整篇重排）时才使用它。
#
# content 允许空字符串 —— 表示清空文件（返回值会明确说明文件已变为空）。
#
# 路径安全：
# 路径关卡：ReadonlyZoneConfig.readonly_patterns 命中的管控区一律禁写
#   （默认 /.git/、/.import/、/.godot/、/.addons/）
# - 豁免前缀：ReadonlyZoneConfig.extra_write_allowlist 可显式放开指定目录（默认空 = 不放开）
# - 格式关卡：ReadonlyZoneConfig.editable_text_extensions 决定哪些扩展名可改写
#
# 换行与 BOM：内部按 LF 处理，写回时沿用原文件的行尾风格与 BOM，
# 因此不必关心目标文件是 LF 还是 CRLF。
#
# .gd 目标会在写回前做静态编译检查：存在编译错误时不写盘、文件保持原状
# （可用 skip_compile_check 跳过）。
#
# 若目标文件正在脚本编辑器中打开且有未保存改动，请先在编辑器内保存，
# 否则编辑器 buffer 稍后保存时会覆盖本次改动。


# --- Constants ---

# GDScript 静态编译检查器（仅对 .gd 生效）
const GDScriptCompileChecker := preload("res://addons/godot_ai_chat/scripts/helper/gdscript_compile_checker.gd")


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "rewrite_file"
	tool_description = "Overwrites an entire existing file with new content. Support: %s. Only use this when the whole file genuinely needs replacing, for targeted changes use `edit_file`, which leaves unrelated content untouched. `.gd` content is compile-checked before writing — on compile errors nothing is written." % ReadonlyZoneConfig.get_config().get_editable_extensions_text()


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "res:// path of the text file to overwrite. The file must already exist."
			},
			"content": {
				"type": "string",
				"description": "The complete new content of the file. An empty string empties the file."
			},
			"skip_compile_check": {
				"type": "boolean",
				"description": "Optional. Set true to skip the GDScript compile check for `.gd` files (e.g. you are rebuilding a broken script in several steps, or it preloads a file that does not exist yet). Default false."
			}
		},
		"required": ["path", "content"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var path: String = String(p_args.get("path", "")).strip_edges()
	
	if path.is_empty():
		return ToolResult.fail("Error: 'path' is required.")
	if not path.begins_with("res://"):
		return ToolResult.fail("Error: Path must start with 'res://'.")
	if path.contains(".."):
		return ToolResult.fail("Error: Path traversal ('..') is not allowed.")
	if not p_args.has("content"):
		return ToolResult.fail("Error: 'content' is required. Pass an empty string to empty the file.")
	
	var content_value: Variant = p_args.get("content", "")
	if not (content_value is String):
		return ToolResult.fail("Error: 'content' must be a string.")
	
	if not FileAccess.file_exists(path):
		return ToolResult.fail(
			"Error: file not found: %s (this tool only overwrites existing files; use a create-type tool to make a new one)." % path
		)
	
	# 路径关卡（管控区 + 豁免前缀）与格式关卡（可写扩展名）统一由配置资源驱动
	var safety_err: String = validate_editable_path(path)
	if not safety_err.is_empty():
		return ToolResult.fail(safety_err)
	
	var extension: String = path.get_extension().to_lower()
	
	# --- 读取原始内容（用于还原行尾风格 / BOM，以及判断内容是否真的变化）---
	var read_file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if read_file == null:
		return ToolResult.fail("Error: failed to open file: %d" % FileAccess.get_open_error())
	var raw_text: String = read_file.get_as_text()
	read_file.close()
	
	var has_bom: bool = raw_text.begins_with("\uFEFF")
	var working_text: String = raw_text.trim_prefix("\uFEFF")
	var uses_crlf: bool = working_text.contains("\r\n")
	working_text = working_text.replace("\r\n", "\n")
	
	var new_text: String = String(content_value).replace("\r\n", "\n")
	
	if new_text == working_text:
		return ToolResult.ok("No change: content is identical. %s" % path)
	
	# --- .gd 静态编译检查：在写回之前做，失败则文件保持原状 ---
	var compile_note: String = ""
	if extension == "gd":
		if bool(p_args.get("skip_compile_check", false)):
			compile_note = "\nCompile check: skipped by request (`skip_compile_check = true`)."
		else:
			var outcome: GDScriptCompileChecker.Outcome = GDScriptCompileChecker.check(new_text, path)
			if not outcome.is_passed:
				return ToolResult.fail(GDScriptCompileChecker.format_failure(outcome, path, "rewritten"))
			compile_note = "\n" + GDScriptCompileChecker.format_pass_note(outcome)
	
	# --- 写回（沿用原文件的行尾风格与 BOM）---
	if uses_crlf:
		new_text = new_text.replace("\n", "\r\n")
	if has_bom:
		new_text = "\uFEFF" + new_text
	
	var write_file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if write_file == null:
		return ToolResult.fail("Error: failed to open file for writing: %d" % FileAccess.get_open_error())
	write_file.store_string(new_text)
	write_file.close()
	
	if extension == "glsl":
		ToolBox.reimport_editor_file(path)
	else:
		ToolBox.update_editor_filesystem(path)
		if extension == "gd":
			ToolBox.sync_open_scripts_after_disk_write(path)
		if extension == "gdshader":
			ToolBox.sync_shader_after_disk_write(path)
	
	# 清空文件是破坏性结果，必须在返回值里说清楚，避免模型以为自己写进了一段内容
	var empty_note: String = ""
	if String(content_value).is_empty():
		empty_note = "\nThe file is now empty (0 chars)."
	
	return ToolResult.ok(
		"Rewrote %s\nLine count: %d -> %d%s%s"
		% [path, working_text.count("\n") + 1, new_text.count("\n") + 1, compile_note, empty_note]
	)
