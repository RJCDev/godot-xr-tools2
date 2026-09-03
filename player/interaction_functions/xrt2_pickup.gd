@tool
class_name XRT2Pickup
extends Node3D


## XRTools2 Pickup Script
##
## This script implements logic for picking up physics objects.
## This script works best when childed to an [XRT2CollisionHand] object.

# TODO:
# - Right now we just pick up RigidBodies which then move with our hand.
#   The idea is to also be able to grab marked StaticBodies but we then keep
#   our hand attached to the static body and work with a movement provider
#   to allow allow body movement.
# - We need to communicate the weight of the [RigidBody3D] we pick up to
#   our collision hands so we can react to holding weighted objects
# - We need to deal with two handed pickup
# - We no longer have logic on our [RigidBody3D] so we need a static
#   interface to easily find out by what the [RigidBody3D] is held
# - We need to come up with a way to override finger positions that work
#   in combination with hand tracking, possibly turning off hand tracking
#   when we are holding an object. Ideally we should have an option to
#   automatically pose the hand correctly if no grab point is specified.
# - Need to re-introduce grab points with optional finger poses

#region Signals

## Inform that this hand has picked up this object (also if this is the second hand).
signal try_pickup(by : XRT2Pickup, what : PhysicsBody3D)

## Trigger edge started a pickup attempt (before try_pickup).
signal pick_trigger_engaged(by : XRT2Pickup, what : PhysicsBody3D)

## Inform that this hand has picked up this object (also if this is the second hand).
signal picked_up(by : XRT2Pickup, what : PhysicsBody3D)

## Inform that this hand has dropped this object (also if this object is still held by another hand).
signal dropped(by : XRT2Pickup, what : PhysicsBody3D, lastHand : bool)

#endregion

# Class for storing our highlight overrule data
class HighlightedBody extends RefCounted:
	var original_materials : Dictionary[MeshInstance3D, Material]
	var pickups : Array[XRT2Pickup]

# Class for storing closest info
class ClosestObject extends RefCounted:
	var body : PhysicsBody3D
	var grab_point : XRT2GrabPoint

# Array of all current pickup handlers
static var _pickup_handlers : Array[XRT2Pickup]

# We only want one hand to highlight
static var _highlighted_bodies : Dictionary[Node3D, HighlightedBody]

#region Export variables
## If ticked we monitor for things we can pick up
@export var enabled : bool = true:
	set(value):
		enabled = value
		if is_inside_tree():
			_update_enabled()

## We only pick up items present in these physics layers
@export_flags_3d_physics var collision_mask = 1:
	set(value):
		collision_mask = value
		if is_inside_tree():
			_update_collision_mask()

## How far from our pickup function we check if there are items to pick up.
@export var detection_radius : float = 0.3:
	set(value):
		detection_radius = value
		if is_inside_tree():
			_update_detection_radius()

## Max distance from the hand to a secondary support grip (foregrip, etc.).
## Keep tight so the bolt/slide reload zone is not swallowed by the brace.
@export var secondary_grab_distance : float = 0.08

## Mesh highlight radius around a secondary support grip point.
@export var secondary_highlight_radius : float = 0.08

## Primary grab/drop action (grip). Also used for sticky drop.
@export var grab_action : String = "grab"

## Alternate action that can initiate a pickup (trigger).
@export var pick_action : String = "trigger_click"

## If false we need to continously hold our grab button, if true we toggle
## Note: with keyboard entry toggle is enforced
@export var grab_toggle : bool = false
	
#endregion


#region Private variables
# Node helpers
var _xr_origin : XROrigin3D
var _xr_controller : XRController3D
var _xr_collision_hand : XRT2CollisionHand
var _xr_player_object : CollisionObject3D

var _detection_area : Area3D
var _collision_shape : CollisionShape3D
var _collision_sphere : SphereShape3D

# When picked up by collision hand
var _joint : Generic6DOFJoint3D

# When picked up by controller
var _remote_transform : RemoteTransform3D

# Visualisation in the editor
var _editor_sphere : SphereMesh
var _editor_mesh_instance : MeshInstance3D

# Tween for animations
var _tween : Tween

# Tracks if our input is currently in grab mode (even if we're not holding anything)
var _is_grab : bool = false

# Remember if our XR actions were pressed last frame
var _was_drop_pressed : bool = false
var _was_pick_pressed : bool = false

# Which input initiated the current grab ("grip_click", "trigger_click", etc.)
var _pick_input : String = ""

# After dropping, ignore grab until the button is fully released so we don't
# immediately re-pick the same object while grip is still held (e.g. Droppable
# items dropped via grip_click from HandComponent).
var _block_grab_until_release : bool = false

# What is currently our closest object
var _closest_object : ClosestObject
var _pending_pickup_grab_point : XRT2GrabPoint

# What are we holding and by which grab point
var _picked_up : PhysicsBody3D
var _grab_point : XRT2GrabPoint

# Original state of picked up object
var _original_freeze_mode : RigidBody3D.FreezeMode
var _original_collision_layer : int
var _original_collision_mask : int

# While the hand mesh tweens into the grab pose, keep held colliders off.
var _orienting_pickup : bool = false
var _orient_collision_restore : Dictionary = {}
## Set during primary pickup; soft-joint reseat + settle after picked_up.emit.
var _glue_primary_after_pickup : bool = false

# Door/frame layers to ignore on single-body held items (walkie, etc.) while gripped.
# Static world + teleport block + door — stripped while held to stop physics jitter
# against props and door frames; post-teleport depenetration handles doors.
const HELD_ENVIRONMENT_COLLISION_MASK := 385
const PICKUP_ORIENT_TWEEN_DURATION := 0.05
var _held_environment_mask_restore : Dictionary = {}

# Keep player/hand collision exceptions briefly after drop so holster snap can settle.
const DROP_COLLISION_GRACE_FRAMES := 8
var _drop_collision_grace : Dictionary = {}

# If true, we are the primary hand holding this object (for 2 handed)
var _is_primary : bool = false

# Our highlight material
var _highlight_material : ShaderMaterial = \
	preload("res://addons/godot-xr-tools2/shaders/highlight_by_vertex.material")
#endregion


#region Public functions
## Find an XRT2Pickup function that is a child of the given parent
static func get_pickup(parent : Node3D) -> XRT2Pickup:
	for child in parent.get_children():
		if child is XRT2Pickup:
			return child

		var pickup = XRT2Pickup.get_pickup(child)
		if pickup:
			return pickup

	return null

## Find which pickup handler has picked up this object
static func picked_up_by(what : PhysicsBody3D) -> XRT2Pickup:
	var by : XRT2Pickup
	for pickup : XRT2Pickup in _pickup_handlers:
		if pickup._picked_up == what:
			by = pickup

			# If this is our primary, return that
			if pickup._is_primary:
				return by

	# If we found one, it will be our secondary hand
	return by


## Find which pickup holds this body or a parent rigidbody in the same assembly.
static func _get_holder_pickup(body: PhysicsBody3D) -> XRT2Pickup:
	var node: Node = body
	while node:
		if node is RigidBody3D:
			var by := picked_up_by(node)
			if by:
				return by
		node = node.get_parent()
	return null
func has_picked_up() -> bool:
	if is_instance_valid(_picked_up):
		return true
	return false


## Returns the object we're currently holding
func get_picked_up() -> PhysicsBody3D:
	if is_instance_valid(_picked_up):
		return _picked_up
	return null


## Returns the grab point on the object we've picked up
func get_picked_up_grab_point() -> XRT2GrabPoint:
	if is_instance_valid(_grab_point):
		return _grab_point
	return null


## Returns which input action initiated the current grab.
func get_pick_input() -> String:
	return _pick_input


## Reset grab intent when a pickup attempt is rejected by game logic.
func cancel_pickup_attempt() -> void:
	_is_grab = false
	_pick_input = ""


## Returns true if we're the primary hand holding this object
func is_primary() -> bool:
	return _is_primary


## True while the grab-orient tween is running (colliders temporarily off).
func is_orienting_pickup() -> bool:
	return _orienting_pickup


## True when a physics joint links the hand to the held body.
func is_jointed_pickup() -> bool:
	return _joint != null and is_instance_valid(_joint)


## True when the held assembly contains multiple rigid bodies (e.g. rifle + slide).
func is_multi_body_assembly() -> bool:
	if not is_instance_valid(_picked_up):
		return false
	var bodies: Array[RigidBody3D] = []
	_collect_orient_bodies(_get_assembly_root(_picked_up), bodies)
	return bodies.size() > 1


## Pick up this object
func pickup_object(which : PhysicsBody3D):
	_pickup_object_internal(which, false)


## Loadout holster draw: ignore grab-point max distance so hip draws always succeed.
func force_pickup_object(which : PhysicsBody3D) -> bool:
	if _picked_up == which:
		_is_grab = true
		return true
	if _picked_up:
		drop_held_object()
	_pickup_object_internal(which, true)
	if _picked_up == which:
		_is_grab = true
		_pick_input = grab_action
		_was_drop_pressed = true
		_was_pick_pressed = _is_action_pressed(pick_action, false)
		return true
	return false


## After loadout draw anim returns to the tracked pose, re-seat the held item.
func reseat_held_to_attachment() -> bool:
	if not is_instance_valid(_picked_up) or not is_instance_valid(_grab_point):
		return false
	if _is_secondary_support_grab(_picked_up, _grab_point):
		return false
	var attachment := get_parent() as XRT2HandAttachment
	if attachment:
		attachment._on_skeleton_updated()
	_place_object_at_hand_attachment(_picked_up)
	if _xr_collision_hand and _xr_collision_hand.has_method("begin_pickup_settle"):
		_xr_collision_hand.begin_pickup_settle()
	return true


func _pickup_object_internal(which : PhysicsBody3D, ignore_grab_distance : bool) -> void:
	if not which is RigidBody3D and not which is PhysicalBone3D:
		push_warning("Picking up objects other than Rigidbody and PhysicalBone3D is currently disabled.")
		return
	if _xr_collision_hand:
		if which is RigidBody3D or which is PhysicalBone3D:
			# Remember our current hand transform.
			var hand_transform : Transform3D = _xr_collision_hand.global_transform

			# Prefer the staged grab point from the trigger/grip edge (keeps secondary
			# brace vs primary fire gating aligned with what the hand highlighted).
			# Holster force-pickup has no stage — resolve closest instead.
			var staged := _consume_pending_grab_point(which)
			if staged:
				_grab_point = staged
			else:
				_grab_point = _get_closest_grabpoint(which, global_position, ignore_grab_distance)
			# Figure out our grab position
			var dest_transform : Transform3D
			if _grab_point:
				dest_transform = _grab_point.get_hand_transform(global_position)
				_xr_collision_hand.finger_poses = _grab_point.finger_poses
				_xr_collision_hand.open_finger_poses = _grab_point.open_finger_poses
				_grab_point._occupied = true
				grab_toggle = _grab_point.toggle
				# Secondary support grips are always trigger-hold, never sticky.
				if _is_secondary_support_grab(which, _grab_point):
					grab_toggle = false
					_pick_input = pick_action
					
			else: # Just  dont pick it up
				push_warning("XRT2Pickup: no grab point for %s (ignore_dist=%s)" % [which.name, ignore_grab_distance])
				return
			
			dest_transform.basis = dest_transform.basis.orthonormalized()
			var attachment := get_parent() as XRT2HandAttachment
			if attachment:
				attachment._on_skeleton_updated()

			var is_hand_to_object := _should_snap_hand_to_grab(which, _grab_point)
			if is_hand_to_object:
				_place_hand_at_grab_point(dest_transform)
			else:
				_place_object_at_hand_attachment(which)

			_joint = Generic6DOFJoint3D.new()
			add_child(_joint, false, Node.INTERNAL_MODE_BACK)
			_joint.node_a = _xr_collision_hand.get_path()
			_joint.node_b = which.get_path()

			which.add_collision_exception_with(_xr_collision_hand)

			if is_hand_to_object:
				if _is_secondary_support_grab(which, _grab_point):
					_begin_pickup_orient(which)
					if _xr_collision_hand._hand_mesh:
						# Foregrip only: brief mesh settle (rifle may shift).
						_xr_collision_hand._hand_mesh.global_transform = hand_transform
						if _tween:
							_tween.kill()
						_tween = _xr_collision_hand._hand_mesh.create_tween()
						_tween.tween_property(
							_xr_collision_hand._hand_mesh, "transform",
							Transform3D(), PICKUP_ORIENT_TWEEN_DURATION
						)
						if not _tween.finished.is_connected(_on_pickup_orient_finished):
							_tween.finished.connect(_on_pickup_orient_finished, CONNECT_ONE_SHOT)
					else:
						_on_pickup_orient_finished()
				else:
					# Bolt/slide reload: hand on carrier, carrier stays on the gun.
					if _xr_collision_hand._hand_mesh:
						_xr_collision_hand._hand_mesh.transform = Transform3D()
					_orienting_pickup = false
			else:
				if _xr_collision_hand._hand_mesh:
					_xr_collision_hand._hand_mesh.transform = Transform3D()
				_orienting_pickup = false
				_glue_primary_after_pickup = true

		else:
			# TODO implement other types of grab
			pass
	elif _xr_controller:
		# Old fashioned pickup, we use remote transform to pickup the object
		if _is_primary:
			if _picked_up is RigidBody3D:
				_original_freeze_mode = _picked_up.freeze_mode

				# Don't control with physics engine, we're in control.
				_picked_up.freeze = true
				_picked_up.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
				_picked_up.collision_layer = 0
				_picked_up.collision_mask = 0

				# Setup our remote transform and sync location to
				# our current picked up object position.
				_remote_transform.global_transform = _picked_up.global_transform
				_remote_transform.remote_path = _picked_up.get_path()
	
				# Find our grab point (if any).
				# Note, we're already handled our exclusive logic, can ignore that here.
				_grab_point = _get_closest_grabpoint(_picked_up, global_position)
				# Figure out our grab position.
				var dest_transform : Transform3D 
				if _grab_point:
					dest_transform = _grab_point.get_hand_transform(global_position)
				else:
					dest_transform = _get_default_hand_transform(_picked_up, global_position)

				# Make our transform local to our picked up object, we'll tween to fetch.
				dest_transform = dest_transform.inverse() * _picked_up.global_transform

				# Adjust our dest_transform to account for any offset in our pickup function
				dest_transform = transform.inverse() * dest_transform

				if _tween:
					_tween.kill()

				_tween = _remote_transform.create_tween()

				# Now tween
				_tween.tween_property(_remote_transform, "transform", dest_transform, 0.1)

			# TODO implement logic for other type of physics bodies
		else:
			# TODO implement secondary pickup
			pass
	
	# No longer show highlighted
	_clear_highlight_for_closest(which, _grab_point)
	
	# Swap primary status to true if its not picked up by something else
	if picked_up_by(which):
		_is_primary = false
	else :
		_is_primary = true

	# Make sure our body doesn't collide with things we've picked up
	if _is_primary and _xr_player_object:
		# TODO should create a collision exception manager to ensure we don't undo this too quickly
		which.add_collision_exception_with(_xr_player_object)
		_xr_player_object.add_collision_exception_with(which)
	

	# Remember state
	_picked_up = which
	if _orient_collision_restore.has(which):
		var layers : Vector2i = _orient_collision_restore[which]
		_original_collision_layer = layers.x
		_original_collision_mask = layers.y
	else:
		_original_collision_layer = _picked_up.collision_layer
		_original_collision_mask = _picked_up.collision_mask

	_picked_up.remove_from_group("dropped")
	picked_up.emit(self, which)

	if _glue_primary_after_pickup:
		_glue_primary_after_pickup = false
		if is_instance_valid(_grab_point) and is_instance_valid(_picked_up):
			var attachment := get_parent() as XRT2HandAttachment
			if attachment:
				attachment._on_skeleton_updated()
			_place_object_at_hand_attachment(_picked_up)
		if _xr_collision_hand and _xr_collision_hand.has_method("begin_pickup_settle"):
			_xr_collision_hand.begin_pickup_settle()


## Drop object we're currently holding
func drop_held_object() -> void:
	_finish_pickup_orient()

	# Get some info from our pose
	var linear_velocity : Vector3 = Vector3()
	var angular_velocity : Vector3 = Vector3()
	var pose : XRPose = _get_pose()
	var primary : bool = _is_primary
	if pose:
		linear_velocity = pose.linear_velocity
		angular_velocity = pose.angular_velocity

	# Make sure we clear some initial state
	if _remote_transform:
		_remote_transform.remote_path = NodePath()

	if _tween:
		_tween.kill()
		_tween = null

	if _grab_point:
		_grab_point._occupied = false

	if not is_instance_valid(_picked_up):
		# Just in case
		_picked_up = null
		_grab_point = null
		_is_primary = false
		return

	var was_picked_up = _picked_up

	# Process letting go
	if _xr_collision_hand:
		if _xr_collision_hand.has_method("end_pickup_settle"):
			_xr_collision_hand.end_pickup_settle()

		if _picked_up is RigidBody3D or _picked_up is PhysicalBone3D:
			if _joint:
				remove_child(_joint)
				_joint.queue_free()
				_joint = null

			if _tween:
				_tween.kill()

			# Physics forces only correct position/rotation — reset scale
			# so a previous grab cannot leave the hand permanently larger.
			_xr_collision_hand.scale = Vector3.ONE
			if _xr_collision_hand._hand_mesh:
				_xr_collision_hand._hand_mesh.transform = Transform3D()

			_xr_collision_hand._force_teleport_allowed = true

			# Collision-hand path previously left velocity at the joint-settled
			# near-zero — apply controller throw and clear leftover held damp.
			if _picked_up is RigidBody3D:
				var rb: RigidBody3D = _picked_up
				rb.freeze = false
				rb.linear_damp = 0.0
				rb.angular_damp = 0.0
				rb.linear_velocity = linear_velocity
				rb.angular_velocity = angular_velocity
				rb.gravity_scale = 1.0
				rb.sleeping = false

	elif _xr_controller:
		_picked_up.collision_layer = _original_collision_layer
		_picked_up.collision_mask = _original_collision_mask

		if _picked_up is RigidBody3D:
			_picked_up.freeze_mode = _original_freeze_mode
			_picked_up.freeze = false
			_picked_up.linear_velocity = linear_velocity
			_picked_up.angular_velocity = angular_velocity
	
	# And we're no longer holding something
	_picked_up = null
	_grab_point = null
	_is_primary = false
	if _xr_collision_hand:
		_xr_collision_hand.finger_poses = null
		_xr_collision_hand.open_finger_poses = null
	
	var other = picked_up_by(was_picked_up)
	if other:
		# If it isn't already primary, this is now our primary
		other._is_primary = true
		# Brace/orient strips floor/door from the held mask and stores the
		# pre-strip values on THIS hand. Transfer so the last hand to drop
		# can restore world collision (otherwise the gun falls through floors).
		_transfer_held_environment_collision_mask(other)
	elif _xr_collision_hand:
		_restore_held_environment_collision_mask()
		_restore_dropped_body_collision(was_picked_up)
		_begin_drop_collision_grace(was_picked_up)
	elif _xr_player_object:
		was_picked_up.remove_collision_exception_with(_xr_player_object)
		_xr_player_object.remove_collision_exception_with(was_picked_up)
		
	# Add to dropped group if it is dropped by the primary ONLY
	if not other:
		was_picked_up.add_to_group("dropped")
	
	grab_toggle = false
	_is_grab = false
	_pick_input = ""
	_block_grab_until_release = true
	
	dropped.emit(self, was_picked_up, other == null)
	
func _re_enable_collision(body: Node3D) -> void:
	if body is PhysicsBody3D and _drop_collision_grace.has(body):
		return
	body.remove_collision_exception_with(_xr_collision_hand)


func _begin_drop_collision_grace(body: PhysicsBody3D) -> void:
	if not is_instance_valid(body):
		return
	_drop_collision_grace[body] = DROP_COLLISION_GRACE_FRAMES


func _process_drop_collision_grace() -> void:
	if _drop_collision_grace.is_empty():
		return

	var finished: Array[PhysicsBody3D] = []
	for body: PhysicsBody3D in _drop_collision_grace:
		if not is_instance_valid(body) or body.is_in_group("snap_zone"):
			finished.append(body)
			continue
		_drop_collision_grace[body] -= 1
		if _drop_collision_grace[body] <= 0:
			_end_drop_collision_grace(body)
			finished.append(body)

	for body in finished:
		_drop_collision_grace.erase(body)


func _end_drop_collision_grace(body: PhysicsBody3D) -> void:
	if not is_instance_valid(body):
		return
	if is_instance_valid(_xr_collision_hand):
		body.remove_collision_exception_with(_xr_collision_hand)
	if is_instance_valid(_xr_player_object):
		body.remove_collision_exception_with(_xr_player_object)
		_xr_player_object.remove_collision_exception_with(body)


func _apply_held_environment_collision_mask(root: PhysicsBody3D) -> void:
	if not _xr_collision_hand:
		return

	var bodies: Array[RigidBody3D] = []
	_collect_orient_bodies(root, bodies)

	for body in bodies:
		if not is_instance_valid(body):
			continue
		# Keep the first pre-strip mask if brace/orient runs more than once.
		if not _held_environment_mask_restore.has(body):
			_held_environment_mask_restore[body] = body.collision_mask
		body.collision_mask &= ~HELD_ENVIRONMENT_COLLISION_MASK


func _transfer_held_environment_collision_mask(other: XRT2Pickup) -> void:
	if other == null or _held_environment_mask_restore.is_empty():
		return
	for body: RigidBody3D in _held_environment_mask_restore:
		if not other._held_environment_mask_restore.has(body):
			other._held_environment_mask_restore[body] = _held_environment_mask_restore[body]
	_held_environment_mask_restore.clear()


func _restore_held_environment_collision_mask() -> void:
	for body: RigidBody3D in _held_environment_mask_restore:
		if is_instance_valid(body):
			body.collision_mask = _held_environment_mask_restore[body]
	_held_environment_mask_restore.clear()


## Collision-hand grabs never restored layer/mask on drop (controller path did).
## After a brace strip, also guarantee the dropped root has its pickup originals.
func _restore_dropped_body_collision(body: PhysicsBody3D) -> void:
	if not is_instance_valid(body):
		return
	if _original_collision_layer != 0:
		body.collision_layer = _original_collision_layer
	if _original_collision_mask != 0:
		body.collision_mask = _original_collision_mask
	# If env restore never made it to this hand, at least re-enable world bits.
	elif (body.collision_mask & HELD_ENVIRONMENT_COLLISION_MASK) != HELD_ENVIRONMENT_COLLISION_MASK:
		body.collision_mask |= HELD_ENVIRONMENT_COLLISION_MASK


func _collect_orient_bodies(node: Node, bodies: Array[RigidBody3D]) -> void:
	if node is RigidBody3D:
		bodies.append(node)
	for child in node.get_children():
		_collect_orient_bodies(child, bodies)


func _get_orient_collision_root(which: PhysicsBody3D) -> Node:
	var root: Node = which
	var node: Node = which.get_parent()
	while node:
		if node is RigidBody3D:
			root = node
		node = node.get_parent()
	return root


func _get_assembly_root(body: PhysicsBody3D) -> PhysicsBody3D:
	return _get_orient_collision_root(body) as PhysicsBody3D


## Move the physics hand so the metacarpal attachment sits on dest_transform.
func _place_hand_at_grab_point(dest_transform: Transform3D) -> void:
	if not _xr_collision_hand:
		return
	dest_transform.basis = dest_transform.basis.orthonormalized()
	var attachment_local : Transform3D = get_parent().transform
	attachment_local.basis = attachment_local.basis.orthonormalized()
	_xr_collision_hand.global_transform = dest_transform * attachment_local.affine_inverse()
	_xr_collision_hand.scale = Vector3.ONE
	_xr_collision_hand.force_update_transform()


## Seat the body so its grab-point hand pose matches the metacarpal attachment.
func _place_object_at_hand_attachment(which: PhysicsBody3D) -> void:
	if not is_instance_valid(_grab_point) or not is_instance_valid(which):
		return
	var attachment_xf : Transform3D = get_parent().global_transform
	attachment_xf.basis = attachment_xf.basis.orthonormalized()
	var grab_hand_xf : Transform3D = _grab_point.get_hand_transform(attachment_xf.origin)
	grab_hand_xf.basis = grab_hand_xf.basis.orthonormalized()
	var delta : Transform3D = attachment_xf * grab_hand_xf.affine_inverse()
	which.global_transform = delta * which.global_transform
	which.force_update_transform()
	if which is RigidBody3D:
		var rb := which as RigidBody3D
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
		rb.reset_physics_interpolation()


func _snap_hand_to_current_grab_point() -> void:
	if not is_instance_valid(_grab_point) or not _xr_collision_hand:
		return
	var dest_transform := _grab_point.get_hand_transform(_xr_collision_hand.global_position)
	_place_hand_at_grab_point(dest_transform)


func _begin_pickup_orient(which: PhysicsBody3D) -> void:
	_orient_collision_restore.clear()
	var bodies: Array[RigidBody3D] = []
	_collect_orient_bodies(_get_orient_collision_root(which), bodies)
	for body in bodies:
		if not is_instance_valid(body):
			continue
		_orient_collision_restore[body] = Vector2i(body.collision_layer, body.collision_mask)
		body.collision_layer = 0
		body.collision_mask = 0
	_orienting_pickup = true


func _finish_pickup_orient() -> void:
	if not _orienting_pickup:
		return
	_orienting_pickup = false
	for body in _orient_collision_restore:
		if not is_instance_valid(body):
			continue
		var layers: Vector2i = _orient_collision_restore[body]
		# GunSlide zeros its layer while the weapon is free so it can't shelf
		# the gun midair. If we captured that free state during gun pickup,
		# restoring 0 would leave the bolt ungrabbable — keep prior non-zero.
		if layers.x == 0 and body.collision_layer != 0:
			layers.x = body.collision_layer
		if layers.y == 0 and body.collision_mask != 0:
			layers.y = body.collision_mask
		body.collision_layer = layers.x
		body.collision_mask = layers.y
	_orient_collision_restore.clear()
	if is_instance_valid(_picked_up):
		_apply_held_environment_collision_mask(_picked_up)


func _on_pickup_orient_finished() -> void:
	_finish_pickup_orient()
	if not is_instance_valid(_picked_up) or not is_instance_valid(_grab_point):
		return
	# Hand-to-object grabs (foregrip / bolt): reseat hand after collision restore.
	if _should_snap_hand_to_grab(_picked_up, _grab_point):
		_snap_hand_to_current_grab_point()
		if _xr_collision_hand and _xr_collision_hand.has_method("_clear_hand_mesh_grab_lock"):
			_xr_collision_hand._clear_hand_mesh_grab_lock()
				
#endregion


#region Private export variable update functions
# Update our enabled status
func _update_enabled():
	#if _collision_sphere:
		#_collision_shape.disabled = !enabled
	#if _detection_area:
		#_detection_area.monitoring = enabled
	pass

	# Q: Do we drop anything we're holding when disabled?


# Update our collision mask
func _update_collision_mask():
	if _detection_area:
		_detection_area.collision_mask = collision_mask


# Update our detection radius
func _update_detection_radius():
	if _collision_sphere:
		_collision_sphere.radius = detection_radius
	if _editor_mesh_instance:
		# Just scale it, prevents having to recreate mesh
		_editor_mesh_instance.scale = Vector3(detection_radius, detection_radius, detection_radius)
#endregion


#region Private Godot functions
# Verifies if we have a valid configuration.
func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()

	var xr_controller = XRT2Helper.get_xr_controller(self)
	var xr_collision_hand = XRT2CollisionHand.get_xr_collision_hand(self)

	if not xr_controller and not xr_collision_hand:
		warnings.push_back("This node requires an XRController3D or XRT2CollisionHand as an anchestor.")

	if xr_collision_hand:
		var bone_name = "LeftMiddleMetacarpal" if xr_collision_hand.hand == 0 else "RightMiddleMetacarpal"
		var parent = get_parent()
		if not parent is XRT2HandAttachment:
			warnings.push_back("This node's parent should be an XRT2HandAttachment when used with XRT2CollisionHand.")
		elif parent.bone_name != bone_name:
			warnings.push_back("The bone associated with XRT2HandAttachment should be set to %s." % [ bone_name ])

	# Return warnings
	return warnings


# Called when the node enters the scene tree for the first time.
func _ready():
	# In editor, just create visual aid
	if Engine.is_editor_hint():
		var material : ShaderMaterial = ShaderMaterial.new()
		material.shader = preload("res://addons/godot-xr-tools2/shaders/unshaded_with_alpha.gdshader")
		material.set_shader_parameter("albedo", Color("#00b6b71b"))

		_editor_sphere = SphereMesh.new()
		_editor_sphere.radius = 1.0
		_editor_sphere.height = 2.0
		_editor_sphere.radial_segments = 32
		_editor_sphere.rings = 16
		_editor_sphere.material = material

		_editor_mesh_instance = MeshInstance3D.new()
		_editor_mesh_instance.mesh = _editor_sphere
		add_child(_editor_mesh_instance, false, Node.INTERNAL_MODE_BACK)

		_update_detection_radius()
		return

	_xr_origin = XRT2Helper.get_xr_origin(self)
	_xr_collision_hand = XRT2CollisionHand.get_xr_collision_hand(self)
	if _xr_collision_hand:
		_xr_player_object = _xr_collision_hand.get_collision_parent()
	else:
		_xr_controller = XRT2Helper.get_xr_controller(self)

	# Add this to our list of active pickup handlers
	_pickup_handlers.push_back(self)

	# Create our collision shape
	_collision_sphere = SphereShape3D.new()

	# Create our collision object
	_collision_shape = CollisionShape3D.new()
	_collision_shape.shape = _collision_sphere

	# Create our area detection node
	_detection_area = Area3D.new()
	_detection_area.add_child(_collision_shape, false, Node.INTERNAL_MODE_FRONT)
	add_child(_detection_area, false, Node.INTERNAL_MODE_BACK)
	
	# Re enable the collision with any body we touch when exiting
	_detection_area.body_exited.connect(_re_enable_collision)
	
	if _xr_collision_hand:
		pass
	elif _xr_controller:
		# Create remote transform
		_remote_transform = RemoteTransform3D.new()
		add_child(_remote_transform, false, Node.INTERNAL_MODE_BACK)

	_update_enabled()
	_update_collision_mask()
	_update_detection_radius()


func _exit_tree():
	if _closest_object and is_instance_valid(_closest_object.body):
		_remove_highlight(_closest_object.body)
	
	drop_held_object()

	# Remove us from the pickup handlers
	if _pickup_handlers.has(self):
		_pickup_handlers.erase(self)


func _process(_delta):
	# Don't run in editor
	if Engine.is_editor_hint():
		return

	_process_drop_collision_grace()
	
	# If we don't have a controller ancestor, nothing we can do
	if not _xr_controller and not _xr_collision_hand:
		return
	
	# if we're not tracking, do nothing
	if not _have_tracking_data():
		# We do not drop what we hold (right away)
		return

	# Object we picked up no longer exists? Drop it
	if _picked_up and not is_instance_valid(_picked_up):
		drop_held_object()

	# Our pickup handler is no longer enabled? Drop what we're holding
	# if not enabled and _picked_up:
	# 	drop_held_object(linear_velocity, angular_velocity)
	if not enabled:
		return

	# Check grab/drop input — pickup accepts trigger OR grip; sticky drop is grip-only.
	# Refresh closest before empty-hand input so secondary/primary rules use current target.
	if not _picked_up:
		_update_closest_object()

	var was_pick_pressed := _was_pick_pressed
	var grip_now := _is_action_pressed(grab_action, _was_drop_pressed)
	var pick_now := _is_action_pressed(pick_action, _was_pick_pressed)
	var pick_pressed_edge := pick_now and not was_pick_pressed
	var closest_is_secondary := _closest_object \
			and is_instance_valid(_closest_object.body) \
			and _is_secondary_support_grab(_closest_object.body, _closest_object.grab_point)

	# Don't allow a new grab until both actions release after a drop.
	if _block_grab_until_release:
		if grip_now or pick_now:
			_was_drop_pressed = grip_now
			_was_pick_pressed = pick_now
			_is_grab = false
		else:
			_block_grab_until_release = false
			_was_drop_pressed = false
			_was_pick_pressed = false
	elif _picked_up:
		if _grab_point and _grab_point.useable:
			# Primary / useable grips stay sticky; holster Droppable handles intentional drop.
			_was_drop_pressed = grip_now
			_was_pick_pressed = pick_now
		elif _is_secondary_support_grab(_picked_up, _grab_point):
			# Secondary gun grips: trigger-hold only (never sticky, never grip-held).
			_was_drop_pressed = grip_now
			_was_pick_pressed = pick_now
			if not pick_now:
				drop_held_object()
		elif grab_toggle:
			# Sticky: only grip toggles/releases can drop; trigger release is ignored.
			if grip_now != _was_drop_pressed:
				_was_drop_pressed = grip_now
				if grip_now:
					_is_grab = not _is_grab
			if pick_now != _was_pick_pressed:
				_was_pick_pressed = pick_now
			if not _is_grab:
				drop_held_object()
		else:
			# Hold mode (door knobs): drop when the button that started the grab releases.
			if _pick_input == grab_action and not grip_now:
				drop_held_object()
			elif _pick_input == pick_action and not pick_now:
				drop_held_object()
			_was_drop_pressed = grip_now
			_was_pick_pressed = pick_now
	elif closest_is_secondary:
		# Secondary support: trigger edge only. Grip must not latch or block pickup.
		_was_drop_pressed = grip_now
		_was_pick_pressed = pick_now
		if _pick_input == grab_action or (_is_grab and _pick_input != pick_action):
			_is_grab = false
			_pick_input = ""
		if not _block_grab_until_release and pick_pressed_edge \
				and _closest_object and is_instance_valid(_closest_object.body):
			_is_grab = true
			_pick_input = pick_action
			_stage_pickup_attempt(_closest_object)
			return
	else:
		# Empty-hand world pickup: trigger only, except bolt/slide reload grips on a
		# weapon already held by the other hand — those also accept grip.
		var was_grip_pressed := _was_drop_pressed
		var grip_pressed_edge := grip_now and not was_grip_pressed
		_was_drop_pressed = grip_now
		_was_pick_pressed = pick_now

		var want_pickup := false
		if pick_pressed_edge:
			_pick_input = pick_action
			want_pickup = true
		elif grip_pressed_edge and can_grip_pickup_reload():
			_pick_input = grab_action
			want_pickup = true

		if want_pickup and not _block_grab_until_release \
				and _closest_object and is_instance_valid(_closest_object.body):
			_is_grab = true
			_stage_pickup_attempt(_closest_object)
			return

		# No object this press: forget intent so a later trigger can still pick up.
		if not _is_grab:
			_pick_input = ""

	# Closest is already refreshed when empty-handed; only refresh here while holding
	# (highlights are suppressed while holding anyway).
	if _picked_up:
		if _grab_point and _uses_local_grab_highlight(_picked_up, _grab_point):
			_remove_highlight(_grab_point)
		return

	# Highlight pass for empty hand (closest already updated above).
	# No further closest recompute needed this frame.
#endregion


func _stage_pickup_attempt(closest: ClosestObject) -> void:
	if closest and closest.grab_point and is_instance_valid(closest.body):
		var root := _get_assembly_root(closest.body)
		if not _grab_point_allowed_while_unheld(root, closest.grab_point):
			return
	_pending_pickup_grab_point = closest.grab_point if closest else null
	if _pick_input == pick_action and closest and is_instance_valid(closest.body) \
			and closest.grab_point and closest.grab_point.useable:
		pick_trigger_engaged.emit(self, closest.body)
	try_pickup.emit(self, closest.body)


func _consume_pending_grab_point(which: PhysicsBody3D) -> XRT2GrabPoint:
	var grab_point := _pending_pickup_grab_point
	_pending_pickup_grab_point = null
	if grab_point == null or not is_instance_valid(grab_point):
		return null
	var grab_body := grab_point.get_parent() as PhysicsBody3D
	if grab_body == null:
		return null
	if grab_body == which:
		return grab_point
	if _get_assembly_root(grab_body) == _get_assembly_root(which):
		return grab_point
	return null


## Another hand already holds a primary/useable grip on this weapon assembly.
func _other_hand_holds_primary_on_assembly(assembly_root: PhysicsBody3D) -> bool:
	return _other_hand_primary_grab_point(assembly_root) != null


## Primary/useable grab point held by the other hand on this assembly, if any.
func _other_hand_primary_grab_point(assembly_root: PhysicsBody3D) -> XRT2GrabPoint:
	if assembly_root == null:
		return null
	for pickup: XRT2Pickup in _pickup_handlers:
		if pickup == self or not is_instance_valid(pickup._picked_up):
			continue
		if _get_assembly_root(pickup._picked_up) != assembly_root:
			continue
		var gp := pickup.get_picked_up_grab_point()
		if gp and gp.useable:
			return gp
	return null


func _is_assembly_held(assembly_root: PhysicsBody3D) -> bool:
	if assembly_root == null:
		return false
	for pickup: XRT2Pickup in _pickup_handlers:
		if not is_instance_valid(pickup._picked_up):
			continue
		if _get_assembly_root(pickup._picked_up) == assembly_root:
			return true
	return false


func _assembly_has_useable_grab_point(assembly_root: PhysicsBody3D) -> bool:
	var grab_points: Array[XRT2GrabPoint] = []
	_collect_grab_points(assembly_root, grab_points)
	for grab_point in grab_points:
		if grab_point.useable:
			return true
	return false


## Multi-grip weapons (Gleagle/rifle):
## - Unheld / holstered: only primary (useable) grips
## - Held on left primary: only right-hand Alt/support
## - Held on right primary: only left-hand Alt/support
## Simple pickables (no useable grips) keep all points.
func _grab_point_allowed_while_unheld(
	assembly_root: PhysicsBody3D, grab_point: XRT2GrabPoint
) -> bool:
	return _grab_point_allowed_for_pickup(assembly_root, grab_point)


func _grab_point_allowed_for_pickup(
	assembly_root: PhysicsBody3D, grab_point: XRT2GrabPoint
) -> bool:
	if grab_point == null:
		return true
	if not _assembly_has_useable_grab_point(assembly_root):
		return true

	var other_primary := _other_hand_primary_grab_point(assembly_root)

	if grab_point.useable:
		# Primaries only while nobody holds a primary (world + holster draws).
		return other_primary == null

	# Bolt/slide reload: only once the weapon is already held.
	if grab_point.exclusive:
		return _is_assembly_held(assembly_root)

	# Secondary brace: only the opposite-hand support after a primary grab.
	return _is_opposite_secondary_for_primary(other_primary, grab_point)


## Left primary → right-hand Alt; right primary → left-hand Alt.
func _is_opposite_secondary_for_primary(
	primary_gp: XRT2GrabPoint, secondary_gp: XRT2GrabPoint
) -> bool:
	if primary_gp == null or secondary_gp == null:
		return false
	if secondary_gp.useable or secondary_gp.exclusive:
		return false

	var primary_left_only := primary_gp.left_hand and not primary_gp.right_hand
	var primary_right_only := primary_gp.right_hand and not primary_gp.left_hand
	var secondary_left_only := secondary_gp.left_hand and not secondary_gp.right_hand
	var secondary_right_only := secondary_gp.right_hand and not secondary_gp.left_hand

	if primary_left_only:
		return secondary_right_only
	if primary_right_only:
		return secondary_left_only
	return false


func _update_closest_object() -> void:
	var was_closest_object : ClosestObject = _closest_object
	_closest_object = _get_closest()

	if was_closest_object and _closest_object \
			and was_closest_object.body == _closest_object.body \
			and was_closest_object.grab_point == _closest_object.grab_point:
		return

	if was_closest_object and is_instance_valid(was_closest_object.body):
		_clear_highlight_for_closest(
			was_closest_object.body, was_closest_object.grab_point
		)

	if _closest_object and is_instance_valid(_closest_object.body):
		if _closest_object.grab_point \
				and _should_skip_grab_point_highlight(_closest_object.grab_point):
			return

		_apply_highlight_for_closest(_closest_object)


#region Private functions
# Returns true if our pickup feature is attached to the left hand.
func _is_left_hand() -> bool:
	if _xr_collision_hand:
		return _xr_collision_hand.hand == 0
	elif _xr_controller:
		return _xr_controller.get_tracker_hand() == XRPositionalTracker.TRACKER_HAND_LEFT
	else:
		return false


# Get collision rids for our hand
func _get_hand_collision_rids() -> Array[RID]:
	var ret : Array[RID]
	if _xr_collision_hand:
		ret.push_back(_xr_collision_hand.get_rid())

	return ret


func _body_has_useable_grab_point(body : PhysicsBody3D) -> bool:
	var grab_points: Array[XRT2GrabPoint] = []
	_collect_grab_points(body, grab_points)
	for grab_point in grab_points:
		if grab_point.useable:
			return true
	return false


func _collect_grab_points(node: Node, grab_points: Array[XRT2GrabPoint], depth: int = 0) -> void:
	for child in node.get_children():
		if child is XRT2GrabPoint and child.enabled:
			grab_points.append(child)
		elif depth < 2 and child is RigidBody3D:
			_collect_grab_points(child, grab_points, depth + 1)


## Non-useable grab on an object that also has primary/useable grips (gun front grip, etc.).
## Exclusive grips (bolt/slide reload) are excluded — they use full detection radius.
func _is_secondary_support_grab(body : PhysicsBody3D, grab_point : XRT2GrabPoint) -> bool:
	if body == null or grab_point == null or grab_point.useable:
		return false
	if grab_point.exclusive:
		return false
	return _body_has_useable_grab_point(_get_assembly_root(body))


## Brace or bolt/slide: hand moves to the grab, object stays put.
func _should_snap_hand_to_grab(body : PhysicsBody3D, grab_point : XRT2GrabPoint) -> bool:
	if _is_secondary_support_grab(body, grab_point):
		return true
	if body == null or grab_point == null:
		return false
	if grab_point.useable or not grab_point.exclusive:
		return false
	return _body_has_useable_grab_point(_get_assembly_root(body))


func _get_grab_point_max_distance(body : PhysicsBody3D, grab_point : XRT2GrabPoint) -> float:
	if _is_secondary_support_grab(body, grab_point):
		return secondary_grab_distance
	return detection_radius


## Bolt/slide reload grip on a weapon already held by another hand.
func _is_reload_grip(body : PhysicsBody3D, grab_point : XRT2GrabPoint) -> bool:
	if body == null or grab_point == null:
		return false
	if not grab_point.exclusive or grab_point.useable:
		return false
	var root := _get_assembly_root(body)
	if root == null or not _body_has_useable_grab_point(root):
		return false
	# Other hand must already be holding this weapon assembly.
	var holder := picked_up_by(root)
	if holder == null:
		holder = picked_up_by(body)
	return holder != null and holder != self


## Used by HandComponent so loadout grip does not steal bolt/slide reload.
func can_grip_pickup_reload() -> bool:
	if _picked_up or _block_grab_until_release:
		return false
	if not _closest_object or not is_instance_valid(_closest_object.body):
		_update_closest_object()
	if not _closest_object or not is_instance_valid(_closest_object.body):
		return false
	return _is_reload_grip(_closest_object.body, _closest_object.grab_point)


## True when the pending (or current) grab point is a primary/useable grip.
## Defaults false — secondary/bolt must never be treated as fireable mid-grab.
func is_pending_grab_useable() -> bool:
	if _pending_pickup_grab_point and is_instance_valid(_pending_pickup_grab_point):
		return _pending_pickup_grab_point.useable
	if _grab_point and is_instance_valid(_grab_point):
		return _grab_point.useable
	if _closest_object and is_instance_valid(_closest_object.grab_point):
		return _closest_object.grab_point.useable
	return false


## True while holding a non-primary foregrip-style brace (not pistol/walkie grips).
func is_secondary_support_hold() -> bool:
	if not _picked_up or not _grab_point:
		return false
	return _is_secondary_support_grab(_picked_up, _grab_point)


## Foregrip or bolt/slide grips: highlight only meshes near the grab point.
func _uses_local_grab_highlight(
	body: PhysicsBody3D, grab_point: XRT2GrabPoint
) -> bool:
	if grab_point == null:
		return false
	if _is_secondary_support_grab(body, grab_point):
		return true
	if grab_point.useable or not grab_point.exclusive:
		return false
	return _body_has_useable_grab_point(_get_assembly_root(body))


func _should_skip_grab_point_highlight(grab_point: XRT2GrabPoint) -> bool:
	if grab_point == null:
		return false
	if grab_point.highlight_mode == 2:
		return true
	if grab_point.highlight_mode != 1:
		return false
	if grab_point._occupied:
		return true
	var parent := grab_point.get_parent()
	if parent is RigidBody3D:
		var holder := picked_up_by(parent)
		if holder == null:
			# Free body, or bolt while the parent gun is held elsewhere.
			return false
		# Other hand holds a primary on this body: still highlight brace / bolt.
		var holder_gp := holder.get_picked_up_grab_point()
		if holder_gp and holder_gp.useable and not grab_point.useable:
			return false
		# Body already held on a primary (or by this hand): skip.
		return true
	return false


func _get_highlight_target(closest : ClosestObject) -> Node3D:
	return _get_highlight_key(closest.body, closest.grab_point)


func _get_highlight_key(
	body: PhysicsBody3D, grab_point: XRT2GrabPoint
) -> Node3D:
	if grab_point and _uses_local_grab_highlight(body, grab_point):
		return grab_point
	return body


func _apply_highlight_for_closest(closest: ClosestObject) -> void:
	if closest.grab_point and _uses_local_grab_highlight(closest.body, closest.grab_point):
		_add_near_grab_point_highlight(
			_get_assembly_root(closest.body), closest.grab_point
		)
	else:
		_add_highlight(closest.body)


func _clear_highlight_for_closest(
	body: PhysicsBody3D, grab_point: XRT2GrabPoint
) -> void:
	if grab_point and _uses_local_grab_highlight(body, grab_point):
		_remove_highlight(grab_point)
	_remove_highlight(body)


func _get_closest_grabpoint(body : PhysicsBody3D, hand_position : Vector3, ignore_max_distance : bool = false) -> XRT2GrabPoint:
	var is_left_hand : bool = _is_left_hand()
	var closest_grab_point : XRT2GrabPoint = null
	var closest_dist : float = 9999.99

	var assembly_root := _get_assembly_root(body)
	var grab_points: Array[XRT2GrabPoint] = []
	_collect_grab_points(assembly_root, grab_points)

	for grab_point in grab_points:
		if not _grab_point_allowed_for_pickup(assembly_root, grab_point):
			continue
		if is_left_hand:
			if not grab_point.left_hand:
				continue
		else:
			if not grab_point.right_hand:
				continue
		if grab_point._occupied:
			continue

		var dist = (grab_point.get_detection_origin() - hand_position).length_squared()
		var max_dist := _get_grab_point_max_distance(assembly_root, grab_point)
		if not ignore_max_distance and dist > max_dist * max_dist:
			continue
		if dist < closest_dist:
			closest_grab_point = grab_point
			closest_dist = dist
	return closest_grab_point


func _find_secondary_support_grabpoint(
	assembly_root: PhysicsBody3D, hand_position: Vector3
) -> XRT2GrabPoint:
	var other_primary := _other_hand_primary_grab_point(assembly_root)
	if other_primary == null:
		return null

	var is_left_hand := _is_left_hand()
	var grab_points: Array[XRT2GrabPoint] = []
	_collect_grab_points(assembly_root, grab_points)

	var closest_grab_point: XRT2GrabPoint = null
	var closest_dist := 9999.99
	for grab_point in grab_points:
		if not _is_opposite_secondary_for_primary(other_primary, grab_point):
			continue
		if is_left_hand and not grab_point.left_hand:
			continue
		if not is_left_hand and not grab_point.right_hand:
			continue
		if grab_point._occupied:
			continue

		var dist := (grab_point.get_detection_origin() - hand_position).length_squared()
		var max_dist := _get_grab_point_max_distance(assembly_root, grab_point)
		if dist > max_dist * max_dist:
			continue
		if dist < closest_dist:
			closest_grab_point = grab_point
			closest_dist = dist
	return closest_grab_point


# Returns a transform for hand positioning using our default logic.
# Used when there are no grab points.
func _get_default_hand_transform(body : PhysicsBody3D, hand_position : Vector3) -> Transform3D:
	var state : PhysicsDirectSpaceState3D = get_world_3d().direct_space_state

	var params : PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()
	params.from = hand_position
	params.to = body.global_position
	params.exclude = _get_hand_collision_rids()
	
	var result : Dictionary = state.intersect_ray(params)
	if result.is_empty():
		# Huh? This shouldn't happen, missing collision shape?
		return body.global_transform
	else:
		# We're assuming no other object was inbetween
		var is_left_hand : bool = _is_left_hand()

		var t : Transform3D
		t.basis.x = result['normal']
		if is_left_hand:
			t.basis.x = -t.basis.x
		t.basis.y = t.basis.x.cross(-global_basis.z).normalized()
		t.basis.z = t.basis.x.cross(t.basis.y).normalized()
		t.origin = result['position'] + t.basis.y * 0.01
		return t


func _get_closest() -> ClosestObject:
	if not _detection_area.monitoring:
		return null

	var overlapping_bodies = _detection_area.get_overlapping_bodies()
	var closest : ClosestObject
	var closest_dist : float = 9999999.99

	for body : Node3D in overlapping_bodies:
		if _picked_up:
			# Ignore if we already picked up with this hand
			continue
		if body.is_ancestor_of(self):
			# Ignore any of our parents
			continue
		elif _xr_origin.is_ancestor_of(body):
			# Ignore any children of our origin
			continue
		elif body is RigidBody3D and not body.freeze:
			# Always include rigidbodies unless frozen
			# TODO see if we can treat frozen bodies like grabing a static body
			pass
		elif body is RigidBody3D and body.freeze:
			# Seated bolt/slide on a held gun is frozen kinematic so it cannot
			# underdamp the hand joint — still allow the other hand to grab it.
			var assembly_holder := _get_holder_pickup(body)
			if assembly_holder == null or assembly_holder == self:
				continue
		elif body is PhysicalBone3D and _xr_collision_hand:
			# We support picking up PhysicalBone3D if we're using collision hands
			pass
		elif body is StaticBody3D:
			# TODO implement a system for selectively including these
			# (or maybe switch on animatable body)
			continue
		else:
			# Skip anything else
			continue

		var by : XRT2Pickup = _get_holder_pickup(body)
		if by and by._picked_up == body:
			# Check if it's already been picked up by an exclusive grab on this body.
			var on_grab_point = by.get_picked_up_grab_point()
			if on_grab_point and on_grab_point.exclusive:
				# Can't pick this up
				continue

		# Do we have a grab point?
		var new_dist : float = 9999999.99
		var assembly_root_for_body := _get_assembly_root(body as PhysicsBody3D)
		var grab_point = null
		# While the other hand holds a primary grip, prefer brace/foregrip points.
		if _other_hand_holds_primary_on_assembly(assembly_root_for_body):
			grab_point = _find_secondary_support_grabpoint(
				assembly_root_for_body, global_position
			)
		if not grab_point:
			grab_point = _get_closest_grabpoint(body, global_position)
		var target_body : PhysicsBody3D = body
		if grab_point:
			# Bolt/slide grips live on a child RigidBody. Assembly search can
			# return them while overlapping the parent gun — pick up the child.
			var grab_body := grab_point.get_parent() as PhysicsBody3D
			if grab_body:
				target_body = grab_body

			var assembly_root := _get_assembly_root(target_body)
			if not _grab_point_allowed_while_unheld(assembly_root, grab_point):
				continue

			# Exclusive: block a second grab of the *same* body, not a child bolt.
			if by and grab_point.exclusive and by._picked_up == target_body:
				continue

			new_dist = (global_position - grab_point.get_detection_origin()).length_squared()

			# Bolt reload wins in its own zone. Only prefer brace when it is
			# clearly closer — never let a large foregrip radius steal the bolt.
			var other_hand_holds_primary := _other_hand_holds_primary_on_assembly(assembly_root)
			if _is_reload_grip(target_body, grab_point) \
					and other_hand_holds_primary:
				var support_gp := _find_secondary_support_grabpoint(
					assembly_root, global_position
				)
				if support_gp:
					var support_dist := (global_position \
							- support_gp.get_detection_origin()).length_squared()
					# Brace must be nearer than the bolt by a clear margin.
					if support_dist * 1.25 < new_dist:
						grab_point = support_gp
						new_dist = support_dist
						if support_gp.get_parent() is PhysicsBody3D:
							target_body = support_gp.get_parent()
		elif by:
			# Held by another hand — require an in-range support grip, not body center.
			continue
		else:
			# TODO should do our raycast to see if there is nothing between us and the object we're picking up
			
			new_dist = (global_position - body.global_position).length_squared()

		# See if this is our closest object
		if new_dist < closest_dist:
			closest = ClosestObject.new()
			closest.body = target_body
			closest.grab_point = grab_point
			closest_dist = new_dist

	return closest


func _highlight_meshes(node : Node3D) -> Dictionary[MeshInstance3D, Material]:
	var ret : Dictionary[MeshInstance3D, Material]

	if node.has_method("get_highlight_meshes"):
		var mesh_instances : Array[MeshInstance3D] = node.get_highlight_meshes()
		for mesh_instance : MeshInstance3D in mesh_instances:
			ret[mesh_instance] = mesh_instance.material_overlay
			mesh_instance.material_overlay = _highlight_material
	else:
		for child in node.get_children():
			if child.is_in_group("xrt2_no_highlight"):
				# Don't process this node for highlights
				continue

			if child is MeshInstance3D:
				var mesh_instance : MeshInstance3D = child
				if mesh_instance.visible:
					ret[mesh_instance] = mesh_instance.material_overlay
					mesh_instance.material_overlay = _highlight_material

			if child is Node3D and not child is PhysicsBody3D:
				# Find mesh instances any level deep, but not into a new physics body
				var dic : Dictionary[MeshInstance3D, Material] = _highlight_meshes(child)
				ret.merge(dic)

	return ret


func _highlight_meshes_near_point(
	root: Node3D, point: Vector3, radius: float
) -> Dictionary[MeshInstance3D, Material]:
	var ret: Dictionary[MeshInstance3D, Material] = {}
	_collect_meshes_near_point(root, point, radius, ret)
	return ret


func _collect_meshes_near_point(
	node: Node, point: Vector3, radius: float, ret: Dictionary[MeshInstance3D, Material]
) -> void:
	if node.is_in_group("xrt2_no_highlight"):
		return
	if node is MeshInstance3D:
		var mesh_instance: MeshInstance3D = node
		if mesh_instance.visible \
				and mesh_instance.global_position.distance_to(point) <= radius:
			ret[mesh_instance] = mesh_instance.material_overlay
			mesh_instance.material_overlay = _highlight_material
	for child in node.get_children():
		_collect_meshes_near_point(child, point, radius, ret)


func _add_near_grab_point_highlight(
	assembly_root: Node3D, grab_point: XRT2GrabPoint
) -> void:
	if _highlighted_bodies.has(grab_point):
		if not _highlighted_bodies[grab_point].pickups.has(self):
			_highlighted_bodies[grab_point].pickups.push_back(self)
		return

	var search_root: Node3D = assembly_root
	var radius: float = secondary_highlight_radius
	if grab_point.exclusive:
		var parent := grab_point.get_parent()
		if parent is Node3D:
			search_root = parent
		# Bolt meshes can sit slightly farther from the grab-point node origin.
		radius = maxf(secondary_highlight_radius, 0.14)

	var highlight: HighlightedBody = HighlightedBody.new()
	highlight.original_materials = _highlight_meshes_near_point(
		search_root, grab_point.global_position, radius
	)
	highlight.pickups.push_back(self)
	_highlighted_bodies[grab_point] = highlight


# Add highlight to this object.
# If there is already a highlight, we add ourself.
func _add_highlight(node : Node3D):
	
	if _highlighted_bodies.has(node):
		if not _highlighted_bodies[node].pickups.has(self):
			_highlighted_bodies[node].pickups.push_back(self)
		return

	var highlight : HighlightedBody = HighlightedBody.new()
	highlight.original_materials = _highlight_meshes(node)
	highlight.pickups.push_back(self)
	_highlighted_bodies[node] = highlight


# Remove highlight from this object.
# If other pickups are highlighting this object, we only remove ourselves.
func _remove_highlight(node : Node3D):
	if _highlighted_bodies.has(node):
		if _highlighted_bodies[node].pickups.has(self):
			_highlighted_bodies[node].pickups.erase(self)

		if _highlighted_bodies[node].pickups.is_empty():
			for mesh_instance in _highlighted_bodies[node].original_materials:
				if is_instance_valid(mesh_instance) and is_instance_valid(_highlighted_bodies[node]):
					mesh_instance.material_overlay = _highlighted_bodies[node].original_materials[mesh_instance]

			_highlighted_bodies.erase(node)


# Returns [code]true[/code] if we have tracking data for our hand
func _have_tracking_data() -> bool:
	if _xr_collision_hand:
		return _xr_collision_hand.get_has_tracking_data()
	elif _xr_controller:
		return _xr_controller.get_has_tracking_data()
	else:
		return false


# Get the pose used for tracking
func _get_pose() -> XRPose:
	if _xr_collision_hand:
		return _xr_collision_hand.get_pose()
	elif _xr_controller:
		return _xr_controller.get_pose()
	else:
		return null


# Returns our grab input
func _get_action_value(action : String) -> float:
	if _xr_collision_hand:
		var input : Variant = _xr_collision_hand.get_input(action)
		if input:
			return input
	elif _xr_controller:
		return _xr_controller.get_float(action)

	return 0.0


func _is_action_pressed(action : String, was_pressed : bool) -> bool:
	var threshold : float = 0.6 if was_pressed else 0.8
	return _get_action_value(action) > threshold
#endregion
