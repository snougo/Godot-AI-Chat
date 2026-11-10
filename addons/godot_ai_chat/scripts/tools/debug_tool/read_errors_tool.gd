extends AiTool

# 读取 Debugger Errors 标签页与 Stack Trace 标签页的 reason 横幅——运行时错误史，以及脚本解析错误的唯一落点。


const EditorConsoleReader := preload("res://addons/godot_ai_chat/scripts/helper/editor_console_reader.gd")


func _init() -> void:
	tool_name = "read_errors"
	tool_description = "Read the Debugger panel — the error and warning history of game runtime, plus the Stack Trace tab's reason banner. A script parse error never reaches the Output panel: while the game is paused on it only the banner holds it, and it enters the Errors list only after execution continues — so read both."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"limit": {
				"type": "integer",
				"description": "Newest error entries to return. Defaults to 10 with no cap."
			},
			"filter": {
				"type": "string",
				"description": "Optional case-insensitive substring; only entries whose text (time, message, or detail) contains it are returned."
			}
		},
		"required": []
	}


func execute(p_args: Dictionary) -> ToolResult:
	var limit: int = int(p_args.get("limit", 0))
	var filter: String = str(p_args.get("filter", ""))
	return ToolResult.ok(EditorConsoleReader.read_errors(limit, filter))
