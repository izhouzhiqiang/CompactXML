
## 3.1 课题所实施的解决方案介绍

### 3.1.1 总体设计思路

本文针对 XML 数据在数据库中的两个实际矛盾展开研究：

一方面，XML 具有明显的结构重复性。同一文档中，大量节点会反复出现相同的标签、路径和短文本值。如果每次都以完整 XML 文本保存，则路径标签、开始标签和结束标签会被重复存储，造成较大的结构性冗余。

另一方面，如果仅采用通用文本压缩方法对 XML 进行压缩，虽然可以获得较高的压缩比，但压缩后的数据通常不能直接查询。数据库在执行查询时，往往需要逐行解压、重新解析 XML，并重新识别路径和文本内容，导致查询过程产生较大开销。

因此，本文采用的不是单纯面向文本字节串的压缩方案，而是面向 XML 结构和查询需求的结构感知压缩方法。其核心思想是：

1. 先解析 XML 的树形结构；
2. 将 XML 中重复出现的路径和文本值转换为可复用的整数标识；
3. 将结构信息、路径信息和内容信息分开组织；
4. 在压缩编码过程中形成的路径 ID 和 token ID，不仅用于压缩存储，还继续用于路径查询、内容查询和 GIN 索引键提取；
5. 对查询产生的候选结果进行精确验证，保证压缩和索引过程不会改变查询语义。

整体处理流程如下：

```text
XML 文本
   │
   ▼
XML 语义解析
   │
   ├── 构建节点结构记录
   └── 构建路径—文本记录
          │
          ▼
路径字典与文本字典编码
          │
          ├── 生成文档序内容流
          ├── 生成路径索引
          ├── 生成 Bloom Filter
          ├── 生成长文本内联区
          └── 生成前序结构流
          │
          ▼
序列化为 CompactXML 二进制值
          │
          ├── 解码并恢复 XML
          ├── 执行路径存在查询
          ├── 执行精确内容查询
          ├── 执行路径取值查询
          └── 提取 GIN 索引键
```

本文方法的关键不在于单独提出一种全新的字典编码、Varint、Bloom Filter 或 GIN 索引，而在于将 XML 编码过程中产生的中间信息组织成一个可以被多个后续环节共同使用的表示。

也就是说，同一组路径 ID 和文本 ID 同时服务于：

- 压缩存储；
- XML 解码；
- 路径查询；
- 内容查询；
- Bloom Filter 构建；
- PostgreSQL GIN 索引键提取。

这种“编码中间数据复用”是本文方案的主要方法主线。

---

### 3.1.2 XML 解析与语义中间表示

#### 3.1.2.1 XML 树结构解析

系统首先使用 XML 解析器读取输入文档，并按照 XML 的嵌套结构构建逻辑节点树。

例如，输入 XML 为：

```xml
<orders>
    <order>
        <id>1001</id>
        <customer>张三</customer>
        <item>
            <name>机械键盘</name>
            <quantity>2</quantity>
        </item>
        <item>
            <name>鼠标</name>
            <quantity>1</quantity>
        </item>
    </order>
</orders>
```

解析过程中，系统维护一个当前路径栈：

```text
/orders
/orders/order
/orders/order/id
/orders/order/customer
/orders/order/item
/orders/order/item/name
/orders/order/item/quantity
```

当解析器遇到开始标签时，将标签压入路径栈；遇到结束标签时，将标签从路径栈弹出。对于叶节点，解析器将当前完整路径与文本内容组合成一条内容记录。

例如，上述 XML 可以转换为如下文档序内容记录：

```text
(
  /orders/order/id,                 1001
  /orders/order/customer,           张三
  /orders/order/item/name,          机械键盘
  /orders/order/item/quantity,      2
  /orders/order/item/name,          鼠标
  /orders/order/item/quantity,      1
)
```

这里保留了 XML 中叶节点的出现顺序。顺序信息非常重要，因为它用于：

- 保证解码后的 XML 节点顺序正确；
- 支持路径取值操作；
- 处理同一路径多次出现的情况；
- 避免将 XML 结构误认为简单的无序键值表。

#### 3.1.2.2 两类语义记录

为了同时满足压缩、查询和解码需求，本文将 XML 解析结果组织为两类中间记录。

第一类是文档序叶节点记录：

\[
R_D=\langle(p_1,v_1),(p_2,v_2),\ldots,(p_n,v_n)\rangle
\]

其中：

- \(p_i\) 表示第 \(i\) 条叶节点记录的完整路径；
- \(v_i\) 表示对应的文本值；
- 记录顺序与 XML 文档中的出现顺序一致；
- \(n\) 表示叶节点文本记录总数。

例如：

```text
R_D =
[
  ("/orders/order/id", "1001"),
  ("/orders/order/customer", "张三"),
  ("/orders/order/item/name", "机械键盘"),
  ("/orders/order/item/quantity", "2"),
  ("/orders/order/item/name", "鼠标"),
  ("/orders/order/item/quantity", "1")
]
```

第二类是前序结构记录：

\[
T_D=\langle(t_1,c_1),(t_2,c_2),\ldots,(t_m,c_m)\rangle
\]

其中：

- \(t_j\) 表示第 \(j\) 个 XML 节点的路径；
- \(c_j\) 表示该节点的直接子节点数量；
- 记录按照 XML 树的前序遍历顺序排列；
- \(m\) 表示 XML 节点总数。

例如，部分结构信息可以表示为：

```text
(
  /orders,                       child_count = 1
  /orders/order,                 child_count = 4
  /orders/order/id,              child_count = 0
  /orders/order/customer,        child_count = 0
  /orders/order/item,            child_count = 2
  /orders/order/item/name,       child_count = 0
  /orders/order/item/quantity,   child_count = 0
  /orders/order/item,            child_count = 2
  /orders/order/item/name,       child_count = 0
  /orders/order/item/quantity,   child_count = 0
)
```

叶节点的 `child_count=0` 与内容流中的下一条叶内容记录对应。解码器根据前序结构流重新确定元素的开始、结束和嵌套关系，再按照内容流顺序填充叶节点文本。

这样做的原因是：

> 仅保存路径—文本对，可以支持部分查询，但不足以完整恢复 XML 树的节点边界和嵌套结构；仅保存结构流，又无法直接完成内容查询。因此，本文同时保存内容流和结构流。

---

### 3.1.3 路径字典与文本字典编码

#### 3.1.3.1 路径字典

XML 文档中相同路径通常会出现多次。例如：

```text
/orders/order/item/name
/orders/order/item/quantity
```

这些完整路径如果以字符串形式反复写入，会带来较大的重复开销。因此，系统为不同路径建立路径字典：

```text
路径字符串                         path_id
------------------------------------------------
/orders                             1
/orders/order                      2
/orders/order/id                   3
/orders/order/customer             4
/orders/order/item                 5
/orders/order/item/name            6
/orders/order/item/quantity        7
```

路径在当前字典作用域内只分配一次 ID。之后，内容流、结构流和路径索引都使用 `path_id` 表示路径。

路径字典需要同时提供两个方向的映射：

```text
路径字符串  ───────► path_id
path_id     ───────► 路径字符串
```

前者用于查询输入的路径转换，后者用于 XML 解码和调试输出。

#### 3.1.3.2 文本值字典

对于长度较短、重复度较高的文本值，系统建立文本值字典：

```text
文本值             token_id
----------------------------
1001               1
张三               2
机械键盘           3
2                  4
鼠标               5
1                  6
```

内容流中的文本不再保存完整字符串，而保存对应的 `token_id`。

例如：

```text
原始内容记录：

("/orders/order/id", "1001")
("/orders/order/customer", "张三")
("/orders/order/item/name", "机械键盘")
("/orders/order/item/quantity", "2")

转换后：

(path_id=3, token_id=1)
(path_id=4, token_id=2)
(path_id=6, token_id=3)
(path_id=7, token_id=4)
```

路径字典和文本字典采用两个相互独立的 ID 空间，避免路径和文本值在语义上发生混淆。

#### 3.1.3.3 长文本处理

对于长度小于 1024 字节的短文本，系统优先使用共享文本字典。

对于长度达到或超过阈值的长文本，不直接写入全局短文本字典，而是采用：

```text
长文本
  │
  ├── 计算 32 位哈希值
  ├── 生成带类型标记的候选 ID
  └── 将原始长文本写入当前文档的内联区
```

长文本的哈希值只作为候选标识，不能直接作为最终语义判断依据。

例如，两个长文本可能出现哈希冲突：

```text
hash("长文本 A") = 123456
hash("长文本 B") = 123456
```

因此，查询时必须执行：

1. 通过哈希 ID 找到候选；
2. 从内联区取出原始字符串；
3. 对原始字符串进行精确比较；
4. 只有精确比较相等时，才确认查询命中。

当前实现对同一文档内检测到的长文本哈希冲突会拒绝该文档；跨文档冲突则通过查询阶段的精确 recheck 处理。

---

### 3.1.4 Varint 变长整数编码

由于路径和文本已经转换为整数 ID，因此可以进一步使用 Varint 对整数进行编码。

Varint 将一个整数拆分为若干组，每组使用 7 个有效数据位，最高位用于表示后续是否仍有数据：

```text
┌───────┬───────┬───────┬───────┐
│ 1 bit │ 7 bit │ 1 bit │ 7 bit │ ...
│续位标记│数据位 │续位标记│数据位 │
└───────┴───────┴───────┴───────┘
```

当 ID 较小时，一个 ID 通常只需要一个字节或少量字节即可表示，相比固定使用 4 字节整数，可以减少内容区空间。

内容流中每条记录逻辑上表示为：

```text
varint(path_id) + varint(token_id)
```

例如：

```text
(path_id=3, token_id=1)
(path_id=4, token_id=2)
(path_id=6, token_id=3)
```

可能被编码为：

```text
03 01 04 02 06 03
```

实际字节数取决于 ID 的大小。Varint 只改变整数的二进制表示方式，不改变路径 ID 和 token ID 的语义。

---

### 3.1.5 二进制存储布局

本文自定义 XML 类型在 PostgreSQL 中以一个自描述的二进制值保存。其逻辑布局如下：

```text
┌──────────────────────────────────────┐
│ PostgreSQL varlena header             │
│ 4 bytes                              │
├──────────────────────────────────────┤
│ CXHeader                             │
│ 32 bytes                             │
│ version / flags / dictionary / size  │
│ content_offset / path_index_offset  │
│ bloom_offset / bloom_size            │
├──────────────────────────────────────┤
│ Sorted Path Index                    │
│ path_id -> pair_count                │
├──────────────────────────────────────┤
│ Document-order Content Section       │
│ varint(path_id) + varint(token_id)  │
├──────────────────────────────────────┤
│ Optional Inline Token Section        │
│ 长文本哈希、长度和原始字节           │
├──────────────────────────────────────┤
│ Bloom Filter Section                 │
│ 参数、位数组                         │
├──────────────────────────────────────┤
│ Preorder Structure Section           │
│ 节点数量、path_id、child_count       │
└──────────────────────────────────────┘
```

各区段的逻辑长度可以表示为：

\[
L_{\text{total}}
=
L_{\text{varlena}}
+
L_{\text{header}}
+
L_{\text{path}}
+
L_{\text{content}}
+
L_{\text{inline}}
+
L_{\text{bloom}}
+
L_{\text{structure}}
\]

其中：

\[
L_{\text{varlena}}=4
\]

\[
L_{\text{header}}=32
\]

若文档中存在 \(P\) 个不同路径，则当前路径索引的逻辑长度为：

\[
L_{\text{path}}=4+8P
\]

内容区长度为：

\[
L_{\text{content}}
=
\sum_{i=1}^{N}
\left(
\operatorname{lenVarint}(path\_id_i)
+
\operatorname{lenVarint}(token\_id_i)
\right)
\]

其中 \(N\) 为叶节点内容记录数。

结构区长度为：

\[
L_{\text{structure}}
=
4+
\sum_{j=1}^{M}
\left(
\operatorname{lenVarint}(path\_id_j)
+
\operatorname{lenVarint}(child\_count_j)
\right)
\]

其中 \(M\) 为 XML 节点总数。

Bloom Filter 的长度可表示为：

\[
L_{\text{bloom}}
=
L_{\text{bloom-header}}
+
\left\lceil \frac{m}{8}\right\rceil
\]

其中：

- \(m\) 为 Bloom Filter 位数组的位数；
- \(m\) 至少满足当前实现设定的最小容量；
- 位数组每 8 位占用 1 字节。

长文本内联区的长度为：

\[
L_{\text{inline}}
=
\sum_{r=1}^{Q}
\left(
L_{\text{fixed-field}}
+
\operatorname{lenVarint}(len_r)
+
len_r
\right)
\]

其中：

- \(Q\) 为当前文档中的长文本数量；
- \(len_r\) 为第 \(r\) 个长文本的字节长度；
- `fixed-field` 包括哈希标识和必要的记录元数据。

这里需要说明，以上是逻辑二进制布局，不等同于 PostgreSQL 数据页、TOAST 页面和索引页的物理布局。数据库层面的完整空间还包括：

- PostgreSQL 行头；
- 对齐填充；
- TOAST 存储；
- GIN 索引；
- 共享字典表；
- 表和索引的页面管理开销。

因此，论文中应分别报告“压缩列值大小”和“完整 relation 大小”，不能将二者混为一个指标。

---

### 3.1.6 XML 写入与压缩编码流程

XML 写入过程可以分为以下几个阶段。

#### 阶段一：解析 XML

系统读取 XML 文本，构建节点栈，并记录：

- 当前路径；
- 节点父子关系；
- 子节点数量；
- 叶节点文本；
- 文档顺序。

#### 阶段二：构建语义中间记录

解析结果被转换为：

```text
LeafRecords:
    [(path, value), ...]

StructureRecords:
    [(path, child_count), ...]
```

#### 阶段三：字典查找和 ID 分配

对每条路径执行路径字典查找；对每个短文本执行 token 字典查找。

如果字典中不存在，则分配新的 ID；如果已经存在，则直接复用旧 ID。

#### 阶段四：构建辅助信息

在编码内容流的同时，构建：

- 路径出现次数；
- token ID 集合；
- Bloom Filter；
- 长文本内联表；
- 前序结构流。

#### 阶段五：序列化

根据各区段长度计算偏移量，将头部、路径索引、内容流、内联区、Bloom 区和结构流连续写入一块内存缓冲区，最后形成 PostgreSQL 自定义类型值。

伪代码如下：

```text
function encode_xml(xml_text):

    # 1. 解析 XML
    nodes, leaf_records = parse_xml(xml_text)

    # nodes:
    #   [(path, child_count), ...]
    #
    # leaf_records:
    #   [(path, value), ...]，保持文档顺序

    content_pairs = []
    path_pair_count = {}
    token_ids = set()
    inline_tokens = {}

    # 2. 编码节点结构中出现的路径
    for node in nodes:
        path_id = path_dict.lookup_or_assign(node.path)
        node.path_id = path_id

    # 3. 编码叶节点路径和值
    for path, value in leaf_records:

        path_id = path_dict.lookup_or_assign(path)

        if utf8_length(value) < 1024:
            token_id = token_dict.lookup_or_assign(value)

        else:
            hash_id = make_long_token_hash(value)
            token_id = mark_as_inline_token(hash_id)

            if hash_id in inline_tokens:
                if inline_tokens[hash_id] != value:
                    reject("long token hash collision")
            else:
                inline_tokens[hash_id] = value

        append(content_pairs, (path_id, token_id))

        path_pair_count[path_id] += 1
        token_ids.add(token_id)

    # 4. 构建文档级辅助结构
    path_index = sort_by_path_id(path_pair_count)
    bloom = build_bloom_filter(token_ids)
    structure_stream = encode_structure(nodes)

    # 5. 计算各区段长度和偏移
    offsets = calculate_offsets(
        path_index,
        content_pairs,
        inline_tokens,
        bloom,
        structure_stream
    )

    # 6. 序列化为自定义二进制值
    binary_value = serialize(
        header=build_header(offsets),
        path_index=path_index,
        content=encode_varint_pairs(content_pairs),
        inline_tokens=encode_inline_tokens(inline_tokens),
        bloom=bloom,
        structure=structure_stream
    )

    return binary_value
```

这个过程的关键是：路径和值在解析、编码阶段完成语义识别后，不再由查询阶段重新从 XML 字符串中解析一遍。

---

### 3.1.7 查询处理方案

本文主要实现三类查询操作：

1. 精确内容查询；
2. 路径存在性查询；
3. 路径值获取查询。

这些查询均直接作用于压缩表示，而不是先把二进制值还原为完整 XML 文本。

---

#### 3.1.7.1 精确内容查询

精确内容查询用于判断某个文本值是否出现在当前 XML 文档中。

例如：

```text
查询 token：机械键盘
```

执行流程为：

```text
查询字符串
   │
   ▼
token 字典查找
   │
   ├── 未找到：返回不存在
   │
   ▼
Bloom Filter 判断
   │
   ├── 明确不存在：返回 false
   │
   └── 可能存在：继续扫描内容流
          │
          ▼
解码 path_id/token_id
          │
          ▼
精确 token 比较
          │
          ├── 短 token：比较 token_id
          └── 长 token：取内联原文比较
```

伪代码如下：

```text
function xml_contains(compact_value, query_text):

    # 1. 查询值转换为 token_id
    token_info = token_dict.lookup(query_text)

    if token_info.not_found:
        return false

    query_token_id = token_info.token_id

    # 2. Bloom Filter 只负责快速否定
    if compact_value.has_bloom:
        if bloom_might_contain(compact_value.bloom,
                               query_token_id) == false:
            return false

    # 3. 对 Bloom 的阳性结果进行精确验证
    for path_id, token_id in scan_content_stream(compact_value):

        if token_id == query_token_id:

            if is_inline_token(token_id):
                original_value = read_inline_token(
                    compact_value,
                    token_id
                )

                if original_value == query_text:
                    return true

            else:
                return true

    return false
```

Bloom Filter 的返回结果只能解释为：

```text
false  ：可以确定不存在
true   ：可能存在，仍需精确验证
```

因此，Bloom Filter 不直接决定最终查询结果，而是用于减少明显不存在的文档扫描。

---

#### 3.1.7.2 路径存在查询

路径存在查询用于判断文档中是否存在指定路径。

例如：

```text
xml_exists(xml_value, "/orders/order/item/name")
```

路径存在查询不需要扫描完整内容流，而是首先将查询路径转换为 `path_id`，然后在排序路径索引中进行二分查找。

```text
查询路径
   │
   ▼
路径字典查找 path_id
   │
   ├── 未找到：返回 false
   │
   ▼
Sorted Path Index 二分查找
   │
   ├── 找到：返回 true
   └── 未找到：返回 false
```

伪代码如下：

```text
function xml_exists(compact_value, query_path):

    path_info = path_dict.lookup(query_path)

    if path_info.not_found:
        return false

    target_path_id = path_info.path_id

    entry = binary_search(
        compact_value.path_index,
        target_path_id
    )

    return entry != NOT_FOUND
```

路径索引的特点是：

- 内容流仍然按照 XML 文档顺序保存；
- 路径索引单独按照 `path_id` 排序；
- 路径索引只保存路径和出现次数；
- 不强制改变内容流的原始顺序。

这样可以同时保留 XML 顺序信息和路径查找能力。

---

#### 3.1.7.3 路径取值查询

路径取值查询用于获取指定路径下的文本值。

例如：

```text
xml_get(xml_value, "/orders/order/item/name")
```

执行过程为：

1. 将路径字符串转换为 `path_id`；
2. 使用路径索引确认路径是否存在；
3. 按文档顺序扫描内容流；
4. 找到匹配路径的 token；
5. 将 token ID 反查为文本；
6. 对长文本执行内联区读取。

伪代码如下：

```text
function xml_get(compact_value, query_path):

    path_info = path_dict.lookup(query_path)

    if path_info.not_found:
        return NULL

    target_path_id = path_info.path_id

    if binary_search(
        compact_value.path_index,
        target_path_id
    ) == NOT_FOUND:
        return NULL

    for path_id, token_id in scan_content_stream(compact_value):

        if path_id != target_path_id:
            continue

        if is_inline_token(token_id):
            return read_inline_token(
                compact_value,
                token_id
            )
        else:
            return token_dict.reverse_lookup(token_id)

    return NULL
```

当前实现按文档序返回第一个匹配值。对于同一路径出现多次的情况，后续可以扩展为返回值集合，但这需要进一步明确 SQL 函数的返回类型和多值语义。

---

### 3.1.8 GIN 索引接入方案

文档内部查询和跨文档查询具有不同的处理范围：

- Bloom Filter 和路径索引负责单个 XML 值内部的快速判断；
- GIN 负责在数据库表中快速定位可能包含目标 token 的行。

因此，本文将内容 token ID 提取为 GIN 索引键。

#### 3.1.8.1 GIN 建索引阶段

GIN 建索引时，`extractValue` 回调从压缩内容流中读取 token ID：

```text
function gin_extract_value(compact_value):

    keys = empty_set()

    for path_id, token_id in scan_content_stream(compact_value):
        add(keys, token_id)

    return sort_and_deduplicate(keys)
```

这里的索引键不是原始文本字符串，而是经过文本字典编码后的 `token_id`。

这样做的好处是：

- GIN 索引键空间较小；
- 相同文本在不同 XML 文档中复用同一个 ID；
- 索引构建时不需要重新解析 XML 文本；
- 查询和索引使用同一套 token 映射规则。

#### 3.1.8.2 GIN 查询阶段

查询条件中的文本值先通过同一个 token 字典转换为查询 ID：

```text
function gin_extract_query(query_text):

    token_info = token_dict.lookup(query_text)

    if token_info.not_found:
        return EMPTY_QUERY

    return token_info.token_id
```

GIN 根据 token ID 找到候选行后，仍然需要执行操作符精确复核。

```text
function gin_consistent(candidate_row, query_text):

    if gin_key_is_absent(candidate_row):
        return false

    # GIN 只说明该行可能命中
    return NEED_RECHECK
```

最终由 `xml_contains` 对候选行进行精确验证：

```text
GIN 候选行
   │
   ▼
xml_contains 精确复核
   │
   ├── token ID 精确匹配
   ├── 长文本读取内联值
   └── 必要时进行原始字符串比较
```

因此，GIN 的职责是缩小候选行集合，而不是替代 XML 内容语义判断。

对于长文本，由于哈希 ID 可能发生跨文档碰撞，GIN 可能返回额外候选行。但这些候选行会在堆表访问阶段进行精确 recheck，从而避免错误返回。

---

### 3.1.9 XML 解码与正确性保证

为了保证压缩过程不改变 XML 语义，系统在解码时同时读取结构流和内容流。

解码过程如下：

```text
读取结构流
   │
   ▼
读取当前节点 path_id 和 child_count
   │
   ├── child_count > 0：创建容器节点
   └── child_count = 0：消费下一条内容记录
          │
          ▼
根据 path_id 恢复路径
          │
          ▼
根据 token_id 恢复文本
          │
          ▼
重新构造 XML 节点
```

伪代码如下：

```text
function decode_xml(compact_value):

    structure_records = read_structure_stream(compact_value)
    content_cursor = open_content_stream(compact_value)

    root = create_document_root()

    for node in structure_records:

        path = path_dict.reverse_lookup(node.path_id)

        if node.child_count > 0:
            current = create_container_node(path)
            attach_to_parent(current)

        else:
            path_id, token_id = next(content_cursor)

            if path_id != node.path_id:
                raise DecodeError("structure/content mismatch")

            value = decode_token(compact_value, token_id)
            leaf = create_leaf_node(path, value)
            attach_to_parent(leaf)

    return serialize_as_xml(root)
```

方法正确性依赖以下约束：

1. 同一个字典作用域内，同一个路径对应唯一 `path_id`；
2. 同一个短文本对应唯一 `token_id`；
3. 结构流中的叶节点顺序与内容流中的叶记录顺序一致；
4. 内容流中的路径 ID 与结构流对应叶节点的路径 ID 一致；
5. Bloom Filter 只用于确定性否定，不用于直接确认命中；
6. 长文本哈希只生成候选，最终必须进行原文比较；
7. 每个二进制区段的偏移量和长度必须与头部记录一致；
8. 解码结束时，结构流和内容流必须同时消费完毕。

在当前实验中，通过结构差分、独立查询预言机和回归测试验证了这些约束在已测数据范围内的可实现性。

---

### 3.1.10 PostgreSQL 工程实现

本文在 PostgreSQL 中实现自定义 XML 压缩类型，并通过扩展接口提供数据库访问能力。

工程上主要包括以下模块：

```text
┌─────────────────────────────────────┐
│ SQL / 用户查询层                    │
├─────────────────────────────────────┤
│ XML 查询函数与操作符                │
│ xml_contains / xml_exists / xml_get │
├─────────────────────────────────────┤
│ 自定义类型输入输出                  │
│ XML 文本 ↔ 二进制值                 │
├─────────────────────────────────────┤
│ 编码与解码模块                      │
│ 字典、Varint、结构流、内联区         │
├─────────────────────────────────────┤
│ 查询辅助结构                        │
│ Path Index / Bloom Filter            │
├─────────────────────────────────────┤
│ GIN 操作类                          │
│ extractValue / extractQuery         │
│ consistent / recheck                │
├─────────────────────────────────────┤
│ PostgreSQL 存储与索引层             │
└─────────────────────────────────────┘
```

在写入过程中：

1. PostgreSQL 接收到 XML 文本；
2. 自定义类型输入函数调用 XML 解析和编码模块；
3. 字典模块完成路径和值 ID 分配；
4. 编码模块生成二进制值；
5. PostgreSQL 将该值作为自定义类型存储；
6. 如果建立 GIN 索引，则由 GIN 操作类从压缩值中提取 token ID。

在查询过程中：

1. SQL 函数接收路径或文本查询条件；
2. 字典模块将查询字符串转换为 ID；
3. 查询函数访问路径索引、Bloom Filter 或内容流；
4. GIN 先返回候选行；
5. 自定义操作符执行精确复核；
6. 将查询结果返回给 PostgreSQL 执行器。

共享字典由 PostgreSQL 表保存，内存中维护缓存。字典缓存可以减少重复的系统表访问，但字典 ID 的有效范围由当前字典生命周期决定，不应被理解为永久固定的跨数据库 ID。

---

### 3.1.11 方案的工程特点

与直接保存 XML 文本或先进行通用压缩再查询相比，本文方案具有以下特点：

#### 第一，压缩对象是 XML 的结构表示，而不是普通文本字节流

系统利用 XML 中重复出现的路径和文本值，将结构冗余转换为整数标识，避免反复保存相同的标签和路径字符串。

#### 第二，压缩编码结果能够直接参与查询

查询阶段可以直接读取路径索引、Bloom Filter 和 Varint 内容流，不必每次都恢复完整 XML 文本。

#### 第三，编码中间信息被多次复用

同一组路径 ID 和 token ID 同时用于：

- 内容压缩；
- 路径索引；
- Bloom Filter；
- XML 查询函数；
- GIN 索引键；
- XML 解码。

#### 第四，近似结构只负责减少查询工作，不负责改变最终语义

Bloom Filter 和哈希 ID 只用于排除或生成候选。最终结果仍由内容流扫描、字典比较或原始字符串 recheck 确认。

#### 第五，文档内索引和跨文档索引分工明确

- Path Index：解决单个 XML 文档中的路径存在性判断；
- Bloom Filter：解决单个 XML 文档中 token 的快速否定；
- GIN：解决多个数据库行之间的候选文档定位；
- 内容流：承担最终精确验证和路径取值。

这种分层结构使不同索引结构不必重复保存完整 XML 文本，也减少了查询阶段重复解析 XML 的工作。

---

### 3.1.12 当前工程实现边界

本文原型主要用于验证结构感知压缩、编码中间数据复用和查询处理方法。当前实现优先支持元素路径、叶节点文本、路径存在、精确内容包含和路径取值等操作，并通过 PostgreSQL 自定义类型和 GIN 操作类完成数据库接入。

需要说明的是，当前原型对输入文档和查询形式仍有工程约束，例如：

- 输入采用 UTF-8 编码；
- 对 XML 节点深度设置上限；
- 当前编码契约主要围绕元素路径和文本节点建立；
- 属性、命名空间、DTD、注释、处理指令、混合内容等复杂结构尚未全部纳入当前二进制布局；
- 当前查询重点是 XPath 1.0 风格的路径存在、路径取值和精确内容操作，并非对所有 XPath 表达式进行统一优化。

这些约束是当前原型的实现边界，不改变本文方法的研究目标。本文关注的是：在 XML 数据进入数据库后，如何通过结构感知编码和编码中间数据复用，同时获得压缩表示、查询处理和索引构建能力。

---

## 3.1.13 方案总结

本文实施的解决方案可以概括为：

```text
XML 结构解析
    ↓
路径与文本语义抽取
    ↓
路径字典和文本字典编码
    ↓
生成结构流与文档序内容流
    ↓
派生路径索引和 Bloom Filter
    ↓
封装为自描述二进制值
    ↓
查询函数和 GIN 复用相同编码标识
    ↓
候选过滤后进行精确验证
    ↓
恢复 XML 或返回查询结果
```

因此，本文方案并非将 XML 先压缩成普通不可查询的字节串，而是将 XML 的树形结构、路径信息和文本内容转换为一种面向数据库操作的压缩表示。该表示在降低结构冗余的同时，保留了查询所需的路径、内容和顺序信息，使压缩结果能够直接参与 XML 查询和索引处理。

从工程角度看，本文方案的核心价值在于：

> 在不完全恢复原始 XML 文本的情况下，复用压缩编码阶段已经生成的结构和内容标识，完成路径判断、内容过滤、路径取值以及跨文档索引候选定位。

这也是本文方法与“先压缩、查询时再完整解压解析”的普通压缩方案之间的主要区别。