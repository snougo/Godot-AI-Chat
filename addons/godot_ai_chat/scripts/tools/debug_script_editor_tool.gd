@tool
extends AiTool

func _init() -> void:
	tool_name = "debug_script_editor"
	tool_description = "Debug tool to inspect ScriptEditor state."

func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var script_editor = EditorInterface.get_script_editor()
	var open_editors = script_editor.get_open_script_editors()
	
	var result = []
	
	for editor in open_editors:
		var info = {
			"class": editor.get_class(),
			"name": editor.name,
			"metadata": {}
		}
		
		# 尝试获取关联的资源或文件路径
		# ScriptEditorBase 没有公开的 get_edited_resource()，我们需要根据元数据或特定属性来猜
		
		# 尝试获取 base_editor (通常是 CodeEdit)
		var base_editor = editor.get_base_editor()
		if base_editor:
			info["base_editor_class"] = base_editor.get_class()
			
		# 很多时候编辑器会把路径存在 metadata 里
		if editor.has_meta("_edit_res_path"):
			info["metadata"]["_edit_res_path"] = editor.get_meta("_edit_res_path")
			
		result.append(info)
		
	return {"success": true, "data": result}
