# D1 用户关键问题（供 D4 写合约篇笔记用）

1. **测试怎么写？** forge 测试 = 继承 `Test` 的合约，`test*` 前缀函数，`assertEq`；`using Lib for T` 只挂第一个参数为 T 的重载；库名调用 + 字面量会重载歧义，要显式 `int256(...)`。
2. **uint 版本 `uint256(1.5e18).decimalMul(...)` 能不能写？** 需要额外 `using SignedDecimalMath for uint256;`，否则 "Member not found"。
3. **GoLand 怎么 debug Solidity 测试？** 不能打断点；用 `console.log`(-vv)、`-vvvv --decode-internal` trace、`forge test --match-test X --debug` 单步 TUI。
4. **`bytes calldata tradeData` 为什么两个修饰符？** `bytes` 是类型，`calldata` 是数据位置；calldata/memory/storage 对比；`memory` 拷贝修改不落链的坑。
5. **接口要写参数名吗？** 不必（选择器只看类型），但推荐写：ABI 带名字 → abigen 生成带字段名的 Go struct。
6. **自己写完如何发现问题？** 四层：编译器(warning 当 error) → forge lint → 测试（数值各不相同、写后读断言）→ Solidity 自查清单；最后再对照参考。
7. **构造函数怎么加？** OZ 4.9：`constructor(address _owner){ transferOwnership(_owner); }`；OZ 5.x 才是 `Ownable(_owner)`。

## 用户踩过的坑（真实发生）
- `balance memory b = balanceMap[x]` → 写入丢失
- `_settle(trader, credit, paper)` 参数顺序与数组/事件不一致（同类型编译器查不出）
- 为消 shadowing warning 改局部变量名后，仍用了未赋值的命名返回值 `paper` → 资金费恒为 0
- struct 改 int256 绕开 SafeCast → 失去 slot packing（2 slot，多 ~2 万 gas）
- event 声明顺序与 emit 实参顺序不一致
- `trade` 漏 `onlyOwner` → 任何人可凭空加 credit
- 思考题：decimalMul 向零截断，多空都少算，持仓拆散时总 credit 有 ±N wei 不守恒
- 参考代码 IPerpetual 注释"正费率多头付空头"与公式矛盾（fundingRate 上涨多头获益）

## 第二天（2026-10-09）补充的问题
8. **用例 2 只有 alice 买，bob 传什么？** 每笔交易必须有对手方；零和：paperChange 之和 = 0、creditChange 之和 = 0（D3 加手续费前）。
9. **非 owner 怎么写？** `vm.prank(alice)` + `vm.expectRevert("Ownable: caller is not the owner")`（OZ 4.9 字符串；5.x 是自定义错误）。
10. **prank 什么时候被用掉？**（实测）下一次对外部合约的 CALL，**包括 view 调用**；作弊码（`vm.label`/`makeAddr`/`expectRevert`）、internal 函数不消耗。多次调用用 `startPrank/stopPrank`。
11. **deposit 想实现什么？** 先 approve，再由合约 `safeTransferFrom` 拉取 + 记账（同一笔交易原子完成）；`to` 可替别人存；`SafeERC20` 兼容不返回 bool 的代币。
12. requestWithdraw / executeWithdraw / fastWithdraw / _withdraw 的设计：时间锁防"订单已签未上链就撤保证金"；pending 覆盖而非累加；CEI 先清零再转账 + nonReentrant；风控检查放在最后、失败整体回滚。

## 第二天踩过的坑
- requestWithdraw 用 `+=` 累加 → 无法撤销、事件与状态不一致
- executeWithdraw 用 `[to]` 当账户、`_withdraw(state, address(this), ...)` → `msg.sender`（谁操作）/ `to`（钱去哪）/ `address(this)`（Dealer 本身）混用
- `_withdraw` 漏掉安全检查 → 可偷别人存款；补上后又写成 `> 0` → 全额取款失败（off-by-one）；secondary 是 uint 无需检查
- MockERC20：直接给 OZ 的 private `_name` 赋值；`uint256 memory`（值类型不能写数据位置）；`mint` 写成 internal；父构造函数 `ERC20(...)` 写在函数体内（被当成类型转换）而不是函数头
- forge lint：`unsafe-typecast`（abs）、`block-timestamp`（时间锁）→ 修复或注释说明后 `forge-lint: disable-next-line`
- 变异测试：注释掉 `primaryCredit >= 0` 检查后，测试 ③ 变红，说明测试有效

> FundingHarness 和 Funding.t.sol 是用户让 Claude 代写的，D2 写 Dealer 时可以让用户自己重写一遍 harness → Dealer 的转换。
