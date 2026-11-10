extends RefCounted

# Watch "pose": the player's position, facing, motion and ground contact, plus the camera's facing
# when the scene has one.
#
# The camera matters because the common first-person rig turns the camera and never rotates the
# body: the body yaw alone cannot tell where the player is looking.
#
# The motion fields are the answer to "is walking broken, or was it merely blocked": `velocity` is
# what the script asked for, `real_velocity` is what the body actually did, and `hits` / `on_wall`
# say whether something was in the way. Who blocked it lives in the "contacts" observer.
#
# Capability contract (duck typed, no base class): key() / collect().

# --- Constants ---

const Frame := preload("res://debug_probe/core/frame.gd")
const PlayerFinder := preload("res://debug_probe/core/player_finder.gd")

# --- Private Vars ---

var _last_player: String = ""
var _last_pos: Variant = null
var _last_frame: int = -1
var _last_unit: String = ""
var _last_moved: Variant = null
var _last_moved_frames: int = 0

# --- Public Functions ---

func key() -> String:
	return "pose"


func collect(p_context) -> Variant:
	var player: Node = PlayerFinder.find(p_context)
	if player == null:
		return {"player": null}
	var d: Dictionary = {"player": str(player.get_path()), "class": player.get_class()}
	if player is Node3D:
		var pos3: Vector3 = player.global_position
		d.pos = Frame.vec3(pos3)
		# The body's yaw: often 0 in an FPS rig, so camera.yaw is the one to read there.
		d.yaw = Frame.n(rad_to_deg(player.global_rotation.y), 0.1)
		d.camera = _camera(p_context)
		_note_move(p_context, d, pos3)
	elif player is Node2D:
		var pos2: Vector2 = player.global_position
		d.pos = Frame.vec2(pos2)
		d.rot = Frame.n(rad_to_deg(player.global_rotation), 0.1)
		_note_move(p_context, d, pos2)
	if player is CharacterBody3D:
		var body: CharacterBody3D = player
		d.velocity = Frame.vec3(body.velocity)
		d.real_velocity = Frame.vec3(body.get_real_velocity())
		d.on_floor = body.is_on_floor()
		d.on_wall = body.is_on_wall()
		d.on_ceiling = body.is_on_ceiling()
		d.hits = body.get_slide_collision_count()
		if body.is_on_wall():
			d.wall_normal = Frame.vec3(body.get_wall_normal())
	elif player is CharacterBody2D:
		var body2: CharacterBody2D = player
		d.velocity = Frame.vec2(body2.velocity)
		d.real_velocity = Frame.vec2(body2.get_real_velocity())
		d.on_floor = body2.is_on_floor()
		d.on_wall = body2.is_on_wall()
		d.on_ceiling = body2.is_on_ceiling()
		d.hits = body2.get_slide_collision_count()
		if body2.is_on_wall():
			d.wall_normal = Frame.vec2(body2.get_wall_normal())
	return d

# --- Private Functions ---

# How far the body actually went since the previous sample, and over how many frames. This is the
# number that separates the three situations a bare position sample cannot tell apart: the walk is
# broken (moved 0, nothing in the way), the walk was blocked (moved 0, hits > 0), and the walk was
# never asked for (moved 0, no input).
#
# velocity cannot answer this: move_and_slide() rewrites it in place, so a body pressed against a
# wall reports velocity 0 exactly like a body nobody is pushing.
func _note_move(p_context, p_data: Dictionary, p_pos: Variant) -> void:
	var path: String = str(p_data.get("player", ""))
	var frame: int = p_context.frame_now()
	var unit: String = p_context.frame_unit
	# A different unit means a different counter: physics frames and render frames are two separate
	# clocks, so a step measured across them would be meaningless (and used to come out negative).
	if _last_pos == null or _last_player != path or _last_unit != unit:
		_last_player = path
		_last_pos = p_pos
		_last_frame = frame
		_last_unit = unit
		_last_moved = null
		_last_moved_frames = 0
		return
	if frame == _last_frame:
		# A second collect inside the same frame (a "check" that reads pose) reuses the answer the
		# sample already produced; otherwise it would consume the reference point and report a
		# zero-length step for a frame that did move.
		if _last_moved != null:
			p_data.moved = _last_moved
			p_data.moved_frames = _last_moved_frames
		return
	var moved: Variant = p_pos - _last_pos
	_last_moved = Frame.vec3(moved) if moved is Vector3 else Frame.vec2(moved)
	_last_moved_frames = frame - _last_frame
	p_data.moved = _last_moved
	p_data.moved_frames = _last_moved_frames
	_last_player = path
	_last_pos = p_pos
	_last_frame = frame


func _camera(p_context) -> Dictionary:
	var cam: Camera3D = p_context.viewport().get_camera_3d()
	if cam == null:
		return {}
	var forward: Vector3 = -cam.global_transform.basis.z
	return {
		"path": str(cam.get_path()),
		"yaw": Frame.n(rad_to_deg(atan2(forward.x, -forward.z)), 0.1),
		"pitch": Frame.n(rad_to_deg(asin(clampf(forward.y, -1.0, 1.0))), 0.1),
		"forward": Frame.vec3(forward),
	}
