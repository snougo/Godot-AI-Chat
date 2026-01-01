extends AiTool


func _init():
	name = "get_context"
	description = "Retrieve context information from the Godot project. Use this to read folder structures, script content, scene trees, or text-based files."


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


func execute(args: Dictionary, context_provider: ContextProvider) -> Dictionary:
	var context_type = args.get("context_type")
	var path = args.get("path")
	
	if not context_type or not path:
		return {"success": false, "data": "Missing parameters: context_type or path"}
		
	match context_type:
		"folder_structure": return context_provider.get_folder_structure_as_markdown(path)
		"scene_tree": return context_provider.get_scene_tree_as_markdown(path)
		"gdscript": return context_provider.get_script_content_as_markdown(path)
		"text-based_file": return context_provider.get_text_content_as_markdown(path)
		"image-meta": return context_provider.get_image_metadata_as_markdown(path)
		_: return {"success": false, "data": "Unknown context_type: %s" % context_type}
