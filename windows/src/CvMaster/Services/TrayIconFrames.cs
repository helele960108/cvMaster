using System.Buffers.Binary;

namespace CvMaster.Services;

internal static class TrayIconFrames
{
    // ICO 的目录不是 Win32 所需的图标资源；只把最合适的 PNG / DIB 帧交给 user32。
    public static ReadOnlySpan<byte> Select(ReadOnlySpan<byte> ico, int size)
    {
        const int headerSize = 6;
        const int entrySize = 16;
        if (ico.Length < headerSize || BinaryPrimitives.ReadUInt32LittleEndian(ico) != 0x00010000)
        {
            return [];
        }

        var count = BinaryPrimitives.ReadUInt16LittleEndian(ico[4..]);
        var directoryEnd = headerSize + count * entrySize;
        if (directoryEnd > ico.Length)
        {
            return [];
        }

        ReadOnlySpan<byte> selected = [];
        var bestRank = int.MaxValue;
        for (var position = headerSize; position < directoryEnd; position += entrySize)
        {
            var entry = ico.Slice(position, entrySize);
            var width = entry[0] == 0 ? 256 : entry[0];
            var height = entry[1] == 0 ? 256 : entry[1];
            var length = BinaryPrimitives.ReadUInt32LittleEndian(entry[8..]);
            var offset = BinaryPrimitives.ReadUInt32LittleEndian(entry[12..]);
            if (width != height || length == 0 || offset < directoryEnd || offset > ico.Length || length > ico.Length - offset)
            {
                continue;
            }

            // 精确匹配优先；没有对应尺寸时，优先下采样，不放大小图。
            var rank = width >= size ? width - size : 256 + size - width;
            if (rank < bestRank)
            {
                bestRank = rank;
                selected = ico.Slice((int)offset, (int)length);
            }
        }

        return selected;
    }
}
