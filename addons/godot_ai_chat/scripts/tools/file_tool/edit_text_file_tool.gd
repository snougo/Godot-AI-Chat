@tool
extends AiTool

## 文本文件编辑工具（精确替换 / 整体重写）。
##
## 用途：直接对磁盘上已存在的文本文件做修改，无需经过脚本编辑器。
## - 精确替换：old_string 必须逐字符匹配（含缩进）；默认要求唯一命中，避免误改
## - 整体重写：提供 rewrite 时忽略 edits，整文件覆盖
##
## 路径安全：
## - 受统一黑名单管控（/.git/、/.import/、/.godot/、/android/、/addons/）
## - EXTRA_WRITE_ALLOWLIST 可显式追加允许写入的目录前缀（默认空 = 不追加）
##
## 换行与 BOM：内部统一按 LF 匹配，写回时恢复原文件的行尾风格与 BOM，
## 因此不必关心目标文件是 LF 还是 CRLF。
##
## 若目标文件正在脚本编辑器中打开且有未保存改动，请先在编辑器内保存，
## 否则编辑器 buffer 稍后保存时会覆盖本次改动。


# --- Constants ---

## 允许编辑的文本类扩展名（二进制资源如 .scn/.res/.png 不在列）
const EDITABLE_EXTENSIONS: Array[String] = [
	"md", "txt", "json", "cfg", "csv", "glsl", "gdshader"
]

## 额外允许写入的路径前缀（默认空 = 完全遵循黑名单）。
## 默认黑名单禁止写入 /addons/。若确实需要让 AI 修改某个插件，可在此显式列出该插件目录，
## 例如 ["res://addons/poly_model/"]。
## 只有【人类编辑本文件】才能放宽该限制 —— AI 无法自行修改自己运行所依赖的这份脚本。
const EXTRA_WRITE_ALLOWLIST: Array[String] = []


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "edit_text_file"
	tool_description = "Edits an existing text file on disk. Support md/txt/json/cfg/csv/glsl/gdshader"


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "res:// path of the text file to edit. The file must already exist."
			},
			"edits": {
				"type": "array",
				"description": "Ordered exact-string replacements. Each edit is applied to the result of the previous one.",
				"items": {
					"type": "object",
					"properties": {
						"old_string": {
							"type": "string",
							"description": "Exact text to replace (multi-line supported). Indentation must match."
						},
						"new_string": {
							"type": "string",
							"description": "Replacement text. Use an empty string to delete the matched text."
						},
						"replace_all": {
							"type": "boolean",
							"description": "If true, replace every occurrence. If false (default), old_string must be unique, otherwise the whole call is rejected."
						}
					},
					"required": ["old_string", "new_string"]
				}
			},
			"rewrite": {
				"type": "string",
				"description": "Optional. If provided (non-empty), the entire file is overwritten with this content and `edits` is ignored."
			}
		},
		"required": ["path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var path: String = String(p_args.get("path", "")).strip_edges()
	if path.is_empty():
		return ToolResult.fail("Error: 'path' is required.")
	if not path.begins_with("res://"):
		return ToolResult.fail("Error: Path must start with 'res://'.")
	if path.contains(".."):
		return ToolResult.fail("Error: Path traversal ('..') is not allowed.")
	if not FileAccess.file_exists(path):
		return ToolResult.fail("Error: file not found: %s (this tool only edits existing files)." % path)

	var blacklist_error: String = _validate_path_safety_with_allowlist(path)
	if not blacklist_error.is_empty():
		return ToolResult.fail(blacklist_error)

	var extension: String = path.get_extension().to_lower()
	if not EDITABLE_EXTENSIONS.has(extension):
		return ToolResult.fail(
			"Error: '.%s' is not an editable text extension. Supported: %s"
			% [extension, ", ".join(EDITABLE_EXTENSIONS)]
		)

	# --- 读取原始内容 ---
	var read_file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if read_file == null:
		return ToolResult.fail("Error: failed to open file: %d" % FileAccess.get_open_error())
	var raw_text: String = read_file.get_as_text()
	read_file.close()

	# --- 规范化（BOM + 行尾）---
	var has_bom: bool = raw_text.begins_with("\uFEFF")
	var working_text: String = raw_text.trim_prefix("\uFEFF")
	var uses_crlf: bool = working_text.contains("\r\n")
	working_text = working_text.replace("\r\n", "\n")

	# --- 生成新内容 ---
	var new_text: String = working_text
	var applied: Array[String] = []
	var rewrite_value: Variant = p_args.get("rewrite", null)

	if rewrite_value is String:
		var rewrite_text: String = String(rewrite_value).replace("\r\n", "\n")
		if rewrite_text.is_empty():
			return ToolResult.fail("Error: 'rewrite' is empty. Use 'edits' with an empty 'new_string' to delete content.")
		new_text = rewrite_text
		applied.append("rewrite: whole file replaced (%d chars)" % new_text.length())
	else:
		var edits_value: Variant = p_args.get("edits", [])
		if not (edits_value is Array) or (edits_value as Array).is_empty():
			return ToolResult.fail("Error: provide either a non-empty 'edits' array or a non-empty 'rewrite' string.")
		var edit_list: Array = edits_value
		var edit_index: int = 0
		for raw_edit: Variant in edit_list:
			edit_index += 1
			if not (raw_edit is Dictionary):
				return ToolResult.fail("Error: edit #%d is not an object." % edit_index)
			var edit: Dictionary = raw_edit
			var old_string: String = String(edit.get("old_string", "")).replace("\r\n", "\n")
			var new_string: String = String(edit.get("new_string", "")).replace("\r\n", "\n")
			var replace_all: bool = bool(edit.get("replace_all", false))
			if old_string.is_empty():
				return ToolResult.fail("Error: edit #%d has an empty 'old_string'." % edit_index)
			var occurrences: int = new_text.count(old_string)
			if occurrences == 0:
				return ToolResult.fail(
					"Error: edit #%d: 'old_string' not found. No changes were written (file unchanged). "
					% edit_index
					+ "Re-read the file and copy the exact text, including indentation."
				)
			if occurrences > 1 and not replace_all:
				return ToolResult.fail(
					"Error: edit #%d: 'old_string' occurs %d times. " % [edit_index, occurrences]
					+ "Add more surrounding context to make it unique, or pass replace_all = true. "
					+ "No changes were written."
				)
			new_text = new_text.replace(old_string, new_string)
			applied.append(
				"edit #%d: replaced %d occurrence(s) (%d -> %d chars)"
				% [edit_index, occurrences, old_string.length(), new_string.length()]
			)

	if new_text == working_text:
		return ToolResult.ok("No change: content is identical. %s" % path)

	# --- 写回（恢复行尾风格与 BOM）---
	if uses_crlf:
		new_text = new_text.replace("\n", "\r\n")
	if has_bom:
		new_text = "\uFEFF" + new_text

	var write_file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if write_file == null:
		return ToolResult.fail("Error: failed to open file for writing: %d" % FileAccess.get_open_error())
	write_file.store_string(new_text)
	write_file.close()

	ToolBox.update_editor_filesystem(path)

	return ToolResult.ok(
		"Edited %s\n%s\nLine count: %d -> %d"
		% [path, "\n".join(applied), working_text.count("\n") + 1, new_text.count("\n") + 1]
	)


# --- Private Functions ---

# 黑名单校验；EXTRA_WRITE_ALLOWLIST 中的前缀可豁免。
func _validate_path_safety_with_allowlist(p_path: String) -> String:
	var normalized: String = p_path.replace("\\", "/")
	for prefix: String in EXTRA_WRITE_ALLOWLIST:
		if normalized.begins_with(prefix.replace("\\", "/")):
			return ""
	return validate_path_safety(p_path)
