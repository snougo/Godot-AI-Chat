@tool
extends AiTool
class_name BaseScriptTool

# 默认允许的扩展名白名单，子类可以按需覆盖或直接使用
const DEFAULT_ALLOWED_EXTENSIONS = ["gd", "gdshader"]

# 统一的文件扩展名检查函数
# path: 文件路径
# allowed_extensions: 允许的小写扩展名数组。如果为 null，则使用默认列表。
# 返回: 错误信息字符串，空字符串表示通过
func validate_file_extension(path: String, allowed_extensions: Array = []) -> String:
	if allowed_extensions.is_empty():
		allowed_extensions = DEFAULT_ALLOWED_EXTENSIONS
	
	var extension: String = path.get_extension().to_lower()
	if extension not in allowed_extensions:
		return "Error: File extension '%s' is not allowed. Allowed extensions: %s" % [extension, str(allowed_extensions)]
	
	return ""
