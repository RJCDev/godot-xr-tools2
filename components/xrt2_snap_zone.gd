@tool
extends Area3D


## Signal emitted when the snap-zone picks something up
signal has_picked_up(what : PhysicsBody3D)

## Signal emitted when the snap-zone drops something
signal has_dropped(what : PhysicsBody3D)

# Signal emitted when the highlight state changes
signal highlight_updated(pickable, enable)

# Signal emitted when the highlight state changes
signal close_highlight_updated(pickable, enable)


## Enumeration of snap mode
enum SnapMode {
	DROPPED,	## Snap only when the object is dropped
	RANGE,		## Snap whenever an object is in range
}


## Enable or disable snap-zone
@export var enabled : bool = true: set = _set_enabled

## Do we move the object to the snapzone transform when it is snapped?
@export var snap_in_place : bool = true

## Should we disable the object inside when we pickup?
@export var disable_on_pickup : bool = true

## Optional audio stream to play when a object snaps to the zone
@export var stash_sound : AudioStream

## Grab distance
@export var grab_distance : float = 0.3: set = _set_grab_distance

## Snap mode
@export var snap_mode : SnapMode = SnapMode.DROPPED

## Require snap items to be in specified group
@export var snap_require : String = ""

## Deny snapping items in the specified group
@export var snap_exclude : String = ""

## Require grab-by to be in the specified group
@export var grab_require : String = ""

## Deny grab-by
@export var grab_exclude : String= ""

## Initial object in snap zone
@export var initial_object : NodePath

## The layer for the object to go in when enterin the snap zone
@export_flags_3d_physics var collision_layer_entered: int = 0


# Public fields
var closest_object : PhysicsBody3D = null
var picked_up_object : PhysicsBody3D = null
var picked_up_ranged : bool = true


# Private fields
var _object_in_grab_area : Array[PhysicsBody3D] = []
var _remember_collision_layer : int
var _remember_collision_mask: int
var _joint : Generic6DOFJoint3D
var _close_highlight_target : PhysicsBody3D = null

func _ready():
	# Set collision shape radius
	if has_node("CollisionShape3D") and "radius" in $CollisionShape3D.shape:
		$CollisionShape3D.shape.radius = grab_distance

	# Add important connections
	if not body_entered.is_connected(_on_snap_zone_body_entered):
		body_entered.connect(_on_snap_zone_body_entered)
	if not body_exited.is_connected(_on_snap_zone_body_exited):
		body_exited.connect(_on_snap_zone_body_exited)

	# Perform the initial object check when next idle
	if not Engine.is_editor_hint():
		_initial_object_check.call_deferred()


# Called on each frame to update the pickup
func _physics_process(_delta):
	# Skip if in editor or not enabled
	if Engine.is_editor_hint() or not enabled:
		return
	
	# Check if we're picked up and were not in the dropped state (inside the snapzone state)
	if is_instance_valid(picked_up_object):
		if picked_up_object is RigidBody3D:
			picked_up_object.linear_velocity = Vector3.ZERO
			picked_up_object.angular_velocity = Vector3.ZERO
			
		if not picked_up_object.is_in_group("dropped"):
			drop_object()

	_refresh_grab_area_objects()
	_update_close_highlight()
		
	# Check for any object in range that can be grabbed
	for o in _object_in_grab_area:
		# pick up our target
		if snap_mode == SnapMode.DROPPED:
			if o.is_in_group("dropped") and not o.is_in_group("snap_zone"):
				pick_up_object(o)
		else:	
			pick_up_object(o)
		return

	if snap_mode == SnapMode.DROPPED and not is_instance_valid(picked_up_object):
		var nearby := _find_dropped_candidate_nearby()
		if nearby:
			pick_up_object(nearby)


# Pickup Method: Drop the currently picked up object
func drop_object() -> void:
	if not is_instance_valid(picked_up_object):
		return
	
	picked_up_object.collision_mask = _remember_collision_mask
	picked_up_object.collision_layer = _remember_collision_layer
	picked_up_object.remove_from_group("snap_zone")
	
	# let go of this object
	if (_joint):
		remove_child(_joint)
		_joint.queue_free()
		_joint = null
		
	if picked_up_object is RigidBody3D:
		picked_up_object.gravity_scale = 1
		
	has_dropped.emit(picked_up_object)
	picked_up_object = null
	highlight_updated.emit(self, enabled)


# Check for an initial object pickup
func _initial_object_check() -> void:
	# Check for an initial object
	if initial_object:
		# Force pick-up the initial object
		pick_up_object(get_node(initial_object))
	else:
		# Show highlight when empty and enabled
		highlight_updated.emit(self, enabled)

	# Stop any audio from initial pickup
	var audio := get_node("AudioStreamPlayer3D") if has_node("AudioStreamPlayer3D") else null

	# Only stop if the user doesn't intend to auto-play
	if audio is AudioStreamPlayer3D and !audio.autoplay:
		audio.stop()


# Called when a body enters the snap zone
func _on_snap_zone_body_entered(target: Node3D) -> void:
	if not is_valid_object(target):
		return
		
	# Add to the list of objects in grab area
	_object_in_grab_area.push_back(target)

# Called when a body leaves the snap zone
func _on_snap_zone_body_exited(target: Node3D) -> void:
	# Ensure the object is not in our list
	_object_in_grab_area.erase(target)

	target.remove_from_group("snap_zone")
		

func is_valid_object(target: Node3D) -> bool:
	# Ignore objects already known about
	if _object_in_grab_area.find(target) >= 0:
		return false

	return _matches_snap_filter(target)


func _matches_snap_filter(target: Node) -> bool:
	if not target is PhysicsBody3D:
		return false

	# Reject objects not in the required snap group
	if not snap_require.is_empty() and not target.is_in_group(snap_require):
		return false

	# Reject objects in the excluded snap group
	if not snap_exclude.is_empty() and target.is_in_group(snap_exclude):
		return false

	return true


func _refresh_grab_area_objects() -> void:
	for body in get_overlapping_bodies():
		if not _matches_snap_filter(body):
			continue
		if _object_in_grab_area.find(body) >= 0:
			continue
		_object_in_grab_area.push_back(body)


func _find_dropped_candidate_nearby() -> PhysicsBody3D:
	var best: PhysicsBody3D = null
	var best_distance := grab_distance * 1.5
	var center := global_transform.origin

	for body in get_overlapping_bodies():
		if not body is PhysicsBody3D:
			continue
		if not body.is_in_group("dropped") or body.is_in_group("snap_zone"):
			continue
		if not _matches_snap_filter(body):
			continue
		var distance := body.global_position.distance_to(center)
		if distance <= best_distance:
			best_distance = distance
			best = body

	return best


func _update_close_highlight() -> void:
	if not enabled:
		_set_close_highlight(null)
		return

	# Holstered item: show ring when a physics hand is in range (grab-out cue).
	if is_instance_valid(picked_up_object):
		if _is_hand_in_grab_area():
			_set_close_highlight(picked_up_object)
		else:
			_set_close_highlight(null)
		return

	_set_close_highlight(_find_close_highlight_candidate())


func _is_hand_in_grab_area() -> bool:
	var center := global_transform.origin
	var reach := grab_distance * 1.5

	for body in get_overlapping_bodies():
		if body == picked_up_object or not body is RigidBody3D:
			continue
		if _matches_snap_filter(body):
			continue
		if body.global_position.distance_to(center) <= reach:
			return true

	return false


func _find_close_highlight_candidate() -> PhysicsBody3D:
	var best: PhysicsBody3D = null
	var best_distance := grab_distance * 1.5
	var center := global_transform.origin

	for body in get_overlapping_bodies():
		if not body is PhysicsBody3D:
			continue
		if not _matches_snap_filter(body):
			continue
		var distance := body.global_position.distance_to(center)
		if distance <= best_distance and (best == null or distance < best_distance):
			best_distance = distance
			best = body

	return best


func _set_close_highlight(target: PhysicsBody3D) -> void:
	if target == _close_highlight_target:
		return
	if is_instance_valid(_close_highlight_target):
		close_highlight_updated.emit(_close_highlight_target, false)
	_close_highlight_target = target
	if is_instance_valid(_close_highlight_target):
		close_highlight_updated.emit(_close_highlight_target, true)


# Test if this snap zone has a picked up object
func has_snapped_object() -> bool:
	return is_instance_valid(picked_up_object)


# Pick up the specified object
func pick_up_object(target: PhysicsBody3D) -> void:
	
	# check if already holding an object
	if is_instance_valid(picked_up_object):
		# skip if holding the target object
		if picked_up_object == target:
			return
		# holding something else? drop it
		drop_object()

	# skip if target null or freed
	if not is_instance_valid(target):
		return

	# Pick up our target. Note, target may do instant drop_and_free
	picked_up_object = target
	if has_node("AudioStreamPlayer3D"):
		var player = get_node("AudioStreamPlayer3D")
		if is_instance_valid(player):
			if player.playing:
				player.stop()
			player.stream = stash_sound
			player.play()
			
	if snap_in_place:
		# Copy pose without inheriting any non-uniform/scaled basis.
		var snap_xf := global_transform
		snap_xf.basis = snap_xf.basis.orthonormalized()
		picked_up_object.global_transform = snap_xf
		picked_up_object.scale = Vector3.ONE
		
	_joint = Generic6DOFJoint3D.new()
	add_child(_joint, false, Node.INTERNAL_MODE_BACK)
	_joint.node_a = $HoldLocation.get_path()
	_joint.node_b =  picked_up_object.get_path()
	
	if picked_up_object is RigidBody3D:
		picked_up_object.gravity_scale = 0

	# If object picked up then emit signal
	if is_instance_valid(picked_up_object):
		has_picked_up.emit(picked_up_object)
		highlight_updated.emit(self, false)
	
	# Handle collision info
	if target is RigidBody3D:
		if disable_on_pickup:	
			target.collision_layer = 0
			target.collision_mask = 0
			enabled = false
		else:
			_remember_collision_layer = target.collision_layer
			_remember_collision_mask = target.collision_mask
			
			target.collision_layer = collision_layer_entered
			target.collision_mask = 0
			# Keep the grabbable layer so hands and snap zones can detect holstered items.
			if collision_layer_entered != 0:
				target.set_collision_layer_value(3, true)
			
	picked_up_object.add_to_group("snap_zone")
	picked_up_object.add_to_group("dropped") # Just in case
	
	_set_close_highlight(null)
	
	

# Called when the enabled property has been modified
func _set_enabled(p_enabled: bool) -> void:
	enabled = p_enabled
	if is_inside_tree:
		highlight_updated.emit(
			self,
			enabled and not is_instance_valid(picked_up_object))


# Called when the grab distance has been modified
func _set_grab_distance(new_value: float) -> void:
	grab_distance = new_value
	if is_inside_tree() and $CollisionShape3D:
		$CollisionShape3D.shape.radius = grab_distance
