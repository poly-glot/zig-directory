const std = @import("std");
const inverted = @import("zigstore").inverted_index;
const schema = @import("../schema.zig");
const changeset = @import("../changeset.zig");
const countries = @import("countries.zig");
const url_facts = @import("url_facts.zig");
const sites = @import("sites.zig");
const entities = @import("entities.zig");

pub const StringId = u32;
pub const IdSet = std.AutoHashMapUnmanaged(u64, void);

const MAX_CATEGORY_DEPTH: usize = 64;
pub const MAX_FOLDED_NAME: usize = 128;

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
    countries: [entities.MAX_COUNTRIES]countries.Code = undefined,
    country_count: u8 = 0,
    name_ids: [2 * entities.MAX_NAMES]StringId = undefined,
    people_count: u8 = 0,
    org_count: u8 = 0,

    fn countrySlice(self: *const EntityFact) []const countries.Code {
        return self.countries[0..self.country_count];
    }

    fn people(self: *const EntityFact) []const StringId {
        return self.name_ids[0..self.people_count];
    }

    fn orgs(self: *const EntityFact) []const StringId {
        return self.name_ids[self.people_count..][0..self.org_count];
    }

    fn allNames(self: *const EntityFact) []const StringId {
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

pub const GroupBy = enum(u8) { none = 0, domain = 1, site = 2, host = 3, branch = 4, country = 5, religion = 6, person = 7, org = 8 };

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
    group_limit: usize = 10,
    page_limit: usize = 20,
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

pub const Answer = struct {
    total: u64,
    sites: u64,
    hosts: u64,
    domains: u64,
    groups: []const Group,
    page: []const PageRow,
    next_after_id: u64,
};

fn known(code: countries.Code) bool {
    return code[0] != 0;
}

const Strings = struct {
    ids: std.StringHashMapUnmanaged(StringId) = .empty,
    values: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Strings, allocator: std.mem.Allocator) void {
        for (self.values.items) |value| allocator.free(value);
        self.values.deinit(allocator);
        self.ids.deinit(allocator);
    }

    fn intern(self: *Strings, allocator: std.mem.Allocator, value: []const u8) !StringId {
        if (self.ids.get(value)) |id| return id;

        const owned = try allocator.dupe(u8, value);
        errdefer allocator.free(owned);
        const id: StringId = @intCast(self.values.items.len);
        try self.values.append(allocator, owned);
        errdefer _ = self.values.pop();
        try self.ids.put(allocator, owned, id);
        return id;
    }

    fn get(self: *const Strings, id: StringId) []const u8 {
        return self.values.items[id];
    }
};

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
    views_stale: bool = true,
    ready: std.atomic.Value(bool) = .init(false),
    loader_stop: std.atomic.Value(bool) = .init(false),

    pub fn deinit(self: *FactsIndex, allocator: std.mem.Allocator) void {
        self.links.deinit(allocator);
        self.categories.deinit(allocator);
        self.strings.deinit(allocator);
        self.touched_links.deinit(allocator);
        self.touched_categories.deinit(allocator);
        self.entities.deinit(allocator);
        self.touched_entities.deinit(allocator);
        var folded = self.name_ids.keyIterator();
        while (folded.next()) |key| allocator.free(key.*);
        self.name_ids.deinit(allocator);
        var named = self.category_names.valueIterator();
        while (named.next()) |ids| ids.deinit(allocator);
        self.category_names.deinit(allocator);
        self.category_views.deinit(allocator);
    }

    pub fn observe(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, cs: changeset.ChangeSet) !void {
        switch (cs) {
            .link_inserted => |e| try self.writeLink(io, allocator, e.link),
            .link_text_updated => |e| {
                try self.writeLink(io, allocator, e.new_link);
                if (schema.embeddedTextChanged(e.old_link, e.new_link)) try self.dropEntities(io, allocator, e.new_link.id);
            },
            .link_recategorized => |e| try self.writeLink(io, allocator, e.link),
            .link_deleted => |e| {
                try self.dropLink(io, allocator, e.link.id);
                try self.dropEntities(io, allocator, e.link.id);
            },
            .link_entities_put => |e| for (e.entries) |entry| try self.writeEntities(io, allocator, entry.link_id, entry.facts),
            .category_inserted => |e| try self.writeCategory(io, allocator, e.cat),
            .category_text_updated => |e| try self.writeCategory(io, allocator, e.new_cat),
            .category_renamed => |e| try self.writeCategory(io, allocator, e.new_cat),
            .category_moved => |e| try self.writeCategory(io, allocator, e.cat),
            .category_deleted => |e| try self.dropCategory(io, allocator, e.cat.id),
            .link_vectors_put, .slug_path_repair_chunk, .slug_path_repair_complete => {},
        }
    }

    pub fn beginLoad(self: *FactsIndex, io: std.Io) void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        self.loading = true;
    }

    pub fn loadLink(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, link: schema.Link) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.touched_links.contains(link.id)) return;
        try self.putLinkLocked(allocator, link);
    }

    pub fn loadEntities(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, link_id: u64, encoded: []const u8) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.touched_entities.contains(link_id)) return;
        try self.putEntitiesLocked(allocator, link_id, encoded);
    }

    pub fn loadCategory(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, cat: schema.Category) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.touched_categories.contains(cat.id)) return;
        try self.putCategoryLocked(allocator, cat);
        self.views_stale = true;
    }

    pub fn finishLoad(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator) void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        self.loading = false;
        self.touched_links.clearAndFree(allocator);
        self.touched_categories.clearAndFree(allocator);
        self.touched_entities.clearAndFree(allocator);
        self.ready.store(true, .release);
    }

    pub fn linkCount(self: *FactsIndex, io: std.Io) usize {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.links.count();
    }

    pub fn entityCount(self: *FactsIndex, io: std.Io) usize {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.entities.count();
    }

    pub fn categoryCount(self: *FactsIndex, io: std.Io) usize {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.categories.count();
    }

    pub fn categoriesNamed(self: *FactsIndex, io: std.Io, arena: std.mem.Allocator, phrase: []const u8) ![]const u64 {
        var folded_buf: [MAX_FOLDED_NAME]u8 = undefined;
        if (phrase.len > folded_buf.len) return &.{};
        const folded = foldName(phrase, &folded_buf);
        if (folded.len == 0) return &.{};

        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        const name = self.strings.ids.get(folded) orelse return &.{};
        const ids = self.category_names.get(name) orelse return &.{};
        return arena.dupe(u64, ids.items);
    }

    pub fn namesSomeone(self: *FactsIndex, io: std.Io, phrase: []const u8) bool {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.nameId(phrase) != null;
    }

    pub fn query(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, arena: std.mem.Allocator, q: Query) !Answer {
        self.lock.lockSharedUncancelable(io);
        if (!self.views_stale) {
            defer self.lock.unlockShared(io);
            return self.evaluate(arena, q);
        }
        self.lock.unlockShared(io);

        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.views_stale) try self.rebuildCategoryViews(allocator);
        return self.evaluate(arena, q);
    }

    fn evaluate(self: *const FactsIndex, arena: std.mem.Allocator, q: Query) !Answer {
        var evaluator: Evaluator = .{
            .index = self,
            .arena = arena,
            .query = q,
            .scope = if (q.category_id == 0) null else self.category_views.get(q.category_id),
            .name = if (q.entity_name.len == 0) null else self.nameId(q.entity_name),
        };
        return evaluator.run();
    }

    fn writeLink(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, link: schema.Link) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.loading) try self.touched_links.put(allocator, link.id, {});
        try self.putLinkLocked(allocator, link);
    }

    fn dropLink(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, id: u64) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.loading) try self.touched_links.put(allocator, id, {});
        _ = self.links.remove(id);
    }

    fn writeEntities(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, link_id: u64, encoded: []const u8) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.loading) try self.touched_entities.put(allocator, link_id, {});
        try self.putEntitiesLocked(allocator, link_id, encoded);
    }

    fn dropEntities(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, link_id: u64) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.loading) try self.touched_entities.put(allocator, link_id, {});
        _ = self.entities.remove(link_id);
    }

    fn putEntitiesLocked(self: *FactsIndex, allocator: std.mem.Allocator, link_id: u64, encoded: []const u8) !void {
        const decoded = entities.decode(encoded) orelse {
            _ = self.entities.remove(link_id);
            return;
        };
        var fact: EntityFact = .{
            .religions = decoded.religions,
            .country_count = @intCast(decoded.country_count),
        };
        @memcpy(fact.countries[0..decoded.country_count], decoded.countrySlice());
        fact.people_count = try self.internDistinct(allocator, decoded.people.slice(), fact.name_ids[0..]);
        fact.org_count = try self.internDistinct(allocator, decoded.orgs.slice(), fact.name_ids[fact.people_count..]);
        try self.entities.put(allocator, link_id, fact);
    }

    fn internDistinct(self: *FactsIndex, allocator: std.mem.Allocator, names: []const []const u8, out: []StringId) !u8 {
        var count: u8 = 0;
        for (names) |name| {
            const id = try self.internName(allocator, name);
            if (std.mem.findScalar(StringId, out[0..count], id) != null) continue;
            out[count] = id;
            count += 1;
        }
        return count;
    }

    fn internName(self: *FactsIndex, allocator: std.mem.Allocator, display: []const u8) !StringId {
        var buf: [entities.MAX_NAME_LEN]u8 = undefined;
        const folded = std.ascii.lowerString(&buf, display[0..@min(display.len, buf.len)]);
        if (self.name_ids.get(folded)) |id| return id;

        const id = try self.strings.intern(allocator, display);
        const owned = try allocator.dupe(u8, folded);
        errdefer allocator.free(owned);
        try self.name_ids.put(allocator, owned, id);
        return id;
    }

    fn nameId(self: *const FactsIndex, name: []const u8) ?StringId {
        var buf: [entities.MAX_NAME_LEN]u8 = undefined;
        if (name.len > buf.len) return null;
        return self.name_ids.get(std.ascii.lowerString(&buf, name));
    }

    fn writeCategory(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, cat: schema.Category) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.loading) try self.touched_categories.put(allocator, cat.id, {});
        try self.putCategoryLocked(allocator, cat);
        self.views_stale = true;
    }

    fn dropCategory(self: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, id: u64) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.loading) try self.touched_categories.put(allocator, id, {});
        if (self.categories.get(id)) |old| self.unlistCategoryName(old.name, id);
        _ = self.categories.remove(id);
        self.views_stale = true;
    }

    fn putLinkLocked(self: *FactsIndex, allocator: std.mem.Allocator, link: schema.Link) !void {
        var host_buf: [url_facts.MAX_HOST_LEN]u8 = undefined;
        const url = url_facts.split(link.url.slice(), &host_buf);
        var site_buf: [sites.MAX_SITE_LEN]u8 = undefined;
        const site = sites.siteOf(url.host, url.path, &site_buf);

        try self.links.put(allocator, link.id, .{
            .category_id = link.category_id,
            .host = try self.strings.intern(allocator, url.host),
            .domain = try self.strings.intern(allocator, url_facts.registrableDomain(url.host)),
            .site = try self.strings.intern(allocator, site.key),
            .cctld = url_facts.cctldCountry(url.host) orelse countries.none,
            .status = link.status,
            .hosted = site.hosted,
            .subdomain = site.hosted and std.mem.findScalar(u8, site.key, '/') == null,
        });
    }

    fn putCategoryLocked(self: *FactsIndex, allocator: std.mem.Allocator, cat: schema.Category) !void {
        const name = cat.name.slice();
        var folded_buf: [MAX_FOLDED_NAME]u8 = undefined;
        const folded = foldName(name, &folded_buf);
        const folded_id = try self.strings.intern(allocator, folded);

        const previous = self.categories.get(cat.id);
        const renamed = if (previous) |old| old.name != folded_id else true;
        if (renamed) {
            if (previous) |old| self.unlistCategoryName(old.name, cat.id);
            if (folded.len > 0) try self.listCategoryName(allocator, folded_id, cat.id);
        }

        try self.categories.put(allocator, cat.id, .{
            .parent_id = cat.parent_id,
            .name = folded_id,
            .named_country = countries.byName(name) orelse countries.none,
            .files_things_by_name = name.len == 1 or parents_that_file_things_by_name.has(name),
        });
    }

    fn listCategoryName(self: *FactsIndex, allocator: std.mem.Allocator, name: StringId, id: u64) !void {
        const entry = try self.category_names.getOrPut(allocator, name);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(allocator, id);
    }

    fn unlistCategoryName(self: *FactsIndex, name: StringId, id: u64) void {
        const ids = self.category_names.getPtr(name) orelse return;
        const at = std.mem.findScalar(u64, ids.items, id) orelse return;
        _ = ids.swapRemove(at);
    }

    fn filesThingsByName(self: *const FactsIndex, id: u64) bool {
        const fact = self.categories.get(id) orelse return false;
        return fact.files_things_by_name;
    }

    fn rebuildCategoryViews(self: *FactsIndex, allocator: std.mem.Allocator) !void {
        var children: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u64)) = .empty;
        defer {
            var lists = children.valueIterator();
            while (lists.next()) |list| list.deinit(allocator);
            children.deinit(allocator);
        }
        var roots: std.ArrayListUnmanaged(u64) = .empty;
        defer roots.deinit(allocator);

        var it = self.categories.iterator();
        while (it.next()) |entry| {
            const parent_id = entry.value_ptr.parent_id;
            if (parent_id == 0 or !self.categories.contains(parent_id)) {
                try roots.append(allocator, entry.key_ptr.*);
                continue;
            }
            const siblings = try children.getOrPut(allocator, parent_id);
            if (!siblings.found_existing) siblings.value_ptr.* = .empty;
            try siblings.value_ptr.append(allocator, entry.key_ptr.*);
        }

        self.category_views.clearRetainingCapacity();
        try self.category_views.ensureTotalCapacity(allocator, self.categories.count());

        var stack: std.ArrayListUnmanaged(Visit) = .empty;
        defer stack.deinit(allocator);
        var clock: u32 = 0;
        for (roots.items) |root| {
            try stack.append(allocator, .{ .id = root });
            while (stack.items.len > 0) {
                const visit = &stack.items[stack.items.len - 1];
                if (!visit.entered) {
                    visit.entered = true;
                    self.category_views.putAssumeCapacity(visit.id, self.viewBelowParent(visit.id, clock));
                    clock += 1;
                }
                const kids: []const u64 = if (children.get(visit.id)) |list| list.items else &.{};
                if (visit.next_child < kids.len) {
                    const child = kids[visit.next_child];
                    visit.next_child += 1;
                    try stack.append(allocator, .{ .id = child });
                    continue;
                }
                self.category_views.getPtr(visit.id).?.last_descendant = clock - 1;
                _ = stack.pop();
            }
        }
        self.views_stale = false;
    }

    fn viewBelowParent(self: *const FactsIndex, id: u64, order: u32) CategoryView {
        const fact = self.categories.get(id).?;
        const parent = if (fact.parent_id == 0) null else self.category_views.get(fact.parent_id);
        const own_country = if (known(fact.named_country) and !self.filesThingsByName(fact.parent_id))
            fact.named_country
        else
            countries.none;

        const p = parent orelse return .{ .country = own_country, .branch = id, .is_root = true, .order = order, .last_descendant = order };
        return .{
            .country = if (known(p.country)) p.country else own_country,
            .branch = if (p.is_root) id else p.branch,
            .is_root = false,
            .order = order,
            .last_descendant = order,
        };
    }
};

const Visit = struct { id: u64, entered: bool = false, next_child: usize = 0 };

fn foldName(text: []const u8, out: *[MAX_FOLDED_NAME]u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    var word_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    var words = inverted.TokenIterator.init(text);
    while (words.next(&word_buf)) |word| {
        const singular = if (word.len > 3 and word[word.len - 1] == 's') word[0 .. word.len - 1] else word;
        if (w.end > 0) w.writeByte(' ') catch break;
        w.writeAll(singular) catch break;
    }
    return out[0..w.end];
}

pub const CategoryView = struct {
    country: countries.Code,
    branch: u64,
    is_root: bool,
    order: u32,
    last_descendant: u32,

    fn contains(self: CategoryView, other: CategoryView) bool {
        return self.order <= other.order and other.order <= self.last_descendant;
    }
};

const Ties = struct {
    codes: [2 + entities.MAX_COUNTRIES]countries.Code = undefined,
    len: usize = 0,

    fn of(cctld: countries.Code, category: countries.Code, entity: ?*const EntityFact, via: u8) Ties {
        var ties: Ties = .{};
        if (via & Via.cctld != 0 and known(cctld)) ties.add(cctld);
        if (via & Via.category != 0 and known(category)) ties.add(category);
        if (via & Via.entity != 0) if (entity) |e| for (e.countrySlice()) |code| ties.add(code);
        return ties;
    }

    fn add(self: *Ties, code: countries.Code) void {
        if (self.contains(code)) return;
        self.codes[self.len] = code;
        self.len += 1;
    }

    fn contains(self: *const Ties, code: countries.Code) bool {
        for (self.codes[0..self.len]) |tied| {
            if (std.mem.eql(u8, &tied, &code)) return true;
        }
        return false;
    }
};

const Tally = struct { links: u64 = 0, sites: u64 = 0 };
const GroupSite = struct { key: u64, site: StringId };

const Evaluator = struct {
    index: *const FactsIndex,
    arena: std.mem.Allocator,
    query: Query,
    scope: ?CategoryView,
    name: ?StringId,
    tallies: std.AutoHashMapUnmanaged(u64, Tally) = .empty,
    group_sites: std.AutoHashMapUnmanaged(GroupSite, void) = .empty,

    fn run(self: *Evaluator) !Answer {
        var matches: std.ArrayListUnmanaged(u64) = .empty;
        const string_count = self.index.strings.values.items.len;
        var site_set = try std.DynamicBitSetUnmanaged.initEmpty(self.arena, string_count);
        var host_set = try std.DynamicBitSetUnmanaged.initEmpty(self.arena, string_count);
        var domain_set = try std.DynamicBitSetUnmanaged.initEmpty(self.arena, string_count);

        var it = self.index.links.iterator();
        while (it.next()) |entry| {
            const fact = entry.value_ptr.*;
            const ties = self.admit(entry.key_ptr.*, fact) orelse continue;

            try matches.append(self.arena, entry.key_ptr.*);
            site_set.set(fact.site);
            host_set.set(fact.host);
            domain_set.set(fact.domain);
            try self.tally(entry.key_ptr.*, fact, ties);
        }

        std.mem.sortUnstable(u64, matches.items, {}, std.sort.asc(u64));
        const paged = try self.page(matches.items);
        return .{
            .total = matches.items.len,
            .sites = site_set.count(),
            .hosts = host_set.count(),
            .domains = domain_set.count(),
            .groups = try self.topGroups(),
            .page = paged.rows,
            .next_after_id = paged.next_after_id,
        };
    }

    fn admit(self: *Evaluator, id: u64, fact: LinkFact) ?Ties {
        const q = self.query;
        if (q.status) |status| if (fact.status != status) return null;
        if (q.hosted_only and !fact.hosted) return null;
        if (q.subdomain_only and !fact.subdomain) return null;
        if (q.allowed_ids) |allowed| if (!allowed.contains(id)) return null;
        if (q.domain_suffix.len > 0 and !url_facts.hasSuffix(self.index.strings.get(fact.host), q.domain_suffix)) return null;

        const entity = self.index.entities.getPtr(id);
        if (q.religions != 0 and (entity == null or entity.?.religions & q.religions == 0)) return null;
        if (q.entity_name.len > 0) {
            const wanted = self.name orelse return null;
            if (entity == null or std.mem.findScalar(StringId, entity.?.allNames(), wanted) == null) return null;
        }

        const category_view = self.index.category_views.get(fact.category_id);
        if (q.category_id != 0) {
            const scope = self.scope orelse return null;
            if (category_view == null or !scope.contains(category_view.?)) return null;
        }

        const category_country = if (category_view) |v| v.country else countries.none;
        const ties = Ties.of(fact.cctld, category_country, entity, q.via);
        if (q.country) |want| if (!ties.contains(want)) return null;
        return ties;
    }

    fn view(self: *Evaluator, category_id: u64) CategoryView {
        return self.index.category_views.get(category_id) orelse
            .{ .country = countries.none, .branch = category_id, .is_root = true, .order = 0, .last_descendant = 0 };
    }

    fn tally(self: *Evaluator, id: u64, fact: LinkFact, ties: Ties) !void {
        const entity = self.index.entities.getPtr(id);
        switch (self.query.group_by) {
            .none => {},
            .domain => try self.count(fact.domain, fact.site),
            .site => try self.count(fact.site, fact.site),
            .host => try self.count(fact.host, fact.site),
            .branch => try self.count(self.view(fact.category_id).branch, fact.site),
            .country => for (ties.codes[0..ties.len]) |code| try self.count(countryKey(code), fact.site),
            .religion => if (entity) |e| for (0..@bitSizeOf(u16)) |bit| {
                if (e.religions & (@as(u16, 1) << @intCast(bit)) != 0) try self.count(bit, fact.site);
            },
            .person => if (entity) |e| for (e.people()) |name| try self.count(name, fact.site),
            .org => if (entity) |e| for (e.orgs()) |name| try self.count(name, fact.site),
        }
    }

    fn count(self: *Evaluator, key: u64, site: StringId) !void {
        const slot = try self.tallies.getOrPut(self.arena, key);
        if (!slot.found_existing) slot.value_ptr.* = .{};
        slot.value_ptr.links += 1;

        const pair = try self.group_sites.getOrPut(self.arena, .{ .key = key, .site = site });
        if (!pair.found_existing) slot.value_ptr.sites += 1;
    }

    fn topGroups(self: *Evaluator) ![]const Group {
        var groups = try std.ArrayListUnmanaged(Group).initCapacity(self.arena, self.tallies.count());
        var it = self.tallies.iterator();
        while (it.next()) |entry| {
            groups.appendAssumeCapacity(.{
                .label = try self.label(entry.key_ptr.*),
                .category_id = if (self.query.group_by == .branch) entry.key_ptr.* else 0,
                .links = entry.value_ptr.links,
                .sites = entry.value_ptr.sites,
            });
        }
        std.mem.sortUnstable(Group, groups.items, {}, largerGroupFirst);
        return groups.items[0..@min(groups.items.len, self.query.group_limit)];
    }

    fn label(self: *Evaluator, key: u64) ![]const u8 {
        switch (self.query.group_by) {
            .none, .branch => return "",
            .domain, .site, .host, .person, .org => return self.arena.dupe(u8, self.index.strings.get(@intCast(key))),
            .religion => return @tagName(@as(entities.Religion, @enumFromInt(key))),
            .country => {
                const code = countryFromKey(key);
                return self.arena.dupe(u8, &code);
            },
        }
    }

    const Page = struct { rows: []const PageRow, next_after_id: u64 };

    fn page(self: *Evaluator, sorted_ids: []const u64) !Page {
        const start = std.sort.upperBound(u64, sorted_ids, self.query.after_id, orderU64);
        const end = @min(sorted_ids.len, start + self.query.page_limit);

        const rows = try self.arena.alloc(PageRow, end - start);
        for (sorted_ids[start..end], rows) |id, *row| {
            const fact = self.index.links.get(id).?;
            const entity = self.index.entities.getPtr(id);
            row.* = .{
                .link_id = id,
                .site = try self.arena.dupe(u8, self.index.strings.get(fact.site)),
                .cctld = fact.cctld,
                .category_country = self.view(fact.category_id).country,
                .entity_countries = if (entity) |e| try self.arena.dupe(countries.Code, e.countrySlice()) else &.{},
                .religions = if (entity) |e| e.religions else 0,
            };
        }
        const more = end < sorted_ids.len;
        return .{ .rows = rows, .next_after_id = if (more and end > start) sorted_ids[end - 1] else 0 };
    }
};

fn orderU64(context: u64, item: u64) std.math.Order {
    return std.math.order(context, item);
}

fn countryKey(code: countries.Code) u64 {
    return (@as(u64, code[0]) << 8) | code[1];
}

fn countryFromKey(key: u64) countries.Code {
    return .{ @intCast(key >> 8), @intCast(key & 0xff) };
}

fn largerGroupFirst(_: void, a: Group, b: Group) bool {
    if (a.links != b.links) return a.links > b.links;
    const by_label = std.mem.order(u8, a.label, b.label);
    if (by_label != .eq) return by_label == .lt;
    return a.category_id < b.category_id;
}

const testing = std.testing;

fn testLink(id: u64, category_id: u64, url: []const u8) schema.Link {
    var link: schema.Link = .{ .id = id, .category_id = category_id };
    link.url = @TypeOf(link.url).fromSlice(url);
    return link;
}

fn testCategory(id: u64, parent_id: u64, name: []const u8) schema.Category {
    var cat: schema.Category = .{ .id = id, .parent_id = parent_id };
    cat.name = @TypeOf(cat.name).fromSlice(name);
    return cat;
}

fn inserted(link: schema.Link) changeset.ChangeSet {
    return .{ .link_inserted = .{ .link = link, .ancestor_updates = &.{}, .tokens = &.{} } };
}

fn categoryInserted(cat: schema.Category) changeset.ChangeSet {
    return .{ .category_inserted = .{ .cat = cat, .ancestor_updates = &.{}, .tokens = &.{}, .slug_path = "", .is_shallowest_for_slug = true } };
}

fn buildTree(index: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, cats: []const schema.Category) !void {
    for (cats) |cat| try index.observe(io, allocator, categoryInserted(cat));
}

test "observe keeps a link's facts in step with inserts, URL edits, moves and deletes" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    const original = testLink(7, 10, "http://samvak.tripod.com/");
    try index.observe(io, allocator, inserted(original));
    try testing.expectEqualStrings("samvak.tripod.com", index.strings.get(index.links.get(7).?.site));

    const edited = testLink(7, 10, "http://www.uet.edu.pk/");
    try index.observe(io, allocator, .{ .link_text_updated = .{ .old_link = original, .new_link = edited, .old_tokens = &.{}, .new_tokens = &.{} } });
    const fact = index.links.get(7).?;
    try testing.expectEqualStrings("uet.edu.pk", index.strings.get(fact.domain));
    try testing.expectEqualSlices(u8, "PK", &fact.cctld);

    const moved = testLink(7, 11, "http://www.uet.edu.pk/");
    try index.observe(io, allocator, .{ .link_recategorized = .{ .link = moved, .old_category_id = 10, .old_chain_updates = &.{}, .new_chain_updates = &.{} } });
    try testing.expectEqual(@as(u64, 11), index.links.get(7).?.category_id);

    try index.observe(io, allocator, .{ .link_deleted = .{ .link = moved, .ancestor_updates = &.{}, .tokens = &.{} } });
    try testing.expectEqual(@as(usize, 0), index.links.count());
}

test "a link the apply path touches while loading keeps that state, not the loader's older read" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    index.beginLoad(io);
    const stale_read = testLink(1, 10, "http://old.example.com/");
    const deleted_meanwhile = testLink(2, 10, "http://gone.example.com/");

    try index.observe(io, allocator, inserted(testLink(1, 10, "http://new.example.org/")));
    try index.observe(io, allocator, .{ .link_deleted = .{ .link = deleted_meanwhile, .ancestor_updates = &.{}, .tokens = &.{} } });

    try index.loadLink(io, allocator, stale_read);
    try index.loadLink(io, allocator, deleted_meanwhile);
    try index.loadLink(io, allocator, testLink(3, 10, "http://untouched.example.net/"));
    index.finishLoad(io, allocator);

    try testing.expectEqualStrings("example.org", index.strings.get(index.links.get(1).?.domain));
    try testing.expect(index.links.get(2) == null);
    try testing.expect(index.links.get(3) != null);
    try testing.expect(index.ready.load(.acquire));
    try testing.expectEqual(@as(usize, 0), index.touched_links.count());
}

test "a category's country is the outermost country on its chain, ignoring names filed by letter or breed" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try buildTree(&index, io, allocator, &.{
        testCategory(1, 0, "Top"),           testCategory(2, 1, "Regional"),
        testCategory(3, 2, "United_States"), testCategory(4, 3, "Georgia"),
        testCategory(5, 1, "Society"),       testCategory(6, 5, "Surnames"),
        testCategory(7, 6, "J"),             testCategory(8, 7, "Jordan"),
        testCategory(9, 1, "Business"),      testCategory(10, 9, "Breeds"),
        testCategory(11, 10, "Jersey"),      testCategory(12, 2, "Europe"),
        testCategory(13, 12, "Germany"),
    });

    try index.rebuildCategoryViews(allocator);
    const view = struct {
        fn of(i: *const FactsIndex, id: u64) CategoryView {
            return i.category_views.get(id).?;
        }
    }.of;

    try testing.expectEqualSlices(u8, "US", &view(&index, 4).country);
    try testing.expectEqualSlices(u8, "DE", &view(&index, 13).country);
    try testing.expect(!known(view(&index, 8).country));
    try testing.expect(!known(view(&index, 11).country));
    try testing.expectEqual(@as(u64, 2), view(&index, 4).branch);
    try testing.expectEqual(@as(u64, 1), view(&index, 1).branch);
    try testing.expect(view(&index, 3).contains(view(&index, 4)));
    try testing.expect(!view(&index, 3).contains(view(&index, 13)));
    try testing.expect(view(&index, 1).contains(view(&index, 13)));
}

test "a category is found by its name in any case or number, and a rename or delete forgets the old name" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try buildTree(&index, io, allocator, &.{
        testCategory(1, 0, "Top"),        testCategory(2, 1, "Arts"),
        testCategory(3, 1, "Society"),    testCategory(4, 3, "Art"),
        testCategory(5, 2, "Pink_Floyd"), testCategory(6, 2, "Kids_and_Teens"),
    });

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualSlices(u64, &.{ 2, 4 }, try index.categoriesNamed(io, arena, "ART"));
    try testing.expectEqualSlices(u64, &.{5}, try index.categoriesNamed(io, arena, "pink floyd"));
    try testing.expectEqualSlices(u64, &.{6}, try index.categoriesNamed(io, arena, "Kids and Teens"));

    try index.writeCategory(io, allocator, testCategory(4, 1, "Art"));
    try index.writeCategory(io, allocator, testCategory(5, 2, "Pink_Floyd_Tribute"));
    try testing.expectEqualSlices(u64, &.{ 2, 4 }, try index.categoriesNamed(io, arena, "arts"));
    try testing.expectEqual(@as(usize, 0), (try index.categoriesNamed(io, arena, "pink floyd")).len);
    try testing.expectEqualSlices(u64, &.{5}, try index.categoriesNamed(io, arena, "pink floyd tribute"));

    try index.dropCategory(io, allocator, 2);
    try testing.expectEqualSlices(u64, &.{4}, try index.categoriesNamed(io, arena, "arts"));
}

test "subdomain_only keeps whole-host sites on a hosting platform and leaves out path sites" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try buildTree(&index, io, allocator, &.{ testCategory(1, 0, "Top"), testCategory(2, 1, "Arts") });
    try index.observe(io, allocator, inserted(testLink(10, 2, "http://samvak.tripod.com/")));
    try index.observe(io, allocator, inserted(testLink(11, 2, "http://samvak.tripod.com/poems.html")));
    try index.observe(io, allocator, inserted(testLink(12, 2, "http://members.tripod.com/~a/")));
    try index.observe(io, allocator, inserted(testLink(13, 2, "http://www.tripod.com/")));
    try index.observe(io, allocator, inserted(testLink(14, 2, "http://www.cs.example.edu/~ada/")));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const on_tripod = try index.query(io, allocator, arena, .{ .domain_suffix = "tripod.com", .subdomain_only = true, .page_limit = 5 });
    try testing.expectEqual(@as(u64, 2), on_tripod.total);
    try testing.expectEqual(@as(u64, 1), on_tripod.sites);

    const anywhere = try index.query(io, allocator, arena, .{ .subdomain_only = true, .page_limit = 5 });
    try testing.expectEqual(@as(u64, 2), anywhere.total);
}

test "a query counts links, distinct sites and hosts, groups by site, and pages after the cursor" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try buildTree(&index, io, allocator, &.{ testCategory(1, 0, "Top"), testCategory(2, 1, "Arts") });
    try index.observe(io, allocator, inserted(testLink(10, 2, "http://samvak.tripod.com/")));
    try index.observe(io, allocator, inserted(testLink(11, 2, "http://members.tripod.com/~a/")));
    try index.observe(io, allocator, inserted(testLink(12, 2, "http://members.tripod.com/~b/x.html")));
    try index.observe(io, allocator, inserted(testLink(13, 2, "http://members.tripod.com/~b/y.html")));
    try index.observe(io, allocator, inserted(testLink(14, 2, "http://nottripod.com/")));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first = try index.query(io, allocator, arena, .{ .domain_suffix = "tripod.com", .group_by = .site, .page_limit = 2 });
    try testing.expectEqual(@as(u64, 4), first.total);
    try testing.expectEqual(@as(u64, 3), first.sites);
    try testing.expectEqual(@as(u64, 2), first.hosts);
    try testing.expectEqualStrings("members.tripod.com/~b", first.groups[0].label);
    try testing.expectEqual(@as(u64, 2), first.groups[0].links);
    try testing.expectEqual(@as(u64, 1), first.groups[0].sites);
    try testing.expectEqual(@as(usize, 2), first.page.len);
    try testing.expectEqual(@as(u64, 11), first.next_after_id);

    const second = try index.query(io, allocator, arena, .{ .domain_suffix = "tripod.com", .page_limit = 2, .after_id = first.next_after_id });
    try testing.expectEqual(@as(u64, 12), second.page[0].link_id);
    try testing.expectEqual(@as(u64, 13), second.page[1].link_id);
    try testing.expectEqual(@as(u64, 0), second.next_after_id);
}

test "country ties follow the requested edges and a link can count for two countries" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try buildTree(&index, io, allocator, &.{
        testCategory(1, 0, "Top"), testCategory(2, 1, "Society"), testCategory(3, 2, "Pakistan"),
    });
    try index.observe(io, allocator, inserted(testLink(10, 2, "http://www.uet.edu.pk/")));
    try index.observe(io, allocator, inserted(testLink(11, 3, "http://www.storyofpakistan.com/")));
    try index.observe(io, allocator, inserted(testLink(12, 3, "http://www.bbc.co.uk/urdu/")));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(@as(u64, 1), (try index.query(io, allocator, arena, .{ .country = "PK".*, .via = Via.cctld })).total);
    try testing.expectEqual(@as(u64, 2), (try index.query(io, allocator, arena, .{ .country = "PK".*, .via = Via.category })).total);
    try testing.expectEqual(@as(u64, 3), (try index.query(io, allocator, arena, .{ .country = "PK".* })).total);

    const by_country = try index.query(io, allocator, arena, .{ .group_by = .country });
    try testing.expectEqual(@as(usize, 2), by_country.groups.len);
    try testing.expectEqualStrings("PK", by_country.groups[0].label);
    try testing.expectEqual(@as(u64, 3), by_country.groups[0].links);
    try testing.expectEqualStrings("GB", by_country.groups[1].label);
}

fn entityBlob(buf: []u8, religions: []const entities.Religion, codes: []const *const [2]u8, people: []const []const u8, orgs: []const []const u8) ![]const u8 {
    var mask: u16 = 0;
    for (religions) |religion| mask |= @as(u16, 1) << @intFromEnum(religion);

    var w: std.Io.Writer = .fixed(buf);
    try w.writeByte(1);
    try w.writeInt(u16, mask, .little);
    try w.writeByte(@intCast(codes.len));
    for (codes) |code| try w.writeAll(code);
    for ([_][]const []const u8{ people, orgs }) |names| {
        try w.writeByte(@intCast(names.len));
        for (names) |name| {
            try w.writeByte(@intCast(name.len));
            try w.writeAll(name);
        }
    }
    return buf[0..w.end];
}

fn putEntities(index: *FactsIndex, io: std.Io, allocator: std.mem.Allocator, link_id: u64, encoded: []const u8) !void {
    const entries = [_]changeset.LinkEntitiesEntry{.{ .link_id = link_id, .facts = encoded }};
    try index.observe(io, allocator, .{ .link_entities_put = .{ .entries = &entries } });
}

test "entity facts follow puts and deletes, a title edit drops them and a status change keeps them" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    const link = testLink(5, 10, "http://www.storyofpakistan.com/");
    try index.observe(io, allocator, inserted(link));
    var buf: [256]u8 = undefined;
    try putEntities(&index, io, allocator, 5, try entityBlob(&buf, &.{.islam}, &.{"PK"}, &.{}, &.{"Deoband"}));
    try testing.expectEqual(@as(u16, 1), index.entities.get(5).?.religions);

    var approved = link;
    approved.status = @intFromEnum(schema.LinkStatus.rejected);
    try index.observe(io, allocator, .{ .link_text_updated = .{ .old_link = link, .new_link = approved, .old_tokens = &.{}, .new_tokens = &.{} } });
    try testing.expect(index.entities.get(5) != null);

    var retitled = approved;
    retitled.title = @TypeOf(retitled.title).fromSlice("Another title");
    try index.observe(io, allocator, .{ .link_text_updated = .{ .old_link = approved, .new_link = retitled, .old_tokens = &.{}, .new_tokens = &.{} } });
    try testing.expect(index.entities.get(5) == null);

    try putEntities(&index, io, allocator, 5, try entityBlob(&buf, &.{.islam}, &.{}, &.{}, &.{}));
    try index.observe(io, allocator, .{ .link_deleted = .{ .link = retitled, .ancestor_updates = &.{}, .tokens = &.{} } });
    try testing.expect(index.entities.get(5) == null);
}

test "entities the apply path writes while loading win over the loader's older read" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    var fresh_buf: [256]u8 = undefined;
    var stale_buf: [256]u8 = undefined;
    index.beginLoad(io);
    try putEntities(&index, io, allocator, 1, try entityBlob(&fresh_buf, &.{.judaism}, &.{}, &.{}, &.{}));
    try index.loadEntities(io, allocator, 1, try entityBlob(&stale_buf, &.{.buddhism}, &.{}, &.{}, &.{}));
    try index.loadEntities(io, allocator, 2, try entityBlob(&stale_buf, &.{.buddhism}, &.{}, &.{}, &.{}));
    index.finishLoad(io, allocator);

    try testing.expectEqual(@as(u16, 1) << @intFromEnum(entities.Religion.judaism), index.entities.get(1).?.religions);
    try testing.expect(index.entities.get(2) != null);
}

test "a link naming one organisation in two letter-cases counts once under its first spelling" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try buildTree(&index, io, allocator, &.{ testCategory(1, 0, "Top"), testCategory(2, 1, "Arts") });
    try index.observe(io, allocator, inserted(testLink(10, 2, "http://www.etree.org/")));
    var buf: [256]u8 = undefined;
    try putEntities(&index, io, allocator, 10, try entityBlob(&buf, &.{}, &.{}, &.{}, &.{ "eTree", "etree" }));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const by_org = try index.query(io, allocator, arena_state.allocator(), .{ .group_by = .org });

    try testing.expectEqual(@as(usize, 1), by_org.groups.len);
    try testing.expectEqualStrings("eTree", by_org.groups[0].label);
    try testing.expectEqual(@as(u64, 1), by_org.groups[0].links);
}

test "queries filter by religion and by a name in any case, tie countries through the entity edge, and group by them" {
    const allocator = testing.allocator;
    const io = testing.io;
    var index: FactsIndex = .{};
    defer index.deinit(allocator);

    try buildTree(&index, io, allocator, &.{ testCategory(1, 0, "Top"), testCategory(2, 1, "Society") });
    try index.observe(io, allocator, inserted(testLink(10, 2, "http://www.storyofpakistan.com/")));
    try index.observe(io, allocator, inserted(testLink(11, 2, "http://www.farooqia.com/")));
    try index.observe(io, allocator, inserted(testLink(12, 2, "http://www.breslov.org/")));

    var buf: [3][256]u8 = undefined;
    try putEntities(&index, io, allocator, 10, try entityBlob(&buf[0], &.{.islam}, &.{"PK"}, &.{"Muhammad Ali Jinnah"}, &.{}));
    try putEntities(&index, io, allocator, 11, try entityBlob(&buf[1], &.{.islam}, &.{"PK"}, &.{}, &.{"Jamia Farooqia"}));
    try putEntities(&index, io, allocator, 12, try entityBlob(&buf[2], &.{.judaism}, &.{"UA"}, &.{"rebbe nachman"}, &.{}));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const islam: u16 = @as(u16, 1) << @intFromEnum(entities.Religion.islam);

    try testing.expectEqual(@as(u64, 2), (try index.query(io, allocator, arena, .{ .religions = islam })).total);
    try testing.expectEqual(@as(u64, 2), (try index.query(io, allocator, arena, .{ .country = "PK".* })).total);
    try testing.expectEqual(@as(u64, 0), (try index.query(io, allocator, arena, .{ .country = "PK".*, .via = Via.either })).total);
    try testing.expectEqual(@as(u64, 1), (try index.query(io, allocator, arena, .{ .entity_name = "JAMIA FAROOQIA" })).total);
    try testing.expectEqual(@as(u64, 0), (try index.query(io, allocator, arena, .{ .entity_name = "nobody" })).total);

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
