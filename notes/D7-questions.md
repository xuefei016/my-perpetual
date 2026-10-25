# D7 用户关键问题（Go 后端骨架 + EIP-712 + 订单簿）

## 开工时的决定
- **（用户调整做法）先搭完整骨架，再每天往里填实现**：吸取合约部分的经验，先把 D7–D9 要用到的所有包、文件、类型、函数签名一次搭好（函数体统一 `panic("TODO(Dx): …")`），整个项目从第一天起就能 `go build`，哪个函数没实现，一跑就 panic 出是哪天的任务。骨架由 Claude 生成，用户逐文件 review；函数体仍然由用户手写。
  - 对排期的影响：D7 = 骨架 + EIP-712 + 订单簿；D8、D9 内容不变，改成往骨架里填。PLAN 需回「总体计划」会话调整。
- 架构（用户确认）：config / chain（eip712、tradedata、submit）/ engine（order、orderbook、engine）/ api（server、dto）/ keeper（funding、liquidator）；engine 只依赖 `TradeSubmitter` 接口（chain.TradeSender 实现），D8 单测可以塞假的提交器；D5 的演示挪到 `cmd/demo`，D7 链上验收工具放 `cmd/signorder`。
- 链上验收：Go 签名 + 打印参数，tradeData 用 `cast abi-encode` 编码（Go 编码是 D8 的 tradedata.go），orderSender #1 `cast send btc.trade`；成交量 0.1 张 @26000（alice credit 2482.6 < 1 张的 IM 2600）。

## 用户踩过的坑（真实发生）
- 第 1 步 PackInfo / UnpackInfo：**一次写对**。用 `encoding/binary` 的 BigEndian.PutUint64 / Uint64 按 8 字节切片写，`uint64(int64)` 补码重解读，没有走 big.Int（避开了 FillBytes 取绝对值、符号扩展污染两个坑）。build/vet/gofmt 干净。
  - Claude 写 `eip712_test.go` TestPackInfoMatchesSolidity：4 组向量（maker 负 taker 正 / 两侧都负 / int64 与 uint64 边界 / 全 0），期望值用 `chisel eval` 按 EIP712Test._packInfo 公式算出，解包侧在 chisel 里用 Trading._info2* 公式验证；每组同时测 Pack 和 Unpack。变异 5 项全抓（maker/taker 互换、expiration 小端、漏 nonce、解包 nonce 位置错、解包截成 32 位）。
- 第 2 步初版（build/vet/gofmt 全过，**哈希全错**——编译器和 vet 都不懂 abi 编码规则，只能靠对照向量）：
  ① DomainSeparator **漏了 domainTypeHash**；
  ② **括号错位**：`Keccak256(keccak("MetaNode"), Keccak256([]byte("1"), chainID.Bytes(), dealer.Bytes()))`——把 "1"、chainId、dealer 拼在一起又哈希了一层，本该是 5 个 32 字节平铺进同一个 keccak；
  ③ chainID.Bytes() 是最短大端（31337 → 2 字节 0x7a69）、dealer.Bytes() 是 20 字节，**都没补到 32 字节**（这是 encodePacked 不是 abi.encode）；
  ④ StructHash 的 perp/signer 同样没补 32 字节；
  ⑤ StructHash **漏了 Info 字段**（TestStructHashCoversEveryField 抓到：改 info 哈希不变 → 两张只差 nonce/过期/费率的单哈希相同，费率可以被篡改）。
  - 做对的：两个 typehash 字符串、math.U256Bytes 处理负数且传 `new(big.Int).Set` 副本（不改原订单）、Digest 的 0x1901 拼接。
  - Claude 补测试：TestTypeHashes、TestDomainSeparatorMatchesChain（= 链上值，且换 chainId/合约必变）、TestStructHashAndDigestMatchSolidity（chisel 算的向量）、TestStructHashDoesNotMutateOrder、TestStructHashCoversEveryField。
- 第 2 步第二版：domainTypeHash 补上、括号改平、Info 补上（TestStructHashCoversEveryField 转绿），**但补 32 字节补错了对象**：给 `math.U256Bytes(...)` 的结果套了 LeftPadBytes（它本来就固定 32 字节，套了等于没套），真正短的 chainID(2 字节)、dealer/perp/signer(20 字节) 仍没补 → DomainSeparator、StructHash 仍错。**也没自己跑 go test 就报改好了**（上一条明确给了命令）。Claude 用临时测试打印每段长度说明：判断要不要补，看的是"这个值的 Bytes() 有几个字节"，不是"它是不是数字"。
- 第 2 步第三版：chainID/dealer/perp/signer 全部 LeftPadBytes 到 32，去掉了 U256Bytes 外多余的 pad → 6 个测试全绿，DomainSeparator = 链上 cast call 值 0x8938cef4…1689。变异 8 项全抓（domain 漏 typeHash、name/version 顺序反、chainId 不补齐、perp/signer 顺序反、credit 取绝对值、U256Bytes 不拷贝（改坏原订单）、前缀少 0x01、name 大小写）。
- 第 3 步 SignOrder / RecoverSigner：**一次写对**。sig[64] += 27；Recover 先查长度 65、v ∈ {27,28}，**拷贝后**再减 27（没改调用方的 sig），SigToPub → PubkeyToAddress。小瑕疵：两种错误同一句 "invalid signature"、SigToPub 的 err 没包装（不影响正确性）。
  - Claude 补测试：TestSignOrderMatchesCast（RFC 6979 确定性签名，向量 = `cast wallet sign --no-hash`，v=0x1c）、TestSignThenRecover（恢复出 alice、不改 sig、篡改 credit 后恢复不出 alice）、TestRecoverSignerRejectsBadInput（v=0/1、v=29、64/66 字节、nil）。变异 5 项抓 4 项；漏掉的「删掉 v 校验」是**等价变异**：v=0/1 减 27 下溢成 229/230，SigToPub 本身也会报错，行为不变——显式校验的价值是错误信息清楚、不依赖库的内部行为。
- 第 5 步 cmd/signorder（build/vet/gofmt 干净）：**用户自己跑通上链**——#1 cast send btc.trade，tx 0x4bfef698…deca7，block 19，status 1，gas 243292。链上核对：alice btc paper 1e17 / credit -2600e6，bob -1.1e18 / 32600e6；Claude 解码 tx input 取出两张单，用 Go 重算 digest = OrderFilled 事件 topic[1]（alice 0x8e52e994…68dc、bob 0x9b103fb8…17b5）逐字节一致；getOrderFilledAmount 两张都是 1e17。**D7 EIP-712 验收完成。**
  - 做得好：Signer 从私钥推导（PubkeyToAddress，不会和私钥对不上）；nonce 用 UnixNano 每次新单；expiration 取 max(区块时间, 本机时间)+1h；DomainSeparator 传的是 Dealer；输出带单引号可以直接 eval 进 shell。
  - 问题：① **本地 domainSeparator 用了写死的 `big.NewInt(31337)` 而不是 c.ChainId**——这一步的意义就是"用连上的链的参数算，再和链上比"，写死后换链时这个检查照样通过（因为两边都是 31337 只在 anvil 成立），把真正的不一致藏起来；② 没做签完后 RecoverSigner 自检（布置里第 5 点）；③ 私钥环境变量为空时报 HexToECDSA 的 "invalid length, need 256 bits"（D5 同样的坑）；④ HeaderByNumber 的 err 检查前插了一行无关代码；⑤ 遗留空的 `var ()` 和 TODO 注释；⑥ panic 与 log.Fatal 混用。
- 第 5 步小修：改用 c.ChainId、补了 RecoverSigner 自检、删了 var () 和 TODO、统一成 panic。仍未改：空私钥的明确报错（留着，D9 统一配置时一起做）、HeaderByNumber 的 err 检查顺序——Claude 直接挪好；地址比较原来写成 `.Hex() != .Hex()`，common.Address 是 [20]byte 数组可以直接 `!=`，Claude 改成和 order.Signer 比较。
- 第 6 步开工前的决定（用户选）：数据结构用 **A 有序价位切片 + 档内 FIFO 切片 + map[ID] 索引**（对比过堆：不能有序遍历；btree：外部依赖；参考项目的双向链表：撤单 O(1) 但代码翻倍、4 处指针要维护。几十～几百档的规模下复杂度差异是微秒级，写对和好测更重要）；价格精度选 **① 拒绝不能整除的单**（|credit|×1e18/|paper| 有余数就报错——截断价排序会和合约 _priceMatchCheck 的交叉相乘判断不一致，链下以为能成交、链上 revert）。
- 第 6a 步初版（build/vet/gofmt 干净）：
  ① **NewBookOrder 没给 ID 赋值**（参数 id 收了没用，Go 不对未使用的函数参数报错）→ 所有单 ID 都是 ""，第二张单 Add 就报 "order already exists"，订单簿等于只能放一张单；
  ② Signature 直接存调用方的切片，没 bytes.Clone；
  ③ Add 没判 Remaining == nil，`o.Remaining.Sign()` 直接 panic。
  - 做对的：nil 检查放在最前；异号用 paper×credit 的符号判断（同时覆盖了 0）；QuoRem 余数判整除；Remaining 用 new(big.Int).Abs 是新对象（不会改签名原文）；Add 所有校验都在改状态之前；sort.Search 两侧方向正确（bids `<= 0`、asks `>= 0`）、同价追加队尾、不同价 slices.Insert 并赋值回去；Best 空簿返回 nil。
  - Seq 从 0 开始（布置说从 1），只影响可读性不影响排序。Best 写法冗长（var + 4 个分支），可以直接 return。bids/asks 两段几乎相同的代码可以用返回 *[]*priceLevel 的辅助函数合并。
  - Claude 写 orderbook_test.go：TestNewBookOrder（字段、原文不被改、Remaining 不与 PaperAmount 共享、签名副本）、TestNewBookOrderRejects（7 种非法）、TestAddPriceTimePriority（5 单例子的完整价位结构 + Best + Seq 递增 + 中间插档 + 新最优买价）、TestGetAndBestOnEmpty、TestAddRejects（重复/别的市场/0/nil 且被拒不改簿）。
- 第 6a 步第二版：只改了 ①（补 ID），②签名副本、③Remaining nil 判断没改，**又没跑 go test 就报改好了**（今天第二次；第 2 步第二版也是）。go test 仍有 2 个 FAIL，就是上一条列出的那两个。
- 第 6a 步第三版：签名 bytes.Clone、Remaining nil 判断都补上，**这次自己跑了 go test**，全绿。变异 10 项初次抓 9 项：漏掉「买侧同价插队首（LIFO）」——测试只有卖侧有同价单（B、C）。Claude 补了买侧同价用例（G、H 同价 26000，H 晚到排后面）后，两侧 LIFO 变异都抓到。
- 第 6b 步 Cancel / Fill / Depth：**一次写对，且自己跑过 go test**。抽了共用的 remove（Cancel 和 Fill 到 0 共用）；Fill 先校验 amount、存在、超额，再 Sub；Depth 的 Price 拷贝、Amount 新对象累加、n<=0 或超长都取全部。未做：bids/asks 两段重复代码没合并（Add、remove 各两份），remove 末尾多一个空行（gofmt 不管）。
  - Claude 补测试：TestDepth（两侧、取前 n、n 超长、空簿、返回值是副本）、TestCancel（撤队首、撤唯一单删整档、重复撤、买侧下一档顶上、撤后同 ID 可重挂）、TestCancelMiddleKeepsFIFO、TestFill（部分成交、不改签名原文、超额被拒不改簿、刚好成交完移出）、TestFillRejects。变异 11 项全抓。engine 10 个测试 + chain 9 个 = 19 个全绿。

## 本次概念问题（用户问的）
- main.go 的 HTTP 启动与优雅关闭：ListenAndServe 阻塞主 goroutine；另一个 goroutine 等 ctx.Done() 再调 Shutdown（停止接新请求、等进行中的请求跑完）；Shutdown 后 ListenAndServe 必定返回 http.ErrServerClosed，用 errors.Is 排除；Shutdown 不能传已取消的 ctx（会立刻放弃等待）；signal.NotifyContext 接管 Ctrl-C 后，删掉"关闭员"goroutine 进程就不会退出。
- config.go：Default（纯常量、可测）/ Load（环境变量覆盖 + 校验，D9）拆开；私钥只走环境变量；返回值而非指针；time.Duration 带单位语义。
- 为什么一个角色一把私钥：合约权限本就是三个地址 + 并发发交易时共用账户会 nonce 冲突。
- Go 部分排了几天：D5 后半（已完成）+ D7、D8、D9；D6 横向对比剩余部分排在 Go 之后。

## 留给 D8 / 后续
- D8：Engine.PlaceOrder（taker 依次吃 Best、价格交叉判断与合约 _priceMatchCheck 一致、上链成功后再 Fill）/ CancelOrder / Snapshot / Traders；chain.EncodeTradeData（替代今天的 cast abi-encode）、TradeSender.SubmitTrade。思考题待答：为什么必须"上链成功后才 Fill"。
- 订单簿可整理：bids/asks 两份重复代码（Add、remove）合并成按 Side 取 *[]*priceLevel 的辅助函数；Best 简化写法；Seq 从 0 开始。
- RecoverSigner：两种错误同一句话、SigToPub err 未包装；high-s 检查 D9 决定。
- signorder / 配置：空私钥的明确报错留到 D9 Load 统一做；Chain 只有 BTC 一个字段（多市场时改 map）。
- 排期：D7 跨了 10-22～10-25 四个自然日（新增骨架）；PLAN 调整回「总体计划」会话。
