extends AiTool


func _init():
	name = "get_context"
	description = "Retrieve context information from the Godot project. Use this to read folder structures, script content, scene trees, text-based files and image-meta info."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"context_type": {
				"type": "string",
				"enum": ["folder_structure", "scene_tree", "gdscript", "text-based_file"],
				"description": "The type of context to retrieve."
			},
			"path": {
				"type": "string",
				"description": "The relative path to the file or directory, starting with res://"
			}
		},
		"required": ["context_type", "path"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var context_type = _args.get("context_type")
	var path = _args.get("path")
	
	if not context_type or not path:
		return {"success": false, "data": "Missing parameters: context_type or path"}
	
	match context_type:
		"folder_structure": return _context_provider.get_folder_structure_as_markdown(path)
		"scene_tree": return _context_provider.get_scene_tree_as_markdown(path)
		"gdscript": return _context_provider.get_script_content_as_markdown(path)
		"text-based_file":
			if path.ends_with(".tscn"):
				return {"success": false, "data": "Error: .tscn files contain complex serialization data. Please use 'context_type': 'scene_tree' to analyze scene structures."}
			if path.ends_with(".scn"):
				return {"success": false, "data": "Error: .scn files are binary. They cannot be read as text."}
			return _context_provider.get_text_content_as_markdown(path)
		"image-meta": return _context_provider.get_image_metadata_as_markdown(path)
		_: return {"success": false, "data": "Unknown context_type: %s" % context_type}
