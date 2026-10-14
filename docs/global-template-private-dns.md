# 全局模板：订阅私有 DNS / hosts 保留契约

## 优先级与范围

仅 `useGlobalTemplate=true` 的 YAML 走私有解析数据合并。关闭时完整 YAML 原文返回；URI/base64、Fastup 与关闭时 node-only 的既有模板流程不变。

- 全局模板拥有通用设置：IPv6、DNS enhanced-mode/fake-ip-range/listen、全局路由、监听器等；源显式 DNS enable（包括 false）保留。
- `hosts`、`nameserver-policy`、`proxy-server-nameserver-policy` 按精确键合并，源同键完整覆盖，不 union 同域 resolver，不规范化字面值。
- 非空源 nameserver/default/proxy-server/direct/fallback pool 完整替换相应模板 pool；源未声明或空列表才补模板默认。nameserver 为并行主池，fallback 为过滤控制备用池，default 用于 DNS 主机 bootstrap，proxy-server 用于代理端点，direct 用于直连。不是列表排序优先，不全域添加 DIRECT/DNSproxy。blacklist fake-ip-filter 可去重合并。
- 源显式 use-hosts/use-system-hosts/respect-rules/direct-nameserver-follow-policy（包括 false）保留；hosts 路由依赖只在有效 use-hosts=true 时闭包，缺失遵循模板/Core 默认。
- fallback-filter 每个源显式字段覆盖、模板只补未声明字段，包括 geoip/geoip-code/domain/ipcidr。仅实际开启 fake-ip 时检查 whitelist/rule 反转；redir-host 不拒不生效 filter mode、不添加 blacklist 条目。
- rule-set/group 引用精准闭包，冲突/循环/缺依赖 value-free 拒绝。resolver fragment 百分号解码后 split &，最后无等号 token（包括清空 selector 的尾空 token）与 Core 一致，proxy/socks/doh 选项不当 selector，原 URL 不改。普通 profile/显式覆写也接受合法 Group%20One。
- 用户显式 DNS 覆写仍覆盖编辑字段。自动默认补齐保留原 enable=false 与私有 policy；最终任务检查依赖，脚本删节点不静默损坏。

### 配对提交边界

保存/删除/重模板读快照/备份/恢复统一 profile 路径队列及 OS 文件锁。最小 undo journal 保留既有两个 YAML 与 zip 兼容；旧 pair flush 完成后发布，失败回滚，未提交 journal 下次合作读取恢复。commit marker 先写临时文件再 rename；已完成 journal 整目录退休后清理避免递归删除中断误回滚。老 archive 缺 source 明确清目标旧 source，新 archive 成对恢复。

这是 journal + commitpoint，**不是 atomic two-files**。未合作加锁的原生/外部直接文件读取仍可能看到发布窗口；不承诺目录 fsync/断电持久性；回滚失败保留 journal 并失败。

## 来源所有权

新模板导入/刷新保留当前 profile 的版本化 `<id>.template-source-v1.yaml` 来源快照（可能包含秘密，按 profile 同等敏感管理）；关闭模板保存不额外保留。重模板从快照生成，不再把旧模板 DNS 当新来源累加。刷新直接替换快照，A/B profile 不共享来源，不写全局模板文件。删除/孤儿清理/备份恢复跟随所属 profile。无需数据库 schema 变更。

已有仅保存 materialized YAML 的历史配置无法还原丢失的原始订阅：第一次重模板保守地以当前文档建立快照；历史污染需重新下载/导入原始订阅清除。手动编辑 materialized 文件不回写来源快照；希望重模板保留的来源改动需重新导入。

## 验证边界

仓库 tests 仅合成 fixture；实际用户 YAML 仅在外部 evidence 运行，输出 schema/count/type/preservation bool。普通 Flutter 测试覆盖 production apply、provider file/clipboard/URL/QR、URL update、重模板、显式覆写与 isolate `makeRealProfileTask`。外部 Go probe 使用固定 core gitlink 的 `config.UnmarshalRawConfig`（真实 getProfileConfig JSON 边界）及 `config.ParseRawConfig`。

离线实际 runtime parse 不拉取 template rule-provider / geodata：保留全量真实 proxies/groups/DNS/hosts，仅 runtime probe 将 rules 改为 MATCH,DIRECT、移除 rule-providers、禁用 fallback-filter geoip。完整未改写模板的 provider prepare / RawConfig / makeRealProfileTask 另外检查保留。该检查不是网络拨号、DNS 实际请求、订阅刷新远端或真机验收，也不改变 Snell suffix 严格边界。
