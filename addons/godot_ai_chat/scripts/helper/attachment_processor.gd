extends RefCounted

# 附件处理器
# 负责解析和处理用户输入中的图片附件。


# --- Public Functions ---

# 处理输入文本，提取附件
# [return]: 包含 final_text, images(Array[Dictionary]) 的字典
static func process_input(p_raw_text: String) -> Dictionary:
	var result: Dictionary = {
		"final_text": p_raw_text,
		"images": [] # [{"data": ..., "mime": ...}]
	}
	
	var lines: PackedStringArray = p_raw_text.split("\n")
	var processed_lines: Array[String] = []
	
	for line in lines:
		var trimmed: String = line.strip_edges()
		if trimmed.begins_with("res://"):
			var ext: String = trimmed.get_extension().to_lower()
			
			# 1. 处理图片 (支持多张)
			if ext in ["png", "jpg", "jpeg"]:
				var img_info: Dictionary = _load_image(trimmed)
				if not img_info.is_empty():
					result.images.append(img_info)
					continue # 路径已提取，不保留在文本
		
		processed_lines.append(line)
	
	result.final_text = "\n".join(processed_lines)
	return result


# --- Private Functions ---

# 加载图片文件
static func _load_image(p_path: String) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {}
	
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if not file:
		return {}
	
	var buffer: PackedByteArray = file.get_buffer(file.get_length())
	var mime: String = "image/png"
	if p_path.ends_with(".jpg") or p_path.ends_with(".jpeg"):
		mime = "image/jpeg"
	elif p_path.ends_with(".webp"):
		mime = "image/webp"
	
	return {"data": buffer, "mime": mime}
