extends Resource
class_name EnemyConfig

enum EnemyType{
	BASIC,
	SHELLED,
	FAST_SMAKK,
	BOOOOMBER,
}

@export_group("基础数值")
#用于标记敌人的大类
@export var enemy_type: EnemyType = EnemyType.BASIC
#显示名称
@export var display_name: String = "基础敌人"


@export_group("基础数值")
#最大生命值
@export_range(1, 999, 1, "or_greater") var max_health: int = 3
#移动速度
@export_range(0.0, 1000.0, 1.0, "or_greater") var move_speed: float = 60.0
#圆型碰撞区域半径
@export_range(1.0, 256.0, 0.5, "or_greater") var collision_radius: float = 8



@export_group("刷怪")
#不为空时，刷怪用这个场景代替默认 enemy_scene（特殊外观/AI 的敌人用）
@export var scene_override: PackedScene


@export_group("动画资源")
#敌人本体使用的 SpriteFranmes 资源
@export var enemy_frames: SpriteFrames
#敌人正常移动时默认播放的动画名
@export var move_animation_name: StringName = &"move"
#敌人死亡时默认播放的动画名
@export var death_animation_name: StringName = &"death"
#爆炸特效默认播放的动画名
@export var explosion_animation_name: StringName = &"explode"

@export_group("死亡效果")
#是否在死亡时触发自爆
@export var explode_on_death: bool = false
#自爆伤害,explode_on_death为true有效
@export_range(0, 999, 1, "or_greater") var explosion_damage: int = 0
#自爆半径,explode_on_death为true有效
@export_range(0.0, 512.0, 1.0, "or_greater") var explosion_radius: float = 0



@export_group("敌人掉落")
#敌人死亡后道具掉落的概率
@export_range(0.0, 1.0, 0.01) var pickup_drop_chance: float = 0.3
#当前敌人允许掉落的道具配置列表，为空时表示该敌人不会掉落道具
@export var pickup_drop_configs: Array[PickupConfig] = [
	preload("res://resources/config/pickup_speed.tres"),
	preload("res://resources/config/pickup_rapid.tres"),
	preload("res://resources/config/pickup_spiral.tres"),
]
