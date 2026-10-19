/**
 * 受控富文本提取：只读取本地字节，不执行 HTML、不加载远程资源。
 * 解析失败时返回 null，由调用方显示安全的占位信息。
 * @author helele
 * @since 2026-10-19
 */
using System.Globalization;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;

namespace CvMaster.Core;

public static class TextExtraction
{
    private static readonly Regex HtmlComment = new(@"<!--.*?-->", RegexOptions.Singleline | RegexOptions.Compiled, TimeSpan.FromSeconds(1));
    private static readonly Regex HtmlScript = new(@"<(script|style)\b[^>]*>.*?</\1\s*>", RegexOptions.IgnoreCase | RegexOptions.Singleline | RegexOptions.Compiled, TimeSpan.FromSeconds(1));
    private static readonly Regex HtmlBreak = new(@"<\s*(br|/p|/div|/li|/tr|/h[1-6])\b[^>]*>", RegexOptions.IgnoreCase | RegexOptions.Compiled, TimeSpan.FromSeconds(1));
    private static readonly Regex HtmlTag = new(@"<[^>]+>", RegexOptions.Singleline | RegexOptions.Compiled, TimeSpan.FromSeconds(1));

    private static readonly HashSet<string> RtfDestinations = new(StringComparer.Ordinal)
    {
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "header", "footer",
        "footnote", "annotation", "fldinst", "listtable", "listoverridetable", "rsidtbl",
        "generator", "xmlnstbl", "themedata", "colorschememapping", "latentstyles",
        "datastore", "filetbl", "revtbl", "pn", "pnse", "pntext", "listtext",
        "author", "operator", "title", "subject", "keywords", "comment", "doccomm"
    };

    /// <summary>提取 RTF 的可见文本；输入和输出均受预算约束。</summary>
    public static string? FromRtf(byte[] data, int maximumCharacters = StorageLimits.SearchableCharacters)
    {
        if (data.Length == 0 || data.Length > StorageLimits.MaximumRichTextPreviewBytes || maximumCharacters <= 0)
        {
            return null;
        }

        try
        {
            var source = Encoding.Latin1.GetString(data);
            if (!source.TrimStart().StartsWith(@"{\rtf", StringComparison.Ordinal))
            {
                return null;
            }

            var output = new StringBuilder(Math.Min(maximumCharacters, 4096));
            var skipStack = new Stack<bool>();
            var ucStack = new Stack<int>();
            var skip = false;
            var ucSkip = 1;
            var pendingSkip = 0;
            var index = 0;

            while (index < source.Length && output.Length < maximumCharacters)
            {
                var current = source[index++];
                switch (current)
                {
                    case '{':
                        skipStack.Push(skip);
                        ucStack.Push(ucSkip);
                        break;
                    case '}':
                        if (skipStack.Count > 0)
                        {
                            skip = skipStack.Pop();
                            ucSkip = ucStack.Pop();
                        }
                        break;
                    case '\\':
                        if (index >= source.Length)
                        {
                            break;
                        }

                        var next = source[index];
                        if (next == '\'')
                        {
                            index++;
                            if (index + 2 <= source.Length)
                            {
                                var hex = source.AsSpan(index, 2);
                                index += 2;
                                if (pendingSkip > 0)
                                {
                                    pendingSkip--;
                                }
                                else if (!skip && byte.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value))
                                {
                                    output.Append((char)value);
                                }
                            }
                            break;
                        }

                        if (!char.IsLetter(next))
                        {
                            index++;
                            if (!skip)
                            {
                                output.Append(next switch
                                {
                                    '\\' => '\\',
                                    '{' => '{',
                                    '}' => '}',
                                    '~' => ' ',
                                    '_' => '-',
                                    _ => '\0'
                                });
                            }
                            if (next == '*' && skipStack.Count > 0)
                            {
                                // 可忽略目标组：当前层的后续内容不进入预览。
                                skip = true;
                            }
                            if (next == '\\' || next == '{' || next == '}' || next == '~' || next == '_')
                            {
                                pendingSkip = Math.Max(0, pendingSkip - 1);
                            }
                            break;
                        }

                        var wordStart = index;
                        while (index < source.Length && char.IsLetter(source[index]))
                        {
                            index++;
                        }
                        var word = source[wordStart..index];
                        var negative = false;
                        if (index < source.Length && source[index] == '-')
                        {
                            negative = true;
                            index++;
                        }
                        var numberStart = index;
                        while (index < source.Length && char.IsDigit(source[index]))
                        {
                            index++;
                        }
                        var hasNumber = index > numberStart;
                        var number = hasNumber
                            ? int.Parse(source.AsSpan(numberStart, index - numberStart), CultureInfo.InvariantCulture)
                            : 0;
                        if (negative)
                        {
                            number = -number;
                        }
                        if (index < source.Length && source[index] == ' ')
                        {
                            index++;
                        }

                        if (word == "bin" && number > 0)
                        {
                            index = Math.Min(source.Length, index + number);
                            break;
                        }

                        if (word == "uc")
                        {
                            ucSkip = Math.Max(0, number);
                            break;
                        }

                        if (word == "u" && hasNumber)
                        {
                            if (pendingSkip > 0)
                            {
                                pendingSkip--;
                            }
                            else if (!skip)
                            {
                                var scalar = number < 0 ? number + 65536 : number;
                                if (scalar is >= 0 and <= 0xFFFF)
                                {
                                    output.Append((char)scalar);
                                }
                            }
                            pendingSkip = ucSkip;
                            break;
                        }

                        if (RtfDestinations.Contains(word))
                        {
                            skip = true;
                            break;
                        }

                        if (skip)
                        {
                            break;
                        }

                        switch (word)
                        {
                            case "par":
                            case "line":
                            case "sect":
                            case "page":
                            case "row":
                                output.Append('\n');
                                break;
                            case "tab":
                                output.Append('\t');
                                break;
                        }
                        break;
                    case '\r':
                    case '\n':
                        break;
                    default:
                        if (pendingSkip > 0)
                        {
                            pendingSkip--;
                        }
                        else if (!skip)
                        {
                            output.Append(current);
                        }
                        break;
                }
            }

            return NormalizeVisibleText(output.ToString(), maximumCharacters);
        }
        catch (Exception)
        {
            // 富文本仅用于搜索和预览；解析失败不能影响原始表示的保存与再次复制。
            return null;
        }
    }

    /// <summary>从 HTML clipboard 负载中提取可见文本，不解析脚本或外部资源。</summary>
    public static string? FromHtml(byte[] data, int maximumCharacters = StorageLimits.SearchableCharacters)
    {
        if (data.Length == 0 || maximumCharacters <= 0)
        {
            return null;
        }

        try
        {
            var html = DecodeHtmlPayload(data);
            if (string.IsNullOrWhiteSpace(html))
            {
                return null;
            }

            html = HtmlComment.Replace(html, " ");
            html = HtmlScript.Replace(html, " ");
            html = HtmlBreak.Replace(html, "\n");
            html = HtmlTag.Replace(html, " ");
            html = WebUtility.HtmlDecode(html).Replace('\u00a0', ' ');
            return NormalizeVisibleText(html, maximumCharacters);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>返回 HTML clipboard 负载中的真实 HTML 字节，供指纹稳定化使用。</summary>
    public static byte[] GetHtmlBody(byte[] data)
    {
        if (data.Length == 0)
        {
            return data;
        }

        try
        {
            var headerLength = Math.Min(data.Length, 4096);
            var header = Encoding.ASCII.GetString(data, 0, headerLength);
            var start = ReadHeaderOffset(header, "StartHTML");
            var end = ReadHeaderOffset(header, "EndHTML");
            if (start >= 0 && end > start && end <= data.Length)
            {
                return data.AsSpan(start, end - start).ToArray();
            }

            for (var i = 0; i < data.Length; i++)
            {
                if (data[i] == (byte)'<')
                {
                    return data.AsSpan(i).ToArray();
                }
            }
        }
        catch (Exception)
        {
            // 头部损坏时使用原始负载；不因指纹归一化失败丢弃内容。
        }

        return data;
    }

    /// <summary>按 Unicode 文本元素截断，避免从代理对中间切开。</summary>
    public static string Truncate(string value, int maximumCharacters)
    {
        if (string.IsNullOrEmpty(value) || maximumCharacters <= 0)
        {
            return string.Empty;
        }

        var info = new StringInfo(value);
        return info.LengthInTextElements <= maximumCharacters
            ? value
            : info.SubstringByTextElements(0, maximumCharacters);
    }

    public static int CountTextElements(string value) =>
        string.IsNullOrEmpty(value) ? 0 : new StringInfo(value).LengthInTextElements;

    /// <summary>标题取首个非空行；空内容使用调用方提供的兜底文案。</summary>
    public static string FirstLine(string value, int maximumCharacters, string fallback)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return fallback;
        }

        foreach (var line in value.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.Length > 0)
            {
                return Truncate(trimmed, maximumCharacters);
            }
        }

        return fallback;
    }

    private static string? DecodeHtmlPayload(byte[] data)
    {
        var body = GetHtmlBody(data);
        try
        {
            return new UTF8Encoding(false, true).GetString(body);
        }
        catch (DecoderFallbackException)
        {
            return Encoding.Latin1.GetString(body);
        }
    }

    private static int ReadHeaderOffset(string header, string name)
    {
        var index = header.IndexOf(name + ":", StringComparison.OrdinalIgnoreCase);
        if (index < 0)
        {
            return -1;
        }

        index += name.Length + 1;
        var end = index;
        while (end < header.Length && char.IsDigit(header[end]))
        {
            end++;
        }

        return end > index && int.TryParse(header.AsSpan(index, end - index), NumberStyles.None, CultureInfo.InvariantCulture, out var value)
            ? value
            : -1;
    }

    private static string? NormalizeVisibleText(string value, int maximumCharacters)
    {
        if (value.Length == 0)
        {
            return null;
        }

        var text = value.Replace("\r\n", "\n").Replace('\r', '\n').Replace('\0', ' ');
        text = Regex.Replace(text, @"[ \t]{2,}", " ", RegexOptions.None, TimeSpan.FromSeconds(1));
        text = Regex.Replace(text, @"[ \t]+\n", "\n", RegexOptions.None, TimeSpan.FromSeconds(1));
        text = Regex.Replace(text, @"\n{3,}", "\n\n", RegexOptions.None, TimeSpan.FromSeconds(1));
        text = text.Trim();
        if (text.Length == 0)
        {
            return null;
        }

        return Truncate(text, maximumCharacters);
    }
}
