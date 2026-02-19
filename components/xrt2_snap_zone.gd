@tool
extends Area3D


## Signal emitted when the snap-zone picks something up
signal has_picked_up(what)

## Signal emitted when the snap-zone drops something
signal has_dropped

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


# Public fields
var closest_object : Node3D = null
var picked_up_object : Node3D = null
var picked_up_ranged : bool = true


# Private fields
var _object_in_grab_area : Array[PhysicsBody3D] = []


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
		if not picked_up_object.is_in_group("dropped"):
			drop_object()
		
	# Check for any object in range that can be grabbed
	for o in _object_in_grab_area:
		# pick up our target
		if snap_mode == SnapMode.DROPPED:
			if o.is_in_group("dropped") and not o.is_in_group("snapped_zone"):
				pick_up_object(o)
		else:	
			pick_up_object(o)
		return


# Pickup Method: Drop the currently picked up object
func drop_object() -> void:
	if not is_instance_valid(picked_up_object):
		return

	# let go of this object
	$Held.remote_path = ""
	picked_up_object = null
	has_dropped.emit()
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

	# Show highlight when something could be snapped
	if not is_instance_valid(picked_up_object):
		close_highlight_updated.emit(target, enabled)

# Called when a body leaves the snap zone
func _on_snap_zone_body_exited(target: Node3D) -> void:
	# Ensure the object is not in our list
	_object_in_grab_area.erase(target)

	target.remove_from_group("snapped_zone")
	
	# Hide highlight when nothing could be snapped
	if _object_in_grab_area.is_empty() && is_valid_object(target):
		close_highlight_updated.emit(target, false)
		

func is_valid_object(target: Node3D) -> bool:
	# Ignore objects already known about
	if _object_in_grab_area.find(target) >= 0:
		return false

	# Reject objects not in the required snap group
	if not snap_require.is_empty() and not target.is_in_group(snap_require):
		return false

	# Reject objects in the excluded snap group
	if not snap_exclude.is_empty() and target.is_in_group(snap_exclude):
		return false

	return true

# Test if this snap zone has a picked up object
func has_snapped_object() -> bool:
	return is_instance_valid(picked_up_object)


# Pick up the specified object
func pick_up_object(target: Node3D) -> void:
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

	$Held.remote_path = picked_up_object.get_path()

	# If object picked up then emit signal
	if is_instance_valid(picked_up_object):
		has_picked_up.emit(picked_up_object)
		highlight_updated.emit(self, false)
		picked_up_object.set_collision_layer_value(4, false) # Not a dropped object anymore
		print("pickup " + picked_up_object.name)
	
	picked_up_object.add_to_group("snapped_zone")

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
