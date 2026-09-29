extends Node
## 全局场景流程 Autoload 名:GameFlow 
## 所有场景切换都从这里走，避免各脚本各写 change_scene_to_file 而漏掉"复位时间缩放/暂停"

const TITLE_SCENE := "res://scene/title.tscn"
const MAP_SCENE := "res://scene/map/map_screen.tscn"          # M4 起只作调试入口保留
const MIDMAP_SCENE := "res://scene/midmap/midmap.tscn"
## M1/M2 建好新战斗场景后这里会自动切过去；在此之前回落到现在的经典战斗场景
const BATTLE_SCENE := "res://scene/battle/battle.tscn"
const LEGACY_BATTLE_SCENE := "res://scene/game.tscn"

## 下一场战斗的上下文 关卡目标，地图，可用敌人等 ，由 Battle 读取
var pending_battle: Dictionary = {}


## 切场景前统一复位:上一场结算可能把 Engine.time_scale 设为 0 并暂停场景树
func _prepare_switch() -> void:
	Engine.time_scale = 1.0
	get_tree().paused = false


func goto_title() -> void:
	_prepare_switch()
	get_tree().change_scene_to_file(TITLE_SCENE)


func goto_map() -> void:
	_prepare_switch()
	get_tree().change_scene_to_file(MAP_SCENE)


## M4-5: 关卡之间的中间地图（可走动 + 对话 + 商店）；每关胜利后回到这里
func goto_midmap() -> void:
	_prepare_switch()
	get_tree().change_scene_to_file(MIDMAP_SCENE)


## 标题界面开始新局入口
func start_new_run() -> void:
	RunState.reset()
	goto_midmap()


## 标题界面经典模式入口:保留原来的单关玩法
func goto_legacy_battle() -> void:
	_prepare_switch()
	get_tree().change_scene_to_file(LEGACY_BATTLE_SCENE)


## 进入一场战斗context 例:{ "floor": 2, "node_type": "battle" }
func start_battle(context: Dictionary = {}) -> void:
	pending_battle = context
	_prepare_switch()
	var path := BATTLE_SCENE if ResourceLoader.exists(BATTLE_SCENE) else LEGACY_BATTLE_SCENE
	get_tree().change_scene_to_file(path)
