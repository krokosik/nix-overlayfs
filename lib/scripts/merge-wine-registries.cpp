#include <cstdint>
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
};

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

        if (!result) {
            result = std::move(parsed);
            continue;
        }

        result->version = parsed->version;
        result->location = parsed->location;
        result->arch = parsed->arch;
        for (auto &[id, key] : parsed->keys) {
            auto &merged = result->keys[id];
            merged.path = key.path;
            for (auto &[name_id, value] : key.values) {
                merged.values[name_id] = value;
            }
        }
    }
    return true;
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

/* The writable layer WRITABLE_DIR gets each hive merged three-way from
   the Nix layers LAYER_DIRS (lowest priority first), the base record in
   BASE_DIR and its own hive; BASE_DIR then gets what the layers gave. */
int merge_with_base(const fs::path &base_dir, const fs::path &writable_dir,
                    const std::vector<fs::path> &layer_dirs)
{
    std::vector<std::optional<Registry>> layers(reg_names.size());
    std::vector<std::optional<Registry>> merged(reg_names.size());
    for (size_t i = 0; i < reg_names.size(); ++i) {
        std::optional<Registry> writable;
        if (!merge_one(reg_names[i], layer_dirs, layers[i])) return 1;
        if (!load_hive(writable_dir / reg_names[i], writable)) return 1;

        /* A base hive that cannot be used is dropped: the writable hive
           then wins, as without a base record, and the base is recorded
           anew. Without a writable hive there is nothing of the user's to
           keep, and the base would only delete the layers' values. */
        std::optional<Registry> base;
        if (writable && !load_hive(base_dir / reg_names[i], base)) {
            std::cerr << "warning: ignoring the registry base record " << base_dir / reg_names[i] << '\n';
            base.reset();
        }

        merged[i] = merge_three_way(layers[i], base, writable);
    }

    if (!make_directory(writable_dir) || !make_directory(base_dir)) return 1;
    std::vector<fs::path> staged(reg_names.size());
    std::vector<fs::path> staged_base(reg_names.size());
    std::error_code ec;
    auto discard_staged = [&]() {
        for (const auto *paths : {&staged, &staged_base}) {
            for (const auto &path : *paths) {
                if (!path.empty()) fs::remove(path, ec);
            }
        }
    };
    for (size_t i = 0; i < reg_names.size(); ++i) {
        if (merged[i]) {
            staged[i] = stage_registry(writable_dir / reg_names[i], *merged[i]);
            if (staged[i].empty()) {
                discard_staged();
                return 1;
            }
        }
        if (layers[i]) {
            staged_base[i] = stage_registry(base_dir / reg_names[i], *layers[i]);
            if (staged_base[i].empty()) {
                discard_staged();
                return 1;
            }
        }
    }

    /* Per hive: the old base goes first, then the hive is replaced, then
       the new base is put in place. Stopping anywhere leaves a hive with
       the base it was merged with, or with none (the writable hive wins). */
    for (size_t i = 0; i < reg_names.size(); ++i) {
        const auto base_path = base_dir / reg_names[i];
        fs::remove(base_path, ec);
        if (ec) {
            std::cerr << "error: failed to remove " << base_path << ": " << ec.message() << '\n';
            discard_staged();
            return 1;
        }
        if (!staged[i].empty()) {
            fs::rename(staged[i], writable_dir / reg_names[i], ec);
            if (ec) {
                std::cerr << "error: failed to replace " << writable_dir / reg_names[i] << ": " << ec.message() << '\n';
                discard_staged();
                return 1;
            }
            staged[i].clear();
        }
        if (!staged_base[i].empty()) {
            fs::rename(staged_base[i], base_path, ec);
            if (ec) {
                std::cerr << "error: failed to replace " << base_path << ": " << ec.message() << '\n';
                discard_staged();
                return 1;
            }
            staged_base[i].clear();
        }
    }

    return 0;
}

} // namespace

int main(int argc, char **argv)
{
    const std::string usage =
        "usage: merge-wine-registries OUT_DIR SOURCE_DIR...\n"
        "       merge-wine-registries --base BASE_DIR WRITABLE_DIR [LAYER_DIR...]\n";

    if (argc >= 2 && std::string_view(argv[1]) == "--base") {
        if (argc < 4) {
            std::cerr << usage;
            return 2;
        }
        std::vector<fs::path> layer_dirs(argv + 4, argv + argc);
        return merge_with_base(argv[2], argv[3], layer_dirs);
    }

    if (argc < 3) {
        std::cerr << usage;
        return 2;
    }
    std::vector<fs::path> source_dirs(argv + 2, argv + argc);
    return merge_two_way(argv[1], source_dirs);
}
