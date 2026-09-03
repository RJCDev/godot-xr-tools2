#-------------------------------------------------------------------------------
# xrt2_collision_hand.gd
#-------------------------------------------------------------------------------
# MIT License
#
# Copyright (c) 2024-present Bastiaan Olij, Malcolm A Nixon and contributors
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#-------------------------------------------------------------------------------


@tool
class_name XRT2CollisionHand
extends RigidBody3D

## XRTools2 Collision Hand Container Script
##
## This script implements logic for collision hands.
## It encompasses all logic for showing an articulated hand mesh,
## handles its animations, and most importantly, collisions.

#region Signals
## Emitted when a new hand mesh was loaded
signal hand_mesh_changed

## Emitted when the skeleton is updated
signal skeleton_updated

## Emitted when a button on this tracker is pressed. Note that many XR runtimes allow other inputs to be mapped to buttons.
signal button_pressed(action_name: String)

## Emitted when a button on this tracker is released.
signal button_released(action_name: String)

## Emitted when a trigger or similar input on this tracker changes value.
signal input_float_changed(action_name: String, value: float)

## Emitted when a thumbstick or thumbpad on this tracker moves.
signal input_vector2_changed(action_name: String, vector: Vector2)
#endregion

## Modes for collision hand
enum CollisionHandMode {
	## Hand is disabled and must be moved externally
	DISABLED,

	## Hand teleports to target
	TELEPORT,

	## Hand collides with world (based on mask)
	COLLIDE
}


# How much displacement is required for the hand to start orienting to a surface
const ORIENT_DISPLACEMENT := 0.05

#region Export variables

## Should we emit input?
@export var emit_input : bool = true

## Properties related to tracking
@export_group("Tracking")

## Which hand are we tracking?
@export_enum("Left","Right") var hand : int = 0:
	set(value):
		hand = value
		if is_inside_tree():
			_update_hand_meshes()

			if not Engine.is_editor_hint():
				_update_trackers()
				_update_hand_motion_range()

## Set the tracked hand motion range (if supported).
## Note, this is a global setting per hand.
## Having multiple collision hand nodes for the same hand
## will result in the latest hand being configured defining
## this behavior.
@export_enum("Full", "Controller") var hand_motion_range = 0:
	set(value):
		hand_motion_range = value
		if is_inside_tree() and not Engine.is_editor_hint():
			_update_hand_motion_range()


## If true we don't use hand tracking data directly but attempt
## to keep our hand mesh dimensions and only apply rotations.
##
## This is important if we use the pose system when picking items
## up or if we're using a fixed sized avatar.
@export var keep_bone_length: bool = true:
	set(value):
		keep_bone_length = value
		if _hand_modifier:
			_hand_modifier.keep_bone_length = keep_bone_length


## Set finger poses
@export var finger_poses: XRT2FingerPoses:
	set(value):
		finger_poses = value
		if _finger_pose_modifier:
			_finger_pose_modifier.finger_poses = finger_poses


## Set open finger poses
## Set these for adjusting finger position
## based on trigger input (index finger only)
## and/or grip input (little, ring and middle fingers)
@export var open_finger_poses: XRT2FingerPoses:
	set(value):
		open_finger_poses = value
		if _finger_pose_modifier:
			_finger_pose_modifier.open_finger_poses = open_finger_poses


## Fallback settings used if hand tracking isn't available.
@export_subgroup("Fallback", "fallback")

## The fallback pose actions to use, in order of checking.
@export var fallback_pose_actions : Array[String] = [ "palm_pose", "grip" ]

## The fallback offset position to apply.
@export var fallback_offset_position : Vector3

## The fallback offset rotation to apply.
@export_custom(PROPERTY_HINT_RANGE, "-360,360,0.1,or_less,or_greater,radians_as_degrees") \
	var fallback_offset_rotation : Vector3

## Trigger action for our fallback
@export var trigger_action : String = "trigger"

## Degrees to which to curl our index finger.
@export_range(0.0, 90.0, 1.0, "radians_as_degrees") var trigger_curl : float = deg_to_rad(45.0)

## Grip action for our fallback
@export var grip_action : String = "grip"

## Degrees to which to curl our bottom 3 fingers.
@export_range(0.0, 90.0, 1.0, "radians_as_degrees") var grip_curl : float = deg_to_rad(70.0)

## Properties related to physics
@export_group("Physics")

@export var _parent_body: CollisionObject3D

## Controls the hand collision mode
@export var mode : CollisionHandMode = CollisionHandMode.COLLIDE:
	set(value):
		mode = value
		notify_property_list_changed()

## Distance to teleport hands
@export var teleport_distance : float = 1.0

## Shape-query iterations after snap-turn/teleport to free hands/objects from walls.
@export_range(1, 12, 1) var depenetration_iterations : int = 3

## Extra separation applied along each depenetration contact normal.
@export var depenetration_margin_epsilon : float = 0.02

## Physics layers to resolve against (defaults to static world + doors; not teleport blockers).
@export_flags_3d_physics var depenetration_collision_mask : int = 257

## Held-item depenetration for jointed pickups (door frame + door panel only).
@export_flags_3d_physics var held_depenetration_collision_mask : int = 384

## Maximum translation applied per depenetration iteration.
@export var max_depenetration_push : float = 1.0

## Minimum combined push before depenetration runs (avoids micro-false-positives).
@export var depenetration_min_push : float = 0.01

## Extra depenetration passes across subsequent frames after a big teleport.
@export_range(0, 8, 1) var depenetration_followup_frames : int = 1

## Resolve arm penetration after snap-turn/teleport using scene Area3D triggers.
@export var arm_depenetration_enabled : bool = true

## Drop held object if teleport distance is reached?
@export var drop_distance : float = 3.0

## Properties related to physical appearance
@export_group("Appearance")

## Specify an alternative hand scene to use instead of our built-in hand.
## Must be a proper Godot humanoid hand with Skeleton3D but without physics.
@export var alternative_hand_scene : PackedScene:
	set(value):
		alternative_hand_scene = value
		if is_inside_tree():
			_update_hand_meshes()

			if not Engine.is_editor_hint():
				_update_trackers()

## If [code]true[/code], we show our hand mesh.
## This has no effect on collisions or tracking.
@export var show_hand_mesh : bool = true:
	set(value):
		show_hand_mesh = value

		if _hand_mesh:
			_hand_mesh.visible = show_hand_mesh

## If [code]true[/code], we show a ghost hand if hand placement doesn't match.
@export var enable_ghost_hand : bool = true

## Override the material of the hand
@export var material_override : Material:
	set(value):
		material_override = value

		if _hand_mesh:
			_update_hand_material(_hand_mesh, material_override, true)

@export var debug_color : Color = Color(Color.RED, 0.9):
	set(value):
		debug_color = value
		if _palm_collision_shape:
			_palm_collision_shape.debug_color = debug_color

		for bone in _digit_collision_shapes:
			if _digit_collision_shapes[bone]:
				_digit_collision_shapes[bone].debug_color = debug_color
#endregion

## Target-override class
class TargetOverride:
	## Target of the override
	var target : Node3D

	## Target priority
	var priority : int

	## Target offset
	var offset : Transform3D

	## Target-override constructor
	func _init(t : Node3D, p : int, o : Transform3D = Transform3D()):
		target = t
		priority = p
		offset = o


#region Private Variables
# Trackers used
var _hand_tracker: XRHandTracker
var _hand_skeleton: Skeleton3D
var _ghost_skeleton: Skeleton3D
var _controller_tracker: XRControllerTracker
var _pickup: XRT2Pickup
var _was_parent_basis: Basis
var _was_parent_transform: Transform3D

var _force_teleport_allowed : bool = true
var _force_teleport : bool = false
# Extra frames to follow XROrigin after teleport (PlayerBody floor-snaps afterward).
var _sticky_origin_follow: int = 0
# Held rigidbodies frozen during a force-teleport; unfrozen next physics frame.
var _held_bodies_to_unfreeze: Array[RigidBody3D] = []
# Hand-local pose for each held body during snap-turn/teleport recovery.
var _held_snap_local: Dictionary = {}
# Skip tracking forces while the joint settles after snap-turn/teleport.
var _held_teleport_hold_frames: int = 0
# Keep held bodies transform-synced while the hand resumes tracking.
var _held_kinematic_follow_frames: int = 0
var _pending_depenetration: bool = false
var _depenetration_followup_remaining: int = 0
# Render-time follow after snap-turn/teleport (physics may update earlier in the frame).
var _visual_teleport_follow_frames: int = 0
# Suppress parent spin impulse briefly after recovery ends.
var _parent_angular_velocity_cooldown: int = 0

var _last_tracked_transform : Transform3D

# Sorted stack of TargetOverride
var _target_overrides: Array[TargetOverride]

# Current target override
var _target_override: Node3D

# Current target offset
var _target_offset: Transform3D

# Hand meshes
var _hand_mesh: Node3D
var _ghost_mesh: Node3D
## Visible hand pose relative to the active grab point (captured once after orient).
var _hand_mesh_grab_local: Transform3D = Transform3D()
var _hand_mesh_grab_locked: bool = false
var _was_pickup_orienting: bool = false

# Skeleton collisions
var _hand_tracking_parent: XRNode3D
var _palm_collision_shape: CollisionShape3D
var _digit_collision_shapes: Dictionary[String, CollisionShape3D]
var _arm_depenetration_areas: Array[Area3D] = []

const ARM_DEPENETRATION_GROUP_LEFT := "arm_depenetration_left"
const ARM_DEPENETRATION_GROUP_RIGHT := "arm_depenetration_right"

# Target used to position physics colliders inside _integrate_forces.
var _shape_update_target: Transform3D

# Hand pose modifier
var _hand_modifier: XRT2HandModifier3D

# Finger pose modifier
var _finger_pose_modifier: XRT2FingerPosesModifier3D

# Safe Transform

#endregion


#region Public API
## Return a XR collision hand ancestor
static func get_xr_collision_hand(p_node : Node3D) -> XRT2CollisionHand:
	var parent = p_node.get_parent()
	while parent:
		if parent is XRT2CollisionHand:
			return parent

		parent = parent.get_parent()

	# Not found
	return null


## Returns the collision parent object for this collision hand.
## Assumed to be the players body.
func get_collision_parent() -> CollisionObject3D:
	var parent = get_parent()
	while parent:
		if parent is CollisionObject3D:
			return parent
		parent = parent.get_parent()

	return null
#endregion


#region Public Action API
func _force_teleport_behavior():
	if _is_pickup_orienting():
		_apply_origin_delta_to_hand_only()
		return
	if not _force_teleport_allowed:
		return

	# Snap-local glue is only for non-jointed held items (legacy recovery path).
	if _has_held_for_teleport_recovery():
		_capture_held_snap_locals()
	_apply_origin_delta_to_hand_and_held()
	if _has_held_for_teleport_recovery():
		_sync_held_to_snap_locals()
	_pending_depenetration = true
	freeze = true
	_force_teleport = true
	_visual_teleport_follow_frames = 0 if _has_held_for_teleport() else 6
	_parent_angular_velocity_cooldown = 2 if _has_held_for_teleport() else 0
	# PlayerBody runs after this hand and may still move XROrigin (floor snap).
	# Shorter sticky while holding — visual grab-lock covers the gun; less freeze hitch.
	_sticky_origin_follow = 2 if _has_held_for_teleport() else 4
	if _has_held_for_teleport_recovery():
		_held_teleport_hold_frames = 2
	_sync_hand_mesh_to_grab_point()
	call_deferred("_deferred_post_teleport_sync")


func _deferred_post_teleport_sync() -> void:
	if not is_inside_tree():
		return
	if _is_pickup_orienting():
		_apply_origin_delta_to_hand_only()
		return
	if not _force_teleport_allowed:
		return
	_apply_origin_delta_to_hand_and_held()
	_sync_hand_mesh_to_grab_point()


func _on_pickup_held_changed(_by: XRT2Pickup, _what: PhysicsBody3D) -> void:
	_abort_all_teleport_recovery()
	_clear_hand_mesh_grab_lock()
	if not _is_pickup_orienting():
		freeze = false
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
	var parent := get_parent()
	if parent:
		_was_parent_transform = parent.global_transform
		_was_parent_basis = parent.global_basis


func _on_pickup_held_released(
	_by: XRT2Pickup, _what: PhysicsBody3D, _last_hand: bool
) -> void:
	_abort_all_teleport_recovery()
	_clear_hand_mesh_grab_lock()


func _clear_hand_mesh_grab_lock() -> void:
	_hand_mesh_grab_locked = false
	_hand_mesh_grab_local = Transform3D()
	if _hand_mesh:
		_hand_mesh.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_INHERIT

func _abort_all_teleport_recovery() -> void:
	_unfreeze_teleported_held_bodies()
	_held_snap_local.clear()
	_held_kinematic_follow_frames = 0
	_held_teleport_hold_frames = 0
	_held_bodies_to_unfreeze.clear()
	_pending_depenetration = false
	_depenetration_followup_remaining = 0
	_sticky_origin_follow = 0
	_force_teleport = false
	_visual_teleport_follow_frames = 0
	_parent_angular_velocity_cooldown = 0
	_set_arm_depenetration_monitoring(false)


func _on_player_moved_follow_origin(_delta_transform: Transform3D) -> void:
	if _sticky_origin_follow <= 0:
		return
	if _is_pickup_orienting():
		_apply_origin_delta_to_hand_only()
		return
	_apply_origin_delta_to_hand_and_held()


func _should_sync_tracked_position_after_teleport() -> bool:
	return not _has_held_for_teleport()


func _apply_post_teleport_hand_sync(tracked: Transform3D = Transform3D()) -> void:
	if _should_sync_tracked_position_after_teleport():
		_sync_tracked_hand_position_only(tracked)


func _is_valid_tracked_target(target: Transform3D) -> bool:
	return target != Transform3D() and target.origin.is_finite()


func _is_pickup_orienting() -> bool:
	return _pickup != null and _pickup.is_orienting_pickup()


func _is_jointed_held_pickup() -> bool:
	return _pickup != null and _pickup.is_jointed_pickup()


func _is_multi_body_held_pickup() -> bool:
	return _pickup != null and _pickup.is_multi_body_assembly()


func _has_held_for_teleport() -> bool:
	return _pickup != null and _pickup._picked_up is RigidBody3D


func _has_held_for_teleport_recovery() -> bool:
	return _has_held_for_teleport() \
		and not _is_pickup_orienting() \
		and not _is_multi_body_held_pickup()


func _capture_held_snap_locals() -> void:
	_held_snap_local.clear()
	if not _has_held_for_teleport():
		return

	var root: RigidBody3D = _pickup._picked_up
	if not _pickup.is_primary() and _is_directly_held_by_other_pickup(root):
		return

	var anchor := _get_held_snap_anchor_xf()
	for body in _collect_held_rigid_bodies(root):
		if not is_instance_valid(body):
			continue
		if body != root and _is_directly_held_by_other_pickup(body):
			continue
		_held_snap_local[body] = anchor.affine_inverse() * body.global_transform


func _sync_held_to_snap_locals() -> void:
	if not _has_held_for_teleport():
		_held_snap_local.clear()
		return
	if _held_snap_local.is_empty():
		return

	var root: RigidBody3D = _pickup._picked_up
	var current_bodies := _collect_held_rigid_bodies(root)
	for body: RigidBody3D in _held_snap_local.keys():
		if not is_instance_valid(body) or body not in current_bodies:
			_held_snap_local.erase(body)

	var anchor := _get_held_snap_anchor_xf()
	for body: RigidBody3D in _held_snap_local:
		if not is_instance_valid(body):
			continue
		body.global_transform = anchor * _held_snap_local[body]
		body.linear_velocity = Vector3()
		body.angular_velocity = Vector3()
		body.reset_physics_interpolation()


## Keep held bodies glued to the palm during settle. Following the live
## metacarpal reorients the gun as fingers/tracking move.
func _get_held_snap_anchor_xf() -> Transform3D:
	return global_transform


func _freeze_held_snap_bodies() -> void:
	for body: RigidBody3D in _held_snap_local:
		if not is_instance_valid(body) or body.freeze:
			continue
		body.freeze = true
		if not _held_bodies_to_unfreeze.has(body):
			_held_bodies_to_unfreeze.append(body)


func _end_held_teleport_recovery() -> void:
	_held_snap_local.clear()
	_held_kinematic_follow_frames = 0


func _clear_held_snap_locals() -> void:
	_end_held_teleport_recovery()
	_held_teleport_hold_frames = 0


## After world pickup, glue the held body to the hand briefly (holster snap already does this).
func begin_pickup_settle(extra_frames: int = 5) -> void:
	if not _pickup or not is_instance_valid(_pickup._picked_up):
		return
	_capture_held_snap_locals()
	_sync_held_to_snap_locals()
	_begin_held_kinematic_follow(extra_frames)


func end_pickup_settle() -> void:
	_unfreeze_teleported_held_bodies()
	_held_snap_local.clear()
	_held_kinematic_follow_frames = 0
	_held_teleport_hold_frames = 0


func _begin_held_kinematic_follow(extra_frames: int = 3) -> void:
	if _held_snap_local.is_empty():
		return
	_held_kinematic_follow_frames = max(
		_held_kinematic_follow_frames, depenetration_followup_frames + extra_frames
	)
	_freeze_held_snap_bodies()


func _maintain_held_kinematic_follow() -> void:
	if _held_kinematic_follow_frames <= 0 or _held_snap_local.is_empty():
		return
	_held_kinematic_follow_frames -= 1
	_freeze_held_snap_bodies()
	_sync_held_to_snap_locals()


func _clamp_depenetration_push(push: Vector3) -> Vector3:
	var length := push.length()
	if length <= max_depenetration_push or length < 0.000001:
		return push
	return push * (max_depenetration_push / length)


func _run_depenetration() -> bool:
	if not get_has_tracking_data():
		return false
	# Tracked bone-world shape rebuild is expensive. While holding, palm + held
	# body shapes are enough and keep snap-turn/teleport from hitching.
	var use_tracked_bones := _ghost_skeleton != null and not _has_held_for_teleport()
	if use_tracked_bones:
		if _ghost_mesh:
			if _is_valid_tracked_target(_last_tracked_transform):
				_ghost_mesh.global_transform = _last_tracked_transform
			else:
				_ghost_mesh.global_transform = global_transform
		_on_skeleton_updated(true)
	var moved := _resolve_post_origin_depenetration()
	if use_tracked_bones:
		_ghost_mesh.global_transform = global_transform
		_on_skeleton_updated(false)
	return moved


func _is_depenetration_active() -> bool:
	return _pending_depenetration or _depenetration_followup_remaining > 0


func _is_teleport_recovery_active() -> bool:
	return _force_teleport or _sticky_origin_follow > 0 \
		or _held_teleport_hold_frames > 0 or _is_depenetration_active() \
		or _is_held_kinematic_follow_active()


func _is_visual_teleport_follow_active() -> bool:
	if _has_held_for_teleport():
		return false
	return _visual_teleport_follow_frames > 0 or _sticky_origin_follow > 0 \
		or _held_teleport_hold_frames > 0


func _is_held_kinematic_follow_active() -> bool:
	return _held_kinematic_follow_frames > 0 and not _held_snap_local.is_empty()


func _get_player_reference_position() -> Vector3:
	var physics_hands := get_parent()
	if physics_hands and physics_hands.get_parent() is Node3D:
		var xr_origin := physics_hands.get_parent() as Node3D
		var head_cam := xr_origin.get_node_or_null("HeadCam")
		if head_cam is Node3D:
			return head_cam.global_position
		var head := xr_origin.get_node_or_null("Head")
		if head is Node3D:
			return head.global_position
		return xr_origin.global_position
	if _parent_body is Node3D:
		return (_parent_body as Node3D).global_position
	return global_position


func _get_toward_player_direction(from: Vector3) -> Vector3:
	var to_player := _get_player_reference_position() - from
	if to_player.length_squared() < 0.000001:
		return Vector3.ZERO
	return to_player.normalized()


func _constrain_push_toward_player(push: Vector3, from: Vector3) -> Vector3:
	var toward_player := _get_toward_player_direction(from)
	if toward_player == Vector3.ZERO or push.length_squared() < 0.000001:
		return push
	var toward_component := push.dot(toward_player)
	if toward_component <= 0.0:
		return Vector3.ZERO
	return toward_player * toward_component


func _try_finish_pending_depenetration() -> void:
	if not _pending_depenetration:
		return
	if _sticky_origin_follow > 0 or _held_teleport_hold_frames > 0:
		return
	_pending_depenetration = false
	if mode == CollisionHandMode.DISABLED or depenetration_iterations <= 0:
		return
	var moved := _run_depenetration()
	if not moved:
		_set_arm_depenetration_monitoring(false)
		return
	_parent_angular_velocity_cooldown = 2
	# Only enter follow-up frames while still overlapping — avoids freezing the
	# hand/gun when a single MovementRecovery push already cleared penetration.
	var use_tracked_bones := _ghost_skeleton != null and not _has_held_for_teleport()
	if use_tracked_bones:
		_on_skeleton_updated(true)
	var still_overlapping := _peek_depenetration_push().length_squared() > 0.000001
	if use_tracked_bones:
		_on_skeleton_updated(false)
	if still_overlapping:
		_depenetration_followup_remaining = depenetration_followup_frames
		_set_arm_depenetration_monitoring(true)
	else:
		_set_arm_depenetration_monitoring(false)
		_unfreeze_teleported_held_bodies()


func _deferred_depenetration_followup() -> void:
	if not is_inside_tree():
		_set_arm_depenetration_monitoring(false)
		return
	if _depenetration_followup_remaining <= 0:
		_set_arm_depenetration_monitoring(false)
		return
	_depenetration_followup_remaining -= 1
	if not _run_depenetration():
		_depenetration_followup_remaining = 0
	if _depenetration_followup_remaining > 0:
		call_deferred("_deferred_depenetration_followup")
	else:
		_set_arm_depenetration_monitoring(false)
		_unfreeze_teleported_held_bodies()
		if _parent_angular_velocity_cooldown <= 0:
			_parent_angular_velocity_cooldown = 2


func _cache_arm_depenetration_areas() -> void:
	_arm_depenetration_areas.clear()
	if not _parent_body:
		return

	var group_name := ARM_DEPENETRATION_GROUP_LEFT if hand == 0 else ARM_DEPENETRATION_GROUP_RIGHT
	for node in get_tree().get_nodes_in_group(group_name):
		if node is Area3D and _parent_body.is_ancestor_of(node):
			_arm_depenetration_areas.append(node)


func _set_arm_depenetration_monitoring(enabled: bool) -> void:
	if _arm_depenetration_areas.is_empty():
		_cache_arm_depenetration_areas()
	for area in _arm_depenetration_areas:
		if is_instance_valid(area):
			area.monitoring = enabled


## Returns true if hand tracking API is used
func get_is_hand_tracking() -> bool:
	if _hand_tracker and _hand_tracker.has_tracking_data:
		return true

	return false


## Returns the hand tracker if active
func get_hand_tracker() -> XRHandTracker:
	if _hand_tracker and _hand_tracker.has_tracking_data:
		return _hand_tracker

	return null


## Returns the pose object that handles our tracking.
func get_pose() -> XRPose:
	if _hand_tracker:
		var pose : XRPose = _hand_tracker.get_pose("default")
		if pose:
			return pose

	if _controller_tracker:
		for fallback_pose_action in fallback_pose_actions:
			var pose : XRPose = _controller_tracker.get_pose(fallback_pose_action)
			if pose:
				return pose

	return null


## Returns [code]true[/code] if we have tracking data for this hand
func get_has_tracking_data() -> bool:
	var pose = get_pose()
	if pose:
		return pose.has_tracking_data

	return false


## Get our (adjusted) transform from our tracking system.
func get_tracked_transform(as_global : bool = true) -> Transform3D:
	var parent_transform : Transform3D = Transform3D()
	if as_global:
		var parent : Node3D = get_parent()
		if parent:
			parent_transform = parent.global_transform
	
	# Give priority to our hand tracker.
	if _hand_tracker:
		var pose : XRPose = _hand_tracker.get_pose("default")
		if pose and pose.has_tracking_data:
			return parent_transform * pose.get_adjusted_transform()

	# Check our controller tracker.
	if _controller_tracker:
		for fallback_pose_action in fallback_pose_actions:
			var pose : XRPose = _controller_tracker.get_pose(fallback_pose_action)
			if pose and pose.has_tracking_data:
				# TODO: if fallback_pose_action == "grip_pose" must adjust angle!!

				var target : Transform3D
				target.basis = Basis.from_euler(fallback_offset_rotation)
				target.origin = fallback_offset_position
				return parent_transform * pose.get_adjusted_transform() * target

	return Transform3D()


## Get the transform for the given pose action of the normal tracker
func get_pose_transform(pose_action : String) -> Transform3D:
	if _controller_tracker and _hand_tracker:
		var controller_pose : XRPose = _controller_tracker.get_pose(pose_action)
		if controller_pose:
			var hand_pose : XRPose = get_pose()
			if hand_pose:
				# Use our hand controller pose
				var hand_transform : Transform3D = hand_pose.get_adjusted_transform()
				if !get_is_hand_tracking():
					var offset : Transform3D
					offset.basis = Basis.from_euler(fallback_offset_rotation)
					offset.origin = fallback_offset_position
					hand_transform = hand_transform * offset

				return hand_transform.inverse() * controller_pose.get_adjusted_transform()

	return Transform3D()


## Returns value for an associated action
func get_input(action_name) -> Variant:
	if _controller_tracker:
		return _controller_tracker.get_input(action_name)

	return null


## Trigger a haptic pulse on this controller
## Specific to OpenXR:
## - Frequence of 0.0 choses an optimal frequency for a short pulse
## - Duration of -1 choses an optimal duration for a short pulse
func trigger_haptic_pulse(action_name: String, frequency: float = 0.0, amplitude: float = 1.0, duration_sec: float = -1, delay_sec: float = 0):
	var xr_interface = XRServer.primary_interface
	if xr_interface and _controller_tracker:
		xr_interface.trigger_haptic_pulse(action_name, _controller_tracker.name, frequency, amplitude, duration_sec, delay_sec)
#endregion


#region Public Target Override API
## This function adds a target override. The collision hand will attempt to
## move to the highest priority target, or the [XRController3D] if no override
## is specified.
func add_target_override(target : Node3D, priority : int, offset : Transform3D = Transform3D()) \
	-> void:
	# Remove any existing target override from this source
	var modified := _remove_target_override(target)

	# Insert the target override
	_insert_target_override(target, priority, offset)
	modified = true

	# Update the target
	if modified:
		_update_target()


## This function remove a target override.
func remove_target_override(target : Node3D) -> void:
	# Remove the target override
	var modified := _remove_target_override(target)

	# Update the pose
	if modified:
		_update_target()
#endregion


#region Public Skeleton API
## Return a string of bone names for our collision hand
func get_concatenated_bone_names() -> String:
	if not _hand_mesh:
		return ""

	var skeleton : Skeleton3D = _get_skeleton_node(_hand_mesh)
	if not skeleton:
		return ""

	return skeleton.get_concatenated_bone_names()


## Get the transform of the given bone local to our collision hand
func get_bone_transform(bone_name : String) -> Transform3D:
	if not _hand_mesh:
		return Transform3D()

	var skeleton : Skeleton3D = _get_skeleton_node(_hand_mesh)
	if not skeleton:
		return Transform3D()

	var bone_idx = skeleton.find_bone(bone_name)
	var bone_transform : Transform3D = _hand_skeleton.get_bone_global_pose(bone_idx)

	var orient_to_godot : Basis = Basis.from_euler(Vector3(0.5 * PI, 0.5 * -PI, 0.0)) if hand==0 \
		else Basis.from_euler(Vector3(0.5 * PI, PI, 0.5 * PI))
	var bone_offset : Transform3D = Transform3D(orient_to_godot, Vector3())

	return bone_transform * bone_offset
#endregion


#region Private Property Update Functions
func get_palm_diameter() -> float:
	if not _palm_collision_shape or not _palm_collision_shape.shape:
		return 0.05

	var scale := _palm_collision_shape.global_transform.basis.get_scale()
	var max_scale := max(scale.x, max(scale.y, scale.z))

	var shape := _palm_collision_shape.shape

	if shape is SphereShape3D:
		return shape.radius * 2.0 * max_scale

	if shape is CapsuleShape3D:
		return shape.radius * 2.0 * max_scale

	if shape is BoxShape3D:
		var s: Vector3 = shape.size * max_scale
		return min(s.x, min(s.y, s.z))

	return 0.05


# Check if we need different trackers
func _update_trackers():
	var new_hand_tracker : XRHandTracker = \
		XRServer.get_tracker("/user/hand_tracker/left" if hand == 0 else "/user/hand_tracker/right")
	if _hand_tracker != new_hand_tracker:
		# Just assign it
		_hand_tracker = new_hand_tracker

	var new_controller_tracker : XRControllerTracker = \
		XRServer.get_tracker("left_hand" if hand == 0 else "right_hand")
	if _controller_tracker != new_controller_tracker:
		if _controller_tracker:
			_controller_tracker.button_pressed.disconnect(_on_button_pressed)
			_controller_tracker.button_released.disconnect(_on_button_released)
			_controller_tracker.input_float_changed.disconnect(_on_input_float_changed)
			_controller_tracker.input_vector2_changed.disconnect(_on_input_vector2_changed)

		_controller_tracker = new_controller_tracker
		if _controller_tracker:
			_controller_tracker.button_pressed.connect(_on_button_pressed)
			_controller_tracker.button_released.connect(_on_button_released)
			_controller_tracker.input_float_changed.connect(_on_input_float_changed)
			_controller_tracker.input_vector2_changed.connect(_on_input_vector2_changed)


func _update_hand_motion_range():
	var openxr_interface : OpenXRInterface = XRServer.find_interface("OpenXR")
	if openxr_interface and openxr_interface.is_initialized():
		var openxr_hand = OpenXRInterface.HAND_LEFT if hand == 0 else OpenXRInterface.HAND_RIGHT
		var openxr_motion_range : OpenXRInterface.HandMotionRange
		match hand_motion_range:
			0: openxr_motion_range = OpenXRInterface.HAND_MOTION_RANGE_UNOBSTRUCTED
			1: openxr_motion_range = OpenXRInterface.HAND_MOTION_RANGE_CONFORM_TO_CONTROLLER
			_: openxr_motion_range = OpenXRInterface.HAND_MOTION_RANGE_UNOBSTRUCTED

		openxr_interface.set_motion_range(openxr_hand, openxr_motion_range)
#endregion


#region Private Godot Node Functions
# Validate our properties
func _validate_property(property: Dictionary):
	# Always hide these built in properties as we control them
	if property.name in [
		"process_physics_priority",
		"gravity_scale",
		"continuous_cd",
		"custom_integrator",
		"freeze",
		"center_of_mass_mode",
		"center_of_mass",
		"inertia"
	]:
		property.usage = PROPERTY_USAGE_NONE

	if mode != CollisionHandMode.COLLIDE and property.name in [\
		"teleport_distance",
		"drop_on_teleport",
	]:
		property.usage = PROPERTY_USAGE_NONE

# Called when the node enters the scene tree for the first time.
func _ready():
	_palm_collision_shape = CollisionShape3D.new()
	_palm_collision_shape.name = "PalmCol"
	_palm_collision_shape.shape = preload("res://addons/godot-xr-tools2/hands/xrt2_hand_palm.shape")
	# This probably needs to be set based on left or right hand
	_palm_collision_shape.rotation_degrees = Vector3(0.0, 90, 90)
	_palm_collision_shape.disabled = false
	_palm_collision_shape.debug_color = debug_color
	add_child(_palm_collision_shape, false, Node.INTERNAL_MODE_BACK)

	# Hardcode these values
	gravity_scale = 1.0
	continuous_cd = true
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, 0.0, 0.0)
	inertia = Vector3(0.01, 0.01, 0.01)
	# inertia = Vector3(0.0, 0.0, 0.0)

	# Init our hand meshes
	_update_hand_meshes()

	if Engine.is_editor_hint():
		return

	# Disconnect from parent transform as we move to it in the physics step,
	# and boost the physics priority above any grab-drivers or hands.
	top_level = true
	process_physics_priority = -90

	#_parent_body = get_collision_parent()
	if _parent_body:
		# Hands shouldn't collide with a parent collision object
		add_collision_exception_with(_parent_body)
		_parent_body.add_collision_exception_with(self)
		if _parent_body.has_signal("player_moved"):
			_parent_body.player_moved.connect(_on_player_moved_follow_origin)

	var parent : Node3D = get_parent()
	if parent:
		# Store this just in case we need to calculate our parents rotational velocity.
		_was_parent_basis = parent.global_basis
		_was_parent_transform = parent.global_transform

	# If we have a pickup function, get it
	_pickup = XRT2Pickup.get_pickup(self)
	if _pickup:
		_pickup.picked_up.connect(_on_pickup_held_changed)
		_pickup.dropped.connect(_on_pickup_held_released)

	# Make sure our trackers are and stay correct
	_update_trackers()
	XRServer.tracker_added.connect(_on_tracker_signal)
	XRServer.tracker_removed.connect(_on_tracker_signal)
	XRServer.tracker_updated.connect(_on_tracker_signal)

	# Update our hand motion range
	_update_hand_motion_range()

	# Update the target
	_update_target()
	_cache_arm_depenetration_areas()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _visual_teleport_follow_frames > 0:
		_visual_teleport_follow_frames -= 1
	if not _held_snap_local.is_empty() and _is_visual_teleport_follow_active():
		_sync_held_to_snap_locals()

	# Foregrip only: glue visible hand to grab point after orient. Primary grips
	# (pistol, walkie, rifle stock) follow the physics hand normally.
	var orienting := _is_pickup_orienting()
	if _was_pickup_orienting and not orienting:
		if _should_sync_hand_mesh_to_grab():
			_capture_hand_mesh_grab_lock()
		else:
			_clear_hand_mesh_grab_lock()
	_was_pickup_orienting = orienting
	if _hand_mesh_grab_locked or _should_sync_hand_mesh_to_grab():
		_sync_hand_mesh_to_grab_point()


func _should_sync_hand_mesh_to_grab() -> bool:
	return _pickup != null \
			and _pickup.has_method("is_secondary_support_hold") \
			and _pickup.is_secondary_support_hold()


func _capture_hand_mesh_grab_lock() -> void:
	if not _hand_mesh or not _pickup or not is_instance_valid(_pickup._picked_up):
		return
	var grab_point = _pickup.get_picked_up_grab_point()
	if not grab_point:
		return
	# Match get_hand_transform (includes rotation_offset) used at pickup time.
	var grab_xf: Transform3D = _get_grab_point_hand_xf(grab_point)
	_hand_mesh_grab_local = grab_xf.affine_inverse() * _hand_mesh.global_transform
	_hand_mesh_grab_local.basis = _hand_mesh_grab_local.basis.orthonormalized()
	_hand_mesh_grab_locked = true
	_hand_mesh.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


func _get_grab_point_hand_xf(grab_point: XRT2GrabPoint) -> Transform3D:
	var grab_xf: Transform3D = grab_point.get_hand_transform(global_position)
	grab_xf.basis = grab_xf.basis.orthonormalized()
	return grab_xf


## Keep the visible hand glued to the held grab point (not the lagged physics palm).
func _sync_hand_mesh_to_grab_point() -> void:
	if not _should_sync_hand_mesh_to_grab():
		if _hand_mesh_grab_locked:
			_clear_hand_mesh_grab_lock()
		return
	if not _hand_mesh or not _pickup or not is_instance_valid(_pickup._picked_up):
		return
	if _is_pickup_orienting():
		return
	var grab_point = _pickup.get_picked_up_grab_point()
	if not grab_point:
		return
	if _pickup._tween and _pickup._tween.is_valid():
		return
	if not _hand_mesh_grab_locked:
		_capture_hand_mesh_grab_lock()
		if not _hand_mesh_grab_locked:
			return

	var grab_xf: Transform3D = _get_grab_point_hand_xf(grab_point)
	var xf: Transform3D = grab_xf * _hand_mesh_grab_local
	xf.basis = xf.basis.orthonormalized() * XRServer.world_scale
	_hand_mesh.global_transform = xf


# Handle physics processing
func _physics_process(delta):
	if Engine.is_editor_hint():
		return

	var parent_transform : Transform3D = Transform3D()
	var parent : Node3D = get_parent()
	if parent:
		parent_transform = parent.global_transform 

	# Handle DISABLED.
	if mode == CollisionHandMode.DISABLED:
		freeze = true
		_was_parent_basis = parent_transform.basis
		_was_parent_transform = parent_transform
		return

	var target : Transform3D = get_tracked_transform()
	
	# Wait for valid tracking before driving hand physics.
	if not _is_valid_tracked_target(target):
		if not _is_valid_tracked_target(_last_tracked_transform):
			_was_parent_basis = parent_transform.basis
			_was_parent_transform = parent_transform
			return
		target = _last_tracked_transform
		
	# Check target override
	if _target_override:
		target = _target_override.global_transform * _target_offset

	_shape_update_target = target

	# Handle TELEPORT
	if mode == CollisionHandMode.TELEPORT:
		freeze = true
		global_transform = target
		_was_parent_basis = parent_transform.basis
		_was_parent_transform = parent_transform
		return

	# We got this far, make sure we're unfrozen and let Godot position our hand.
	if freeze and not _is_teleport_recovery_active():
		freeze = false
		linear_velocity = Vector3()
		angular_velocity = Vector3()
		_parent_angular_velocity_cooldown = 2

	if not _is_held_kinematic_follow_active() and _held_bodies_to_unfreeze.size() > 0 \
			and not _is_teleport_recovery_active():
		_unfreeze_teleported_held_bodies()
		_end_held_teleport_recovery()

	# Get information about our parent body velocities
	var parent_linear_velocity : Vector3 = Vector3()
	var parent_angular_velocity : Vector3 = Vector3()
	var parent_global_position : Vector3 = Vector3()
	var parent_global_basis : Basis = Basis()
	if _parent_body:
		parent_global_position = _parent_body.global_position
		parent_global_basis = _parent_body.global_basis
		if _parent_body is RigidBody3D:
			parent_linear_velocity = _parent_body.linear_velocity
			parent_angular_velocity = _parent_body.angular_velocity
		elif _parent_body is CharacterBody3D:
			parent_linear_velocity = _parent_body.velocity + _parent_body.get_platform_velocity()
			# Calculate our parents angular velocity.
			# Our characterbody also includes our physical movement and we would double account for this.
			parent_angular_velocity = XRT2Helper.rotation_to_axis_angle(_was_parent_basis, parent_transform.basis) / delta
	# TODO: If physics runs at a higher update rate than we get tracking,
	# we should adjust our proportional value accordingly
	
	# Handle dropping if too far from target, and grab point visual movement
	if _pickup and _pickup._picked_up and not _is_pickup_orienting():
		var grab_point = _pickup.get_picked_up_grab_point()
		
		var distance = _last_tracked_transform.origin.distance_to(_pickup._picked_up.global_position)
		if grab_point:
			distance = _last_tracked_transform.origin.distance_to(grab_point.global_position)
			
		# Drop if too far		
		if distance > drop_distance:
			if _pickup and _pickup.picked_up:
				_pickup.drop_held_object()
				
	# Handle hand too far from target tracking target.
	var did_force_teleport := false
	var skip_tracking := false
	if _force_teleport or _sticky_origin_follow > 0:
		# Origin delta already applied in the teleport/turn signal and any
		# following PlayerBody origin corrections (floor snap).
		did_force_teleport = true
		skip_tracking = true
		_force_teleport = false
		if _sticky_origin_follow > 0:
			_sticky_origin_follow -= 1
		freeze = true
		linear_velocity = Vector3()
		angular_velocity = Vector3()
		if not _held_snap_local.is_empty():
			_sync_held_to_snap_locals()
		if _sticky_origin_follow == 0 and _held_teleport_hold_frames <= 0:
			_try_finish_pending_depenetration()
	elif _held_teleport_hold_frames > 0:
		# Keep the held object glued to the hand while the joint recovers.
		skip_tracking = true
		_held_teleport_hold_frames -= 1
		_sync_held_to_snap_locals()
		_freeze_held_snap_bodies()
		freeze = true
		linear_velocity = Vector3()
		angular_velocity = Vector3()
		if _held_teleport_hold_frames <= 0:
			_try_finish_pending_depenetration()
	elif _is_pickup_orienting():
		# Joint is settling — only follow origin rotation, not tracking forces.
		skip_tracking = true
		freeze = true
		linear_velocity = Vector3()
		angular_velocity = Vector3()
	elif _depenetration_followup_remaining > 0:
		skip_tracking = true
		freeze = true
		linear_velocity = Vector3()
		angular_velocity = Vector3()
		_depenetration_followup_remaining -= 1
		if not _run_depenetration():
			_depenetration_followup_remaining = 0
		if _depenetration_followup_remaining <= 0:
			_set_arm_depenetration_monitoring(false)
			_unfreeze_teleported_held_bodies()
			if _parent_angular_velocity_cooldown <= 0:
				_parent_angular_velocity_cooldown = 2
	elif _is_held_kinematic_follow_active():
		skip_tracking = true
		freeze = true
		linear_velocity = Vector3()
		angular_velocity = Vector3()
		_maintain_held_kinematic_follow()
	elif not _has_held_for_teleport() \
			and _is_valid_tracked_target(target) \
			and global_position.distance_to(target.origin) > teleport_distance:
		var safe_target := target
		_teleport_held_bodies_with_hand(global_transform, safe_target)

		freeze = true
		global_transform = safe_target

		linear_velocity = Vector3()
		angular_velocity = Vector3()
		reset_physics_interpolation()

		if _parent_body:
			_parent_body.reset_physics_interpolation()

	# Do not apply tracking forces the same frame as a player teleport/turn.
	# Parent snap-turn angular velocity would double-rotate the hand and yank
	# the jointed object (visible dip + slide click detectors).
	if not skip_tracking:
		if _parent_angular_velocity_cooldown > 0:
			parent_angular_velocity = Vector3.ZERO
			_parent_angular_velocity_cooldown -= 1
		XRT2Helper.apply_force_to_target(delta, self, target.origin,
			1.0, parent_linear_velocity, parent_angular_velocity, parent_global_position
		)

		# Apply angular motion to hands.
		XRT2Helper.apply_torque_to_target(
			delta, self, target.basis, 1.0, parent_angular_velocity, parent_global_basis
		)

	# Remember this in case we need it
	_was_parent_basis = parent_transform.basis
	_was_parent_transform = parent_transform
	_last_tracked_transform = target

	# Ghost mesh tracks the controller for reach-limit feedback only.
	if _ghost_mesh:
		_ghost_mesh.global_transform = target
		# Bone copy already happens in _on_skeleton_updated. Extra copy while
		# frozen doubled skeleton work every physics tick during settle/teleport.

	# Our hand should now be positioned so we can do our ghost logic.
	if _ghost_mesh:
		_ghost_mesh.visible = false
		if enable_ghost_hand:
			if (_ghost_mesh.global_position - _hand_mesh.global_position).length() > 0.005:
				_ghost_mesh.visible = true
			else:
				if (_ghost_mesh.global_basis * _hand_mesh.global_basis.inverse()) \
					.get_rotation_quaternion().get_angle() > deg_to_rad(15.0):
					_ghost_mesh.visible = true

	# Adjust for world scale
	var world_scale = XRServer.world_scale
	if _ghost_mesh.visible:
		_ghost_mesh.scale = Vector3(world_scale, world_scale, world_scale)
	# While holding, _process owns hand_mesh pose via grab-lock (do not touch here).
	if _hand_mesh.visible and not (_pickup and is_instance_valid(_pickup._picked_up)):
		_hand_mesh.scale = Vector3(world_scale, world_scale, world_scale)

func _integrate_forces(_state: PhysicsDirectBodyState3D) -> void:
	if mode != CollisionHandMode.COLLIDE:
		return
	if freeze or _is_depenetration_active():
		return
	if not _ghost_mesh or not _ghost_skeleton:
		return
	if not _is_valid_tracked_target(_shape_update_target):
		return
	_ghost_mesh.global_transform = _shape_update_target
	_on_skeleton_updated(false)


#region Private Target Override Functions
# This function inserts a target override into the overrides list by priority
# order.
func _insert_target_override( \
	target : Node3D, priority : int, offset : Transform3D = Transform3D() \
	) -> void:
	# Construct the target override
	var override := TargetOverride.new(target, priority, offset)

	# Iterate over all target overrides in the list
	for pos in _target_overrides.size():
		# Get the target override
		var o : TargetOverride = _target_overrides[pos]

		# Insert as early as possible to not invalidate sorting
		if o.priority <= priority:
			_target_overrides.insert(pos, override)
			return

	# Insert at the end
	_target_overrides.push_back(override)


# This function removes a target from the overrides list
func _remove_target_override(target : Node) -> bool:
	var pos := 0
	var length := _target_overrides.size()
	var modified := false

	# Iterate over all pose overrides in the list
	while pos < length:
		# Get the target override
		var o : TargetOverride = _target_overrides[pos]

		# Check for a match
		if o.target == target:
			# Remove the override
			_target_overrides.remove_at(pos)
			modified = true
			length -= 1
		else:
			# Advance down the list
			pos += 1

	# Return the modified indicator
	return modified


# This function updates the target for hand movement.
func _update_target() -> void:
	# Assume no current override.
	_target_override = null
	_target_offset = Transform3D()

	# Use first target override if specified
	if _target_overrides.size():
		_target_override = _target_overrides[0].target
		_target_offset = _target_overrides[0].offset

		if mode != CollisionHandMode.DISABLED:
			# Reposition to our target override
			global_transform = _target_override.global_transform * _target_offset


func _teleport_held_bodies_with_hand(from_hand: Transform3D, to_hand: Transform3D) -> void:
	_teleport_held_bodies(to_hand * from_hand.affine_inverse())


#region MovementRecovery
# Tag: MovementRecovery — baseline snap-turn/teleport + held coupling.
# Depenetration must move the hand and held assembly through these helpers only.
# To restore this behavior, revert changes outside this region that alter these
# functions or depenetration's use of _apply_translation_to_hand_and_held().


func _apply_origin_delta_to_hand_only() -> void:
	var parent: Node3D = get_parent()
	var current_parent := parent.global_transform if parent else Transform3D()
	var parent_delta := current_parent * _was_parent_transform.affine_inverse()
	parent_delta.basis = parent_delta.basis.orthonormalized()
	if _apply_rigid_delta_to_hand_and_held(parent_delta, false):
		_was_parent_transform = current_parent
		_was_parent_basis = current_parent.basis


func _apply_origin_delta_to_hand_and_held() -> void:
	var parent: Node3D = get_parent()
	var current_parent := parent.global_transform if parent else Transform3D()
	var parent_delta := current_parent * _was_parent_transform.affine_inverse()
	parent_delta.basis = parent_delta.basis.orthonormalized()
	if _apply_rigid_delta_to_hand_and_held(parent_delta, true):
		_was_parent_transform = current_parent
		_was_parent_basis = current_parent.basis


func _apply_translation_to_hand_and_held(
	translation: Vector3, freeze_held: bool = true
) -> bool:
	if translation.length_squared() < 0.000001:
		return false
	return _apply_rigid_delta_to_hand_and_held(
		Transform3D(Basis.IDENTITY, translation), true, freeze_held
	)


func _apply_rigid_delta_to_hand_and_held(
	delta: Transform3D, move_held: bool, freeze_held: bool = true
) -> bool:
	var moved := delta.origin.length_squared() > 0.00000001
	if not moved:
		var angle := delta.basis.get_rotation_quaternion().get_angle()
		moved = angle > 0.0001
	if not moved:
		return false

	global_transform = delta * global_transform
	linear_velocity = Vector3()
	angular_velocity = Vector3()
	reset_physics_interpolation()
	if move_held and _has_held_for_teleport():
		_teleport_held_bodies(delta, freeze_held)
	return true


#endregion MovementRecovery


func _sync_tracked_hand_position_only(tracked: Transform3D = Transform3D()) -> void:
	if not get_has_tracking_data():
		return
	var resolved := tracked
	if not _is_valid_tracked_target(resolved):
		resolved = get_tracked_transform()
	if not _is_valid_tracked_target(resolved):
		return
	var hand_xf := global_transform
	hand_xf.origin = resolved.origin
	global_transform = hand_xf
	linear_velocity = Vector3()
	angular_velocity = Vector3()
	reset_physics_interpolation()


func _teleport_held_bodies(delta: Transform3D, freeze_bodies: bool = true) -> void:
	if not _pickup or not _pickup._picked_up is RigidBody3D:
		return

	var root: RigidBody3D = _pickup._picked_up

	# Support grip on the same body as another hand: that primary moves it.
	if not _pickup.is_primary() and _is_directly_held_by_other_pickup(root):
		return

	for body in _collect_held_physics_bodies(root):
		if not is_instance_valid(body):
			continue
		# Pump/slide etc. held by the other hand — that hand applies the delta.
		if body != root and _is_directly_held_by_other_pickup(body):
			continue
		body.global_transform = delta * body.global_transform
		body.linear_velocity = Vector3()
		body.angular_velocity = Vector3()
		body.reset_physics_interpolation()
		if freeze_bodies and not body.freeze:
			body.freeze = true
			_held_bodies_to_unfreeze.append(body)


func _is_directly_held_by_other_pickup(body: PhysicsBody3D) -> bool:
	if body == null or _pickup == null:
		return false
	for other in XRT2Pickup._pickup_handlers:
		if other == _pickup or not is_instance_valid(other):
			continue
		if other._picked_up == body:
			return true
	return false


func _collect_held_rigid_bodies(root: Node) -> Array[RigidBody3D]:
	var bodies: Array[RigidBody3D] = []
	_collect_held_rigid_bodies_recursive(root, bodies)
	return bodies


func _get_held_assembly_root(grabbed: RigidBody3D) -> RigidBody3D:
	var assembly_root := grabbed
	var node := grabbed.get_parent()
	while node:
		if node is RigidBody3D:
			assembly_root = node
			break
		node = node.get_parent()
	return assembly_root


func _collect_held_physics_bodies(grabbed: RigidBody3D) -> Array[RigidBody3D]:
	# Rifles grab the slide child; meshes and barrel rays live on the parent body.
	# Move every rigidbody in the held assembly by the same origin delta.
	return _collect_held_rigid_bodies(_get_held_assembly_root(grabbed))


func _collect_held_rigid_bodies_recursive(node: Node, bodies: Array[RigidBody3D]) -> void:
	if node is RigidBody3D:
		bodies.append(node)
	for child in node.get_children():
		_collect_held_rigid_bodies_recursive(child, bodies)


func _unfreeze_teleported_held_bodies() -> void:
	for body in _held_bodies_to_unfreeze:
		if not is_instance_valid(body):
			continue
		body.freeze = false
		body.linear_velocity = Vector3()
		body.angular_velocity = Vector3()
	_held_bodies_to_unfreeze.clear()


func _resolve_post_origin_depenetration() -> bool:
	if mode == CollisionHandMode.DISABLED or depenetration_iterations <= 0:
		return false
	if not get_has_tracking_data():
		return false

	var moved := false
	for _iteration in depenetration_iterations:
		var push := _peek_depenetration_push()
		if push.length_squared() < 0.000001:
			break
		_apply_translation_to_hand_and_held(push, false)
		moved = true

	if not moved:
		return false

	linear_velocity = Vector3()
	angular_velocity = Vector3()
	reset_physics_interpolation()
	return true


func _peek_depenetration_push() -> Vector3:
	var push := Vector3.ZERO
	push += _compute_hand_collision_shapes_push()
	# Arm segment queries are the heavy path; skip while holding — the held
	# body queries cover door/wall penetration for the gun itself.
	if not _has_held_for_teleport():
		push += _compute_arm_segment_depenetration_push()
	for body in _get_held_depenetration_bodies():
		push += _compute_held_collision_shapes_push(body, held_depenetration_collision_mask)
	push = _constrain_push_toward_player(push, global_transform.origin)
	push = _clamp_depenetration_push(push)
	if push.length() < depenetration_min_push:
		return Vector3.ZERO
	return push


func _get_held_depenetration_bodies() -> Array[RigidBody3D]:
	var bodies: Array[RigidBody3D] = []
	if not _pickup or not _pickup._picked_up is RigidBody3D:
		return bodies

	var root: RigidBody3D = _pickup._picked_up
	if not _pickup.is_primary() and _is_directly_held_by_other_pickup(root):
		return bodies

	for body in _collect_held_physics_bodies(root):
		if not is_instance_valid(body):
			continue
		if body != root and _is_directly_held_by_other_pickup(body):
			continue
		bodies.append(body)

	return bodies


func _compute_body_recovery_push_filtered(
	body: PhysicsBody3D, from_transform: Transform3D
) -> Vector3:
	var params := PhysicsTestMotionParameters3D.new()
	params.from = from_transform
	params.motion = Vector3.ZERO
	params.margin = depenetration_margin_epsilon
	params.recovery_as_collision = true

	var result := PhysicsTestMotionResult3D.new()
	if not PhysicsServer3D.body_test_motion(body.get_rid(), params, result):
		return Vector3.ZERO

	var excluded := _get_depenetration_exclude_rids()
	var toward_player := _get_toward_player_direction(from_transform.origin)
	var push := Vector3.ZERO
	for i in result.get_collision_count():
		var collider := result.get_collider(i)
		if collider is CollisionObject3D:
			var collision_object := collider as CollisionObject3D
			if excluded.has(collision_object.get_rid()):
				continue
			if (collision_object.collision_layer & depenetration_collision_mask) == 0:
				continue
		var depth: float = result.get_collision_depth(i)
		var normal: Vector3 = result.get_collision_normal(i)
		if toward_player != Vector3.ZERO and normal.dot(toward_player) < 0.0:
			normal = -normal
		if toward_player != Vector3.ZERO and normal.dot(toward_player) <= 0.0:
			continue
		push += normal * max(depth, depenetration_margin_epsilon)

	return push


func _compute_hand_collision_shapes_push() -> Vector3:
	return _compute_collision_shapes_push_for_mask(depenetration_collision_mask)


func _compute_collision_shapes_push_for_mask(collision_mask: int) -> Vector3:
	var push := Vector3.ZERO

	if _palm_collision_shape and _palm_collision_shape.shape:
		var palm_scale := _palm_collision_shape.global_transform.basis.get_scale()
		var palm_max_scale := max(palm_scale.x, max(palm_scale.y, palm_scale.z))
		var palm_margin := _get_shape_max_half_extent(
			_palm_collision_shape.shape, palm_max_scale
		)
		push += _compute_shape_query_push(
			_palm_collision_shape.shape,
			_palm_collision_shape.global_transform,
			palm_margin,
			collision_mask
		)

	for bone_name in _digit_collision_shapes:
		var col_shape: CollisionShape3D = _digit_collision_shapes[bone_name]
		if not col_shape.shape or col_shape.disabled:
			continue
		var shape_scale := col_shape.global_transform.basis.get_scale()
		var max_scale := max(shape_scale.x, max(shape_scale.y, shape_scale.z))
		var margin := _get_shape_max_half_extent(col_shape.shape, max_scale)
		push += _compute_shape_query_push(
			col_shape.shape, col_shape.global_transform, margin, collision_mask
		)

	return push


func _compute_arm_segment_depenetration_push() -> Vector3:
	if not arm_depenetration_enabled:
		return Vector3.ZERO

	if _arm_depenetration_areas.is_empty():
		_cache_arm_depenetration_areas()

	var push := Vector3.ZERO
	for area in _arm_depenetration_areas:
		if not is_instance_valid(area):
			continue
		for child in area.get_children():
			if child is CollisionShape3D:
				var col_shape: CollisionShape3D = child
				if not col_shape.shape or col_shape.disabled:
					continue
				var shape_scale := col_shape.global_transform.basis.get_scale()
				var max_scale := max(shape_scale.x, max(shape_scale.y, shape_scale.z))
				var margin := _get_shape_max_half_extent(col_shape.shape, max_scale)
				push += _compute_shape_query_push(
					col_shape.shape,
					col_shape.global_transform,
					margin,
					depenetration_collision_mask
				)

	return push


func _update_hand_collision_shapes() -> void:
	if _ghost_skeleton:
		_on_skeleton_updated(false)


func _collect_collision_shapes(node: Node, shapes: Array[CollisionShape3D]) -> void:
	if node is CollisionShape3D:
		shapes.append(node)
	for child in node.get_children():
		_collect_collision_shapes(child, shapes)


func _compute_held_collision_shapes_push(
	body: RigidBody3D, collision_mask: int = 0
) -> Vector3:
	if collision_mask == 0:
		collision_mask = depenetration_collision_mask
	var push := Vector3.ZERO
	var shapes: Array[CollisionShape3D] = []
	_collect_collision_shapes(body, shapes)
	var toward_player := _get_toward_player_direction(body.global_position)
	if toward_player == Vector3.ZERO:
		return push

	for col_shape in shapes:
		if not col_shape.shape or col_shape.disabled:
			continue
		var shape_scale := col_shape.global_transform.basis.get_scale()
		var max_scale := max(shape_scale.x, max(shape_scale.y, shape_scale.z))
		var margin := _get_shape_extent_along_direction(
			col_shape.shape, col_shape.global_transform.basis, toward_player, max_scale
		)
		push += _compute_shape_query_push(
			col_shape.shape, col_shape.global_transform, margin, collision_mask
		)

	return push


func _get_shape_extent_along_direction(
	shape: Shape3D, shape_basis: Basis, world_direction: Vector3, max_scale: float
) -> float:
	var dir := world_direction.normalized()
	var local_dir := shape_basis.inverse() * dir
	local_dir = Vector3(abs(local_dir.x), abs(local_dir.y), abs(local_dir.z))
	if shape is BoxShape3D:
		var box: BoxShape3D = shape
		var half: Vector3 = box.size * max_scale * 0.5
		return local_dir.x * half.x + local_dir.y * half.y + local_dir.z * half.z
	if shape is CapsuleShape3D:
		var capsule: CapsuleShape3D = shape
		var radius: float = capsule.radius * max_scale
		var half_height: float = capsule.height * 0.5 * max_scale
		var axis_extent: float = half_height - radius
		if axis_extent < 0.0:
			axis_extent = 0.0
		# Capsule aligned to local Y in Godot.
		return radius + axis_extent * local_dir.y
	if shape is CylinderShape3D:
		var cylinder: CylinderShape3D = shape
		var radius: float = cylinder.radius * max_scale
		var half_height: float = cylinder.height * 0.5 * max_scale
		return radius + (half_height - radius) * local_dir.y
	return _get_shape_max_half_extent(shape, max_scale)


func _get_shape_max_half_extent(shape: Shape3D, max_scale: float) -> float:
	if shape is SphereShape3D:
		return shape.radius * max_scale
	if shape is CapsuleShape3D:
		return max(shape.radius, shape.height * 0.5) * max_scale
	if shape is BoxShape3D:
		var box_shape: BoxShape3D = shape
		var size: Vector3 = box_shape.size * max_scale
		return max(size.x, max(size.y, size.z)) * 0.5
	if shape is CylinderShape3D:
		return max(shape.radius, shape.height * 0.5) * max_scale
	return 0.025 * max_scale


func _get_depenetration_exclude_rids() -> Array[RID]:
	var exclude: Array[RID] = [get_rid()]
	if _parent_body and is_instance_valid(_parent_body):
		_append_collision_rids(_parent_body, exclude)

	var physics_hands := get_parent()
	if physics_hands:
		for sibling in physics_hands.get_children():
			if sibling is CollisionObject3D and sibling != self:
				_append_collision_rids(sibling, exclude)

	if _pickup and _pickup._picked_up is RigidBody3D:
		for body in _collect_held_physics_bodies(_pickup._picked_up):
			if is_instance_valid(body):
				_append_collision_rids(body, exclude)

	return exclude


func _append_collision_rids(node: Node, exclude: Array[RID]) -> void:
	if node is CollisionObject3D:
		var rid := (node as CollisionObject3D).get_rid()
		if not exclude.has(rid):
			exclude.append(rid)
	for child in node.get_children():
		_append_collision_rids(child, exclude)


func _compute_shape_query_push(
	shape: Shape3D, shape_transform: Transform3D, margin: float,
	collision_mask: int = 0
) -> Vector3:
	if collision_mask == 0:
		collision_mask = depenetration_collision_mask
	var space_state := get_world_3d().direct_space_state if get_world_3d() else null
	if not space_state:
		return Vector3.ZERO

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = shape_transform
	params.collision_mask = collision_mask
	params.collide_with_areas = false
	params.exclude = _get_depenetration_exclude_rids()

	var origin := shape_transform.origin
	var toward_player := _get_toward_player_direction(origin)
	if toward_player == Vector3.ZERO:
		return Vector3.ZERO

	var separation := margin + depenetration_margin_epsilon
	var probe_distance := margin + max_depenetration_push

	params.motion = Vector3.ZERO
	if space_state.intersect_shape(params, 8).is_empty():
		return Vector3.ZERO

	var push := Vector3.ZERO

	for contact_point: Vector3 in space_state.collide_shape(params, 16):
		var escape := origin - contact_point
		if escape.length_squared() < 0.000001:
			continue
		escape = escape.normalized()
		if escape.dot(toward_player) < 0.0:
			escape = -escape
		if escape.dot(toward_player) <= 0.0:
			continue
		push += escape * separation

	# Measure penetration depth by casting into the obstacle. When embedded, casting
	# toward the player is often unobstructed, so probe both directions.
	var best_depth := 0.0
	for direction: Vector3 in [toward_player, -toward_player]:
		params.motion = direction * probe_distance
		var fractions := space_state.cast_motion(params)
		var safe_fraction := fractions[0] if fractions.size() > 0 else 1.0
		if safe_fraction < 1.0:
			var depth := probe_distance * (1.0 - safe_fraction)
			if depth > best_depth:
				best_depth = depth

	if best_depth > 0.0:
		push += toward_player * max(best_depth + depenetration_margin_epsilon, separation)

	return push


func get_safe_sweep_target(target: Transform3D) -> Transform3D:
	var start := global_transform
	var distance := start.origin.distance_to(target.origin)

	if distance <= 0.001:
		return target

	var diameter := max(get_palm_diameter(), 0.01)

	# Use half diameter so thin geometry is harder to skip.
	var step_size = diameter * 0.5
	var steps := max(1, int(ceil(distance / step_size)))

	var previous_safe := start
	var current := start

	for i in range(1, steps + 1):
		var t := float(i) / float(steps)

		var next := start.interpolate_with(target, t)
		var motion := next.origin - current.origin

		var params := PhysicsTestMotionParameters3D.new()
		params.from = current
		params.motion = motion
		params.margin = 0.01
		params.recovery_as_collision = true

		var result := PhysicsTestMotionResult3D.new()

		var hit := PhysicsServer3D.body_test_motion(
			get_rid(),
			params,
			result
		)

		if hit:
			return previous_safe

		previous_safe = next
		current = next

	return target
#endregion


#region Private Hand Mesh Functions
# Find the skeleton node child
func _get_skeleton_node(p_node : Node) -> Skeleton3D:
	for child in p_node.get_children():
		if child is Skeleton3D:
			return child

		var ret : Skeleton3D = _get_skeleton_node(child)
		if ret:
			return ret

	return null


# Add modifier nodes to our hand meshes
func _add_hand_modifiers(p_hand_mesh : Node3D) -> void:
	var skeleton_node = _get_skeleton_node(p_hand_mesh)
	if not skeleton_node:
		push_error("Couldn't locate skeleton node for " + name)
		return

	# Add XRT2 hand modifier
	_hand_modifier = XRT2HandModifier3D.new()
	_hand_modifier.keep_bone_length = keep_bone_length
	_hand_modifier.trigger_action = trigger_action
	_hand_modifier.trigger_curl = trigger_curl
	_hand_modifier.grip_action = grip_action
	_hand_modifier.grip_curl = grip_curl
	skeleton_node.add_child(_hand_modifier)

	# Add finger poses modifier
	_finger_pose_modifier = XRT2FingerPosesModifier3D.new()
	_finger_pose_modifier.finger_poses = finger_poses
	_finger_pose_modifier.open_finger_poses = open_finger_poses
	skeleton_node.add_child(_finger_pose_modifier)

# Find the mesh_instance node child
func _get_mesh_instance_node(p_node : Node) -> MeshInstance3D:
	for child in p_node.get_children():
		if child is MeshInstance3D:
			return child

		var ret : MeshInstance3D = _get_mesh_instance_node(child)
		if ret:
			return ret

	return null


# Set the material on the given hand mesh
func _update_hand_material(p_node : Node, p_material : Material, p_cast_shadows : bool) -> void:
	var mesh_instance = _get_mesh_instance_node(p_node)
	if mesh_instance:
		mesh_instance.material_override = p_material
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if p_cast_shadows \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _update_hand_meshes():
	# Clean up old hand meshes
	_clear_digit_collisions()

	if _hand_modifier:
		_hand_modifier = null

	if _finger_pose_modifier:
		_finger_pose_modifier = null

	if _hand_skeleton:
		_hand_skeleton = null

	if _hand_mesh:
		remove_child(_hand_mesh)
		_hand_mesh.queue_free()
		_hand_mesh = null

	if _ghost_skeleton:
		_ghost_skeleton.skeleton_updated.disconnect(_on_skeleton_updated)
		_ghost_skeleton = null

	if _ghost_mesh:
		remove_child(_ghost_mesh)
		_ghost_mesh.queue_free()
		_ghost_mesh = null

	# Load new ones
	var hand_scene : PackedScene
	if alternative_hand_scene:
		hand_scene = alternative_hand_scene
	elif hand == 0:
		hand_scene = preload("res://addons/godot-xr-tools2/hands/gltf/LeftHandHumanoid.gltf")
	else:
		hand_scene = preload("res://addons/godot-xr-tools2/hands/gltf/RightHandHumanoid.gltf")

	if hand_scene:
		_hand_mesh = hand_scene.instantiate()
		if _hand_mesh:
			_hand_mesh.visible = show_hand_mesh
			add_child(_hand_mesh)
			_update_hand_material(_hand_mesh, material_override, false)

			_hand_skeleton = _get_skeleton_node(_hand_mesh)

		_ghost_mesh = hand_scene.instantiate()
		if _ghost_mesh:
			_ghost_mesh.visible = false
			_ghost_mesh.top_level = true
			add_child(_ghost_mesh)
			_add_hand_modifiers(_ghost_mesh)
			_update_hand_material(_ghost_mesh, \
				preload("res://addons/godot-xr-tools2/hands/gltf/ghost_material.tres"), false)

			# We apply our modifiers to our ghost skeleton,
			# and then copy them to our hand skeleton.
			# Eventually this will allow us to restrict the movement
			# on the hand based on collisions.
			_ghost_skeleton = _get_skeleton_node(_ghost_mesh)
			if _ghost_skeleton:
				_ghost_skeleton.skeleton_updated.connect(_on_skeleton_updated)
				_on_skeleton_updated()

	hand_mesh_changed.emit()
#endregion


#region Private Collision Functions
# Remove all our digit collisions
func _clear_digit_collisions() -> void:
	for digit : String in _digit_collision_shapes:
		var collision_node = _digit_collision_shapes[digit]
		remove_child(collision_node)
		collision_node.queue_free()
	_digit_collision_shapes.clear()
#endregion


#region Signal handling
# React to add/remove/change tracker signal
func _on_tracker_signal(_tracker_name: StringName, _type: int):
	_update_trackers()

# Update our skeleton including creating missing digit collisions.
# use_tracked_world_shapes: true for snap-turn depenetration queries only.
# false (default): colliders stay on the rigidbody so physics can hit surfaces.
func _on_skeleton_updated(use_tracked_world_shapes: bool = false) -> void:
	var bone_count = _ghost_skeleton.get_bone_count()
	for i in bone_count:
		var bone_transform : Transform3D = _ghost_skeleton.get_bone_global_pose(i)
		var collision_node : CollisionShape3D
		var offset : Transform3D
		offset.origin = Vector3(0.0, 0.015, 0.0) # move to side of object

		var bone_name = _ghost_skeleton.get_bone_name(i)
		if bone_name == ("LeftHand" if hand == 0 else "RightHand"):
			offset.origin = Vector3(0.0, 0.025, 0.0) # move to side of object
			collision_node = _palm_collision_shape
		elif bone_name.contains("Proximal") or bone_name.contains("Intermediate") or \
			bone_name.contains("Distal"):
			if _digit_collision_shapes.has(bone_name):
				collision_node = _digit_collision_shapes[bone_name]
			else:
				collision_node = CollisionShape3D.new()
				collision_node.name = bone_name + "Col"
				collision_node.shape = \
					preload("res://addons/godot-xr-tools2/hands/xrt2_hand_digit.shape")
				collision_node.debug_color = debug_color
				collision_node.disabled = false
				add_child(collision_node, false, Node.INTERNAL_MODE_BACK)
				_digit_collision_shapes[bone_name] = collision_node

		var bone_pose : Transform3D = _ghost_skeleton.get_bone_pose(i)
		_hand_skeleton.set_bone_pose(i, bone_pose)

		if collision_node:
			if use_tracked_world_shapes:
				collision_node.disabled = false
				collision_node.global_transform = bone_transform * offset
			elif collision_node == _palm_collision_shape and _hand_mesh and _hand_skeleton:
				# Palm only for live physics — digit hulls shift too much and cause jitter.
				collision_node.disabled = false
				collision_node.transform = \
					_hand_mesh.transform * _hand_skeleton.get_bone_global_pose(i) * offset
			else:
				collision_node.disabled = true

	skeleton_updated.emit()


# TODO: Hook this up, this is now part of our locomotion system.
func _on_player_moved(from_transform : Transform3D, to_transform : Transform3D, is_teleport : bool):
	if is_teleport:
		# TODO this needs to be implemented
		pass
	else:
		# Old logic, no longer applied
		# var current_local_transform : Transform3D = from_transform.inverse() * global_transform
		# var target_transform : Transform3D = to_transform * current_local_transform
		# var delta_movement : Vector3 = target_transform.origin - global_transform.origin
		pass


func _on_button_pressed(action_name: String):
	# Just chain this.
	if (emit_input):
		button_pressed.emit(action_name)


func _on_button_released(action_name: String):
	# Just chain this.
		button_released.emit(action_name)


func _on_input_float_changed(action_name: String, value: float):
	# Just chain this.
	if (emit_input):
		input_float_changed.emit(action_name, value)


func _on_input_vector2_changed(action_name: String, vector: Vector2):
	# Just chain this.
	if (emit_input):
		input_vector2_changed.emit(action_name, vector)
#endregion
