extends RefCounted

# Watch "scene": which scene is running and whether the tree is paused or slowed.
#
# Capability contract (duck typed, no base class): key() / collect().

# --- Public Functions ---

func key() -> String:
	return "scene"


func collect(p_context) -> Variant:
	var scene: Node = p_context.tree().current_scene
	return {
		"scene": scene.scene_file_path if scene != null else "",
		"paused": p_context.tree().paused,
		"time_scale": Engine.time_scale,
	}
