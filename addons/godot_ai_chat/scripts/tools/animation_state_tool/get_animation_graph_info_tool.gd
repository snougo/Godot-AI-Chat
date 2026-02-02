@tool
extends AiTool


func _init() -> void:
	tool_name = "get_animation_graph_info"
	tool_description = "Returns a text summary of the StateMachine (Nodes & Transitions)."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_path": { "type": "string" }
		},
		"required": ["file_path"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var path = p_args.get("file_path", "")
	var sm = ResourceLoader.load(path, "AnimationNodeStateMachine", ResourceLoader.CACHE_MODE_REUSE) as AnimationNodeStateMachine
	if not sm: return {"success": false, "data": "Resource not found."}
	
	var lines = []
	lines.append("=== Nodes (%d) ===" % sm.get_node_list().size())
	for n in sm.get_node_list():
		var node = sm.get_node(n)
		var extra = ""
		if node is AnimationNodeAnimation: extra = " -> " + node.animation
		lines.append("- [%s]%s" % [n, extra])
	
	lines.append("\n=== Transitions (%d) ===" % sm.get_transition_count())
	for i in range(sm.get_transition_count()):
		var from = sm.get_transition_from(i)
		var to = sm.get_transition_to(i)
		var tr = sm.get_transition(i)
		var info = []
		if tr.switch_mode == 1: info.append("Sync")
		elif tr.switch_mode == 2: info.append("AtEnd")
		if tr.advance_mode == 1: info.append("Auto")
		if tr.xfade_time > 0: info.append("XFade:%.2fs" % tr.xfade_time)
		if not tr.advance_condition.is_empty(): info.append("Cond:" + tr.advance_condition)
		
		lines.append("- %s -> %s  (%s)" % [from, to, ", ".join(info)])
	
	return {"success": true, "data": "\n".join(lines)}
