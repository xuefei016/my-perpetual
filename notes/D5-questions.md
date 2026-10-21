# D5 用户关键问题（管理函数 + 部署 + Go 骨架）

## 开工时的决定
- setOperator：是用户自助函数（msg.sender 给自己授权机器人），**入口留在 MetaNodeExternal**，不迁到 MetaNodeOperation（那个文件只放 onlyOwner 的管理入口）。
- Go 后端位置：按 PLAN，同级独立仓库 `/Users/fei/Documents/Solidity/my-perpetual-backend`（用户确认）。
- 资金费入口：用户选**今天补上**。原因：Perpetual.updateFundingRate 是 onlyOwner，owner 是 Dealer，而 Dealer 没有转发函数 → 部署后无人能改资金费率，D9 keeper 无入口。做法同参考实现：State 加 fundingRateKeeper，Operation 加 setFundingRateKeeper（onlyOwner）+ updateFundingRate（onlyFundingRateKeeper）。
- setPerpRiskParams 参数校验：用户选**加** `liquidationPriceOff + insuranceFeeRate <= liquidationThreshold`（否则清算本身就把被清算人打穿仓）。
- 步骤与权重：1 Operation 20 / 2 View+组装 15 / 3 测试 10 / 4 部署脚本 20 / 5 Go 骨架+abigen 15 / 6 Go 读 10 / 7 Go deposit 10。

## 用户踩过的坑（真实发生）
- 第 1 步初版（编译通过，106/107，Perpetual.t.sol 的 testNotOwnerCallUpdateFunding 失败）：
  ① **删掉了 Perpetual.updateFundingRate 的 onlyOwner**——以为库里发出的调用过不了 onlyOwner。实际 external 库函数是 DELEGATECALL，在 Dealer 的上下文里执行，库里再调 Perpetual 时 msg.sender 就是 Dealer。删掉后任何人都能改资金费率、直接改所有人的 credit（D1 的旧测试抓住了）。
  ② setFundingRateKeeper 和 updateFundingRate 的修饰符**写反了**：setFundingRateKeeper 用了 onlyFundingRateKeeper（初始 keeper 是 0 地址 → 永远没人能设置，死锁），updateFundingRate 用了 onlyOwner。
  ③ 漏了 setPerpRiskParams 的参数校验 require（开工时用户选了加）。
  ④ 细节：MetaNodeOperation 没写 abstract；多余的 import（MetaNodeOperation 里的 IPerpetual，Dealer 里的 Types）；Operation 用了 `import "../interfaces/IPerpetual.sol"` 非具名导入，和项目其他地方的 `{X}` 风格不一致。forge lint 没报这些，要靠人看。

- 第 2 步：一次写对（零警告、107/107）。
- 第 3 步（Claude 写测试）：test/Operation.t.sol 两个合约 12 个测试——OperationTest 6 个（资金费权限、绕过 Dealer 直接改 Perpetual、rate 0→10e6 多 +10 空 -10 且事件由 Dealer 地址发出、多市场与长度、风控校验 3%+3% revert / 2%+3%=5% 通过 / 多 1 wei revert、6 个 setter 事件旧值新值 + state getter）；ViewTest 6 个（getRiskParams、场景 A 的 positions/credit/risk/强平价、多头清算成本全部/部分/超额截断/反号/安全账户、空头清算成本 +33835、订单已成交量、operator 键序）。变异 14 项全被抓（修饰符互换、删校验、<= 改 <、校验用错字段、oldRate 写新值、删长度检查、SetInsurance 旧值、只更新第一个市场、返回值交换、键序反、成交量恒 0、getRiskParams 读 msg.sender、Perpetual 去 onlyOwner）。119/119。
- 知识点：external 库函数是 DELEGATECALL，库里 emit 的事件**由 Dealer 地址发出**（expectEmit 要写 address(dealer)）；但 solc 0.8.19 不会把库事件放进 Dealer 的 ABI → Go 用 abigen 解析这些事件时要单独用 Operation 库的 ABI（D7+ 监听事件时注意）。
- 第 4 步初版 Deploy.s.sol（照抄参考项目 DeploySepolia 结构，编译通过、anvil 上 13 笔交易全部成功）：
  ① **`setPerpRiskParams(address(pxBtc), ...)` 注册成了价格源地址而不是 perpBtc**——脚本"成功"，但 cast call getRiskParams(btc) 返回全 0 / isRegistered=false，价格源地址反而被注册成市场 → Perpetual 回调 Dealer 会被 onlyRegisteredPerp 拦下，系统根本不能交易。教训：**部署脚本"跑成功"≠ 配置对**，必须用 cast call 逐项读回验证。
  ② 漏了 `usdc.mint(TRADER, ...)`（第 7 步 Go 存款需要），console.log 漏了 USDC 和价格源地址（Go 要用）。
  ③ 照抄了参考项目的风控参数（IM 5% / MM 3% / "BTC-PERP"）和"不配环境变量就全用部署者"的角色默认值 → anvil 上 owner = insurance = keeper = orderSender 全是 #0 账户；构造时已给 30000 又多调一次 setMarkPrice。
  ④ 思考题（owner 是谁）未回答；cast 读回 owner = 0xf39F…（#0 账户），不是脚本合约。
- 第 4 步第二版：注册地址改对、mint 给 #4、角色改成 anvil #1–#3 常量、删多余 setMarkPrice、import 改具名。**仍漏：风控参数只改了名字（IM/MM 还是 5%/3%）、日志仍缺 USDC/价格源地址**——Claude 直接改掉（机械性两处），并删了未使用的 DEPLOYER 常量。思考题仍未回答 → Claude 讲解：`vm.startBroadcast(pk)` 让之后每个调用都变成由 pk 对应账户（#0）签名发出的真实交易，`new MetaNodeDealer` 这笔创建交易的 msg.sender = #0，所以 Ownable 构造函数把 owner 设成 #0；后续 set* 也是 #0 发的，onlyOwner 通过。（若不 broadcast，在脚本模拟里 msg.sender 是脚本合约。）
- 第 4 步验证（重开 anvil 全新部署，13 笔交易：3 个 external 库 Funding/Liquidation/Operation 由 forge 自动先部署并链接）：owner=#0、btc 注册 {1e17,5e16,1e16,1e16,价格源,"BTC-USDC",true}、btc.owner=Dealer、state getter 读出 maxPositionAmount 20 / insurance #2 / keeper #3、价格 30000e6、#4 有 100000e6 USDC。**validOrderSender 没有 view 函数**，用 `forge inspect MetaNodeDealer storageLayout`（state 从 slot 2 开始、validOrderSender 是第 15 个字段 → slot 16）+ `cast index address <addr> 16` + `cast storage` 直接读 mapping：#1 = 1、#0 = 0。
- 运行环境踩坑（Claude）：第一次用 `(anvil --silent &)` 后紧接着 forge script，脚本卡住、txpool 里 8 笔 queued（nonce 断档）；重开 anvil（nohup 后台）后再跑正常。

- **（用户调整）第 5 步开始前，用户决定 Go 骨架（第 5–7 步）挪到明天**，今天先把合约架构讲清楚：①写完后怎么跑起来 ②合约部分怎么收尾。
- 「怎么跑起来」：Claude 写了 `script/Demo.s.sol`（演示脚本，不是用户手写），在 Deploy 部署好的 anvil 上用 4 个 anvil 账户真实跑场景 A：存款（alice 5000 / bob 5000 / carol 10000）→ alice、bob 用 vm.sign 签 EIP-712 订单，撮合引擎 #1 调 btc.trade 成交 1 张 @30000 → 任何人改价到 26000（alice 净值 1000 < MM 1300）→ carol 先 getLiquidationCost 得 -25740 作为 expectCredit，再 btc.liquidate。链上读回：alice paper 0、primaryCredit 482.6（5000 − 30000 + 25740 − 257.4）、保险账户 257.4、carol 持 1 张。写脚本时踩到：console2.log 没有 (int,int,int) 重载、run() 局部变量太多 Stack too deep（拆成 4 个 step 函数）、NatSpec `///` 注释里出现 `@30000` 会被当成文档标签报错。

- **（用户调整）部署分三阶段走**：①不连链的本地模拟（`forge script` 不带 --rpc-url，-vvvv 能看到 `Operation::setX(2, …) [delegatecall]`——2 就是 state 的起始存储槽，库拿着槽号改 Dealer 存储）②用户自己开 anvil 广播部署 + 6 项 cast 核对（全部通过：owner、BTC 注册、Perpetual owner=Dealer、state 7 个值字段、#4 余额、cast storage 读 validOrderSender）③Sepolia——**用户决定不上 Sepolia，只在本地 anvil 跑**。
- anvil 上 13 笔部署交易只出了 2 个块：forge 并发发送，anvil 把同时到达的打进同一块。

## 留给后续
- **Go 骨架 + abigen + 读链上 + 发 deposit（原 D5 第 5–7 步）挪到下一次**，排期调整需回「总体计划」会话；第 5 步的布置（目录结构、类型对照、abigen 命令、go-ethereum 对齐 1.17.4）已在本会话讲完，可直接照做。
