//! The in-memory facts behind `query_links`: for every link its host, registrable domain, site
//! and ccTLD; for every category its folded name and named country; and the entity facts put
//! for a link. Category views carry DFS pre-order numbers so a subtree test is a range test,
//! and they are rebuilt lazily after any category change. The string table interns every host,
//! domain, site and name once, so a fact refers to strings by id.

const std = @import("std");
const assert = std.debug.assert;
const inverted = @import("zigstore").inverted_index;
const schema = @import("../schema.zig");
const changeset = @import("../changeset.zig");
const countries = @import("countries.zig");
const url_facts = @import("url_facts.zig");
const sites = @import("sites.zig");
const entities = @import("entities.zig");
const adjacency = @import("adjacency.zig");
const derived_snapshot = @import("../derived_snapshot.zig");

pub const StringId = u32;
pub const IdSet = std.AutoHashMapUnmanaged(u64, void);

pub const folded_name_len_max: usize = 128;
pub const subtree_roots_max: usize = 8;

// Links written since the adjacency was last built are visited one by one beside it. Past this
// many the next reader rebuilds instead: at 3.04M links a rebuild sorts three row sets in about
// a second, so a backfill writing 40 links a second pays that once every 100 seconds.
pub const dirty_links_max: usize = 4096;

pub const neighbours_max: usize = 50;

// One walk reads at most this many of its source's links and passes over a category filed
// with more links than the second bound: imdb.com has 10,832 links, and a category shared with
// thousands of sites says little about any one of them.
const neighbour_source_links_max: usize = 2048;
const neighbour_category_links_max: usize = 512;

// A name carried by more categories than this is a filing template ("Business and Economy"
// sits under every region), not a subject, so its namesakes are not offered as related.
const namesakes_max: usize = 24;

const parents_that_file_things_by_name = std.StaticStringMap(void).initComptime(.{
    .{"Breeds"}, .{"Kitchen_and_Dining"}, .{"Poultry"},
});

pub const LinkFact = struct {
    category_id: u64,
    host: StringId,
    domain: StringId,
    site: StringId,
    cctld: countries.Code,
    status: u8,
    hosted: bool,
    subdomain: bool,
};

pub const CategoryFact = struct {
    parent_id: u64,
    name: StringId,
    named_country: countries.Code,
    files_things_by_name: bool,
};

pub const EntityFact = struct {
    religions: u16 = 0,
    countries: [entities.countries_max]countries.Code = undefined,
    country_count: u8 = 0,
    name_ids: [2 * entities.names_max]StringId = undefined,
    people_count: u8 = 0,
    org_count: u8 = 0,

    fn country_slice(self: *const EntityFact) []const countries.Code {
        assert(self.country_count <= entities.countries_max);
        return self.countries[0..self.country_count];
    }

    fn people(self: *const EntityFact) []const StringId {
        assert(self.people_count <= entities.names_max);
        assert(self.people_count + self.org_count <= self.name_ids.len);
        return self.name_ids[0..self.people_count];
    }

    fn orgs(self: *const EntityFact) []const StringId {
        assert(self.org_count <= entities.names_max);
        assert(self.people_count + self.org_count <= self.name_ids.len);
        return self.name_ids[self.people_count..][0..self.org_count];
    }

    fn all_names(self: *const EntityFact) []const StringId {
        assert(self.people_count <= entities.names_max);
        assert(self.org_count <= entities.names_max);
        return self.name_ids[0 .. self.people_count + self.org_count];
    }
};

pub const Via = struct {
    pub const cctld: u8 = 1;
    pub const category: u8 = 2;
    pub const entity: u8 = 4;
    pub const either: u8 = cctld | category;
    pub const all: u8 = cctld | category | entity;
};

pub const GroupBy = enum(u8) {
    none = 0,
    domain = 1,
    site = 2,
    host = 3,
    branch = 4,
    country = 5,
    religion = 6,
    person = 7,
    org = 8,
};

pub const Query = struct {
    category_id: u64 = 0,
    domain_suffix: []const u8 = "",
    country: ?countries.Code = null,
    via: u8 = Via.all,
    religions: u16 = 0,
    entity_name: []const u8 = "",
    hosted_only: bool = false,
    subdomain_only: bool = false,
    status: ?u8 = @intFromEnum(schema.LinkStatus.approved),
    allowed_ids: ?*const IdSet = null,
    group_by: GroupBy = .none,
    group_limit: u32 = 10,
    page_limit: u32 = 20,
    after_id: u64 = 0,
};

pub const Group = struct {
    label: []const u8,
    category_id: u64,
    links: u64,
    sites: u64,
};

pub const PageRow = struct {
    link_id: u64,
    site: []const u8,
    cctld: countries.Code,
    category_country: countries.Code,
    entity_countries: []const countries.Code,
    religions: u16,
};

/// Something close to what was asked about: a site by its key, an entity by its name, or a
/// category by its id. `shared` counts what ties the two: categories for sites, links for
/// entities, and for categories 1 when the name is the same and 0 when only the meaning is.
pub const Neighbour = struct {
    label: []const u8 = "",
    category_id: u64 = 0,
    shared: u32,
};

const Affinity = struct { weight: f64 = 0, shared: u32 = 0 };
const Affinities = std.AutoHashMapUnmanaged(StringId, Affinity);

const RankedAffinity = struct {
    key: StringId,
    affinity: Affinity,

    fn before(_: void, a: RankedAffinity, b: RankedAffinity) bool {
        if (a.affinity.weight != b.affinity.weight) return a.affinity.weight > b.affinity.weight;
        return a.key < b.key;
    }
};

pub const Answer = struct {
    total: u64,
    sites: u64,
    hosts: u64,
    domains: u64,
    categories: u64,
    groups: []const Group,
    page: []const PageRow,
    next_after_id: u64,
};

fn known(code: countries.Code) bool {
    if (code[0] != 0) assert(code[1] != 0);
    return code[0] != 0;
}

const Strings = struct {
    ids: std.StringHashMapUnmanaged(StringId) = .empty,
    values: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Strings, allocator: std.mem.Allocator) void {
        assert(self.ids.count() == self.values.items.len);
        for (self.values.items) |value| allocator.free(value);
        self.values.deinit(allocator);
        self.ids.deinit(allocator);
    }

    fn intern(self: *Strings, allocator: std.mem.Allocator, value: []const u8) !StringId {
        assert(self.ids.count() == self.values.items.len);
        if (self.ids.get(value)) |id| return id;

        const owned = try allocator.dupe(u8, value);
        errdefer allocator.free(owned);

        assert(self.values.items.len < std.math.maxInt(StringId));
        const id: StringId = @intCast(self.values.items.len);
        try self.values.append(allocator, owned);
        errdefer _ = self.values.pop();
        try self.ids.put(allocator, owned, id);
        assert(self.ids.count() == self.values.items.len);
        return id;
    }

    fn get(self: *const Strings, id: StringId) []const u8 {
        assert(id < self.values.items.len);
        return self.values.items[id];
    }
};

// The fixed rows of the derived snapshot. The string table is written first so every id a
// later row carries is checked against it as the row is read.
const LinkRecord = extern struct {
    id: u64,
    category_id: u64,
    host: StringId,
    domain: StringId,
    site: StringId,
    cctld: countries.Code,
    status: u8,
    hosted: u8,
    subdomain: u8,
    reserved: [7]u8,
};

const CategoryRecord = extern struct {
    id: u64,
    parent_id: u64,
    name: StringId,
    named_country: countries.Code,
    files_things_by_name: u8,
    reserved: [1]u8,
};

const entity_record_payload = 8 + 4 * 2 * entities.names_max + 2 * entities.countries_max + 5;
const entity_record_reserved = (8 - entity_record_payload % 8) % 8;

const EntityRecord = extern struct {
    link_id: u64,
    name_ids: [2 * entities.names_max]StringId,
    countries: [entities.countries_max]countries.Code,
    religions: u16,
    country_count: u8,
    people_count: u8,
    org_count: u8,
    reserved: [entity_record_reserved]u8,
};

comptime {
    assert(@sizeOf(LinkRecord) == 40);
    assert(@sizeOf(CategoryRecord) == 24);
    assert(@sizeOf(EntityRecord) == entity_record_payload + entity_record_reserved);
}

// The longest string the table can hold: hosts, registrable domains, site keys, entity names
// and folded category names are each bounded by their own maximum.
const snapshot_string_len_max: usize = @max(
    @max(url_facts.host_len_max, sites.site_len_max),
    @max(entities.name_len_max, folded_name_len_max),
);
const snapshot_rows_max: u64 = std.math.maxInt(u32);

pub const FactsIndex = struct {
    lock: std.Io.RwLock = .init,
    links: std.AutoHashMapUnmanaged(u64, LinkFact) = .empty,
    categories: std.AutoHashMapUnmanaged(u64, CategoryFact) = .empty,
    strings: Strings = .{},
    loading: bool = false,
    touched_links: IdSet = .empty,
    touched_categories: IdSet = .empty,
    entities: std.AutoHashMapUnmanaged(u64, EntityFact) = .empty,
    touched_entities: IdSet = .empty,
    name_ids: std.StringHashMapUnmanaged(StringId) = .empty,
    category_names: std.AutoHashMapUnmanaged(StringId, std.ArrayListUnmanaged(u64)) = .empty,
    category_views: std.AutoHashMapUnmanaged(u64, CategoryView) = .empty,
    categories_by_order: []u64 = &.{},
    views_stale: bool = true,
    by_category: adjacency.Adjacency = .{},
    by_domain: adjacency.Adjacency = .{},
    by_name: adjacency.Adjacency = .{},
    adjacency_built: bool = false,
    dirty_links: IdSet = .empty,
    ready: std.atomic.Value(bool) = .init(false),
    loader_stop: std.atomic.Value(bool) = .init(false),

    pub fn deinit(self: *FactsIndex, allocator: std.mem.Allocator) void {
        if (!self.loading) assert(self.touched_links.count() == 0);
        if (!self.loading) assert(self.touched_categories.count() == 0);
        if (!self.loading) assert(self.touched_entities.count() == 0);
        self.links.deinit(allocator);
        self.categories.deinit(allocator);
        self.strings.deinit(allocator);
        self.touched_links.deinit(allocator);
        self.touched_categories.deinit(allocator);
        self.entities.deinit(allocator);
        self.touched_entities.deinit(allocator);

        var folded = self.name_ids.keyIterator();
        var folded_count: usize = 0;
        while (folded.next()) |key| : (folded_count += 1) {
            assert(folded_count < self.name_ids.count());
            allocator.free(key.*);
        }
        self.name_ids.deinit(allocator);

        var named = self.category_names.valueIterator();
        var named_count: usize = 0;
        while (named.next()) |ids| : (named_count += 1) {
            assert(named_count < self.category_names.count());
            ids.deinit(allocator);
        }
        self.category_names.deinit(allocator);
        self.category_views.deinit(allocator);
        allocator.free(self.categories_by_order);
        self.by_category.deinit(allocator);
        self.by_domain.deinit(allocator);
        self.by_name.deinit(allocator);
        self.dirty_links.deinit(allocator);
    }

    pub fn observe(
        self: *FactsIndex,
        io: std.Io,
        allocator: std.mem.Allocator,
        change_set: *const changeset.ChangeSet,
    ) !void {
        switch (change_set.*) {
            .link_inserted => |event| try self.write_link(io, allocator, &event.link),
            .link_text_updated => |event| {
                try self.write_link(io, allocator, &event.new_link);
                if (schema.embedded_text_changed(&event.old_link, &event.new_link)) {
                    try self.drop_entities(io, allocator, event.new_link.id);
                }
            },
            .link_recategorized => |event| try self.write_link(io, allocator, &event.link),
            .link_deleted => |event| {
                try self.drop_link(io, allocator, event.link.id);
                try self.drop_entities(io, allocator, event.link.id);
            },
            .link_entities_put => |event| for (event.entries) |entry| {
                try self.write_entities(io, allocator, entry.link_id, entry.facts);
            },
            .category_inserted => |event| try self.write_category(io, allocator, &event.cat),
            .category_text_updated => |event| {
                try self.write_category(io, allocator, &event.new_cat);
            },
            .category_renamed => |event| try self.write_category(io, allocator, &event.new_cat),
            .category_moved => |event| try self.write_category(io, allocator, &event.cat),
            .category_deleted => |event| try self.drop_category(io, allocator, event.cat.id),
            .link_vectors_put,
            .category_vectors_put,
            .slug_path_repair_chunk,
            .slug_path_repair_complete,
            => {},
        }
    }

    pub fn begin_load(self: *FactsIndex, io: std.Io) void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        assert(!self.loading);
        assert(self.touched_links.count() == 0);
        assert(self.touched_categories.count() == 0);
        assert(self.touched_entities.count() == 0);
        self.loading = true;
    }

    pub fn load_link(
        self: *FactsIndex,
        io: std.Io,
        allocator: std.mem.Allocator,
        link: *const schema.Link,
    ) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        assert(self.loading);
        assert(!self.adjacency_built);
        if (self.touched_links.contains(link.id)) return;
        try self.put_link_locked(allocator, link);
        assert(self.links.contains(link.id));
    }

    pub fn load_entities(
        self: *FactsIndex,
        io: std.Io,
        allocator: std.mem.Allocator,
        link_id: u64,
        encoded: []const u8,
    ) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        assert(self.loading);
        assert(!self.adjacency_built);
        if (self.touched_entities.contains(link_id)) return;
        try self.put_entities_locked(allocator, link_id, encoded);
    }

    pub fn load_category(
        self: *FactsIndex,
        io: std.Io,
        allocator: std.mem.Allocator,
        category: *const schema.Category,
    ) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        assert(self.loading);
        if (self.touched_categories.contains(category.id)) return;
        try self.put_category_locked(allocator, category);
        self.views_stale = true;
        assert(self.categories.contains(category.id));
    }

    pub fn finish_load(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator) void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        assert(self.loading);
        self.loading = false;
        self.touched_links.clearAndFree(allocator);
        self.touched_categories.clearAndFree(allocator);
        self.touched_entities.clearAndFree(allocator);
        self.ready.store(true, .release);
    }

    /// One consistent cut of the whole index under the shared lock: queries go on, the apply
    /// path waits for the section. Strings first, then the rows that refer to them.
    pub fn snapshot_write(
        self: *FactsIndex,
        io: std.Io,
        payload: *derived_snapshot.SectionWriter,
    ) !void {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        assert(self.ready.load(.acquire));
        assert(!self.loading);
        try self.snapshot_write_strings(payload);
        try self.snapshot_write_categories(payload);
        try self.snapshot_write_links(payload);
        try self.snapshot_write_entities(payload);
    }

    fn snapshot_write_strings(
        self: *const FactsIndex,
        payload: *derived_snapshot.SectionWriter,
    ) !void {
        const values = self.strings.values.items;
        assert(values.len == self.strings.ids.count());
        try payload.put_u64(values.len);
        for (values) |value| {
            assert(value.len <= snapshot_string_len_max);
            try payload.put_u32(@intCast(value.len));
            try payload.put(value);
        }
    }

    fn snapshot_write_categories(
        self: *const FactsIndex,
        payload: *derived_snapshot.SectionWriter,
    ) !void {
        try payload.put_u64(self.categories.count());
        var categories = self.categories.iterator();
        var written: usize = 0;
        while (categories.next()) |entry| : (written += 1) {
            assert(written < self.categories.count());
            const fact = entry.value_ptr;
            const record = CategoryRecord{
                .id = entry.key_ptr.*,
                .parent_id = fact.parent_id,
                .name = fact.name,
                .named_country = fact.named_country,
                .files_things_by_name = @intFromBool(fact.files_things_by_name),
                .reserved = @splat(0),
            };
            try payload.put(std.mem.asBytes(&record));
        }
        assert(written == self.categories.count());
    }

    fn snapshot_write_links(
        self: *const FactsIndex,
        payload: *derived_snapshot.SectionWriter,
    ) !void {
        try payload.put_u64(self.links.count());
        var links = self.links.iterator();
        var written: usize = 0;
        while (links.next()) |entry| : (written += 1) {
            assert(written < self.links.count());
            const fact = entry.value_ptr;
            if (fact.subdomain) assert(fact.hosted);
            const record = LinkRecord{
                .id = entry.key_ptr.*,
                .category_id = fact.category_id,
                .host = fact.host,
                .domain = fact.domain,
                .site = fact.site,
                .cctld = fact.cctld,
                .status = fact.status,
                .hosted = @intFromBool(fact.hosted),
                .subdomain = @intFromBool(fact.subdomain),
                .reserved = @splat(0),
            };
            try payload.put(std.mem.asBytes(&record));
        }
        assert(written == self.links.count());
    }

    fn snapshot_write_entities(
        self: *const FactsIndex,
        payload: *derived_snapshot.SectionWriter,
    ) !void {
        try payload.put_u64(self.entities.count());
        var facts = self.entities.iterator();
        var written: usize = 0;
        while (facts.next()) |entry| : (written += 1) {
            assert(written < self.entities.count());
            const fact = entry.value_ptr;
            const names = fact.all_names();
            var record = EntityRecord{
                .link_id = entry.key_ptr.*,
                .name_ids = @splat(0),
                .countries = @splat(countries.none),
                .religions = fact.religions,
                .country_count = fact.country_count,
                .people_count = fact.people_count,
                .org_count = fact.org_count,
                .reserved = @splat(0),
            };
            @memcpy(record.name_ids[0..names.len], names);
            @memcpy(record.countries[0..fact.country_count], fact.country_slice());
            try payload.put(std.mem.asBytes(&record));
        }
        assert(written == self.entities.count());
    }

    /// Fills an empty index from a section in the order `snapshot_write` produced it. Every
    /// value is operating input: a bad one returns an error and the caller discards the index.
    pub fn snapshot_restore(
        self: *FactsIndex,
        allocator: std.mem.Allocator,
        payload: *derived_snapshot.SectionReader,
    ) !void {
        assert(!self.ready.load(.acquire));
        assert(!self.loading);
        assert(self.links.count() == 0);
        assert(self.strings.values.items.len == 0);
        try self.snapshot_restore_strings(allocator, payload);
        try self.snapshot_restore_categories(allocator, payload);
        try self.snapshot_restore_links(allocator, payload);
        try self.snapshot_restore_entities(allocator, payload);
        self.views_stale = true;
    }

    pub fn snapshot_discard(self: *FactsIndex, allocator: std.mem.Allocator) void {
        assert(!self.ready.load(.acquire));
        assert(!self.loading);
        self.deinit(allocator);
        self.* = .{};
    }

    fn snapshot_restore_strings(
        self: *FactsIndex,
        allocator: std.mem.Allocator,
        payload: *derived_snapshot.SectionReader,
    ) !void {
        const count = try payload.take_u64();
        if (count > std.math.maxInt(StringId)) return error.SnapshotCorrupt;
        try self.strings.values.ensureTotalCapacity(allocator, @intCast(count));
        try self.strings.ids.ensureTotalCapacity(allocator, @intCast(count));
        var buffer: [snapshot_string_len_max]u8 = undefined;
        for (0..@intCast(count)) |index| {
            const len = try payload.take_u32();
            if (len > buffer.len) return error.SnapshotCorrupt;
            try payload.take(buffer[0..len]);
            const id = try self.strings.intern(allocator, buffer[0..len]);
            if (id != index) return error.SnapshotCorrupt;
        }
        assert(self.strings.values.items.len == count);
        assert(self.strings.ids.count() == count);
    }

    fn snapshot_restore_categories(
        self: *FactsIndex,
        allocator: std.mem.Allocator,
        payload: *derived_snapshot.SectionReader,
    ) !void {
        const count = try payload.take_u64();
        if (count > snapshot_rows_max) return error.SnapshotCorrupt;
        try self.categories.ensureTotalCapacity(allocator, @intCast(count));
        const strings_total = self.strings.values.items.len;
        for (0..@intCast(count)) |_| {
            var record: CategoryRecord = undefined;
            try payload.take(std.mem.asBytes(&record));
            if (record.id == 0) return error.SnapshotCorrupt;
            if (record.name >= strings_total) return error.SnapshotCorrupt;
            if (record.files_things_by_name > 1) return error.SnapshotCorrupt;
            if (self.categories.contains(record.id)) return error.SnapshotCorrupt;
            self.categories.putAssumeCapacity(record.id, .{
                .parent_id = record.parent_id,
                .name = record.name,
                .named_country = record.named_country,
                .files_things_by_name = record.files_things_by_name == 1,
            });
            if (self.strings.get(record.name).len > 0) {
                try self.list_category_name(allocator, record.name, record.id);
            }
        }
        assert(self.categories.count() == count);
        assert(self.category_names.count() <= count);
    }

    fn snapshot_restore_links(
        self: *FactsIndex,
        allocator: std.mem.Allocator,
        payload: *derived_snapshot.SectionReader,
    ) !void {
        const count = try payload.take_u64();
        if (count > snapshot_rows_max) return error.SnapshotCorrupt;
        try self.links.ensureTotalCapacity(allocator, @intCast(count));
        const strings_total = self.strings.values.items.len;
        for (0..@intCast(count)) |_| {
            var record: LinkRecord = undefined;
            try payload.take(std.mem.asBytes(&record));
            if (record.id == 0) return error.SnapshotCorrupt;
            if (record.host >= strings_total) return error.SnapshotCorrupt;
            if (record.domain >= strings_total) return error.SnapshotCorrupt;
            if (record.site >= strings_total) return error.SnapshotCorrupt;
            if (record.hosted > 1) return error.SnapshotCorrupt;
            if (record.subdomain > record.hosted) return error.SnapshotCorrupt;
            if (self.links.contains(record.id)) return error.SnapshotCorrupt;
            self.links.putAssumeCapacity(record.id, .{
                .category_id = record.category_id,
                .host = record.host,
                .domain = record.domain,
                .site = record.site,
                .cctld = record.cctld,
                .status = record.status,
                .hosted = record.hosted == 1,
                .subdomain = record.subdomain == 1,
            });
        }
        assert(self.links.count() == count);
    }

    fn snapshot_restore_entities(
        self: *FactsIndex,
        allocator: std.mem.Allocator,
        payload: *derived_snapshot.SectionReader,
    ) !void {
        const count = try payload.take_u64();
        if (count > snapshot_rows_max) return error.SnapshotCorrupt;
        try self.entities.ensureTotalCapacity(allocator, @intCast(count));
        for (0..@intCast(count)) |_| {
            var record: EntityRecord = undefined;
            try payload.take(std.mem.asBytes(&record));
            if (record.link_id == 0) return error.SnapshotCorrupt;
            if (record.country_count > entities.countries_max) return error.SnapshotCorrupt;
            if (record.people_count > entities.names_max) return error.SnapshotCorrupt;
            if (record.org_count > entities.names_max) return error.SnapshotCorrupt;
            if (record.religions & ~entities.religion_mask != 0) return error.SnapshotCorrupt;
            if (self.entities.contains(record.link_id)) return error.SnapshotCorrupt;
            const names: usize = @as(usize, record.people_count) + record.org_count;
            for (record.name_ids[0..names]) |id| try self.snapshot_list_name(allocator, id);
            var fact: EntityFact = .{
                .religions = record.religions,
                .country_count = record.country_count,
                .people_count = record.people_count,
                .org_count = record.org_count,
            };
            const country_count: usize = record.country_count;
            @memcpy(fact.countries[0..country_count], record.countries[0..country_count]);
            @memcpy(fact.name_ids[0..names], record.name_ids[0..names]);
            self.entities.putAssumeCapacity(record.link_id, fact);
        }
        assert(self.entities.count() == count);
    }

    /// `intern_name` keeps one id per folded name, the first display form interned, so every
    /// name id an entity carries maps back to its own folded form without ambiguity.
    fn snapshot_list_name(self: *FactsIndex, allocator: std.mem.Allocator, id: StringId) !void {
        if (id >= self.strings.values.items.len) return error.SnapshotCorrupt;
        const display = self.strings.get(id);
        if (display.len == 0) return error.SnapshotCorrupt;
        if (display.len > entities.name_len_max) return error.SnapshotCorrupt;
        var folded_buffer: [entities.name_len_max]u8 = undefined;
        const folded = std.ascii.lowerString(&folded_buffer, display);
        if (self.name_ids.contains(folded)) return;

        const owned = try allocator.dupe(u8, folded);
        errdefer allocator.free(owned);

        try self.name_ids.put(allocator, owned, id);
        assert(self.name_ids.contains(folded));
        assert(self.name_ids.count() <= self.strings.values.items.len);
    }

    pub fn link_count(self: *FactsIndex, io: std.Io) usize {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.links.count();
    }

    pub fn entity_count(self: *FactsIndex, io: std.Io) usize {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.entities.count();
    }

    pub fn category_count(self: *FactsIndex, io: std.Io) usize {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.categories.count();
    }

    pub fn categories_named(
        self: *FactsIndex,
        io: std.Io,
        arena: std.mem.Allocator,
        phrase: []const u8,
    ) ![]const u64 {
        var folded_buffer: [folded_name_len_max]u8 = undefined;
        if (phrase.len > folded_buffer.len) return &.{};
        const folded = fold_name(phrase, &folded_buffer);
        assert(folded.len <= phrase.len);
        if (folded.len == 0) return &.{};

        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        const name = self.strings.ids.get(folded) orelse return &.{};
        const ids = self.category_names.get(name) orelse return &.{};
        for (ids.items) |id| assert(self.categories.contains(id));
        return arena.dupe(u64, ids.items);
    }

    pub fn names_someone(self: *FactsIndex, io: std.Io, phrase: []const u8) bool {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.name_id(phrase) != null;
    }

    /// `gpa` is the allocator the index itself was built with: the first reader after a
    /// category write rebuilds `category_views`, which outlives the request. A request's
    /// scratch slab here let the next large request overwrite the views (2026-11-19).
    pub fn query(
        self: *FactsIndex,
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        request: Query,
    ) !Answer {
        const held = try self.lock_current(io, gpa);
        defer self.unlock_current(io, held);
        return self.evaluate(arena, &request);
    }

    /// The ids come from `scratch` and are the caller's to free; `gpa` is for the views, as
    /// in `query`.
    pub fn subtree_link_ids(
        self: *FactsIndex,
        io: std.Io,
        gpa: std.mem.Allocator,
        scratch: std.mem.Allocator,
        roots: []const u64,
    ) ![]u64 {
        assert(roots.len <= subtree_roots_max);
        const held = try self.lock_current(io, gpa);
        defer self.unlock_current(io, held);
        return self.collect_subtree_link_ids(scratch, roots);
    }

    /// The sites filed in the same categories as the site at `suffix`, the most alike first.
    /// A shared category counts for more the fewer links it holds.
    pub fn sites_like(
        self: *FactsIndex,
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        request: struct { suffix: []const u8, limit: u32 },
    ) ![]const Neighbour {
        assert(request.limit <= neighbours_max);
        assert(request.suffix.len > 0);
        const held = try self.lock_current(io, gpa);
        defer self.unlock_current(io, held);

        const suffix = request.suffix;
        const on_domain = self.domain_links(suffix) orelse return &.{};
        const source = on_domain[0..@min(on_domain.len, neighbour_source_links_max)];

        var affinities: Affinities = .empty;
        var categories_seen: IdSet = .empty;
        var sites_here: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        for (source) |id| {
            const fact = self.clean_approved(id) orelse continue;
            if (!url_facts.has_suffix(self.strings.get(fact.host), suffix)) continue;
            if (try categories_seen.fetchPut(arena, fact.category_id, {}) != null) continue;

            const filed = self.by_category.of(fact.category_id);
            assert(filed.len > 0);
            if (filed.len > neighbour_category_links_max) continue;
            sites_here.clearRetainingCapacity();
            const weight = 1.0 / @as(f64, @floatFromInt(filed.len));
            for (filed) |other_id| {
                const other = self.clean_approved(other_id) orelse continue;
                if (url_facts.has_suffix(self.strings.get(other.host), suffix)) continue;
                if (try sites_here.fetchPut(arena, other.site, {}) != null) continue;
                const entry = try affinities.getOrPutValue(arena, other.site, .{});
                entry.value_ptr.weight += weight;
                entry.value_ptr.shared += 1;
            }
        }
        return self.strongest(arena, &affinities, request.limit);
    }

    /// The people and organisations named on the same links as `name`, by how many links.
    pub fn named_alongside(
        self: *FactsIndex,
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        request: struct { name: []const u8, limit: u32 },
    ) ![]const Neighbour {
        assert(request.limit <= neighbours_max);
        assert(request.name.len > 0);
        const held = try self.lock_current(io, gpa);
        defer self.unlock_current(io, held);

        const own = self.name_id(request.name) orelse return &.{};
        const naming = self.by_name.of(own);
        const source = naming[0..@min(naming.len, neighbour_source_links_max)];

        var affinities: Affinities = .empty;
        for (source) |id| {
            if (self.clean_approved(id) == null) continue;
            const fact = self.entities.getPtr(id) orelse continue;
            const names = fact.all_names();
            for (names, 0..) |other, index| {
                if (other == own) continue;
                if (std.mem.findScalar(StringId, names[0..index], other) != null) continue;
                const entry = try affinities.getOrPutValue(arena, other, .{});
                entry.value_ptr.weight += 1;
                entry.value_ptr.shared += 1;
            }
        }
        return self.strongest(arena, &affinities, request.limit);
    }

    /// Of `candidates`, the categories that are known and sit neither above nor below
    /// `category_id`: a page already shows its own ancestors and children.
    pub fn off_the_line(
        self: *FactsIndex,
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        request: struct { category_id: u64, candidates: []const u64 },
    ) ![]const u64 {
        assert(request.category_id != 0);
        const held = try self.lock_current(io, gpa);
        defer self.unlock_current(io, held);

        const own = self.category_views.get(request.category_id) orelse return &.{};
        var kept = try std.ArrayListUnmanaged(u64).initCapacity(arena, request.candidates.len);
        for (request.candidates) |candidate| {
            const view = self.category_views.get(candidate) orelse continue;
            if (own.contains(&view)) continue;
            if (view.contains(&own)) continue;
            kept.appendAssumeCapacity(candidate);
        }
        assert(kept.items.len <= request.candidates.len);
        return kept.items;
    }

    /// The other categories that carry `category_id`'s name, the largest subtree first, and
    /// none when the name is a filing template.
    pub fn namesakes(
        self: *FactsIndex,
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        request: struct { category_id: u64, limit: u32 },
    ) ![]const u64 {
        assert(request.limit <= neighbours_max);
        assert(request.category_id != 0);
        const held = try self.lock_current(io, gpa);
        defer self.unlock_current(io, held);

        const own = self.categories.get(request.category_id) orelse return &.{};
        const named = self.category_names.get(own.name) orelse return &.{};
        if (named.items.len > namesakes_max + 1) return &.{};

        const Sized = struct {
            id: u64,
            below: u32,

            fn before(_: void, a: @This(), b: @This()) bool {
                if (a.below != b.below) return a.below > b.below;
                return a.id < b.id;
            }
        };
        var sized = try std.ArrayListUnmanaged(Sized).initCapacity(arena, named.items.len);
        for (named.items) |id| {
            if (id == request.category_id) continue;
            const view = self.category_views.get(id) orelse continue;
            sized.appendAssumeCapacity(.{ .id = id, .below = view.last_descendant - view.order });
        }
        std.sort.pdq(Sized, sized.items, {}, Sized.before);

        const out = try arena.alloc(u64, @min(request.limit, sized.items.len));
        for (out, sized.items[0..out.len]) |*id, twin| id.* = twin.id;
        assert(out.len <= namesakes_max);
        return out;
    }

    /// A link the adjacency still describes and that readers may be shown. A dirty link is
    /// left out: a neighbour list tolerates missing the last few thousand writes.
    fn clean_approved(self: *const FactsIndex, id: u64) ?*const LinkFact {
        assert(self.adjacency_built);
        assert(id != 0);
        if (self.dirty_links.contains(id)) return null;
        const fact = self.links.getPtr(id).?;
        if (fact.status != @intFromEnum(schema.LinkStatus.approved)) return null;
        return fact;
    }

    fn strongest(
        self: *const FactsIndex,
        arena: std.mem.Allocator,
        affinities: *const Affinities,
        limit: u32,
    ) ![]const Neighbour {
        assert(limit <= neighbours_max);
        const ranked = try arena.alloc(RankedAffinity, affinities.count());
        var entries = affinities.iterator();
        var filled: usize = 0;
        while (entries.next()) |entry| : (filled += 1) {
            assert(filled < ranked.len);
            ranked[filled] = .{ .key = entry.key_ptr.*, .affinity = entry.value_ptr.* };
        }
        assert(filled == ranked.len);
        std.sort.pdq(RankedAffinity, ranked, {}, RankedAffinity.before);

        const out = try arena.alloc(Neighbour, @min(limit, ranked.len));
        for (out, ranked[0..out.len]) |*neighbour, top| {
            assert(top.affinity.shared > 0);
            neighbour.* = .{
                .label = try arena.dupe(u8, self.strings.get(top.key)),
                .shared = top.affinity.shared,
            };
        }
        assert(out.len <= limit);
        return out;
    }

    const Held = enum { shared, exclusive };

    /// Takes the lock a reader needs: shared when the views and the adjacency are current,
    /// exclusive after bringing them up to date. `gpa` is the index's own allocator.
    fn lock_current(self: *FactsIndex, io: std.Io, gpa: std.mem.Allocator) !Held {
        self.lock.lockSharedUncancelable(io);
        if (self.current()) return .shared;
        self.lock.unlockShared(io);

        self.lock.lockUncancelable(io);
        errdefer self.lock.unlock(io);
        try self.refresh(gpa);
        assert(self.current());
        return .exclusive;
    }

    fn unlock_current(self: *FactsIndex, io: std.Io, held: Held) void {
        assert(self.current());
        switch (held) {
            .shared => self.lock.unlockShared(io),
            .exclusive => self.lock.unlock(io),
        }
    }

    /// Whether a reader can answer under the shared lock: the views match the categories and
    /// the adjacency is within `dirty_links_max` writes of the links.
    fn current(self: *const FactsIndex) bool {
        if (!self.adjacency_built) assert(self.dirty_links.count() == 0);
        if (self.views_stale) return false;
        if (!self.adjacency_built) return false;
        return self.dirty_links.count() <= dirty_links_max;
    }

    /// Brings the views and the adjacency up to date. The caller holds the exclusive lock.
    fn refresh(self: *FactsIndex, gpa: std.mem.Allocator) !void {
        if (self.views_stale) try self.rebuild_category_views(gpa);
        assert(!self.views_stale);
        if (!self.adjacency_built or self.dirty_links.count() > dirty_links_max) {
            try self.rebuild_adjacency(gpa);
        }
        assert(self.current());
    }

    fn rebuild_adjacency(self: *FactsIndex, gpa: std.mem.Allocator) !void {
        assert(self.links.count() <= adjacency.rows_max);
        const rows = try gpa.alloc(adjacency.Row, self.links.count());
        defer gpa.free(rows);

        self.fill_link_rows(rows, .category);
        try self.by_category.rebuild(gpa, rows);
        self.fill_link_rows(rows, .domain);
        try self.by_domain.rebuild(gpa, rows);
        try self.rebuild_by_name(gpa);

        self.dirty_links.clearRetainingCapacity();
        self.adjacency_built = true;
        assert(self.by_category.link_ids.len == self.links.count());
        assert(self.by_domain.link_ids.len == self.links.count());
    }

    const LinkKey = enum { category, domain };

    fn fill_link_rows(self: *const FactsIndex, rows: []adjacency.Row, key: LinkKey) void {
        assert(rows.len == self.links.count());
        var links = self.links.iterator();
        var filled: usize = 0;
        while (links.next()) |entry| : (filled += 1) {
            assert(filled < rows.len);
            rows[filled] = .{
                .key = switch (key) {
                    .category => entry.value_ptr.category_id,
                    .domain => entry.value_ptr.domain,
                },
                .link_id = entry.key_ptr.*,
            };
        }
        assert(filled == rows.len);
    }

    fn rebuild_by_name(self: *FactsIndex, gpa: std.mem.Allocator) !void {
        var names_total: usize = 0;
        var counted = self.entities.valueIterator();
        var entities_counted: usize = 0;
        while (counted.next()) |fact| : (entities_counted += 1) {
            assert(entities_counted < self.entities.count());
            names_total += fact.all_names().len;
        }
        assert(names_total <= self.entities.count() * 2 * entities.names_max);

        const rows = try gpa.alloc(adjacency.Row, names_total);
        defer gpa.free(rows);

        var filled: usize = 0;
        var named = self.entities.iterator();
        var entities_filled: usize = 0;
        while (named.next()) |entry| : (entities_filled += 1) {
            assert(entities_filled < self.entities.count());
            for (entry.value_ptr.all_names()) |name| {
                rows[filled] = .{ .key = name, .link_id = entry.key_ptr.* };
                filled += 1;
            }
        }
        assert(filled == rows.len);
        try self.by_name.rebuild(gpa, rows);
        assert(self.by_name.link_ids.len <= names_total);
    }

    /// The links whose registrable domain `suffix` sits at or below, or null when `suffix` is
    /// a public suffix such as `pk` or `ac.uk`, which spans domains and cannot narrow.
    fn domain_links(self: *const FactsIndex, suffix: []const u8) ?[]const u64 {
        assert(self.adjacency_built);
        if (suffix.len == 0) return null;
        if (url_facts.is_public_suffix(suffix)) return null;
        const domain = self.strings.ids.get(url_facts.registrable_domain(suffix)) orelse
            return &.{};
        return self.by_domain.of(domain);
    }

    /// Records that a link's facts are about to change, so readers stop trusting its rows in
    /// the adjacency. The caller holds the exclusive lock.
    fn mark_dirty(self: *FactsIndex, allocator: std.mem.Allocator, link_id: u64) !void {
        assert(link_id != 0);
        if (!self.adjacency_built) return;
        try self.dirty_links.put(allocator, link_id, {});
        assert(self.dirty_links.contains(link_id));
    }

    fn collect_subtree_link_ids(
        self: *const FactsIndex,
        scratch: std.mem.Allocator,
        roots: []const u64,
    ) ![]u64 {
        assert(self.current());
        assert(roots.len <= subtree_roots_max);
        var scopes_buffer: [subtree_roots_max]CategoryView = undefined;
        const scopes = self.disjoint_scopes(roots, &scopes_buffer);

        var ids: std.ArrayListUnmanaged(u64) = .empty;
        errdefer ids.deinit(scratch);

        for (scopes) |*scope| {
            const below = self.categories_by_order[scope.order .. scope.last_descendant + 1];
            for (below) |category_id| try self.append_clean(scratch, &ids, category_id);
        }

        var dirty = self.dirty_links.keyIterator();
        var visited: usize = 0;
        while (dirty.next()) |id| : (visited += 1) {
            assert(visited < self.dirty_links.count());
            const fact = self.links.getPtr(id.*) orelse continue;
            const view = self.category_views.get(fact.category_id) orelse continue;
            for (scopes) |*scope| {
                if (scope.contains(&view)) try ids.append(scratch, id.*);
            }
        }
        assert(ids.items.len <= self.links.count());
        return ids.toOwnedSlice(scratch);
    }

    /// The views of the known roots, leaving out any root that sits inside another, so every
    /// link under them belongs to exactly one scope.
    fn disjoint_scopes(
        self: *const FactsIndex,
        roots: []const u64,
        out: *[subtree_roots_max]CategoryView,
    ) []const CategoryView {
        assert(roots.len <= subtree_roots_max);
        var count: usize = 0;
        for (roots, 0..) |root, index| {
            const view = self.category_views.get(root) orelse continue;
            var covered = false;
            for (roots, 0..) |other, other_index| {
                if (other_index == index) continue;
                const outer = self.category_views.get(other) orelse continue;
                if (!outer.contains(&view)) continue;
                const same = outer.order == view.order;
                if (!same or other_index < index) covered = true;
            }
            if (covered) continue;
            out[count] = view;
            count += 1;
        }
        assert(count <= roots.len);
        return out[0..count];
    }

    fn append_clean(
        self: *const FactsIndex,
        scratch: std.mem.Allocator,
        ids: *std.ArrayListUnmanaged(u64),
        category_id: u64,
    ) !void {
        assert(self.adjacency_built);
        const filed = self.by_category.of(category_id);
        if (self.dirty_links.count() == 0) return ids.appendSlice(scratch, filed);

        for (filed) |id| {
            if (self.dirty_links.contains(id)) continue;
            assert(self.links.contains(id));
            try ids.append(scratch, id);
        }
    }

    fn evaluate(
        self: *const FactsIndex,
        arena: std.mem.Allocator,
        request: *const Query,
    ) !Answer {
        assert(self.current());
        var scope: ?CategoryView = null;
        if (request.category_id != 0) scope = self.category_views.get(request.category_id);
        var name: ?StringId = null;
        if (request.entity_name.len > 0) name = self.name_id(request.entity_name);

        const string_count = self.strings.values.items.len;
        var evaluator: Evaluator = .{
            .index = self,
            .arena = arena,
            .query = request,
            .scope = scope,
            .name = name,
            .site_set = try std.DynamicBitSetUnmanaged.initEmpty(arena, string_count),
            .host_set = try std.DynamicBitSetUnmanaged.initEmpty(arena, string_count),
            .domain_set = try std.DynamicBitSetUnmanaged.initEmpty(arena, string_count),
        };
        const answer = try evaluator.run();
        assert(answer.page.len <= request.page_limit);
        assert(answer.groups.len <= request.group_limit);
        return answer;
    }

    fn write_link(
        self: *FactsIndex,
        io: std.Io,
        allocator: std.mem.Allocator,
        link: *const schema.Link,
    ) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.loading) try self.touched_links.put(allocator, link.id, {});
        try self.mark_dirty(allocator, link.id);
        try self.put_link_locked(allocator, link);
        assert(self.links.contains(link.id));
        if (self.loading) assert(self.touched_links.contains(link.id));
    }

    fn drop_link(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, id: u64) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.loading) try self.touched_links.put(allocator, id, {});
        try self.mark_dirty(allocator, id);
        _ = self.links.remove(id);
        assert(!self.links.contains(id));
        if (self.loading) assert(self.touched_links.contains(id));
    }

    fn write_entities(
        self: *FactsIndex,
        io: std.Io,
        allocator: std.mem.Allocator,
        link_id: u64,
        encoded: []const u8,
    ) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.loading) try self.touched_entities.put(allocator, link_id, {});
        try self.mark_dirty(allocator, link_id);
        try self.put_entities_locked(allocator, link_id, encoded);
        if (self.loading) assert(self.touched_entities.contains(link_id));
    }

    fn drop_entities(
        self: *FactsIndex,
        io: std.Io,
        allocator: std.mem.Allocator,
        link_id: u64,
    ) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.loading) try self.touched_entities.put(allocator, link_id, {});
        try self.mark_dirty(allocator, link_id);
        _ = self.entities.remove(link_id);
        assert(!self.entities.contains(link_id));
        if (self.loading) assert(self.touched_entities.contains(link_id));
    }

    fn put_entities_locked(
        self: *FactsIndex,
        allocator: std.mem.Allocator,
        link_id: u64,
        encoded: []const u8,
    ) !void {
        const decoded = entities.decode(encoded) orelse {
            _ = self.entities.remove(link_id);
            return;
        };
        assert(decoded.country_count <= entities.countries_max);
        var fact: EntityFact = .{
            .religions = decoded.religions,
            .country_count = @intCast(decoded.country_count),
        };
        @memcpy(fact.countries[0..decoded.country_count], decoded.country_slice());
        fact.people_count = try self.intern_distinct(
            allocator,
            decoded.people.slice(),
            fact.name_ids[0..],
        );
        fact.org_count = try self.intern_distinct(
            allocator,
            decoded.orgs.slice(),
            fact.name_ids[fact.people_count..],
        );
        assert(fact.people_count <= entities.names_max);
        assert(fact.people_count + fact.org_count <= fact.name_ids.len);
        try self.entities.put(allocator, link_id, fact);
    }

    fn intern_distinct(
        self: *FactsIndex,
        allocator: std.mem.Allocator,
        names: []const []const u8,
        out: []StringId,
    ) !u8 {
        assert(names.len <= entities.names_max);
        assert(out.len >= names.len);
        var count: u8 = 0;
        for (names) |name| {
            const id = try self.intern_name(allocator, name);
            if (std.mem.findScalar(StringId, out[0..count], id) != null) continue;
            out[count] = id;
            count += 1;
        }
        assert(count <= names.len);
        return count;
    }

    fn intern_name(self: *FactsIndex, allocator: std.mem.Allocator, display: []const u8) !StringId {
        assert(display.len > 0);
        assert(display.len <= entities.name_len_max);
        var folded_buffer: [entities.name_len_max]u8 = undefined;
        const folded = std.ascii.lowerString(&folded_buffer, display);
        if (self.name_ids.get(folded)) |id| return id;

        const id = try self.strings.intern(allocator, display);

        const owned = try allocator.dupe(u8, folded);
        errdefer allocator.free(owned);

        try self.name_ids.put(allocator, owned, id);
        assert(self.name_ids.count() <= self.strings.values.items.len);
        return id;
    }

    fn name_id(self: *const FactsIndex, name: []const u8) ?StringId {
        var folded_buffer: [entities.name_len_max]u8 = undefined;
        if (name.len > folded_buffer.len) return null;
        const folded = std.ascii.lowerString(&folded_buffer, name);
        const id = self.name_ids.get(folded) orelse return null;
        assert(id < self.strings.values.items.len);
        return id;
    }

    fn write_category(
        self: *FactsIndex,
        io: std.Io,
        allocator: std.mem.Allocator,
        category: *const schema.Category,
    ) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.loading) try self.touched_categories.put(allocator, category.id, {});
        try self.put_category_locked(allocator, category);
        self.views_stale = true;
        assert(self.categories.contains(category.id));
        if (self.loading) assert(self.touched_categories.contains(category.id));
    }

    fn drop_category(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, id: u64) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.loading) try self.touched_categories.put(allocator, id, {});
        if (self.categories.get(id)) |old| self.unlist_category_name(old.name, id);
        _ = self.categories.remove(id);
        self.views_stale = true;
        assert(!self.categories.contains(id));
        if (self.loading) assert(self.touched_categories.contains(id));
    }

    fn put_link_locked(
        self: *FactsIndex,
        allocator: std.mem.Allocator,
        link: *const schema.Link,
    ) !void {
        var host_buffer: [url_facts.host_len_max]u8 = undefined;
        const url = url_facts.split(link.url.slice(), &host_buffer);
        assert(url.host.len <= url_facts.host_len_max);
        var site_buffer: [sites.site_len_max]u8 = undefined;
        const site = sites.site_of(url.host, url.path, &site_buffer);
        assert(site.key.len <= sites.site_len_max);

        const fact: LinkFact = .{
            .category_id = link.category_id,
            .host = try self.strings.intern(allocator, url.host),
            .domain = try self.strings.intern(allocator, url_facts.registrable_domain(url.host)),
            .site = try self.strings.intern(allocator, site.key),
            .cctld = url_facts.cctld_country(url.host) orelse countries.none,
            .status = link.status,
            .hosted = site.hosted,
            .subdomain = site.hosted and std.mem.findScalar(u8, site.key, '/') == null,
        };
        if (fact.subdomain) assert(fact.hosted);
        try self.links.put(allocator, link.id, fact);
    }

    fn put_category_locked(
        self: *FactsIndex,
        allocator: std.mem.Allocator,
        category: *const schema.Category,
    ) !void {
        const name = category.name.slice();
        var folded_buffer: [folded_name_len_max]u8 = undefined;
        const folded = fold_name(name, &folded_buffer);
        assert(folded.len <= name.len);
        const folded_id = try self.strings.intern(allocator, folded);
        try self.categories.ensureUnusedCapacity(allocator, 1);

        const previous = self.categories.get(category.id);
        const renamed = if (previous) |old| old.name != folded_id else true;
        if (renamed) {
            if (previous) |old| self.unlist_category_name(old.name, category.id);
            if (folded.len > 0) try self.list_category_name(allocator, folded_id, category.id);
        }

        self.categories.putAssumeCapacity(category.id, .{
            .parent_id = category.parent_id,
            .name = folded_id,
            .named_country = countries.by_name(name) orelse countries.none,
            .files_things_by_name = name.len == 1 or parents_that_file_things_by_name.has(name),
        });
        assert(self.categories.contains(category.id));
        if (folded.len > 0) assert(self.category_names.contains(folded_id));
    }

    fn list_category_name(
        self: *FactsIndex,
        allocator: std.mem.Allocator,
        name: StringId,
        id: u64,
    ) !void {
        const entry = try self.category_names.getOrPut(allocator, name);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        assert(std.mem.findScalar(u64, entry.value_ptr.items, id) == null);
        try entry.value_ptr.append(allocator, id);
        assert(entry.value_ptr.items.len > 0);
    }

    fn unlist_category_name(self: *FactsIndex, name: StringId, id: u64) void {
        const ids = self.category_names.getPtr(name) orelse return;
        const at = std.mem.findScalar(u64, ids.items, id) orelse return;
        assert(at < ids.items.len);
        _ = ids.swapRemove(at);
        assert(std.mem.findScalar(u64, ids.items, id) == null);
    }

    fn rebuild_category_views(self: *FactsIndex, gpa: std.mem.Allocator) !void {
        var children: ChildrenByParent = .empty;
        defer {
            var lists = children.valueIterator();
            while (lists.next()) |list| list.deinit(gpa);
            children.deinit(gpa);
        }
        var roots: std.ArrayListUnmanaged(u64) = .empty;
        defer roots.deinit(gpa);
        try self.group_children(gpa, &children, &roots);

        const categories_total = self.categories.count();
        const by_order = try gpa.alloc(u64, categories_total);
        errdefer gpa.free(by_order);
        @memset(by_order, 0);
        self.category_views.clearRetainingCapacity();
        try self.category_views.ensureTotalCapacity(gpa, categories_total);

        var stack: std.ArrayListUnmanaged(Visit) = .empty;
        defer stack.deinit(gpa);
        var clock: u32 = 0;
        var steps: usize = 0;
        for (roots.items) |root| {
            try stack.append(gpa, .{ .id = root });
            while (stack.items.len > 0) : (steps += 1) {
                assert(steps < 2 * categories_total);
                assert(stack.items.len <= categories_total);
                const visit = &stack.items[stack.items.len - 1];
                if (!visit.entered) {
                    visit.entered = true;
                    self.category_views.putAssumeCapacity(
                        visit.id,
                        self.view_below_parent(visit.id, clock),
                    );
                    by_order[clock] = visit.id;
                    clock += 1;
                }
                const kids: []const u64 = if (children.get(visit.id)) |list| list.items else &.{};
                if (visit.next_child < kids.len) {
                    const child = kids[visit.next_child];
                    visit.next_child += 1;
                    try stack.append(gpa, .{ .id = child });
                    continue;
                }
                self.category_views.getPtr(visit.id).?.last_descendant = clock - 1;
                _ = stack.pop();
            }
        }
        assert(clock <= categories_total);
        assert(self.category_views.count() == clock);
        gpa.free(self.categories_by_order);
        self.categories_by_order = by_order;
        self.views_stale = false;
    }

    const ChildrenByParent = std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u64));

    /// Files every category under its parent, and as a root when it has none in the index.
    fn group_children(
        self: *const FactsIndex,
        gpa: std.mem.Allocator,
        children: *ChildrenByParent,
        roots: *std.ArrayListUnmanaged(u64),
    ) !void {
        assert(children.count() == 0);
        assert(roots.items.len == 0);
        const categories_total = self.categories.count();
        var categories = self.categories.iterator();
        var visited: usize = 0;
        while (categories.next()) |entry| : (visited += 1) {
            assert(visited < categories_total);
            const parent_id = entry.value_ptr.parent_id;
            if (parent_id == 0 or !self.categories.contains(parent_id)) {
                try roots.append(gpa, entry.key_ptr.*);
                continue;
            }
            const siblings = try children.getOrPut(gpa, parent_id);
            if (!siblings.found_existing) siblings.value_ptr.* = .empty;
            try siblings.value_ptr.append(gpa, entry.key_ptr.*);
        }
        assert(visited == categories_total);
    }

    fn view_below_parent(self: *const FactsIndex, id: u64, order: u32) CategoryView {
        assert(order < self.categories.count());
        assert(self.category_views.count() == order);
        const fact = self.categories.get(id).?;
        const parent = if (fact.parent_id == 0) null else self.category_views.get(fact.parent_id);

        var own_country = countries.none;
        if (known(fact.named_country)) {
            const parent_files_by_name = if (self.categories.get(fact.parent_id)) |parent_fact|
                parent_fact.files_things_by_name
            else
                false;
            if (!parent_files_by_name) own_country = fact.named_country;
        }

        const parent_view = parent orelse return .{
            .country = own_country,
            .branch = id,
            .is_root = true,
            .order = order,
            .last_descendant = order,
        };
        assert(parent_view.order < order);
        return .{
            .country = if (known(parent_view.country)) parent_view.country else own_country,
            .branch = if (parent_view.is_root) id else parent_view.branch,
            .is_root = false,
            .order = order,
            .last_descendant = order,
        };
    }
};

const Visit = struct { id: u64, entered: bool = false, next_child: u32 = 0 };

fn fold_name(text: []const u8, out: *[folded_name_len_max]u8) []const u8 {
    var writer: std.Io.Writer = .fixed(out);
    var word_buffer: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    var words = inverted.TokenIterator.init(text);
    var word_count: usize = 0;
    while (words.next(&word_buffer)) |word| : (word_count += 1) {
        assert(word_count < text.len);
        var singular = word;
        if (word.len > 3) {
            if (word[word.len - 1] == 's') singular = word[0 .. word.len - 1];
        }
        if (writer.end > 0) writer.writeByte(' ') catch break;
        writer.writeAll(singular) catch break;
    }
    const folded = out[0..writer.end];
    assert(folded.len <= text.len);
    return folded;
}

pub const CategoryView = struct {
    country: countries.Code,
    branch: u64,
    is_root: bool,
    order: u32,
    last_descendant: u32,

    fn contains(self: *const CategoryView, other: *const CategoryView) bool {
        assert(self.order <= self.last_descendant);
        assert(other.order <= other.last_descendant);
        return self.order <= other.order and other.order <= self.last_descendant;
    }
};

const Ties = struct {
    codes: [2 + entities.countries_max]countries.Code = undefined,
    len: u32 = 0,

    fn of(
        cctld: countries.Code,
        category: countries.Code,
        entity: ?*const EntityFact,
        via: u8,
    ) Ties {
        assert(via <= Via.all);
        var ties: Ties = .{};
        if (via & Via.cctld != 0) {
            if (known(cctld)) ties.add(cctld);
        }
        if (via & Via.category != 0) {
            if (known(category)) ties.add(category);
        }
        if (via & Via.entity != 0) {
            if (entity) |fact| for (fact.country_slice()) |code| ties.add(code);
        }
        assert(ties.len <= ties.codes.len);
        return ties;
    }

    fn add(self: *Ties, code: countries.Code) void {
        assert(known(code));
        if (self.contains(code)) return;
        assert(self.len < self.codes.len);
        self.codes[self.len] = code;
        self.len += 1;
    }

    fn contains(self: *const Ties, code: countries.Code) bool {
        assert(self.len <= self.codes.len);
        for (self.codes[0..self.len]) |tied| {
            if (std.mem.eql(u8, &tied, &code)) return true;
        }
        return false;
    }
};

const Tally = struct { links: u64 = 0, sites: u64 = 0 };
const GroupSite = struct { key: u64, site: StringId };

// Where an evaluation gets its candidate links. Every candidate still goes through `admit`,
// so a driver only has to cover the matches, never to decide them.
const Driver = union(enum) {
    all,
    none,
    ids: []const u64,
    words: *const IdSet,
    subtree: CategoryView,
};

const Evaluator = struct {
    index: *const FactsIndex,
    arena: std.mem.Allocator,
    query: *const Query,
    scope: ?CategoryView,
    name: ?StringId,
    site_set: std.DynamicBitSetUnmanaged,
    host_set: std.DynamicBitSetUnmanaged,
    domain_set: std.DynamicBitSetUnmanaged,
    category_set: IdSet = .empty,
    matches: std.ArrayListUnmanaged(u64) = .empty,
    tallies: std.AutoHashMapUnmanaged(u64, Tally) = .empty,
    group_sites: std.AutoHashMapUnmanaged(GroupSite, void) = .empty,

    fn run(self: *Evaluator) !Answer {
        switch (self.driver()) {
            .none => {},
            .all => try self.visit_every_link(),
            .words => |allowed| try self.visit_words(allowed),
            .ids => |ids| {
                try self.visit_clean(ids);
                try self.visit_dirty();
            },
            .subtree => |scope| {
                const index = self.index;
                const below = index.categories_by_order[scope.order .. scope.last_descendant + 1];
                for (below) |category_id| try self.visit_clean(index.by_category.of(category_id));
                try self.visit_dirty();
            },
        }
        const matches = self.matches.items;
        assert(matches.len <= self.index.links.count());
        assert(self.site_set.count() <= matches.len);
        assert(self.host_set.count() <= matches.len);
        assert(self.domain_set.count() <= self.host_set.count());

        std.mem.sortUnstable(u64, matches, {}, std.sort.asc(u64));
        const paged = try self.page(matches);
        assert(paged.rows.len <= self.query.page_limit);
        return .{
            .total = matches.len,
            .sites = self.site_set.count(),
            .hosts = self.host_set.count(),
            .domains = self.domain_set.count(),
            .categories = self.category_set.count(),
            .groups = try self.top_groups(),
            .page = paged.rows,
            .next_after_id = paged.next_after_id,
        };
    }

    /// The narrowest set of candidates the query's filters allow: an exact key (an entity
    /// name, a domain, the links holding the query's words) beats a subtree, which beats
    /// every link. A filter naming something unknown matches nothing.
    fn driver(self: *const Evaluator) Driver {
        const query = self.query;
        assert(self.index.adjacency_built);
        if (query.category_id != 0 and self.scope == null) return .none;
        if (query.entity_name.len > 0 and self.name == null) return .none;

        var narrowest: Driver = .all;
        var narrowest_len: usize = std.math.maxInt(usize);
        if (self.name) |name| {
            const named = self.index.by_name.of(name);
            narrowest = .{ .ids = named };
            narrowest_len = named.len;
        }
        if (self.index.domain_links(query.domain_suffix)) |on_domain| {
            if (on_domain.len < narrowest_len) {
                narrowest = .{ .ids = on_domain };
                narrowest_len = on_domain.len;
            }
        }
        if (query.allowed_ids) |allowed| {
            if (allowed.count() < narrowest_len) narrowest = .{ .words = allowed };
        }
        if (narrowest != .all) return narrowest;

        // Walking a subtree costs a lookup per category and a fetch per link, where the scan
        // reads the links in memory order: measured at 3.04M links and 632k categories, a
        // subtree of half the tree ties with the scan and the whole tree takes 1.6 times as
        // long. Below that the walk wins by one to two orders of magnitude.
        const scope = self.scope orelse return .all;
        const below: usize = scope.last_descendant - scope.order + 1;
        if (below * 2 > self.index.categories_by_order.len) return .all;
        return .{ .subtree = scope };
    }

    fn visit_every_link(self: *Evaluator) !void {
        const link_count = self.index.links.count();
        var links = self.index.links.iterator();
        var visited: usize = 0;
        while (links.next()) |entry| : (visited += 1) {
            assert(visited < link_count);
            try self.visit(entry.key_ptr.*, entry.value_ptr);
        }
        assert(visited == link_count);
    }

    fn visit_words(self: *Evaluator, allowed: *const IdSet) !void {
        var ids = allowed.keyIterator();
        var visited: usize = 0;
        while (ids.next()) |id| : (visited += 1) {
            assert(visited < allowed.count());
            const fact = self.index.links.getPtr(id.*) orelse continue;
            try self.visit(id.*, fact);
        }
        assert(visited == allowed.count());
    }

    /// Adjacency rows are trusted only for links no write has touched since the rebuild; the
    /// touched ones are visited by `visit_dirty`, once each.
    fn visit_clean(self: *Evaluator, ids: []const u64) !void {
        assert(self.index.adjacency_built);
        for (ids) |id| {
            if (self.index.dirty_links.contains(id)) continue;
            const fact = self.index.links.getPtr(id).?;
            try self.visit(id, fact);
        }
    }

    fn visit_dirty(self: *Evaluator) !void {
        const dirty_count = self.index.dirty_links.count();
        assert(dirty_count <= dirty_links_max);
        var dirty = self.index.dirty_links.keyIterator();
        var visited: usize = 0;
        while (dirty.next()) |id| : (visited += 1) {
            assert(visited < dirty_count);
            const fact = self.index.links.getPtr(id.*) orelse continue;
            try self.visit(id.*, fact);
        }
        assert(visited == dirty_count);
    }

    fn visit(self: *Evaluator, id: u64, fact: *const LinkFact) !void {
        assert(id != 0);
        const ties = self.admit(id, fact) orelse return;
        try self.matches.append(self.arena, id);
        self.site_set.set(fact.site);
        self.host_set.set(fact.host);
        self.domain_set.set(fact.domain);
        try self.category_set.put(self.arena, fact.category_id, {});
        try self.tally(id, fact, &ties);
    }

    fn admit(self: *Evaluator, id: u64, fact: *const LinkFact) ?Ties {
        const query = self.query;
        assert(query.via <= Via.all);
        if (fact.subdomain) assert(fact.hosted);
        if (query.status) |status| if (fact.status != status) return null;
        if (query.hosted_only) {
            if (!fact.hosted) return null;
        }
        if (query.subdomain_only) {
            if (!fact.subdomain) return null;
        }
        if (query.allowed_ids) |allowed| if (!allowed.contains(id)) return null;
        if (query.domain_suffix.len > 0) {
            const host = self.index.strings.get(fact.host);
            if (!url_facts.has_suffix(host, query.domain_suffix)) return null;
        }

        const entity = self.index.entities.getPtr(id);
        if (query.religions != 0) {
            const fact_entity = entity orelse return null;
            if (fact_entity.religions & query.religions == 0) return null;
        }
        if (query.entity_name.len > 0) {
            const wanted = self.name orelse return null;
            const fact_entity = entity orelse return null;
            if (std.mem.findScalar(StringId, fact_entity.all_names(), wanted) == null) return null;
        }

        const category_view = self.index.category_views.get(fact.category_id);
        if (query.category_id != 0) {
            const scope = self.scope orelse return null;
            const link_view = category_view orelse return null;
            if (!scope.contains(&link_view)) return null;
        }

        var category_country = countries.none;
        if (category_view) |link_view| category_country = link_view.country;
        const ties = Ties.of(fact.cctld, category_country, entity, query.via);
        if (query.country) |want| if (!ties.contains(want)) return null;
        return ties;
    }

    fn view(self: *Evaluator, category_id: u64) CategoryView {
        const known_view = self.index.category_views.get(category_id) orelse return .{
            .country = countries.none,
            .branch = category_id,
            .is_root = true,
            .order = 0,
            .last_descendant = 0,
        };
        assert(known_view.order <= known_view.last_descendant);
        return known_view;
    }

    fn tally(self: *Evaluator, id: u64, fact: *const LinkFact, ties: *const Ties) !void {
        assert(ties.len <= ties.codes.len);
        const entity = self.index.entities.getPtr(id);
        if (entity) |fact_entity| assert(fact_entity.religions & ~entities.religion_mask == 0);
        switch (self.query.group_by) {
            .none => {},
            .domain => try self.count(fact.domain, fact.site),
            .site => try self.count(fact.site, fact.site),
            .host => try self.count(fact.host, fact.site),
            .branch => try self.count(self.view(fact.category_id).branch, fact.site),
            .country => for (ties.codes[0..ties.len]) |code| {
                try self.count(country_key(code), fact.site);
            },
            .religion => if (entity) |fact_entity| for (0..@bitSizeOf(u16)) |bit| {
                const flag = @as(u16, 1) << @intCast(bit);
                if (fact_entity.religions & flag != 0) try self.count(bit, fact.site);
            },
            .person => if (entity) |fact_entity| for (fact_entity.people()) |name| {
                try self.count(name, fact.site);
            },
            .org => if (entity) |fact_entity| for (fact_entity.orgs()) |name| {
                try self.count(name, fact.site);
            },
        }
    }

    fn count(self: *Evaluator, key: u64, site: StringId) !void {
        assert(site < self.index.strings.values.items.len);
        const slot = try self.tallies.getOrPut(self.arena, key);
        if (!slot.found_existing) slot.value_ptr.* = .{};
        slot.value_ptr.links += 1;

        const pair = try self.group_sites.getOrPut(self.arena, .{ .key = key, .site = site });
        if (!pair.found_existing) slot.value_ptr.sites += 1;
        assert(slot.value_ptr.sites <= slot.value_ptr.links);
    }

    fn top_groups(self: *Evaluator) ![]const Group {
        var groups = try std.ArrayListUnmanaged(Group).initCapacity(
            self.arena,
            self.tallies.count(),
        );
        var tallies = self.tallies.iterator();
        var visited: usize = 0;
        while (tallies.next()) |entry| : (visited += 1) {
            assert(visited < self.tallies.count());
            groups.appendAssumeCapacity(.{
                .label = try self.label(entry.key_ptr.*),
                .category_id = if (self.query.group_by == .branch) entry.key_ptr.* else 0,
                .links = entry.value_ptr.links,
                .sites = entry.value_ptr.sites,
            });
        }
        std.mem.sortUnstable(Group, groups.items, {}, larger_group_first);
        if (groups.items.len > 1) {
            const earlier_groups = groups.items[0 .. groups.items.len - 1];
            for (groups.items[1..], earlier_groups) |later, earlier| {
                assert(!larger_group_first({}, later, earlier));
            }
        }
        const top = groups.items[0..@min(groups.items.len, self.query.group_limit)];
        assert(top.len <= self.query.group_limit);
        return top;
    }

    fn label(self: *Evaluator, key: u64) ![]const u8 {
        switch (self.query.group_by) {
            .none, .branch => return "",
            .domain, .site, .host, .person, .org => {
                assert(key <= std.math.maxInt(StringId));
                return self.arena.dupe(u8, self.index.strings.get(@intCast(key)));
            },
            .religion => {
                assert(key < @typeInfo(entities.Religion).@"enum".fields.len);
                return @tagName(@as(entities.Religion, @enumFromInt(key)));
            },
            .country => {
                const code = country_from_key(key);
                assert(known(code));
                return self.arena.dupe(u8, &code);
            },
        }
    }

    const Page = struct { rows: []const PageRow, next_after_id: u64 };

    fn page(self: *Evaluator, sorted_ids: []const u64) !Page {
        assert(std.sort.isSorted(u64, sorted_ids, {}, std.sort.asc(u64)));
        const start = std.sort.upperBound(u64, sorted_ids, self.query.after_id, order_u64);
        const end = @min(sorted_ids.len, start + self.query.page_limit);
        assert(start <= end);

        const rows = try self.arena.alloc(PageRow, end - start);
        for (sorted_ids[start..end], rows) |id, *row| {
            const fact = self.index.links.get(id).?;
            const entity = self.index.entities.getPtr(id);
            row.* = .{
                .link_id = id,
                .site = try self.arena.dupe(u8, self.index.strings.get(fact.site)),
                .cctld = fact.cctld,
                .category_country = self.view(fact.category_id).country,
                .entity_countries = if (entity) |fact_entity| try self.arena.dupe(
                    countries.Code,
                    fact_entity.country_slice(),
                ) else &.{},
                .religions = if (entity) |fact_entity| fact_entity.religions else 0,
            };
        }
        assert(rows.len <= self.query.page_limit);
        const more = end < sorted_ids.len;
        if (more) assert(rows.len == self.query.page_limit);
        return .{
            .rows = rows,
            .next_after_id = if (more and end > start) sorted_ids[end - 1] else 0,
        };
    }
};

fn order_u64(context: u64, item: u64) std.math.Order {
    return std.math.order(context, item);
}

fn country_key(code: countries.Code) u64 {
    assert(known(code));
    const key = (@as(u64, code[0]) << 8) | code[1];
    assert(key <= std.math.maxInt(u16));
    return key;
}

fn country_from_key(key: u64) countries.Code {
    assert(key <= std.math.maxInt(u16));
    const code: countries.Code = .{ @intCast(key >> 8), @intCast(key & 0xff) };
    assert(known(code));
    return code;
}

fn larger_group_first(_: void, a: Group, b: Group) bool {
    assert(a.links > 0);
    assert(b.links > 0);
    if (a.links != b.links) return a.links > b.links;
    const by_label = std.mem.order(u8, a.label, b.label);
    if (by_label != .eq) return by_label == .lt;
    return a.category_id < b.category_id;
}

const testing = std.testing;

fn test_link(options: struct { id: u64, category_id: u64 }, url: []const u8) schema.Link {
    assert(options.id != 0);
    var link: schema.Link = .{ .id = options.id, .category_id = options.category_id };
    assert(url.len <= link.url.data.len);
    link.url = @TypeOf(link.url).fromSlice(url);
    return link;
}

fn test_category(options: struct { id: u64, parent_id: u64 }, name: []const u8) schema.Category {
    assert(options.id != 0);
    var category: schema.Category = .{ .id = options.id, .parent_id = options.parent_id };
    assert(name.len <= category.name.data.len);
    category.name = @TypeOf(category.name).fromSlice(name);
    return category;
}

fn inserted(link: schema.Link) changeset.ChangeSet {
    assert(link.id != 0);
    assert(link.category_id != 0);
    return .{ .link_inserted = .{ .link = link, .ancestor_updates = &.{}, .tokens = &.{} } };
}

fn category_inserted(category: schema.Category) changeset.ChangeSet {
    assert(category.id != 0);
    assert(category.parent_id != category.id);
    return .{ .category_inserted = .{
        .cat = category,
        .ancestor_updates = &.{},
        .tokens = &.{},
        .slug_path = "",
        .is_shallowest_for_slug = true,
    } };
}

fn build_tree(
    index: *FactsIndex,
    io: std.Io,
    allocator: std.mem.Allocator,
    categories: []const schema.Category,
) !void {
    assert(categories.len > 0);
    for (categories) |category| try index.observe(io, allocator, &category_inserted(category));
    assert(index.categories.count() >= categories.len);
}

// Insert a link, edit its URL, move it and delete it through observe, checking the site, domain,
// ccTLD and category facts after each step.
test "observe keeps a link's facts in step with inserts, URL edits, moves and deletes" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    const original = test_link(.{ .id = 7, .category_id = 10 }, "http://samvak.tripod.com/");
    try index.observe(io, allocator, &inserted(original));
    try testing.expectEqualStrings(
        "samvak.tripod.com",
        index.strings.get(index.links.get(7).?.site),
    );

    const edited = test_link(.{ .id = 7, .category_id = 10 }, "http://www.uet.edu.pk/");
    try index.observe(
        io,
        allocator,
        &.{ .link_text_updated = .{
            .old_link = original,
            .new_link = edited,
            .old_tokens = &.{},
            .new_tokens = &.{},
        } },
    );
    const fact = index.links.get(7).?;
    try testing.expectEqualStrings("uet.edu.pk", index.strings.get(fact.domain));
    try testing.expectEqualSlices(u8, "PK", &fact.cctld);

    const moved = test_link(.{ .id = 7, .category_id = 11 }, "http://www.uet.edu.pk/");
    try index.observe(
        io,
        allocator,
        &.{ .link_recategorized = .{
            .link = moved,
            .old_category_id = 10,
            .old_chain_updates = &.{},
            .new_chain_updates = &.{},
        } },
    );
    try testing.expectEqual(@as(u64, 11), index.links.get(7).?.category_id);

    try index.observe(
        io,
        allocator,
        &.{ .link_deleted = .{ .link = moved, .ancestor_updates = &.{}, .tokens = &.{} } },
    );
    try testing.expectEqual(@as(usize, 0), index.links.count());
}

// Build a small tree with one link under Arts and one under Science, then ask for the Arts
// subtree and for roots that do not exist.
test "subtree_link_ids collects the links under known roots and nothing for unknown ones" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try build_tree(
        &index,
        io,
        allocator,
        &.{
            test_category(.{ .id = 1, .parent_id = 0 }, "Top"),
            test_category(.{ .id = 2, .parent_id = 1 }, "Arts"),
            test_category(.{ .id = 3, .parent_id = 2 }, "Music"),
            test_category(.{ .id = 4, .parent_id = 1 }, "Science"),
        },
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 10, .category_id = 3 }, "http://music.example/")),
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 11, .category_id = 4 }, "http://science.example/")),
    );

    const under_arts = try index.subtree_link_ids(io, allocator, allocator, &.{2});
    defer allocator.free(under_arts);
    try testing.expectEqualSlices(u64, &.{10}, under_arts);

    const none = try index.subtree_link_ids(io, allocator, allocator, &.{ 999, 998 });
    defer allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

// Goal: overlapping and repeated roots count each link once. Method: ask for a parent, its
// child and the parent again, then for the child alone.
test "subtree_link_ids counts a link once under nested and repeated roots" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try build_tree(
        &index,
        io,
        allocator,
        &.{
            test_category(.{ .id = 1, .parent_id = 0 }, "Top"),
            test_category(.{ .id = 2, .parent_id = 1 }, "Arts"),
            test_category(.{ .id = 3, .parent_id = 2 }, "Music"),
        },
    );
    for ([_]u64{ 10, 11, 12 }, [_]u64{ 2, 3, 3 }) |id, category_id| {
        const link = test_link(.{ .id = id, .category_id = category_id }, "http://a.example/");
        try index.observe(io, allocator, &inserted(link));
    }

    const nested = try index.subtree_link_ids(io, allocator, allocator, &.{ 2, 3, 2 });
    defer allocator.free(nested);
    std.mem.sortUnstable(u64, nested, {}, std.sort.asc(u64));
    try testing.expectEqualSlices(u64, &.{ 10, 11, 12 }, nested);

    const child = try index.subtree_link_ids(io, allocator, allocator, &.{3});
    defer allocator.free(child);
    try testing.expectEqualSlices(u64, &.{ 11, 12 }, child);
}

/// What visiting every link answers for `request`: the oracle each driver must agree with.
fn scanned(index: *const FactsIndex, arena: std.mem.Allocator, request: *const Query) ![]u64 {
    assert(index.current());
    const string_count = index.strings.values.items.len;
    var evaluator: Evaluator = .{
        .index = index,
        .arena = arena,
        .query = request,
        .scope = index.category_views.get(request.category_id),
        .name = if (request.entity_name.len > 0) index.name_id(request.entity_name) else null,
        .site_set = try std.DynamicBitSetUnmanaged.initEmpty(arena, string_count),
        .host_set = try std.DynamicBitSetUnmanaged.initEmpty(arena, string_count),
        .domain_set = try std.DynamicBitSetUnmanaged.initEmpty(arena, string_count),
    };
    try evaluator.visit_every_link();
    std.mem.sortUnstable(u64, evaluator.matches.items, {}, std.sort.asc(u64));
    return evaluator.matches.items;
}

fn expect_drivers_agree_with_a_scan(
    index: *FactsIndex,
    io: std.Io,
    arena: std.mem.Allocator,
    words: *const IdSet,
) !void {
    const any: ?u8 = null;
    const requests = [_]Query{
        .{ .status = any, .category_id = 2 },
        .{ .status = any, .category_id = 3 },
        .{ .status = any, .category_id = 999 },
        .{ .status = any, .domain_suffix = "tripod.com" },
        .{ .status = any, .domain_suffix = "samvak.tripod.com" },
        .{ .status = any, .domain_suffix = "nowhere.example" },
        .{ .status = any, .domain_suffix = "pk" },
        .{ .status = any, .domain_suffix = "edu.pk" },
        .{ .status = any, .domain_suffix = "uet.edu.pk" },
        .{ .status = any, .entity_name = "jamia farooqia" },
        .{ .status = any, .entity_name = "nobody" },
        .{ .status = any, .category_id = 2, .domain_suffix = "tripod.com" },
        .{ .status = any, .category_id = 4, .entity_name = "Jamia Farooqia" },
        .{ .status = any, .allowed_ids = words },
        .{ .status = any, .allowed_ids = words, .domain_suffix = "tripod.com" },
        .{ .status = any, .country = "PK".* },
        .{ .status = any },
    };
    for (requests) |request| {
        var paged = request;
        paged.page_limit = 2 * dirty_links_max;
        const answer = try index.query(io, testing.allocator, arena, paged);
        const expected = try scanned(index, arena, &paged);
        try testing.expectEqual(expected.len, answer.total);
        try testing.expectEqual(expected.len, answer.page.len);
        for (expected, answer.page) |id, row| try testing.expectEqual(id, row.link_id);
    }
}

// Goal: whichever adjacency list drives a query, the answer is the one a scan of every link
// gives: straight after a build, with writes still pending beside the lists, and after the
// pending writes pass `dirty_links_max` and force a rebuild. Method: one table of queries,
// compared with `scanned` at each of the three points.
test "every driver answers what a scan of every link answers, through writes and a rebuild" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try build_tree(&index, io, allocator, &.{
        test_category(.{ .id = 1, .parent_id = 0 }, "Top"),
        test_category(.{ .id = 2, .parent_id = 1 }, "Arts"),
        test_category(.{ .id = 3, .parent_id = 2 }, "Music"),
        test_category(.{ .id = 4, .parent_id = 1 }, "Society"),
    });
    const urls = [_][]const u8{
        "http://samvak.tripod.com/",    "http://members.tripod.com/~x/",
        "http://www.uet.edu.pk/",       "http://www.example.org/",
        "http://farooqia.example.org/", "http://two.tripod.com/",
    };
    for (urls, [_]u64{ 2, 3, 4, 4, 4, 3 }, 1..) |url, category_id, id| {
        const link = test_link(.{ .id = id, .category_id = category_id }, url);
        try index.observe(io, allocator, &inserted(link));
    }
    var buffer: [256]u8 = undefined;
    const named = try entity_blob(&buffer, &.{.islam}, &.{"PK"}, &.{}, &.{"Jamia Farooqia"});
    try put_entities(&index, io, allocator, 3, named);
    var twice_buffer: [256]u8 = undefined;
    const farooqia = [_][]const u8{"Jamia Farooqia"};
    const named_twice = try entity_blob(&twice_buffer, &.{}, &.{}, &farooqia, &farooqia);
    try put_entities(&index, io, allocator, 5, named_twice);

    var words: IdSet = .empty;
    defer words.deinit(allocator);
    for ([_]u64{ 1, 4, 6, 77 }) |id| try words.put(allocator, id, {});

    try expect_drivers_agree_with_a_scan(&index, io, arena, &words);
    try testing.expectEqual(@as(usize, 0), index.dirty_links.count());

    const moved = test_link(.{ .id = 1, .category_id = 4 }, "http://samvak.tripod.com/");
    try index.observe(io, allocator, &.{ .link_recategorized = .{
        .link = moved,
        .old_category_id = 2,
        .old_chain_updates = &.{},
        .new_chain_updates = &.{},
    } });
    const gone = test_link(.{ .id = 6, .category_id = 3 }, "http://two.tripod.com/");
    try index.observe(io, allocator, &.{
        .link_deleted = .{ .link = gone, .ancestor_updates = &.{}, .tokens = &.{} },
    });
    const added = test_link(.{ .id = 7, .category_id = 3 }, "http://new.tripod.com/");
    try index.observe(io, allocator, &inserted(added));
    try put_entities(&index, io, allocator, 7, named);

    try testing.expectEqual(@as(usize, 3), index.dirty_links.count());
    try expect_drivers_agree_with_a_scan(&index, io, arena, &words);
    try testing.expectEqual(@as(usize, 3), index.dirty_links.count());

    for (100..100 + dirty_links_max) |id| {
        const link = test_link(.{ .id = id, .category_id = 3 }, "http://bulk.example.net/");
        try index.observe(io, allocator, &inserted(link));
    }
    try testing.expect(index.dirty_links.count() > dirty_links_max);
    try expect_drivers_agree_with_a_scan(&index, io, arena, &words);
    try testing.expectEqual(@as(usize, 0), index.dirty_links.count());
}

// Goal: a site's neighbours are the sites filed beside it, the one sharing more categories
// first, and never the site itself, a pending link's site or a site in no shared category.
// Method: three categories with overlapping sites, asked from one site, an unknown one and a
// public suffix.
test "sites_like ranks the sites filed in the same categories" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try build_tree(&index, io, allocator, &.{
        test_category(.{ .id = 1, .parent_id = 0 }, "Top"),
        test_category(.{ .id = 2, .parent_id = 1 }, "Films"),
        test_category(.{ .id = 3, .parent_id = 1 }, "Reviews"),
        test_category(.{ .id = 4, .parent_id = 1 }, "Gardening"),
    });
    const urls = [_][]const u8{
        "http://www.imdb.example/a", "http://reviews.example/a", "http://stills.example/",
        "http://www.imdb.example/b", "http://reviews.example/b", "http://roses.example/",
        "http://waiting.example/",
    };
    for (urls, [_]u64{ 2, 2, 2, 3, 3, 4, 3 }, 1..) |url, category_id, id| {
        var link = test_link(.{ .id = id, .category_id = category_id }, url);
        if (id == 7) link.status = @intFromEnum(schema.LinkStatus.pending);
        try index.observe(io, allocator, &inserted(link));
    }

    const like = try index.sites_like(
        io,
        allocator,
        arena,
        .{ .suffix = "imdb.example", .limit = 10 },
    );
    try testing.expectEqual(@as(usize, 2), like.len);
    try testing.expectEqualStrings("reviews.example", like[0].label);
    try testing.expectEqual(@as(u32, 2), like[0].shared);
    try testing.expectEqualStrings("stills.example", like[1].label);
    try testing.expectEqual(@as(u32, 1), like[1].shared);

    const fewer = [_]struct { suffix: []const u8, limit: u32, expected: u32 }{
        .{ .suffix = "imdb.example", .limit = 1, .expected = 1 },
        .{ .suffix = "no.example", .limit = 5, .expected = 0 },
        .{ .suffix = "example", .limit = 5, .expected = 0 },
    };
    for (fewer) |case| {
        const found = try index.sites_like(
            io,
            allocator,
            arena,
            .{ .suffix = case.suffix, .limit = case.limit },
        );
        try testing.expectEqual(@as(usize, case.expected), found.len);
    }
}

// Goal: an entity's neighbours are the names that share its links, by how many links, with a
// name given as both person and organisation counted once. Method: three links naming
// overlapping people and organisations.
test "named_alongside counts the links two names share" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try build_tree(&index, io, allocator, &.{test_category(.{ .id = 1, .parent_id = 0 }, "Top")});
    for (1..4) |id| {
        const link = test_link(.{ .id = id, .category_id = 1 }, "http://a.example/");
        try index.observe(io, allocator, &inserted(link));
    }
    var buffer: [256]u8 = undefined;
    const amnesty = [_][]const u8{"Amnesty International"};
    const both = [_][]const u8{ "Amnesty International", "United Nations" };
    const watch = [_][]const u8{"Human Rights Watch"};
    const named = [_]struct { people: []const []const u8, orgs: []const []const u8 }{
        .{ .people = &watch, .orgs = &both },
        .{ .people = &.{}, .orgs = &both },
        .{ .people = &amnesty, .orgs = &amnesty },
    };
    for (named, 1..) |names, id| {
        const blob = try entity_blob(&buffer, &.{}, &.{}, names.people, names.orgs);
        try put_entities(&index, io, allocator, id, blob);
    }

    const alongside = try index.named_alongside(
        io,
        allocator,
        arena,
        .{ .name = "amnesty international", .limit = 10 },
    );
    try testing.expectEqual(@as(usize, 2), alongside.len);
    try testing.expectEqualStrings("United Nations", alongside[0].label);
    try testing.expectEqual(@as(u32, 2), alongside[0].shared);
    try testing.expectEqualStrings("Human Rights Watch", alongside[1].label);
    try testing.expectEqual(@as(u32, 1), alongside[1].shared);

    const nobody = try index.named_alongside(
        io,
        allocator,
        arena,
        .{ .name = "nobody", .limit = 5 },
    );
    try testing.expectEqual(@as(usize, 0), nobody.len);
}

// Goal: a category's namesakes are the other categories with its name, larger subtree first,
// and candidates on its own line of ancestors and descendants are dropped. Method: two Chess
// categories, one with a child, plus an unrelated category.
test "namesakes lists same-named categories and off_the_line drops a category's own line" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try build_tree(&index, io, allocator, &.{
        test_category(.{ .id = 1, .parent_id = 0 }, "Top"),
        test_category(.{ .id = 2, .parent_id = 1 }, "Games"),
        test_category(.{ .id = 3, .parent_id = 2 }, "Chess"),
        test_category(.{ .id = 4, .parent_id = 3 }, "Openings"),
        test_category(.{ .id = 5, .parent_id = 1 }, "Computers"),
        test_category(.{ .id = 6, .parent_id = 5 }, "Chess"),
        test_category(.{ .id = 7, .parent_id = 1 }, "Chess"),
        test_category(.{ .id = 8, .parent_id = 7 }, "Clubs"),
        test_category(.{ .id = 9, .parent_id = 8 }, "Europe"),
    });

    const twins = try index.namesakes(io, allocator, arena, .{ .category_id = 6, .limit = 10 });
    try testing.expectEqualSlices(u64, &.{ 7, 3 }, twins);
    const none = try index.namesakes(io, allocator, arena, .{ .category_id = 5, .limit = 10 });
    try testing.expectEqual(@as(usize, 0), none.len);

    const kept = try index.off_the_line(
        io,
        allocator,
        arena,
        .{ .category_id = 3, .candidates = &.{ 2, 4, 6, 1, 99, 3, 9 } },
    );
    try testing.expectEqualSlices(u64, &.{ 6, 9 }, kept);
}

// Goal: a snapshot round trip reproduces the index. Method: load links on two hosts, write the
// section into a buffer, restore it into a fresh index and compare counts, strings and a query.
test "snapshot round trip reproduces links, strings and a domain query" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    index.begin_load(io);
    const one = test_link(.{ .id = 1, .category_id = 10 }, "http://one.tripod.com/");
    const two = test_link(.{ .id = 2, .category_id = 10 }, "http://two.tripod.com/");
    const three = test_link(.{ .id = 3, .category_id = 11 }, "http://www.example.org/");
    try index.load_link(io, allocator, &one);
    try index.load_link(io, allocator, &two);
    try index.load_link(io, allocator, &three);
    index.finish_load(io, allocator);

    var buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var payload = derived_snapshot.SectionWriter.init(&writer);
    try index.snapshot_write(io, &payload);

    var reader = std.Io.Reader.fixed(buffer[0..writer.end]);
    var incoming = derived_snapshot.SectionReader.init(&reader);
    var restored: FactsIndex = .{};
    defer restored.deinit(allocator);
    try restored.snapshot_restore(allocator, &incoming);
    try testing.expectEqual(payload.bytes, incoming.bytes);
    try testing.expectEqual(payload.crc.final(), incoming.crc.final());
    restored.ready.store(true, .release);

    try testing.expectEqual(index.links.count(), restored.links.count());
    try testing.expectEqual(index.strings.values.items.len, restored.strings.values.items.len);
    const domain_of_two = restored.strings.get(restored.links.get(2).?.domain);
    try testing.expectEqualStrings("tripod.com", domain_of_two);
    try testing.expect(restored.links.get(3).?.subdomain == false);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const on_tripod = try restored.query(io, allocator, arena.allocator(), .{
        .domain_suffix = "tripod.com",
        .subdomain_only = true,
        .page_limit = 5,
    });
    try testing.expectEqual(@as(u64, 2), on_tripod.total);
}

// Goal: a damaged section never half-fills an index. Method: restore from a truncated buffer
// and from one whose link row names a string the table does not hold.
test "snapshot restore refuses a truncated section and a row with a foreign string id" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    index.begin_load(io);
    const one = test_link(.{ .id = 1, .category_id = 10 }, "http://one.tripod.com/");
    try index.load_link(io, allocator, &one);
    index.finish_load(io, allocator);

    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var payload = derived_snapshot.SectionWriter.init(&writer);
    try index.snapshot_write(io, &payload);
    const written = buffer[0..writer.end];

    var truncated_reader = std.Io.Reader.fixed(written[0 .. written.len - 8]);
    var truncated = derived_snapshot.SectionReader.init(&truncated_reader);
    var from_truncated: FactsIndex = .{};
    defer from_truncated.deinit(allocator);
    try testing.expectError(
        error.EndOfStream,
        from_truncated.snapshot_restore(allocator, &truncated),
    );
    from_truncated.snapshot_discard(allocator);

    // The link row is the last 40 bytes: its host id sits right after the two u64s.
    const host_offset = written.len - @sizeOf(LinkRecord) + 16;
    std.mem.writeInt(u32, written[host_offset..][0..4], 9999, .little);
    var foreign_reader = std.Io.Reader.fixed(written);
    var foreign = derived_snapshot.SectionReader.init(&foreign_reader);
    var from_foreign: FactsIndex = .{};
    defer from_foreign.deinit(allocator);
    try testing.expectError(
        error.SnapshotCorrupt,
        from_foreign.snapshot_restore(allocator, &foreign),
    );
    from_foreign.snapshot_discard(allocator);
    try testing.expectEqual(@as(usize, 0), from_foreign.links.count());
}

// While loading, apply a newer insert and a delete before the loader hands over its older reads
// of the same links: the apply-path state must win and the touched set must be cleared after.
test "a link the apply path touches while loading keeps that state, not the loader's read" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    index.begin_load(io);
    const stale_read = test_link(.{ .id = 1, .category_id = 10 }, "http://old.example.com/");
    const deleted_meanwhile = test_link(
        .{ .id = 2, .category_id = 10 },
        "http://gone.example.com/",
    );

    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 1, .category_id = 10 }, "http://new.example.org/")),
    );
    try index.observe(
        io,
        allocator,
        &.{ .link_deleted = .{
            .link = deleted_meanwhile,
            .ancestor_updates = &.{},
            .tokens = &.{},
        } },
    );

    try index.load_link(io, allocator, &stale_read);
    try index.load_link(io, allocator, &deleted_meanwhile);
    try index.load_link(
        io,
        allocator,
        &test_link(.{ .id = 3, .category_id = 10 }, "http://untouched.example.net/"),
    );
    index.finish_load(io, allocator);

    try testing.expectEqualStrings("example.org", index.strings.get(index.links.get(1).?.domain));
    try testing.expect(index.links.get(2) == null);
    try testing.expect(index.links.get(3) != null);
    try testing.expect(index.ready.load(.acquire));
    try testing.expectEqual(@as(usize, 0), index.touched_links.count());
}

// Build chains through Regional, Surnames filed by letter and Breeds, rebuild the views and
// check each category's country, branch and subtree containment.
test "a category's country is the outermost country on its chain" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try build_tree(&index, io, allocator, &.{
        test_category(.{ .id = 1, .parent_id = 0 }, "Top"),
        test_category(.{ .id = 2, .parent_id = 1 }, "Regional"),
        test_category(.{ .id = 3, .parent_id = 2 }, "United_States"),
        test_category(.{ .id = 4, .parent_id = 3 }, "Georgia"),
        test_category(.{ .id = 5, .parent_id = 1 }, "Society"),
        test_category(.{ .id = 6, .parent_id = 5 }, "Surnames"),
        test_category(.{ .id = 7, .parent_id = 6 }, "J"),
        test_category(.{ .id = 8, .parent_id = 7 }, "Jordan"),
        test_category(.{ .id = 9, .parent_id = 1 }, "Business"),
        test_category(.{ .id = 10, .parent_id = 9 }, "Breeds"),
        test_category(.{ .id = 11, .parent_id = 10 }, "Jersey"),
        test_category(.{ .id = 12, .parent_id = 2 }, "Europe"),
        test_category(.{ .id = 13, .parent_id = 12 }, "Germany"),
    });

    try index.rebuild_category_views(allocator);
    const view = struct {
        fn of(facts: *const FactsIndex, id: u64) CategoryView {
            assert(id != 0);
            return facts.category_views.get(id).?;
        }
    }.of;

    try testing.expectEqualSlices(u8, "US", &view(&index, 4).country);
    try testing.expectEqualSlices(u8, "DE", &view(&index, 13).country);
    try testing.expect(!known(view(&index, 8).country));
    try testing.expect(!known(view(&index, 11).country));
    try testing.expectEqual(@as(u64, 2), view(&index, 4).branch);
    try testing.expectEqual(@as(u64, 1), view(&index, 1).branch);
    try testing.expect(view(&index, 3).contains(&view(&index, 4)));
    try testing.expect(!view(&index, 3).contains(&view(&index, 13)));
    try testing.expect(view(&index, 1).contains(&view(&index, 13)));
}

// Look categories up by folded name in another case and number, then rename and delete some
// and check the old names no longer resolve while the new ones do.
test "a category is found by its folded name and a rename or delete forgets the old one" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try build_tree(&index, io, allocator, &.{
        test_category(.{ .id = 1, .parent_id = 0 }, "Top"),
        test_category(.{ .id = 2, .parent_id = 1 }, "Arts"),
        test_category(.{ .id = 3, .parent_id = 1 }, "Society"),
        test_category(.{ .id = 4, .parent_id = 3 }, "Art"),
        test_category(.{ .id = 5, .parent_id = 2 }, "Pink_Floyd"),
        test_category(.{ .id = 6, .parent_id = 2 }, "Kids_and_Teens"),
    });

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualSlices(u64, &.{ 2, 4 }, try index.categories_named(io, arena, "ART"));
    try testing.expectEqualSlices(u64, &.{5}, try index.categories_named(io, arena, "pink floyd"));
    try testing.expectEqualSlices(
        u64,
        &.{6},
        try index.categories_named(io, arena, "Kids and Teens"),
    );

    try index.write_category(io, allocator, &test_category(.{ .id = 4, .parent_id = 1 }, "Art"));
    try index.write_category(
        io,
        allocator,
        &test_category(.{ .id = 5, .parent_id = 2 }, "Pink_Floyd_Tribute"),
    );
    try testing.expectEqualSlices(u64, &.{ 2, 4 }, try index.categories_named(io, arena, "arts"));
    try testing.expectEqual(
        @as(usize, 0),
        (try index.categories_named(io, arena, "pink floyd")).len,
    );
    try testing.expectEqualSlices(
        u64,
        &.{5},
        try index.categories_named(io, arena, "pink floyd tribute"),
    );

    try index.drop_category(io, allocator, 2);
    try testing.expectEqualSlices(u64, &.{4}, try index.categories_named(io, arena, "arts"));
}

// Store whole-host, path and tilde sites on tripod plus a tilde site elsewhere, then query with
// subdomain_only on and off a domain suffix.
test "subdomain_only keeps whole-host sites on a hosting platform and leaves out path sites" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try build_tree(
        &index,
        io,
        allocator,
        &.{
            test_category(.{ .id = 1, .parent_id = 0 }, "Top"),
            test_category(.{ .id = 2, .parent_id = 1 }, "Arts"),
        },
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 10, .category_id = 2 }, "http://samvak.tripod.com/")),
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(
            .{
                .id = 11,
                .category_id = 2,
            },
            "http://samvak.tripod.com/poems.html",
        )),
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 12, .category_id = 2 }, "http://members.tripod.com/~a/")),
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 13, .category_id = 2 }, "http://www.tripod.com/")),
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 14, .category_id = 2 }, "http://www.cs.example.edu/~ada/")),
    );

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const on_tripod = try index.query(
        io,
        allocator,
        arena,
        .{ .domain_suffix = "tripod.com", .subdomain_only = true, .page_limit = 5 },
    );
    try testing.expectEqual(@as(u64, 2), on_tripod.total);
    try testing.expectEqual(@as(u64, 1), on_tripod.sites);

    const anywhere = try index.query(
        io,
        allocator,
        arena,
        .{ .subdomain_only = true, .page_limit = 5 },
    );
    try testing.expectEqual(@as(u64, 2), anywhere.total);
}

// Store four tripod links over three sites and two hosts plus a decoy, query grouped by site
// with a page of two, then fetch the second page from the cursor.
test "a query counts links, distinct sites and hosts, groups by site, and pages after the cursor" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try build_tree(
        &index,
        io,
        allocator,
        &.{
            test_category(.{ .id = 1, .parent_id = 0 }, "Top"),
            test_category(.{ .id = 2, .parent_id = 1 }, "Arts"),
        },
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 10, .category_id = 2 }, "http://samvak.tripod.com/")),
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 11, .category_id = 2 }, "http://members.tripod.com/~a/")),
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(
            .{ .id = 12, .category_id = 2 },
            "http://members.tripod.com/~b/x.html",
        )),
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(
            .{ .id = 13, .category_id = 2 },
            "http://members.tripod.com/~b/y.html",
        )),
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 14, .category_id = 2 }, "http://nottripod.com/")),
    );

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first = try index.query(
        io,
        allocator,
        arena,
        .{ .domain_suffix = "tripod.com", .group_by = .site, .page_limit = 2 },
    );
    try testing.expectEqual(@as(u64, 4), first.total);
    try testing.expectEqual(@as(u64, 3), first.sites);
    try testing.expectEqual(@as(u64, 2), first.hosts);
    try testing.expectEqualStrings("members.tripod.com/~b", first.groups[0].label);
    try testing.expectEqual(@as(u64, 2), first.groups[0].links);
    try testing.expectEqual(@as(u64, 1), first.groups[0].sites);
    try testing.expectEqual(@as(usize, 2), first.page.len);
    try testing.expectEqual(@as(u64, 11), first.next_after_id);

    const second = try index.query(
        io,
        allocator,
        arena,
        .{ .domain_suffix = "tripod.com", .page_limit = 2, .after_id = first.next_after_id },
    );
    try testing.expectEqual(@as(u64, 12), second.page[0].link_id);
    try testing.expectEqual(@as(u64, 13), second.page[1].link_id);
    try testing.expectEqual(@as(u64, 0), second.next_after_id);
}

// Tie Pakistan through a ccTLD on one link and through a category on two others, one of which
// is also British by ccTLD, then count by each edge and group by country.
test "country ties follow the requested edges and a link can count for two countries" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try build_tree(&index, io, allocator, &.{
        test_category(.{ .id = 1, .parent_id = 0 }, "Top"),
        test_category(.{ .id = 2, .parent_id = 1 }, "Society"),
        test_category(.{ .id = 3, .parent_id = 2 }, "Pakistan"),
    });
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 10, .category_id = 2 }, "http://www.uet.edu.pk/")),
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 11, .category_id = 3 }, "http://www.storyofpakistan.com/")),
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 12, .category_id = 3 }, "http://www.bbc.co.uk/urdu/")),
    );

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(
        @as(u64, 1),
        (try index.query(io, allocator, arena, .{ .country = "PK".*, .via = Via.cctld })).total,
    );
    try testing.expectEqual(
        @as(u64, 2),
        (try index.query(io, allocator, arena, .{ .country = "PK".*, .via = Via.category })).total,
    );
    try testing.expectEqual(
        @as(u64, 3),
        (try index.query(io, allocator, arena, .{ .country = "PK".* })).total,
    );

    const by_country = try index.query(io, allocator, arena, .{ .group_by = .country });
    try testing.expectEqual(@as(usize, 2), by_country.groups.len);
    try testing.expectEqualStrings("PK", by_country.groups[0].label);
    try testing.expectEqual(@as(u64, 3), by_country.groups[0].links);
    try testing.expectEqualStrings("GB", by_country.groups[1].label);
}

fn entity_blob(
    buffer: []u8,
    religions: []const entities.Religion,
    codes: []const *const [2]u8,
    people: []const []const u8,
    orgs: []const []const u8,
) ![]const u8 {
    assert(codes.len <= entities.countries_max);
    assert(people.len <= entities.names_max);
    assert(orgs.len <= entities.names_max);
    var mask: u16 = 0;
    for (religions) |religion| mask |= @as(u16, 1) << @intFromEnum(religion);

    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeByte(1);
    try writer.writeInt(u16, mask, .little);
    try writer.writeByte(@intCast(codes.len));
    for (codes) |code| try writer.writeAll(code);
    for ([_][]const []const u8{ people, orgs }) |names| {
        try writer.writeByte(@intCast(names.len));
        for (names) |name| {
            try writer.writeByte(@intCast(name.len));
            try writer.writeAll(name);
        }
    }
    return buffer[0..writer.end];
}

fn put_entities(
    index: *FactsIndex,
    io: std.Io,
    allocator: std.mem.Allocator,
    link_id: u64,
    encoded: []const u8,
) !void {
    assert(link_id != 0);
    assert(encoded.len <= entities.encoded_len_max);
    const entries = [_]changeset.LinkEntitiesEntry{.{ .link_id = link_id, .facts = encoded }};
    try index.observe(io, allocator, &.{ .link_entities_put = .{ .entries = &entries } });
}

// Put facts for a link, flip its status (facts stay), retitle it (facts drop), put facts again
// and delete the link (facts drop).
test "entity facts follow puts, deletes and text edits" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    const link = test_link(.{ .id = 5, .category_id = 10 }, "http://www.storyofpakistan.com/");
    try index.observe(io, allocator, &inserted(link));
    var buffer: [256]u8 = undefined;
    try put_entities(
        &index,
        io,
        allocator,
        5,
        try entity_blob(&buffer, &.{.islam}, &.{"PK"}, &.{}, &.{"Deoband"}),
    );
    try testing.expectEqual(@as(u16, 1), index.entities.get(5).?.religions);

    var rejected = link;
    rejected.status = @intFromEnum(schema.LinkStatus.rejected);
    try index.observe(
        io,
        allocator,
        &.{ .link_text_updated = .{
            .old_link = link,
            .new_link = rejected,
            .old_tokens = &.{},
            .new_tokens = &.{},
        } },
    );
    try testing.expect(index.entities.get(5) != null);

    var retitled = rejected;
    retitled.title = @TypeOf(retitled.title).fromSlice("Another title");
    try index.observe(
        io,
        allocator,
        &.{ .link_text_updated = .{
            .old_link = rejected,
            .new_link = retitled,
            .old_tokens = &.{},
            .new_tokens = &.{},
        } },
    );
    try testing.expect(index.entities.get(5) == null);

    try put_entities(
        &index,
        io,
        allocator,
        5,
        try entity_blob(&buffer, &.{.islam}, &.{}, &.{}, &.{}),
    );
    try index.observe(
        io,
        allocator,
        &.{ .link_deleted = .{ .link = retitled, .ancestor_updates = &.{}, .tokens = &.{} } },
    );
    try testing.expect(index.entities.get(5) == null);
}

// While loading, put fresh facts for a link before the loader hands over its stale read of the
// same link: the fresh facts must survive and an untouched link's facts must load.
test "entities the apply path writes while loading win over the loader's older read" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    var fresh_buffer: [256]u8 = undefined;
    var stale_buffer: [256]u8 = undefined;
    index.begin_load(io);
    try put_entities(
        &index,
        io,
        allocator,
        1,
        try entity_blob(&fresh_buffer, &.{.judaism}, &.{}, &.{}, &.{}),
    );
    try index.load_entities(
        io,
        allocator,
        1,
        try entity_blob(&stale_buffer, &.{.buddhism}, &.{}, &.{}, &.{}),
    );
    try index.load_entities(
        io,
        allocator,
        2,
        try entity_blob(&stale_buffer, &.{.buddhism}, &.{}, &.{}, &.{}),
    );
    index.finish_load(io, allocator);

    try testing.expectEqual(
        @as(u16, 1) << @intFromEnum(entities.Religion.judaism),
        index.entities.get(1).?.religions,
    );
    try testing.expect(index.entities.get(2) != null);
}

// Put the same organisation twice in different letter-cases on one link and group by org: one
// group, labelled with the first spelling, counting one link.
test "a link naming one organisation in two letter-cases counts once under its first spelling" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try build_tree(
        &index,
        io,
        allocator,
        &.{
            test_category(.{ .id = 1, .parent_id = 0 }, "Top"),
            test_category(.{ .id = 2, .parent_id = 1 }, "Arts"),
        },
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 10, .category_id = 2 }, "http://www.etree.org/")),
    );
    var buffer: [256]u8 = undefined;
    try put_entities(
        &index,
        io,
        allocator,
        10,
        try entity_blob(&buffer, &.{}, &.{}, &.{}, &.{ "eTree", "etree" }),
    );

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const by_org = try index.query(io, allocator, arena_state.allocator(), .{ .group_by = .org });

    try testing.expectEqual(@as(usize, 1), by_org.groups.len);
    try testing.expectEqualStrings("eTree", by_org.groups[0].label);
    try testing.expectEqual(@as(u64, 1), by_org.groups[0].links);
}

// Put religion, country, person and org facts on three links, then filter by religion, by a
// country tied only through the entity edge and by a name in another case, and group by
// religion and by person.
test "queries filter by religion and name and tie countries through entities" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try build_tree(
        &index,
        io,
        allocator,
        &.{
            test_category(.{ .id = 1, .parent_id = 0 }, "Top"),
            test_category(.{ .id = 2, .parent_id = 1 }, "Society"),
        },
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 10, .category_id = 2 }, "http://www.storyofpakistan.com/")),
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 11, .category_id = 2 }, "http://www.farooqia.com/")),
    );
    try index.observe(
        io,
        allocator,
        &inserted(test_link(.{ .id = 12, .category_id = 2 }, "http://www.breslov.org/")),
    );

    var buffers: [3][256]u8 = undefined;
    try put_entities(
        &index,
        io,
        allocator,
        10,
        try entity_blob(&buffers[0], &.{.islam}, &.{"PK"}, &.{"Muhammad Ali Jinnah"}, &.{}),
    );
    try put_entities(
        &index,
        io,
        allocator,
        11,
        try entity_blob(&buffers[1], &.{.islam}, &.{"PK"}, &.{}, &.{"Jamia Farooqia"}),
    );
    try put_entities(
        &index,
        io,
        allocator,
        12,
        try entity_blob(&buffers[2], &.{.judaism}, &.{"UA"}, &.{"rebbe nachman"}, &.{}),
    );

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const islam: u16 = @as(u16, 1) << @intFromEnum(entities.Religion.islam);

    try testing.expectEqual(
        @as(u64, 2),
        (try index.query(io, allocator, arena, .{ .religions = islam })).total,
    );
    try testing.expectEqual(
        @as(u64, 2),
        (try index.query(io, allocator, arena, .{ .country = "PK".* })).total,
    );
    try testing.expectEqual(
        @as(u64, 0),
        (try index.query(io, allocator, arena, .{ .country = "PK".*, .via = Via.either })).total,
    );
    try testing.expectEqual(
        @as(u64, 1),
        (try index.query(io, allocator, arena, .{ .entity_name = "JAMIA FAROOQIA" })).total,
    );
    try testing.expectEqual(
        @as(u64, 0),
        (try index.query(io, allocator, arena, .{ .entity_name = "nobody" })).total,
    );

    const by_religion = try index.query(io, allocator, arena, .{ .group_by = .religion });
    try testing.expectEqualStrings("islam", by_religion.groups[0].label);
    try testing.expectEqual(@as(u64, 2), by_religion.groups[0].links);
    try testing.expectEqualStrings("judaism", by_religion.groups[1].label);

    const by_person = try index.query(io, allocator, arena, .{ .group_by = .person });
    try testing.expectEqual(@as(usize, 2), by_person.groups.len);
    const page = (try index.query(io, allocator, arena, .{ .religions = islam })).page;
    try testing.expectEqualSlices(u8, "PK", &page[0].entity_countries[0]);
    try testing.expectEqual(islam, page[0].religions);
}
