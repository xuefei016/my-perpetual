# D3 用户关键问题（供 D4 写合约篇笔记用）

## 开工时的决定
- 测试是否延续"Claude 写、用户看懂"：已在开工时问，待用户答复（默认延续）。
- `Perpetual.trade` 结尾安全检查：PLAN 写"IM safe"，参考实现用 `isAllSafe`（MM）；建议沿用 MM，第 6 步讲原因，不改 PLAN。
- `operatorRegistry` 今天引入（State 一行 + 验签多一个条件），setOperator 入口视情况。

## 用户踩过的坑（真实发生）
- 第 1 步 Types：一次写对（Order 5 字段、typehash、MatchResult、两个 mapping）；只有末尾多余空行、typehash 续行没缩进这类格式小问题。
- 第 2 步 EIP712（初稿，未跑编译就点了 Create PR）：`keccak256(name)` 直接传 string → Error 7556，keccak256 只收 bytes，要 `keccak256(bytes(name))`（string 和 bytes 内存布局相同，显式转换零成本）；`block.chainId` 大小写错，应为 `block.chainid`；MetaNodeStorage 构造函数调了 `_buildDomainSeparator` 但没把返回值赋给 `domainSeparator`（结果被丢弃，immutable 未初始化会触发 Error 2658，被前面的错误挡住还没显示）；Storage 用了不带花括号的 `import "./libraries/EIP712.sol"`（lint 的 unaliased-plain-import）。又一次没跑编译就报"写好了"。
- 第 3 步 Trading：`_structHash` 的 abi.encode 版一次写对。三个 info 解码函数括号位置错：写成 `uint64(uint256(info)) >> 192`（先截断成 64 位再右移，结果恒为 0），应为 `uint64(uint256(info) >> 192)`（先移位再截断）。编译、lint、28 个旧测试全绿，完全没暴露；Claude 先写了 3 个解码单测，全部 `0 != 期望值` 失败才抓到。后果：费率恒为 0（不收手续费）、过期时间恒为 0（第 6 步接上后所有订单都判过期）。教训：类型转换和运算符的结合顺序——转换是函数调用语法，括号包住谁就先转谁。
- 第 4 步 `_priceMatchCheck`：两个乘积（先转 int256 再乘）和两个不等号方向都对，但 taker 卖那一支的方向检查写成了 `require(takerOrder.paperAmount > 0)`（应为 makerOrder）——进 else 时 taker 必然 ≤ 0，所以 taker 卖单永远 revert。编译和旧测试全绿；Claude 写的 8 个价格测试里 2 个"taker 卖能成交"失败才抓到，而 2 个"taker 卖应 revert"的测试是"因为错误的原因通过"的——只测失败路径会把这种 bug 放过去，必须有成功路径测试。另：`import "./Errors.sol"` 又用了不带花括号的写法。
- 第 5a 步：一次写对（从 2 计数、循环从 2 开始且有 ++i、排序判断、成交量相等、按人数分配三个数组）。错误串和常量名不一致（`INVALID_TRADER_NUMBER` = "META_AT_LEAST_TWO_TRADERS"），不算错。
- （教学反馈）5b 布置直接从例子表格切入，用户要求"先用简练的话概括整体要实现什么功能，再罗列细节"。之后每块布置固定为：一句话总述 → 例子 → 细节 → 你要写的。
- 第 5b 步（第一版）：比价、paperChange 符号、按 maker 价算 creditChange（先乘后除）、同一 maker 合并的分支逻辑都对。但：① taker 在循环前按**自己的**订单价初始化（paper 恒为正、credit 按 30100 算），且循环里没有对 taker 记相反数——alice 会付 45150 而 maker 只收 45062，taker 卖单时 paper 方向也错（多空不相等）；② maker 的 signer 没写进 traderList，第 1、2 格是 address(0)；③ maker 手续费没从 maker credit 里扣，orderSenderFee 凭空多出钱；④ fee 用 `SafeCast.toUint256` 转无符号，maker 返佣（负费率）会直接 revert。⑤ 单独编译时没问题（internal 库函数没有调用方就不生成代码），一被测试调用就 **Stack too deep**——局部变量 + emit 的 7 个参数超过 EVM 16 个栈槽可访问范围；参考实现用 `{ }` 作用域块让 5a 的临时变量用完即释放。"编译通过"对没被调用的 internal 函数几乎没有意义。用户用两个 `{ }` 块分别包住 5a、5b 后编译通过。守恒测试的失败值 -83.4938 正好 = alice 多付的 -88 + 凭空多出的手续费 4.5062，测试数字能直接反推 bug。
- **问：taker 的 paper 按自己方向加符号、credit 按自己价格算，这样改行不行？** paper 可以（5a 已保证 taker 量 = maker 量之和、比价保证方向相反，结果等价）；credit 不行——taker 的价格只是限价线，taker 吃多档时每档按各自 maker 价成交，没有单一价格能一次算完。例：dave 卖 1 下限 29900，erin 买 0.3 价 30000、frank 买 0.7 价 29950，买方共付 29965，按 taker 价 dave 只收 29900，65 凭空消失。最终用户在循环里对格 0 逐笔 `-= paperChange / -= creditChange`，并在代码里注释"taker 的价格由 maker 决定，不是他自己决定的"。
- 5b 第二轮：把 fee 从 `creditChange` 本身减掉（`creditChange -= fee`），导致 taker 也只付扣费后的金额，orderSender 的手续费又凭空多出；emit 里再减一次 fee 变成扣两遍。另把费率 `SafeCast.toUint256(rate)` 转成无符号，返佣仍 revert。要点：maker 手续费只从 maker 那格扣，taker 付完整成交额，这笔钱拆成"给 maker 的 credit − fee"和"给 orderSender 的 fee"；有符号的量整条计算都保持 int256。
- 5b 第三轮：全部改对，48/48 全绿。变异 5 项全被抓：去排序检查（有意思：不报 WRONG_SORTING 而是数组越界 panic 0x32——人数数少了，第二个 bob 之后的 carol 没格子放）、去 taker 成交量检查、合并分支不扣 fee、taker 付扣费后金额、不调用比价。
- 第 5c 步：takerFee 直接用 `result.creditChangeList[0].decimalMul(rate)`，漏了 `abs()`。taker 卖时 credit 为正，结果碰巧对；taker 买时 credit 为负 → fee 为负 → 买方 taker 不但不付手续费反而拿返佣、orderSender 倒贴（-45062 − (−22.531) = −45039.469）。旧的 48 个测试 taker 费率全是 0，抓不到；Claude 补的 taker 买入手续费测试抓到，卖出测试是绿的——只测一个方向会漏掉"符号碰巧对"的 bug。5a 里注释掉的旧代码仍未删。
- 5c 第二轮：`abs()` 加在了费率上（`rate.abs()`），而不是成交额上——编译失败（abs 返回 uint256，decimalMul 的 int 版本收不了）；即便能编译也是错的：基数仍为负，费率取绝对值还会把返佣变成收费。又一次没跑编译就报"写好了"。
- 5c 第三轮：写成 `abs(credit × rate)`——对乘积取绝对值。费率 ≥ 0 时与正确写法等价，51 个测试全绿；但 taker 费率为负（返佣）时，用户签的是 -0.01%，却被收 +0.01%（违背签名意图）。Claude 补 `testMatchOrdersTakerRebate`：-30003 ≠ -29997。三种写法对比：abs(基数)×费率 ✓ / 基数×abs(费率) ✗ / abs(基数×费率) ✗。第四轮改对，52/52；变异 2 项（不扣 taker 费、taker 费不归 orderSender）均被抓。
- 用户要求在第 6 步前先提交一次：wip 提交 `ebe109a` 已推送（52/52）。
- 第 6a 步 approveTrade 逐单校验：解码、orderHash、过期、异号、perp == msg.sender、自成交、防超额成交都对，去掉了 view。问题：ERC1271 分支判断和调用的是 `recoverSigner`（从签名恢复出的地址），应为 `order.signer`——要问"这张单的主人认不认这个签名"，主人才是钱会被动的账户；恢复出的地址是 ECDSA 算出来的，必然是 EOA（没人有合约地址的私钥），所以合约钱包永远签不了单。多 import 了用不到的 ReentrancyGuard；lint 对 `block.timestamp` 比较报 block-timestamp（订单过期以秒计、验证者只能挪几秒，可接受，注释后 disable）。typehash 字符串、abi.encode 五项顺序、`_hashTypedDataV4` 一行都对。
- 第 6b 步：orderHashList、_matchOrders、手续费入账、返佣时 `_isSolidIMSafe` 检查、返回 result 都对；多余的 ReentrancyGuard import 已删。第一次说"写好了"时磁盘上没有 6b（疑似写在别的标签页/未保存），第二次才落盘。`setOperator` 仍未写。

## 第 7 步测试（Claude 写）
- `test/utils/EIP712Test.sol`：测试侧**独立**按 EIP-712 规范重算 domainSeparator / structHash / digest，再 `vm.sign`——不调用 src 的 EIP712/Trading，所以合约侧写错一个字节签名就恢复不出 signer。
- `test/utils/DealerFixture.sol`：从 Dealer.t.sol 抽出的公共底座（真 Dealer + Perpetual + 价格源 + `makeAddrAndKey` 带私钥的 alice/bob/carol），`_trade` 改为 long 当 taker、short 当 maker 双方签名；nonce 自增保证相同内容的单哈希不同。D2 的 12 个集成测试全部改用签名订单并通过（等于从另一侧验证了 domainSeparator 和 structHash 正确）。
- `test/ApproveTrade.t.sol` 16 个：domainSeparator 与规范一致、一对一带双边手续费、多 maker、分次成交到上限后超额、单次超额、整份 tradeData 重放、错签名、签后篡改、ERC1271 钱包能成交 / 不认别人签名、过期边界（== 有效、早 1 秒过期）、异号、市场不符、自成交、比价、orderSender 倒贴需保证金。
- 小坑：`vm.expectRevert` 之后的"下一次调用"会被 vm.sign 等构造步骤占用，所以 tradeData 要在 expectRevert 之前构造好。
- approveTrade 变异 11 项全部被抓（过期、异号、市场、自成交、超额、只比单次不累加、跳过签名比对两种、1271 问 recoverSigner、手续费不入账、去掉 orderSender 安全检查）。
- 第 7 步决定：`Perpetual.trade` 结尾保持 MM 检查（选项 A，与参考实现一致），IM 开仓门槛交给 D7 撮合引擎接单时检查。理由：全员 IM 会挡住"已低于 IM 但高于 MM 的人减仓"；只查 MM 的漏洞是可绕过杠杆上限（存 2000 开 30000 ≈15x）。PLAN 写的 IM 是与实现的差异，未改 PLAN。
- `setOperator`：赋值写成 `= true`，没用参数 `isValid`（编译器报 unused parameter 5667）→ 授权永远无法取消。bot 私钥泄露时用户无法止损。Claude 的 `testOperatorSignLifecycle` 在"取消授权后应 revert"处失败抓到。

## D3 收尾记录
- 全量 70 个测试（Trading 24 单测、ApproveTrade 18 集成、Dealer 12、Perpetual 6、SignedDecimalMath 7、Funding 3），`forge build --force` 零警告，lint 干净（两处 disable 均有注释：测试 `_packInfo` 的 unsafe-typecast、订单过期的 block-timestamp）。
- 与 PLAN 的差异：成交后安全检查保持 MM（`isAllSafe`），PLAN 写 IM；IM 门槛留给 D7 撮合引擎。approveTrade 集成测试放在 `test/ApproveTrade.t.sol`（PLAN 只列了 Trading.t.sol）。`_structHash` 用 abi.encode 版，未写 assembly 版。
- 留给后续：setOperator / 管理函数 D5 搬到 Operation；`MetaNodeView` 暂无 orderFilledPaperAmount / operatorRegistry 的查询函数（D5 后端需要时补）；D6 Go 端 EIP-712 要对齐 `domainSeparator()` 与测试 `EIP712Test` 的算法。
