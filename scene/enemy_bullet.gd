extends Area2D
## 敌人子弹：只打"玩家 / 队友 / 守护对象"（它们都有 apply_damage），碰到墙或超时消失

const WORLD_COLLISION_MASK := 1
const ACTOR_COLLISION_MASK := 2 | 256     ## 2 = 玩家/队友；256 = 守护对象

@export var speed: float = 220.0
@export var max_lifetime: float = 3.0
@export var damage: int = 1

var direction: Vector2 = Vector2.RIGHT
var _life := 0.0


func _ready() -> void:
	_life = max_lifetime
	collision_mask = ACTOR_COLLISION_MASK
	body_entered.connect(_on_body_entered)


func setup(initial_direction: Vector2) -> void:
	if initial_direction != Vector2.ZERO:
		direction = initial_direction.normalized()
	rotation = direction.angle()


func _physics_process(delta: float) -> void:
	# 兜底：如果出膛时就已经在墙里（射线从形状内部出发打不到墙），直接销毁，
	# 否则子弹会"从墙里穿出去"
	if _is_inside_wall(global_position):
		queue_free()
		return
	var from_position := global_position
	var to_position := from_position + direction * speed * delta
	if _will_hit_world(from_position, to_position):
		queue_free()
		return
	global_position = to_position
	_life -= delta
	if _life <= 0.0:
		queue_free()


func _is_inside_wall(point: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	if space == null:
		return false
	var query := PhysicsPointQueryParameters2D.new()
	query.position = point
	query.collision_mask = WORLD_COLLISION_MASK
	query.collide_with_areas = false
	return not space.intersect_point(query, 1).is_empty()


func _will_hit_world(from_position: Vector2, to_position: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	if space == null:
		return false
	var query := PhysicsRayQueryParameters2D.create(from_position, to_position, WORLD_COLLISION_MASK)
	return not space.intersect_ray(query).is_empty()


func _on_body_entered(body: Node2D) -> void:
	if body == null or not body.has_method("apply_damage"):
		return
	body.apply_damage(damage)
	queue_free()
