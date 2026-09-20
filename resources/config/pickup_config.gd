extends Resource
class_name PickupConfig

enum PickupType{
	SPEED,
	RAPID,
	SPIRAL,
}

enum PlayerFormMode{
	NORMAL,
	ARMED,
}

enum ShotPattern{
	NORMAL,
	SPIRAL,
}

@export_group("基础信息")
#标记类型
@export var pickup_type: PickupType = PickupType.SPEED
#显示名称
@export var display_name: String = "移速道具"
#掉落权重，设为0表示不参与掉落
@export_range(0.0, 1000.0, 0.1, "or_greater") var drop_weight: float = 1.0

@export_group("显示资源")
#道具在场景中显示的静态图标资源
@export var icon_texture: Texture2D


@export_group("Buff 效果")
#效果持续时间，秒
@export_range(0.0, 120.0, 0.1, "or_greater") var duration: float = 5.0
#玩家移速倍率，1.0表示不变，每0.1表示提升10%
@export_range(0.1, 5.0, 0.05, "or_greater") var move_speed_multiplier: float = 1.0
#玩家射速倍率，1.0表示不变，每0.1表示提升10%
@export_range(0.1, 5.0, 0.05, "or_greater") var fire_rate_multiplier: float = 1.0

@export_group("形态与弹幕")
#拾取到切换形态
@export var player_form_mode: PlayerFormMode = PlayerFormMode.NORMAL
#玩家拾取后的弹幕模式
@export var shot_pattern: ShotPattern = ShotPattern.NORMAL
