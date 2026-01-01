@tool
extends TextEdit

# 当有数据拖拽到控件上方时，此函数被调用。
func _can_drop_data(_pos, data) -> bool:
	# 检查拖拽的数据类型是否是 "files" (单个文件) 或 "files_and_dirs" (文件夹或多选)。
	var drag_type = data.get("type")
	return drag_type in ["files", "files_and_dirs"]


# 当数据被成功放置到控件上时，此函数被调用。
func _drop_data(_pos, data):
	var dirs: PackedStringArray = data.get("dirs", PackedStringArray())
	var files: PackedStringArray = data.get("files", PackedStringArray())
	
	var all_paths: PackedStringArray = dirs + files
	
	# 遍历所有路径，将它们用换行符隔开，追加到现有文本的末尾
	for path in all_paths:
		# 如果文本框不是空的，且末尾不是换行符，先添加一个换行符作为分隔。
		if not text.is_empty() and not text.ends_with("\n"):
			text += "\n"
		
		text += path
		# 为了确保每个路径都独占一行，我们在添加路径后也追加一个换行符
		text += "\n"
