extends Resource
class_name PluginLongTermMemory

# 用于存储已获取的文件夹上下文
# Key: String (文件夹路径)
# Value: String (Markdown格式的文件夹结构)
@export var folder_context_memory: Dictionary = {}

# 未来可以扩展其他类型的记忆
# @export var code_snippet_memory: Dictionary = {}
# @export var scene_tree_memory: Dictionary = {}
