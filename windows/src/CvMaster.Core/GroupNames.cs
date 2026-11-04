/**
 * 分组名称的唯一性语义；UI 预检与存储层共用，避免两套大小写 / 宽度规则给出不同结果。
 * @author helele
 * @since 2026-11-04
 */
using System.Globalization;

namespace CvMaster.Core;

public static class GroupNames
{
    /// <summary>忽略大小写和全 / 半角宽度；与现有存储层名称比较保持一致。</summary>
    public static bool Equal(string left, string right) =>
        CultureInfo.InvariantCulture.CompareInfo.Compare(
            left,
            right,
            CompareOptions.IgnoreCase | CompareOptions.IgnoreWidth) == 0;
}
