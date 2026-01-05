@tool
extends RefCounted
class_name ChatArchive

# 存档目录常量
const ARCHIVE_DIR: String = "res://addons/godot_ai_chat/chat_archives/"


# 获取存档目录中所有聊天存档（.tres 文件）的文件名列表
# 被 ChatUI 调用
static func get_archive_list() -> Array:
	var archives: Array = []
	var dir: DirAccess = DirAccess.open(ARCHIVE_DIR)
	
	if dir:
		dir.list_dir_begin()
		var file_name: String = dir.get_next()
		
		while file_name != "":
			if not dir.current_is_dir() and file_name.ends_with(".tres"):
				archives.append(file_name)
			file_name = dir.get_next()
	
	archives.sort()
	# 让最新的文件排在前面通常体验更好
	archives.reverse()
	return archives


# 将聊天消息导出为 Markdown
# 被 ChatHub 调用
# 适配了 Array[ChatMessage]
static func save_to_markdown(messages: Array[ChatMessage], file_path: String) -> bool:
	var md_text: String = ""
	
	for msg in messages:
		# 跳过系统消息 (可选，看你需求)
		if msg.role == ChatMessage.ROLE_SYSTEM: continue
		
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
	
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	
	if file:
		file.store_string(md_text)
		file.close()
		ToolBox.refresh_editor_filesystem()
		return true
	else:
		push_error("Failed to export markdown: %s" % FileAccess.get_open_error())
		return false
