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
        if (values.count("__wine_link")) out << "#link\n";
        for (const auto &[name, value] : values) {
            if (name == "__wine_link") continue;
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

/* Merges the hive REG_NAME of the sources (lowest priority first). A source
   hive that exists but cannot be read or parsed fails the merge: skipping
   it would drop its values, and when it is the writable layer's own hive,
   the user's values would be replaced by the layers below. */
bool merge_one(const std::string &reg_name, const std::vector<fs::path> &source_dirs,
               std::optional<Registry> &result)
{
    Registry merged;
    bool have_registry = false;

    for (const auto &source_dir : source_dirs) {
        const auto source_path = source_dir / reg_name;
        std::error_code ec;
        if (!fs::exists(source_path, ec)) {
            if (ec) {
                std::cerr << "error: cannot inspect registry " << source_path << ": " << ec.message() << '\n';
                return false;
            }
            continue;
        }
        if (!fs::is_regular_file(source_path, ec)) {
            std::cerr << "error: registry " << source_path << " is not a regular file\n";
            return false;
        }

        std::string error;
        auto parsed = parse_registry(source_path, error);
        if (!parsed) {
            std::cerr << "error: failed to parse registry " << source_path << ": " << error << '\n';
            return false;
        }

        if (!have_registry) {
            merged = std::move(*parsed);
            have_registry = true;
            continue;
        }

        merged.version = parsed->version;
        merged.location = parsed->location;
        merged.arch = parsed->arch;
        for (auto &[section, values] : parsed->keys) {
            auto &merged_values = merged.keys[section];
            for (auto &[name, value] : values) {
                merged_values[name] = value;
            }
        }
    }

    if (have_registry) result = std::move(merged);
    return true;
}

} // namespace

int main(int argc, char **argv)
{
    if (argc < 3) {
        std::cerr << "usage: merge-wine-registries OUT_DIR SOURCE_DIR...\n";
        return 2;
    }

    const fs::path out_dir = argv[1];
    std::vector<fs::path> source_dirs;
    for (int i = 2; i < argc; ++i) {
        source_dirs.emplace_back(argv[i]);
    }

    const std::vector<std::string> reg_names = {"system.reg", "user.reg", "userdef.reg"};

    /* Everything is read and merged before anything is written. */
    std::vector<std::optional<Registry>> merged(reg_names.size());
    for (size_t i = 0; i < reg_names.size(); ++i) {
        if (!merge_one(reg_names[i], source_dirs, merged[i])) return 1;
    }

    /* Each hive is written next to its original, read back and compared,
       and only then renamed over it. */
    std::error_code ec;
    fs::create_directories(out_dir, ec);
    if (ec) {
        std::cerr << "error: cannot create " << out_dir << ": " << ec.message() << '\n';
        return 1;
    }
    std::vector<fs::path> staged(reg_names.size());
    auto discard_staged = [&]() {
        for (const auto &path : staged) {
            if (!path.empty()) fs::remove(path, ec);
        }
    };
    for (size_t i = 0; i < reg_names.size(); ++i) {
        if (!merged[i]) continue;
        staged[i] = out_dir / ("." + reg_names[i] + ".nix-overlayfs-new");
        std::string error;
        std::optional<Registry> written;
        if (write_registry(staged[i], *merged[i])) written = parse_registry(staged[i], error);
        if (!written || !same_registry(*written, *merged[i])) {
            std::cerr << "error: failed to write " << out_dir / reg_names[i] << '\n';
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
