extends KinematicBody

const METERS_PER_STEP = 0.7
var _debug_steps_per_sec = 0
var _target_steps_per_sec = 0.0
var _curr_steps_per_sec = 0.0

var _elapsed = 0.0
var _distance = 0.0

var current_path: Path = null setget _set_current_path

# A list of [timestamp, magnitude] half steps taken in the last
# second.
var half_steps = CircularBuffer.new()

onready var _follow = $PathFollow

onready var _pivot = $Pivot
onready var _eye_camera = $Pivot/Eye/EyeCamera
onready var _third_person_camera = $Pivot/ThirdPersonCamera
onready var _mph_label = $Control/Panel/MphLabel
onready var _steps_label = $Control/Panel/StepsLabel
onready var _mph_label_format = _mph_label.text
onready var _steps_label_format = _steps_label.text

onready var _client = SyncRoot.find_client(NetUtils.get_unique_id(self))

onready var _ground_detector = $GroundDetector
onready var _ground_orientation = $GroundOrientation

onready var _footsteps = $Footsteps/Audio
onready var _footsteps_countdown = $Footsteps/Audio/CountdownTimer
onready var _footsteps_rest = $Footsteps/RestTimer

func _ready():
	if _client != null:
		_client.steps_per_sec.connect("values_changed", self, "_on_StepsPerSec_values_changed")
	
	_update_ui()

func _process(delta):
	for i in 10:
		if Input.is_key_pressed(KEY_0 + i):
			_debug_steps_per_sec = i
		elif Input.is_key_pressed(KEY_KP_0):
			_debug_steps_per_sec = 100
			
	if Input.is_action_just_pressed("camera_toggle"):
		if _eye_camera.current:
			_third_person_camera.current = true
			_eye_camera.current = false
		else:
			_third_person_camera.current = false
			_eye_camera.current = true

func _set_current_path(path: Path):
	if current_path != null:
		current_path.enqueue_free()

	# Make our own copy of the path and autocalculate curves
	current_path = Path.new()
	current_path.curve = Curve3D.new()

	for i in path.curve.get_point_count():
		# Convert 3D path to 2D path (we ignore the height coordinate). Instead,
		# we stick the player to the ground, making us robust against invalid
		# waypoints. Also, 2D points are easier to do math on a bit later
		var point_copy = path.curve.get_point_position(i)
		point_copy.y = 0
		current_path.curve.add_point(point_copy, Vector3(), Vector3())
		
	for i in current_path.curve.get_point_count():
		var beforei = i - 1
		if beforei < 0:
			beforei += current_path.curve.get_point_count()
		var afteri = i + 1
		if afteri == current_path.curve.get_point_count():
			afteri = 0

		var curr = current_path.curve.get_point_position(i)
		var before = current_path.curve.get_point_position(beforei)
		var after = current_path.curve.get_point_position(afteri)
		
		var after_delta = (after - curr)
		var before_delta = (before - curr)
		var avg = ((after_delta.normalized() + before_delta.normalized()) / 2.0).normalized()

		var is_right_turn = (before_delta.cross(after_delta).y) >= 0

		var turn_angle = PI / 2.0
		if !is_right_turn:
			turn_angle = -turn_angle

		var smaller_delta = after_delta
		if (after_delta.length_squared() > before_delta.length_squared()):
			smaller_delta = before_delta

		var control_out = avg.rotated(Vector3.UP, turn_angle).normalized() * (smaller_delta.length() / 5.0)
		var control_in = -control_out

		current_path.curve.set_point_in(i, control_in)
		current_path.curve.set_point_out(i, control_out)

	# Close the loop!
	current_path.curve.add_point(current_path.curve.get_point_position(0), current_path.curve.get_point_in(0), current_path.curve.get_point_out(0))
	path.get_parent().add_child(current_path)

	_follow.get_parent().remove_child(_follow)
	current_path.add_child(_follow)
	_snap_to_follow()

func _align_with_y(xform, new_y):
	# See also: https://kidscancode.org/godot_recipes/3d/3d_align_surface/
	xform.basis.y = new_y
	xform.basis.x = -xform.basis.z.cross(new_y)
	xform.basis = xform.basis.orthonormalized()
	return xform

func _snap_to_follow():
	translation.x = _follow.translation.x
	translation.z = _follow.translation.z
	if _ground_detector.is_colliding():
		translation.y = _ground_detector.get_collision_point().y

		# Have camera's x rotation (looking up or down) align with the ground
		# e.g. on an upslope, look up
		var ground_normal = _ground_detector.get_collision_normal()
		_eye_camera.global_transform = _eye_camera.global_transform.interpolate_with(_align_with_y(_eye_camera.global_transform, ground_normal), 0.01)
		_eye_camera.rotation = Vector3(_eye_camera.rotation.x, 0.0, 0.0)

	_pivot.rotation.y = _follow.rotation.y + (PI / 2)

func _prune_half_steps():
	if half_steps.is_empty():
		return

	var last = half_steps.get_item(-1)
	var prune_if_before = last[0] - 1.0
	while !half_steps.is_empty() \
	&& half_steps.get_item(0)[0] < prune_if_before:
		half_steps.remove_first()
		
func _on_StepsPerSec_values_changed():
	half_steps.append(_client.steps_per_sec.value)
	_footsteps_rest.start()

func _update_steps_per_sec():
	if _client == null: 
		_target_steps_per_sec = _debug_steps_per_sec
	else:
		_prune_half_steps()
		_target_steps_per_sec = half_steps.size() / 2.0

	_curr_steps_per_sec = lerp(_curr_steps_per_sec, _target_steps_per_sec, 0.05)

func _physics_process(delta):
	_update_steps_per_sec()

	if _curr_steps_per_sec > 0:
		# The steeper the ground, the slower the player moves
		var ground_slope = _eye_camera.rotation.x
		_distance += cos(ground_slope) * _curr_steps_per_sec * METERS_PER_STEP * delta

		_follow.offset = _distance
		_snap_to_follow()
		var vel = Vector3(0.0, -9.8, 0.0)
		vel = move_and_collide(vel * delta)
		
		if _footsteps_countdown.is_stopped():
			_footsteps.step()
			# Too many steps sounds chaotic
			var clamped_steps_per_sec = min(_curr_steps_per_sec, 5)
			_footsteps_countdown.start(1.0 / clamped_steps_per_sec)
			
		_update_ui()
	else:
		_footsteps_countdown.stop()

func _update_ui():
	var miles = _distance * 0.000621371
	_mph_label.text = _mph_label_format % miles
	_steps_label.text = _steps_label_format % _curr_steps_per_sec

func _on_StepCountdown_timeout():
	_footsteps.step()

func _on_RestTimer_timeout():
	half_steps.clear()
	_target_steps_per_sec = 0.0
	_update_ui()
	
