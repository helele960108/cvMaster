/**
 * 稳定内容指纹：类型、item 边界和长度参与哈希，避免不同表示串联碰撞。
 * HTML 指纹忽略 clipboard 头部，避免同一内容因 SourceURL 不同而重复入库。
 * @author helele
 * @since 2026-10-19
 */
using System.Security.Cryptography;
using System.Text;

namespace CvMaster.Core;

public static class Fingerprint
{
    public static string Compute(IReadOnlyList<ClipRepresentation> representations)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var representation in representations
                     .OrderBy(item => item.Item)
                     .ThenBy(item => item.Type, StringComparer.Ordinal))
        {
            var payload = representation.Type == "text/html"
                ? TextExtraction.GetHtmlBody(representation.Data)
                : representation.Data;
            var header = Encoding.UTF8.GetBytes(
                $"{representation.Item}:{representation.Type}:{payload.Length}:");
            hash.AppendData(header);
            hash.AppendData(payload);
        }

        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }
}
