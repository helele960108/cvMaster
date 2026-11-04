/**
 * 分组同步存储合成验证；所有数据库、资产与外部引用都位于 runner 的临时目录。
 * 不调用 GetRepresentations / 预览等 Win32 硬链接校验路径，不接触 UI 或剪贴板。
 */
using System.Text;
using System.Text.Json;
using CvMaster.Core;
using Microsoft.Data.Sqlite;

namespace CvMaster.SmokeTests;

internal static class GroupChecks
{
    internal static async Task RunAsync(
        string root,
        Action<string, bool> check,
        Func<ClipKind, string, ClipRepresentation[], ClipCapture> capture,
        Func<HistoryStore, string, Task<HistoryPage>> page)
    {
        Console.WriteLine("Group storage tests (synthetic, cross-platform)");
        await DeleteAsync(new Fixture(Path.Combine(root, "delete"), capture, page), check);
        await OrderAsync(new Fixture(Path.Combine(root, "order"), capture, page), check);
        await NamesAsync(new Fixture(Path.Combine(root, "names"), capture, page), check);
        await RollbackAsync(new Fixture(Path.Combine(root, "rollback"), capture, page), check);
    }

    private static async Task DeleteAsync(Fixture fixture, Action<string, bool> check)
    {
        await using var f = fixture;
        await f.InitializeAsync();
        var removed = await f.AddGroupAsync("待删除");
        var kept = await f.AddGroupAsync("保留");
        var empty = await f.AddGroupAsync("空分组");
        var shared = await f.AddClipAsync("共享置顶内容");
        var only = await f.AddClipAsync("仅归属待删组");
        var reference = await f.AddClipAsync("合成文件引用", fileReference: true);
        await f.AddClipAsync("过期但未分组内容");
        await f.Store.SetPinnedAsync(shared.Id, true);
        await f.Store.MarkCopiedAsync(shared.Id);
        await f.Store.MarkCopiedAsync(shared.Id);
        await f.Store.MarkCopiedAsync(only.Id);
        foreach (var clip in new[] { shared, only, reference })
        {
            await f.Store.SetGroupAsync(clip.Id, removed.Id, true);
        }
        await f.Store.SetGroupAsync(shared.Id, kept.Id, true);
        await f.Store.SetGroupAsync(reference.Id, kept.Id, true);
        f.Execute("UPDATE entry SET copied_at=1");
        f.AddRecoveryCanaries();
        f.Execute("""
            CREATE TRIGGER smoke_no_entry_delete BEFORE DELETE ON entry
            BEGIN SELECT RAISE(FAIL,'group operation must not prune'); END;
            CREATE TRIGGER smoke_no_entry_update BEFORE UPDATE ON entry
            BEGIN SELECT RAISE(FAIL,'group operation must not change clips'); END;
            """);
        var content = f.ContentState();
        var assets = f.Assets();
        var survivingMemberships = f.Rows(
            "SELECT * FROM entry_group WHERE group_id<>@id ORDER BY entry_id,group_id", ("@id", removed.Id));
        var memberships = f.Memberships();

        await f.Store.DeleteGroupAsync(empty.Id);
        check("删除空分组仅移除目录项", (await f.Store.GetGroupsAsync()).SequenceEqual(new[] { removed, kept }) &&
            f.Memberships().SequenceEqual(memberships) && f.ContentState() == content);
        check("删除空分组不回收任何资产", f.AssetsMatch(assets));

        await f.Store.DeleteGroupAsync(removed.Id);
        var clips = (await f.PageAsync()).Clips;
        check("删除非空分组保留全部条目及原始元数据", f.ContentState() == content && clips.Count == 4);
        check("删除分组保留置顶、copies 与其它归属", clips.Single(c => c.Id == shared.Id) is { Pinned: true, Copies: 3 } sharedAfter &&
            sharedAfter.Groups.SetEquals(new[] { kept.Id }) &&
            clips.Single(c => c.Id == only.Id) is { Pinned: false, Copies: 2 } onlyAfter && onlyAfter.Groups.Count == 0 &&
            f.Memberships().SequenceEqual(survivingMemberships));
        check("删除后的旧分组筛选为空，其它分组仍可筛选", (await f.PageAsync(removed.Id.ToString("D"))).Total == 0 &&
            (await f.PageAsync(kept.Id.ToString("D"))).Total == 2);
        check("删除分组不触发 prune 或 asset recovery，资产逐字节保留", f.AssetsMatch(assets));
        check("合成外部引用文件保留原字节", f.ExternalFileIntact());
        check("未删分组 GUID、名称、颜色和顺序不变", (await f.Store.GetGroupsAsync()).SequenceEqual(new[] { kept }));

        var state = f.DatabaseState();
        await f.Store.DeleteGroupAsync(removed.Id);
        await f.Store.DeleteGroupAsync(Guid.NewGuid());
        check("重复删除与删除缺失分组幂等", f.DatabaseState() == state && f.AssetsMatch(assets));
        await f.Store.DeleteGroupAsync(kept.Id);
        check("删除最后分组只解除归属，不删除历史", (await f.Store.GetGroupsAsync()).Count == 0 &&
            f.Memberships().Length == 0 && f.ContentState() == content && (await f.PageAsync()).Total == 4);
        await f.Store.DeleteGroupAsync(kept.Id);
        check("最后分组重复删除仍幂等，资产及外部引用不变", f.AssetsMatch(assets) && f.ExternalFileIntact());
        f.CheckIntegrity(check, "删除分组");
    }

    private static async Task OrderAsync(Fixture fixture, Action<string, bool> check)
    {
        await using var f = fixture;
        await f.InitializeAsync();
        var a = await f.AddGroupAsync("A");
        var b = await f.AddGroupAsync("B");
        var c = await f.AddGroupAsync("C");
        var old = await f.AddClipAsync("排序期间的历史");
        await f.Store.SetGroupAsync(old.Id, b.Id, true);
        await f.Store.SetPinnedAsync(old.Id, true);
        f.Execute("UPDATE user_group SET position=CASE name WHEN 'A' THEN 3 WHEN 'B' THEN 11 ELSE 27 END");
        var d = await f.AddGroupAsync("D");
        check("position 有空洞时新建分组追加至真实末尾", f.Positions().SequenceEqual(new long[] { 3, 11, 27, 28 }) &&
            (await f.Store.GetGroupsAsync()).Select(g => g.Id).SequenceEqual(new[] { a.Id, b.Id, c.Id, d.Id }));
        var content = f.ContentState();
        var memberships = f.Memberships();
        f.AddRecoveryCanaries();
        var assets = f.Assets();
        var metadata = f.Rows("SELECT id,name,color FROM user_group ORDER BY id");
        await f.Store.MoveGroupAsync(c.Id, -1);
        await f.CheckOrderAsync(check, "上移使用相邻目录位置并收拢空洞", a.Id, c.Id, b.Id, d.Id);
        await f.Store.MoveGroupAsync(a.Id, 1);
        await f.CheckOrderAsync(check, "下移与相邻分组交换", c.Id, a.Id, b.Id, d.Id);
        check("移动不改变分组 GUID、名称或颜色", f.Rows("SELECT id,name,color FROM user_group ORDER BY id").SequenceEqual(metadata));
        await CheckNoWritesAsync(f, check, c.Id, d.Id);

        // 先持有旧投影，再由独立连接重排、改名并插入，禁止按旧 index 定位 B。
        var cached = await f.Store.GetGroupsAsync();
        var external = Guid.NewGuid();
        f.Execute("UPDATE user_group SET position=CASE name WHEN 'D' THEN 2 WHEN 'B' THEN 12 WHEN 'A' THEN 37 ELSE 49 END");
        f.Execute("UPDATE user_group SET name='B 外部',color=7 WHERE id=@id", ("@id", b.Id));
        f.Execute("INSERT INTO user_group(id,name,color,position) VALUES(@id,'另一连接新增',9,25)", ("@id", external));
        await f.Store.MoveGroupAsync(cached.Single(g => g.Id == b.Id).Id, 1);
        await f.CheckOrderAsync(check, "另一连接修改后按 GUID 在最新目录定位", d.Id, external, b.Id, a.Id, c.Id);
        check("移动保留另一连接改名、颜色与新建目录项", (await f.Store.GetGroupsAsync()).Single(g => g.Id == b.Id) ==
            new ClipGroup(b.Id, "B 外部", 7) && (await f.Store.GetGroupsAsync()).Single(g => g.Id == external).ColorIndex == 9);
        f.Execute("DELETE FROM user_group WHERE id=@id", ("@id", d.Id));
        var afterExternalDelete = f.DatabaseState();
        await ExpectErrorAsync(check, "另一连接已删除的旧 GUID 返回 MissingGroup", LibraryErrorCode.MissingGroup,
            () => f.Store.MoveGroupAsync(cached.Single(g => g.Id == d.Id).Id, -1));
        check("缺失 GUID 不影响其它目录项", f.DatabaseState() == afterExternalDelete);
        check("所有移动保留条目、归属与资产", f.ContentState() == content && f.Memberships().SequenceEqual(memberships) && f.AssetsMatch(assets));

        f.RemoveRecoveryCanaries();
        assets = f.Assets();
        var persisted = f.DatabaseState();
        var ordered = (await f.Store.GetGroupsAsync()).ToArray();
        await f.ReopenAsync();
        check("重开存储保留分组元数据、顺序、归属及 positions", f.DatabaseState() == persisted &&
            (await f.Store.GetGroupsAsync()).SequenceEqual(ordered) && f.AssetsMatch(assets));
        await f.AddClipAsync("清理时保留的新历史");
        f.Execute("UPDATE entry SET copied_at=1 WHERE id=@id", ("@id", old.Id));
        var directory = f.GroupState();
        var removed = await f.Store.ClearAsync(DateTimeOffset.FromUnixTimeMilliseconds(2));
        check("按时间清理历史不改变完整分组目录和顺序", removed == 1 && (await f.PageAsync()).Total == 1 && f.GroupState() == directory &&
            (await f.Store.GetGroupsAsync()).SequenceEqual(ordered));
        check("清空历史保留完整分组目录和顺序", await f.Store.ClearAsync(null) == 1 &&
            (await f.PageAsync()).Total == 0 && f.GroupState() == directory && (await f.Store.GetGroupsAsync()).SequenceEqual(ordered));
        check("空历史再次清理仍保留分组", await f.Store.ClearAsync(null) == 0 && f.GroupState() == directory && f.Memberships().Length == 0);
        await f.ReopenAsync();
        check("清理后重开仍保留完整目录和顺序", f.GroupState() == directory && (await f.Store.GetGroupsAsync()).SequenceEqual(ordered));
        f.CheckIntegrity(check, "排序与清理历史");

        await using var single = new Fixture(Path.Combine(f.DirectoryPath, "single"), f.Capture, f.Page);
        await single.InitializeAsync();
        var one = await single.AddGroupAsync("唯一分组");
        single.Execute("UPDATE user_group SET position=17");
        await CheckNoWritesAsync(single, check, one.Id, one.Id);
        await single.Store.DeleteGroupAsync(one.Id);
        await ExpectErrorAsync(check, "空目录移动缺失 GUID", LibraryErrorCode.MissingGroup, () => single.Store.MoveGroupAsync(one.Id, 1));
        var replacement = await single.AddGroupAsync("重新创建");
        await single.CheckOrderAsync(check, "删除最后分组后新建从 position 0 开始", replacement.Id);
        single.CheckIntegrity(check, "单分组与空目录");
    }

    private static async Task CheckNoWritesAsync(Fixture f, Action<string, bool> check, Guid first, Guid last)
    {
        f.Execute("""
            CREATE TRIGGER smoke_no_group_update BEFORE UPDATE ON user_group
            BEGIN SELECT RAISE(FAIL,'no-op must not update'); END;
            CREATE TRIGGER smoke_no_group_insert BEFORE INSERT ON user_group
            BEGIN SELECT RAISE(FAIL,'no-op must not insert'); END;
            CREATE TRIGGER smoke_no_group_delete BEFORE DELETE ON user_group
            BEGIN SELECT RAISE(FAIL,'no-op must not delete'); END;
            """);
        try
        {
            var state = f.DatabaseState();
            var version = f.Scalar("PRAGMA data_version");
            await f.Store.MoveGroupAsync(first, -1);
            await f.Store.MoveGroupAsync(last, 1);
            check(first == last ? "单分组两端移动不写入且不归一化 position" : "首尾越界移动不写入数据库",
                f.DatabaseState() == state && f.Scalar("PRAGMA data_version") == version);
            foreach (var offset in new[] { 0, -2, 2, int.MinValue, int.MaxValue })
            {
                await ExpectErrorAsync(check, $"无效 offset {offset} 返回 Storage", LibraryErrorCode.Storage,
                    () => f.Store.MoveGroupAsync(first, offset));
            }
            foreach (var offset in new[] { -1, 1 })
            {
                await ExpectErrorAsync(check, $"缺失分组 offset {offset} 返回 MissingGroup", LibraryErrorCode.MissingGroup,
                    () => f.Store.MoveGroupAsync(Guid.NewGuid(), offset));
            }
            check("无效与缺失移动保持元数据且没有提交写入", f.DatabaseState() == state && f.Scalar("PRAGMA data_version") == version);
        }
        finally
        {
            f.Execute("DROP TRIGGER smoke_no_group_update; DROP TRIGGER smoke_no_group_insert; DROP TRIGGER smoke_no_group_delete");
        }
    }

    private static async Task NamesAsync(Fixture fixture, Action<string, bool> check)
    {
        await using var f = fixture;
        await f.InitializeAsync();
        var target = await f.AddGroupAsync("  Work  ");
        var other = await f.AddGroupAsync("其它组");
        var clip = await f.AddClipAsync("重命名保留归属");
        await f.Store.SetGroupAsync(clip.Id, target.Id, true);
        await f.Store.SetGroupAsync(clip.Id, other.Id, true);
        await f.Store.SetPinnedAsync(clip.Id, true);
        await f.Store.MarkCopiedAsync(clip.Id);
        f.Execute("UPDATE user_group SET position=position*9+4");
        f.AddRecoveryCanaries();
        var content = f.ContentState();
        var memberships = f.Memberships();
        var assets = f.Assets();
        var identity = f.Rows("SELECT id,color,position FROM user_group ORDER BY position,id");
        check("创建分组 trim 后保存名称", target.Name == "Work");
        await f.Store.SaveGroupAsync(target.Id, " work ");
        await f.Store.SaveGroupAsync(target.Id, "重命名");
        check("重命名保留 GUID、颜色、位置、其它目录项和归属", f.Rows("SELECT id,color,position FROM user_group ORDER BY position,id").SequenceEqual(identity) &&
            (await f.Store.GetGroupsAsync()).SequenceEqual(new[] { target with { Name = "重命名" }, other }) &&
            f.ContentState() == content && f.Memberships().SequenceEqual(memberships));
        await f.Store.SaveGroupAsync(target.Id, "Work");
        var beforeFailures = f.DatabaseState();
        foreach (var name in new[] { "", " \t\r\n ", new string('a', 21), "work", "Ｗｏｒｋ" })
        {
            await ExpectErrorAsync(check, $"无效或冲突名称拒绝（{TextExtraction.CountTextElements(name)} 文本元素）", LibraryErrorCode.NameConflict,
                () => f.Store.SaveGroupAsync(null, name));
        }
        await ExpectErrorAsync(check, "重命名到其它现有名称拒绝", LibraryErrorCode.NameConflict, () => f.Store.SaveGroupAsync(target.Id, other.Name));
        await ExpectErrorAsync(check, "缺失 GUID 重命名返回 MissingGroup", LibraryErrorCode.MissingGroup, () => f.Store.SaveGroupAsync(Guid.NewGuid(), "新名称"));
        check("名称校验失败不改变数据库", f.DatabaseState() == beforeFailures);

        var combining = string.Concat(Enumerable.Repeat("e\u0301", 20));
        var emoji = string.Concat(Enumerable.Repeat("👩‍💻", 20));
        var composed = await f.AddGroupAsync(combining);
        var emojiGroup = await f.AddGroupAsync(emoji);
        check("20 个组合字符或 emoji 文本元素可创建", composed.Name == combining && emojiGroup.Name == emoji);
        await ExpectErrorAsync(check, "21 个组合文本元素拒绝", LibraryErrorCode.NameConflict, () => f.Store.SaveGroupAsync(null, combining + "e\u0301"));
        await ExpectErrorAsync(check, "21 个 emoji 文本元素重命名拒绝", LibraryErrorCode.NameConflict, () => f.Store.SaveGroupAsync(emojiGroup.Id, emoji + "👩‍💻"));
        check("分组名称 UTF8 上限固定为 1024", StorageLimits.MaximumGroupNameBytes == 1024);
        var atLimit = "é" + new string('\u0301', (StorageLimits.MaximumGroupNameBytes - 2) / 2);
        var overLimit = "e" + new string('\u0301', StorageLimits.MaximumGroupNameBytes / 2);
        var byteGroup = await f.AddGroupAsync(atLimit);
        check("单个文本元素在 UTF8 1024 字节边界可保存", Encoding.UTF8.GetByteCount(byteGroup.Name) == 1024 && byteGroup.Name == atLimit);
        await ExpectErrorAsync(check, "文本元素合规但 UTF8 超限的创建拒绝", LibraryErrorCode.NameConflict, () => f.Store.SaveGroupAsync(null, overLimit));
        await ExpectErrorAsync(check, "文本元素合规但 UTF8 超限的重命名拒绝", LibraryErrorCode.NameConflict, () => f.Store.SaveGroupAsync(byteGroup.Id, overLimit));
        var padded = await f.AddGroupAsync(new string(' ', StorageLimits.MaximumGroupNameBytes - 1) + "x");
        check("原名恰为 1024 字节可 trim 后保存", padded.Name == "x");
        var beforePaddedFailure = f.DatabaseState();
        await ExpectErrorAsync(check, "trim 后短名称仍拒绝原名超 1024 字节", LibraryErrorCode.NameConflict,
            () => f.Store.SaveGroupAsync(null, new string(' ', StorageLimits.MaximumGroupNameBytes) + "y"));
        await ExpectErrorAsync(check, "重命名也校验 trim 前原名字节数", LibraryErrorCode.NameConflict,
            () => f.Store.SaveGroupAsync(target.Id, new string(' ', StorageLimits.MaximumGroupNameBytes) + "z"));
        check("字节超限不改变分组或内容，成功创建和重命名也不回收资产", f.DatabaseState() == beforePaddedFailure &&
            f.ContentState() == content && f.Memberships().SequenceEqual(memberships) && f.AssetsMatch(assets));
        f.CheckIntegrity(check, "名称与重命名");
    }

    private static async Task RollbackAsync(Fixture fixture, Action<string, bool> check)
    {
        await using var f = fixture;
        await f.InitializeAsync();
        var a = await f.AddGroupAsync("事务 A");
        var b = await f.AddGroupAsync("事务 B");
        await f.AddGroupAsync("事务 C");
        var clip = await f.AddClipAsync("事务中的文件引用", fileReference: true);
        await f.Store.SetGroupAsync(clip.Id, a.Id, true);
        await f.Store.SetGroupAsync(clip.Id, b.Id, true);
        await f.Store.SetPinnedAsync(clip.Id, true);
        await f.Store.MarkCopiedAsync(clip.Id);
        f.AddRecoveryCanaries();

        // RAISE(FAIL) 保留当前语句已发生的变更，只有显式事务回滚才能恢复快照。
        await AssertRollbackAsync(f, check, "创建分组", """
            CREATE TRIGGER smoke_fault AFTER INSERT ON user_group BEGIN
              UPDATE user_group SET color=color+10 WHERE id<>NEW.id;
              SELECT RAISE(FAIL,'smoke create failure');
            END;
            """, () => f.Store.SaveGroupAsync(null, "失败创建"));
        await AssertRollbackAsync(f, check, "重命名分组", """
            CREATE TRIGGER smoke_fault AFTER UPDATE OF name ON user_group BEGIN
              UPDATE user_group SET color=color+10;
              SELECT RAISE(FAIL,'smoke rename failure');
            END;
            """, () => f.Store.SaveGroupAsync(a.Id, "失败重命名"));
        await AssertRollbackAsync(f, check, "删除非空分组及级联关系", """
            CREATE TRIGGER smoke_fault AFTER DELETE ON user_group BEGIN
              UPDATE user_group SET color=color+10;
              SELECT RAISE(FAIL,'smoke delete failure');
            END;
            """, () => f.Store.DeleteGroupAsync(a.Id));

        f.Execute("UPDATE user_group SET position=position*10+5; CREATE TABLE smoke_position_writes(writes INTEGER NOT NULL); INSERT INTO smoke_position_writes VALUES(0)");
        await AssertRollbackAsync(f, check, "移动第二次 position 更新", """
            CREATE TRIGGER smoke_fault AFTER UPDATE OF position ON user_group BEGIN
              UPDATE smoke_position_writes SET writes=writes+1;
              SELECT CASE WHEN (SELECT writes FROM smoke_position_writes)=2
                THEN RAISE(FAIL,'smoke second position failure') END;
            END;
            """, () => f.Store.MoveGroupAsync(b.Id, -1));
        check("position 故障回滚也撤销触发器前两次计数", f.Scalar("SELECT writes FROM smoke_position_writes") == 0);
        f.Execute("DROP TABLE smoke_position_writes");
        // 去掉 canary 后才重开；启动恢复本身不属于分组操作。
        f.RemoveRecoveryCanaries();
        var persisted = f.DatabaseState();
        var assets = f.Assets();
        await f.ReopenAsync();
        check("故障回滚在重开后仍完整持久化", f.DatabaseState() == persisted && f.AssetsMatch(assets) && f.ExternalFileIntact());
        await f.Store.SaveGroupAsync(a.Id, "恢复后可重命名");
        await f.Store.MoveGroupAsync(b.Id, -1);
        await f.Store.DeleteGroupAsync(a.Id);
        await f.AddGroupAsync("恢复后可创建");
        check("故障后同一存储仍可创建、重命名、移动和删除", (await f.Store.GetGroupsAsync()).Any(g => g.Name == "恢复后可创建") &&
            (await f.PageAsync()).Total == 1 && f.ExternalFileIntact());
        f.CheckIntegrity(check, "故障后恢复");
    }

    private static async Task AssertRollbackAsync(Fixture f, Action<string, bool> check, string label, string trigger, Func<Task> operation)
    {
        f.Execute(trigger);
        try
        {
            var state = f.DatabaseState();
            var assets = f.Assets();
            await ExpectErrorAsync(check, label + " RAISE(FAIL) 映射 Storage", LibraryErrorCode.Storage, operation, "smoke ");
            check(label + "回滚完整数据库及资产字节", f.DatabaseState() == state && f.AssetsMatch(assets) && f.ExternalFileIntact());
            f.CheckIntegrity(check, label + "回滚");
        }
        finally
        {
            f.Execute("DROP TRIGGER smoke_fault");
        }
    }

    private static async Task ExpectErrorAsync(Action<string, bool> check, string label, LibraryErrorCode expected, Func<Task> operation,
        string? injectedMessage = null)
    {
        try
        {
            await operation();
            check(label, false);
        }
        catch (LibraryException exception)
        {
            check(label + $"（实际 {exception.Code}）", exception.Code == expected &&
                (injectedMessage is null || exception.InnerException is SqliteException sqlite &&
                    sqlite.Message.Contains(injectedMessage, StringComparison.Ordinal)));
        }
        catch (Exception exception)
        {
            check(label + $"（意外 {exception.GetType().Name}）", false);
        }
    }

    private sealed class Fixture : IAsyncDisposable
    {
        private readonly SqliteConnection _sql;
        private readonly List<string> _canaries = [];
        private static readonly byte[] ExternalBytes = Encoding.UTF8.GetBytes("synthetic external reference; never delete me");
        internal Fixture(string directory, Func<ClipKind, string, ClipRepresentation[], ClipCapture> capture,
            Func<HistoryStore, string, Task<HistoryPage>> page)
        {
            DirectoryPath = directory;
            Capture = capture;
            Page = page;
            Store = new HistoryStore(Path.Combine(directory, "library"));
            _sql = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = Store.DatabasePath,
                Mode = SqliteOpenMode.ReadWrite,
                Pooling = false
            }.ToString());
        }

        internal string DirectoryPath { get; }
        internal HistoryStore Store { get; private set; }
        internal Func<ClipKind, string, ClipRepresentation[], ClipCapture> Capture { get; }
        internal Func<HistoryStore, string, Task<HistoryPage>> Page { get; }
        private string ExternalPath => Path.Combine(DirectoryPath, "synthetic-reference.txt");

        internal async Task InitializeAsync()
        {
            await Store.InitializeAsync();
            await _sql.OpenAsync();
            Execute("PRAGMA foreign_keys=ON");
            await File.WriteAllBytesAsync(ExternalPath, ExternalBytes);
        }

        internal Task<HistoryPage> PageAsync(string scope = "all") => Page(Store, scope);

        internal async Task<ClipGroup> AddGroupAsync(string name)
        {
            var before = (await Store.GetGroupsAsync()).Select(g => g.Id).ToHashSet();
            await Store.SaveGroupAsync(null, name);
            return (await Store.GetGroupsAsync()).Single(g => !before.Contains(g.Id));
        }

        internal async Task<Clip> AddClipAsync(string text, bool fileReference = false)
        {
            var representation = new ClipRepresentation(0, fileReference ? "windows/file-list" : "text/plain",
                fileReference ? HistoryStore.EncodeFileList([ExternalPath]) : Encoding.UTF8.GetBytes(text));
            await Store.SaveAsync(Capture(fileReference ? ClipKind.File : ClipKind.Text, text, [representation]), 0);
            return (await PageAsync()).Clips.Single(c => c.Title == text);
        }

        internal async Task ReopenAsync()
        {
            await Store.DisposeAsync();
            Store = new HistoryStore(Path.Combine(DirectoryPath, "library"));
            await Store.InitializeAsync();
        }

        private SqliteCommand Command(string sql, params (string Name, object Value)[] values)
        {
            var command = _sql.CreateCommand();
            command.CommandText = sql;
            foreach (var (name, value) in values)
            {
                command.Parameters.AddWithValue(name, value is Guid id ? id.ToString("D") : value);
            }
            return command;
        }

        internal void Execute(string sql, params (string Name, object Value)[] values)
        {
            using var command = Command(sql, values);
            command.ExecuteNonQuery();
        }

        internal long Scalar(string sql)
        {
            using var command = Command(sql);
            return Convert.ToInt64(command.ExecuteScalar());
        }

        internal string[] Rows(string sql, params (string Name, object Value)[] values)
        {
            using var command = Command(sql, values);
            using var reader = command.ExecuteReader();
            var rows = new List<string>();
            while (reader.Read())
            {
                var cells = new object[reader.FieldCount];
                reader.GetValues(cells);
                rows.Add(JsonSerializer.Serialize(cells));
            }
            return rows.ToArray();
        }

        internal long[] Positions()
        {
            using var command = Command("SELECT position FROM user_group ORDER BY position,id");
            using var reader = command.ExecuteReader();
            var positions = new List<long>();
            while (reader.Read()) positions.Add(reader.GetInt64(0));
            return positions.ToArray();
        }

        internal string GroupState() => string.Join("\n", Rows("SELECT * FROM user_group ORDER BY position,id"));
        internal string[] Memberships() => Rows("SELECT * FROM entry_group ORDER BY entry_id,group_id");
        internal string ContentState() => JsonSerializer.Serialize(new[]
        {
            Rows("SELECT * FROM entry ORDER BY id"), Rows("SELECT * FROM representation ORDER BY id")
        });
        internal string DatabaseState() => JsonSerializer.Serialize(new[] { GroupState(), ContentState(), JsonSerializer.Serialize(Memberships()) });
        internal Dictionary<string, byte[]> Assets() => Directory.GetFiles(Store.AssetsDirectory)
            .ToDictionary(path => path, File.ReadAllBytes, StringComparer.Ordinal);
        internal bool AssetsMatch(Dictionary<string, byte[]> before) =>
            Directory.GetFiles(Store.AssetsDirectory).ToHashSet(StringComparer.Ordinal).SetEquals(before.Keys) &&
            before.All(pair => File.ReadAllBytes(pair.Key).AsSpan().SequenceEqual(pair.Value));
        internal bool ExternalFileIntact() => File.Exists(ExternalPath) && File.ReadAllBytes(ExternalPath).AsSpan().SequenceEqual(ExternalBytes);

        internal void AddRecoveryCanaries()
        {
            foreach (var name in new[] { Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N") + ".tmp" })
            {
                var path = Path.Combine(Store.AssetsDirectory, name);
                File.WriteAllBytes(path, Encoding.UTF8.GetBytes("must survive group operations"));
                _canaries.Add(path);
            }
        }

        internal void RemoveRecoveryCanaries()
        {
            foreach (var path in _canaries) File.Delete(path);
            _canaries.Clear();
        }

        internal async Task CheckOrderAsync(Action<string, bool> check, string label, params Guid[] ids) =>
            check(label, (await Store.GetGroupsAsync()).Select(g => g.Id).SequenceEqual(ids) &&
                Positions().SequenceEqual(Enumerable.Range(0, ids.Length).Select(i => (long)i)));

        internal void CheckIntegrity(Action<string, bool> check, string label)
        {
            check(label + " foreign_key_check", Rows("PRAGMA foreign_key_check").Length == 0 && Scalar("PRAGMA foreign_keys") == 1);
            using var command = Command("PRAGMA integrity_check");
            using var reader = command.ExecuteReader();
            var ok = reader.Read() && reader.GetString(0) == "ok";
            check(label + " integrity_check", ok && !reader.Read());
        }

        public async ValueTask DisposeAsync()
        {
            try
            {
                await _sql.DisposeAsync();
            }
            finally
            {
                await Store.DisposeAsync();
            }
        }
    }
}
