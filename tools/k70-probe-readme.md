# k70-probe.sh 使用说明

给**红米 K70（vermeer，SM8550 骁龙 8 Gen 2）**做一个「原厂充电参数模板」用的采集脚本。
模块里其它机型（小米15 / K80 Pro / K90 …）都有现成的 `<代号>_os*.tpl` 和 `<代号>.avb`，K70 还没有，
这个脚本负责把做模板需要的原始材料从手机里读出来。

**全程只读**：脚本只对 dtbo 分区做 `dd if=` 读取，只往 `/sdcard`（或你指定的目录）写文件。
不会 `dd of=` 写块设备，不会 `blockdev --setrw`，不 remount，不重启，不改任何分区内容。

---

## 1. 前置条件

- 手机已 root（Magisk / KernelSU 都行），`su` 能拿到 root shell
- 系统自带的 `sh` / `toybox`（`dd`、`od`、`awk`、`sha256sum`）就够，**不需要 python、不需要 jq**
- 有 `/sdcard` 写权限（默认输出目录，可改成 `/data/local/tmp/...`）

## 2. 怎么跑

```sh
# 把脚本放到手机里（放到 /sdcard/Download 就行），然后：
su -c 'sh /sdcard/Download/k70-probe.sh'

# 想换输出目录：
su -c 'sh /sdcard/Download/k70-probe.sh /sdcard/Download/k70-my'

# 临时目录不想落到 /dev 的话也可以先 export TMPDIR，但一般不用管
```

跑完屏幕上会打印完整报告（和 `report.txt` 内容完全一样），最后一行是 `=== 完成 ===`。
整个过程大概几秒到十几秒（看分区大小）。

## 3. 它做了什么

1. 读取机型属性（`ro.product.*`、`ro.soc.*`、`ro.mi.os.version.incremental`、`uname -r`、`getenforce` 等）
2. 找 dtbo 分区：`/dev/block/by-name/dtbo$slot` → `/dev/block/bootdevice/by-name/dtbo$slot` → `platform/*/by-name/dtbo*`
3. 用 `blockdev --getsize64` / `wc -c` 取分区大小，检查是否 > 1 MiB、是否是正常的分区大小
4. `dd if=` 读出**整个分区**，先后读两遍算 sha256 比对，确认 dump 没读坏
5. 解析 DT table 头（`d7b7ab1e` + `total_size`）和每个 FDT entry，列出关注节点下的全部属性：
   `mca_strategy_quick_charge`、`mca_quick_charge_batt_para_gbl`、`mca_buckchg_jeita*`、`mca_charger_thermal`、
   `strategy-fg`、`strategy_quick_charge_override`、`mca_qcom_subpmic_proxy`、`mca_protocol_pd_class`、
   `mca_strategy_buckchg_class`、`sc8585_master@6e`
   每行给出原厂字节的十六进制 + 32 位大端（`be=`，`.tpl` 的 `w` 列用这个）+ 小端（`le=`）解码
6. 解析 AVB 尾部：footer 版本 / `original_image_size` / `vbmeta_offset` / `vbmeta_size` / vbmeta 的 `AVB0`、
   有没有认证块（签名）、哈希描述符里的分区名 / salt / digest
7. 写出下面这些产物

## 4. 会产出什么

| 文件 | 说明 |
| --- | --- |
| `report.txt` | 完整报告（与屏幕输出相同），**必须发回来** |
| `dtbo.img` | 整个 dtbo 分区镜像（原样，未改动） |
| `vermeer.avb` | 712 字节 AVB 模板，可放进 `module/dtbo/<SOC>/`；找不到 AVB 尾部时不会生成 |
| `stock-dtbo.info` | 一行，格式与 `module/dtbo/stock.list` 一致：`<sha256> <代号> <模板名> <原厂系统版本>`（模板名列先写 `-`，等模板做好再改） |

`vermeer.avb` 的布局（与仓库现有 15 个 `<代号>.avb` 一致，共 712 字节）：

```
[0..7]     dtbo 分区大小（大端 u64，例如 8 MiB = 00 00 00 00 00 80 00 00）
[8..71]    AVB footer（64 字节，字段全大端）
[72..711]  footer 里 vbmeta_size 指定的 vbmeta 块
```

> 注意：这 8 字节不是「footer 前面那 8 个原始字节」，而是分区大小。仓库里 `miro.avb` 等模板的这 8 字节分别是
> `0x800000` / `0x1200000` / `0x1600000`（8 / 18 / 22 MiB），正好是各机型的 dtbo 分区大小；
> `dtbopatch.bin` 里也有 `INFO footer at %d (device partition %d)`、`partition smaller than template`、
> `patched image too large for partition` 这些提示，说明它把这 8 字节当分区大小用。

## 5. 要发回来什么

把整个输出目录里的 **`report.txt`** 发回来（最重要），再带上：

- `stock-dtbo.info`（作者要往 `stock.list` 里加这一行）
- `vermeer.avb`（如果生成了）
- `dtbo.img`（几十 MB，方便作者在 PC 上直接跑 `tools/ftd-parse.py` 生成 `.tpl`；不想发大文件就只发前三个，
  作者会照 `report.txt` 里的属性自己拼模板）

作者拿到后会在 PC 上：

```sh
python tools/ftd-parse.py dtbo.img --emit-tpl vermeer_os?.tpl --emit-avb vermeer.avb
```

人工把该用占位符（`{I}` `{V}` `{T}` `{L}` 等）的数字换掉，放进 `module/dtbo/8550/`，再补一行 `stock.list`。

## 6. 返回码

| 码 | 含义 |
| --- | --- |
| `0` | 全部成功 |
| `1` | 失败（找不到分区 / 没有读权限 / dd 校验不过 / 非小米设备 …），`!` 开头的那行会写原因 |
| `2` | 有产物，但有需要人工确认的地方（例如这台机器的 dtbo 没有 AVB 尾部、机型代号不是 vermeer 等） |

## 7. 常见问题

- **`! 这台机器没有小米/红米系统属性`**：不是小米/红米机型。脚本只打印属性就退出，没有读过任何分区。
- **`! 找不到 dtbo 分区`**：分区名不在这台机器上，把 `report.txt` 发回来让作者加路径。
- **`! 没有找到 AVB footer`**：移植包 / 官改包的 dtbo 常常把 AVB 尾部删掉了。这时 `dtbo.img` 和
  `stock-dtbo.info` 照样有用，但 `vermeer.avb` 得从**原厂卡刷包**里的 `dtbo.img` 提取（原厂镜像才有 AVB）。
- **`! 没找到关注节点`**（在报告里）：这台机器的节点名跟预期不同，照样把 `report.txt` 发回来。
- **`! 无法创建输出目录` / `写不了 …`**：SD 卡写不进去，换成 `su -c 'sh … /data/local/tmp/k70-probe'`。
- 脚本只用 `dd if=` 读分区。如果你自己改脚本往里加写入操作，后果自负——原版不会写任何分区。
