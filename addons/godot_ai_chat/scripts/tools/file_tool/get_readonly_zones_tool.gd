extends AiTool

# 管控区查询工具。
# 返回当前生效的写入管控配置：禁写的路径片断、显式豁免前缀、可改写的文本扩展名。
# 说明：本类为 RefCounted 工具，仅通过 new() 实例化，故无需 @tool。


# --- Constants ---

# .md 文档豁免说明（对应 create_document_file 的实现：完全不经过路径关卡）
const DOCUMENT_TOOL_EXEMPTION: String = "`create_document_file` (`.md` only) skips the read-only zones entirely — it only validates the `res://` prefix, path traversal and that the target folder exists."


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "get_readonly_zones"
	tool_description = "Lists the paths where write operations are denied (read-only zones), the configured write exceptions, and the text extensions that may be edited. These zones block writes only — reading them with any tool is unaffected."


# --- Public Functions ---

## 获取工具参数的 JSON Schema（无参数）
func get_parameters_schema() -> Dictionary:
	return {"type": "object", "properties": {}}


func execute(_p_args: Dictionary) -> ToolResult:
	var config: ReadonlyZoneConfig = ReadonlyZoneConfig.get_config()
	var md: String = "Read-only zones: write operations on these paths are denied. Reading them is unaffected.\n\n"
	
	# --- 管控区片断 ---
	md += "## Read-only zones\n\n"
	if config.readonly_patterns.is_empty():
		md += "None configured — every `res://` path can be written.\n\n"
	else:
		md += "Path-fragment matching: the fragment is looked up anywhere in the target path, so a matched folder name is banned at any depth.\n\n"
		for raw_pattern: String in config.readonly_patterns:
			var pattern: String = raw_pattern.strip_edges()
			if pattern.is_empty():
				continue
			md += "- `%s`\n" % pattern
		md += "\n"
	
	# --- 写操作例外 ---
	md += "## Write exceptions\n\n"
	md += "- %s\n" % DOCUMENT_TOOL_EXEMPTION
	if config.extra_write_allowlist.is_empty():
		md += "- No extra allowed prefixes — every path matching a read-only zone above stays denied.\n\n"
	else:
		md += "- Allowed prefixes (full `res://` prefix matching, bypasses the zones above; extension limits still apply):\n"
		for raw_prefix: String in config.extra_write_allowlist:
			var prefix: String = raw_prefix.strip_edges()
			if prefix.is_empty():
				continue
			md += "  - `%s`\n" % prefix
		md += "\n"
	
	# --- 可改写格式 ---
	md += "## Editable text extensions (`edit_file`)\n\n"
	var extensions_text: String = config.get_editable_extensions_text()
	if extensions_text.is_empty():
		md += "None configured — `edit_file` rejects every file.\n"
	else:
		md += "%s\n" % extensions_text
	
	md += "\nSource of truth: `%s` — a human edits that resource to change these lists." % PluginPaths.READONLY_ZONE_CONFIG_PATH
	return ToolResult.ok(md)
