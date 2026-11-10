extends AiTool

# Launches a scene with the AI Debug Probe injected, without touching the project.
#
# DEPENDS ON: the AI Debug Probe module at res://debug_probe/ (game side).
# host/host.gd and host/host.tscn; this tool only bakes the scene path into that host scene and
# plays it. The scene under test keeps its file untouched, project.godot is untouched, no autoload
# is registered, and no node needs to be placed by hand.
#
# Takes effect only in the editor.


# --- Constants ---

const MODULE_DIR: String = "res://debug_probe"
const HOST_SCENE_PATH: String = "res://debug_probe/host/host.tscn"
const HOST_SCRIPT_PATH: String = "res://debug_probe/host/host.gd"
const ChannelScript := preload("res://debug_probe/probe_channel.gd")

# How long to wait for the game to hand its capabilities over. Startup includes loading the first
# scene, so a heavy project can take a few seconds.
const HELLO_TIMEOUT_SECONDS: float = 15.0


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "debug_launch"
	tool_description = "Run a scene with the Debug Probe injected, Use `debug_probe_step` afterwards to drive it frame by frame, Using `stop_game` to stop game."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"scene_path": {
				"type": "string",
				"description": "res:// path of the scene to run."
			},
			"player_path": {
				"type": "string",
				"description": "Optional node the probe should report as the player: an absolute path, or one relative to the probe at the tree root (e.g. \"/root/Game/Player\"). Empty: the \"player\" group, then the first CharacterBody in the scene."
			},
			"auto_release_seconds": {
				"type": "number",
				"description": "Seconds without a request before the probe hands pause control back, counted from launch. Once a step request arrives the probe keeps pause control until the game stops. 0 disables auto release.",
				"default": 3.0
			}
		},
		"required": ["scene_path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Error: editor only tool.")
	if not ResourceLoader.exists(HOST_SCENE_PATH):
		return ToolResult.fail("Error: the AI Debug Probe module is missing: %s not found." % HOST_SCENE_PATH)

	var scene_path: String = str(p_args.get("scene_path", ""))
	if scene_path.is_empty():
		return ToolResult.fail("Error: 'scene_path' is required.")
	var safety: String = validate_path_safety(scene_path)
	if not safety.is_empty():
		return ToolResult.fail(safety)
	if not ResourceLoader.exists(scene_path):
		return ToolResult.fail("Error: scene not found: %s" % scene_path)

	var err: int = _write_host(
		scene_path,
		str(p_args.get("player_path", "")),
		float(p_args.get("auto_release_seconds", 3.0))
	)
	if err != OK:
		return ToolResult.fail("Error: cannot write the host scene (%s). Is %s writable?" % [error_string(err), MODULE_DIR])

	# Only a hello arriving AFTER this moment belongs to the game we are about to start: session ids
	# are reused across runs, and a previous game may still be alive for a moment.
	var channel: Variant = ChannelScript.instance
	var launched_at: int = Time.get_ticks_msec()

	EditorInterface.play_custom_scene(HOST_SCENE_PATH)
	# play_custom_scene is asynchronous: without this wait the first ai_debug_probe_step would answer
	# "no running game" for a game that is in fact still starting up.
	if channel == null:
		return ToolResult.ok("Launched `%s`, but the probe channel is not registered, so the game cannot be driven. Check that godot_ai_chat is enabled." % scene_path)
	var hello: Dictionary = await channel.await_hello(launched_at, HELLO_TIMEOUT_SECONDS)
	if hello.is_empty():
		return ToolResult.ok("Launched `%s`, but no probe handshake arrived within %s s. The game may still be loading, or it failed to start: check read_output, then call ai_debug_probe_step once it is up." % [scene_path, str(HELLO_TIMEOUT_SECONDS)])
	return ToolResult.ok("Launched with the probe injected: `%s`\nProbe version %s supports plan keys %s and watch keys %s.\nThe probe is under /root; call ai_debug_probe_step to drive it." % [
		scene_path,
		str(hello.get("version", "unknown")),
		str(hello.get("inputs", [])),
		str(hello.get("observes", [])),
	])

# --- Private Functions ---

# Rebuilds the host scene with the given settings and saves it over the existing file, so Godot
# never has to rescan: the file is already part of the project.
func _write_host(p_scene_path: String, p_player_path: String, p_auto_release: float) -> int:
	var host_script: Script = load(HOST_SCRIPT_PATH)
	if host_script == null:
		return ERR_CANT_OPEN

	var root := Node.new()
	root.name = "ProbeHost"
	root.set_script(host_script)
	root.set("game_scene_path", p_scene_path)
	root.set("player_path", NodePath(p_player_path))
	root.set("auto_release_seconds", p_auto_release)

	var packed := PackedScene.new()
	var pack_err := packed.pack(root)
	root.free()
	if pack_err != OK:
		return pack_err

	return ResourceSaver.save(packed, HOST_SCENE_PATH)
