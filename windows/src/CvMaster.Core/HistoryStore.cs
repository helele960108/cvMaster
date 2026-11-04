/**
 * SQLite 串行后台存储：关系型元数据与独立内容文件，不使用 JSON 字段。
 * 所有查询、索引、哈希、磁盘读写都在后台执行；UI 只接收轻量投影。
 * @author helele
 * @since 2026-10-19
 */
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Data.Sqlite;
using Microsoft.Win32.SafeHandles;

namespace CvMaster.Core;

public sealed class HistoryStore : IAsyncDisposable
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private SqliteConnection? _connection;
    private bool _disposed;

    public HistoryStore(string? rootDirectory = null)
    {
        RootDirectory = rootDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "cvMaster");
        AssetsDirectory = Path.Combine(RootDirectory, "assets");
        DatabasePath = Path.Combine(RootDirectory, "history.sqlite");
    }

    public string RootDirectory { get; }

    public string AssetsDirectory { get; }

    public string DatabasePath { get; }

    public Task InitializeAsync(CancellationToken cancellationToken = default) =>
        RunAsync(() =>
        {
            EnsureInitialized();
            return true;
        }, cancellationToken);

    public Task<HistoryPage> GetPageAsync(ClipSearchQuery query, CancellationToken cancellationToken = default) =>
        RunAsync(() => GetPageCore(query), cancellationToken);

    public Task<StorageStats> GetStorageStatsAsync(CancellationToken cancellationToken = default) =>
        RunAsync(() => StorageStatsCore(), cancellationToken);

    public Task<IReadOnlyList<ClipGroup>> GetGroupsAsync(CancellationToken cancellationToken = default) =>
        RunAsync(() =>
        {
            EnsureInitialized();
            return (IReadOnlyList<ClipGroup>)ReadGroupsCore();
        }, cancellationToken);

    public Task SaveAsync(ClipCapture capture, int retentionDays, CancellationToken cancellationToken = default) =>
        RunAsync(() => SaveCore(capture, retentionDays), cancellationToken);

    public Task SetPinnedAsync(Guid id, bool pinned, CancellationToken cancellationToken = default) =>
        RunAsync(() =>
        {
            EnsureInitialized();
            using var command = CreateCommand(
                "UPDATE entry SET pinned=@pinned WHERE id=@id",
                ("@pinned", pinned ? 1 : 0),
                ("@id", id.ToString("D")));
            command.ExecuteNonQuery();
            return true;
        }, cancellationToken);

    public Task SetGroupAsync(Guid entryId, Guid groupId, bool included, CancellationToken cancellationToken = default) =>
        RunAsync(() =>
        {
            EnsureInitialized();
            using var command = included
                ? CreateCommand(
                    "INSERT OR IGNORE INTO entry_group(entry_id,group_id) VALUES(@entry,@group)",
                    ("@entry", entryId.ToString("D")),
                    ("@group", groupId.ToString("D")))
                : CreateCommand(
                    "DELETE FROM entry_group WHERE entry_id=@entry AND group_id=@group",
                    ("@entry", entryId.ToString("D")),
                    ("@group", groupId.ToString("D")));
            command.ExecuteNonQuery();
            return true;
        }, cancellationToken);

    public Task SaveGroupAsync(Guid? id, string name, CancellationToken cancellationToken = default) =>
        RunAsync(() =>
        {
            EnsureInitialized();
            SaveGroupCore(id, name);
            return true;
        }, cancellationToken);

    /// <summary>仅删除分组及其归属关系；缺失分组按成功处理，不触发内容或资产清理。</summary>
    public Task DeleteGroupAsync(Guid id, CancellationToken cancellationToken = default) =>
        RunAsync(() =>
        {
            EnsureInitialized();
            DeleteGroupCore(id);
            return true;
        }, cancellationToken);

    /// <summary>按最新目录将分组前移或后移一位；仅接受 -1 / +1，首尾越界不写入。</summary>
    public Task MoveGroupAsync(Guid id, int offset, CancellationToken cancellationToken = default) =>
        RunAsync(() =>
        {
            EnsureInitialized();
            MoveGroupCore(id, offset);
            return true;
        }, cancellationToken);

    public Task DeleteAsync(Guid id, CancellationToken cancellationToken = default) =>
        RunAsync(() =>
        {
            EnsureInitialized();
            DeleteEntryCore(id);
            return true;
        }, cancellationToken);

    public Task<int> ClearAsync(DateTimeOffset? before, CancellationToken cancellationToken = default) =>
        RunAsync(() => ClearCore(before), cancellationToken);

    /// <summary>
    /// 读取完整原始表示并确认文件引用仍可用。
    /// 外部文件检查在串行存储队列之外执行，异常挂载点不会阻塞其他查询。
    /// </summary>
    public async Task<IReadOnlyList<ClipRepresentation>> GetRepresentationsAsync(Guid id, CancellationToken cancellationToken = default)
    {
        var representations = await RunAsync(
            () => (IReadOnlyList<ClipRepresentation>)RepresentationsCore(id),
            cancellationToken).ConfigureAwait(false);
        await EnsureFileReferencesAvailableAsync(representations, cancellationToken).ConfigureAwait(false);
        return representations;
    }

    public Task<IReadOnlyList<ClipRepresentation>> GetPlainTextAsync(Guid id, ClipKind kind, CancellationToken cancellationToken = default) =>
        RunAsync(() => (IReadOnlyList<ClipRepresentation>)PlainTextCore(id, kind), cancellationToken);

    public Task<ClipPreviewData> GetPreviewAsync(Guid id, CancellationToken cancellationToken = default) =>
        RunAsync(() => PreviewCore(id), cancellationToken);

    /// <summary>返回列表缩略图可解码的本地文件路径；无图或引用失效时返回 null。</summary>
    public Task<string?> GetThumbnailSourceAsync(Guid id, CancellationToken cancellationToken = default) =>
        RunAsync(() => ThumbnailSourceCore(id), cancellationToken);

    /// <summary>仅在粘贴事件已发送后记录使用次数。</summary>
    public Task MarkCopiedAsync(Guid id, CancellationToken cancellationToken = default) =>
        RunAsync(() =>
        {
            EnsureInitialized();
            using var command = CreateCommand(
                "UPDATE entry SET copied_at=@now,copies=copies+1 WHERE id=@id",
                ("@now", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()),
                ("@id", id.ToString("D")));
            command.ExecuteNonQuery();
            return true;
        }, cancellationToken);

    private async Task<T> RunAsync<T>(Func<T> work, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(work, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task RunAsync(Action work, CancellationToken cancellationToken)
    {
        await RunAsync(() =>
        {
            work();
            return true;
        }, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>首次初始化后复用一个连接；不自动切换临时存储或覆盖旧库。</summary>
    private void EnsureInitialized()
    {
        if (_connection is not null)
        {
            return;
        }

        try
        {
            InitializeCore();
        }
        catch (LibraryException)
        {
            throw;
        }
        catch (Exception exception)
        {
            CloseConnection();
            throw new LibraryException(LibraryErrorCode.Storage, exception);
        }
    }

    private void InitializeCore()
    {
        Directory.CreateDirectory(RootDirectory);
        Directory.CreateDirectory(AssetsDirectory);

        // 数据目录与数据库必须是普通路径；重解析点会把读写引到目录之外。
        if (IsReparsePoint(RootDirectory) || IsReparsePoint(AssetsDirectory) || IsReparsePoint(DatabasePath))
        {
            throw new LibraryException(LibraryErrorCode.Storage);
        }

        foreach (var suffix in new[] { "-wal", "-shm", "-journal" })
        {
            if (IsReparsePoint(DatabasePath + suffix))
            {
                throw new LibraryException(LibraryErrorCode.Storage);
            }
        }

        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Private,
            Pooling = false
        };
        var connection = new SqliteConnection(builder.ToString());
        connection.Open();
        _connection = connection;
        try
        {
            ExecutePragma("PRAGMA foreign_keys=ON");
            ExecutePragma("PRAGMA journal_mode=WAL");
            ExecutePragma("PRAGMA synchronous=NORMAL");
            ExecutePragma("PRAGMA cache_size=-2048");
            ExecutePragma("PRAGMA journal_size_limit=4194304");
            ExecutePragma("PRAGMA busy_timeout=1500");

            var version = ScalarLong("PRAGMA user_version");
            if (version > 1)
            {
                throw new LibraryException(LibraryErrorCode.Storage);
            }

            using var schema = connection.CreateCommand();
            schema.CommandText = """
                CREATE TABLE IF NOT EXISTS entry(
                    id TEXT PRIMARY KEY,
                    fingerprint TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    excerpt TEXT NOT NULL,
                    search_text TEXT NOT NULL,
                    source TEXT NOT NULL,
                    source_process TEXT NOT NULL DEFAULT '',
                    copied_at INTEGER NOT NULL,
                    byte_size INTEGER NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    copies INTEGER NOT NULL DEFAULT 1);
                CREATE INDEX IF NOT EXISTS entry_order ON entry(pinned DESC, copied_at DESC, id);
                CREATE TABLE IF NOT EXISTS user_group(
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL COLLATE NOCASE UNIQUE,
                    color INTEGER NOT NULL,
                    position INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS entry_group(
                    entry_id TEXT NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
                    group_id TEXT NOT NULL REFERENCES user_group(id) ON DELETE CASCADE,
                    PRIMARY KEY(entry_id, group_id));
                CREATE INDEX IF NOT EXISTS group_entries ON entry_group(group_id, entry_id);
                CREATE TABLE IF NOT EXISTS representation(
                    id TEXT PRIMARY KEY,
                    entry_id TEXT NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
                    item_order INTEGER NOT NULL,
                    type TEXT NOT NULL,
                    filename TEXT NOT NULL UNIQUE,
                    byte_size INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS representation_entry ON representation(entry_id, item_order);
                """;
            schema.ExecuteNonQuery();
            if (version < 1)
            {
                ExecutePragma("PRAGMA user_version=1");
            }

            RecoverAssetsCore();
        }
        catch
        {
            CloseConnection();
            throw;
        }
    }

    private void CloseConnection()
    {
        _connection?.Dispose();
        _connection = null;
    }

    private void ExecutePragma(string sql)
    {
        using var command = CreateCommand(sql);
        command.ExecuteNonQuery();
    }

    private SqliteCommand CreateCommand(string sql, params (string Name, object? Value)[] values)
    {
        if (_connection is null)
        {
            throw new LibraryException(LibraryErrorCode.Storage);
        }

        var command = _connection.CreateCommand();
        command.CommandText = sql;
        foreach (var (name, value) in values)
        {
            command.Parameters.AddWithValue(name, value ?? DBNull.Value);
        }

        return command;
    }

    private long ScalarLong(string sql, params (string Name, object? Value)[] values)
    {
        using var command = CreateCommand(sql, values);
        var result = command.ExecuteScalar();
        return result is null or DBNull ? 0 : Convert.ToInt64(result, CultureInfo.InvariantCulture);
    }

    private string? ScalarString(string sql, params (string Name, object? Value)[] values)
    {
        using var command = CreateCommand(sql, values);
        return command.ExecuteScalar() as string;
    }

    private HistoryPage GetPageCore(ClipSearchQuery query)
    {
        EnsureInitialized();
        var clauses = new List<string> { "1=1" };
        var values = new List<(string, object?)>();

        if (query.Scope == "pinned")
        {
            clauses.Add("e.pinned=1");
        }
        else if (query.Scope != "all" && Guid.TryParse(query.Scope, out var groupId))
        {
            clauses.Add("EXISTS(SELECT 1 FROM entry_group eg WHERE eg.entry_id=e.id AND eg.group_id=@scopeGroup)");
            values.Add(("@scopeGroup", groupId.ToString("D")));
        }

        if (query.Kind is { } kind)
        {
            clauses.Add("e.kind=@kind");
            values.Add(("@kind", kind.ToStorageValue()));
        }

        if (query.TimeRange.GetBounds(DateTimeOffset.Now) is { } bounds)
        {
            clauses.Add("e.copied_at>=@start AND e.copied_at<@end");
            values.Add(("@start", bounds.StartMs));
            values.Add(("@end", bounds.EndMs));
        }

        var keyword = TextExtraction.Truncate(query.Query.Trim(), 256);
        if (keyword.Length > 0)
        {
            clauses.Add("e.kind IN (@kindText,@kindLink,@kindFile) AND e.search_text LIKE @pattern ESCAPE '\\'");
            values.Add(("@kindText", ClipKind.Text.ToStorageValue()));
            values.Add(("@kindLink", ClipKind.Link.ToStorageValue()));
            values.Add(("@kindFile", ClipKind.File.ToStorageValue()));
            values.Add(("@pattern", "%" + EscapeLike(keyword) + "%"));
        }

        var filter = string.Join(" AND ", clauses);
        var total = checked((int)ScalarLong($"SELECT COUNT(*) FROM entry e WHERE {filter}", values.ToArray()));
        var limit = Math.Clamp(query.Limit, 1, StorageLimits.MaximumLoaded);
        var selectValues = values.Concat(new (string, object?)[]
        {
            ("@fileType", "windows/file-list"),
            ("@limit", limit)
        }).ToArray();

        var clips = new List<Clip>();
        var idParams = new List<(string, object?)>();
        using (var command = CreateCommand($"""
                   SELECT e.id,e.kind,e.title,e.excerpt,e.source,e.source_process,e.copied_at,e.byte_size,
                          e.pinned,e.copies,
                          EXISTS(SELECT 1 FROM representation r WHERE r.entry_id=e.id AND r.type=@fileType)
                   FROM entry e
                   WHERE {filter}
                   ORDER BY e.pinned DESC,e.copied_at DESC,e.id
                   LIMIT @limit
                   """, selectValues))
        {
            using var reader = command.ExecuteReader();
            var index = 0;
            while (reader.Read())
            {
                if (!Guid.TryParse(reader.GetString(0), out var id))
                {
                    throw new LibraryException(LibraryErrorCode.Storage);
                }

                var storedKind = ClipKindExtensions.FromStorageValue(reader.GetString(1));
                var copiedAt = DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(6));
                clips.Add(new Clip(
                    id,
                    storedKind,
                    reader.GetString(2),
                    reader.GetString(4),
                    reader.GetString(5),
                    copiedAt,
                    reader.GetInt64(7),
                    reader.GetInt32(8) != 0,
                    new HashSet<Guid>(),
                    reader.GetInt32(9),
                    reader.GetString(3),
                    reader.GetInt32(10) != 0));
                idParams.Add(($"@g{index}", id.ToString("D")));
                index++;
            }
        }

        if (idParams.Count > 0)
        {
            var inClause = string.Join(",", idParams.Select(item => item.Item1));
            var groupMap = new Dictionary<Guid, HashSet<Guid>>();
            using var command = CreateCommand(
                $"SELECT entry_id,group_id FROM entry_group WHERE entry_id IN ({inClause})",
                idParams.ToArray());
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                if (!Guid.TryParse(reader.GetString(0), out var entryId) ||
                    !Guid.TryParse(reader.GetString(1), out var group))
                {
                    continue;
                }

                if (!groupMap.TryGetValue(entryId, out var set))
                {
                    set = new HashSet<Guid>();
                    groupMap[entryId] = set;
                }

                set.Add(group);
            }

            for (var i = 0; i < clips.Count; i++)
            {
                var clip = clips[i];
                if (groupMap.TryGetValue(clip.Id, out var groups))
                {
                    clips[i] = new Clip(
                        clip.Id,
                        clip.Kind,
                        clip.Title,
                        clip.Source,
                        clip.SourceProcess,
                        clip.CopiedAt,
                        clip.ByteSize,
                        clip.Pinned,
                        groups,
                        clip.Copies,
                        clip.Excerpt,
                        clip.HasFileReference);
                }
            }
        }

        var stats = StorageStatsCore();
        return new HistoryPage(clips, total, stats.Entries, stats.Bytes);
    }

    private StorageStats StorageStatsCore()
    {
        var entries = checked((int)ScalarLong("SELECT COUNT(*) FROM entry"));
        var bytes = ScalarLong("SELECT COALESCE(SUM(byte_size),0) FROM entry");
        return new StorageStats(entries, bytes);
    }

    private List<ClipGroup> ReadGroupsCore()
    {
        var groups = new List<ClipGroup>();
        using var command = CreateCommand("SELECT id,name,color FROM user_group ORDER BY position,id");
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            if (!Guid.TryParse(reader.GetString(0), out var id))
            {
                throw new LibraryException(LibraryErrorCode.Storage);
            }

            groups.Add(new ClipGroup(id, reader.GetString(1), reader.GetInt32(2)));
        }

        return groups;
    }

    private void SaveCore(ClipCapture capture, int retentionDays)
    {
        EnsureInitialized();
        if (capture.Representations.Count == 0 ||
            capture.Representations.Count > StorageLimits.MaximumRepresentations)
        {
            throw new LibraryException(LibraryErrorCode.Unsupported);
        }

        long totalBytes = 0;
        foreach (var representation in capture.Representations)
        {
            if (representation.Data.Length == 0 ||
                representation.Data.Length > StorageLimits.MaximumRepresentationBytes)
            {
                throw new LibraryException(LibraryErrorCode.Unsupported);
            }

            totalBytes += representation.Data.Length;
            if (totalBytes > StorageLimits.MaximumCaptureBytes)
            {
                throw new LibraryException(LibraryErrorCode.Unsupported);
            }
        }

        var title = TextExtraction.Truncate(capture.Title.Trim(), StorageLimits.MaximumTitleCharacters);
        var excerpt = TextExtraction.Truncate(capture.Excerpt.Trim(), StorageLimits.MaximumExcerptCharacters);
        var searchText = TextExtraction.Truncate(capture.SearchText, StorageLimits.SearchableCharacters);
        var source = TextExtraction.Truncate(capture.Source.Trim(), 120);
        var sourceProcess = TextExtraction.Truncate(capture.SourceProcess.Trim(), 260);
        if (title.Length == 0)
        {
            title = "未命名内容";
        }

        var fingerprint = Fingerprint.Compute(capture.Representations);
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var entryId = Guid.NewGuid();
        var written = new List<string>();
        var removed = new List<string>();
        try
        {
            using (var begin = CreateCommand("BEGIN IMMEDIATE"))
            {
                begin.ExecuteNonQuery();
            }

            var duplicate = ScalarLong(
                "SELECT COUNT(*) FROM entry WHERE fingerprint=@fingerprint",
                ("@fingerprint", fingerprint)) > 0;
            if (duplicate)
            {
                using var update = CreateCommand(
                    "UPDATE entry SET copied_at=@now,copies=copies+1,source=@source,source_process=@process WHERE fingerprint=@fingerprint",
                    ("@now", now),
                    ("@source", source),
                    ("@process", sourceProcess),
                    ("@fingerprint", fingerprint));
                update.ExecuteNonQuery();
            }

            // 清理与去重 / 入库共享事务：失败时旧记录和旧资产保持不变。
            removed.AddRange(PruneCore(Math.Max(0, retentionDays), duplicate ? 0 : totalBytes, addingEntry: !duplicate));

            if (!duplicate)
            {
                using (var insert = CreateCommand(
                           """
                           INSERT INTO entry(id,fingerprint,kind,title,excerpt,search_text,source,source_process,copied_at,byte_size)
                           VALUES(@id,@fingerprint,@kind,@title,@excerpt,@search,@source,@process,@now,@bytes)
                           """,
                           ("@id", entryId.ToString("D")),
                           ("@fingerprint", fingerprint),
                           ("@kind", capture.Kind.ToStorageValue()),
                           ("@title", title),
                           ("@excerpt", excerpt),
                           ("@search", searchText),
                           ("@source", source),
                           ("@process", sourceProcess),
                           ("@now", now),
                           ("@bytes", totalBytes)))
                {
                    insert.ExecuteNonQuery();
                }

                foreach (var representation in capture.Representations)
                {
                    var assetId = Guid.NewGuid().ToString("N");
                    var path = Path.Combine(AssetsDirectory, assetId);
                    WriteAsset(path, representation.Data);
                    written.Add(path);
                    using var insert = CreateCommand(
                        """
                        INSERT INTO representation(id,entry_id,item_order,type,filename,byte_size)
                        VALUES(@id,@entry,@item,@type,@filename,@bytes)
                        """,
                        ("@id", Guid.NewGuid().ToString("D")),
                        ("@entry", entryId.ToString("D")),
                        ("@item", representation.Item),
                        ("@type", representation.Type),
                        ("@filename", assetId),
                        ("@bytes", representation.Data.Length));
                    insert.ExecuteNonQuery();
                }
            }

            using (var commit = CreateCommand("COMMIT"))
            {
                commit.ExecuteNonQuery();
            }
        }
        catch (LibraryException)
        {
            TryRollback();
            DeleteAssets(written);
            throw;
        }
        catch (Exception exception)
        {
            TryRollback();
            DeleteAssets(written);
            throw new LibraryException(LibraryErrorCode.Storage, exception);
        }

        // 提交成功后才回收旧资产，避免回滚时误删仍被引用的文件。
        DeleteAssets(removed.Select(AssetPath).OfType<string>());
    }

    /// <summary>
    /// 清理仅删除非保护记录；保护内容占满容量时拒绝新内容。
    /// 只修改数据库并返回待回收的资产名，调用方在事务提交后删除文件。
    /// </summary>
    private List<string> PruneCore(int retentionDays, long incomingBytes, bool addingEntry)
    {
        const string protectedFilter = "pinned=1 OR EXISTS(SELECT 1 FROM entry_group WHERE entry_id=entry.id)";
        var protectedCount = ScalarLong($"SELECT COUNT(*) FROM entry WHERE {protectedFilter}");
        var protectedBytes = ScalarLong($"SELECT COALESCE(SUM(byte_size),0) FROM entry WHERE {protectedFilter}");
        if (protectedCount + (addingEntry ? 1 : 0) > StorageLimits.MaximumEntries ||
            protectedBytes + incomingBytes > StorageLimits.MaximumBytes)
        {
            throw new LibraryException(LibraryErrorCode.Capacity);
        }

        var cutoff = retentionDays > 0
            ? DateTimeOffset.UtcNow.AddDays(-retentionDays).ToUnixTimeMilliseconds()
            : long.MinValue;
        var count = ScalarLong("SELECT COUNT(*) FROM entry");
        var bytes = ScalarLong("SELECT COALESCE(SUM(byte_size),0) FROM entry");
        var removed = new List<string>();

        while (true)
        {
            var candidates = new List<(Guid Id, long Bytes)>();
            var plannedCount = count;
            var plannedBytes = bytes;
            using (var select = CreateCommand(
                       """
                       SELECT id,byte_size,copied_at FROM entry
                       WHERE pinned=0
                         AND NOT EXISTS(SELECT 1 FROM entry_group WHERE entry_id=entry.id)
                       ORDER BY copied_at
                       LIMIT 128
                       """))
            using (var reader = select.ExecuteReader())
            {
                while (reader.Read())
                {
                    var overBudget = plannedCount + (addingEntry ? 1 : 0) > StorageLimits.MaximumEntries ||
                                     plannedBytes + incomingBytes > StorageLimits.MaximumBytes;
                    var copiedAt = reader.GetInt64(2);
                    if (!overBudget && copiedAt >= cutoff)
                    {
                        break;
                    }

                    if (!Guid.TryParse(reader.GetString(0), out var id))
                    {
                        throw new LibraryException(LibraryErrorCode.Storage);
                    }

                    var size = reader.GetInt64(1);
                    candidates.Add((id, size));
                    plannedCount--;
                    plannedBytes -= size;
                }
            }

            if (candidates.Count == 0)
            {
                break;
            }

            var idParameters = candidates
                .Select((candidate, index) => ($"@id{index}", (object?)candidate.Id.ToString("D")))
                .ToArray();
            var inClause = string.Join(",", idParameters.Select(item => item.Item1));
            using (var assets = CreateCommand(
                       $"SELECT filename FROM representation WHERE entry_id IN ({inClause})",
                       idParameters))
            using (var reader = assets.ExecuteReader())
            {
                while (reader.Read())
                {
                    removed.Add(reader.GetString(0));
                }
            }

            using (var delete = CreateCommand(
                       $"DELETE FROM entry WHERE id IN ({inClause})",
                       idParameters))
            {
                delete.ExecuteNonQuery();
            }

            count = plannedCount;
            bytes = plannedBytes;
        }

        if (count + (addingEntry ? 1 : 0) > StorageLimits.MaximumEntries ||
            bytes + incomingBytes > StorageLimits.MaximumBytes)
        {
            throw new LibraryException(LibraryErrorCode.Capacity);
        }

        return removed;
    }

    private void DeleteEntryCore(Guid id)
    {
        var filenames = new List<string>();
        using (var select = CreateCommand(
                   "SELECT filename FROM representation WHERE entry_id=@id",
                   ("@id", id.ToString("D"))))
        using (var reader = select.ExecuteReader())
        {
            while (reader.Read())
            {
                filenames.Add(reader.GetString(0));
            }
        }

        using (var delete = CreateCommand("DELETE FROM entry WHERE id=@id", ("@id", id.ToString("D"))))
        {
            if (delete.ExecuteNonQuery() == 0)
            {
                throw new LibraryException(LibraryErrorCode.MissingContent);
            }
        }

        foreach (var filename in filenames)
        {
            if (AssetPath(filename) is { } path)
            {
                TryDelete(path);
            }
        }
    }

    private int ClearCore(DateTimeOffset? before)
    {
        EnsureInitialized();
        var removed = before is null
            ? checked((int)ScalarLong("SELECT COUNT(*) FROM entry"))
            : checked((int)ScalarLong(
                "SELECT COUNT(*) FROM entry WHERE copied_at<@cutoff",
                ("@cutoff", before.Value.ToUnixTimeMilliseconds())));
        if (removed == 0)
        {
            return 0;
        }

        try
        {
            using (var begin = CreateCommand("BEGIN IMMEDIATE"))
            {
                begin.ExecuteNonQuery();
            }

            using (var delete = before is null
                       ? CreateCommand("DELETE FROM entry")
                       : CreateCommand(
                           "DELETE FROM entry WHERE copied_at<@cutoff",
                           ("@cutoff", before.Value.ToUnixTimeMilliseconds())))
            {
                delete.ExecuteNonQuery();
            }

            using (var commit = CreateCommand("COMMIT"))
            {
                commit.ExecuteNonQuery();
            }
        }
        catch (Exception exception)
        {
            TryRollback();
            throw new LibraryException(LibraryErrorCode.Storage, exception);
        }

        // 删除提交即成功边界；资产回收与 checkpoint 失败不伪装成删除回滚。
        // 不执行 VACUUM：空闲页留待复用，避免长时间阻塞和其他查询饥饿。
        try
        {
            RecoverAssetsCore();
        }
        catch (Exception)
        {
            // 启动恢复会再次回收孤立资产。
        }

        try
        {
            ExecutePragma("PRAGMA wal_checkpoint(TRUNCATE)");
        }
        catch (Exception)
        {
            // checkpoint 失败不影响已提交的删除。
        }

        return removed;
    }

    /// <summary>分组校验和写入共用显式写事务；事务开始后不再检查取消。</summary>
    private void RunGroupTransaction(Action work)
    {
        try
        {
            using (var begin = CreateCommand("BEGIN IMMEDIATE"))
            {
                begin.ExecuteNonQuery();
            }

            work();

            using var commit = CreateCommand("COMMIT");
            commit.ExecuteNonQuery();
        }
        catch (LibraryException)
        {
            TryRollback();
            throw;
        }
        catch (Exception exception)
        {
            TryRollback();
            throw new LibraryException(LibraryErrorCode.Storage, exception);
        }
    }

    private void SaveGroupCore(Guid? id, string name)
    {
        RunGroupTransaction(() =>
        {
            // 先限制原名的字节预算，避免超长空白或组合字符绕过 trim / 文本元素限额。
            if (name.Length > StorageLimits.MaximumGroupNameBytes ||
                Encoding.UTF8.GetByteCount(name) > StorageLimits.MaximumGroupNameBytes)
            {
                throw new LibraryException(LibraryErrorCode.NameConflict);
            }

            var trimmed = name.Trim();
            if (Encoding.UTF8.GetByteCount(trimmed) > StorageLimits.MaximumGroupNameBytes)
            {
                throw new LibraryException(LibraryErrorCode.NameConflict);
            }

            var length = TextExtraction.CountTextElements(trimmed);
            if (length == 0 || length > StorageLimits.MaximumGroupNameCharacters)
            {
                throw new LibraryException(LibraryErrorCode.NameConflict);
            }

            var groups = ReadGroupsCore();
            if (id is { } existingId && !groups.Any(group => group.Id == existingId))
            {
                throw new LibraryException(LibraryErrorCode.MissingGroup);
            }

            if ((id is null && groups.Count >= StorageLimits.MaximumGroups) ||
                groups.Any(group => group.Id != id && GroupNames.Equal(group.Name, trimmed)))
            {
                throw new LibraryException(LibraryErrorCode.NameConflict);
            }

            if (id is { } groupId)
            {
                using var update = CreateCommand(
                    "UPDATE user_group SET name=@name WHERE id=@id",
                    ("@name", trimmed),
                    ("@id", groupId.ToString("D")));
                update.ExecuteNonQuery();
                return;
            }

            var position = ScalarLong("SELECT COALESCE(MAX(position),-1)+1 FROM user_group");
            using var insert = CreateCommand(
                "INSERT INTO user_group(id,name,color,position) VALUES(@id,@name,@color,@position)",
                ("@id", Guid.NewGuid().ToString("D")),
                ("@name", trimmed),
                ("@color", groups.Count % 4),
                ("@position", position));
            insert.ExecuteNonQuery();
        });
    }

    private void DeleteGroupCore(Guid id)
    {
        RunGroupTransaction(() =>
        {
            // 仅由外键级联解除关系，不删除历史、表示或资产，也不触发保留期清理。
            using var delete = CreateCommand(
                "DELETE FROM user_group WHERE id=@id",
                ("@id", id.ToString("D")));
            delete.ExecuteNonQuery();
        });
    }

    private void MoveGroupCore(Guid id, int offset)
    {
        if (offset is not (-1 or 1))
        {
            throw new LibraryException(LibraryErrorCode.Storage);
        }

        RunGroupTransaction(() =>
        {
            // 持有写锁后重读，以稳定 GUID 定位，不能使用可能陈旧的 UI 索引。
            var groups = ReadGroupsCore();
            var index = groups.FindIndex(group => group.Id == id);
            if (index < 0)
            {
                throw new LibraryException(LibraryErrorCode.MissingGroup);
            }

            var destination = index + offset;
            if (destination < 0 || destination >= groups.Count)
            {
                return;
            }

            (groups[index], groups[destination]) = (groups[destination], groups[index]);
            for (var position = 0; position < groups.Count; position++)
            {
                using var update = CreateCommand(
                    "UPDATE user_group SET position=@position WHERE id=@id",
                    ("@position", position),
                    ("@id", groups[position].Id.ToString("D")));
                update.ExecuteNonQuery();
            }
        });
    }


    private List<ClipRepresentation> RepresentationsCore(Guid id)
    {
        EnsureInitialized();
        var result = new List<ClipRepresentation>();
        long total = 0;
        using var command = CreateCommand(
            """
            SELECT item_order,type,filename,byte_size FROM representation
            WHERE entry_id=@id
            ORDER BY item_order,
                CASE type
                    WHEN 'windows/file-list' THEN 0
                    WHEN 'text/plain' THEN 1
                    WHEN 'text/url' THEN 2
                    WHEN 'text/rtf' THEN 3
                    WHEN 'text/html' THEN 4
                    WHEN 'image/png' THEN 5
                    ELSE 6
                END,
                id
            """,
            ("@id", id.ToString("D")));
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            var type = reader.GetString(1);
            var filename = reader.GetString(2);
            var expected = reader.GetInt64(3);
            total += expected;
            if (total > StorageLimits.MaximumCaptureBytes)
            {
                throw new LibraryException(LibraryErrorCode.MissingContent);
            }

            var path = AssetPath(filename);
            if (path is null || !IsSafeAssetFile(path, expected))
            {
                throw new LibraryException(LibraryErrorCode.MissingContent);
            }

            byte[] data;
            try
            {
                data = File.ReadAllBytes(path);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                throw new LibraryException(LibraryErrorCode.MissingContent, exception);
            }

            result.Add(new ClipRepresentation(reader.GetInt32(0), type, data));
        }

        if (result.Count == 0)
        {
            throw new LibraryException(LibraryErrorCode.MissingContent);
        }

        return result;
    }

    /// <summary>
    /// 文件引用可读性检查可能因断开的网络卷或异常磁盘永久阻塞，
    /// 因此只在串行存储队列之外等待，超过 3 秒按“原文件不可用”处理。
    /// </summary>
    private static async Task EnsureFileReferencesAvailableAsync(
        IReadOnlyList<ClipRepresentation> representations,
        CancellationToken cancellationToken)
    {
        var files = representations
            .Where(item => item.Type == "windows/file-list")
            .SelectMany(item => DecodeFileList(item.Data))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (files.Length == 0)
        {
            return;
        }

        var check = Task.Run(
            () => files.All(path => File.Exists(path) || Directory.Exists(path)),
            CancellationToken.None);
        var timeout = Task.Delay(TimeSpan.FromSeconds(3), cancellationToken);
        var completed = await Task.WhenAny(check, timeout).ConfigureAwait(false);
        if (completed != check)
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw new LibraryException(LibraryErrorCode.UnavailableFile);
        }

        if (!await check.ConfigureAwait(false))
        {
            throw new LibraryException(LibraryErrorCode.UnavailableFile);
        }
    }

    private List<ClipRepresentation> PlainTextCore(Guid id, ClipKind kind)
    {
        if (kind is not (ClipKind.Text or ClipKind.Link))
        {
            throw new LibraryException(LibraryErrorCode.Unsupported);
        }

        var originals = RepresentationsCore(id);
        var parts = new List<string>();
        long bytes = 0;
        var richTextBudget = StorageLimits.MaximumRichTextPreviewBytes;
        foreach (var itemIndex in originals.Select(item => item.Item).Distinct().OrderBy(item => item))
        {
            var items = originals.Where(item => item.Item == itemIndex).ToList();
            string? value = null;
            if (kind == ClipKind.Link)
            {
                value = DecodeText(items.FirstOrDefault(item => item.Type == "text/url")?.Data)
                        ?? DecodeText(items.FirstOrDefault(item => item.Type == "text/plain")?.Data);
            }
            else
            {
                value = DecodeText(items.FirstOrDefault(item => item.Type == "text/plain")?.Data)
                        ?? DecodeText(items.FirstOrDefault(item => item.Type == "text/url")?.Data);
            }

            var rtf = items.FirstOrDefault(item => item.Type == "text/rtf")?.Data;
            if (value is null && rtf is { Length: > 0 })
            {
                // RTF 解析预算跨条目共享；超限明确失败，不返回截断的粘贴内容。
                if (rtf.Length > richTextBudget)
                {
                    throw new LibraryException(LibraryErrorCode.RichTextTooLarge);
                }

                richTextBudget -= rtf.Length;
                value = TextExtraction.FromRtf(rtf, StorageLimits.SearchableCharacters);
            }

            value ??= TextExtraction.FromHtml(
                items.FirstOrDefault(item => item.Type == "text/html")?.Data ?? [],
                StorageLimits.SearchableCharacters);
            if (value is null)
            {
                throw new LibraryException(LibraryErrorCode.PlainTextUnavailable);
            }

            bytes += Encoding.UTF8.GetByteCount(value) + (parts.Count == 0 ? 0 : 1);
            if (bytes > StorageLimits.MaximumCaptureBytes)
            {
                throw new LibraryException(LibraryErrorCode.Unsupported);
            }

            parts.Add(value);
        }

        var text = string.Join("\n", parts);
        if (text.Length == 0)
        {
            throw new LibraryException(LibraryErrorCode.PlainTextUnavailable);
        }

        return [new ClipRepresentation(0, "text/plain", Encoding.UTF8.GetBytes(text))];
    }

    private ClipPreviewData PreviewCore(Guid id)
    {
        EnsureInitialized();
        var text = new StringBuilder();
        var textItems = new HashSet<int>();
        var filePaths = new List<string>();
        string? imagePath = null;
        var truncated = false;
        var hasFileReference = false;
        var richTextBudget = StorageLimits.MaximumRichTextPreviewBytes;

        using var command = CreateCommand(
            """
            SELECT item_order,type,filename,byte_size FROM representation
            WHERE entry_id=@id
            ORDER BY item_order,
                CASE type
                    WHEN 'windows/file-list' THEN 0
                    WHEN 'text/plain' THEN 1
                    WHEN 'text/url' THEN 2
                    WHEN 'text/rtf' THEN 3
                    WHEN 'text/html' THEN 4
                    WHEN 'image/png' THEN 5
                    ELSE 6
                END,
                id
            """,
            ("@id", id.ToString("D")));
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            var itemOrder = reader.GetInt32(0);
            var type = reader.GetString(1);
            var filename = reader.GetString(2);
            var expected = reader.GetInt64(3);
            var path = AssetPath(filename);
            if (path is null || !IsSafeAssetFile(path, expected))
            {
                continue;
            }

            if (type == "windows/file-list")
            {
                hasFileReference = true;
                if (ReadFilePrefix(path, StorageLimits.MaximumRepresentationBytes) is not { } data)
                {
                    continue;
                }

                var files = DecodeFileList(data);
                if (files.Length == 0)
                {
                    continue;
                }

                filePaths.AddRange(files);
                if (imagePath is null && files.All(IsImagePath))
                {
                    // 只按扩展名选择候选；是否可读与解码由视图层在存储队列外限时完成。
                    imagePath = files.FirstOrDefault();
                }

                if (!textItems.Contains(itemOrder))
                {
                    var names = files.Select(Path.GetFileName).OfType<string>().ToArray();
                    AppendPreviewText(text, string.Join("\n", names), itemOrder, textItems, ref truncated);
                }

                continue;
            }

            if (type == "image/png")
            {
                imagePath ??= path;
                continue;
            }

            if (textItems.Contains(itemOrder))
            {
                continue;
            }

            string? value = null;
            switch (type)
            {
                case "text/plain":
                case "text/url":
                    {
                        var remaining = StorageLimits.MaximumPreviewTextBytes - text.Length;
                        if (remaining <= 0)
                        {
                            truncated = true;
                            continue;
                        }

                        var data = ReadFilePrefix(path, remaining * 4 + 4);
                        if (data is not null)
                        {
                            value = Encoding.UTF8.GetString(data);
                        }

                        break;
                    }
                case "text/rtf":
                    {
                        if (richTextBudget <= 0)
                        {
                            truncated = true;
                            continue;
                        }

                        var data = ReadFilePrefix(path, richTextBudget);
                        if (data is not null)
                        {
                            richTextBudget -= data.Length;
                            value = TextExtraction.FromRtf(data);
                        }

                        break;
                    }
                case "text/html":
                    {
                        var data = ReadFilePrefix(path, Math.Min(StorageLimits.MaximumRichTextPreviewBytes, richTextBudget));
                        if (data is not null)
                        {
                            richTextBudget -= data.Length;
                            value = TextExtraction.FromHtml(data);
                        }

                        break;
                    }
            }

            if (value is null)
            {
                continue;
            }

            AppendPreviewText(text, value, itemOrder, textItems, ref truncated);
        }

        if (truncated)
        {
            text.Append("\n…预览已截断，复制保留原始内容");
        }

        return new ClipPreviewData(text.ToString(), imagePath, filePaths, truncated, hasFileReference);
    }

    private static void AppendPreviewText(
        StringBuilder target,
        string value,
        int itemOrder,
        HashSet<int> textItems,
        ref bool truncated)
    {
        if (string.IsNullOrEmpty(value))
        {
            return;
        }

        var remaining = StorageLimits.MaximumPreviewTextBytes - target.Length;
        if (remaining <= 1)
        {
            truncated = true;
            return;
        }

        if (target.Length > 0)
        {
            target.Append('\n');
            remaining--;
        }

        var bounded = TextExtraction.Truncate(value, Math.Max(1, remaining));
        target.Append(bounded);
        textItems.Add(itemOrder);
        if (bounded.Length < value.Length)
        {
            truncated = true;
        }
    }

    private string? ThumbnailSourceCore(Guid id)
    {
        EnsureInitialized();
        using var command = CreateCommand(
            """
            SELECT type,filename FROM representation
            WHERE entry_id=@id
            ORDER BY
                CASE type
                    WHEN 'image/png' THEN 0
                    WHEN 'windows/file-list' THEN 1
                    ELSE 2
                END,
                item_order,id
            """,
            ("@id", id.ToString("D")));
        using var reader = command.ExecuteReader();
        string[]? files = null;
        while (reader.Read())
        {
            var type = reader.GetString(0);
            var filename = reader.GetString(1);
            if (type == "image/png")
            {
                var path = AssetPath(filename);
                if (path is not null && IsSafeAssetFile(path))
                {
                    return path;
                }
            }
            else if (type == "windows/file-list" && files is null)
            {
                var path = AssetPath(filename);
                if (path is not null && IsSafeAssetFile(path) &&
                    ReadFilePrefix(path, StorageLimits.MaximumRepresentationBytes) is { } data)
                {
                    files = DecodeFileList(data);
                }
            }
        }

        return files?.All(IsImagePath) == true ? files.FirstOrDefault() : null;
    }

    private static byte[]? ReadFilePrefix(string path, int maximumBytes)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            var length = (int)Math.Min(Math.Max(0, maximumBytes), stream.Length);
            var buffer = new byte[length];
            var offset = 0;
            while (offset < length)
            {
                var read = stream.Read(buffer, offset, length - offset);
                if (read <= 0)
                {
                    break;
                }

                offset += read;
            }

            return offset == 0 ? [] : buffer.AsSpan(0, offset).ToArray();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static string? DecodeText(byte[]? data)
    {
        if (data is null || data.Length == 0)
        {
            return null;
        }

        return Encoding.UTF8.GetString(data);
    }

    public static byte[] EncodeFileList(IEnumerable<string> files)
    {
        var text = string.Join('\0', files.Where(file => !string.IsNullOrEmpty(file)));
        return Encoding.UTF8.GetBytes(text);
    }

    public static string[] DecodeFileList(byte[] data)
    {
        if (data.Length == 0)
        {
            return [];
        }

        return Encoding.UTF8.GetString(data)
            .Split('\0', StringSplitOptions.RemoveEmptyEntries)
            .Take(StorageLimits.MaximumFileReferences)
            .ToArray();
    }

    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tif", ".tiff", ".heic", ".heif", ".ico"
    };

    /// <summary>按扩展名判断文件引用是否能作为图片卡片展示，不访问磁盘。</summary>
    public static bool IsImagePath(string path) =>
        ImageExtensions.Contains(Path.GetExtension(path));

    /// <summary>目录 / 文件本身是符号链接、目录联接或其他重解析点时返回 true。</summary>
    private static bool IsReparsePoint(string path)
    {
        try
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    /// <summary>
    /// 存储资产必须是本目录内的普通文件：拒绝符号链接 / 重解析点、目录、
    /// 离线占位文件以及大小不符的替换文件。
    /// </summary>
    private static bool IsSafeAssetFile(string path, long? expectedLength = null)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists)
            {
                return false;
            }

            var attributes = info.Attributes;
            if (attributes.HasFlag(FileAttributes.Directory) ||
                attributes.HasFlag(FileAttributes.ReparsePoint) ||
                attributes.HasFlag(FileAttributes.Offline))
            {
                return false;
            }

            // 普通资产应只有一个目录项；硬链接替换同样视为不可信。
            if (!HasSingleLink(path))
            {
                return false;
            }

            return expectedLength is { } expected ? info.Length == expected : info.Length > 0;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    private void RecoverAssetsCore()
    {
        if (_connection is null)
        {
            throw new LibraryException(LibraryErrorCode.Storage);
        }

        var referenced = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var command = CreateCommand("SELECT filename FROM representation"))
        using (var reader = command.ExecuteReader())
        {
            while (reader.Read())
            {
                referenced.Add(reader.GetString(0));
            }
        }

        foreach (var file in Directory.EnumerateFiles(AssetsDirectory))
        {
            var name = Path.GetFileName(file);
            if (name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase))
            {
                TryDelete(file);
                continue;
            }

            if (Guid.TryParseExact(name, "N", out _) && !referenced.Contains(name))
            {
                TryDelete(file);
            }
        }
    }

    private string? AssetPath(string filename)
    {
        if (!Guid.TryParseExact(filename, "N", out _))
        {
            return null;
        }

        var full = Path.GetFullPath(Path.Combine(AssetsDirectory, filename));
        var root = Path.GetFullPath(AssetsDirectory) + Path.DirectorySeparatorChar;
        return full.StartsWith(root, StringComparison.OrdinalIgnoreCase) ? full : null;
    }

    private static void WriteAsset(string path, byte[] data)
    {
        var temporary = path + ".tmp";
        try
        {
            using (var stream = new FileStream(
                       temporary,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None,
                       81920,
                       FileOptions.WriteThrough))
            {
                stream.Write(data);
                stream.Flush(true);
            }

            File.Move(temporary, path);
        }
        catch
        {
            TryDelete(temporary);
            throw;
        }
    }

    private static void DeleteAssets(IEnumerable<string> paths)
    {
        foreach (var path in paths)
        {
            TryDelete(path);
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // 清理失败不影响元数据一致性；启动恢复会再次回收孤立文件。
        }
    }

    private void TryRollback()
    {
        try
        {
            using var rollback = CreateCommand("ROLLBACK");
            rollback.ExecuteNonQuery();
        }
        catch (Exception)
        {
            // 事务可能已因错误自动回滚；保留原始异常。
        }
    }

    private static string EscapeLike(string value) =>
        value.Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("%", "\\%", StringComparison.Ordinal)
            .Replace("_", "\\_", StringComparison.Ordinal);

    /// <summary>通过句柄读取链接数，避免路径在检查后被替换成硬链接。</summary>
    private static bool HasSingleLink(string path)
    {
        try
        {
            using var handle = File.OpenHandle(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            return GetFileInformationByHandle(handle, out var information) &&
                   information.NumberOfLinks == 1;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public uint CreationTimeLow;
        public uint CreationTimeHigh;
        public uint LastAccessTimeLow;
        public uint LastAccessTimeHigh;
        public uint LastWriteTimeLow;
        public uint LastWriteTimeHigh;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file,
        out ByHandleFileInformation information);

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            CloseConnection();
        }
        finally
        {
            _gate.Release();
            _gate.Dispose();
        }
    }
}
