@tool
class_name ChatUserInput
extends TextEdit

## 用户输入框扩展
##
## 扩展 TextEdit 以支持文件和文件夹的拖放功能，自动将拖入的路径追加到文本末尾。

# --- Built-in Functions ---

## [Virtual] 检查是否可以放置拖拽数据
## [param _at_position]: 拖拽位置 (未使用)
## [param p_data]: 拖拽数据
func _can_drop_data(_at_position: Vector2, p_data: Variant) -> bool:
	if typeof(p_data) != TYPE_DICTIONARY:
		return false
	
	# 检查拖拽的数据类型是否是 "files" (单个文件) 或 "files_and_dirs" (文件夹或多选)。
	var drag_type: String = p_data.get("type", "")
	return drag_type in ["files", "files_and_dirs"]


## [Virtual] 处理放置数据
## [param _at_position]: 拖拽位置 (未使用)
## [param p_data]: 拖拽数据
func _drop_data(_at_position: Vector2, p_data: Variant) -> void:
	if typeof(p_data) != TYPE_DICTIONARY:
		return

	var dirs: PackedStringArray = p_data.get("dirs", PackedStringArray())
	var files: PackedStringArray = p_data.get("files", PackedStringArray())
	
	var all_paths: PackedStringArray = dirs + files
	
	# 遍历所有路径，将它们用换行符隔开，追加到现有文本的末尾
	for path in all_paths:
		# 如果文本框不是空的，且末尾不是换行符，先添加一个换行符作为分隔。
		if not text.is_empty() and not text.ends_with("\n"):
			text += "\n"
		
		text += path
		# 为了确保每个路径都独占一行，我们在添加路径后也追加一个换行符
		text += "\n"
