extends AiTool

# 读取编辑器 Output 控制台（底部输出面板）——用户正在看的日志，包括运行中游戏的 print 和错误。


const EditorConsoleReader := preload("res://addons/godot_ai_chat/scripts/helper/editor_console_reader.gd")


func _init() -> void:
	tool_name = "read_output"
	tool_description = "Read messages from Editor's Output Panel. NOTE: messages from push_error() and push_warning() never appear here."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"type": {
				"type": "string",
				"enum": ["print", "issue"],
				"description": "Required. \"print\" returns ordinary messages only (without an ERROR/WARNING messages); \"issue\" returns ERROR and WARNING messages"
			},
			"lines": {
				"type": "integer",
				"description": "Newest lines of the selected kind to return. Defaults to 40 with no cap — raise it freely when you need more of the log."
			},
			"filter": {
				"type": "string",
				"description": "Optional case-insensitive substring; only lines containing it are returned (the newest of those)."
			}
		},
		"required": ["type"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var raw_type: String = str(p_args.get("type", ""))
	var kind: String = EditorConsoleReader.normalize_message_type(raw_type)
	
	if kind == "":
		if raw_type.strip_edges() == "":
			return ToolResult.fail("read_output: \"type\" is required — pass \"print\" (ordinary output) or \"issue\" (errors + warnings).")
		return ToolResult.fail("read_output: unknown \"type\" value \"%s\" — use \"print\" or \"issue\"." % raw_type)
	
	var lines: int = int(p_args.get("lines", 0))
	var filter: String = str(p_args.get("filter", ""))
	
	return ToolResult.ok(EditorConsoleReader.read_output(lines, filter, kind))
