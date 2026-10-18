# D4 用户关键问题（清算 + 坏账 + 保险账户）

## 开工时的决定
- 保险账户地址：今天在 MetaNodeDealer 加临时 `setInsurance`（onlyOwner），和其他临时管理函数一起 D5 迁到 Operation。
- 清算后清算人的安全检查：PLAN 写 IM safe，参考实现用 `isSafe`（MM）。**第 4 步用户选 B：IM**（与参考实现不同）。理由：D3 trade 选 MM 是因为 IM 门槛交给 D7 撮合引擎接单时查；清算人直接调合约、不经过撮合引擎，链下没人替你查 IM。用 MM 时 carol 存 1040 就能接 26000 的仓（约 25x 贴着清算线），价格再跌 0.1% 她也可被清算 → 连环清算。Dealer 需新增 `isIMSafe` 并加进 IDealer。
- 价格保护 `expectCredit`：PLAN 没写，参考实现有，今天一起写（D8 清算机器人要用）。
- 笔记：D1–D3 手写实战笔记已由 D3 会话写好推送（Obsidian 提交 98f7937），收尾只写 D4 一篇，沿用同结构（frontmatter tags+created、参考/前后篇链接、做了什么 / 核心概念配数字 / 重点问题 / 踩坑 / 测试），开头链接 [[D3-EIP712订单签名与撮合结算]]。
- 用户要求每完成一步报一次进度（7 步，权重 5/15/15/20/10/10/25）。
- 待顺手处理：`Funding.sol` 第 4 行 `import "forge-std/console.sol"`（生产代码依赖测试库，未使用），让用户删掉。

## 用户踩过的坑（真实发生）
- （教学反馈）第 1 步初版只列"加什么"，用户要求每步讲清**作用、原因、后面的使用**才能全局理解 → 之后每步布置固定：一句话总述 → 作用/原因/后面的使用 → 数字例子 → 细节 → 你要写的。
- 第 1 步：一次写对并跑过编译（insurance 加在 State 末尾、setInsurance 带 onlyOwner、删了 Funding 的 console import）。setInsurance 写在了 MetaNodeExternal 而不是 MetaNodeDealer（功能等价，和其他临时管理函数不在一处，D5 一起搬到 Operation 时注意）。Claude 在 testAdminFunctionsOnlyOwner 补了 setInsurance，去掉 onlyOwner 变异被抓。
- （教学反馈）布置函数时要逐个讲清**每个参数和返回值的含义**（单位、符号约定、谁传入、谁使用）→ 之后每个函数都配参数表 + 返回值表。
- 第 2 步 getLiquidateCreditAmount 第一版（编译零警告、旧测试全绿，Claude 的 9 个新测试 8 个失败）：① 漏了"该市场 paper != 0"和"请求与仓位同号"两个 require——请求 -1 会让多头 alice 加仓、无仓位市场返回全 0 不报错；② `liqtorCreditChange = 名义价值 × liquidationPriceOff` 算出的是**折扣额**（+260）而不是**清算人付的钱**（-25740）：既没有 `1 ± off`、也没有 `-1 ×` 取负、也不分多空方向；③ 保险费用了 `initialMarginRatio` 而不是 `insuranceFeeRate`（数字碰巧都是 1e17/1e16 量级，读字段名才能看出），且基数用了标记价成交额 26000 而非折扣价成交额 25740。
- 第 2 步变异 6 项：去无仓位检查、去同号检查、不截断、不分多空、去可清算检查都被抓；**费率用错字段（insuranceFeeRate→liquidationPriceOff）一开始没被抓**——底座两个参数都是 1%。补 `testCreditAmountUsesInsuranceFeeRate`（费率改 2%）后被抓。教训：测试参数取值相同时，用错字段的 bug 测不出来。80/80。
- 第 3 步：测试冒充 BTC 市场（vm.prank(address(btc))）直接调 dealer.requestLiquidation，8 个测试（数字与守恒、空头、三事件、他人冒用、operator 授权/撤销、operator 键序、自清、未注册市场）。变异 7 项：去权限、键序反、去自清、保险不入账、不扣保险费、保险费符号反都被抓；**序号取错人一开始没被抓**（alice、carol 序号都是 0）→ 让 carol 先开平一次（序号 1）后被抓。88/88。
- 第 4 步：8 个端到端测试（场景 A 全流程含守恒、空头全流程、部分清算后恢复安全不能再清、单价比较正反例、多/空价格保护边界、清算人 IM 边界 2000 revert/2340 通过、执行人权限端到端）。变异 9 项：去多头/空头保护、多头不等号反、IM→MM、去清算人检查、executor 传 liquidator、不结算被清算人都被抓；**直接比 credit 一开始没被抓**——正例（请求 2 预期 -51600）下直接比较也碰巧通过；补反例（请求 2 预期 -51000，截断后单价 25740 > 25500 应 revert）后被抓。96/96。
- 第 5 步：5 个场景 B 测试（穿仓转保险 -1240 + 事件 + 守恒、保险预注资 2000 → 760、还有 ETH 仓位时不处理直到全清再一次转 -1517.4、部分清算不触发、任何人调用条件不满足时 no-op 不 revert）。变异 6 项全被抓（去无仓位条件、去穿仓条件、不清零、不转保险、钩子不调、钩子条件反）。101/101。secondaryCredit 无 setter（secondaryAsset 未设置），次级资产的坏账转移未测。
- 第 6 步：6 个测试（多/空数值、全仓含 ETH 及 ETH 跌价、返回 0 两种情况、换折扣字段强平价不变、边界性质测试）。边界性质测试发现**取整误差**：空头真实边界 33333.3333… 被 decimalDiv 向零截断，加上 MM 计算向下取整，实际要高 2 个最小单位才不安全——不是 bug（误差 < 0.00001 USDC），测试给空头留 0.01 USDC 容差并注释原因。变异 7 项全被抓（不跳过目标市场、漏 MM'、漏其他市场价值、多头用加、用折扣字段、NV' 漏主账户、负数不归零）。107/107。

## 留给后续
- **合约架构设计模式收尾总结**（用户 2026-10-16 提出，合约部分全部写完后做；会影响排期，放哪一天要回「总体计划」会话定）：
  1. 总结本项目的设计模式：继承拆分（Storage → External/Operation/View → Dealer）、库操作 storage、中心-辐射（Dealer + 多个 Perpetual）、回调与信任边界、权限按文件隔离等，配继承图和调用链。
  2. 横向对比之前写过的借贷类、DEX 类项目（Compound / Aave / Uniswap 风格）：代码组织、存储布局、可升级、多合约协作、钱放在哪、清算与坏账，并分析各自为什么这样选。
  - /Users/fei/Documents/Solidity 下的候选目录（待用户确认）：
    - 借贷：`ProjectBreakdown-Pledge/pledgev2`（Pledge 固定利率借贷，合约在 contracts/，有 PledgePool、DebtToken、Oracle）
    - DEX：`Base2_Solidity_Dex/swap-contract`（MetaNodeSwap，Uniswap V3 风格：Factory / Pool / PoolManager / PositionManager / SwapRouter）；`v2-core`、`v2-periphery`（Uniswap V2 官方源码）
    - 其他可参考：`Advanced2-contract-stake`（MetaNodeStake 质押）
    - 本地没有 Compound / Aave 的源码目录（只在 Pledge README 里提到），对比时按公开设计讲或需另拉代码。
