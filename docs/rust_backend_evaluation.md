# Rust → SA 落地评估：sa_plugin_rust 现状 与 sci/sa 底层缺口

日期：2026-09-27
范围：`sa_plugin_rust`（新建）实现过程中的实测结论，以及为了「更完美支持 Rust」
`sci`/`sa` 底层需要补齐的能力。

---

## 一、交付现状

### 1.1 已完成并验证

| 组件 | 文件 | 规模 | 验证 |
|---|---|---|---|
| Lexer | `src/lexer.zig` | 805 行 | 11/11 测试 |
| AST | `src/ast.zig` | 1162 行 | 5/5 测试 |
| Parser | `src/parser.zig` | 3601 行 | 42/42 测试 |
| Layout | `src/layout.zig` | ~760 行 | 5/5 测试 |
| Lowering | `src/lower.zig` | ~3600 行 | 跨层测试 |
| 单态化 | `src/monomorph.zig` | ~330 行 | 泛型函数 + 泛型结构体/枚举端到端 |
| 插件层 | `plugin.zig` / `plugin_commands.zig` / `local_cli.zig` / `host_paths.zig` / `plugin_skills.zig` | ~900 行 | `zig build` + `sa plugin install --dev` 通过 |
| 合计 | | 121/121 测试全绿，10/10 e2e 端到端（每个 fixture 额外做一次 `-g` 调试构建） | |

**泛型已可用**：`fn sum<T>(p: T, q: T)` 与 `struct Pair<T>` 会按具体类型实参
单态化，生成 `sum__PAIR` / `Pair__I32` 这样的具体符号，`#def` 布局随之生成。
显式 turbofish、调用点类型推断、嵌套泛型折叠、类型实参去重均已验证。

### 1.2 关键量化结果

**Parser 覆盖率：313/313（100%）**

用 `sa_plugin_sla/demos/rosetta` 的 **313 个真实 Rust 文件**做回归，全部解析成功。
这覆盖了：泛型、trait/impl、GAT、生命周期、let-chains、let-else、标签循环、
`?` 运算符、宏定义、属性、raw string、`cfg`、`extern "C"`、元组/切片/数组类型、
模式（or/range/slice/绑定@子模式/结构体/元组结构体）、`macro_rules!`、负 impl、
specialization（`default impl`/`default fn`）等。

**端到端验证（真实 `sa` 编译器 + 真实可执行文件）**

```
$ sa rust build-exe rich.rs -o rich
Rust Compiler: compiled rich.rs to rich.sa.
$ ./rich
max=20
sum=55
point=3
acc=10
```

`rich.rs` 覆盖：`struct` 布局、函数签名与调用、`if/else` 表达式值、`while`、
`for` 范围循环、`println!` 带参格式化、字段访问。

**当前 lowering 覆盖的构造**：标量算术/比较/逻辑（含短路）、`if`/`else`（语句与
表达式两种形态）、`while`、`for a..b`、`loop`、`break`/`continue`、函数调用与
方法调用、struct/tuple/array 字面量与下标/字段访问、赋值与复合赋值、`as` 转换、
借用与解引用、`match`（enum）、`?` 运算符、`println!`/`print!`/`format!`/
`panic!`/`assert!`/`vec!`。

**未覆盖**（lowering 计入 `unsupported` 计数而非静默丢弃）：`Box`/`Vec`/`String`
的堆语义、trait 静态/动态分发、闭包、迭代器、`async`、`Drop` 实现、字符串相等
比较、格式规格（`{:.2}` / `{:>4}`）、`match` on 聚合体（结构化匹配）。

### 1.5 模式解构与标量 `match`

这两项原先都是**静默错误**，不是「不支持」：

* `let (a, b) = ..;` 直接被丢掉并 note 一次，`a`/`b` 从不存在，之后用到它们的
  地方读到的是别的寄存器——一个能编译、能运行、结果是错的程序。
* `match` 遇到非 enum 题型时**只 lowering 第一个臂**，其余臂的副作用整段消失。

现在：

* `bindPattern` 处理 `pat_ident` / `pat_tuple` / `pat_tuple_struct` /
  `pat_struct`（含 `..`）/ `pat_ref` / `pat_or`（校验各分支绑定同名）。
  聚合体本来就是一个堆块，解构只是把每个字段 `load` 进自己的寄存器——
  与参考实现 `12_destructuring` 的形状一致，没有拷贝。
  关键细节：**谁拥有这个块**。`let (a, b) = (2, 5);` 的元组是这条语句的，
  语句结束就 `!`；`let P { x, .. } = p;` 只是读 `p`，`p` 仍归自己的绑定所有，
  由作用域出口释放。判据取自**活跃集合快照**（降低前是否已在其中），
  而不是靠初始化表达式的形状去猜——猜错就是泄漏或 use-after-free。
* `lowerMatchScalar` 把标量 `match` 降成一条 `eq`/`sge`/`slt` 派发链，
  臂形态覆盖字面量、区间、or-模式、绑定、以及 `if` guard。值位置会像 `if`
  一样分配合流槽。链的形状与 enum 路径共用同一套活跃集合协议。

途中撞出并修掉的三个真实缺陷：

1. 值位置 `match` 原来没有合流槽，函数以 `ret void` 结束而签名写着返回值，
   后端直接拒绝（`Function return type does not match operand type`）。
2. guard 被**整个忽略**，于是 `x if x > LIMIT` 匹配一切，后面的臂全成死代码。
   guard 在派发块里求值（`br` 之前），所以模式绑定必须**提前**——
   对标量而言就是先把被匹配者拷一份；这些临时寄存器归该臂所有，
   臂尾释放、落空路径也释放。
3. 绑定臂 `x => ...` 原来发的是 `load n+0`，即读 `n` 那个地址上的内存，
   与 `n` 的值毫无关系。标量被匹配者是寄存器不是地址，只能拷贝不能 load。

### 1.6 边界筛查查出的问题（`jev_edge_cases`）

把新增代码原文交给边界筛查，判定的两个最脆弱维度是「空与缺省」与「边界数值」。
逐一验证后，确实都是真缺陷：

1. **测不出的模式被当成「恒真」。**
   `emitPatternTest` 原来在无法生成测试时返回 `"1"`，于是
   `match s { "a" => 1, "b" => 2, _ => 0 }`（`s: &str`）**对任何输入都返回 1**，
   而且一声不吭——字符串字面量模式没有单寄存器形式。
   改成：`patternIsTestable` 纯判定 + `emitPatternTest` 返回 `null`，
   `lowerMatchScalar` 在**发出任何指令之前**就检查全部臂，任一臂不可测就整体
   报 unsupported。宁可拒绝，也不猜。
2. **区间比较不跟题型走。** `1..=5` 在 `u32` 上发的是 `sgt`/`sle`，
   于是 `3_000_000_000` 被判为「不在区间内」——超过 `MAX_INT` 之后
   有符号比较的结论是反的，而且同样静默。改为按 `unsignedOf` 选
   `uge/ugt/ule/ult`。
3. **`..=` 只在一端inclusive。** parser 把 `inclusive_start` 硬编码为 `false`，
   于是 `1..=5` 连 `1` 本身都不接受。Rust 没有半开区间，一个标志决定两端。
4. **负数区间端点是语法错误。** `parsePatternPrimary` 的 `.minus` 分支直接读
   `pat_literal` 字段，而 `-2..=-1` 解析出来是 `pat_range` —— 对 union 读错字段
   直接 panic；上界 `-1` 则完全没有处理。
   现在按 tag 分派，并给 `parseLiteralOrPathAtom` 补上负号。
5. **`let x = match ..` 根本没产生值。** `value_pos` 只在块尾表达式里被置位，
   `lowerLet` 没置，于是 `match` 降成语句形态、什么值都不留，
   发出一条空的 `x = `，flattener 报 `InvalidSyntax`。`lowerLet` 现在同样置位。
6. **值位置不可达的 `match` 会伪装成能编译。** 占位值返回 `()`，
   而签名写着 `-> i32`，后端只报「return type does not match operand type of
   return inst」——这条信息完全指不到原因。改成：值位置直接报
   `error.Unsupported`（语句位置仍可降级，`()` 对语句是诚实的值）。
7. **合流块在 merge 前被丢出活跃集合**，函数出口 `MemoryLeak`。
   `restoreLive` 要带上结果块；取走它的下一手（`let` 移动 `&str` 盒子）再 untrack。

`--deny-unsupported` 的退出码经复核是正确的 1（此前一次读数取的是管道里
`head` 的退出码，不是命令的）。

### 1.7 整数边界（第二轮边界筛查）

`jev_edge_cases` 第二轮把 `null_empty_omitted` 从 0.55 降到 0.20，剩下的唯一
脆弱维度是 `boundary_numbers`（0.72）。查下来有一个真缺陷：

**`layout.parseIntLiteral` 用的是回绕累加**（`acc *% radix + d`），再
`@bitCast` 成 `i64`。于是 `18446744073709551615`（`u64::MAX`）累加得到
`0xFFFF_FFFF_FFFF_FFFF`，bitcast 之后是 **`-1`**：
`match n { 18446744073709551615 => 1, _ => 0 }` 编译成 `eq n, -1`，
匹配的是完全相反的值，而且一声不吭。

修法：

1. `parseIntValue` 改成**检查过的**累加（`std.math.mul`/`add`），越界返回
   `null` 而不是回绕；`parseIntLiteral` 额外拒绝超过 `i64::MAX` 的非负值。
   `i64::MIN`（量级恰为 `2^63`）用二进制补码取负，不会溢出转换。
2. 新增 `intLiteralText`：直接输出**十进制原文**。`SA` 接受全宽立即数
   （已实测 `n = 18446744073709551615` 与 `eq n, 18446744073709551615` 均可），
   所以模式与 `let` 都不该再绕道 `i64` 往返。
3. `lowerLiteral` 的整数同样改用原文输出；只有在连 `u64` 都装不下时才
   `note` + 占位，而不是静默变成 `0`。

**已验证**：`i64::MIN` / `i64::MAX` 作为模式与作为调用实参都正确
（输出 `1 2 3`）。

**仍然存在的 SA 侧限制**：`u64` 中大于 `i64::MAX` 的值**不能作为实参传入
带类型的参数**。手写 `.sa` 实测 `@g(n: u64)` + `call @g(18446744073709551615)`
进去的值与该立即数不相等（`r=0`）。也就是说前端现在发出的文本是对的，
是 `SA` 的参数通路把它截断了。这属于底层缺口，不是前端能补的；
`SA` 需要参数传递按声明宽度取值。

### 1.3 `&str` 落地：`[data, len]` 胖指针

`SA` 没有任何字符串字面量糖，也没有值拷贝指令。`sci/docs/requirements.md`
第 9 条给出的正规写法是两步声明：先 `@const NAME = utf8:"..."`，再在运行时
构造胖指针。`lower.zig` 采纳这个形状，并按「**哪个上下文不需要拷贝**」分三种
形式（`Value.str_form`）：

| 形式 | `reg` 的含义 | 用在哪 | 指令数 |
|---|---|---|---|
| `const_text` | 内联 `@const` 的名字 | `println!("{}", "hi")`、`"lit".len()` | 0 / 1 |
| `at_addr` | `[data, len]` **就地**存在 `reg` 指向的地址 | struct 字段 | 2 |
| `boxed` | 指向 16 字节盒子的指针 | 绑定、调用实参、返回值、分支合流槽 | 4 |

这样做的收益是 `&str` 从此是一个**真正的值**：可以穿过绑定、函数调用、返回值、
分支合流（`if` / `match`）、struct 字段，并且 `len()` / `is_empty()` 有了确定的
语义。在此之前 `&str` 只是一个编译期名字，一旦离开直线代码就没有地方存放长度，
`let y = if c { "pos" } else { "neg" };` 会把数据地址当整数打印。

> 代价：SA 没有 `copy`，所以「把一个 `&str` 变量搬进 struct 字段」在语义上是
> 复制同一个盒子。`emitStrInto` 选择**读出两个字再写进去、并保留源盒子**。
> 对不可变的 `&str` 这个别名是安全的（无人能通过它写入），源在自身作用域出口
> 才释放。这正是文档第四节「生命周期由前端做保守近似」的策略。

### 1.4 顺带修掉的两个正确性缺陷

这两条都不是 `&str` 引入的，是被新 fixture 撞出来的既有问题：

1. **分支臂释放了外层作用域的活跃寄存器。**
   `lowerIf` / `lowerMatch` 原来在臂尾 `releaseAll("除了结果块以外全部")`，
   这把合流点之前就存活的局部变量也 `!` 了。于是
   `let a = 5; let b = if a > 0 {1} else {2}; println!("{}", a);`
   会在 Referee 报 `UseAfterMove`。
   修法：臂只释放**自己创建**的寄存器（`armKeep(outer_live, dst)`），外层集合原样
   带到合流点。`else if` 链需要把外层的 keep-set 一路传下去（`inherited_outer`），
   否则链上各臂对合流点的看法不一致，会撞 `BranchArmLiveSetMismatch`。

2. **`&str` 字段在布局里只占 1 个字。**
   `layout.zig` 把所有 `&T` 一律当成 8 字节，于是 `Tag { label: &str, rank: i32 }`
   的 `rank` 落在 `label` 的长度字上——`t.label.len()` 读回 7（`rank` 的值），
   一个**看起来完全合理的错数**，比 trap 更危险。
   修法：按**被指类型的形状**判定，`&str` / `&[T]` / `&dyn Trait` 是 16 字节，
   `&i32` / `&[i32; 4]` / `&i128` 仍然是 8 字节。

3. **`stringConst` 把调用方的切片当 map key 存了下来。**
   `println!` 的格式串扫描器用的是一个 `ArrayList`，宏调用结束就 `deinit`；
   存进去的 key 随即悬空，下次插入时读到已释放内存、与别的字符串撞上，
   `putAssumeCapacityNoClobberContext` 直接 abort 掉整个编译。
   修法：key 必须 `dupe` 一份自己拥有。

4. **值位置的 `if` 只要有一个分支发散，合流点就没有终结指令。**
   `fn f(n) { if n > 0 { 1 } else { panic!("x") } }` 里 `panic!` 会置
   `fn_done`，而 `emitReturnFrom` 看到 `fn_done` 就不发 `return`，
   于是 `L_MERGE` 后面直接结束 —— `FallthroughForbidden`。
   根因是 `fn_done` 同时表达了「这个块结束了」和「整个函数结束了」两件事。
   修法：`lowerIf` 分别记下两个臂是否可达，只有**全部**臂发散时函数才算结束。

5. **发散分支臂会在终结指令之后留下不可达代码。**
   臂以 `panic` / `return` 结束后，`releaseAll` 仍然把 `!` 发了出来。
   普通构建下 Referee 容忍，但 `sa build-exe -g` 的 LLVM emitter 直接拒绝整个
   程序（`InvalidOperand`）——**任何带 panic 分支的 `if`，调试构建都是坏的**。
   修法：臂发散时只把活跃集合恢复成合流点的形状（纯簿记），不发 `!` 也不发
   `jmp`；`lowerIf` 与 `lowerMatch` 都要改。

---

## 二、SA-ASM 的关键语义（实测确认，非文档推断）

这些是实现过程中**必须靠试错才发现**的语义，直接决定了 lowering 的形状：

### 2.1 `dst = src` 是 MOVE，不是拷贝

```
b = a      // 消费 a
!a         // UseAfterMove
```

这是影响最大的发现。后果：

* **不能**用「先算到临时寄存器再赋值」的模式。
* 必须把目标寄存器名**前置**到表达式的最外层操作上：
  `let s = a + b` → `s = add a, b`（而不是 `tmp = add a, b; s = tmp`）。
  `lower.zig` 的 `pending_dest` 机制就是为此。
* Rust 的拷贝语义（`Copy` 类型）只能表达成算术恒等式：
  `b = add a, 0`。`sa_plugin_sla` 的参考输出正是这么做的
  （`101_custom_drop/main.sa` 里的 `tmp_3 = add n, 0`）。
* **SA 层面没有值克隆指令**。任何需要「保留原值」的语义，前端必须重新计算而
  不是复制。

### 2.2 `load` / `store` 必须显式写 `+offset`

`load base as T` 是语法错误（`ForbiddenSyntax`）；必须 `load base+0 as T`。
`flattener.parseAddress` 按第一个 `+` 切分，没有裸寄存器地址这种形式。

**推论（实测）**：一个地址里只能有一个 `+`。生成的布局字典是
`#def Tag_label = +0`（自带符号），所以 `store t+Tag_label+0, ...` 会被折叠成
`0+0` 然后解析失败。字符串这类需要第二个偏移量时，先用 `ptr_add` 取出字段地址
再 `store addr+0` / `store addr+8`。

### 2.3 `stack_alloc` 不能显式 `!`

循环归纳变量必须 `stack_alloc` 且提到循环外（`PhiStateConflict`），
但槽位只能靠函数出口自动回收，不能 `!slot`（`StackEscape`）。

### 2.4 循环的活跃集合必须精确对称

`br c -> L_BODY, L_END` 之后，**回边（back edge）呈现的活跃集合必须与 `L_COND`
入口完全一致**，否则 `PhiStateConflict`。参考实现的形状是：

```
L_COND:
    i = load slot+0
    more = ult i, n
    br more -> L_BODY, L_END
L_BODY:
    ...
    !i
    !more
    jmp L_COND
L_END:
    !i          # 再释放一次：L_END 的入口状态来自 br 的假边
    !more
    !slot
    return
```

`lower.zig` 用 `snapshotLive` / `restoreLive` / `releaseAllFrom` 三件套实现
这一点，其中 `releaseAllFrom(loop_live)` 是「回到循环入口的活跃集合」。

### 2.5 分支的每个分支臂必须重置活跃集合

`releaseAll` 会排空集合，所以第二个分支臂若不重置就会漏释放 → 汇合点
`PhiStateConflict`。这也是 `snapshotLive` 存在的原因。

**并且：分支臂只能释放自己创建的寄存器。** 把「除结果块以外全部释放」当成臂的
清理动作，会连带释放分支之前就存活的局部变量，它们在合流点之后被读到时就是
`UseAfterMove`。正确形状是 keep = 进入分支时的活跃集合 ∪ {结果块}。
`else if` 链必须把这个 keep-set 传给下一节，否则链上各臂的合流点状态不一致。

### 2.6 `if` 作为表达式时目标必须在分支前分配

```
dst = alloc 8            # 必须在 br 之前
c = <cond>
br c -> L_THEN, L_ELSE
L_THEN:
    store dst+0, v as T
    jmp L_MERGE
L_ELSE:
    store dst+0, w as T
    jmp L_MERGE
L_MERGE:
    r = load dst+0 as T   # 消费者必须 load
```

若改成 `dst = <value>`（move），一个分支臂会消费掉输入值。

### 2.7 读不消费，写才 move

`store p+0, a as i32` 之后 `a` 仍然 Active，`!a` 合法。但
`d = call_indirect ...` 的返回值、`alloc` 的结果都是拥有权，必须 `!`/`^`。

### 2.8 `#loc "main.rs":L:C` 已被支持

`flattener/line_classifier.zig:339-366` 解析 `#loc` 并生成 DWARF
`!DILocation`。**Rust 源码映射是免费拿到的**，前端只要在每个函数入口和语句前
emit 一行即可。目前 `lower.zig` 尚未 emit，这是低成本高收益的补齐项。

---

## 2.9 后续实测新增的三条底层约束

这一节是后续几轮实测踩出来的，都属于「上层可以绕、但绕一次就错一类」的问题。

#### (1) 调用点的 capability 前缀必须与被调方契约逐字一致

被调方签名里的 `^` / `&` 与调用点的 `^` / `&` 由 Referee 强制比对，不一致直接
`CapabilityMismatch`（trap 1013）。

问题在于两端的信息量不同：被调方只有**声明类型**，调用点手里有**实参类型**。
只要两端各算各的，就会出现「被调方看到 `T` 没有布局 → 按借用传，调用点看到实参
是聚合体 → 按所有权 move」的分裂。

**结论**：这必须由前端保证，而不是让底层放宽。上层做法是定义唯一的
`ParamCap` 决策点，被调方签名与调用点都从**声明类型**取，不看实参。

#### (2) 活跃集合必须按「后进先出」释放

`tmp = ptr_add base, off` 派生出的寄存器是**借用** `base` 的。若先 `!base` 再
`!tmp`，Referee 报 `UseAfterMove`（trap 1009）。

**结论**：释放顺序是语义的一部分，不是实现细节。这条对任何带指针运算的
前端都成立，建议在底层文档里写明，或由底层提供 scope 对象自动处理。

#### (3) 函数出口要求「无残留活跃寄存器」

`@exit` 时若仍有活跃寄存器，报 `MemoryLeak`（trap 1012）。这意味着
`&T` 这类**借用参数在函数内也必须被 `!` 掉**——借用只免去跨函数的所有权转移，
不免去本函数的资源回收。

**结论**：与直觉相反，但规则统一；`MemoryLeak` 反而是个好的守门人。

---

## 三、sci/sa 底层需要补齐的能力（按 ROI 排序）

### ⭐⭐⭐⭐⭐ P0-1：`move` 与 `copy` 必须显式区分

**现状**：`dst = src` 语义是 move，但 SA 没有任何值拷贝指令。这让
「保留原值再赋值」这一在几乎所有语言里最常见的操作，无法直接表达，只能靠
`add x, 0` 这种算术恒等式绕过——既浪费指令，又对聚合类型无效。

**建议**：新增 `copy` 指令，或给 `=` 一个显式的 move 修饰：

```
b = copy a          # 值拷贝，a 仍然 Active
b = ^a              # 显式 move（现在 `^` 只能作语句前缀）
```

**收益**：Rust 的 `Copy` 语义、`self` 方法里改字段但保留整体、`mem::swap`、
所有「先算后用」的临时值模式。**这是当前限制前端代码量最大的单点。**

### ⭐⭐⭐⭐⭐ P0-2：结构化控制流 + 共享清理（epilogue）

**现状**（`sci/SA_LIMITATIONS.md` 第 2 条，已经被本次实现完整复现）：

* 每个基本块必须以 `jmp`/`br`/`return`/`panic` 结束；
* 每个出口必须手工 `!` 掉所有活跃寄存器；
* 分支越多，释放路径越多，出错概率二次增长。

`lower.zig` 为了正确处理这一点，需要 `snapshotLive` / `restoreLive` /
`releaseAllFrom` / `releaseReg` 四个辅助函数，加起来约 60 行只为「算清楚谁还活着」。

**建议**：在 `sci` 的 flattener 层引入两个零成本的**结构化宏**：

```
@fn f(a: i32) -> i32:
    ...
    defer !a            # 作用域出口自动释放（编译期展开成 `!a`）
```

或在宏层提供 `[SCOPE]` / `[END_SCOPE]` 块，由 flattener 在块尾自动插入活跃集合的
`!` 序列。**注意 `SA_LIMITATIONS.md` 第 14 条：现有 `[MACRO]` 展开会把行缩进，
而 label 必须在第 0 列，所以 label 生成必须由 flattener 完成而不是宏文本。**

**收益**：直接消掉 `Lua`/`Rust`/`Python` 所有前端 50%+ 的代码量。

### ⭐⭐⭐⭐⭐ P0-3：受控的临时值 / 作用域对象

**现状**：`stack_alloc` 不能显式释放（`StackEscape`），且在循环体内分配会
`PhiStateConflict`，必须提到循环外手写槽位。

**建议**：提供一个「作用域分配」指令或模式，让编译器可以自动做循环变量提升：

```
@fn f() -> i32:
    loop:
        i = <scope_alloc i64>       # 编译器决定放栈还是提循环外
        ...
```

**收益**：`for` 循环、递归数据结构、任何需要跨块存活但作用域明确的临时值。

### ⭐⭐⭐⭐ P4-1：`switch` / `br_table`

**现状**（`SA_LIMITATIONS.md` 第 1 条）：多路分派只能手写 `eq` + `br` 链。
Rust 的 `match` 在 tag 上有 N 个分支时，生成的指令数是 O(N)，且每个分支都要
重复 `!` 尾巴。

**建议**：`br_table tag_reg -> L_CASE_0, L_CASE_1, ..., L_DEFAULT`

**收益**：`match`、VM opcode 派发、解析器 token 分派。Rust 的 `match` 是
最常见的控制流之一，这个收益立竿见影。

### ⭐⭐⭐⭐ P4-2：phi 节点的显式表达

**现状**：phi 合流靠「同名寄存器 + Referee 线性扫描对账」隐式完成，因此前端
必须精确维护活跃集合，且分支臂要重置（见 2.4/2.5）。这是本次实现里最容易出错
的部分，`PhiStateConflict` 和「错误寄存器名」诊断都源于此
（`SA_LIMITATIONS.md` 第 7 条：`snapshotFirstMismatch` 用 slot index 而非
globalId 查名）。

**建议**：允许显式 phi 指令，或至少提供 `sa layout-merge` 之类的诊断增强。

### ⭐⭐⭐ P3-1：栈上的聚合体传参与返回

**现状**：签名里不能出现用户类型名，聚合体一律是 `ptr` + `alloc`/`load`/`store`。
这让 `struct` 按值传/返回必须走堆。

**建议**：`@f(s: { i32, i32 })` 或 `@f(s: ^stack.N)`，让小聚合体走栈而非堆。
**收益**：消除大量 `alloc`/`!`，指令数与内存流量显著下降。

### ⭐⭐⭐ P3-2：内建 `defer` / 作用域析构

**现状**：无自动 drop。Rust 的 `Drop` trait、`let _guard = Guard::new()` 这类
RAII 惯用法必须在前端展开成每个出口的显式 `!`（参考
`sa_plugin_sla/demos/rosetta/101_custom_drop`）。

**建议**：在 flattener 层做一次「按作用域重写」，把 `Drop` 调用插到所有出口。

### ⭐⭐ P2-1：多返回值

**现状**：只有 `-> T!`（状态码 + 单值）。Rust 的 `(T, E)`、`Result<(A,B), E>`
需要打包。

**建议**：`-> { i32, ptr }` 或 out-param 语法糖（`sa_std/fmt.sai` 已有
`&out_len: ptr` 的先例）。

### ⭐⭐ P2-2：泛型/单态化不属于底层

**评估结论**：单态化必须留在前端。`sci` 里没有任何 monomorphizer
（grep 确认只有文档提及），而且**不应该加**——单态化需要源语言类型信息，
SA-ASM 层拿不到。`sa_plugin_sla` 的 `monomorphizer.zig`（88 KB）是正确位置。

### ⭐⭐ P2-3：闭包 / 状态机原语

Rust 闭包 = env 结构体 + 顶层函数 + vtable 间接调用。SA 有
`@const ... = vtable { ... }` + `call_indirect`，够用，但**没有闭包构造糖**。
建议在前端做，不要下沉。

### ⭐⭐ P1-1：诊断质量

`PhiStateConflict` 报出的寄存器名与真正冲突的寄存器不匹配
（`SA_LIMITATIONS.md` 第 7 条）。本次调试中这个误导导致多次误判。
**建议**：修 `snapshotFirstMismatch`，用 globalId 而非 slot index 查名。

### P1-2：`#loc` 的前端约定 —— **已落地**

`#loc "file":L:C` 机制早已存在但无前端使用。现在 `sa_plugin_rust` 是第一个
使用者：每个 `@fn` 之前、每条语句之前各 emit 一行，`--no-loc` 可关闭。

需要前端配合的三件事，都已确认：

* `flattener.setPendingLoc` 对 `line == 0 || col == 0` 直接报 `InvalidLocHint`，
  所以**没记录到的位置必须跳过，不能 emit `0:0`**（`Lowerer.emitLoc` 如此处理）。
* `@fn` 之前的 `#loc` 会被读成该函数的 `upstream_loc`；
  `emit_llvm_llvmc.zig` 用 `fsig.upstream_loc.file` 当 DWARF 的
  `func_source_path`，用 `line`/`col` 造 `CDebugLoc`。
* 位置信息只能来自 parser。`ast.Node` 原本**完全没有行号**，所以给
  `FnItem` / `LetStmt` / `ExprStmt` / `ItemStmt` 加了 `pos: SrcPos`。
  parser 侧建一张「每行起始偏移」表并二分查找——原来 `lineCol` 是逐字节线性
  扫描，现在要每条语句调一次，线性扫描会让解析对文件长度变成 O(n²)，
  313 文件的语料回归立刻能感觉到。

> **已端到端证实**：`sa build-exe -g` 产物的 `.debug_line` 段里出现
> `locdemo.rs`，行号与 Rust 源码一致（1 / 9 / 10 / 12 / 13 全部对上）。
>
> 途中撞出并修掉一个真实缺陷：发散分支臂会把 `!` 释放语句 emit 在
> `panic` / `return` **之后**，形成终结指令之后的不可达指令。Referee 容忍，
> 但 LLVM emitter 不容忍，整个程序在 `-g` 下报 `InvalidOperand`——也就是说
> **任何带 panic 分支的 `if`，调试构建都是坏的**。修法：臂发散时只把活跃集合
> 恢复成合流点的形状（纯簿记，不发代码），不发 `!` 也不发 `jmp`。
> `tools/e2e.sh` 现在对每个 fixture 额外做一次 `-g` 构建并运行，把这条路径
> 永久纳入门禁。

---

## 四、不建议下沉到底层的（明确结论）

| 能力 | 原因 |
|---|---|
| 泛型单态化 | 需要源语言类型信息；`sci` 无 AST |
| 闭包构造 | 已有 vtable + `call_indirect`，够用 |
| 迭代器/集合 | 属于 `sa_std`，不属于 ISA |
| 生命周期/借用检查 | SA 的仿射模型是**子集**；Rust 的生命周期是**超集**。强行下沉会破坏 SA 的简单性（`sci/docs/faq.md` 已明确「没有 `'a` 标注」是设计选择）。**应该由前端做保守近似**——这也是 `sa_plugin_sla` 的策略。 |
| 异常/unwind | `panic(code)` + `-> T!` 已覆盖 90%；Rust 的 `?` 正好对应 `?` 指令 |

---

## 五、建议的实施顺序

1. **`copy` 指令**（P0-1）——单点收益最大，实现成本最低（flattener 一处 +
   Referee 一处 + emit 一处）。
2. **结构化 scope / 自动 epilogue**（P0-2）——直接决定所有前端的代码量上限。
3. **`br_table`**（P4-1）——`match` 的必需品。
4. **循环变量自动提升 + 作用域分配**（P0-3）——让 `for` 循环不再需要手写槽位。
5. **修 phi 诊断**（P1-1）——低成本，直接减少调试时间。
6. **确立 `#loc` 前端约定**（P1-2）——所有前端共享的收益。

前三项落地后，一个「普通 Rust 子集」的编译器前端可以稳定在
**每条语句 3–8 条 SA 指令**的水平，且不再需要手写活跃集合 bookkeeping。

---

## 六、复现方式

```bash
# 构建
cd sa_plugin_rust && zig build            # -> zig-out/lib/librust.so, zig-out/bin/rust

# 单元测试
zig build test                            # 121/121

# 端到端：每个 fixture 编译成真正的可执行文件并 diff 真实 stdout
./tools/e2e.sh                           # 10/10（每个 fixture 还跑一次 -g 调试构建）

# 独立 CLI
export PATH=$PWD/zig-out/bin:$PATH SCI_ROOT=../sci
rust check  main.rs
rust build main.rs
rust build-exe main.rs -o main && ./main

# 通过真实 host
SA_PLUGIN_DEV=1 sa plugin install --dev ./sa_plugin_rust
SA_PLUGIN_DEV=1 sa rust build-exe main.rs -o main && ./main

# 解析器覆盖率（313 个真实 Rust 文件）
./tools/corpus_check.sh ../sa_plugin_sla/demos/rosetta
#   等价于: zig-out/bin/rust check --corpus <dir>

# 未支持构造现在会显式告警，并可用 --deny-unsupported 变成失败
rust build main.rs --deny-unsupported
```

**继续追 `boundary_numbers` 又查出两个**：

1. **`match n { }`（不可居住的 match）会读未初始化内存。** 零个臂的链在
   `panic(106)` 之后仍然落到 `L_MERGE`，而那里 `load` 的是一个永远不会被写入的
   结果块。现在零臂在**分配结果块之前**就被识别：直接发 `panic`，不发合流标签；
   值位置则报 `error.Unsupported`（不可居住的类型没有值可给）。
2. **`1e400` 被静默接受。** 浮点字面量原来直接把原文发出去，Rust 在编译期
   就会拒绝超出 `f64` 范围的值。现在先 `parseFloat` 校验，`isInf` 就
   `note` + 占位，不再把一个无穷大悄悄塞进程序。

3. **浮点字面量的打印与 Rust 不一致。** `sa_fmt_f64` 是**固定精度**格式化器：
   `sa_fmt_f64(0.5, 0)` 打成 `1`，`sa_fmt_f64(0.5, 2)` 打成 `0.50`，
   而 Rust 的 `{}` 是最短往返表示。字面量的精确文本在前端是已知的，
   所以 `rustFloatText` 直接从源码算出 Rust 的 `Display` 并原样输出
   （`1.0` → `1`，`2.50` → `2.5`，`100.25` → `100.25`，与 Rust 逐字相同）。
   指数形式（`1e3`）不做展开——那需要另一个解析器——仍走格式化器并明确 note。

`null_empty_omitted` 与 `boundary_numbers` 三轮筛查累计修掉 10 个真实缺陷
（详见 1.5 与 1.6、1.7 节），全部有对应的回归测试。两个维度的评分变化：
`null_empty_omitted` 0.55 → 0.19（不再进入次弱），`boundary_numbers`
0.78 → 0.59。

### 1.8 一致性审计发现并补上的三个缺失测试

`jev_consistency` 判 `regression_lock` 为 **violated**：我声称「13 个缺陷每个都有
一条回归测试」，实际有三个没有。补上之后逐个做了**反向验证**——把修复改回去，
确认对应测试确实失败，而不是恒过的空测试：

| 改回的修复 | 失败的测试 |
|---|---|
| `stringConst` 不再 `dupe` key | `a repeated format string does not abort the compilation`（expected 1, found 3：同一段文本被重复 intern 成三条 `@const`） |
| 语句位置改回在 `parseExpr` 之后取 | 3 个测试失败，其中 `a statement that spans lines is attributed to its first line` 是新增的那条 |
| `restoreLive` 不带结果块 | `a value-position match releases its result block exactly once`（expected 1, found 0） |

三次改回各自只让对应测试失败，恢复后 121/121 全绿。
