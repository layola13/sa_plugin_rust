在 Windows PowerShell 环境中处理包含中文的文件时，必须显式使用 UTF-8 编码。

Rust 插件以 dev 模式运行：每次调用 `sa rust` 子命令前必须设置 `SA_PLUGIN_DEV=1` 环境变量（例：`SA_PLUGIN_DEV=1 sa rust help`），否则会调用到系统已安装的正式版本而非仓库的 dev 版本。安装/更新插件用：`SA_PLUGIN_DEV=1 sa plugin install --dev .`。

## 管线

```
main.rs
  -> src/lexer.zig        Rust token 流
  -> src/parser.zig       Rust AST
  -> src/monomorph.zig    泛型静态分发（函数 / 结构体 / 枚举）-> 具体实例
  -> src/lower.zig        AST -> SA-ASM 文本 (.sa) + 布局字典 (.sal)
  -> sci_bridge           sci 的 flattener / verifier / sab 编码器
```

`build` 走纯进程内 `rust -> .sa`；`build-exe` / `test` / `run` 在拿到 `.sab` 后 spawn 外部 `sa` 二进制（`host_paths.resolveSaExecutable`）。

## 静默降级原则

`unsupported` 计数**不会**被吞掉。降级点一律走 `Lowerer.note(reason)`，
原因会经 `Result.unsupported_notes` 传到 CLI，由 `reportUnsupported` 打到 stderr。
任何未支持的构造都会产出占位值（通常是 `0`），所以「能编译」不等于「正确」；
`--deny-unsupported` 可把降级直接变成构建失败，供 CI 把关。

## 调试环境变量

- `RUST_PROFILE=1` 打开分阶段计时
- `RUST_KEEP_SA=1` 保留中间 `.sa`
- `RUST_DUMP_AST=1` 打印 AST
- `SA_PLUGIN_DEV=1` 使用仓库 dev 插件
