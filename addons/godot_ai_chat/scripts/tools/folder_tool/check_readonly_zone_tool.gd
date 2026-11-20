extends AiTool

# 管控区检查工具。
# 传入一个 res:// 路径（通常是当前工作区），返回该路径是否落在管控区内，
# 并附带命中的片断与仍可绕过的写入例外，供 AI 在写操作前自行判断。
# 说明：本类为 RefCounted 工具，仅通过 new() 实例化，故无需 @tool。


# --- Constants ---

# .md 文档豁免说明（对应 create_document_file 的实现：完全不经过路径关卡）
const DOCUMENT_TOOL_EXEMPTION: String = "`create_document_file` and `edit_markdown` (`.md` only) skips the read-only zones entirely — it only validates the `res://` prefix, path traversal and that the target folder exists."


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "check_readonly_zone"
	tool_description = "Checks whether a path is inside a read-only zone where writes are denied. Pass the current workspace path to learn whether you may write into the workspace. When the path is blocked, the result also lists the write exceptions that can still bypass the block."


# --- Public Functions ---

# 获取工具参数的 JSON Schema（path 为必填参数）
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Required. The path to check, must start with 'res://'. Pass the current workspace path to check whether the workspace is read-only."
			}
		},
		"required": ["path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var path: String = str(p_args.get("path", "")).strip_edges()
	if path.is_empty():
		return ToolResult.fail("Error: 'path' is required. Pass the path to check, e.g. the current workspace path.")
	if not path.begins_with("res://"):
		return ToolResult.fail("Error: 'path' must start with 'res://'. Got: '%s'" % path)
	
	var config: ReadonlyZoneConfig = ReadonlyZoneConfig.get_config()
	var blocked_pattern: String = config.get_blocked_pattern(path)
	var is_blocked: bool = not blocked_pattern.is_empty()
	
	var md: String = ""
	if is_blocked:
		md += "## `%s` is a read-only zone\n\n" % path
		md += "- Verdict: **writes are DENIED** on this path. Reading it is unaffected.\n"
		md += "- Matched zone fragment: `%s`\n" % blocked_pattern
		md += "- Matching rule: the fragment is looked up anywhere in the path, so a matched folder name is blocked at any depth.\n\n"
		md += "### Write exceptions that still bypass this block\n\n"
		md += _build_exception_lines(config)
	else:
		md += "## `%s` is writable\n\n" % path
		md += "- Verdict: **writes are ALLOWED** — no read-only zone fragment matched this path.\n"
		md += "- Note: the extension limit below still applies when editing an existing text file.\n\n"
		md += "### Editable text extensions (`edit_file`)\n\n"
		var extensions_text: String = config.get_editable_extensions_text()
		if extensions_text.is_empty():
			md += "None configured — `edit_file` rejects every file.\n"
		else:
			md += "%s\n" % extensions_text
	
	md += "\nSource of truth: `%s` — a human edits that resource to change these lists." % PluginPaths.READONLY_ZONE_CONFIG_PATH
	return ToolResult.ok(md)


# --- Private Functions ---

# 组装「写操作例外」段落：.md 文档豁免 + 显式豁免前缀
func _build_exception_lines(p_config: ReadonlyZoneConfig) -> String:
	var lines: String = "- %s\n" % DOCUMENT_TOOL_EXEMPTION
	
	if p_config.extra_write_allowlist.is_empty():
		lines += "- No extra allowed prefixes — every path matching the zone fragment above stays denied.\n"
		return lines
	
	lines += "- Allowed prefixes (full `res://` prefix matching, bypasses the zones above; extension limits still apply):\n"
	for raw_prefix: String in p_config.extra_write_allowlist:
		var prefix: String = raw_prefix.strip_edges()
		if prefix.is_empty():
			continue
		lines += "  - `%s`\n" % prefix
	
	return lines
