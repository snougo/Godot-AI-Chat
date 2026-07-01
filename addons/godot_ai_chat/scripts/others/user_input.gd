@tool
class_name ChatUserInput
extends TextEdit

## 用户输入框扩展
##
## 扩展 TextEdit 以支持文件和文件夹的拖放功能，自动将拖入的路径追加到文本末尾。
## 在 _input() 中清除字母/数字/空格键的 keycode，使编辑器无法匹配快捷键。
## TextEdit 仍通过 unicode（英文）或 TextServer IME（中文）正常处理文本输入。


# --- Built-in Functions ---

func _input(event: InputEvent) -> void:
	# 在反向深度优先遍历中，本节点先于 SceneTreeDock 等编辑器节点收到事件。
	# 清除全部键标识符使编辑器无法匹配任何快捷键。
	if event is InputEventKey and event.pressed:
		if not event.is_echo() and has_focus() and Engine.is_editor_hint():
			if not event.ctrl_pressed and not event.alt_pressed and not event.meta_pressed:
				match event.keycode:
					KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F, KEY_G, \
					KEY_H, KEY_I, KEY_J, KEY_K, KEY_L, KEY_M, KEY_N, \
					KEY_O, KEY_P, KEY_Q, KEY_R, KEY_S, KEY_T, KEY_U, \
					KEY_V, KEY_W, KEY_X, KEY_Y, KEY_Z, \
					KEY_0, KEY_1, KEY_2, KEY_3, KEY_4, \
					KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, \
					KEY_SPACE:
						# 编辑器按 keycode → physical_keycode → unicode 优先级匹配快捷键
						# 三个全清掉，编辑器彻底无法匹配
						event.keycode = KEY_NONE
						event.physical_keycode = KEY_NONE
						event.key_label = KEY_NONE
						# unicode 保持不变 → TextEdit 正常插入字符


## [Virtual] 检查是否可以放置拖拽数据
## [param _at_position]: 拖拽位置 (未使用)
## [param data]: 拖拽数据
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	
	# 检查拖拽的数据类型是否是 "files" (单个文件) 或 "files_and_dirs" (文件夹或多选)。
	var drag_type: String = data.get("type", "")
	return drag_type in ["files", "files_and_dirs"]


## [Virtual] 处理放置数据
## [param _at_position]: 拖拽位置 (未使用)
## [param data]: 拖拽数据
func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	
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
