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

struct Registry {
    std::string version;
    std::string location;
    std::string arch;
    std::map<std::string, std::map<std::string, std::string>> keys;
};

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

std::optional<Registry> parse_registry(const fs::path &path, std::string &error)
{
    std::ifstream in(path);
    if (!in) {
        error = "failed to open";
        return std::nullopt;
    }

    Registry registry;
    std::string section;
    std::string line;
    std::string pending_name;
    std::string pending_value;
    bool have_pending = false;

    auto flush_pending = [&]() {
        if (have_pending) {
            registry.keys[section][pending_name] = pending_value;
            pending_name.clear();
            pending_value.clear();
            have_pending = false;
        }
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
            flush_pending();
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

        if (line == "#link" && !section.empty()) {
            registry.keys[section]["__wine_link"] = "1";
            continue;
        }

        if (starts_with(line, "#class=") && !section.empty()) {
            registry.keys[section]["__wine_class"] = line.substr(std::string("#class=").size());
            continue;
        }

        if (starts_with(line, "#")) {
            continue;
        }

        if (line.front() == '[') {
            const auto close = line.find(']');
            if (close == std::string::npos) {
                error = "malformed section header at line " + std::to_string(line_no);
                return std::nullopt;
            }
            section = line.substr(1, close - 1);
            registry.keys.try_emplace(section);
            continue;
        }

        const auto equals = line.find('=');
        if (equals == std::string::npos || section.empty()) {
            error = "malformed value at line " + std::to_string(line_no);
            return std::nullopt;
        }

        pending_name = line.substr(0, equals);
        pending_value = line.substr(equals + 1);
        if (!pending_value.empty() && pending_value.back() == '\\') {
            have_pending = true;
        } else {
            registry.keys[section][pending_name] = pending_value;
        }
    }

    flush_pending();

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
    for (const auto &[section, values] : registry.keys) {
        if (!first_section) out << '\n';
        first_section = false;

        out << '[' << section << "]\n";
        const auto key_class = values.find("__wine_class");
        if (key_class != values.end()) out << "#class=" << key_class->second << '\n';
        if (values.count("__wine_link")) out << "#link\n";
        for (const auto &[name, value] : values) {
            if (name == "__wine_link" || name == "__wine_class") continue;
            out << name << '=' << value << '\n';
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
        for (auto &[section, values] : parsed->keys) {
            auto &merged_values = result->keys[section];
            for (auto &[name, value] : values) {
                merged_values[name] = value;
            }
        }
    }
    return true;
}

/* A value's type and data, without the line breaks Wine puts into long
   hex values ("\" at the end of a line, the next one indented). */
std::string canonical_value(const std::string &value)
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

using Keys = std::map<std::string, std::map<std::string, std::string>>;

/* Whether the key SECTION exists in KEYS: written out, or implied by a
   subkey (Wine does not write keys that have subkeys but no values). */
bool has_key(const Keys &keys, const std::string &section)
{
    if (keys.count(section)) return true;
    const std::string prefix = section + "\\\\";
    const auto next = keys.lower_bound(prefix);
    return next != keys.end() && starts_with(next->first, prefix);
}

/* Three-way merge of one hive: LAYERS is what the Nix layers give now,
   BASE what they gave at the last successful merge, WRITABLE the writable
   layer's hive. Per value:
   - WRITABLE has it as BASE had it (same type and data): the user did not
     change it, so the layers decide (their value, or none);
   - WRITABLE has it, but BASE did not, or differently: the user's;
   - WRITABLE lacks it, but BASE had it: the user deleted it;
   - neither has it: the layers decide.
   Keys without values follow the same rules for their existence. Without
   a BASE this is the two-way merge with the writable hive on top. */
std::optional<Registry> merge_three_way(const std::optional<Registry> &layers,
                                        const std::optional<Registry> &base,
                                        const std::optional<Registry> &writable)
{
    if (!layers && !writable) return std::nullopt;

    static const Keys no_keys;
    const Keys &l = layers ? layers->keys : no_keys;
    const Keys &b = base ? base->keys : no_keys;
    const Keys &w = writable ? writable->keys : no_keys;

    Registry result = writable ? *writable : *layers;
    result.keys.clear();

    std::map<std::string, bool> sections;
    for (const Keys *keys : {&l, &b, &w}) {
        for (const auto &entry : *keys) sections[entry.first] = true;
    }

    static const std::map<std::string, std::string> no_values;
    auto values_of = [](const Keys &keys, const std::string &section) -> const std::map<std::string, std::string> & {
        const auto found = keys.find(section);
        return found == keys.end() ? no_values : found->second;
    };

    for (const auto &[section, unused] : sections) {
        (void)unused;
        const auto &lv = values_of(l, section);
        const auto &bv = values_of(b, section);
        const auto &wv = values_of(w, section);

        std::map<std::string, bool> names;
        for (const auto *values : {&lv, &bv, &wv}) {
            for (const auto &entry : *values) names[entry.first] = true;
        }

        std::map<std::string, std::string> merged;
        for (const auto &[name, unused_name] : names) {
            (void)unused_name;
            const auto in_l = lv.find(name);
            const auto in_b = bv.find(name);
            const auto in_w = wv.find(name);
            const bool user_unchanged = in_w != wv.end() && in_b != bv.end()
                && canonical_value(in_w->second) == canonical_value(in_b->second);

            if (in_w != wv.end() && !user_unchanged) {
                merged[name] = in_w->second;
            } else if (in_w == wv.end() && in_b != bv.end()) {
                /* deleted by the user */
            } else if (in_l != lv.end()) {
                merged[name] = in_l->second;
            }
        }

        bool keep_key = !merged.empty();
        if (!keep_key) {
            const bool in_w = has_key(w, section);
            const bool in_b = has_key(b, section);
            if (in_w && !in_b) keep_key = true;
            else if (!in_w && in_b) keep_key = false;
            else keep_key = has_key(l, section);
        }
        if (keep_key) result.keys[section] = std::move(merged);
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
