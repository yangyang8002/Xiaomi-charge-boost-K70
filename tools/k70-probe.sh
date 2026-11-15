#!/system/bin/sh
# k70-probe.sh —— 红米 K70（vermeer / SM8550）dtbo 采集脚本
#   用途：在已 root 的 K70 上把 dtbo 分区读出来、解析 DT table + AVB 尾部，产出做原厂充电模板需要的原始材料：
#         report.txt（人读报告）、dtbo.img（整分区镜像）、<代号>.avb（712 字节 AVB 模板）、stock-dtbo.info
#   用法：sh k70-probe.sh [输出目录]        默认 /sdcard/Download/k70-probe
#         需要读 /dev/block 下的分区，请用 root 跑：su -c 'sh /sdcard/Download/k70-probe.sh'
#   只读：全程只对块设备做 dd 读取，绝不 dd 写入、绝不 blockdev --setrw、绝不改分区内容；
#         不认识的机型（非小米/红米）只打印属性然后退出，不动任何分区。
#   返回码：0 全部成功 / 1 失败（含非小米设备）/ 2 有产物但需要人工确认（例如没找到 AVB 尾部）
#   纯 shell 实现（toybox/busybox 的 dd + od + awk + sha256sum），不需要 python、不需要 jq。
#
# 关于 .avb 模板首 8 字节（与“footer 前 8 字节”不同，这里按仓库现有 15 个模板的实际情况写）：
#   module/dtbo/8750/miro.avb 等 712 字节模板 = [8 字节 dtbo 分区大小(大端 u64)][64 字节 footer][vbmeta]
#   仓库里这些值都是 0x800000 / 0x1200000 / 0x1600000（8 / 18 / 22 MiB），就是对应机型的 dtbo 分区大小；
#   dtbopatch.bin 里也有 "INFO footer at %d (device partition %d)"、"partition smaller than template"、
#   "patched image too large for partition"，说明这 8 字节是分区大小，不是 footer 前面的原始字节。

OUTD=${1:-/sdcard/Download/k70-probe}
NODES='mca_strategy_quick_charge mca_quick_charge_batt_para_gbl mca_buckchg_jeita mca_charger_thermal strategy-fg strategy_quick_charge_override mca_qcom_subpmic_proxy mca_protocol_pd_class mca_strategy_buckchg_class sc8585_master@6e'
WARN=0
AVBW=
RP=
T=

say(){ printf '%s\n' "$1"; [ -n "$RP" ] && printf '%s\n' "$1" >> "$RP"; return 0; }
warn(){ WARN=1; say "! $1"; [ -n "$2" ] && say "  $2"; return 0; }
die(){ say "! ${1:-未知错误}"; [ -n "$2" ] && say "  $2"; [ -n "$T" ] && rm -rf "$T"; exit 1; }

# ---------- 准备输出目录 / 临时目录 ----------
[ -n "$OUTD" ] || die "输出目录为空"
mkdir -p "$OUTD" 2>/dev/null
if [ ! -d "$OUTD" ]; then echo "! 无法创建输出目录: $OUTD"; echo "  换个目录试试: sh k70-probe.sh /data/local/tmp/k70-probe"; exit 1; fi
RP=$OUTD/report.txt
: > "$RP" 2>/dev/null || { RP=; echo "! 无法写入 $OUTD/report.txt"; exit 1; }
for b in /dev ${TMPDIR:-/data/local/tmp} "$OUTD"; do
  t=$b/.k70p.$$
  rm -rf "$t" 2>/dev/null
  mkdir -p "$t" 2>/dev/null && touch "$t/.w" 2>/dev/null && { T=$t; break; }
done
[ -n "$T" ] || die "无法创建临时目录（/dev、/data/local/tmp、$OUTD 都不可写）"
trap 'rm -rf "$T"' EXIT HUP INT TERM

# ---------- 小工具：按偏移取字节 / 转十六进制 / 十六进制转十进制 ----------
cutb(){ # $1=文件 $2=偏移 $3=长度 -> 原始字节
  [ "${3:-0}" -gt 0 ] || return 0
  tail -c +$(($2 + 1)) "$1" 2>/dev/null | head -c "$3"
}
hexb(){ cutb "$1" "$2" "$3" | od -An -v -tx1 | tr -d ' \n'; }
dec(){ # 十六进制串 -> 十进制（用 awk 算，避免 shell 64 位溢出）
  awk -v h="$1" 'BEGIN{
    n = 0; L = length(h)
    if (L == 0 || L > 16) { print ""; exit }
    for (i = 1; i <= L; i++) {
      c = tolower(substr(h, i, 1)); v = index("0123456789abcdef", c) - 1
      if (v < 0) { print ""; exit }
      n = n * 16 + v
    }
    if (n > 9007199254740992) { print ""; exit }
    printf "%.0f\n", n
  }'
}
u32be(){ dec "$(hexb "$1" "$2" 4)"; }
num(){ case "$1" in ''|*[!0-9]*) return 1;; esac; return 0; }   # 是十进制数字吗
mib(){ awk -v b="$1" 'BEGIN{ printf "%.2f", b / 1048576 }'; }
strb(){ # $1=文件 $2=偏移 $3=长度 -> 可打印文本（NUL 去掉，非打印字符变 .；不用 tr 处理 NUL，兼容性更好）
  hexb "$1" "$2" "$3" | LC_ALL=C awk '{
    h = $0
    for (i = 1; i <= length(h); i += 2) {
      v = nib(substr(h, i, 2))
      if (v == 0) continue
      printf "%s", (v >= 32 && v < 127) ? sprintf("%c", v) : "."
    }
    printf "\n"
  }
  function nib(h2,   i, c, v, n) {
    n = 0
    for (i = 1; i <= length(h2); i++) { c = tolower(substr(h2, i, 1)); v = index("0123456789abcdef", c) - 1; n = n * 16 + v }
    return n
  }'
}

# ---------- 1. 系统属性 ----------
say "# k70-probe 采集报告（只读脚本，不写任何分区）"
say "时间: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
say ""
say "[系统属性]"
for p in ro.product.device ro.product.vendor.device ro.soc.model ro.soc.manufacturer \
         ro.board.platform ro.product.marketname ro.mi.os.version.incremental \
         ro.build.version.incremental ro.build.version.release ro.boot.slot_suffix; do
  say "  $p = $(getprop "$p" 2>/dev/null)"
done
say "  uname -r = $(uname -r 2>/dev/null)"
say "  getenforce = $(getenforce 2>/dev/null)"
say "  id -u = $(id -u 2>/dev/null)"
say ""

CODE=$(getprop ro.product.vendor.device 2>/dev/null)
[ -n "$CODE" ] || CODE=$(getprop ro.product.device 2>/dev/null)
SOC=$(getprop ro.soc.model 2>/dev/null)
MARKET=$(getprop ro.product.marketname 2>/dev/null)
OSVER=$(getprop ro.mi.os.version.incremental 2>/dev/null)
[ -n "$OSVER" ] || OSVER=$(getprop ro.build.version.incremental 2>/dev/null)
MIOS=$(getprop ro.mi.os.version.incremental 2>/dev/null)$(getprop ro.miui.os.version.name 2>/dev/null)$(getprop ro.miui.ui.version.name 2>/dev/null)

# 非小米设备：只报告，不碰分区
case "$MIOS$MARKET" in
  "") say "! 这台机器没有小米/红米系统属性（ro.mi.os.* / ro.miui.* / ro.product.marketname 都为空）"
      say "  本脚本只针对红米 K70（vermeer，SM8550）这类小米机型；已停止，没有读取任何分区"
      [ -n "$T" ] && rm -rf "$T"
      exit 1;;
esac
case "$CODE" in
  vermeer) say "- 机型代号: vermeer（红米 K70）";;
  "") warn "读不到机型代号（ro.product.vendor.device / ro.product.device 都为空）" "stock-dtbo.info 里代号写“未知”、.avb 用默认名 vermeer.avb，请人工改";;
  *[!A-Za-z0-9_.-]*) warn "机型代号里有不常见字符: $CODE" "产物文件名/stock-dtbo.info 请人工确认";;
  *) warn "本机代号是 $CODE，不是 vermeer（红米 K70）" "脚本照样继续，但产物里的代号/版本要人工确认";;
esac
case "$SOC" in
  SM8550|sm8550) say "- 处理器: SM8550（骁龙 8 Gen 2，与 K70 一致）";;
  "") warn "读不到 ro.soc.model";;
  *) warn "本机处理器是 ${SOC:-未知}，K70 是 SM8550" "dtbo 布局可能不同，脚本判断不了，产物请人工复核";;
esac
say ""

# ---------- 2. 找 dtbo 分区 ----------
say "[dtbo 分区]"
S=$(getprop ro.boot.slot_suffix 2>/dev/null)
BLK=
# 调试用：K70_DTBO_BLK 可以直接指定块设备（甚至一个本地镜像文件），方便在 PC 上验脚本
[ -n "$K70_DTBO_BLK" ] && BLK=$K70_DTBO_BLK
for b in "/dev/block/by-name/dtbo$S" "/dev/block/bootdevice/by-name/dtbo$S"; do
  [ -n "$BLK" ] && break
  [ -e "$b" ] && { BLK=$b; break; }
done
if [ -z "$BLK" ]; then
  for b in /dev/block/platform/*/by-name/dtbo* /dev/block/platform/*/*/by-name/dtbo*; do
    [ -e "$b" ] || continue
    case "$b" in *dtbo) BLK=$b; break;; esac
    BLK=$b; break
  done
fi
[ -n "$BLK" ] || die "找不到 dtbo 分区（by-name/dtbo$S 与 platform/*/by-name/dtbo* 都没有）" \
  "把 report.txt 发回来，让作者确认你这台的分区名"
[ -r "$BLK" ] || die "没有读权限: $BLK" "用 root 跑：su -c 'sh $0'"
say "  块设备: $BLK"

SZ=$(blockdev --getsize64 "$BLK" 2>/dev/null)
case "$SZ" in ''|*[!0-9]*) SZ=$(wc -c < "$BLK" 2>/dev/null);; esac
case "$SZ" in ''|*[!0-9]*) die "读不到分区大小（blockdev 和 wc -c 都失败）";; esac
say "  分区大小: $SZ 字节（$(mib "$SZ") MiB）"

# 大小合理性检查：> 1 MiB，且是 4096 的整数倍、并且（2 的幂 或 1 MiB 的整数倍）
[ "$SZ" -gt 1048576 ] || die "分区大小只有 $SZ 字节，不像 dtbo 分区（应该 > 1 MiB）" "分区名可能找错了，请人工确认"
[ $((SZ % 4096)) -eq 0 ] || warn "分区大小 $SZ 不是 4096 的整数倍，不太像分区" "先人工确认，再决定要不要用产物"
POW2=0; [ $((SZ & (SZ - 1))) -eq 0 ] && POW2=1
BLK1M=0; [ $((SZ % 1048576)) -eq 0 ] && BLK1M=1
[ "$POW2" = 1 ] || [ "$BLK1M" = 1 ] || warn "分区大小 $SZ 既不是 2 的幂也不是 1 MiB 的整数倍（dtbo 一般 8/18/22 MiB）" "不常见，但脚本会继续；产物的首 8 字节仍按这个大小写"
say ""

# ---------- 3. dump 整个分区并校验 ----------
say "[读取分区]"
TMPIMG=$T/dtbo.img
dd if="$BLK" of="$TMPIMG" bs=1048576 2>"$T/dd.log" || die "dd 读取失败: $(cat "$T/dd.log" 2>/dev/null | tr '\n' ' ')"
SZ2=$(wc -c < "$TMPIMG" 2>/dev/null)
case "$SZ2" in ''|*[!0-9]*) die "读出来的文件大小不对";; esac
[ "$SZ2" = "$SZ" ] || die "读出来的文件 $SZ2 字节，与分区大小 $SZ 不一致" "分区可能在读的时候被改了，重跑一次"
SHA1=$(sha256sum "$TMPIMG" 2>/dev/null | cut -d' ' -f1)
SHA2=$(dd if="$BLK" bs=1048576 2>/dev/null | sha256sum | cut -d' ' -f1)
[ -n "$SHA1" ] && [ "$SHA1" = "$SHA2" ] || die "dump 校验失败（两次读取 sha256 不同）" "分区读不稳定，重跑一次；还是不行就把 report.txt 发回来"
dd if="$TMPIMG" of="$OUTD/dtbo.img" bs=4096 2>/dev/null || die "写不了 $OUTD/dtbo.img" "换个输出目录，例如 /data/local/tmp/k70-probe"
[ "$(sha256sum "$OUTD/dtbo.img" 2>/dev/null | cut -d' ' -f1)" = "$SHA1" ] || die "复制到 $OUTD/dtbo.img 后 sha256 不一致" "SD 卡写入有问题，换目录重试"
say "  dtbo.img: $SZ 字节, sha256=$SHA1"
say ""
IMG=$OUTD/dtbo.img

# ---------- 4. DT table 头 ----------
say "[DT table 头]"
MAGIC=$(hexb "$IMG" 0 4)
[ "$MAGIC" = d7b7ab1e ] || die "分区头 magic 是 ${MAGIC:-空}，不是 d7b7ab1e（DT table）" \
  "这台机器的 dtbo 不是标准 DT table 格式，脚本做不了；把 report.txt 发回来"
TSIZE=$(u32be "$IMG" 4)
HDRSZ=$(u32be "$IMG" 8)
ENTSZ=$(u32be "$IMG" 12)
ECNT=$(u32be "$IMG" 16)
EOFF=$(u32be "$IMG" 20)
PGSZ=$(u32be "$IMG" 24)
TVER=$(u32be "$IMG" 28)
[ -n "$TSIZE" ] && [ "$TSIZE" -gt 0 ] || die "DT table 的 total_size 读不出来或为 0"
for v in "$TSIZE" "$HDRSZ" "$ENTSZ" "$ECNT" "$EOFF" "$PGSZ" "$TVER"; do
  num "$v" || die "DT table 头字段读不出来（total_size=${TSIZE:-空} header_size=${HDRSZ:-空} dt_entry_size=${ENTSZ:-空} dt_entry_count=${ECNT:-空} entries_offset=${EOFF:-空}）" \
    "分区读取有问题？重跑一次"
done
[ "$TSIZE" -le "$SZ" ] || die "DT table 声明 total_size=$TSIZE，比分区 $SZ 还大" "镜像不完整？重跑一次"
TSHA=$(head -c "$TSIZE" "$IMG" 2>/dev/null | sha256sum | cut -d' ' -f1)
say "  magic = d7b7ab1e (ok)"
say "  total_size = $TSIZE 字节"
say "  total_size sha256 = $TSHA   ← stock.list 第一列"
say "  header_size=$HDRSZ  dt_entry_size=$ENTSZ  dt_entry_count=$ECNT  entries_offset=$EOFF  page_size=$PGSZ  version=$TVER"
[ "$HDRSZ" -ge 32 ] && [ "$ENTSZ" -ge 32 ] || die "header_size=$HDRSZ / dt_entry_size=$ENTSZ 不是标准 DT table" \
  "只有 header 32 / entry 32 的布局受支持"
[ "$ECNT" -gt 0 ] || die "dt_entry_count=0，一个 FDT 都没有"
[ "$ECNT" -le 16 ] || warn "dt_entry_count=$ECNT 偏多，只解析前 16 个" ""
[ $((EOFF + ECNT * ENTSZ)) -le "$TSIZE" ] || die "entry 表越界（$((EOFF + ECNT * ENTSZ)) > total_size $TSIZE）"
say ""

# ---------- 5. 逐 entry 解析 FDT ----------
# awk 程序：先从字符串块还原 offset->属性名，再顺序走结构块（token 1 节点 / 2 节点结束 / 3 属性 / 4 NOP / 9 结束）
# 只打印关注节点（$NODES）下的属性：十六进制原样 + 大小端 u32 解码
AWK_FDT='
BEGIN { for (i = 0; i < 256; i++) HB[sprintf("%02x", i)] = i; nw = split(NODES, WN, " ") }
FILENAME == ARGV[1] { for (i = 1; i <= NF; i++) B[nb++] = $i; next }
{ for (i = 1; i <= NF; i++) S[ns++] = $i }
END {
  st = 0; cur = ""
  for (i = 0; i < ns; i++) {
    v = HB[S[i]]
    if (v == 0) { NM[st] = cur; st = i + 1; cur = "" }
    else cur = cur ((v >= 32 && v < 127) ? sprintf("%c", v) : "?")
  }
  pos = 0; depth = 0; cnt = 0; nodes = 0; hot = 0
  while (pos + 4 <= nb) {
    t = be32(pos)
    if (t == 1) {
      np = pos + 4; nm = ""; l = 0
      while (np + l < nb && HB[B[np + l]] != 0) {
        nh = HB[B[np + l]]
        nm = nm ((nh >= 32 && nh < 127) ? sprintf("%c", nh) : "?"); l++
      }
      if (substr(nm, 1, 1) == "/") nm = substr(nm, 2)
      if (depth < 0) depth = 0
      STK[depth] = nm
      p = ""
      for (k = 0; k <= depth; k++) if (STK[k] != "") p = p "/" STK[k]
      if (p == "") p = "/"
      base = nm
      if (index(base, "@") > 0) base = substr(base, 1, index(base, "@") - 1)
      hot = 0
      for (k = 1; k <= nw; k++) {
        wb = WN[k]
        if (index(wb, "@") > 0) wb = substr(wb, 1, index(wb, "@") - 1)
        if (nm == WN[k] || base == wb || index(base, wb) == 1) hot = 1
      }
      if (hot) { nodes++; printf("  ● %s（%s）\n", p, nm) }
      HOT[depth] = hot
      depth++
      pos = np + int((l + 4) / 4) * 4
    } else if (t == 2) {
      depth--; if (depth < 0) { print "  ! 结构块 END_NODE 多于 BEGIN_NODE"; exit 3 }
      hot = (depth > 0) ? HOT[depth - 1] : 0
      pos += 4
    } else if (t == 3) {
      len = be32(pos + 4); noff = be32(pos + 8); vp = pos + 12
      if (len < 0 || vp + len > nb) { print "  ! 属性值越界，结构块解析中止"; exit 3 }
      if (hot) {
        pn = NM[noff]; if (pn == "") pn = "?nameoff" noff
        hx = ""
        for (i = 0; i < len; i++) hx = hx B[vp + i]
        line = sprintf("      %-34s len=%-4d hex=%s", pn, len, hx)
        if (len % 4 == 0 && len > 0 && len <= 16 && (len <= 8 || !istext(vp, len))) {
          bs = ""; ls = ""
          for (i = 0; i < len; i += 4) {
            bs = bs (bs == "" ? "" : ",") be32(vp + i)
            ls = ls (ls == "" ? "" : ",") le32(vp + i)
          }
          line = line "  be=" bs "  le=" ls
        }
        print line
        cnt++
      }
      pos = vp + int((len + 3) / 4) * 4
    } else if (t == 4) { pos += 4 }
    else if (t == 9) { break }
    else { print "  ! 结构块出现未知 token " t "，解析中止"; exit 3 }
  }
  printf("  关注节点 %d 个，属性 %d 项\n", nodes, cnt)
  if (nodes == 0) print "  ! 没找到关注节点：本机 dtbo 的节点名跟预期不同，请把 report.txt 发回来"
}
function be32(i) { return HB[B[i]] * 16777216 + HB[B[i + 1]] * 65536 + HB[B[i + 2]] * 256 + HB[B[i + 3]] }
function le32(i) { return HB[B[i]] + HB[B[i + 1]] * 256 + HB[B[i + 2]] * 65536 + HB[B[i + 3]] * 16777216 }
function istext(vp, len,   i, v) {
  for (i = 0; i < len; i++) { v = HB[B[vp + i]]; if (v != 0 && (v < 32 || v > 126)) return 0 }
  return 1
}
'

e=0
while [ "$e" -lt "$ECNT" ] && [ "$e" -lt 16 ]; do
  EO=$((EOFF + e * ENTSZ))
  DTSZ=$(u32be "$IMG" "$EO")
  DTOFF=$(u32be "$IMG" $((EO + 4)))
  DTID=$(u32be "$IMG" $((EO + 8)))
  DTREV=$(u32be "$IMG" $((EO + 12)))
  say "[entry $e]"
  say "  dt_size=$DTSZ  dt_offset=$DTOFF  id=$DTID  rev=$DTREV"
  if ! num "$DTSZ" || ! num "$DTOFF"; then say "  ! entry 字段读不出来，跳过"; WARN=1; e=$((e + 1)); continue; fi
  if [ $((DTOFF + DTSZ)) -gt "$SZ" ]; then say "  ! entry 越界（$((DTOFF + DTSZ)) > $SZ），跳过"; WARN=1; e=$((e + 1)); continue; fi
  FM=$(hexb "$IMG" "$DTOFF" 4)
  if [ "$FM" != d00dfeed ]; then say "  ! FDT magic 是 ${FM:-空}，不是 d00dfeed，跳过该 entry"; WARN=1; e=$((e + 1)); continue; fi
  FTS=$(u32be "$IMG" $((DTOFF + 4)))
  SOFF=$(u32be "$IMG" $((DTOFF + 8)))
  STROFF=$(u32be "$IMG" $((DTOFF + 12)))
  RSOFF=$(u32be "$IMG" $((DTOFF + 16)))
  FVER=$(u32be "$IMG" $((DTOFF + 20)))
  FLCV=$(u32be "$IMG" $((DTOFF + 24)))
  FCPU=$(u32be "$IMG" $((DTOFF + 28)))
  SZS=$(u32be "$IMG" $((DTOFF + 32)))
  SZST=$(u32be "$IMG" $((DTOFF + 36)))
  if ! num "$FTS" || ! num "$SOFF" || ! num "$STROFF" || ! num "$SZS" || ! num "$SZST"; then
    say "  ! FDT 头字段读不出来（totalsize/off_dt_struct/off_dt_strings/size），跳过该 entry"; WARN=1; e=$((e + 1)); continue
  fi
  say "  FDT magic d00dfeed (ok)  totalsize=$FTS  version=$FVER  last_comp_version=$FLCV  boot_cpuid=$FCPU"
  say "  off_dt_struct=$SOFF (size $SZST)  off_dt_strings=$STROFF (size $SZS)  off_mem_rsvmap=$RSOFF"
  if [ "$SOFF" -ge "$DTSZ" ] || [ "$STROFF" -ge "$DTSZ" ] || [ $((SOFF + SZST)) -gt "$DTSZ" ] || [ $((STROFF + SZS)) -gt "$DTSZ" ] || [ "$SZST" -eq 0 ] || [ "$SZS" -eq 0 ]; then
    say "  ! 结构块/字符串块越界（dt_size=$DTSZ），跳过该 entry"; WARN=1; e=$((e + 1)); continue
  fi
  cutb "$IMG" $((DTOFF + SOFF)) "$SZST" | od -An -v -tx1 > "$T/struct.hex" 2>/dev/null
  cutb "$IMG" $((DTOFF + STROFF)) "$SZS" | od -An -v -tx1 > "$T/strings.hex" 2>/dev/null
  awk -v NODES="$NODES" "$AWK_FDT" "$T/struct.hex" "$T/strings.hex" > "$T/props.txt" 2>"$T/awk.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "entry $e 结构块解析出错（awk 返回 $rc）" "$(cat "$T/awk.err" 2>/dev/null | head -2 | tr '\n' ' ')"
  fi
  while IFS= read -r ln; do say "$ln"; done < "$T/props.txt"
  say ""
  e=$((e + 1))
done

# ---------- 6. AVB 尾部 ----------
# 两种布局都认：
#   A) footer 紧跟 vbmeta（vbmeta_offset + vbmeta_size == footer 位置）—— 仓库里 15 个 <代号>.avb 是这种；
#   B) footer 在分区最后 64 字节、vbmeta 在 vbmeta_offset 处、中间全是补零 —— AVB 标准布局，真机整分区 dump 常见。
# B 布局下 footer 和 vbmeta 相隔很远，不能指望一次扫描窗口里两个都在：
#   第一步 在两段窗口里找“字段自洽”的 AVBf，输出 偏移:vbmeta偏移:大小；
#   第二步 逐个用 dd 去 vbmeta_offset 处确认是 AVB0，优先取“紧跟 vbmeta”的那个。
# 自洽条件：vbmeta 不越界、original_image_size <= vbmeta_offset。
AWK_AVB='
BEGIN { for (i = 0; i < 256; i++) HB[sprintf("%02x", i)] = i }
{ for (i = 1; i <= NF; i++) B[n++] = $i }
END {
  s = ""
  for (i = 0; i < n; i++) s = s B[i]
  start = 1
  while (start <= length(s)) {
    k = index(substr(s, start), "41564266")
    if (k == 0) break
    k = k + start - 1
    start = k + 2
    if (k % 2 != 1) continue
    p = (k - 1) / 2
    if (p + 64 > n) continue
    og = gdec(substr(s, k + 24, 16))
    vb = gdec(substr(s, k + 40, 16))
    sz = gdec(substr(s, k + 56, 16))
    if (vb == "" || sz == "" || sz <= 0) continue
    if (vb + sz > total) continue
    if (og != "" && og > vb) continue
    print (base + p) ":" vb ":" sz
  }
}
function gdec(h,   i, c, v, nn) {
  nn = 0
  for (i = 1; i <= length(h); i++) {
    c = tolower(substr(h, i, 1)); v = index("0123456789abcdef", c) - 1
    if (v < 0) return ""
    nn = nn * 16 + v
  }
  if (nn > 9007199254740992) return ""
  return nn
}
'
scan_avb(){ # $1=起始偏移 $2=长度 -> 每行打印 "footer偏移:vbmeta偏移:vbmeta大小"（未确认 vbmeta 内容）
  [ "${2:-0}" -gt 0 ] || return 0
  cutb "$IMG" "$1" "$2" | od -An -v -tx1 | awk -v base="$1" -v total="$SZ" "$AWK_AVB" 2>/dev/null
}

say "[AVB 尾部]"
FO=
W1S=$TSIZE
W1L=$((SZ - TSIZE))
[ "$W1L" -gt 65536 ] && W1L=65536
AVBC=""
[ "$W1L" -gt 0 ] && AVBC=$(scan_avb "$W1S" "$W1L")
[ "$SZ" -gt 4096 ] && AVBC="$AVBC
$(scan_avb $((SZ - 4096)) 4096)"
AVBC=$(printf '%s\n' "$AVBC" | awk 'NF' | sort -u)
ADJ=""; LOO=""
for c in $AVBC; do
  off=${c%%:*}; rest=${c#*:}; vb=${rest%%:*}; sz=${rest#*:}
  case "$off" in ''|*[!0-9]*) continue;; esac
  case "$vb" in ''|*[!0-9]*) continue;; esac
  [ "$(hexb "$IMG" "$vb" 4)" = 41564230 ] || continue
  if [ $((vb + sz)) -eq "$off" ]; then ADJ="$ADJ $off"; else LOO="$LOO $off"; fi
done
[ -n "$ADJ" ] && FO=$(echo $ADJ | tr ' ' '\n' | sort -un | tail -1)
[ -z "$FO" ] && [ -n "$LOO" ] && FO=$(echo $LOO | tr ' ' '\n' | sort -un | tail -1)
[ -n "$FO" ] && say "  找到 AVB footer: 偏移 $FO"
if [ -z "$FO" ]; then
  warn "没有找到 AVB footer（AVBf + 自洽的 vbmeta 偏移）" \
    "移植包/官改包的 dtbo 可能没有 AVB；这时只能拿到 dtbo.img 和 stock-dtbo.info，<代号>.avb 需要从原厂卡刷包的 dtbo.img 提取"
else
  say "  footer 位置: $FO（距分区末尾 $((SZ - FO - 64)) 字节）"
  say "  footer magic: $(hexb "$IMG" "$FO" 4) = AVBf (ok)"
  say "  footer 前 8 字节（原样）: $(hexb "$IMG" $((FO - 8)) 8)"
  FMAJ=$(u32be "$IMG" $((FO + 4)))
  FMIN=$(u32be "$IMG" $((FO + 8)))
  ORIG=$(dec "$(hexb "$IMG" $((FO + 12)) 8)")
  VBOFF=$(dec "$(hexb "$IMG" $((FO + 20)) 8)")
  VBSZ=$(dec "$(hexb "$IMG" $((FO + 28)) 8)")
  say "  footer 版本: $FMAJ.$FMIN"
  say "  original_image_size: ${ORIG:-未知}"
  say "  vbmeta_offset: ${VBOFF:-未知}"
  say "  vbmeta_size  : ${VBSZ:-未知}"
  if [ -z "$VBOFF" ] || [ -z "$VBSZ" ] || [ "$VBSZ" -le 0 ]; then
    warn "footer 里的 vbmeta 偏移/大小读不出来" "跳过 AVB 细节"
  elif [ $((VBOFF + VBSZ)) -gt "$SZ" ]; then
    warn "vbmeta 越界（$VBOFF + $VBSZ > $SZ）" "跳过 AVB 细节"
  else
    VBM=$(hexb "$IMG" "$VBOFF" 4)
    if [ "$VBM" != 41564230 ]; then
      warn "vbmeta magic 是 ${VBM:-空}，不是 AVB0" "跳 AVB 细节"
    else
      say "  vbmeta magic: AVB0 (ok)"
      RVM=$(u32be "$IMG" $((VBOFF + 4)))
      RVN=$(u32be "$IMG" $((VBOFF + 8)))
      AUTHSZ=$(dec "$(hexb "$IMG" $((VBOFF + 12)) 8)")
      AUXSZ=$(dec "$(hexb "$IMG" $((VBOFF + 20)) 8)")
      ALGO=$(u32be "$IMG" $((VBOFF + 28)))
      DOFF=$(dec "$(hexb "$IMG" $((VBOFF + 96)) 8)")
      DSZ=$(dec "$(hexb "$IMG" $((VBOFF + 104)) 8)")
      RSTR=$(strb "$IMG" $((VBOFF + 128)) 48)
      say "  required_libavb_version: ${RVM:-?}.${RVN:-?}   release_string: ${RSTR:-空}"
      if [ "${AUTHSZ:-0}" -gt 0 ]; then
        say "  authentication_data_block_size: $AUTHSZ → 有认证块（签名）"
      else
        say "  authentication_data_block_size: 0 → 无认证块（算法 NONE，只有哈希）"
      fi
      say "  auxiliary_data_block_size: ${AUXSZ:-未知}   algorithm_type: ${ALGO:-未知}"
      say "  descriptors_offset/size: ${DOFF:-未知} / ${DSZ:-未知}"
      if [ -z "$DOFF" ] || [ -z "$DSZ" ]; then
        warn "描述符偏移/大小读不出来" "跳过 salt/digest"
      elif [ "$DSZ" -le 0 ]; then
        warn "vbmeta 里没有描述符（descriptors_size=0）" "没有哈希描述符就拿不到 salt/digest"
      else
        # 描述符在辅助块里：辅助块紧跟 vbmeta 头(256) + 认证块
        DP=$((VBOFF + 256 + ${AUTHSZ:-0} + DOFF))
        DEND=$((DP + DSZ))
        [ "$DEND" -le $((VBOFF + VBSZ)) ] || warn "描述符区越界（$DEND > $((VBOFF + VBSZ))），按实际 vbmeta 末尾截断" ""
        [ "$DEND" -gt $((VBOFF + VBSZ)) ] && DEND=$((VBOFF + VBSZ))
        k=0
        found=0
        while [ "$DP" -lt "$DEND" ] && [ "$k" -lt 32 ]; do
          TAG=$(dec "$(hexb "$IMG" "$DP" 8)")
          NBF=$(dec "$(hexb "$IMG" $((DP + 8)) 8)")
          case "${TAG:-x}${NBF:-x}" in *[!0-9]*) say "  ! 描述符字段读不出来，停止"; break;; esac
          if [ "$NBF" -lt 0 ] || [ "$NBF" -gt 65536 ]; then say "  ! 描述符长度 $NBF 异常，停止"; WARN=1; break; fi
          if [ "$TAG" = 2 ]; then
            # tag 2 = 哈希描述符：image_size(8) hash_algorithm(32) 三个长度(4x4) 保留(60) 然后 分区名/salt/digest
            HIMG=$(dec "$(hexb "$IMG" $((DP + 16)) 8)")
            HALG=$(strb "$IMG" $((DP + 24)) 32)
            NLEN=$(u32be "$IMG" $((DP + 56)))
            SLEN=$(u32be "$IMG" $((DP + 60)))
            DLEN=$(u32be "$IMG" $((DP + 64)))
            HFLG=$(u32be "$IMG" $((DP + 68)))
            HNAME=$(strb "$IMG" $((DP + 132)) "${NLEN:-0}")
            SALT=$(hexb "$IMG" $((DP + 132 + ${NLEN:-0})) "${SLEN:-0}")
            DGST=$(hexb "$IMG" $((DP + 132 + ${NLEN:-0} + ${SLEN:-0})) "${DLEN:-0}")
            say "  [tag 2 哈希描述符] 分区名=${HNAME:-未知}  算法=${HALG:-未知}  image_size=${HIMG:-未知}  flags=${HFLG:-未知}"
            say "      salt  (${SLEN:-0} 字节): ${SALT:-空}"
            say "      digest(${DLEN:-0} 字节): ${DGST:-空}"
            found=1
          else
            say "  [tag $TAG 描述符] $NBF 字节（本脚本只解读 tag 2，其余跳过）"
          fi
          DP=$((DP + 16 + (NBF + 7) / 8 * 8))
          k=$((k + 1))
        done
        [ "$found" = 1 ] || warn "vbmeta 里没有哈希描述符（tag 2）" "取不到 salt/digest；这是移植包常见情况"
      fi
      # ---- 产物：<代号>.avb（首 8 字节 = 分区大小，大端 u64；然后 64 字节 footer；然后 vbmeta）----
      ACODE=${CODE:-vermeer}
      AVB=$OUTD/$ACODE.avb
      n=$SZ; u=8; pfx=
      while [ "$u" -gt 0 ]; do
        byte=$((n % 256)); n=$((n / 256))
        pfx="\\$(printf '%03o' "$byte")$pfx"
        u=$((u - 1))
      done
      if printf "$pfx" > "$AVB" 2>/dev/null && cutb "$IMG" "$FO" 64 >> "$AVB" 2>/dev/null && cutb "$IMG" "$VBOFF" "$VBSZ" >> "$AVB" 2>/dev/null; then
        ASZ=$(wc -c < "$AVB" 2>/dev/null)
        if [ "$ASZ" = 712 ]; then
          AVBW=$AVB
          say "  已写出 $AVB（712 字节, sha256=$(sha256sum "$AVB" 2>/dev/null | cut -d' ' -f1)）"
        else
          warn "$AVB 是 ${ASZ:-?} 字节，不是 712 字节（vbmeta_size=$VBSZ）" "dtbopatch 只认 712 字节模板，请人工确认"
        fi
      else
        warn "写不了 $AVB" "换个输出目录重试"
      fi
    fi
  fi
fi
say ""

# ---------- 7. stock-dtbo.info ----------
# 格式与 module/dtbo/stock.list 一致：<sha256> <代号> <模板名> <原厂系统版本>
# 模板名先写 "-"：vermeer 还没有模板，等作者按生成的 .tpl 起名后再改，绝不瞎猜
INFO=$OUTD/stock-dtbo.info
LINE="${TSHA:-未知} ${CODE:-未知} - ${OSVER:-未知}"
if printf '%s\n' "$LINE" > "$INFO" 2>/dev/null; then
  say "[stock-dtbo.info]"
  say "  $LINE"
  say "  （第 3 列是模板名占位 -：vermeer 还没有 <代号>_os*.tpl，等模板做好后由作者填）"
  say ""
else
  warn "写不了 $INFO" "换个输出目录重试"
fi

# ---------- 8. 汇总 ----------
say "[产物]"
say "  $RP"
say "  $OUTD/dtbo.img"
[ -n "$AVBW" ] && say "  $AVBW"
say "  $INFO"
say ""
say "- 下一步：把 report.txt、stock-dtbo.info 和 dtbo.img（或 ${CODE:-vermeer}.avb）发给模块作者；"
say "  或用 PC 跑：python tools/ftd-parse.py dtbo.img --emit-tpl ${CODE:-vermeer}_os?.tpl --emit-avb ${CODE:-vermeer}.avb"
say "- 本脚本全程只读，没有向任何分区写入过任何字节"
if [ "$WARN" = 1 ]; then
  say ""
  say "=== 完成，但有需要人工确认的地方（见上面 ! 行）==="
  [ -n "$T" ] && rm -rf "$T"
  exit 2
fi
say ""
say "=== 完成 ==="
[ -n "$T" ] && rm -rf "$T"
exit 0
