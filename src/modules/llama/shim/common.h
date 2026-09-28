// The part of llama.cpp's common/common.h that common/json-schema-to-grammar.cpp
// uses: three string helpers (their definitions, from common.cpp, are in
// ../json_schema_grammar.cpp). Oriel builds the converter alone, not all of
// llama.cpp's `common` library.
#pragma once

#include <sstream>
#include <string>
#include <vector>

std::string string_join(const std::vector<std::string> & values, const std::string & separator);
std::vector<std::string> string_split(const std::string & str, const std::string & delimiter);
std::string string_repeat(const std::string & str, size_t n);
