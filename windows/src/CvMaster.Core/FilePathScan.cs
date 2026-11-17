/**
 * 文本形式文件路径的保守扫描：整段文本必须全部由已存在的本地绝对路径组成。
 * 用于钉钉 / 企业微信 / 飞书等 IM 复制聊天文件时只把路径文本写入剪贴板的场景。
 * @author helele
 * @since 2026-10-24
 */
namespace CvMaster.Core;

public static class FilePathScan
{
    /// <summary>单行路径的字符上限；更长的行视为普通文本，不做存在性探测。</summary>
    public const int MaximumPathCharacters = 1024;

    /// <summary>
    /// 尝试把整段文本解析为本地文件引用列表。
    /// 任意一行不是绝对路径或目标不存在即整体放弃，不做部分截取，也不扫描长文本内部的路径。
    /// </summary>
    /// <param name="text">剪贴板纯文本，多文件时每行一个路径。</param>
    /// <param name="maximum">最多接受的路径条数，与文件引用上限一致。</param>
    /// <param name="exists">存在性判断委托；生产环境为文件或目录存在。</param>
    /// <returns>全部行匹配时返回按原顺序的路径列表，否则 null。</returns>
    public static List<string>? TryScanFileList(string? text, int maximum, Func<string, bool> exists)
    {
        if (string.IsNullOrWhiteSpace(text) || maximum <= 0)
        {
            return null;
        }

        var lines = text.Split('\n');
        if (lines.Length > maximum)
        {
            return null;
        }

        var result = new List<string>();
        foreach (var rawLine in lines)
        {
            var line = rawLine.Trim('\r', ' ', '\t');
            if (line.Length == 0)
            {
                continue;
            }

            if (line.Length > MaximumPathCharacters)
            {
                return null;
            }

            // 部分 IM 会给路径加英文引号；只剥掉成对的一层。
            if (line.Length >= 2 && line.StartsWith('"') && line.EndsWith('"'))
            {
                line = line[1..^1].Trim();
                if (line.Length == 0)
                {
                    return null;
                }
            }

            if (!Path.IsPathFullyQualified(line))
            {
                return null;
            }

            if (!exists(line))
            {
                return null;
            }

            result.Add(line);
        }

        return result.Count > 0 ? result : null;
    }
}
