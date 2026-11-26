#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iterator>
#include <sstream>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace fs = std::filesystem;

namespace {

/* Keys and values are kept under their identity as Wine sees it (see
   key_identity and name_identity), with the text they were written in. */
struct Value {
    std::string name;
    std::string data;

    bool operator==(const Value &other) const { return name == other.name && data == other.data; }
};

struct Key {
    std::string path;
    std::map<std::string, Value> values;

    bool operator==(const Key &other) const { return path == other.path && values == other.values; }
};

using Keys = std::map<std::string, Key>;

struct Registry {
    std::string version;
    std::string location;
    std::string arch;
    Keys keys;
    /* A layer's hive can delete what the layers below it give: [-path]
       deletes that key's values (not its subkeys), "name"=- one value.
       Wine never writes these; they are applied when layers are merged. */
    std::map<std::string, std::string> deleted_keys;
};

const std::string deleted_value = "-";

/* Key flags stored as values; the leading \x01 keeps them apart from every
   real value name. */
const std::string link_flag = "\x01link";
const std::string class_flag = "\x01class";

bool starts_with(std::string_view value, std::string_view prefix)
{
    return value.size() >= prefix.size() && value.substr(0, prefix.size()) == prefix;
}

bool blank(std::string_view line)
{
    for (const char c : line) {
        if (c != ' ' && c != '\t' && c != '\r') return false;
    }
    return true;
}

void strip_cr(std::string &line)
{
    if (!line.empty() && line.back() == '\r') line.pop_back();
}

int hex_digit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Decodes UTF-8 text with Wine's registry escapes (parse_strW in
   server/registry.c) into UTF-16 code units. */
std::u16string unescape(std::string_view text)
{
    std::u16string result;
    auto push_code_point = [&](uint32_t cp) {
        if (cp >= 0x10000) {
            cp -= 0x10000;
            result += static_cast<char16_t>(0xd800 + (cp >> 10));
            result += static_cast<char16_t>(0xdc00 + (cp & 0x3ff));
        } else {
            result += static_cast<char16_t>(cp);
        }
    };

    for (size_t i = 0; i < text.size();) {
        const unsigned char c = static_cast<unsigned char>(text[i]);
        if (c == '\\' && i + 1 < text.size()) {
            const char e = text[i + 1];
            i += 2;
            switch (e) {
            case 'a': result += u'\a'; break;
            case 'b': result += u'\b'; break;
            case 'e': result += char16_t(27); break;
            case 'f': result += u'\f'; break;
            case 'n': result += u'\n'; break;
            case 'r': result += u'\r'; break;
            case 't': result += u'\t'; break;
            case 'v': result += u'\v'; break;
            case 'x': {
                uint32_t value = 0;
                int digits = 0;
                while (digits < 4 && i < text.size() && hex_digit(text[i]) >= 0) {
                    value = value * 16 + hex_digit(text[i]);
                    ++i;
                    ++digits;
                }
                if (digits == 0) result += u'x';
                else result += static_cast<char16_t>(value);
                break;
            }
            default:
                if (e >= '0' && e <= '7') {
                    uint32_t value = e - '0';
                    int digits = 1;
                    while (digits < 3 && i < text.size() && text[i] >= '0' && text[i] <= '7') {
                        value = value * 8 + (text[i] - '0');
                        ++i;
                        ++digits;
                    }
                    result += static_cast<char16_t>(value);
                } else {
                    push_code_point(static_cast<unsigned char>(e));
                }
            }
            continue;
        }

        /* UTF-8; a malformed sequence is taken byte by byte. */
        const int extra = c >= 0xf8 ? -1 : c >= 0xf0 ? 3 : c >= 0xe0 ? 2 : c >= 0xc0 ? 1 : c >= 0x80 ? -1 : 0;
        uint32_t cp = extra == 3 ? (c & 0x07) : extra == 2 ? (c & 0x0f) : extra == 1 ? (c & 0x1f) : c;
        bool valid = extra >= 0;
        for (int k = 1; valid && k <= extra; ++k) {
            if (i + k >= text.size() || (static_cast<unsigned char>(text[i + k]) & 0xc0) != 0x80) valid = false;
            else cp = (cp << 6) | (static_cast<unsigned char>(text[i + k]) & 0x3f);
        }
        if (!valid) {
            result += static_cast<char16_t>(c);
            ++i;
            continue;
        }
        push_code_point(cp);
        i += extra + 1;
    }
    return result;
}

/* Wine compares key and value names without regard to case. This folds
   ASCII, Latin-1, Latin Extended-A, Greek and Cyrillic capitals, which
   covers the names Windows programs use in practice. */
char16_t fold(char16_t c)
{
    if (c >= u'A' && c <= u'Z') return c + 32;
    if (c < 0x80) return c;
    if (c >= 0xc0 && c <= 0xde && c != 0xd7) return c + 32;
    if (c == 0x178) return 0xff;
    if (c >= 0x100 && c <= 0x17f && c != 0x130 && c != 0x131 && c != 0x138 && c != 0x149 && c != 0x17f) {
        /* Pairs: even capital, odd small, except 0x139-0x148 and 0x179-0x17e. */
        const bool odd_capitals = (c >= 0x139 && c <= 0x148) || (c >= 0x179 && c <= 0x17e);
        if (odd_capitals ? (c & 1) : !(c & 1)) return c + 1;
        return c;
    }
    if (c >= 0x391 && c <= 0x3ab && c != 0x3a2) return c + 32;
    if (c >= 0x410 && c <= 0x42f) return c + 32;
    if (c >= 0x400 && c <= 0x40f) return c + 80;
    return c;
}

std::string identity(const std::u16string &text)
{
    std::string result;
    result.reserve(text.size() * 2);
    for (const char16_t c : text) {
        const char16_t f = fold(c);
        result += static_cast<char>(f >> 8);
        result += static_cast<char>(f & 0xff);
    }
    return result;
}

/* The identity of a key path as written between [ and ]. */
std::string key_identity(std::string_view path)
{
    return identity(unescape(path));
}

/* The identity of a written value name: @ is the default value, the empty
   name. */
std::string name_identity(std::string_view name)
{
    if (name == "@") return {};
    if (name.size() >= 2 && name.front() == '"' && name.back() == '"') {
        return identity(unescape(name.substr(1, name.size() - 2)));
    }
    return identity(unescape(name));
}

/* The separator between a key and its subkeys in an identity. */
const std::string separator_identity = identity(u"\\");

/* Where the string starting with the quote at START ends (the index of the
   closing quote), or npos. */
size_t closing_quote(std::string_view text, size_t start)
{
    for (size_t i = start + 1; i < text.size(); ++i) {
        if (text[i] == '\\') {
            ++i;
            continue;
        }
        if (text[i] == '"') return i;
    }
    return std::string_view::npos;
}

/* A value's type and data, decoded from the forms Wine writes
   (dump_value in server/registry.c): "string" (REG_SZ), str(N):"string",
   dword:XXXXXXXX (REG_DWORD), hex:... (REG_BINARY) and hex(N):...; the
   same type and bytes in any of these forms are the same value. Text that
   is none of them is compared as it is, without line continuations. */
struct Data {
    bool decoded = false;
    uint32_t type = 0;
    std::vector<uint8_t> bytes;
    std::string text;

    bool operator==(const Data &other) const
    {
        if (decoded != other.decoded) return false;
        if (!decoded) return text == other.text;
        return type == other.type && bytes == other.bytes;
    }
};

/* Removes the line breaks Wine puts into long hex values ("\" at the end
   of a line, the next one indented). */
std::string join_lines(std::string_view value)
{
    std::string result;
    result.reserve(value.size());
    for (size_t i = 0; i < value.size(); ++i) {
        if (value[i] == '\\' && i + 1 < value.size() && value[i + 1] == '\n') {
            i += 2;
            while (i < value.size() && (value[i] == ' ' || value[i] == '\t')) ++i;
            --i;
            continue;
        }
        result += value[i];
    }
    return result;
}

std::optional<uint32_t> parse_hex_number(std::string_view text)
{
    if (text.empty() || text.size() > 8) return std::nullopt;
    uint32_t value = 0;
    for (const char c : text) {
        const int d = hex_digit(c);
        if (d < 0) return std::nullopt;
        value = value * 16 + d;
    }
    return value;
}

bool decode_string(std::string_view text, Data &data)
{
    if (text.empty() || text.front() != '"') return false;
    const size_t close = closing_quote(text, 0);
    if (close == std::string_view::npos || !blank(text.substr(close + 1))) return false;
    std::u16string chars = unescape(text.substr(1, close - 1));
    chars += u'\0';
    for (const char16_t c : chars) {
        data.bytes.push_back(static_cast<uint8_t>(c & 0xff));
        data.bytes.push_back(static_cast<uint8_t>(c >> 8));
    }
    return true;
}

bool decode_hex_bytes(std::string_view text, Data &data)
{
    int high = -1;
    for (const char c : text) {
        if (c == ',' || c == ' ' || c == '\t') {
            if (high >= 0) return false;
            continue;
        }
        const int d = hex_digit(c);
        if (d < 0) return false;
        if (high < 0) {
            high = d;
        } else {
            data.bytes.push_back(static_cast<uint8_t>(high * 16 + d));
            high = -1;
        }
    }
    return high < 0;
}

Data decode_data(std::string_view raw)
{
    Data data;
    data.text = join_lines(raw);
    const std::string_view text = data.text;

    bool ok = false;
    if (starts_with(text, "\"")) {
        data.type = 1;
        ok = decode_string(text, data);
    } else if (starts_with(text, "str(")) {
        const size_t close = text.find("):");
        if (close != std::string_view::npos) {
            const auto type = parse_hex_number(text.substr(4, close - 4));
            if (type) {
                data.type = *type;
                ok = decode_string(text.substr(close + 2), data);
            }
        }
    } else if (starts_with(text, "dword:")) {
        const auto value = parse_hex_number(text.substr(6));
        if (value) {
            data.type = 4;
            for (int i = 0; i < 4; ++i) data.bytes.push_back(static_cast<uint8_t>(*value >> (8 * i)));
            ok = true;
        }
    } else if (starts_with(text, "hex:")) {
        data.type = 3;
        ok = decode_hex_bytes(text.substr(4), data);
    } else if (starts_with(text, "hex(")) {
        const size_t close = text.find("):");
        if (close != std::string_view::npos) {
            const auto type = parse_hex_number(text.substr(4, close - 4));
            if (type) {
                data.type = *type;
                ok = decode_hex_bytes(text.substr(close + 2), data);
            }
        }
    }

    if (ok) {
        data.decoded = true;
    } else {
        data.type = 0;
        data.bytes.clear();
    }
    return data;
}

bool same_data(const std::string &a, const std::string &b)
{
    return a == b || decode_data(a) == decode_data(b);
}

Key &key_for(Registry &registry, const std::string &path)
{
    auto &key = registry.keys[key_identity(path)];
    if (key.path.empty()) key.path = path;
    return key;
}

std::optional<Registry> parse_registry(const fs::path &path, std::string &error)
{
    std::ifstream in(path);
    if (!in) {
        error = "failed to open";
        return std::nullopt;
    }

    Registry registry;
    Key *section = nullptr;
    std::string line;
    std::string pending_name;
    std::string pending_value;
    bool have_pending = false;

    auto store = [&](const std::string &name, const std::string &value) {
        const std::string id = name_identity(name);
        section->values[id] = Value{name, value};
    };

    size_t line_no = 0;
    while (std::getline(in, line)) {
        ++line_no;
        strip_cr(line);

        if (have_pending) {
            pending_value += "\n";
            pending_value += line;
            if (!line.empty() && line.back() == '\\') {
                continue;
            }
            store(pending_name, pending_value);
            have_pending = false;
            continue;
        }

        if (starts_with(line, "WINE REGISTRY Version ")) {
            registry.version = line.substr(std::string("WINE REGISTRY Version ").size());
            continue;
        }

        if (starts_with(line, ";; All keys relative to ")) {
            registry.location = line.substr(std::string(";; All keys relative to ").size());
            continue;
        }

        if (starts_with(line, "#arch=")) {
            registry.arch = line.substr(std::string("#arch=").size());
            continue;
        }

        if (line.empty() || blank(line)) {
            continue;
        }

        if (line == "#link" && section) {
            section->values[link_flag] = Value{"#link", "1"};
            continue;
        }

        if (starts_with(line, "#class=") && section) {
            section->values[class_flag] = Value{"#class", line.substr(std::string("#class=").size())};
            continue;
        }

        if (starts_with(line, "#")) {
            continue;
        }

        if (line.front() == '[') {
            /* The key path ends at the first ] that is not escaped; a
               modification time may follow. */
            size_t close = std::string::npos;
            for (size_t i = 1; i < line.size(); ++i) {
                if (line[i] == '\\') {
                    ++i;
                    continue;
                }
                if (line[i] == ']') {
                    close = i;
                    break;
                }
            }
            if (close == std::string::npos) {
                error = "malformed section header at line " + std::to_string(line_no);
                return std::nullopt;
            }
            if (line[1] == '-') {
                registry.deleted_keys[key_identity(line.substr(2, close - 2))] = line.substr(2, close - 2);
                section = nullptr;
                continue;
            }
            section = &key_for(registry, line.substr(1, close - 1));
            continue;
        }

        size_t equals = std::string::npos;
        if (line.front() == '"') {
            const size_t close = closing_quote(line, 0);
            if (close != std::string::npos && close + 1 < line.size() && line[close + 1] == '=') equals = close + 1;
        } else if (line.front() == '@' && line.size() > 1 && line[1] == '=') {
            equals = 1;
        } else {
            equals = line.find('=');
        }
        if (equals == std::string::npos || !section) {
            error = "malformed value at line " + std::to_string(line_no);
            return std::nullopt;
        }

        pending_name = line.substr(0, equals);
        pending_value = line.substr(equals + 1);
        if (!pending_value.empty() && pending_value.back() == '\\') {
            have_pending = true;
        } else {
            store(pending_name, pending_value);
        }
    }

    if (have_pending) store(pending_name, pending_value);

    if (registry.version.empty()) registry.version = "2";
    if (registry.arch.empty()) registry.arch = "win64";
    if (registry.location.empty()) {
        error = "missing registry location header";
        return std::nullopt;
    }

    return registry;
}

bool write_registry(const fs::path &path, const Registry &registry)
{
    std::ofstream out(path, std::ios::trunc);
    if (!out) return false;

    out << "WINE REGISTRY Version " << registry.version << '\n';
    out << ";; All keys relative to " << registry.location << "\n\n";
    out << "#arch=" << registry.arch << "\n\n";

    bool first_section = true;
    for (const auto &[id, key] : registry.keys) {
        if (!first_section) out << '\n';
        first_section = false;

        out << '[' << key.path << "]\n";
        const auto key_class = key.values.find(class_flag);
        if (key_class != key.values.end()) out << "#class=" << key_class->second.data << '\n';
        if (key.values.count(link_flag)) out << "#link\n";
        for (const auto &[name_id, value] : key.values) {
            if (name_id == link_flag || name_id == class_flag) continue;
            out << value.name << '=' << value.data << '\n';
        }
    }

    out.flush();
    out.close();
    return !out.fail();
}

bool same_registry(const Registry &a, const Registry &b)
{
    return a.version == b.version && a.location == b.location && a.arch == b.arch && a.keys == b.keys;
}

/* Reads the hive at PATH into RESULT, which stays empty when there is no
   such file. A hive that exists but cannot be read or parsed is an error. */
bool load_hive(const fs::path &path, std::optional<Registry> &result)
{
    std::error_code ec;
    if (!fs::exists(path, ec)) {
        if (ec) {
            std::cerr << "error: cannot inspect registry " << path << ": " << ec.message() << '\n';
            return false;
        }
        return true;
    }
    if (!fs::is_regular_file(path, ec)) {
        std::cerr << "error: registry " << path << " is not a regular file\n";
        return false;
    }

    std::string error;
    result = parse_registry(path, error);
    if (!result) {
        std::cerr << "error: failed to parse registry " << path << ": " << error << '\n';
        return false;
    }
    return true;
}

void apply_layer(Registry &result, const Registry &layer);

/* Merges the hive REG_NAME of the sources (lowest priority first). A source
   hive that exists but cannot be read or parsed fails the merge: skipping
   it would drop its values, and when it is the writable layer's own hive,
   the user's values would be replaced by the layers below. */
bool merge_one(const std::string &reg_name, const std::vector<fs::path> &source_dirs,
               std::optional<Registry> &result)
{
    for (const auto &source_dir : source_dirs) {
        std::optional<Registry> parsed;
        if (!load_hive(source_dir / reg_name, parsed)) return false;
        if (!parsed) continue;

        if (!result) result = Registry{};
        apply_layer(*result, *parsed);
    }
    return true;
}

/* Puts the layer hive LAYER on top of RESULT: its header, its deletions,
   then its keys and values. A key that only deletes values is not created. */
void apply_layer(Registry &result, const Registry &layer)
{
    result.version = layer.version;
    result.location = layer.location;
    result.arch = layer.arch;
    for (const auto &entry : layer.deleted_keys) result.keys.erase(entry.first);
    for (const auto &[id, key] : layer.keys) {
        bool only_deletions = !key.values.empty();
        for (const auto &value : key.values) {
            if (value.second.data != deleted_value) only_deletions = false;
        }
        auto existing = result.keys.find(id);
        if (existing == result.keys.end()) {
            if (only_deletions) continue;
            existing = result.keys.emplace(id, Key{}).first;
        }
        existing->second.path = key.path;
        for (const auto &[name_id, value] : key.values) {
            if (value.data == deleted_value) existing->second.values.erase(name_id);
            else existing->second.values[name_id] = value;
        }
    }
}

/* Whether a hive has deletions, which only layers may have. */
bool has_deletions(const Registry &registry)
{
    if (!registry.deleted_keys.empty()) return true;
    for (const auto &key : registry.keys) {
        for (const auto &value : key.second.values) {
            if (value.second.data == deleted_value) return true;
        }
    }
    return false;
}

/* Whether the key ID exists in KEYS: written out, or implied by a subkey
   (Wine does not write keys that have subkeys but no values). */
bool has_key(const Keys &keys, const std::string &id)
{
    if (keys.count(id)) return true;
    const std::string prefix = id + separator_identity;
    const auto next = keys.lower_bound(prefix);
    return next != keys.end() && starts_with(next->first, prefix);
}

/* Three-way merge of one hive: LAYERS is what the Nix layers give now,
   BASE what they gave at the last successful merge, WRITABLE the writable
   layer's hive. Keys and value names are matched as Wine matches them
   (without regard to case, @ for the empty name), and values compared by
   type and data (decode_data). Per value:
   - WRITABLE has it as BASE had it: the user did not change it, so the
     layers decide (their value, or none);
   - WRITABLE has it, but BASE did not, or differently: the user's;
   - WRITABLE lacks it, but BASE had it: the user deleted it;
   - neither has it: the layers decide.
   Keys without values follow the same rules for their existence. The
   result keeps the winning side's text. Without a BASE this is the
   two-way merge with the writable hive on top. */
std::optional<Registry> merge_three_way(const std::optional<Registry> &layers,
                                        const std::optional<Registry> &base,
                                        const std::optional<Registry> &writable)
{
    if (!layers && !writable) return std::nullopt;

    static const Keys no_keys;
    const Keys &l = layers ? layers->keys : no_keys;
    const Keys &b = base ? base->keys : no_keys;
    const Keys &w = writable ? writable->keys : no_keys;

    Registry result;
    const Registry &header = writable ? *writable : *layers;
    result.version = header.version;
    result.location = header.location;
    result.arch = header.arch;

    std::map<std::string, bool> ids;
    for (const Keys *keys : {&l, &b, &w}) {
        for (const auto &entry : *keys) ids[entry.first] = true;
    }

    static const Key no_key;
    auto key_of = [](const Keys &keys, const std::string &id) -> const Key & {
        const auto found = keys.find(id);
        return found == keys.end() ? no_key : found->second;
    };

    for (const auto &entry : ids) {
        const std::string &id = entry.first;
        const Key &lk = key_of(l, id);
        const Key &bk = key_of(b, id);
        const Key &wk = key_of(w, id);

        std::map<std::string, bool> names;
        for (const Key *key : {&lk, &bk, &wk}) {
            for (const auto &value : key->values) names[value.first] = true;
        }

        Key merged;
        for (const auto &name : names) {
            const auto in_l = lk.values.find(name.first);
            const auto in_b = bk.values.find(name.first);
            const auto in_w = wk.values.find(name.first);
            const bool user_unchanged = in_w != wk.values.end() && in_b != bk.values.end()
                && same_data(in_w->second.data, in_b->second.data);

            if (in_w != wk.values.end() && !user_unchanged) {
                merged.values[name.first] = in_w->second;
            } else if (in_w == wk.values.end() && in_b != bk.values.end()) {
                /* deleted by the user */
            } else if (in_l != lk.values.end()) {
                merged.values[name.first] = in_l->second;
            }
        }

        bool keep_key = !merged.values.empty();
        if (!keep_key) {
            const bool in_w = has_key(w, id);
            const bool in_b = has_key(b, id);
            if (in_w && !in_b) keep_key = true;
            else if (!in_w && in_b) keep_key = false;
            else keep_key = has_key(l, id);
        }
        if (keep_key) {
            merged.path = !wk.path.empty() ? wk.path : !lk.path.empty() ? lk.path : bk.path;
            result.keys[id] = std::move(merged);
        }
    }

    return result;
}

/* Writes REGISTRY to a hidden file next to TARGET, reads it back and
   compares; returns the staged path, or an empty one on failure. */
fs::path stage_registry(const fs::path &target, const Registry &registry)
{
    const fs::path staged = target.parent_path() / ("." + target.filename().string() + ".nix-overlayfs-new");
    std::string error;
    std::optional<Registry> written;
    if (write_registry(staged, registry)) written = parse_registry(staged, error);
    if (!written || !same_registry(*written, registry)) {
        std::cerr << "error: failed to write " << target << '\n';
        std::error_code ec;
        fs::remove(staged, ec);
        return {};
    }
    return staged;
}

bool make_directory(const fs::path &dir)
{
    std::error_code ec;
    fs::create_directories(dir, ec);
    if (ec) {
        std::cerr << "error: cannot create " << dir << ": " << ec.message() << '\n';
        return false;
    }
    return true;
}

const std::vector<std::string> reg_names = {"system.reg", "user.reg", "userdef.reg"};

int merge_two_way(const fs::path &out_dir, const std::vector<fs::path> &source_dirs)
{
    /* Everything is read and merged before anything is written. */
    std::vector<std::optional<Registry>> merged(reg_names.size());
    for (size_t i = 0; i < reg_names.size(); ++i) {
        if (!merge_one(reg_names[i], source_dirs, merged[i])) return 1;
    }

    /* Each hive is written next to its original, read back and compared,
       and only then renamed over it. */
    if (!make_directory(out_dir)) return 1;
    std::vector<fs::path> staged(reg_names.size());
    std::error_code ec;
    auto discard_staged = [&]() {
        for (const auto &path : staged) {
            if (!path.empty()) fs::remove(path, ec);
        }
    };
    for (size_t i = 0; i < reg_names.size(); ++i) {
        if (!merged[i]) continue;
        staged[i] = stage_registry(out_dir / reg_names[i], *merged[i]);
        if (staged[i].empty()) {
            discard_staged();
            return 1;
        }
    }
    for (size_t i = 0; i < reg_names.size(); ++i) {
        if (staged[i].empty()) continue;
        fs::rename(staged[i], out_dir / reg_names[i], ec);
        if (ec) {
            std::cerr << "error: failed to replace " << out_dir / reg_names[i] << ": " << ec.message() << '\n';
            discard_staged();
            return 1;
        }
        staged[i].clear();
    }

    return 0;
}

/* Test hook: NIX_OVERLAYFS_REGISTRY_TEST_INTERRUPT=N ends the program at
   the Nth step of a commit, as if the launcher had been killed there. */
void checkpoint()
{
    static int step = 0;
    static const char *interrupt = std::getenv("NIX_OVERLAYFS_REGISTRY_TEST_INTERRUPT");
    ++step;
    if (interrupt && std::atoi(interrupt) == step) {
        std::cerr << "nix-overlayfs: test: interrupting the registry merge at step " << step << '\n';
        std::_Exit(75);
    }
}

/* FNV-1a over a file's bytes, with its size: enough to notice a base
   record that was truncated or changed. */
std::optional<std::string> fingerprint(const fs::path &path)
{
    std::ifstream in(path, std::ios::binary);
    if (!in) return std::nullopt;
    uint64_t hash = 0xcbf29ce484222325ull;
    uint64_t size = 0;
    char buffer[65536];
    while (in.read(buffer, sizeof(buffer)) || in.gcount() > 0) {
        for (std::streamsize i = 0; i < in.gcount(); ++i) {
            hash ^= static_cast<unsigned char>(buffer[i]);
            hash *= 0x100000001b3ull;
        }
        size += static_cast<uint64_t>(in.gcount());
    }
    if (in.bad()) return std::nullopt;
    char text[64];
    std::snprintf(text, sizeof(text), "%llu %016llx", static_cast<unsigned long long>(size),
                  static_cast<unsigned long long>(hash));
    return std::string(text);
}

std::optional<std::string> read_file(const fs::path &path)
{
    std::ifstream in(path, std::ios::binary);
    if (!in) return std::nullopt;
    std::string content((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (in.bad()) return std::nullopt;
    return content;
}

/* Writes CONTENT to PATH through a temporary file next to it. */
bool replace_file(const fs::path &path, const std::string &content)
{
    const fs::path tmp = path.parent_path() / ("." + path.filename().string() + ".nix-overlayfs-tmp");
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        out << content;
        out.flush();
        if (!out) {
            std::cerr << "error: failed to write " << tmp << '\n';
            std::error_code ec;
            fs::remove(tmp, ec);
            return false;
        }
    }
    std::error_code ec;
    fs::rename(tmp, path, ec);
    if (ec) {
        std::cerr << "error: failed to replace " << path << ": " << ec.message() << '\n';
        fs::remove(tmp, ec);
        return false;
    }
    return true;
}

/* Where a merge with a base record keeps its state. BASE holds the base
   record: the layers' hives and a manifest naming each hive's size and
   hash (or that the layers had none) and the Nix layers it was made for.
   BASE.new is the next base record while it is being written and
   BASE.old the previous one while it is being replaced; BASE.journal
   exists from the moment everything is staged until the commit is done. */
struct State {
    fs::path writable;
    fs::path base;
    fs::path base_new;
    fs::path base_old;
    fs::path journal;
    fs::path signature;
    fs::path signature_next;
    /* The launcher's integration layer, one of the layers, or empty. */
    fs::path launcher_layer;
};

const std::string manifest_header = "nix-overlayfs registry base 1";

fs::path staged_path(const fs::path &dir, const std::string &reg_name)
{
    return dir / ("." + reg_name + ".nix-overlayfs-new");
}

/* Finishes a commit that was interrupted after its journal was written
   (everything it needs is staged and verified), or drops what an
   interrupted merge staged before that. */
bool recover(const State &state)
{
    std::error_code ec;
    if (fs::exists(state.journal, ec)) {
        const auto journal = read_file(state.journal);
        if (!journal) {
            std::cerr << "error: cannot read " << state.journal << '\n';
            return false;
        }
        std::istringstream lines(*journal);
        std::string word;
        std::string reg_name;
        while (lines >> word >> reg_name) {
            if (word != "hive") continue;
            const fs::path staged = staged_path(state.writable, reg_name);
            if (fs::exists(staged, ec)) {
                fs::rename(staged, state.writable / reg_name, ec);
                if (ec) {
                    std::cerr << "error: failed to replace " << state.writable / reg_name << ": " << ec.message() << '\n';
                    return false;
                }
            }
        }
        if (fs::exists(state.base_new, ec)) {
            if (fs::exists(state.base, ec)) {
                fs::remove_all(state.base_old, ec);
                fs::rename(state.base, state.base_old, ec);
                if (ec) {
                    std::cerr << "error: failed to move " << state.base << " aside: " << ec.message() << '\n';
                    return false;
                }
            }
            fs::rename(state.base_new, state.base, ec);
            if (ec) {
                std::cerr << "error: failed to replace " << state.base << ": " << ec.message() << '\n';
                return false;
            }
        }
        fs::remove_all(state.base_old, ec);
        fs::remove(state.journal, ec);
        if (ec) {
            std::cerr << "error: failed to remove " << state.journal << ": " << ec.message() << '\n';
            return false;
        }
        std::cerr << "nix-overlayfs: completed an interrupted registry merge of " << state.writable << '\n';
        return true;
    }

    for (const auto &reg_name : reg_names) fs::remove(staged_path(state.writable, reg_name), ec);
    fs::remove_all(state.base_new, ec);
    if (fs::exists(state.base_old, ec)) {
        if (fs::exists(state.base, ec)) fs::remove_all(state.base_old, ec);
        else fs::rename(state.base_old, state.base, ec);
    }
    return true;
}

/* Reads the base record into BASES. No record at all is fine (a writable
   layer from before base records: the writable hives win). A record that
   does not match its manifest is an error. */
bool load_base(const State &state, std::vector<std::optional<Registry>> &bases)
{
    std::error_code ec;
    if (!fs::exists(state.base, ec)) return true;

    auto damaged = [&](const std::string &why) {
        std::cerr << "error: the registry base record " << state.base << " is damaged (" << why
                  << "); remove it to merge with the writable values on top\n";
        return false;
    };

    if (!fs::is_directory(state.base, ec)) return damaged("not a directory");
    const auto manifest = read_file(state.base / "manifest");
    if (!manifest) return damaged("no manifest");

    std::istringstream lines(*manifest);
    std::string line;
    if (!std::getline(lines, line) || line != manifest_header) return damaged("unknown manifest");
    std::map<std::string, std::string> fingerprints;
    std::string sources;
    while (std::getline(lines, line)) {
        if (starts_with(line, "hive ")) {
            const auto space = line.find(' ', 5);
            if (space == std::string::npos) return damaged("malformed manifest");
            fingerprints[line.substr(5, space - 5)] = line.substr(space + 1);
        } else if (starts_with(line, "source ")) {
            sources += line.substr(7) + "\n";
        } else {
            return damaged("malformed manifest");
        }
    }

    for (size_t i = 0; i < reg_names.size(); ++i) {
        const auto found = fingerprints.find(reg_names[i]);
        if (found == fingerprints.end()) return damaged("the manifest does not name " + reg_names[i]);
        const fs::path path = state.base / reg_names[i];
        if (found->second == "absent") {
            if (fs::exists(path, ec)) return damaged(reg_names[i] + " should not exist");
            continue;
        }
        const auto actual = fingerprint(path);
        if (!actual) return damaged(reg_names[i] + " is missing");
        if (*actual != found->second) return damaged(reg_names[i] + " does not match the manifest");
        std::string error;
        bases[i] = parse_registry(path, error);
        if (!bases[i]) return damaged(reg_names[i] + ": " + error);
    }

    /* A launcher without base records merges without updating them; the
       base is then older than the writable hives. It is still used: those
       merges only add the layers' values on top, so nothing is taken for
       deleted, and values it shares with the layers follow them. */
    const auto recorded = read_file(state.signature);
    if (recorded && *recorded != sources) {
        std::cerr << "warning: the registry base record " << state.base
                  << " was made for other Nix layers than the last merge; using it\n";
    }
    return true;
}

/* The writable layer gets each hive merged three-way from the Nix layers
   LAYER_DIRS (lowest priority first), the base record and its own hive;
   the base record then gets what the layers gave, and SIGNATURE the
   content of SIGNATURE_NEXT. Everything is read, merged, staged and
   verified first; the journal then marks the commit, which a later run
   completes if it is interrupted. SIGNATURE is removed before the commit
   and written after it, so an interrupted merge is run again. */
int merge_with_base(const State &state, const std::vector<fs::path> &layer_dirs)
{
    if (!recover(state)) return 1;

    std::vector<std::optional<Registry>> bases(reg_names.size());
    if (!load_base(state, bases)) return 1;

    const auto signature_next = read_file(state.signature_next);
    if (!signature_next) {
        std::cerr << "error: cannot read " << state.signature_next << '\n';
        return 1;
    }

    std::vector<std::optional<Registry>> layers(reg_names.size());
    std::vector<std::optional<Registry>> merged(reg_names.size());
    for (size_t i = 0; i < reg_names.size(); ++i) {
        std::optional<Registry> writable;
        if (!merge_one(reg_names[i], layer_dirs, layers[i])) return 1;
        if (!load_hive(state.writable / reg_names[i], writable)) return 1;
        if (writable && has_deletions(*writable)) {
            std::cerr << "error: the writable hive " << state.writable / reg_names[i]
                      << " has deletions ([-key] or \"name\"=-), which only layers may have\n";
            return 1;
        }

        /* Earlier launchers wrote the integration layer's keys into the
           writable hive at every launch. Without a base record they would
           win and stay; taking the values it has as unchanged gives them to
           the layers. */
        if (writable && !bases[i] && !state.launcher_layer.empty()) {
            std::optional<Registry> launcher;
            if (!load_hive(state.launcher_layer / reg_names[i], launcher)) return 1;
            if (launcher) {
                Registry assumed;
                assumed.version = writable->version;
                assumed.location = writable->location;
                assumed.arch = writable->arch;
                for (const auto &[id, key] : launcher->keys) {
                    const auto found = writable->keys.find(id);
                    if (found == writable->keys.end()) continue;
                    Key &assumed_key = assumed.keys[id];
                    assumed_key.path = found->second.path;
                    for (const auto &value : key.values) {
                        const auto written = found->second.values.find(value.first);
                        if (written != found->second.values.end()) assumed_key.values.insert(*written);
                    }
                }
                bases[i] = std::move(assumed);
            }
        }

        /* Without a writable hive there is nothing of the user's to keep,
           and the base would only delete the layers' values. */
        merged[i] = merge_three_way(layers[i], writable ? bases[i] : std::nullopt, writable);
    }

    if (!make_directory(state.writable) || !make_directory(state.base.parent_path())) return 1;
    std::error_code ec;
    std::vector<fs::path> staged(reg_names.size());
    auto discard_staged = [&]() {
        for (const auto &path : staged) {
            if (!path.empty()) fs::remove(path, ec);
        }
        fs::remove_all(state.base_new, ec);
    };

    for (size_t i = 0; i < reg_names.size(); ++i) {
        if (!merged[i]) continue;
        staged[i] = stage_registry(state.writable / reg_names[i], *merged[i]);
        if (staged[i].empty()) {
            discard_staged();
            return 1;
        }
    }

    fs::remove_all(state.base_new, ec);
    if (!make_directory(state.base_new)) {
        discard_staged();
        return 1;
    }
    std::string manifest = manifest_header + "\n";
    for (size_t i = 0; i < reg_names.size(); ++i) {
        if (!layers[i]) {
            manifest += "hive " + reg_names[i] + " absent\n";
            continue;
        }
        const fs::path path = state.base_new / reg_names[i];
        const fs::path written = stage_registry(path, *layers[i]);
        if (written.empty()) {
            discard_staged();
            return 1;
        }
        fs::rename(written, path, ec);
        const auto print = ec ? std::nullopt : fingerprint(path);
        if (!print) {
            std::cerr << "error: failed to write " << path << '\n';
            discard_staged();
            return 1;
        }
        manifest += "hive " + reg_names[i] + " " + *print + "\n";
    }
    std::istringstream sources(*signature_next);
    std::string source;
    while (std::getline(sources, source)) manifest += "source " + source + "\n";
    if (!replace_file(state.base_new / "manifest", manifest)) {
        discard_staged();
        return 1;
    }

    /* The commit. */
    checkpoint();
    fs::remove(state.signature, ec);
    if (ec) {
        std::cerr << "error: failed to remove " << state.signature << ": " << ec.message() << '\n';
        discard_staged();
        return 1;
    }
    checkpoint();
    std::string journal;
    for (size_t i = 0; i < reg_names.size(); ++i) {
        if (!staged[i].empty()) journal += "hive " + reg_names[i] + "\n";
    }
    if (!replace_file(state.journal, journal)) {
        discard_staged();
        return 1;
    }
    checkpoint();
    for (size_t i = 0; i < reg_names.size(); ++i) {
        if (staged[i].empty()) continue;
        fs::rename(staged[i], state.writable / reg_names[i], ec);
        if (ec) {
            std::cerr << "error: failed to replace " << state.writable / reg_names[i] << ": " << ec.message() << '\n';
            return 1;
        }
        checkpoint();
    }
    if (fs::exists(state.base, ec)) {
        fs::remove_all(state.base_old, ec);
        fs::rename(state.base, state.base_old, ec);
        if (ec) {
            std::cerr << "error: failed to move " << state.base << " aside: " << ec.message() << '\n';
            return 1;
        }
    }
    checkpoint();
    fs::rename(state.base_new, state.base, ec);
    if (ec) {
        std::cerr << "error: failed to replace " << state.base << ": " << ec.message() << '\n';
        return 1;
    }
    checkpoint();
    fs::remove_all(state.base_old, ec);
    checkpoint();
    fs::remove(state.journal, ec);
    if (ec) {
        std::cerr << "error: failed to remove " << state.journal << ": " << ec.message() << '\n';
        return 1;
    }
    checkpoint();

    return replace_file(state.signature, *signature_next) ? 0 : 1;
}

} // namespace

int main(int argc, char **argv)
{
    const std::string usage =
        "usage: merge-wine-registries OUT_DIR SOURCE_DIR...\n"
        "       merge-wine-registries --base BASE_DIR --signature SIGNATURE --signature-next SIGNATURE_NEXT\n"
        "                             [--launcher-layer DIR] WRITABLE_DIR [LAYER_DIR...]\n";

    if (argc >= 2 && std::string_view(argv[1]) == "--base") {
        if (argc < 8 || std::string_view(argv[3]) != "--signature" || std::string_view(argv[5]) != "--signature-next") {
            std::cerr << usage;
            return 2;
        }
        State state;
        state.base = argv[2];
        state.signature = argv[4];
        state.signature_next = argv[6];
        int next = 7;
        if (std::string_view(argv[next]) == "--launcher-layer") {
            if (argc < 10) {
                std::cerr << usage;
                return 2;
            }
            state.launcher_layer = argv[next + 1];
            next += 2;
        }
        state.writable = argv[next];
        state.base_new = state.base.string() + ".new";
        state.base_old = state.base.string() + ".old";
        state.journal = state.base.string() + ".journal";
        std::vector<fs::path> layer_dirs(argv + next + 1, argv + argc);
        return merge_with_base(state, layer_dirs);
    }

    if (argc < 3) {
        std::cerr << usage;
        return 2;
    }
    std::vector<fs::path> source_dirs(argv + 2, argv + argc);
    return merge_two_way(argv[1], source_dirs);
}
