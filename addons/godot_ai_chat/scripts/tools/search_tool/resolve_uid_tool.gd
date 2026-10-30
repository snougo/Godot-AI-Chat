extends AiTool

## 将资源 UID（uid://xxx）反向解析为项目内的具体文件路径。
## 适用于已知某个资源引用中的 UID，需要定位其对应文件的场景。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "resolve_uid"
	tool_description = "Resolves a single resource UID to its file path within the project."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"uid": {
				"type": "string",
				"description": "The resource UID to resolve."
			}
		},
		"required": ["uid"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var uid_text: String = String(p_args.get("uid", "")).strip_edges()
	if uid_text.is_empty():
		return ToolResult.fail("Error: 'uid' parameter is required.")
	
	# 容错：允许省略 "uid://" 前缀
	if not uid_text.begins_with("uid://"):
		uid_text = "uid://" + uid_text
	
	var uid_id: int = ResourceUID.text_to_id(uid_text)
	if uid_id == ResourceUID.INVALID_ID:
		return ToolResult.fail("Error: Invalid UID: '%s'." % uid_text)
	
	if not ResourceUID.has_id(uid_id):
		return ToolResult.fail("Error: UID not found in the resource cache: '%s'." % uid_text)
	
	var file_path: String = ResourceUID.get_id_path(uid_id)
	if file_path.is_empty():
		return ToolResult.fail("Error: No file path is mapped to UID '%s'." % uid_text)
	
	if not FileAccess.file_exists(file_path):
		return ToolResult.fail("Error: UID '%s' maps to '%s', but the file does not exist." % [uid_text, file_path], {"path": file_path})
	
	return ToolResult.ok("%s -> %s" % [uid_text, file_path], {"path": file_path})
