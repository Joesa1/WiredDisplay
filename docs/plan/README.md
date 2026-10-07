# 交付计划

状态：文档整理 sprint 正在验收。

本目录记录可交付工作，而不是产品说明。设计合同在 `docs/architecture/`、`docs/ui/` 和 `docs/operations/`；每个任务必须引用这些文档，避免把需求复制进任务文件后产生两套事实。

```text
analysis -> task ready -> develop -> verify -> merge -> mark done
                              ^          |
                              └-- fix ---┘ (blocking finding)
```

| 区域 | 用途 |
| --- | --- |
| `analysis/` | 模块分解、真实集成路径和已知差距。 |
| `tasks/` | 有边界、可验证的交付任务。 |
| `reviews/` | 代理独立审阅的临时记录；通过并合并后删除。 |
| `backlog.md` | 已知但尚未排期的工作，不能被视为已实现。 |

任务状态：`pending` -> `ready` -> `in-progress` -> `done`；遇到设计或依赖无法满足时标记 `blocked`。一个代码任务完成前必须通过独立审阅，且审阅要核对代码与其 `context` 文档的一致性。
