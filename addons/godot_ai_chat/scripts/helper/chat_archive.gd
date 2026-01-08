@tool
class_name ChatArchive
extends RefCounted

## 负责聊天存档的管理，包括列举存档文件和导出为 Markdown 格式。

# --- Constants ---

## 存档目录路径
const ARCHIVE_DIR: String = "res://addons/godot_ai_chat/chat_archives/"

# --- Public Functions ---

## 获取存档目录中所有聊天存档（.tres 文件）的文件名列表
## [return]: 按时间倒序排列的文件名数组
static func get_archive_list() -> Array[String]:
	var _archives: Array[String] = []
	var _dir: DirAccess = DirAccess.open(ARCHIVE_DIR)
	
	if _dir:
		_dir.list_dir_begin()
		var _file_name: String = _dir.get_next()
		
		while _file_name != "":
			if not _dir.current_is_dir() and _file_name.ends_with(".tres"):
				_archives.append(_file_name)
			_file_name = _dir.get_next()
	
	_archives.sort()
	# 让最新的文件排在前面
	_archives.reverse()
	return _archives


## 将聊天消息导出为 Markdown 文件
## [param _messages]: 要导出的消息数组
## [param _file_path]: 目标文件路径
## [return]: 导出是否成功
static func save_to_markdown(_messages: Array[ChatMessage], _file_path: String) -> bool:
	var _md_text: String = ""
	
	for _msg in _messages:
		# 跳过系统消息
		if _msg.role == ChatMessage.ROLE_SYSTEM: 
			continue
		
		# 标题头
		match _msg.role:
			ChatMessage.ROLE_USER:
				_md_text += "### 🧑‍💻 User"
			ChatMessage.ROLE_ASSISTANT:
				_md_text += "### 🤖 AI"
			ChatMessage.ROLE_TOOL:
				_md_text += "### ⚙️ Tool (%s)" % _msg.name
		
		_md_text += "\n\n"
		_md_text += _msg.content
		_md_text += "\n\n---\n\n"
	
	var _file: FileAccess = FileAccess.open(_file_path, FileAccess.WRITE)
	
	if _file:
		_file.store_string(_md_text)
		_file.close()
		ToolBox.refresh_editor_filesystem()
		return true
	else:
		push_error("Failed to export markdown: %s" % FileAccess.get_open_error())
		return false
