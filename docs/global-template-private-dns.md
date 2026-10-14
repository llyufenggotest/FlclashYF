# 全局模板：订阅私有 DNS / hosts 保留契约

## 优先级与范围

仅 `useGlobalTemplate=true` 的 YAML 走私有解析数据合并。关闭时完整 YAML 原文返回；URI/base64、Fastup 与关闭时 node-only 的既有模板流程不变。

- 全局模板拥有通用设置：IPv6、DNS enable/enhanced-mode/fake-ip-range/listen、全局路由、监听器等不从订阅全文覆盖。
- `hosts`、`nameserver-policy`、`proxy-server-nameserver-policy` 按键合并，订阅同键优先；字符串、列表、IPv4/IPv6、别名和中文逗号不拆分、不规范化。
- 解析器列表（nameserver/default/proxy-server/direct/fallback）、fake-ip-filter：订阅条目在前，模板缺失项随后补齐；字符串 policy 值保持字符串，列表保持列表。
- `use-hosts`、`use-system-hosts`、`respect-rules`、`direct-nameserver-follow-policy` 仅当订阅显式存在才继承，包括 false。它们决定私有解析数据的消费方式，不等于订阅接管全部 DNS 设置。
- fallback-filter 仅合并 domain/ipcidr 解析约束；geoip/geoip-code 等仍由模板控制。私有 hosts/具体 policy 域名添加 blacklist fake-ip 排除；whitelist/rule 模式遇到私有解析数据时明确拒绝，要求用户调整模板，避免反转语义。
- 不批量搬运 source rules。只保留与私有 hosts/具体 policy 域名精确对应的 DOMAIN/DOMAIN-SUFFIX 规则。DNS `rule-set:` 引用仅复制所需 rule-provider；resolver `#proxy` / overlay DNS 仅闭包保留其依赖的节点组。冲突、丢失引用、循环、无法安全恢复的 provider 组拒绝生成，不输出原始 URL、域名、token 或节点名。
- 用户之后的显式 UI DNS 覆写仍覆盖可编辑 DNS 字段；未被模型覆盖的键保留。自动启用未启用 DNS 只是补默认值，不清空订阅私有 policy。最终 `makeRealProfileTask` 再校验 DNS 依赖，脚本删节点不能静默生成损坏配置。

## 来源所有权

新模板导入/刷新保留当前 profile 的版本化 `<id>.template-source-v1.yaml` 来源快照（可能包含秘密，按 profile 同等敏感管理）；关闭模板保存不额外保留。重模板从快照生成，不再把旧模板 DNS 当新来源累加。刷新直接替换快照，A/B profile 不共享来源，不写全局模板文件。删除/孤儿清理/备份恢复跟随所属 profile。无需数据库 schema 变更。

已有仅保存 materialized YAML 的历史配置无法还原丢失的原始订阅：第一次重模板保守地以当前文档建立快照；历史污染需重新下载/导入原始订阅清除。手动编辑 materialized 文件不回写来源快照；希望重模板保留的来源改动需重新导入。

## 验证边界

仓库 tests 仅合成 fixture；实际用户 YAML 仅在外部 evidence 运行，输出 schema/count/type/preservation bool。普通 Flutter 测试覆盖 production apply、provider file/clipboard/URL/QR、URL update、重模板、显式覆写与 isolate `makeRealProfileTask`。外部 Go probe 使用固定 core gitlink 的 `config.UnmarshalRawConfig`（真实 getProfileConfig JSON 边界）及 `config.ParseRawConfig`。

离线实际 runtime parse 不拉取 template rule-provider / geodata：保留全量真实 proxies/groups/DNS/hosts，仅 runtime probe 将 rules 改为 MATCH,DIRECT、移除 rule-providers、禁用 fallback-filter geoip。完整未改写模板的 provider prepare / RawConfig / makeRealProfileTask 另外检查保留。该检查不是网络拨号、DNS 实际请求、订阅刷新远端或真机验收，也不改变 Snell suffix 严格边界。
