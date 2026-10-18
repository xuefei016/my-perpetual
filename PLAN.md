# my-perpetual 手写计划（每天 4-5 小时，共 9 天）

参考答案：`../perpetual-contract`（只读对照，不修改）

项目拆分：
- Solidity 合约：`/Users/fei/Documents/Solidity/my-perpetual`（本仓库，L1-L7）
- Go 后端：`/Users/fei/Documents/Solidity/my-perpetual-backend`（独立仓库，L8-L12，D5 创建）
  - abigen 从 `../my-perpetual/out/*.json` 导出 ABI 生成绑定，生成的绑定代码提交进后端仓库

| 天 | 课程 | 内容 | 完成 |
|---|---|---|---|
| D1 | L1 + L2 | 定点数学 + Perpetual 账本（reducedCredit/资金费）；Types/Storage + 存取款时间锁 | [x] |
| D2 | L3 + L4 | Dealer ↔ Perpetual 联动、标记价格；保证金风控 IM/MM safe | [x] |
| D3 | L5 | EIP-712 订单签名 + 撮合结算 `_matchOrders` | [x] |
| D4 | L6 | 清算 + 坏账 + 保险账户 | [x] |
| D5 | L7 + L8 | 管理函数 + anvil 部署；Go 骨架 + abigen + 连接 anvil | [ ] |
| D6 | 总结 | 合约架构设计模式总结 + 与之前借贷/DEX 项目横向对比（不写新代码） | [ ] |
| D7 | L9 + L10 前半 | Go 端 EIP-712 与合约哈希对齐；订单簿数据结构 | [ ] |
| D8 | L10 后半 + L11 | 撮合引擎（部分成交、价格-时间优先）；tradeData 编码 + 提交 trade | [ ] |
| D9 | L12 | HTTP API + 资金费 keeper + 清算机器人，端到端跑通 | [ ] |

节点：D4 结束写合约篇笔记，D6 写架构总结笔记，D9 结束写后端篇笔记（Obsidian `Solidity学习/MetaNodePerpetual/`）。
每天收尾：`forge test` 全绿 + git commit。

---

## 每日详细安排（每天约 4.5h：读参考 0.5h → 手写 2.5h → 测试 1h → 复盘提交 0.5h）

> 规则：先读参考对应文件的**函数签名和注释**，合上参考自己写；卡住超过 20 分钟再看参考实现。

### D1 — L1 定点数学 + Perpetual 账本；L2 Types/Storage + 存取款
| 时段 | 内容 | 产出文件 |
|---|---|---|
| 1h | `SignedDecimalMath`：1e18 定点 `decimalMul/decimalDiv/abs`，取整方向（向下/向上） | `src/libraries/SignedDecimalMath.sol` |
| 1.5h | `Perpetual`：`paper`（持仓）+ `reducedCredit`（已扣资金费的信用），`balanceOf` 公式 `credit = paper*fundingRate/1e18 + reducedCredit`；`updateFundingRate` / `trade` / `_settle` | `src/Perpetual.sol`、`src/interfaces/IPerpetual.sol` |
| 1h | `Types`（State/Order/RiskParams 结构体）、`Errors`、`MetaNodeStorage` | `src/libraries/Types.sol` 等 |
| 1h | `Funding`：`deposit` / `requestWithdraw` / `executeWithdraw`（时间锁）/ `fastWithdraw` | `src/libraries/Funding.sol` |
| 验收 | 测试：资金费率变化后 `balanceOf` 正确；时间锁未到期提现 revert | `test/` |

### D2 — L3 Dealer ↔ Perpetual 联动；L4 保证金风控
| 时段 | 内容 | 产出文件 |
|---|---|---|
| 1h | `MetaNodeDealer` 骨架 + `MetaNodeExternal` 入口；Perpetual 只信任 Dealer（`onlyOwner`） | `src/MetaNode*.sol` |
| 1h | `Position`：`_openPosition`（登记开仓的 perp 列表）、`_realizePnl`（平仓后把 credit 结回主账户） | `src/libraries/Position.sol` |
| 0.5h | 标记价格：`getMarkPrice` 读预言机（先用 `ConstOracle` / Mock） | `src/oracle/ConstOracle.sol` |
| 1.5h | `Liquidation` 前半：`getTotalExposure`、`_isIMSafe` / `_isMMSafe` / `_isAllMMSafe`，次级资产（secondaryCredit）怎么计入净值 | `src/libraries/Liquidation.sol` |
| 验收 | 场景测试：存款 → 开仓 → 价格下跌 → `isSafe` 从 true 变 false | |

### D3 — L5 EIP-712 订单签名 + 撮合结算（最难的一天）
| 时段 | 内容 | 产出文件 |
|---|---|---|
| 1h | `EIP712`：domain separator、`_hashTypedDataV4`；`Order` 的 typehash | `src/libraries/EIP712.sol` |
| 2h | `Trading._matchOrders`：验签（EOA + ERC1271）、`orderSender` 权限、价格匹配 `_priceMatchCheck`、`orderFilledPaperAmount` 防超额成交、手续费 `_info2MakerFeeRate`（info 字段打包解码） | `src/libraries/Trading.sol` |
| 0.5h | `Perpetual.trade` 调 `approveTrade`，结算后检查所有参与者 IM safe | |
| 1h | 测试：用 `vm.sign` 签订单；部分成交、超额成交 revert、错误签名 revert | `test/utils/EIP712Test.sol`、`test/Trading.t.sol` |

### D4 — L6 清算 + 坏账 + 保险账户
| 时段 | 内容 | 产出文件 |
|---|---|---|
| 1h | `getLiquidationPrice`、`getLiquidateCreditAmount`（清算折扣价 = 标记价 × (1 ± liquidationPriceOff)，保险费） | `Liquidation.sol` |
| 1.5h | `requestLiquidation` + `Perpetual.liquidate`：清算人接手仓位，被清算人付保险费；清算后清算人必须 IM safe | |
| 1h | `handleBadDebt`：仓位清零但净值 < 0 → 亏空由 insurance 账户承担 | |
| 1h | 场景测试（清算、坏账）+ **写合约篇笔记**（先确认 Obsidian 分类） | |

### D5 — L7 管理函数 + 部署；L8 Go 骨架
| 时段 | 内容 |
|---|---|
| 1h | `Operation` + `MetaNodeOperation`：`setPerpRiskParams`、`setInsurance`、`setOrderSender`、`setWithdrawTimeLock` 等（`onlyOwner`）；`MetaNodeView` 只写后端要用的几个 view |
| 1h | `script/Deploy.s.sol`：部署 USDC mock → Dealer → Perpetual(BTC) → 设风控参数；`anvil` 上跑通，`cast call` 验证 |
| 0.5h | 新建 `my-perpetual-backend`：`go mod init`，目录 `cmd/ internal/{chain,engine,api,keeper}` |
| 1h | abigen 生成 Dealer/Perpetual 绑定，Go 连 anvil 读 `getRiskParams`、`getPositions` |
| 0.5h | Go 发一笔 deposit 交易并等待回执 |

### D6 — 合约架构设计模式总结（2026-10-18 插入，合约全部写完后单独一天）
> 来源：D4 会话中用户提出，详见 `notes/D4-questions.md`「留给后续」。开工前先和用户确认对比哪几个项目。

| 时段 | 内容 |
|---|---|
| 1.5h | **本项目的设计模式**：继承拆分（Storage → External/Operation/View → Dealer）、library 操作 storage、中心-辐射（Dealer + 多个 Perpetual）、回调与信任边界、权限按文件隔离；画继承图 + 关键调用链（存款、撮合、清算） |
| 2h | **横向对比**：维度是代码组织、存储布局、可升级、多合约协作、钱放在哪、清算与坏账；各自为什么这么选。候选：借贷 `ProjectBreakdown-Pledge/pledgev2`；DEX `Base2_Solidity_Dex/swap-contract`（V3 风格）、`v2-core`/`v2-periphery`；可选 `Advanced2-contract-stake`。Compound/Aave 本地无源码，按公开设计讲 |
| 1h | 写成 Obsidian 笔记（先确认分类），推送 GitHub |

### D7 — L9 Go 端 EIP-712；L10 前半 订单簿
| 时段 | 内容 | 参考 |
|---|---|---|
| 2h | Go 实现 Order 的 typehash / structHash / domain，与合约 `getOrderHash` 逐字节对齐；用私钥签名，合约侧验签通过 | `others/backend/internal/chain/eip712.go` |
| 2.5h | 订单簿：买卖两侧按价格排序 + 同价 FIFO（价格-时间优先），增删改查 + 单测 | `internal/engine/orderbook.go` |

### D8 — L10 后半 撮合引擎；L11 提交 trade 上链
| 时段 | 内容 | 参考 |
|---|---|---|
| 2h | 撮合：taker 吃多档 maker、部分成交、剩余挂单、撤单；表格驱动单测覆盖场景 | `internal/engine/matchengine.go`（只取核心，1118 行不要照抄） |
| 1.5h | `tradeData` ABI 编码（orderList / signatureList / matchPaperAmount / price），与合约 `abi.decode` 对齐 | `internal/chain/tradedata.go` |
| 1h | orderSender 账户调 `Perpetual.trade` 上链，链上持仓与引擎结果对账 | |

### D9 — L12 HTTP API + keeper + 清算机器人，端到端
| 时段 | 内容 |
|---|---|
| 1.5h | `net/http`：`POST /order`（验签→进撮合）、`DELETE /order`、`GET /orderbook`、`GET /position` |
| 1h | 资金费 keeper：定时算 funding rate 并调 `updateFundingRate` |
| 1h | 清算机器人：轮询持仓，`isSafe=false` 就发起清算 |
| 1h | 端到端：两个账户签名下单 → 撮合 → 上链 → 价格变动 → 资金费/清算；**写后端篇笔记** |

### 不在计划内（可选加餐）
- `PythOracleAdaptor` / `OracleAdaptor`（真实预言机）、`Subaccount` 子账户、Postgres 持久化、K 线、钱包登录。
