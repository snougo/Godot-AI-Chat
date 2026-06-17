class_name PopupCodeViewWindow
extends AcceptDialog

## 独立代码查看器窗口

@export var popup_code_edit: CodeEdit


func _ready() -> void:
	if not popup_code_edit:
		popup_code_edit = $MarginContainer/VBoxContainer/CodeEdit
