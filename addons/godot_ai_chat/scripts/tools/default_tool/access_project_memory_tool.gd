@tool
extends AiTool

## 项目记忆管理工具
##
## 这是一个"外挂式大脑"接口。
## 允许 AI 读取 (Recall) 和 写入 (Remember) 项目的长期记忆。

# 锁定的记忆文件路径
const MEMORY_FILE_PATH: String = "res://addons/godot_ai_chat/MEMORY.md"

# 严格的分类映射 (Enum Key -> File Header)
const CATEGORY_MAP = {
	"user_preferences": "👤 用户偏好",
	"project_experience": "📚 项目经验"
}

func _init() -> void:
	tool_name = "access_project_memory"
	tool_description = "Accesses the project's long-term memory."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["read", "add"],
				"description": "The operation to perform."
			},
			"category": {
				"type": "string",
				"enum": ["user_preferences", "project_experience"],
				"description": "Required for 'add'. STRICTLY choose one of these categories."
			},
			"content": {
				"type": "string",
				"description": "Required for 'add'. The content to remember. ONE item at a time. NO newlines allowed."
			}
		},
		"required": ["action"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var action: String = p_args.get("action", "read")
	
	match action:
		"read":
			return _read_memory()
		"add":
			var category_key: String = p_args.get("category", "")
			var content: String = p_args.get("content", "")
			
			if not CATEGORY_MAP.has(category_key):
				return {"success": false, "data": "Error: Invalid category '%s'. Must be 'user_preferences' or 'project_experience'." % category_key}
				
			if content.is_empty():
				return {"success": false, "data": "Error: 'content' is required."}
			
			# [新增] 严格校验：禁止多行文本，强制原子化操作
			if "\n" in content:
				return {
					"success": false, 
					"data": "Error: Newlines detected. You MUST call this tool multiple times to add multiple items. Do NOT combine them."
				}
				
			return _add_memory(CATEGORY_MAP[category_key], content)
		_:
			return {"success": false, "data": "Error: Unknown action '%s'." % action}


func _read_memory() -> Dictionary:
	if not FileAccess.file_exists(MEMORY_FILE_PATH):
		return {"success": false, "data": "Memory file not found. It is empty."}
	
	var file := FileAccess.open(MEMORY_FILE_PATH, FileAccess.READ)
	if not file:
		return {"success": false, "data": "Error: Failed to open memory file."}
	
	return {"success": true, "data": file.get_as_text()}


func _add_memory(p_target_header: String, p_content: String) -> Dictionary:
	var full_text: String = ""
	
	# 1. 读取或初始化
	if FileAccess.file_exists(MEMORY_FILE_PATH):
		var file := FileAccess.open(MEMORY_FILE_PATH, FileAccess.READ)
		if file:
			full_text = file.get_as_text()
			file.close()
	
	# 初始化默认结构
	if full_text.strip_edges().is_empty():
		full_text = "# 🧠 Project Memory\n\n## 👤 用户偏好\n- (Empty)\n\n## 📚 项目经验\n- (Empty)\n"
	
	var lines: PackedStringArray = full_text.split("\n")
	var new_lines: Array[String] = [] 
	for line in lines: new_lines.append(line)
	
	# 2. 定位插入点
	var category_index: int = -1
	var next_category_index: int = -1
	
	for i in range(new_lines.size()):
		var line = new_lines[i].strip_edges()
		if line.begins_with("## "):
			# 精确匹配标题部分 (去掉 "## ")
			if line.substr(3).strip_edges() == p_target_header:
				category_index = i
			elif category_index != -1:
				next_category_index = i
				break
	
	# 3. 执行插入
	var content_line = "- " + p_content
	
	if category_index != -1:
		var insert_pos = next_category_index if next_category_index != -1 else new_lines.size()
		
		# 尝试替换 (Empty) 占位符
		var replaced = false
		for k in range(category_index + 1, insert_pos):
			if new_lines[k].strip_edges() == "- (Empty)":
				new_lines[k] = content_line
				replaced = true
				break
		
		if not replaced:
			# 保持段落间距：如果插入点前是空行，则插在空行前
			if next_category_index != -1 and insert_pos > 0 and new_lines[insert_pos - 1].strip_edges() == "":
				insert_pos -= 1
			new_lines.insert(insert_pos, content_line)
	else:
		# 异常防御：理论上不应发生，因为文件结构是固定的
		# 但如果文件被破坏，则重建该标题
		if not new_lines.is_empty() and not new_lines[-1].strip_edges().is_empty():
			new_lines.append("") 
		new_lines.append("## " + p_target_header)
		new_lines.append(content_line)
	
	# 4. 写回
	var save_file := FileAccess.open(MEMORY_FILE_PATH, FileAccess.WRITE)
	if not save_file:
		return {"success": false, "data": "Error: Failed to write memory file."}
	
	save_file.store_string("\n".join(new_lines))
	save_file.close()
	
	return {"success": true, "data": "Added to '%s'." % p_target_header}
