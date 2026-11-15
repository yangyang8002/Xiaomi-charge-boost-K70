#!/system/bin/sh
# 已适配机型表（v8.4.9 起多机型）：代号 → 参数
# MN 机型名  MI 原厂快充电流(mA)  MX 模块允许的电流上限  SC 单电荷泵分支上限(div_single_curr)
# VQ 满电 FFC 截止电压(mV，模块不改，只用于重构表/显示)  V0 原厂关机电压  PW0 原厂私有协议功率  PWO 可选协议功率
# SOC 处理器代号（dtbo 模板目录）  HZ 1=支持屏幕超频 165Hz/高刷切换（只有小米15 华星 o3_42 屏）  DEFT 非原厂底包时用的模板
MODELS="dada haotian miro annibale warsaw pudding pandora popsicle nezha byron myron athens songyuan hongkong madrid"
# SOC 处理器代号 = dtbo/<SOC>/ 模板目录（v8.7.0）：8750 骁龙8至尊版 / 8850 第五代骁龙8至尊版 / 8950、8975 小米18 系列（6.18 内核）
# 6.12/6.18 内核机型（v8.7.0）：模板按 OS4 官方卡刷包里的原厂 dtbo 自动生成；私有协议节点布局与旧机型不同，不提供可选档位
# 未收录模板的处理器（v8.8.0）：8550 骁龙8Gen2（红米K70 vermeer、POCO F6 Pro）/ 8650 骁龙8Gen3（红米K70 Pro manet、K70 至尊版以外的同代机型）
# 这类机型没有 <代号>_os*.tpl 与 <代号>.avb，只能按通用模式安装：dtbo 逐项比对全部已收录模板，只写原厂值吻合的项
model_info(){
  case "$1" in
    dada)     MN=小米15;            SOC=8750; MI=15500; MX=20500; SC=20000; VQ=4580; V0=3050; PW0=90;  PWO="100 120"; HZ=1; DEFT=dada;;
    haotian)  MN="小米15 Pro";      SOC=8750; MI=15600; MX=20500; SC=20000; VQ=4580; V0=3050; PW0=90;  PWO="100 120"; HZ=0; DEFT=haotian_os4;;
    miro)     MN="红米K80 Pro";     SOC=8750; MI=20500; MX=22000; SC=20500; VQ=4550; V0=3050; PW0=120; PWO="";        HZ=0; DEFT=miro_os4;;
    annibale) MN=红米K90;           SOC=8750; MI=17600; MX=20500; SC=20000; VQ=4550; V0=2850; PW0=100; PWO="120";     HZ=0; DEFT=annibale_os4;;
    warsaw)   MN=红米K90至尊版;     SOC=8750; MI=17600; MX=20500; SC=20000; VQ=4560; V0=2850; PW0=100; PWO="120";     HZ=0; DEFT=warsaw_os4b;;
    pudding)  MN=小米17;            SOC=8850; MI=18400; MX=20500; SC=20000; VQ=4560; V0=3030; PW0=100; PWO="";        HZ=0; DEFT=pudding_os4;;
    pandora)  MN="小米17 Pro";      SOC=8850; MI=18000; MX=20500; SC=20000; VQ=4520; V0=3030; PW0=100; PWO="";        HZ=0; DEFT=pandora_os4;;
    popsicle) MN="小米17 Pro Max";  SOC=8850; MI=18000; MX=20500; SC=20000; VQ=4535; V0=3030; PW0=100; PWO="";        HZ=0; DEFT=popsicle_os4;;
    nezha)    MN="小米17 Ultra";    SOC=8850; MI=15600; MX=20500; SC=20000; VQ=4530; V0=2850; PW0=90;  PWO="";        HZ=0; DEFT=nezha_os4;;
    byron)    MN="小米17 Max";      SOC=8850; MI=18400; MX=20500; SC=20000; VQ=4580; V0=2850; PW0=100; PWO="";        HZ=0; DEFT=byron_os4;;
    myron)    MN="红米K90 Pro Max"; SOC=8850; MI=18400; MX=20500; SC=20000; VQ=4550; V0=3030; PW0=100; PWO="";        HZ=0; DEFT=myron_os4;;
    athens)   MN="红米K100 Pro";    SOC=8850; MI=18400; MX=20500; SC=20000; VQ=4580; V0=2850; PW0=100; PWO="";        HZ=0; DEFT=athens_os4;;
    songyuan) MN="红米K100 Pro Max";SOC=8850; MI=18400; MX=20500; SC=20000; VQ=4580; V0=2850; PW0=100; PWO="";        HZ=0; DEFT=songyuan_os4;;
    hongkong) MN="小米18 Pro";      SOC=8950; MI=18200; MX=20500; SC=20000; VQ=4590; V0=2850; PW0=100; PWO="";        HZ=0; DEFT=hongkong_os4;;
    madrid)   MN="小米18 Pro Max";  SOC=8975; MI=18000; MX=20500; SC=20000; VQ=4580; V0=2850; PW0=100; PWO="";        HZ=0; DEFT=madrid_os4;;
    *) return 1;;
  esac
  MODNAME="${MN}充电加速模块"; return 0
}
# 通用加载（v8.5.9）：已适配机型用表内参数；未适配机型按通用参数运行（v8.7.1 起先过 platform_check，处理器不是 SOCS 里任一款直接退出安装）
# v8.8.0：红米K70（vermeer，8550）、红米K70 Pro（manet，8650）就是走这条通用路径——没有原厂模板，dtbo 逐项比对
# GEN=1 表示未适配机型：电流上限 20500、无私有协议档位、无屏幕超频，FFC 截止电压等一律保持本机原厂（dtbo 逐项比对，只写原厂值吻合的项）
model_load(){
  if model_info "$1"; then GEN=0; return 0; fi
  GEN=1; MN=$(sh ${MCB_ROOT:-${0%/*}}/sysinfo.sh 2>/dev/null | sed -n 1p); [ -n "$MN" ] || MN=$(getprop ro.product.marketname); [ -n "$MN" ] || MN=小米
  MI=15500; MX=20500; SC=20000; VQ=0; V0=3000; PW0=0; PWO=""; HZ=0; DEFT=""; SOC=$(soc_code); [ -n "$SOC" ] || SOC=$(code_soc "$1")
  MODNAME="${MN}充电加速模块"; return 0
}
# 处理器兜底（v8.8.0）：个别底包/移植包读不到 ro.soc.model，按机型代号兜底，避免被 platform_check 误挡
# 红米K70 vermeer / POCO F6 Pro = SM8550，红米K70 Pro manet = SM8650
code_soc(){ case "$1" in vermeer) echo 8550;; manet) echo 8650;; *) :;; esac; }
model_names(){ echo "小米15 / 小米15 Pro / 红米K80 Pro / 红米K90 / 红米K90至尊版 / 小米17 / 17 Pro / 17 Pro Max / 17 Ultra / 17 Max / 红米K90 Pro Max / 红米K100 Pro / K100 Pro Max / 小米18 Pro / 18 Pro Max"; }
# 未适配机型的处理器代号：ro.soc.model（SM8850 → 8850），读不到为空（逐项比对时用全部模板）
soc_code(){ for k in ro.soc.model ro.vendor.soc.model ro.boot.hardware.sku; do v=$(getprop $k); case "$v" in SM[0-9][0-9][0-9][0-9]*) v=${v#SM}; echo ${v%%[!0-9]*}; return;; esac; done; }
# 处理器校验（v8.7.1，v8.8.0 起加入 SM8550 / SM8650）：只支持高通骁龙 SM8550/8650/8750/8850/8950/8975；天玑、玄戒不做适配。
# 内核版本只识别显示，不拦截
# 输出处理器描述；返回 1 = 非适配机型。$1 = 机型表 SOC（已适配机型读不到 ro.soc.model 时兜底）
SOCS="8550 8650 8750 8850 8950 8975"
# 已收录原厂 dtbo 模板（<代号>_os*.tpl + <代号>.avb）的处理器（v8.8.0）。
# 不在这个表里的处理器（8550 / 8650）没有原厂模板可参照，只能走通用模式：dtbo 逐项比对，
# 比对不到吻合项时 dtbo 不改动（v8.7.2 起这种情况会退出安装，见 customize.sh）
TPL_SOCS="8750 8850 8950 8975"
tpl_soc(){ case " $TPL_SOCS " in *" $1 "*) return 0;; esac; return 1; }
kernel_ver(){ uname -r 2>/dev/null | sed -n 's/^\([0-9]*\.[0-9]*\).*/\1/p'; }
platform_check(){
  mf=$(getprop ro.soc.manufacturer); sm=$(getprop ro.soc.model); hw="$(getprop ro.board.platform) $(getprop ro.hardware) $(getprop ro.boot.hardware)"
  case "$mf $sm $hw" in
    *[Mm]ediatek*|*MEDIATEK*|*MT[0-9][0-9][0-9][0-9]*|*\ mt[0-9][0-9][0-9][0-9]*) echo "天玑 ${sm:-${mf:-${hw%% *}}}"; return 1;;
    *[Xx][Rr][Ii][Nn][Gg]*) echo "玄戒 ${sm:-$mf}"; return 1;;
  esac
  case "$mf" in [Xx]iaomi*|XIAOMI*) echo "玄戒 ${sm:-$mf}"; return 1;; esac
  s=$(soc_code); [ -n "$s" ] || s=$1
  [ -n "$s" ] || { echo "未知（ro.soc.model=${sm:-空}）"; return 1; }
  case " $SOCS " in *" $s "*) echo "骁龙 SM$s"; return 0;; esac
  echo "骁龙 SM$s"; return 1
}
# 品牌校验（v8.7.1，v8.7.2 修移植包误判）：只装小米 / 红米。
# 移植包（ColorOS 等）会把 vendor/odm 的 brand/manufacturer 一起改成别家，所以按「底包」判断，依次：
#  1. 机型代号已识别为已适配小米机型（$1 = detect_code 结果）
#  2. 底包是 HyperOS/MIUI（sysinfo.sh 第 4 行，读 vendor/odm/vendor_dlkm 版本号与指纹）
#  3. vendor/odm/bootimage/vendor_dlkm 指纹或分区 build.prop 原文带 Xiaomi/Redmi/POCO
#  4. 品牌/厂商属性是 Xiaomi/Redmi
# 输出品牌（或识别依据）；返回 1 = 非小米红米机型
brand_check(){
  model_info "$1" >/dev/null 2>&1 && { echo "小米（机型代号 $1）"; return 0; }
  bs=$(sh ${MCB_ROOT:-${0%/*}}/sysinfo.sh 2>/dev/null | sed -n 4p)
  case "$bs" in OS[0-9]*|V[0-9]*) echo "小米（底包 $bs）"; return 0;; esac
  for k in ro.vendor.build.fingerprint ro.odm.build.fingerprint ro.vendor_dlkm.build.fingerprint ro.bootimage.build.fingerprint; do
    case "$(getprop $k)" in [Xx]iaomi/*|XIAOMI/*|[Rr]edmi/*|REDMI/*|POCO/*|[Pp]oco/*) echo "小米（底包指纹）"; return 0;; esac; done
  grep -qhiE '^ro\.(vendor|odm|vendor_dlkm|bootimage)\.build\.fingerprint=(xiaomi|redmi|poco)/' /vendor/build.prop /odm/etc/build.prop /vendor/odm/etc/build.prop /vendor_dlkm/etc/build.prop 2>/dev/null && { echo "小米（底包指纹）"; return 0; }
  b=""; for k in ro.product.vendor.brand ro.product.odm.brand ro.product.vendor.manufacturer ro.product.odm.manufacturer ro.product.brand ro.product.manufacturer; do
    v=$(getprop $k); [ -n "$v" ] || continue; [ -n "$b" ] || b=$v
    case "$v" in [Xx]iaomi*|XIAOMI*|[Rr]edmi*|REDMI*) echo "$v"; return 0;; esac; done
  v=$(grep -hE '^ro\.product\.(vendor\.)?(brand|manufacturer)=' /vendor/build.prop /odm/etc/build.prop 2>/dev/null | grep -iE '=(xiaomi|redmi)' | head -1)
  [ -n "$v" ] && { echo "${v#*=}"; return 0; }
  echo "${b:-未知}"; return 1
}
# 识别机型代号：sysinfo.sh（移植系统优先读 vendor/odm）→ 其它属性 → 分区 build.prop
detect_code(){
  c=$(sh ${MCB_ROOT:-${0%/*}}/sysinfo.sh 2>/dev/null | sed -n 2p)
  model_info "$c" >/dev/null 2>&1 && { echo $c; return 0; }
  for k in ro.product.vendor.device ro.product.odm.device ro.product.device ro.product.board ro.product.vendor.name ro.product.mod_device ro.build.product; do
    v=$(getprop $k); v=${v%%_*}; model_info "$v" >/dev/null 2>&1 && { echo $v; return 0; }; done
  for m in $MODELS; do
    grep -qE "^ro\.product\.(vendor\.)?(device|name)=${m}(_|\$)" /vendor/build.prop /odm/etc/build.prop 2>/dev/null && { echo $m; return 0; }; done
  echo "${c:-unknown}"; return 1
}
# 运行时取机型：安装时写入 $MCB_ROOT/model，没有再现场识别
model_code(){ r=${MCB_ROOT:-/data/adb/modules/mi_charge_boost}; c=$(cat $r/model 2>/dev/null)
  model_info "$c" >/dev/null 2>&1 && { echo $c; return 0; }; MCB_ROOT=$r detect_code; }
