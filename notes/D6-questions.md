# D6 用户关键问题（合约架构设计模式总结，不写新代码）

## 开工时的决定
- 横向对比项目（用户全选）：Pledge 借贷（pledgev2）、Uniswap V2（v2-core + v2-periphery）、MetaNodeSwap V3 风格（swap-contract）、MetaNodeStake 质押（Advanced2-contract-stake）；Compound / Aave 按公开设计讲（本地无源码）。
- 笔记位置：`个人笔记/Solidity学习/MetaNodePerpetual/手写实战/D6-合约架构设计模式与横向对比.md`。
- 分块：1 本项目设计模式 + 继承图/调用链 / 2 横向对比 / 3 写笔记推送。

## 用户提问
### 第 1 块思考题（用户回答 + 纠正）
- Q1「Funding.deposit 改 internal 会怎样」—— 用户答：会超 24KB。**半对**：`forge build --sizes` 实测 Dealer 14,868B，Funding 3,777 / Liquidation 4,861 / Operation 3,092。只把 deposit 一个函数改 internal，只多内联一小段，远不到 24KB；三个库全内联约 26.6KB 才会超（24,576B 上限）。链上行为基本不变（DELEGATECALL 本来就保留 msg.sender、存储、事件地址），区别是：少一次 DELEGATECALL 的 gas、Dealer 变大、Deposit 事件会进 Dealer ABI、少部署一个库。结论：external 库是**为了合约大小**，不是为了权限或逻辑隔离。
- Q2「realizePnl 为什么不能像 handleBadDebt 那样按状态条件放开」—— 用户答：不注册就能随便改 primaryCredit。**方向对，缺根因**：handleBadDebt 的决策数据（openPositions、净值）**全在 Dealer 自己的 state 里**，Dealer 能自己验证；realizePnl 的 `pnl` 是**调用方传进来的数字**，真相在 Perpetual 的账本里，Dealer 没法验证，只能信任调用者身份。规则：决策数据在自己手里 → 可按状态放开；数据来自调用方 → 必须校验调用方身份。
- Q3「Perpetual owner 被转走最坏会怎样」—— 用户答：新 owner 能做所有 onlyOwner 的事，比如 updateFundingRate（答案未写完）。**补全**：①Perpetual 的所有回调都写 `IDealer(owner())`，owner 换成攻击者合约后，trade 会去问攻击者的假 approveTrade → 不验签直接给自己记任意 paper/credit；②但 Dealer 仍把这个 Perpetual 当已注册市场，`getTotalExposure` 照读 `balanceOf` → 攻击者净值虚高 → `fastWithdraw` 通过 `_isSolidIMSafe` → **把 Dealer 里所有人的 USDC 提走**；③改资金费率也能让其他人净值暴跌被清算。结论：Perpetual 没钱，但**它的账本数字被 Dealer 当钱用**，信任是传递的。项目里除 Perpetual 构造函数外没有任何调用 transferOwnership 的路径（grep 确认），这是对的。

### 第 2 块调整（用户反馈）
- 用户觉得第 2 块初版（一张大表概览 6 个项目）**太简单**。改为：用分析本项目的同一套框架（继承图 + 5 个模式 + 调用链 + 6 维度）逐个深挖，先只做 **Pledge → MetaNodeSwap → MetaNodeStake**，Compound V2 / Aave V3 先不展开。初版思考题作废。
- Pledge 已深挖完（继承图、5 个模式逐条对照、调用链、六维度、读代码发现 4 个问题：liquidate 不检查清算条件、清算卖币 amountOutMin=0、setPrices 写错键、validCall 批准不绑定操作也不消费）。思考题 3 道未答，记在笔记 6.6。
- **（用户调整）横向对比先跳过**：MetaNodeSwap、MetaNodeStake、Compound V2 / Aave V3 等 Go 后端做完再回来做。

## 留给后续
- 横向对比剩余：MetaNodeSwap → MetaNodeStake →（Compound V2 / Aave V3），用同一套框架；Pledge 的 3 道思考题。排期需回「总体计划」会话调整。
- Obsidian 笔记：`个人笔记/Solidity学习/MetaNodePerpetual/手写实战/D6-合约架构设计模式与横向对比.md`（dc8ae9a 已推送），续写时在第 6 节后追加。
