# k70-nodes.sh 使用说明

用来查清**为什么充电配置页里有功能显示「本机不支持」**。

模块里有三个「免重启」功能，它们不是改 dtbo，而是直接往小米 **MCA 充电框架**的 sysfs 节点里写值：

| 功能 | 需要的节点 / 模块 |
| --- | --- |
| 解除温控降速 | `/sys/class/xm_power/charger/charger_thermal/wired_thermal_remove` |
| 实时充电电流 | `/sys/class/xm_power/charger/charger_thermal/wired_chg_curr` |
| 快充断流秒恢复 | 内核模块 `/sys/module/mca_strategy_quickchg` |

红米 K70（vermeer，SM8550）上如果看不到 `/sys/class/xm_power`，这三个功能就用不了 —— 脚本就是用来确认这一点，顺便看看有没有名字/路径不同的等价节点。

**全程只读**：只 `cat` / `ls` / `find` / `dmesg` / `getprop`，不写 `/sys`、不写 `/proc`、不碰任何分区，可选只在最后往 `/sdcard` 写一份 txt。

---

## 怎么跑

```sh
# 1. 把脚本丢到手机（放 /sdcard/Download 就行）
# 2. 执行
su -c 'sh /sdcard/Download/k70-nodes.sh'

# 顺便存一份文本方便发出来：
su -c 'sh /sdcard/Download/k70-nodes.sh /sdcard/Download/k70-nodes.txt'
```

几秒钟出结果。屏幕输出就是报告内容，可以直接截图。

## 报告里看什么

重点看这几节：

| 节 | 说明 |
| --- | --- |
| 2. 关键目录是否存在 | **最关键**。`/sys/class/xm_power` 有还是没有 |
| 3. 三个功能各自需要的节点 | 逐个 `[找到]` / `[缺失]` |
| 4. MCA 内核模块 | 有没有 `mca_strategy_quickchg` |
| 6b. `/sys/class/qcom-battery` 全部节点 | 已知 K70 上 PPS 能读到 `pd_verifed`，说明这套布局在 |
| 7. 全盘按名字搜索 | 找同类功能的**别名**节点（如 `restrict_chg_curr`、`thermal_mitigation`） |
| 9. 结论 | 直接给结论 + 判断本机是 `xm_power` 还是 `qcom-battery` 布局 |

## 三种可能的结果

1. **`xm_power` 不存在、`qcom-battery` 存在** → 本机是高通/QTI 布局，没有 MCA 节点树。三个免重启功能绑定 MCA 实现，**本机做不了**；PPS、充电记录、dtbo 参数不受影响。
2. **第 7 节搜到别名节点** → 功能可以做，只是节点名/路径不同。把报告发出来即可补适配。
3. **`xm_power` 存在但缺个别节点** → 部分功能可用，按报告补齐。

## 常见问题

- **`! 找不到 dtbo 分区`**：这个脚本不读 dtbo，报这个说明你跑错脚本了（那是 `k70-probe.sh`）。
- **`dmesg` 没内容**：部分内核限制了非 root 读 dmesg；用 `su -c` 跑就有。
- **第 7 节很慢**：`find` 扫 `/sys/devices` 会花几秒，正常。
