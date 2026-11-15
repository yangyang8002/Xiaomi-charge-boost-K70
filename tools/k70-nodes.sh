#!/system/bin/sh
# 红米 K70（及任意小米/红米机型）充电相关 sysfs 节点清单 · 只读
#
# 用途：模块里三个「免重启」功能依赖小米 MCA 充电框架的节点：
#   解除温控降速   -> charger_thermal/wired_thermal_remove
#   实时充电电流   -> charger_thermal/wired_chg_curr
#   快充断流秒恢复 -> 内核模块 mca_strategy_quickchg
# 如果 WebUI 显示「本机不支持」，就跑这个脚本，把输出发给作者，就能确定：
#   1) 节点根本不存在（硬件/固件不支持，做不了）
#   2) 节点存在但在别的路径 / 别的名字（可以补适配）
#   3) 节点存在但单位/格式不同（能补，但要改写入逻辑）
#
# 安全：全程只 cat / ls / find / dmesg / getprop 读取。
# 不写任何 /sys、/proc、块设备，不动 /data，只在最后可选写一份 txt 到 /sdcard。
#
# 用法：
#   su -c 'sh /sdcard/Download/k70-nodes.sh'
#   su -c 'sh /sdcard/Download/k70-nodes.sh /sdcard/Download/k70-nodes.txt'
#
# 输出同时打印到屏幕，便于直接截图。

OUT=${1:-}
# 便于在 PC 上验脚本：MCB_SYSROOT 指向一个假根目录（里面有 sys/…）时可以离线跑
SR=${MCB_SYSROOT:-}

say(){ printf '%s\n' "$*"; }
hr(){ say "------------------------------------------------------------"; }
sec(){ say ""; say "===== $* ====="; }

# 读节点：$1=路径
rd(){ [ -f "$1" ] && cat "$1" 2>/dev/null | head -c 200 | tr -d '\n'; }

# 找节点：$1=文件名，在若干根目录下按名字精确查找，输出第一个命中
# 只认文件名完全相等，避免误命中同前缀的其它节点
findn(){ n=$1
  for d in "$SR/sys/class/xm_power/charger/charger_thermal" \
           "$SR/sys/class/xm_power/charger/charge_interface" \
           "$SR/sys/class/xm_power/charger/charger_common" \
           "$SR/sys/class/qcom-battery" \
           "$SR/sys/class/power_supply/battery"; do
    [ -f "$d/$n" ] && { say "$d/$n"; return 0; }
  done
  for r in "$SR/sys/class/xm_power" "$SR/sys/class/qcom-battery" "$SR/sys/class/power_supply" "$SR/sys/devices"; do
    [ -d "$r" ] || continue
    f=$(find -L "$r" -maxdepth 6 -name "$n" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && { say "$f"; return 0; }
  done
  return 1
}

say "================ 充电节点清单（只读） ================"
say "生成时间: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"

sec "1. 机型与系统"
for k in ro.product.vendor.device ro.product.device ro.product.vendor.marketname \
         ro.product.model ro.soc.model ro.soc.manufacturer ro.board.platform \
         ro.hardware ro.build.version.release ro.build.version.incremental \
         ro.mi.os.version.incremental ro.vendor.build.version.incremental \
         ro.miui.ui.version.code; do
  v=$(getprop $k 2>/dev/null); [ -n "$v" ] && say "  $k = $v"
done
say "  uname -r = $(uname -r 2>/dev/null)"
say "  SELinux  = $(getenforce 2>/dev/null)"
say "  slot     = $(getprop ro.boot.slot_suffix 2>/dev/null)"

sec "2. 关键目录是否存在"
for d in /sys/class/xm_power /sys/class/qcom-battery \
         /sys/class/xm_power/charger /sys/class/xm_power/charger/charger_thermal \
         /sys/class/xm_power/charger/charge_interface \
         /sys/class/xm_power/charger/charger_common \
         /sys/class/xm_power/fuelgauge /sys/class/power_supply/battery; do
  if [ -d "$SR$d" ]; then say "  [有] $d"
  elif [ -L "$SR$d" ]; then say "  [符号链接] $d -> $(readlink "$SR$d" 2>/dev/null)"
  else say "  [无] $d"; fi
done

sec "3. 三个功能各自需要的节点"
chk(){ # $1=说明 $2=节点名
  p=$(findn "$2")
  if [ -n "$p" ]; then say "  [找到] $2  ->  $p"
    say "         值 = $(rd "$p")"
    say "         权限 = $(ls -l "$SR$p" 2>/dev/null | awk '{print $1, $3, $4}')"
  else say "  [缺失] $2   ($1)"; fi
}
chk "解除温控降速"     wired_thermal_remove
chk "实时充电电流"     wired_chg_curr
chk "断充（暂停输入）" input_suspend
chk "温控限流上限"     wired_ctrl_limit
chk "充电使能"         charge_enable
chk "充电电流上限"     ichg_limit
chk "输入电流上限"     iin_limit
chk "快充类型"         quick_charge_type
chk "实际充电器类型"   real_type
chk "系统标称功率"     power_max
chk "小米适配认证"     pd_verified

sec "4. MCA 内核模块（快充断流秒恢复依赖 mca_strategy_quickchg）"
if [ -d "$SR/sys/module" ]; then
  m=$(ls "$SR/sys/module" 2>/dev/null | grep -iE 'mca|charge|charger|chg|ffc|smart_chg|mi_' | sort | tr '\n' ' ')
  say "  相关模块: ${m:-（无）}"
  for x in mca_strategy_quickchg mca_strategy_quick_charge mca_quick_charge mi_charger mca_charger; do
    [ -d "$SR/sys/module/$x" ] && say "  [有] /sys/module/$x"
  done
  [ -d "$SR/sys/module/mca_strategy_quickchg" ] || say "  [无] /sys/module/mca_strategy_quickchg"
else say "  [无] /sys/module"; fi

sec "5. /sys/class/xm_power 目录树（深度 4）"
if [ -d "$SR/sys/class/xm_power" ]; then
  # 只列到 4 层，避免刷屏；文件只显示名字
  ( cd "$SR/sys/class/xm_power" 2>/dev/null && find -L . -maxdepth 4 2>/dev/null | sed 's#^\./##' | sort | head -200 )
  n=$(cd "$SR/sys/class/xm_power" 2>/dev/null && find -L . -maxdepth 4 2>/dev/null | wc -l)
  say "  （共 $n 项，上面最多列 200 项）"
else
  say "  /sys/class/xm_power 不存在 —— 这基本可以解释三个功能为什么都不可用"
fi

sec "6. 所有 power_supply 设备"
for p in "$SR"/sys/class/power_supply/*; do
  [ -d "$p" ] || continue
  say "  $(basename "$p")  type=$(rd "$p/type")  online=$(rd "$p/online")"
done

sec "6b. /sys/class/qcom-battery 全部节点"
# 已知线索：公版 PPS 在 K70 上能读到 pd_verifed，说明走的是 qcom-battery 这套布局
if [ -d "$SR/sys/class/qcom-battery" ]; then
  say "  目录存在。下面是全部条目（文件名 + 前 200 字符内容）："
  for f in "$SR"/sys/class/qcom-battery/*; do
    [ -e "$f" ] || continue
    [ -f "$f" ] || { say "    [目录] $(basename "$f")"; continue; }
    say "    $(basename "$f") = $(rd "$f")"
  done
else
  say "  /sys/class/qcom-battery 不存在"
fi

sec "6c. 其它充电相关 class 目录"
for d in "$SR"/sys/class/Charging_Adapter "$SR"/sys/class/power_supply/bms "$SR"/sys/class/mi_charger "$SR"/sys/class/smartchg "$SR"/sys/class/qti_charger; do
  if [ -d "$d" ]; then
    say "  [有] $d"
    for f in "$d"/*; do [ -f "$f" ] && say "        $(basename "$f") = $(rd "$f")"; done | head -40
  else say "  [无] $d"; fi
done

sec "7. 全盘按名字搜索（/sys/class 与 /sys/devices）"
# 除了模块当前用的名字，再搜一批「同类功能可能的别名」：找不到原名的机器上也许是这些
for n in wired_thermal_remove wired_chg_curr wired_ctrl_limit \
         thermal_remove chg_curr ctrl_limit restrict_chg_curr \
         restrict_cur thermal_mitigation chg_thermal_limit \
         charge_current_limit charging_current_max; do
  h=$(find -L "$SR/sys/class" "$SR/sys/devices" -maxdepth 8 -name "$n" 2>/dev/null | head -5)
  if [ -n "$h" ]; then say "  [$n]"; say "$h" | sed 's/^/    /'
  else say "  [$n] 无"; fi
done

sec "8. 内核日志里的充电框架线索"
if command -v dmesg >/dev/null 2>&1; then
  d=$(dmesg 2>/dev/null | grep -iE 'mca|quick_charge|charger_thermal|wired_chg|ffc' | tail -25)
  if [ -n "$d" ]; then say "$d" | sed 's/^/  /'
  else say "  （dmesg 里没有 mca / quick_charge / charger_thermal 相关行）"; fi
else say "  dmesg 不可用"; fi

sec "9. 结论"
A=$(findn wired_thermal_remove); B=$(findn wired_chg_curr)
if [ -d "$SR/sys/module/mca_strategy_quickchg" ]; then Q="可用"; else Q="不可用"; fi
[ -n "$A" ] && say "  解除温控降速  : 节点存在，可用" || say "  解除温控降速  : 节点缺失，不可用"
[ -n "$B" ] && say "  实时充电电流  : 节点存在，可用" || say "  实时充电电流  : 节点缺失，不可用"
say "  快充断流秒恢复: $Q（依赖原厂 MCA 快充内核模块）"
say ""
# 判断本机是哪套充电框架布局
LAYOUT="未知"
if [ -d "$SR/sys/class/xm_power" ]; then LAYOUT="xm_power（小米 MCA 布局）"
elif [ -d "$SR/sys/class/qcom-battery" ]; then LAYOUT="qcom-battery（高通/QTI 布局）"
elif [ -d "$SR/sys/class/power_supply/battery" ]; then LAYOUT="power_supply（通用布局）"
fi
say "  本机充电框架布局: $LAYOUT"
say ""
if [ -z "$A" ] && [ -z "$B" ] && [ ! -d "$SR/sys/module/mca_strategy_quickchg" ]; then
  if [ -d "$SR/sys/class/qcom-battery" ] && [ ! -d "$SR/sys/class/xm_power" ]; then
    say "  这台机器用的是 qcom-battery 布局，没有小米 MCA 的 xm_power 节点树。"
    say "  三个「免重启」功能是直接写 MCA 节点实现的，所以在本机用不了；"
    say "  但 PPS / 充电记录 / dtbo 充电参数这些走 qcom-battery 的功能不受影响"
    say "  （截图里 pd_verifed 能读到 1 就是这个原因）。"
  else
    say "  这台机器上找不到小米 MCA 充电框架的这套节点。"
    say "  三个「免重启」功能绑定 MCA 框架实现，因此无法在本机使用；"
    say "  其余功能（充电记录、WebUI、公版 PPS、低电量延迟关机、dtbo 充电参数）不受影响。"
  fi
  say ""
  say "  如果第 7 节搜到了同义的别名节点，说明可以补适配，请把本报告发给作者。"
else
  say "  有节点可用。请把本报告整份发给作者，按报告里的实际路径/名字补适配。"
fi
hr
say "本脚本只读：没有向任何分区或 /sys 写入过内容。"

if [ -n "$OUT" ]; then
  # 重新跑一遍写到文件（保持屏幕输出与文件内容一致）
  if sh "$0" > "$OUT" 2>&1; then say "已保存：$OUT"; else say "! 写 $OUT 失败"; fi
fi
