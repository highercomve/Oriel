// A C entry point to llama.cpp's JSON-schema-to-GBNF converter
// (common/json-schema-to-grammar.cpp), for llama.zig's jsonSchemaToGrammar.

#include "json-schema-to-grammar.h"

#include <cstdlib>
#include <cstring>
#include <exception>

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
