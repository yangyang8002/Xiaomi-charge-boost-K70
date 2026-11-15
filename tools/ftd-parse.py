#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ftd-parse.py —— 小米 dtbo.img 解析 / 原厂模板生成（PC 端，只用 CPython 标准库）

用法:
  python ftd-parse.py dtbo.img                      人读转储：DT table 头 / 每个 entry / 关注节点属性 / AVB 尾部
  python ftd-parse.py dtbo.img --emit-tpl out.tpl   生成 stock 模板（仓库 .tpl 行格式；未改占位符前是 no-op）
  python ftd-parse.py dtbo.img --emit-avb out.avb   提取 712 字节 AVB 模板（分区大小 + 64 字节 footer + vbmeta）
  python ftd-parse.py dtbo.img --list-nodes         额外列出镜像里所有节点（新处理器上找充电节点名用）

--emit-avb 生成的是 module/dtbo/<SOC>/<代号>.avb 那种 712 字节模板：
  [0..7]   dtbo 分区大小（大端 u64）——仓库里 15 个 .avb 的首 8 字节都是 0x800000 / 0x1200000 / 0x1600000，
           即 8 / 18 / 22 MiB，就是各机型的 dtbo 分区大小；dtbopatch.bin 里有
           "INFO footer at %d (device partition %d)" / "partition smaller than template" /
           "patched image too large for partition"，说明它拿这 8 字节当分区大小用。
  [8..71]  AVB footer（64 字节，字段全大端）
  [72..]   footer 里 vbmeta_size 指定的 vbmeta 块
如果手里是整分区 dump（手机 k70-probe.sh 就是这么 dump 的），首 8 字节直接用文件大小；
只有压缩过/裁剪过的镜像才需要 --partition-size 手动给分区大小。

退出码: 0 正常 / 1 参数或镜像错误 / 2 成功但有需要人工确认的地方

只读：只读传入的镜像文件，只写命令行指定的输出文件，不碰任何分区、不改仓库。
与 module/dtbo/apply.sh 的关系：生成的 .tpl / .avb 需要人工过一遍再放进 module/dtbo/<SOC>/。
"""

import argparse
import hashlib
import os
import struct
import sys
import time

# ---------------------------------------------------------------- 常量

DT_MAGIC = 0xD7B7AB1E                     # DT table 头 magic（大端）
FDT_MAGIC = 0xD00DFEED                    # FDT blob magic（大端）
FDT_BEGIN_NODE = 0x01
FDT_END_NODE = 0x02
FDT_PROP = 0x03
FDT_NOP = 0x04
FDT_END = 0x09

AVB_FOOTER_MAGIC = b"AVBf"
AVB_VBMETA_MAGIC = b"AVB0"
AVB_FOOTER_SIZE = 64
AVB_VBMETA_HEADER_SIZE = 256
AVB_TPL_SIZE = 712                        # module/dtbo/<代号>.avb 的固定长度（8 + 64 + 640）
AVB_TAIL_SCAN = 65536                     # 分区比镜像大（尾部补零）时，在最后 64 KiB 里回扫 footer
AVB_DESC_HASH = 2
AVB_DESC_PROPERTY = 0
AVB_DESC_HASHTREE = 1

# 小米充电参数所在节点（其余节点不展开）。匹配规则：同名、去单元地址同名、或前缀同名，
# 这样可以顺带覆盖 mca_buckchg_jeita_gbl_para / _second_para / _tmp_para 这类变体。
INTERESTING_NODES = (
    "mca_strategy_quick_charge",
    "mca_quick_charge_batt_para_gbl",
    "mca_buckchg_jeita",
    "mca_charger_thermal",
    "strategy-fg",
    "strategy_quick_charge_override",
    "mca_qcom_subpmic_proxy",
    "mca_protocol_pd_class",
    "mca_strategy_buckchg_class",
    "sc8585_master@6e",
)

WARNED = []                               # 需要人工确认的事项，最后统一列出

# ---------------------------------------------------------------- 基础工具


def die(msg, hint=None):
    sys.stderr.write("! %s\n" % msg)
    if hint:
        sys.stderr.write("  提示: %s\n" % hint)
    sys.stderr.flush()
    sys.exit(1)


def warn(msg, hint=None):
    line = msg if not hint else "%s（%s）" % (msg, hint)
    if line in WARNED:                    # 多个 entry 会重复遇到同一件事，只报一次
        return
    WARNED.append(line)
    sys.stderr.write("! %s\n" % msg)
    if hint:
        sys.stderr.write("  提示: %s\n" % hint)
    sys.stderr.flush()


def read_image(path):
    if not os.path.exists(path):
        die("找不到镜像文件: %s" % path,
            "用法: python ftd-parse.py <dtbo.img>（镜像可以从手机 /sdcard/Download/k70-probe/dtbo.img 拉回来）")
    if os.path.isdir(path):
        die("%s 是目录，不是镜像文件" % path, "请传 dtbo 分区镜像（dtbo.img）")
    try:
        with open(path, "rb") as fp:
            data = fp.read()
    except OSError as exc:
        die("读不了 %s: %s" % (path, exc), "确认文件存在、有读权限")
    if len(data) < 4096:
        die("%s 只有 %d 字节，不像 dtbo 分区镜像" % (path, len(data)),
            "dtbo 分区一般 1 MiB 以上；用手机上的 tools/k70-probe.sh 重新 dump 一份")
    return data


def be32(data, off):
    if off + 4 > len(data):
        die("读 32 位大端值时越界: 偏移 %d，文件 %d 字节" % (off, len(data)),
            "镜像被截断了？请重新 dump")
    return struct.unpack_from(">I", data, off)[0]


def be64(data, off):
    if off + 8 > len(data):
        die("读 64 位大端值时越界: 偏移 %d，文件 %d 字节" % (off, len(data)),
            "镜像被截断了？请重新 dump")
    return struct.unpack_from(">Q", data, off)[0]


def pad4(n):
    return (n + 3) & ~3


def pad8(n):
    return (n + 7) & ~7


def strip_unit(name):
    """去掉节点名的单元地址: sc8585_master@6e -> sc8585_master"""
    return name.split("@")[0]


def is_interesting(node_name):
    base = strip_unit(node_name)
    for item in INTERESTING_NODES:
        ibase = strip_unit(item)
        if node_name == item or base == ibase or base.startswith(ibase):
            return True
    return False


def u32_be(val):
    return [int.from_bytes(val[i:i + 4], "big") for i in range(0, len(val) - len(val) % 4, 4)]


def u32_le(val):
    return [int.from_bytes(val[i:i + 4], "little") for i in range(0, len(val) - len(val) % 4, 4)]


def text_fields(val):
    """值能否当 NUL 分隔的 ASCII 文本读（.tpl 的 s 类型）；不能则返回 None"""
    if not val:
        return None
    for byte in val:
        if byte != 0 and (byte < 0x20 or byte > 0x7E):
            return None
    parts = val.split(b"\x00")
    while parts and parts[-1] == b"":
        parts.pop()
    if not parts:
        return None
    out = [p.decode("ascii") for p in parts]
    for item in out:
        if "|" in item or "\t" in item:
            return None
    return out


def sha256_of(data):
    return hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------- DT table


def parse_dt_table(data, path):
    if len(data) < 32:
        die("%s 不足 32 字节，放不下 DT table 头" % path)
    magic = be32(data, 0)
    if magic != DT_MAGIC:
        die("%s: DT table magic 是 %08x，应该是 d7b7ab1e" % (path, magic),
            "确认传进来的是 dtbo 分区镜像而不是 boot/vbmeta；apply.sh 也是用这个 magic 判断的")
    hdr = {
        "total_size": be32(data, 4),
        "header_size": be32(data, 8),
        "entry_size": be32(data, 12),
        "entry_count": be32(data, 16),
        "entries_offset": be32(data, 20),
        "page_size": be32(data, 24),
        "version": be32(data, 28),
    }
    if hdr["total_size"] == 0:
        die("%s: DT table 的 total_size 是 0" % path, "镜像损坏？重新 dump 一份")
    if hdr["total_size"] > len(data):
        die("%s: DT table 声明 total_size=%d，但文件只有 %d 字节" % (path, hdr["total_size"], len(data)),
            "dump 不完整（dd 被中断）；请重新 dump")
    if hdr["header_size"] < 32 or hdr["entry_size"] < 32:
        die("%s: header_size=%d entry_size=%d，不是标准 DT table" % (path, hdr["header_size"], hdr["entry_size"]),
            "只有标准 DT table（header 32 / entry 32）才受支持")
    end_entries = hdr["entries_offset"] + hdr["entry_count"] * hdr["entry_size"]
    if end_entries > hdr["total_size"]:
        die("%s: entry 表越界（%d > total_size %d）" % (path, end_entries, hdr["total_size"]),
            "镜像损坏？重新 dump 一份")
    entries = []
    for idx in range(hdr["entry_count"]):
        off = hdr["entries_offset"] + idx * hdr["entry_size"]
        entries.append({
            "index": idx,
            "dt_size": be32(data, off),
            "dt_offset": be32(data, off + 4),
            "id": be32(data, off + 8),
            "rev": be32(data, off + 12),
        })
    return hdr, entries


# ---------------------------------------------------------------- FDT


def string_at(blob, off_strings, size_strings, nameoff, what):
    start = off_strings + nameoff
    limit = off_strings + size_strings
    if size_strings == 0 or start >= limit:
        die("%s: 属性名偏移 %d 超出字符串块（offset=%d size=%d）" % (what, nameoff, off_strings, size_strings),
            "FDT 头里的 off_dt_strings / size_dt_strings 不对，镜像可能不完整")
    end = blob.find(b"\x00", start, limit)
    if end < 0:
        die("%s: 字符串块里偏移 %d 处的属性名没有 NUL 结束" % (what, nameoff), "镜像损坏？")
    return blob[start:end].decode("utf-8", "replace")


def parse_fdt(blob, what):
    if len(blob) < 40:
        die("%s: FDT 只有 %d 字节，放不下 40 字节的 FDT 头" % (what, len(blob)))
    magic = be32(blob, 0)
    if magic != FDT_MAGIC:
        die("%s: FDT magic 是 %08x，应该是 d00dfeed" % (what, magic),
            "dt_offset 指向的位置不是 FDT；DT table entry 表可能被改过")
    info = {
        "totalsize": be32(blob, 4),
        "off_dt_struct": be32(blob, 8),
        "off_dt_strings": be32(blob, 12),
        "off_mem_rsvmap": be32(blob, 16),
        "version": be32(blob, 20),
        "last_comp_version": be32(blob, 24),
        "boot_cpuid_phys": be32(blob, 28),
        "size_dt_strings": be32(blob, 32),
        "size_dt_struct": be32(blob, 36),
    }
    if info["totalsize"] > len(blob):
        die("%s: FDT 头声明 totalsize=%d，但 entry 只有 %d 字节" % (what, info["totalsize"], len(blob)),
            "DT table entry 的 dt_size 与 FDT 头不一致，镜像损坏或被截断")
    if info["totalsize"] != len(blob):
        warn("%s: FDT totalsize=%d，DT table entry 的 dt_size=%d，两者不同" % (what, info["totalsize"], len(blob)))
    s_off = info["off_dt_struct"]
    s_size = info["size_dt_struct"]
    if s_size == 0 or s_off + s_size > len(blob):
        die("%s: 结构块越界（off=%d size=%d，blob %d 字节）" % (what, s_off, s_size, len(blob)),
            "FDT 头损坏？")
    str_off = info["off_dt_strings"]
    str_size = info["size_dt_strings"]
    if str_size == 0 or str_off + str_size > len(blob):
        die("%s: 字符串块越界（off=%d size=%d，blob %d 字节）" % (what, str_off, str_size, len(blob)),
            "FDT 头损坏？")

    nodes = []
    stack = []                                # 节点名栈（拼路径用）
    nstack = []                               # 节点对象栈（属性挂到“当前节点”，不是最后一个遇到的节点）
    pos = s_off
    end = s_off + s_size
    while True:
        if pos + 4 > end:
            die("%s: 结构块在读到 FDT_END 之前就用完了（偏移 %d）" % (what, pos), "镜像损坏？")
        tok = be32(blob, pos)
        if tok == FDT_BEGIN_NODE:
            npos = pos + 4
            stop = blob.find(b"\x00", npos, end)
            if stop < 0:
                die("%s: 节点名没有 NUL 结束（结构块偏移 %d）" % (what, pos), "镜像损坏？")
            raw = blob[npos:stop].decode("utf-8", "replace")
            name = raw.lstrip("/")            # 个别 dtbo 的节点名自带前导 /
            pos = npos + pad4(len(raw) + 1)
            stack.append(name)
            node = {
                "name": name,
                "path": "/" + "/".join(x for x in stack if x),
                "depth": len(stack) - 1,
                "props": [],
            }
            nodes.append(node)
            nstack.append(node)
        elif tok == FDT_END_NODE:
            if not stack or not nstack:
                die("%s: 结构块里 END_NODE 多于 BEGIN_NODE（偏移 %d）" % (what, pos), "镜像损坏？")
            stack.pop()
            nstack.pop()
            pos += 4
        elif tok == FDT_PROP:
            if pos + 12 > end:
                die("%s: 属性头越界（结构块偏移 %d）" % (what, pos), "镜像损坏？")
            plen = be32(blob, pos + 4)
            nameoff = be32(blob, pos + 8)
            vpos = pos + 12
            if vpos + plen > len(blob):
                die("%s: 属性值越界（偏移 %d，长度 %d，blob %d 字节）" % (what, vpos, plen, len(blob)),
                    "镜像损坏或被截断")
            pname = string_at(blob, str_off, str_size, nameoff, what)
            if nstack:
                nstack[-1]["props"].append((pname, blob[vpos:vpos + plen]))
            pos = vpos + pad4(plen)
        elif tok == FDT_NOP:
            pos += 4
        elif tok == FDT_END:
            pos += 4
            break
        else:
            die("%s: 结构块出现未知 token %08x（偏移 %d）" % (what, tok, pos),
                "结构块偏移不对，或者这不是标准 FDT")
    if stack:
        warn("%s: 读到 FDT_END 时还有 %d 层节点没结束（%s）" % (what, len(stack), "/".join(stack)))
    return info, nodes


# ---------------------------------------------------------------- AVB


def parse_avb_footer(data, off, where):
    if off < 8 or off + AVB_FOOTER_SIZE > len(data):
        die("AVB footer 偏移 %d 越界（文件 %d 字节）" % (off, len(data)))
    if data[off:off + 4] != AVB_FOOTER_MAGIC:
        die("%s: AVB footer magic 是 %s，应该是 AVBf" % (where, data[off:off + 4].hex()),
            "这个 dtbo 尾部没有 AVB（移植包常见）；没有 AVB 就生成不了 <代号>.avb 模板")
    ver_major, ver_minor = struct.unpack_from(">II", data, off + 4)
    orig, vb_off, vb_size = struct.unpack_from(">QQQ", data, off + 12)
    return {
        "offset": off,
        "version": "%d.%d" % (ver_major, ver_minor),
        "original_image_size": orig,
        "vbmeta_offset": vb_off,
        "vbmeta_size": vb_size,
    }


def find_avb_footer(data):
    """找 AVB footer。两种布局都认：
      A) footer 紧跟 vbmeta（vbmeta_offset + vbmeta_size == footer 位置）—— 仓库里 15 个 <代号>.avb 都是这种；
      B) footer 在分区最后 64 字节、vbmeta 在 vbmeta_offset 处、中间是补零 —— AVB 标准布局，真机整分区 dump 常见。
    自洽判定：vbmeta_offset 处是 AVB0、vbmeta 不越界、original_image_size <= vbmeta_offset。
    多个候选时优先 A（紧跟 vbmeta 的那个），其次取位置最靠后的。"""
    scan_start = max(0, len(data) - AVB_TAIL_SCAN)
    positions = []
    idx = data.find(AVB_FOOTER_MAGIC, scan_start)
    while idx >= 0:
        positions.append(idx)
        idx = data.find(AVB_FOOTER_MAGIC, idx + 1)
    adjacent, loose = [], []
    for off in positions:
        if off + AVB_FOOTER_SIZE > len(data):
            continue
        try:
            orig, vb_off, vb_size = struct.unpack_from(">QQQ", data, off + 12)
        except struct.error:
            continue
        if vb_size == 0 or vb_off + vb_size > len(data):
            continue
        if orig > vb_off:
            continue
        if data[vb_off:vb_off + 4] != AVB_VBMETA_MAGIC:
            continue
        (adjacent if vb_off + vb_size == off else loose).append(off)
    good = adjacent or loose
    if not good:
        return None
    last = good[-1]
    if last + AVB_FOOTER_SIZE != len(data):
        warn("AVB footer 不在文件末尾（位置 %d，文件 %d 字节）：分区比镜像大、尾部是补零" % (last, len(data)),
             "生成 .avb 模板没问题；写入时模块会按整分区处理")
    return last


def parse_vbmeta(data, footer):
    vb_off = footer["vbmeta_offset"]
    vb_size = footer["vbmeta_size"]
    if vb_off + vb_size > len(data):
        die("vbmeta 越界（offset=%d size=%d，文件 %d 字节）" % (vb_off, vb_size, len(data)),
            "footer 里的 vbmeta_offset/vbmeta_size 不对；镜像可能被改过")
    blob = data[vb_off:vb_off + vb_size]
    if len(blob) < AVB_VBMETA_HEADER_SIZE:
        die("vbmeta 只有 %d 字节，放不下 256 字节的 vbmeta 头" % len(blob))
    if blob[0:4] != AVB_VBMETA_MAGIC:
        die("vbmeta magic 是 %s，应该是 AVB0" % blob[0:4].hex(),
            "vbmeta_offset 指错地方了，或者这个镜像的 AVB 结构不是标准布局")
    req_major, req_minor, auth_size, aux_size, algo = struct.unpack_from(">IIQQI", blob, 4)
    names = ("hash_offset", "hash_size", "signature_offset", "signature_size",
             "public_key_offset", "public_key_size", "public_key_metadata_offset",
             "public_key_metadata_size", "descriptors_offset", "descriptors_size")
    values = struct.unpack_from(">10Q", blob, 32)
    head = dict(zip(names, values))
    rollback_index, flags, rollback_location = struct.unpack_from(">QII", blob, 112)
    release = blob[128:176].split(b"\x00")[0].decode("ascii", "replace")
    info = {
        "offset": vb_off,
        "size": vb_size,
        "blob": blob,
        "required_version": "%d.%d" % (req_major, req_minor),
        "auth_size": auth_size,
        "aux_size": aux_size,
        "algorithm": algo,
        "rollback_index": rollback_index,
        "flags": flags,
        "rollback_index_location": rollback_location,
        "release_string": release,
    }
    info.update(head)
    if AVB_VBMETA_HEADER_SIZE + auth_size + aux_size > vb_size:
        warn("vbmeta 头 %d + 认证块 %d + 辅助块 %d > vbmeta_size %d"
             % (AVB_VBMETA_HEADER_SIZE, auth_size, aux_size, vb_size),
             "vbmeta_size 与头里的块大小不一致，属块可能读不全")
    return info


def parse_descriptors(data, vb):
    """返回 (描述符列表, 原始起点)；描述符在辅助块里，辅助块紧跟 vbmeta 头 + 认证块"""
    aux_start = vb["offset"] + AVB_VBMETA_HEADER_SIZE + vb["auth_size"]
    start = aux_start + vb["descriptors_offset"]
    end = start + vb["descriptors_size"]
    if vb["descriptors_size"] == 0:
        return [], start
    if end > vb["offset"] + vb["size"]:
        die("描述符越界（%d..%d，vbmeta 到 %d）" % (start, end, vb["offset"] + vb["size"]),
            "vbmeta 头里的 descriptors_offset/descriptors_size 不对")
    out = []
    pos = start
    while pos + 16 <= end:
        tag, nbf = struct.unpack_from(">QQ", data, pos)
        body = pos + 16
        if body + nbf > end:
            warn("描述符 tag=%d 声明 %d 字节，超出描述符区（剩余 %d）" % (tag, nbf, end - body))
            break
        item = {"tag": tag, "num_bytes_following": nbf, "offset": pos}
        if tag == AVB_DESC_HASH:
            item.update(parse_hash_descriptor(data, body, nbf))
        elif tag == AVB_DESC_PROPERTY:
            item.update(parse_property_descriptor(data, body, nbf))
        out.append(item)
        pos = body + pad8(nbf)
    return out, start


def parse_hash_descriptor(data, body, nbf):
    """tag 2 = 哈希描述符：image_size / hash_algorithm / 三个长度 / 保留 / 分区名 / salt / digest，全部大端"""
    if nbf < 116:
        die("哈希描述符只有 %d 字节，放不下 116 字节的固定部分" % nbf)
    image_size = be64(data, body)
    algo = data[body + 8:body + 40].split(b"\x00")[0].decode("ascii", "replace")
    name_len, salt_len, digest_len, flags = struct.unpack_from(">IIII", data, body + 40)
    pos = body + 116
    if pos + name_len + salt_len + digest_len > body + nbf:
        die("哈希描述符内容越界（分区名 %d + salt %d + digest %d > %d）"
            % (name_len, salt_len, digest_len, nbf))
    name = data[pos:pos + name_len].decode("ascii", "replace")
    pos += name_len
    salt = data[pos:pos + salt_len]
    pos += salt_len
    digest = data[pos:pos + digest_len]
    return {
        "kind": "hash",
        "image_size": image_size,
        "hash_algorithm": algo,
        "partition_name": name,
        "salt": salt,
        "digest": digest,
        "flags": flags,
    }


def parse_property_descriptor(data, body, nbf):
    if nbf < 16:
        die("属性描述符只有 %d 字节，放不下 key_len/value_len" % nbf)
    key_len, value_len = struct.unpack_from(">QQ", data, body)
    if 16 + key_len + value_len > nbf:
        die("属性描述符内容越界（key %d + value %d > %d）" % (key_len, value_len, nbf))
    key = data[body + 16:body + 16 + key_len].decode("utf-8", "replace").rstrip("\x00")
    raw = data[body + 16 + key_len:body + 16 + key_len + value_len]
    return {"kind": "property", "key": key, "value": raw}


def avb_template_blob(data, footer, vb, part_size):
    """[分区大小 u64 大端][64 字节 footer][footer 里 vbmeta_size 指定的 vbmeta]，共 712 字节（vbmeta 640 时）"""
    fo = footer["offset"]
    if fo + AVB_FOOTER_SIZE > len(data):
        die("footer 不完整（位置 %d，文件 %d 字节）" % (fo, len(data)))
    if part_size <= 0:
        die("分区大小是 %d，没法写进模板首 8 字节" % part_size, "用 --partition-size 指定 dtbo 分区大小")
    if part_size < fo + AVB_FOOTER_SIZE:
        die("分区大小 %d 比镜像尾部（%d）还小" % (part_size, fo + AVB_FOOTER_SIZE),
            "分区大小给错了？用 blockdev --getsize64 重新取")
    return struct.pack(">Q", part_size) + data[fo:fo + AVB_FOOTER_SIZE] + vb["blob"]


# ---------------------------------------------------------------- .tpl 行


def tpl_row(node, prop, val):
    """返回 (类型, 新值列, 备注)；类型 w=32 位大端值列表（与仓库 .tpl 一致），s=NUL 分隔 ASCII 用 | 连接"""
    size = len(val)
    if size == 0:
        return None, None, "属性长度为 0（空属性），模板里没法表达，跳过"
    if size % 4 == 0 and size <= 8:
        return "w", ",".join(str(x) for x in u32_be(val)), None
    fields = text_fields(val)
    if fields is not None:
        return "s", "|".join(fields), None
    if size % 4 == 0:
        # 长度超过 8 且不是 ASCII（例如 div_max_curr 这种多值二进制）：按 w 输出才是真正的 no-op
        return "w", ",".join(str(x) for x in u32_be(val)), \
            "二进制数据（%d 字节），按 32 位大端值列表输出，人工确认是否应改成 s" % size
    raw = "|".join(val.split(b"\x00")).rstrip("|")
    safe = "".join(chr(b) if 0x20 <= b <= 0x7E and chr(b) not in "|\t" else "?" for b in raw.encode("latin-1"))
    return "s", safe, "长度 %d 不是 4 的倍数且不是 ASCII，按 s 转义输出（可能不对）" % size


def collect_tpl_rows(parsed_entries):
    rows = []
    index = {}
    conflicts = []
    for entry in parsed_entries:
        for node in entry["nodes"]:
            if not is_interesting(node["name"]):
                continue
            if node["path"].count("/") > 1:
                warn("关注节点 %s 是嵌套节点（%s）" % (node["name"], node["path"]),
                     "仓库 .tpl 的节点列只写节点名，dtbopatch 靠名字找节点，嵌套路径可能匹配不上，人工确认")
            for pname, val in node["props"]:
                key = (node["name"], pname)
                if key in index:
                    if index[key]["value"] != val:
                        conflicts.append((node["name"], pname, index[key]["entry"], entry["index"]))
                    continue
                typ, spec, note = tpl_row(node["name"], pname, val)
                if typ is None:
                    warn("%s/%s: %s" % (node["name"], pname, note))
                    continue
                if note:
                    warn("%s/%s: %s" % (node["name"], pname, note))
                row = {"node": node["name"], "prop": pname, "value": val, "type": typ, "spec": spec,
                       "entry": entry["index"]}
                index[key] = row
                rows.append(row)
    for node, prop, first, other in conflicts:
        warn("%s/%s 在 entry %d 与 entry %d 里值不同（多 entry dtbo 不一致）" % (node, prop, first, other),
             "模板只写第一份；写入前请确认各 entry 内容一致，否则 dtbopatch 会报 entry 结果不同")
    return rows


def emit_tpl(out_path, rows, image_path, table_sha, source_sha):
    if os.path.isdir(out_path):
        die("--emit-tpl 的路径 %s 是目录" % out_path, "请给文件名，例如 module/dtbo/8550/vermeer_os?.tpl")
    try:
        with open(out_path, "w", encoding="utf-8", newline="\n") as fp:
            fp.write("# ftd-parse.py 从 %s 生成的原厂(stock)模板，%s\n"
                     % (os.path.basename(image_path), time.strftime("%Y-%m-%d %H:%M:%S")))
            fp.write("# DT table 头部 total_size 的 sha256=%s；镜像文件 sha256=%s\n" % (table_sha, source_sha))
            fp.write("# 第 3 列是本机原厂字节的十六进制，第 5 列已填原厂值：不改占位符之前写入是 no-op\n")
            fp.write("# w = 32 位大端值列表（与 module/dtbo 现有 .tpl 一致，devicetree cell 是大端）；s = NUL 分隔的 ASCII 字段，用 | 连接\n")
            fp.write("# 需要随电流/温度/电压变化的行，请人工把对应数字换成 {I} {S} {IW} {V} {T} {L} {MQ} {LQ} {VQ} {M} / @T: @C: 等占位符\n")
            for row in rows:
                fp.write("%s\t%s\t%s\t%s\t%s\n"
                         % (row["node"], row["prop"], row["value"].hex(), row["type"], row["spec"]))
    except OSError as exc:
        die("写不了 %s: %s" % (out_path, exc), "确认目录存在、有写权限")
    return len(rows)


def emit_avb(out_path, data, footer, vb, part_size):
    if os.path.isdir(out_path):
        die("--emit-avb 的路径 %s 是目录" % out_path, "请给文件名，例如 module/dtbo/8750/miro.avb")
    blob = avb_template_blob(data, footer, vb, part_size)
    try:
        with open(out_path, "wb") as fp:
            fp.write(blob)
    except OSError as exc:
        die("写不了 %s: %s" % (out_path, exc), "确认目录存在、有写权限")
    if len(blob) != AVB_TPL_SIZE:
        warn("AVB 模板是 %d 字节，不是仓库用的 %d 字节（vbmeta_size=%d）"
             % (len(blob), AVB_TPL_SIZE, vb["size"]),
             "dtbopatch 只认 712 字节模板，请人工确认后再用")
    return blob


# ---------------------------------------------------------------- 输出


def print_header(data, image_path):
    print("=" * 72)
    print("镜像: %s" % image_path)
    print("大小: %d 字节（%.2f MiB）" % (len(data), len(data) / 1048576.0))
    print("sha256(整文件): %s" % sha256_of(data))
    print()


def print_dt_table(hdr, entries, data):
    print("[DT table 头]")
    print("  magic          : d7b7ab1e (ok)")
    print("  total_size     : %d 字节" % hdr["total_size"])
    print("  total_size sha256: %s" % sha256_of(data[:hdr["total_size"]]))
    print("                     ↑ stock.list 第一列就是它（只算 total_size 长度，与尾部 AVB 无关）")
    print("  header_size    : %d" % hdr["header_size"])
    print("  dt_entry_size  : %d" % hdr["entry_size"])
    print("  dt_entry_count : %d" % hdr["entry_count"])
    print("  entries_offset : %d" % hdr["entries_offset"])
    print("  page_size      : %d" % hdr["page_size"])
    print("  version        : %d" % hdr["version"])
    print()


def print_entry(entry, info, nodes, list_nodes):
    print("─" * 72)
    print("[entry %d]" % entry["index"])
    print("  dt_size   : %d 字节" % entry["dt_size"])
    print("  dt_offset : %d" % entry["dt_offset"])
    print("  id        : %d   rev: %d" % (entry["id"], entry["rev"]))
    print("  FDT magic : d00dfeed (ok)")
    print("  FDT totalsize: %d   version: %d   last_comp_version: %d"
          % (info["totalsize"], info["version"], info["last_comp_version"]))
    print("  off_dt_struct: %d (size %d)   off_dt_strings: %d (size %d)"
          % (info["off_dt_struct"], info["size_dt_struct"], info["off_dt_strings"], info["size_dt_strings"]))
    prop_total = sum(len(n["props"]) for n in nodes)
    hits = [n for n in nodes if is_interesting(n["name"])]
    print("  节点 %d 个，属性 %d 个，其中关注节点 %d 个" % (len(nodes), prop_total, len(hits)))
    for node in hits:
        print("  ● %s（%s）%d 项" % (node["path"], node["name"], len(node["props"])))
        for pname, val in node["props"]:
            line = "      %-38s len=%-4d hex=%s" % (pname, len(val), val.hex())
            # 数值只在“像 w”的时候打两套解码：长度 <= 8 一律打；8~16 字节仅当不是可读文本
            if len(val) % 4 == 0 and 0 < len(val) <= 16 and (len(val) <= 8 or text_fields(val) is None):
                line += "  be=%s" % ",".join(str(x) for x in u32_be(val))
                line += "  le=%s" % ",".join(str(x) for x in u32_le(val))
            print(line)
    if list_nodes:
        print("  ── 全部节点 ──")
        for node in nodes:
            mark = "*" if is_interesting(node["name"]) else " "
            print("  %s %s%s" % (mark, "  " * node["depth"], node["path"]))
    print()


def show_value(val):
    """可打印的按文本显示（去掉 NUL），否则按十六进制显示（属性描述符的值可能带 NUL 或填充）"""
    txt = val.replace(b"\x00", b"")
    try:
        s = txt.decode("ascii")
        if s and all(0x20 <= ord(ch) <= 0x7E for ch in s):
            return s
    except UnicodeDecodeError:
        pass
    return val.hex()


def print_avb(data, footer, vb, descs, tpl_blob, tpl_path, part_size):
    print("─" * 72)
    print("[AVB 尾部]")
    print("  footer 位置: %d（文件 %d 字节，距末尾 %d 字节）"
          % (footer["offset"], len(data), len(data) - footer["offset"] - AVB_FOOTER_SIZE))
    print("  footer magic: AVBf (ok)   footer 版本: %s" % footer["version"])
    print("  footer 前 8 字节（原样）: %s（仓库模板首 8 字节放的是分区大小，不是这 8 字节）"
          % data[footer["offset"] - 8:footer["offset"]].hex())
    print("  original_image_size: %d" % footer["original_image_size"])
    print("  vbmeta_offset: %d" % footer["vbmeta_offset"])
    print("  vbmeta_size  : %d" % footer["vbmeta_size"])
    print("  vbmeta magic : AVB0 (ok)   required_libavb_version: %s   release_string: %s"
          % (vb["required_version"], vb["release_string"] or "(空)"))
    print("  authentication_data_block_size: %d %s"
          % (vb["auth_size"], "→ 有签名/认证块" if vb["auth_size"] else "→ 无认证块（算法 NONE，只存哈希）"))
    print("  auxiliary_data_block_size     : %d" % vb["aux_size"])
    print("  algorithm_type                : %d%s" % (vb["algorithm"], "（0 = NONE）" if vb["algorithm"] == 0 else ""))
    print("  descriptors_offset/size       : %d / %d" % (vb["descriptors_offset"], vb["descriptors_size"]))
    print("  rollback_index: %d   flags: %d   rollback_index_location: %d"
          % (vb["rollback_index"], vb["flags"], vb["rollback_index_location"]))
    if not descs:
        print("  描述符: 无")
    for desc in descs:
        if desc["tag"] == AVB_DESC_HASH:
            print("  [tag 2 哈希描述符] 分区名=%s  算法=%s  image_size=%d  flags=%d"
                  % (desc["partition_name"], desc["hash_algorithm"], desc["image_size"], desc["flags"]))
            print("      salt  (%d 字节): %s" % (len(desc["salt"]), desc["salt"].hex() or "(空)"))
            print("      digest(%d 字节): %s" % (len(desc["digest"]), desc["digest"].hex() or "(空)"))
        elif desc["tag"] == AVB_DESC_PROPERTY:
            print("  [tag 0 属性描述符] %s = %s" % (desc["key"], show_value(desc["value"])))
        elif desc["tag"] == AVB_DESC_HASHTREE:
            print("  [tag 1 hashtree 描述符] %d 字节（dtbo 一般没有，只打印长度）"
                  % desc["num_bytes_following"])
        else:
            print("  [tag %d 描述符] %d 字节（本脚本只解读 0/1/2，其余打印长度）"
                  % (desc["tag"], desc["num_bytes_following"]))
    print()
    print("[AVB 模板]")
    print("  首 8 字节（dtbo 分区大小，大端 u64）: %d（0x%x）" % (part_size, part_size))
    print("  + 64 字节 footer + %d 字节 vbmeta = %d 字节%s"
          % (vb["size"], len(tpl_blob), "" if len(tpl_blob) == AVB_TPL_SIZE else "（注意：不是 712）"))
    print("  sha256: %s" % sha256_of(tpl_blob))
    if tpl_path:
        print("  已写入: %s" % tpl_path)
    print()


def print_summary(rows, tpl_path, avb_path):
    print("=" * 72)
    if tpl_path:
        print("模板: %s（%d 行）" % (tpl_path, len(rows)))
        print("  下一步: 人工过一遍，把随电流/温度变化的数字换成 {I}/{V}/{T}/{L} 等占位符，")
        print("          再放进 module/dtbo/<SOC>/，并在 module/dtbo/stock.list 里加一行")
        print("          （<DT table sha256>  <代号>  <模板名>  <原厂系统版本>）")
    if avb_path:
        print("AVB : %s" % avb_path)
    if WARNED:
        print()
        print("需要人工确认 %d 项:" % len(WARNED))
        for line in WARNED:
            print("  - %s" % line)


# ---------------------------------------------------------------- main


def resolve_part_size(args, data, footer):
    """模板首 8 字节 = dtbo 分区大小：整分区 dump 时就是文件大小，裁剪过的镜像要手动 --partition-size"""
    if args.partition_size is not None:
        if args.partition_size <= 0:
            die("--partition-size 必须是正整数（字节）", "手机上用 blockdev --getsize64 /dev/block/by-name/dtbo 取")
        if args.partition_size < footer["offset"] + AVB_FOOTER_SIZE:
            die("--partition-size=%d 比镜像尾部（%d）还小"
                % (args.partition_size, footer["offset"] + AVB_FOOTER_SIZE), "分区大小给错了？")
        return args.partition_size
    size = len(data)
    if footer["offset"] + AVB_FOOTER_SIZE == size:
        warn("镜像正好在 footer 处结束（%d 字节），模板首 8 字节按镜像大小填" % size,
             "如果这不是整分区 dump（被裁剪过），请用 --partition-size 指定真实 dtbo 分区大小")
    return size


def build_parser():
    parser = argparse.ArgumentParser(
        prog="ftd-parse.py",
        description="小米 dtbo.img 解析 / 原厂(stock)模板生成（只读，不改分区、不改仓库）",
        epilog="示例: python ftd-parse.py dtbo.img --emit-tpl vermeer_os4.tpl --emit-avb vermeer.avb")
    parser.add_argument("image", help="dtbo 分区镜像（例如手机 k70-probe.sh dump 出来的 dtbo.img）")
    parser.add_argument("--emit-tpl", metavar="out.tpl", help="写原厂 stock 模板（仓库 .tpl 行格式）")
    parser.add_argument("--emit-avb", metavar="out.avb", help="写 712 字节 AVB 模板（8 + footer + vbmeta）")
    parser.add_argument("--list-nodes", action="store_true", help="额外列出镜像里所有节点")
    parser.add_argument("--partition-size", type=int, metavar="N",
                        help="dtbo 分区大小（字节）；不给就按镜像文件大小（整分区 dump 时是对的）")
    return parser


def main(argv):
    if len(argv) == 1:
        sys.stderr.write("! 缺少镜像参数\n  用法: python ftd-parse.py <dtbo.img> [--emit-tpl out.tpl] [--emit-avb out.avb]\n")
        return 1
    args = build_parser().parse_args(argv[1:])
    data = read_image(args.image)
    table_sha = None
    source_sha = sha256_of(data)

    print_header(data, os.path.abspath(args.image))
    hdr, entries = parse_dt_table(data, args.image)
    table_sha = sha256_of(data[:hdr["total_size"]])
    print_dt_table(hdr, entries, data)
    if not entries:
        die("%s: DT table 里一个 entry 都没有" % args.image, "镜像损坏？")

    parsed = []
    for entry in entries:
        off = entry["dt_offset"]
        size = entry["dt_size"]
        if off + size > len(data):
            die("entry %d 越界（offset=%d size=%d，文件 %d 字节）"
                % (entry["index"], off, size, len(data)), "镜像被截断？请重新 dump")
        if off == 0:
            warn("entry %d 的 dt_offset 是 0，与 DT table 头重叠" % entry["index"])
        what = "entry %d" % entry["index"]
        info, nodes = parse_fdt(data[off:off + size], what)
        print_entry(entry, info, nodes, args.list_nodes)
        parsed.append({"index": entry["index"], "nodes": nodes})

    footer_off = find_avb_footer(data)
    tpl_rows = []
    tpl_written = None
    avb_written = None
    if footer_off is None:
        warn("没有找到 AVB footer（最后 %d 字节里没有自洽的 AVBf）" % AVB_TAIL_SCAN,
             "移植包/官改包的 dtbo 可能没有 AVB：只能生成 .tpl，<代号>.avb 需要从原厂包里的 dtbo 提取")
    else:
        footer = parse_avb_footer(data, footer_off, "AVB footer")
        vb = parse_vbmeta(data, footer)
        descs, _ = parse_descriptors(data, vb)
        part_size = resolve_part_size(args, data, footer)
        tpl_blob = avb_template_blob(data, footer, vb, part_size)
        if args.emit_avb:
            emit_avb(args.emit_avb, data, footer, vb, part_size)
            avb_written = args.emit_avb
        print_avb(data, footer, vb, descs, tpl_blob, avb_written, part_size)

    tpl_rows = collect_tpl_rows(parsed)
    if args.emit_tpl:
        count = emit_tpl(args.emit_tpl, tpl_rows, args.image, table_sha, source_sha)
        tpl_written = args.emit_tpl
        if count == 0:
            warn("模板一行都没生成：镜像里没有找到关注节点",
                 "先在手机上跑 tools/k70-probe.sh，把 report.txt 发回来确认节点名")
    print_summary(tpl_rows, tpl_written, avb_written)
    if footer_off is None and args.emit_avb:
        die("没有 AVB footer，--emit-avb 没有东西可写",
            "从原厂卡刷包里的 dtbo.img 提取（原厂镜像才有 AVB）")
    return 2 if WARNED else 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass
    sys.exit(main(sys.argv))
