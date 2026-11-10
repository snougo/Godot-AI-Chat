extends Node

# Root of the wrapper scene the launcher generates.
#
# The probe has two requirements that a plain "add the node to the scene" cannot satisfy at once:
#   - it must outlive scene changes, so it belongs under the tree root
#   - the game must see its own scene as current_scene, or reload_current_scene() and every
#     "am I the current scene" check breaks
#
# So this node assembles exactly that and then disappears:
#   1. adds the probe to the tree root (survives change_scene_to_file)
#   2. instantiates the game scene into the root and makes it current_scene
#   3. frees itself, leaving nothing of its own in the running game
#
# The assembly is DEFERRED on purpose: while the root is propagating _ready it is "busy setting up
# children", and add_child() silently fails there (ERR_FAIL_COND prints but does not stop us). The
# cost is one frame of un-paused game time before the probe takes over.
#
# The scene under test is never modified, project.godot is never touched, no autoload is
# registered. Stop the game and the probe is gone.


# --- @export Vars ---

## res:// path of the scene to run.
@export_file("*.tscn") var game_scene_path: String = ""

## Passed to the probe: an absolute node path, or one relative to the probe.
@export var player_path: NodePath = ^""

## Passed to the probe: seconds of inactivity before it hands pause control back.
@export var auto_release_seconds: float = 3.0


# --- Built-in Functions ---

func _ready() -> void:
	if game_scene_path.is_empty():
		push_error("[AiDebugProbe] host: game_scene_path is empty")
		return

	var packed: PackedScene = load(game_scene_path)
	if packed == null:
		push_error("[AiDebugProbe] host: cannot load %s" % game_scene_path)
		return

	var probe_script: Script = load("res://debug_probe/probe_node.gd")
	if probe_script == null:
		push_error("[AiDebugProbe] host: cannot load the probe script")
		return

	var tree: SceneTree = get_tree()
	var probe: Node = probe_script.new()
	probe.set("player_path", player_path)
	probe.set("auto_release_seconds", auto_release_seconds)
	probe.name = "AiDebugProbe"

	var game: Node = packed.instantiate()
	# Deferred: see the note at the top of this file.
	tree.root.add_child.call_deferred(probe)
	tree.root.add_child.call_deferred(game)
	_finish.call_deferred(tree, game)


# --- Private Functions ---

# Runs on the next idle frame, once the deferred add_child calls have landed.
func _finish(p_tree: SceneTree, p_game: Node) -> void:
	p_tree.current_scene = p_game
	queue_free()
