@tool
class_name SessionStorage
extends RefCounted

## 聊天存档助手
##
## 负责聊天存档的管理，包括列举存档文件和导出为 Markdown 格式。


# --- Public Functions ---

## 获取存档目录中所有聊天存档（.tres 文件）的文件名列表
## [return]: 按时间倒序排列的文件名数组
static func get_session_list() -> Array[String]:
	var archives: Array[String] = []
	var dir: DirAccess = DirAccess.open(PluginPaths.SESSION_DIR)
	
	if dir:
		dir.list_dir_begin()
		var file_name: String = dir.get_next()
		
		while file_name != "":
			if not dir.current_is_dir() and file_name.ends_with(".tres"):
				archives.append(file_name)
			file_name = dir.get_next()
	
	archives.sort()
	# 让最新的文件排在前面
	archives.reverse()
	return archives


## 将聊天消息导出为 Markdown 文件
## [param p_messages]: 要导出的消息数组
## [param p_file_path]: 目标文件路径
## [return]: 导出是否成功
static func save_to_markdown(p_messages: Array[ChatMessage], p_file_path: String) -> bool:
	var md_text: String = ""
	
	for msg in p_messages:
		# 跳过系统消息
		if msg.role == ChatMessage.ROLE_SYSTEM: 
			continue
		
		# 标题头
		match msg.role:
			ChatMessage.ROLE_USER:
				md_text += "### 🧑‍💻 User"
			ChatMessage.ROLE_ASSISTANT:
				md_text += "### 🤖 AI"
			ChatMessage.ROLE_TOOL:
				md_text += "### ⚙️ Tool (%s)" % msg.name
		
		md_text += "\n\n"
		md_text += msg.content
		md_text += "\n\n---\n\n"
	
	var file: FileAccess = FileAccess.open(p_file_path, FileAccess.WRITE)
	
	if file:
		file.store_string(md_text)
		file.close()
		ToolBox.refresh_editor_filesystem()
		return true
	else:
		AIChatLogger.error("Failed to export markdown: %s" % FileAccess.get_open_error())
		return false
