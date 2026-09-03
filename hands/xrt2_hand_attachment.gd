#-------------------------------------------------------------------------------
# xrt2_hand_attachment.gd
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
class_name XRT2HandAttachment
extends Node3D

## XRTools2 Hand Attachment Script
##
## This script exposes bone locations for collision hands.
## This has to be a child of a [XRT2CollisionHand] node.

@export var bone_name : String:
	set(value):
		bone_name = value
		if is_inside_tree():
			_on_skeleton_updated()

var _updating : bool = false
## Scene-file local pose, captured before skeleton overwrites this node.
var _authored_local : Transform3D = Transform3D()
var _has_authored_local : bool = false
var _pickup: XRT2Pickup

# Verifies if we have a valid configuration.
func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()

	var parent = get_parent()
	if not parent or not parent is XRT2CollisionHand:
		warnings.push_back("This node must be a child of an XRT2CollisionHand node.")

	# Return warnings
	return warnings


# Update our properties
func _validate_property(property):
	if (property.name == "bone_name"):
		var parent = get_parent()
		if parent and parent is XRT2CollisionHand:
			property.hint = PROPERTY_HINT_ENUM
			property.hint_string = parent.get_concatenated_bone_names()
		else:
			property.hint = PROPERTY_HINT_NONE
			property.hint_string = ""


func _enter_tree():
	if not _has_authored_local:
		_authored_local = transform
		_has_authored_local = true

	var parent = get_parent()
	if parent and parent is XRT2CollisionHand:
		parent.hand_mesh_changed.connect(_on_hand_mesh_changed)
		parent.skeleton_updated.connect(_on_skeleton_updated)

	_cache_pickup()
	_on_skeleton_updated()


func _ready():
	_cache_pickup()


## Palm-relative pose from the scene, not the live tracked metacarpal.
func get_authored_local_transform() -> Transform3D:
	return _authored_local if _has_authored_local else transform


func get_authored_global_transform() -> Transform3D:
	var parent = get_parent()
	if parent is Node3D and _has_authored_local:
		var xf: Transform3D = (parent as Node3D).global_transform * _authored_local
		xf.basis = xf.basis.orthonormalized()
		return xf
	var live := global_transform
	live.basis = live.basis.orthonormalized()
	return live


func _exit_tree():
	var parent = get_parent()
	if parent and parent is XRT2CollisionHand:
		parent.hand_mesh_changed.disconnect(_on_hand_mesh_changed)
		parent.skeleton_updated.disconnect(_on_skeleton_updated)


func _on_hand_mesh_changed():
	notify_property_list_changed()
	_on_skeleton_updated()


func _cache_pickup() -> void:
	_pickup = null
	for child in get_children():
		if child is XRT2Pickup:
			_pickup = child
			return


func _should_pin_authored_local() -> bool:
	return _pickup != null \
			and _pickup.has_method("is_useable_primary_hold") \
			and _pickup.is_useable_primary_hold()


func _on_skeleton_updated():
	if _updating:
		return
	_updating = true

	var parent = get_parent()
	if _should_pin_authored_local() and _has_authored_local:
		# Keep the pickup/joint in palm space while holding. Following the live
		# metacarpal moved the joint origin every skeleton tick.
		transform = _authored_local
	elif not bone_name.is_empty() and parent and parent is XRT2CollisionHand:
		transform = parent.get_bone_transform(bone_name)
	else:
		transform = Transform3D()

	_updating = false
