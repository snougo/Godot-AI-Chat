extends RefCounted
class_name ToolExecutor


var context_provider = ContextProvider.new() # ContextProvider为外部上下文工具调用API接口类


#==============================================================================
# ## 公共函数 ##
#==============================================================================

# 从一个已经解析好的工具调用字典执行工具。
# 这是该类的主要入口点。
func tool_call_execute_parsed(_parsed_call: Dictionary) -> String:
	var tool_name = _parsed_call.get("tool_name")
	var arguments = _parsed_call.get("arguments")
	
	# 添加一些健壮性检查
	if not tool_name is String or not arguments is Dictionary:
		var error_msg = "[ERROR: Invalid parsed call structure]"
		push_error(error_msg)
		return error_msg
	
	print("[ToolExecutor] Executing parsed call. Name: '%s', Args: %s" % [tool_name, str(arguments)])
	var context_result: Dictionary = _execute_tool_call(tool_name, arguments)
	
	# 确保总是返回字符串
	if context_result.has("data") and context_result.data is String:
		return context_result.data
	else:
		var error_msg: String = "[ERROR: Tool execution result was not a string]"
		push_error(error_msg)
		return error_msg


#==============================================================================
# ## 内部函数 ##
#==============================================================================

# 根据工具名称和参数，分派并执行具体的工具逻辑。
func _execute_tool_call(_tool_name: String, _arguments: Dictionary) -> Dictionary:
	match _tool_name:
		"get_context":
			var context_type = _arguments.get("context_type")
			var path = _arguments.get("path")
			
			# 健壮性检查：确保必要参数存在
			if not context_type or not path:
				var feedback = ToolCallUtils.handle_tool_call_error("missing_parameters", {"tool_name": _tool_name})
				return {"success": false, "data": feedback}
			
			# 将语义化的 context_type 映射到具体的 ContextProvider 函数
			match context_type:
				"folder_structure": return context_provider.get_folder_structure_as_markdown(path)
				"scene_tree": return context_provider.get_scene_tree_as_markdown(path)
				"gdscript": return context_provider.get_script_content_as_markdown(path)
				"text-based_file": return context_provider.get_text_content_as_markdown(path)
				"image-meta": return context_provider.get_image_metadata_as_markdown(path)
				_:
					var feedback = ToolCallUtils.handle_tool_call_error("unknown_context_type", {"context_type": context_type})
					return {"success": false, "data": feedback}
		_:
			var feedback = ToolCallUtils.handle_tool_call_error("unknown_tool", {"tool_name": _tool_name})
			return {"success": false, "data": feedback}
