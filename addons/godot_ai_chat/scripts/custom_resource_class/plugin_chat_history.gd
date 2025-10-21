extends Resource
class_name PluginChatHistory

# 该脚本定义了一个自定义资源（Resource），用于持久化存储单次聊天会话的历史记录。
# 通过继承 Resource，Godot 引擎能够轻松地将其序列化并保存为 .tres 文件。
# 这使得加载和保存聊天记录变得非常方便。

# 存储聊天消息的核心数组。
@export var messages: Array = []
