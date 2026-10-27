# D8 用户关键问题（撮合引擎 + tradeData 编码 + 提交上链）

## 思考题：为什么"上链成功后才 Fill"
- 用户答：上链成功才算真正成交；先 Fill 的话失败了要回滚，很麻烦。
- 补充：
  - **链上是唯一真相**：合约的 `orderFilledPaperAmount[hash]` 是防超额的账本，引擎的 `Remaining` 必须和它一致（Remaining = |paper| − 链上已成交）。
  - 会 revert 的常见情况：成交后有人保证金不够（trade 末尾 `isAllSafe`，**查的是 MM 维持保证金，不是 IM**——第 6 步链上实测发现，见下）、订单过期、签名不对、maker 没按 signer 升序排（ORDER_WRONG_SORTING）、自成交。
  - 先 Fill 再失败的后果不只是"麻烦"：maker 被吃完会**移出订单簿**，回滚要把它按原 Seq 塞回原位；回滚前的这段时间里别的请求看到的是错的簿；忘了回滚，Remaining 就比链上少，这张单有一部分永远成交不了。
  - 不是"maker 把钱划给 taker"：成交是双方 paper（仓位）和 credit（USDC 记账）反向变化，钱都留在 Dealer 里。

## 用户踩过的坑 / review（真实发生）
- 第 1 步 EncodeTradeData：**一次写对编码**，自己跑过检查。abi.NewType 三个 err 都处理了（参考项目用 `_` 吞掉）；直接传 `[]Order`（go-ethereum 把 component 名 paperAmount 转驼峰后按名字匹配 Go 字段）；Pack 前先校验。
  - 问题：`a.Sign() < 0` 放过了 0（布置要求 > 0）；nil 时报 "is negative"，报错内容不对；`orders == nil ||` 多余。Claude 直接改了（`<= 0` + 报错带下标和值）。
  - Claude 写 tradedata_test.go：2 组 cast abi-encode 向量（1 taker + 1 maker 的 D8 例子；1 taker + 2 maker，info 含负费率全 ff），逐字节比对；7 个拒绝用例。变异 5 项抓 4：paper/credit 互换、perp/signer 互换、bytes[]/uint256[] 互换、info 改 uint256 都抓到；**int128 改 int256 是等价变异**——abi.encode 里两者都补成 32 字节、负数都符号扩展，值在 int128 范围内时编码完全一样（合约 decode 时才会检查范围）。
- 第 2 步 SubmitTrade：**一次写对**。拷贝 `opts := *s.auth` 再设 Context（没有原地改共享的 auth）；perpetual.NewPerpetual 现场绑定任意 perp；三处 err 都 %w 包装并标明阶段。Claude 小改：回执失败时返回 tx.Hash()（交易已上链，带哈希便于 cast receipt 查原因）。变量名 perpCaller 不准确（它是完整绑定，不只是 Caller），不影响。
- 第 3 步决定（用户选）：自成交处理选 **A 跳过、继续找下一张**（对比过 B 遇到就停、C 整张拒绝）。代价：簿可能出现同一 signer 的交叉（bid > ask），记入 D9 遗留。
- 第 3 步 Iter / crosses：**一次写对**，自己跑过检查。
  - crosses 没用布置推荐的"比较精确 Price"，而是照抄合约交叉相乘，同时判断 maker 方向（同侧 false）——结论正确，但 **temp1/temp2 的命名和合约正好相反**（用户的 temp1 = 合约的 temp2），比较方向也跟着反过来，读代码对照合约时容易看错。
  - Iter：两层 range + `if !yield(...) { return }` 正确；命名问题：`level` 其实是价位切片、`bookOrder` 其实是 priceLevel；缺文档注释。
  - Claude 写 TestIter（两侧顺序、同档中/跨档前/跨档后 break、只读、空簿）和 TestCrosses（8 例，期望值用精确价格独立推出，数量故意不同）。变异 10 项：初次漏 2 项「去掉 maker 方向判断」——同侧用例的价格恰好让交叉相乘也得 false；Claude 把同侧用例改成"单看交叉相乘会误判成交"的价格后两项都抓到。
- 第 4 步 PlaceOrder 初版（build/vet/gofmt/旧测试全过，**但新测试 7 个 FAIL + 1 个 panic**——旧测试根本没覆盖 PlaceOrder，"全绿"不代表写对）：
  - 做对的：撮合循环顺序（left==0 → 不交叉 break → 自己 continue）；`left` 是副本、成交量 `new(big.Int).Set` 新对象（双重原地修改坑都避开了）；上链失败直接返回不改簿；成功后才 Fill；buildTrade 用 slices.Clone 后 SortStableFunc + bytes.Compare 排副本，Match.Fills 保持价格-时间顺序；amounts[0] 先放 total 指针再累加（巧妙但隐晦）。
  - 漏掉的（布置细节清单里都有）：① **剩余部分没有 book.Add**——任何单都挂不进簿，引擎永远没有 maker；② 没判 `e.books[perp] == nil`（未知市场直接 nil 指针 panic）；③ 没判 ID 重复；④ 没判 Remaining nil / <= 0；⑤ 没记 traders；⑥ err 没 %w 包装，本地 Fill 失败（链上已成交）没有特别标明。
  - Claude 写 engine_test.go：fakeSubmitter（记录参数、可注入 revert）；贯穿例子 TestPlaceOrderWalkthrough（Fills 顺序与数量、提交顺序 aliceB/carol1/carol2/bob、amounts 8/3/3/2、上链后簿状态、自己的单不动）；不交叉只挂单；部分成交后挂剩余（2 例）；卖方 taker；上链失败簿/maker/taker 全不变 + errors.Is；拒绝 5 例；Traders 去重。先用参考补丁在副本上验证测试本身正确，再还原用户代码。
- 第 4 步第二版：6 条全补，**自己跑过 go test**，全绿。本地 Fill 失败的报错写明"trade 已上链但本地 fill 失败"。Claude 删了一行遗留注释 `// ← 补在这里`。
  - 变异 17 项抓 15，漏的 2 项都是等价变异：「不交叉时 continue 而不是 break」——价位已排序，第一个不交叉之后全都不交叉，结果相同只是多遍历；「SortStableFunc 换成 SortFunc」——pdqsort 在 12 个元素以内走插入排序，本身稳定；而且合约只要求同一 signer 相邻，同一人多张单之间的先后对链上结果没有影响，稳定只是让提交顺序更好读。
  - 小遗留：上链成功后 book.Add 剩余失败时，报错没说明"链上已成交"（理论上不会发生：ID 已在前面查过重）。
- 第 6 步 cmd/matchdemo 初版：**自己跑通了**（tx 0x1c66…0eb9，block 16，#1 → BTC.trade）。Claude 用 cast 独立核对：input 解码出 orderList = [alice 买 0.18, carol, bob]（carol 0x976E < bob 0x9965，排序生效）、amounts [1.8e17, 8e16, 1e17]；bob −1.1 张 / +32600、carol 0.92 张 / −23660，和预期一致。
  - 做得好：泛型 `must[T]` 消掉大量 if err；mustEnv 空私钥明确报错（D7 遗留坑修了）；diff 返回新对象不改快照；RecoverSigner 自检；ID 用 digest.Hex 再 HexToHash 回去查 getOrderFilledAmount；domainSeparator 用 c.ChainId。
  - 问题：① 对账期望值**全部写死**（1.8e17、−4680e6…），布置要求从 Match 推导——写死只能验证这一个场景，换场景就得手改，也没有直接比较"引擎的 Fills ↔ 链上"；② **没对账 Remaining**：引擎簿里 carol 剩 0.02，应等于 |paper| − 链上已成交 0.08，这是"引擎和链上一致"最核心的一条；③ 没打印 Fills 明细和 Snapshot。
- **Claude 的预测错了（重要）**：布置时说"跑第 2 次 alice IM 不够会 revert"，实际第 2 次成功了。查合约：`Perpetual.trade` 末尾是 `require(isAllSafe(traderList), "TRADER_NOT_SAFE")`，`isAllSafe` → `_isAllMMSafe`，**成交后只要求 MM（维持保证金 5%）安全，不要求 IM（10%）**；参考项目 perpetual-contract 也是这样。第 2 次后 alice 0.36 张：净值 482.6 ≥ MM 468，但 < IM 936（链上 isIMSafe=false、isSafe=true）。第 3 次 0.54 张 MM 702 > 482.6 → `execution reverted: TRADER_NOT_SAFE`，**区块号没变（17）**——revert 在 estimateGas 阶段就报出，交易根本没发出（第 2 步细节 3 的实证）。PLAN D3 一行"结算后检查所有参与者 IM safe"写得不准确。
  - 含义：链上不挡"开仓后低于 IM"，D9 的 API 如果要防用户开仓即接近爆仓，要在链下自己查 IM（或接受这个设计）。
- 第 6 步第二版（用户："这块不是重点"，由 Claude 改）：对账改成从 Match 推导——maker paperChange = ±Amount、creditChange = paperChange × credit / paper（**用 Quo 向零截断，对应 Solidity `/`；Div 是欧几里得除法，负数除不尽时差 1**），taker 取反求和；新增「引擎 Remaining + 链上 getOrderFilledAmount == |paper|」四张单逐一核对；打印 Fills 明细和 Snapshot。先用 cmd/demo 给 alice 存 1000（primary 1482.6）再跑：tx 0x3403…a0ca 成交，bob 0.1 吃满、carol 剩 0.02 + 链上 0.08、alice 自己的卖单 0.1 + 0、taker 0 + 0.18，asks 剩 26000×0.12（2 张），**reconciled ✓**。

## 留给 D9 / 后续
- **链上成交后只查 MM**：API 是否在链下额外检查 IM（防开仓即接近爆仓），D9 决定；PLAN D3 "IM safe" 一行需要更正（回「总体计划」会话）。
- 自成交选 A 的代价：同一 signer 可能让簿交叉（bid > ask），Snapshot 会显示交叉；如需 STP 再议。
- 下单入口要查链上已成交：同一张签名单撤单后重新提交时，NewBookOrder 的 Remaining = |paper|，但链上 orderFilledPaperAmount 可能已有值 → 再成交会 ORDER_FILLED_OVERFLOW。API 收单时应 `Remaining = |paper| − getOrderFilledAmount`。
- 一张坏 maker（过期 / 保证金不足）会让整笔 trade revert，taker 每次都吃到它、每次都失败：需要识别失败原因并剔除坏单（或提交前 eth_call 预检）。
- PlaceOrder 持锁等上链（秒级），所有市场串行；以后可按市场分锁或异步提交。
- 订单簿 bids/asks 重复代码合并、Best 简化、Iter/crosses 命名与注释（temp1/temp2 与合约对齐）未做。
- 订单过期：引擎不检查 expiration，过期单留在簿里直到被吃时链上 revert。
- 运行环境：anvil 重启后要重跑 Deploy + Demo（本次 10-26 已重跑一次），再用 cmd/demo 给 alice 存款。
