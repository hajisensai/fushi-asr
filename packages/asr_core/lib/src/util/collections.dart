/// 集合比较工具：只为替掉 `package:flutter/foundation.dart` 的 [listEquals]，
/// 语义与它逐字一致（含 null 与 identical 短路），不引入 `package:collection`。
library;

/// 两个列表逐元素相等（`==`）时为 true；两个都是 null 也算相等。
bool listEquals<T>(List<T>? a, List<T>? b) {
  if (a == null) return b == null;
  if (b == null || a.length != b.length) return false;
  if (identical(a, b)) return true;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
