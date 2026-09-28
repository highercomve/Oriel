// A C entry point to llama.cpp's JSON-schema-to-GBNF converter
// (common/json-schema-to-grammar.cpp), for llama.zig's jsonSchemaToGrammar,
// plus the three common.cpp string helpers it uses (see shim/common.h).

#include "common.h" // the shim
#include "json-schema-to-grammar.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <sstream>

std::string string_join(const std::vector<std::string> & values, const std::string & separator) {
    std::ostringstream result;
    for (size_t i = 0; i < values.size(); ++i) {
        if (i > 0) {
            result << separator;
        }
        result << values[i];
    }
    return result.str();
}

std::vector<std::string> string_split(const std::string & str, const std::string & delimiter) {
    std::vector<std::string> parts;
    size_t start = 0;
    size_t end = str.find(delimiter);
    while (end != std::string::npos) {
        parts.push_back(str.substr(start, end - start));
        start = end + delimiter.length();
        end = str.find(delimiter, start);
    }
    parts.push_back(str.substr(start));
    return parts;
}

std::string string_repeat(const std::string & str, size_t n) {
    std::string result;
    result.reserve(str.length() * n);
    for (size_t i = 0; i < n; ++i) {
        result += str;
    }
    return result;
}

static char * dup_string(const std::string & s) {
    char * out = static_cast<char *>(std::malloc(s.size() + 1));
    if (out) std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

extern "C" {

// The GBNF grammar for the JSON schema `schema` (`len` bytes, not
// NUL-terminated), malloc'd; free with oriel_llama_free_string. On a bad
// schema: null, and `*err` (when not null) gets the reason, malloc'd too.
char * oriel_llama_json_schema_to_grammar(const char * schema, size_t len, char ** err) {
    if (err) *err = nullptr;
    try {
        const common_json parsed = common_json::parse(std::string(schema, len));
        return dup_string(json_schema_to_grammar(parsed, true));
    } catch (const std::exception & e) {
        if (err) *err = dup_string(e.what());
    } catch (...) {
        if (err) *err = dup_string("unknown error");
    }
    return nullptr;
}

void oriel_llama_free_string(char * s) {
    std::free(s);
}

}
