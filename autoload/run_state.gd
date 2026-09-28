extends Node
## 整局 Run 状态:跨场景常驻的单例 Autoload 名:RunState 
## 这里的一"局"指一次完整闯关:标题 到 路线图 到 多场战斗 到 通关/失败
## 单场战斗里的临时数据 本场击杀，本场倒计时 不放这里，放 Battle 自己身上

signal run_started
signal run_finished(cleared: bool)
signal gold_changed(gold: int)
signal health_changed(current: int, maximum: int)
signal floor_changed(floor_index: int)

## 总层数 含最终 Boss 层 
const MAX_FLOOR := 10
## 固定 BOSS 层（第 5 层是中途 BOSS，第 10 层是最终 BOSS）
const BOSS_FLOORS: Array[int] = [5, 10]

## 玩家基础数值:升级只加在"基础值"上，限时道具仍是独立倍率 三层数值，互不污染 
const BASE_MAX_HEALTH := 3
const BASE_MOVE_SPEED := 120.0
const BASE_FIRE_INTERVAL := 0.18

var is_active: bool = false          ## 是否处于一局进行中
var cleared: bool = false            ## 本局是否已通关
var floor_index: int = 1             ## 当前层 从 1 开始 
var gold: int = 0                    ## 金币 唯一来源:敌人掉落 
var total_kills: int = 0             ## 本局累计击杀
var run_elapsed: float = 0.0         ## 本局累计用时 秒 

# ---- 长效升级 M5 商店写入，Battle 开场读取 ----
# ---- 局内成长（Hub 商店写入，Battle 开场读取；新开一局重置）----
## 生命值：跨关卡保留（上一关剩多少，下一关就带多少）
var max_health: int = BASE_MAX_HEALTH
var current_health: int = BASE_MAX_HEALTH
## 子弹伤害（基础 1，商店每级 +1）
var player_damage: int = 1
## 射速等级（每级 +10%）
var fire_rate_level: int = 0
## 移速等级（预留）
var speed_level: int = 0
# ---- 旧字段（保留兼容）----
var bonus_max_health: int = 0
var move_speed_multiplier: float = 1.0
var fire_rate_multiplier: float = 1.0
var bonus_invincibility: float = 0.0

## 本层路线图 M3 由 RunMap 填充 ，M0 阶段留空
var route: Array = []

## 上一关的成绩汇报（关卡结束后由 Battle 写入，Hub 到达时展示一次后清空）
## 字段: floor / node_type / goal_text / won / kills / elapsed / gold_gained / gold_total / health / max_health
var last_level_report: Dictionary = {}

## 本局是否已经写过战绩（避免重复结算写多条）
var _record_written := false


## 开始新的一局:把全部进度清零
func reset() -> void:
	is_active = true
	cleared = false
	floor_index = 1
	gold = 0
	total_kills = 0
	run_elapsed = 0.0
	max_health = BASE_MAX_HEALTH
	current_health = BASE_MAX_HEALTH
	player_damage = 1
	fire_rate_level = 0
	speed_level = 0
	bonus_max_health = 0
	move_speed_multiplier = 1.0
	fire_rate_multiplier = 1.0
	bonus_invincibility = 0.0
	route.clear()
	shop_buy_count.clear()
	last_level_report.clear()
	_record_written = false
	run_started.emit()
	floor_changed.emit(floor_index)
	gold_changed.emit(gold)


# ---- 金币 ----
func add_gold(amount: int) -> void:
	if amount <= 0:
		return
	gold += amount
	gold_changed.emit(gold)


func try_spend_gold(amount: int) -> bool:
	if amount <= 0 or gold < amount:
		return false
	gold -= amount
	gold_changed.emit(gold)
	return true


# ---- 层数推进 ----
## 前进一层；已在最终层时保持在最终层（避免打赢最终层的精英关后层数溢出）
func advance_floor() -> void:
	floor_index = mini(floor_index + 1, MAX_FLOOR)
	floor_changed.emit(floor_index)


func is_final_floor() -> bool:
	return floor_index >= MAX_FLOOR


## 节点类型的显示名（Hub 角色名 / 关卡汇报共用）
func kind_title(kind: String) -> String:
	match kind:
		"battle":
			return "普通关"
		"elite":
			return "精英关"
		"shop":
			return "商店"
		"boss":
			return "BOSS"
	return kind


## 是否 BOSS 层（不传参数 = 当前层）
func is_boss_floor(index: int = -1) -> bool:
	return BOSS_FLOORS.has(floor_index if index < 0 else index)


## 中间地图三个位置刷什么角色：
## - BOSS 层：固定 商店 - BOSS - 商店（打 BOSS 前左右各一个商店，方便补给）
## - 其它层：三个位置随机（精英关/普通关/商店），但没有普通关时保底塞一个普通关
## 同一层结果固定（用层数做随机种子），方便重进时一致、也方便复现
func hub_kinds(index: int = -1) -> Array[String]:
	var target_floor: int = floor_index if index < 0 else index
	var kinds: Array[String] = []
	if BOSS_FLOORS.has(target_floor):
		kinds = ["shop", "boss", "shop"]
		return kinds
	var rng := RandomNumberGenerator.new()
	rng.seed = target_floor * 104729
	var pool: Array[String] = ["elite", "battle", "shop"]
	for _slot in range(3):
		kinds.append(pool[rng.randi_range(0, pool.size() - 1)])
	if not kinds.has("battle"):
		kinds[rng.randi_range(0, kinds.size() - 1)] = "battle"    # 保底：至少一个普通关
	return kinds


# ---- 供 Player 取用的最终数值 基础值 × 升级 ----
func get_player_max_health() -> int:
	return maxi(max_health, 1)


## 子弹伤害（商店升级驱动）
func get_player_damage() -> int:
	return maxi(player_damage, 1)


## 战斗结束时把这一场的血量写回整局状态（跨关卡保留的关键）
func set_health(current: int, maximum: int) -> void:
	max_health = maxi(maximum, 1)
	current_health = clampi(current, 1, max_health)
	health_changed.emit(current_health, max_health)


## 商店: +1 生命（上限与当前生命一起 +1）
func buy_max_health() -> void:
	max_health += 1
	current_health += 1
	health_changed.emit(current_health, max_health)


## 商店: 射速 +10%
func buy_fire_rate() -> void:
	fire_rate_level += 1


## 商店: 子弹伤害 +1
func buy_damage() -> void:
	player_damage += 1


func get_player_move_speed() -> float:
	return BASE_MOVE_SPEED * move_speed_multiplier


func get_player_fire_interval() -> float:
	return BASE_FIRE_INTERVAL / (maxf(fire_rate_multiplier, 0.01) * (1.0 + 0.1 * float(fire_rate_level)))


# ---- 商店（Hub，本局内有效；新开一局重置）----
const SHOP_KEYS: Array[String] = ["health", "fire_rate", "damage"]
const SHOP_PRICE_HEALTH := 15        ## 生命上限 +1 的初始价
const SHOP_PRICE_FIRE_RATE := 25     ## 射速 +10% 的初始价
const SHOP_PRICE_DAMAGE := 40        ## 子弹伤害 +1 的初始价
const SHOP_PRICE_HEAL := 30          ## 恢复血量：**固定价**，不随购买次数上涨

## 商店货架（按用户要求的分类与顺序）：道具 / 加成
const SHOP_SHELVES: Array = [
	{"title": "道具", "keys": ["health", "heal"]},
	{"title": "加成", "keys": ["fire_rate", "damage"]},
]
const SHOP_PRICE_GROWTH := 0.5       ## 每买一次涨价 = 初始价的 50%

## 本局各商品已买次数 key -> int 
var shop_buy_count: Dictionary = {}


## 当前价格 = 初始价 + 初始价的一半 * 已买次数
func shop_price(key: String) -> int:
	if key == "heal":
		return SHOP_PRICE_HEAL          # 固定 30 金
	var base := 0
	match key:
		"health":
			base = SHOP_PRICE_HEALTH
		"fire_rate":
			base = SHOP_PRICE_FIRE_RATE
		"damage":
			base = SHOP_PRICE_DAMAGE
		_:
			return 0
	var bought: int = int(shop_buy_count.get(key, 0))
	return base + int(float(base) * SHOP_PRICE_GROWTH) * bought


## 买一件：钱不够返回 false（不扣钱也不加属性）
func shop_buy(key: String) -> bool:
	if key == "heal":
		# 恢复血量：血满不让买（省得白花钱），买了直接回满
		if current_health >= max_health:
			return false
		if not try_spend_gold(SHOP_PRICE_HEAL):
			return false
		current_health = max_health
		health_changed.emit(current_health, max_health)
		return true
	if not SHOP_KEYS.has(key):
		return false
	if not try_spend_gold(shop_price(key)):
		return false
	match key:
		"health":
			buy_max_health()
		"fire_rate":
			buy_fire_rate()
		"damage":
			buy_damage()
	shop_buy_count[key] = int(shop_buy_count.get(key, 0)) + 1
	return true


## 该商品已升了几级（商店显示用）
func shop_level(key: String) -> int:
	match key:
		"health":
			return maxi(max_health - BASE_MAX_HEALTH, 0)
		"fire_rate":
			return fire_rate_level
		"damage":
			return maxi(player_damage - 1, 0)
	return 0


func finish_run(did_clear: bool) -> void:
	cleared = did_clear
	is_active = false
	# 一局只写一条战绩（M4 闯关模式原来完全没写，开始界面右侧的"最近战绩"一直是空的）
	if not _record_written:
		_record_written = true
		RoundRecords.add_record(run_elapsed, total_kills, did_clear, floor_index, gold)
	run_finished.emit(did_clear)
