extends RefCounted
class_name ToolExecutor


var context_provider = ContextProvider.new() # ContextProvider为外部上下文工具调用API接口类


#==============================================================================
# ## 公共函数 ##
#==============================================================================

# 从原始的、未解析的工具调用字符串执行工具。
func tool_call_execute(_raw_tool_call: String) -> Dictionary:
	print("[ToolExecutor] Received raw tool call: ", _raw_tool_call)
	var validation: Dictionary = ToolCallUtils.validate_and_parse_tool_call(_raw_tool_call)
	
	if not validation["success"]:
		print("[ToolExecutor] Validation failed. Error type: ", validation["error_type"])
		var error_data: Dictionary = {"call": validation.get("invalid_part", _raw_tool_call)}
		var error_feedback: String = ToolCallUtils.handle_tool_call_error(validation["error_type"], error_data)
		return {"data": error_feedback}
	
	var tool_name: String = validation.tool_name
	var arguments = validation.arguments
	print("[ToolExecutor] Validation successful. Name: '%s', Args: %s" % [tool_name, str(arguments)])
	
	var context_result: Dictionary = _execute_tool_call(tool_name, arguments)
	
	if not context_result["success"]:
		print("[ToolExecutor] Tool execution returned an error. Generating system feedback.")
		var error_feedback: String = ToolCallUtils.handle_tool_call_error("path_not_found", {"path": arguments.get("path", "[unknown path]")})
		return {"data": error_feedback}
	
	print("[ToolExecutor] Tool execution returned success. Data length: ", len(context_result["data"]))
	return {"data": context_result["data"]}


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
			var context_type = _arguments["context_type"]
			var path = _arguments["path"]
			
			# 将语义化的 context_type 映射到具体的 ContextProvider 函数
			match context_type:
				"folder_structure": return context_provider.get_folder_structure_as_markdown(path)
				"scene_tree": return context_provider.get_scene_tree_as_markdown(path)
				"gdscript": return context_provider.get_script_content_as_markdown(path)
				"text-based_file": return context_provider.get_text_content_as_markdown(path)
				"image": return context_provider.get_image_metadata_as_markdown(path)
				_:
					var error_msg = "[ERROR: Unknown context_type '%s']" % context_type
					print("[ToolExecutor] ", error_msg)
					return {"success": false, "data": error_msg}
		_:
			var error_msg: String = "[ERROR: Unknown tool_name '%s']" % _tool_name
			print("[ToolExecutor] ", error_msg)
			return {"success": false, "data": error_msg}
