extends Area2D
class_name Pickup

const BLINK_ENABLED_SHADER_PARAMETER := &"blink_enabled"
#当前凋落物使用的配置资源
@export var config: PickupConfig
#道具消失前的提醒
@export_range(0.0, 10.0, 0.1, "or_greater") var blink_before_expire: float = 1.2

@onready var sprite: Sprite2D = $Sprite2D
@onready var lifetime_timer: Timer = $LifeTimer

var is_expiring: bool = false

func _ready() -> void:
	add_to_group("pickup")          # 队友靠这个组找道具
	body_entered.connect(_on_body_entered)
	lifetime_timer.timeout.connect(_on_lifetime_timer_timeout)
	lifetime_timer.one_shot = true
	if lifetime_timer.wait_time > 0.8:
		lifetime_timer.start()
		_set_blink_enabled(false)
		_apply_config_to_visual()
		
	
# 道具临近消失时开始闪烁
func _process(_delta: float) -> void:
	if lifetime_timer.is_stopped():
		if is_expiring:
			is_expiring = false
			_set_blink_enabled(false)
		return
	
	# 检查是否应该开始闪烁
	if lifetime_timer.time_left <= blink_before_expire and not is_expiring:
		is_expiring = true
		_set_blink_enabled(true)
	
	# 检查是否应该停止闪烁 如果时间又变大了，虽然不太可能 
	if lifetime_timer.time_left > blink_before_expire and is_expiring:
		is_expiring = false
		_set_blink_enabled(false)
	
#将配置中的图标资源应用到显示节点上
func _apply_config_to_visual() -> void:
	if config == null:
		push_warning("Pickup config is missing.")
		return
	sprite.texture = config.icon_texture
	
func _on_body_entered(body: Node2D) -> void:
	if config == null:
		return
	# 玩家和队友都能吃：谁有 apply_pickup 就归谁（队友吃到的加成只作用于队友自己）
	if body == null or not body.has_method("apply_pickup"):
		return
	if body.call("apply_pickup", config):
		SfxPlayer.pickup()
		queue_free()
	
#道具寿命结束后自刎归天
func _on_lifetime_timer_timeout() -> void:
	queue_free()
	
#统一道具是否闪烁
func _set_blink_enabled(enabled: bool) -> void:
	var sprite_material := sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARAMETER,enabled)
