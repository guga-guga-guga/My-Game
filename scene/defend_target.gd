extends CharacterBody2D
## 守护对象（守护关）：站在地图中心，不会移动/射击，只会被打；5 血，血空即关卡失败。
## 外观：W.png 第 5 排（32x32，4 帧）。
## 敌人碰到它 -> 敌人"静默消失"（不算击杀、不掉落），守护对象 -1 血。

signal health_changed(current: int, maximum: int)
signal died

const MAX_HEALTH := 5
const GUARD_ATLAS := "res://resources/texture/W.png"
const SPRITE_ROW_Y := 128
const FRAME_SIZE := 32
const FRAME_COUNT := 4
const BODY_SCALE := 1.6

var current_health := MAX_HEALTH
var is_dead := false

@onready var _sprite: AnimatedSprite2D = $Sprite2D
@onready var _guard_area: Area2D = $GuardArea


func _ready() -> void:
	add_to_group("guard_target")
	_build_frames()
	_guard_area.body_entered.connect(_on_body_entered)
	health_changed.emit(current_health, MAX_HEALTH)


func _build_frames() -> void:
	var atlas := load(GUARD_ATLAS) as Texture2D
	var frames := SpriteFrames.new()
	frames.clear("default")
	if atlas != null:
		for index in range(FRAME_COUNT):
			var frame := AtlasTexture.new()
			frame.atlas = atlas
			frame.region = Rect2(index * FRAME_SIZE, SPRITE_ROW_Y, FRAME_SIZE, FRAME_SIZE)
			frames.add_frame("default", frame)
	frames.set_animation_speed("default", 4.0)
	frames.set_animation_loop("default", true)
	_sprite.sprite_frames = frames
	_sprite.scale = Vector2(BODY_SCALE, BODY_SCALE)
	_sprite.play("default")


## 子弹 / 接触伤害都走这里
func apply_damage(amount: int) -> bool:
	if is_dead or amount <= 0:
		return false
	current_health = maxi(current_health - amount, 0)
	health_changed.emit(current_health, MAX_HEALTH)
	if current_health <= 0:
		_die()
	return true


func _die() -> void:
	if is_dead:
		return
	is_dead = true
	_sprite.modulate = Color(0.5, 0.5, 0.5, 0.6)
	died.emit()


## 敌人碰到守护对象：敌人静默消失 + 守护对象 -1
func _on_body_entered(body: Node2D) -> void:
	if is_dead or body == null or not body.has_method("apply_damage"):
		return
	if body.get("is_dead") == true:
		return
	_silent_remove(body)
	apply_damage(1)


## 让敌人静默消失：不调用 _die() -> 不 emit died -> 不算击杀、不掉金币/道具
func _silent_remove(enemy: Node) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	enemy.set("is_dead", true)
	enemy.set_deferred("collision_layer", 0)
	enemy.set_deferred("collision_mask", 0)
	var area := enemy.get_node_or_null("TouchDamageArea")
	if area != null:
		area.set_deferred("monitoring", false)
		area.set_deferred("monitorable", false)
	enemy.queue_free()
