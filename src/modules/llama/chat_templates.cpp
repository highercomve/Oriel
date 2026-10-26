// A C entry point to llama.cpp's chat templates (common/chat.cpp), for
// llama.zig's ChatTemplates: what llama-server does for an OpenAI chat
// request. The model's own Jinja template renders the messages, tools and
// thinking switch into the prompt; the sampler carries the template's
// (lazy) tool-call grammar; the parser turns the generated text back into
// an OpenAI message (content, reasoning_content, tool_calls).

#include "chat.h"
#include "common.h"
#include "sampling.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <map>
#include <set>
#include <string>
#include <vector>

static char * dup_string(const std::string & s) {
    char * out = static_cast<char *>(std::malloc(s.size() + 1));
    if (out) std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

static void set_error(char ** err, const char * what) {
    if (err) *err = dup_string(what);
}

struct oriel_llama_chat {
    const llama_model *       model;
    common_chat_templates_ptr tmpls;
};

struct oriel_llama_chat_turn {
    const llama_vocab *       vocab   = nullptr;
    common_sampler *          sampler = nullptr;
    common_chat_parser_params parser;
    std::vector<std::string>  stops;
    std::set<llama_token>     preserved;
    std::string               text; // generated so far
    common_chat_msg           msg;  // its last parse

    ~oriel_llama_chat_turn() {
        if (sampler) common_sampler_free(sampler);
    }
};

// The request's thinking-independent template kwargs (values as JSON text).
static std::map<std::string, std::string> template_kwargs(const common_json & request) {
    std::map<std::string, std::string> out;
    if (request.contains("chat_template_kwargs") && request.at("chat_template_kwargs").is_object()) {
        for (const auto & item : request.at("chat_template_kwargs").items()) {
            if (item.key() != "enable_thinking") out[item.key()] = item.value().dump();
        }
    }
    // Some templates (gpt-oss) read the effort itself.
    if (request.contains("reasoning_effort") && request.at("reasoning_effort").is_string()) {
        const auto effort = request.at("reasoning_effort").get<std::string>();
        if (!effort.empty() && effort != "none") out["reasoning_effort"] = common_json(effort).dump();
    }
    return out;
}

// response_format: a JSON schema the answer must match ("" = none).
static std::string json_schema_of(const common_json & request) {
    if (!request.contains("response_format") || !request.at("response_format").is_object()) return "";
    const auto & rf   = request.at("response_format");
    const auto   type = rf.value("type", std::string());
    if (type == "json_object") return "{\"type\":\"object\"}";
    if (type == "json_schema" && rf.contains("json_schema") && rf.at("json_schema").is_object()) {
        const auto & js = rf.at("json_schema");
        if (js.contains("schema")) return js.at("schema").dump();
    }
    return "";
}

// The grammar triggers as the sampler wants them: a trigger word that is one
// (preserved) token becomes a token trigger, as llama-server does.
static std::vector<common_grammar_trigger> sampler_triggers(const llama_vocab * vocab, const std::vector<common_grammar_trigger> & triggers, const std::set<llama_token> & preserved) {
    std::vector<common_grammar_trigger> out;
    for (const auto & t : triggers) {
        if (t.type == COMMON_GRAMMAR_TRIGGER_TYPE_WORD) {
            const auto ids = common_tokenize(vocab, t.value, false, true);
            if (ids.size() == 1 && preserved.count(ids[0])) {
                common_grammar_trigger token;
                token.type  = COMMON_GRAMMAR_TRIGGER_TYPE_TOKEN;
                token.value = t.value;
                token.token = ids[0];
                out.push_back(std::move(token));
                continue;
            }
        }
        out.push_back(t);
    }
    return out;
}

// `s`'s length without a UTF-8 sequence its last token only began (the
// next token completes it).
static size_t complete_utf8(const std::string & s) {
    const size_t n = s.size();
    for (size_t back = 1; back <= 4 && back <= n; ++back) {
        const unsigned char ch = static_cast<unsigned char>(s[n - back]);
        if ((ch & 0xC0) == 0x80) continue; // a continuation byte
        const size_t need = ch < 0x80 ? 1 : (ch >> 5) == 0x6 ? 2 : (ch >> 4) == 0xE ? 3 : (ch >> 3) == 0x1E ? 4 : 1;
        return back >= need ? n : n - back;
    }
    return n;
}

// The reasoning and content added since the last parse, appended to `reasoning`/`content`.
static void take_diffs(oriel_llama_chat_turn * turn, const common_chat_msg & next, std::string & reasoning, std::string & content) {
    for (const auto & d : common_chat_msg_diff::compute_diffs(turn->msg, next)) {
        reasoning += d.reasoning_content_delta;
        content += d.content_delta;
    }
    turn->msg = next;
}

static common_json message_json(const common_chat_msg & msg) {
    auto out = common_json::object();
    out["role"]              = "assistant";
    out["content"]           = msg.content;
    out["reasoning_content"] = msg.reasoning_content;
    auto calls               = common_json::array();
    for (const auto & tc : msg.tool_calls) {
        auto call         = common_json::object();
        call["name"]      = tc.name;
        call["arguments"] = tc.arguments;
        calls.push_back(call);
    }
    out["tool_calls"] = calls;
    return out;
}

// The sampler's settings for one answer (llama.zig's Options; a field at
// its "off" value leaves llama.cpp's sampler step out).
struct oriel_llama_sampling {
    float    temperature;
    float    top_p;            // 1: off
    int32_t  top_k;            // 0: off
    float    min_p;            // 0: off
    float    presence_penalty; // 0: off
    float    frequency_penalty;
    float    repeat_penalty;   // 1: off
    int32_t  penalty_last_n;   // tokens the penalties look back over (-1: the context)
    uint32_t seed;
};

extern "C" {

// The model's chat templates (`tmpl` when not null, else its own, else
// ChatML); null with `*err` set (malloc'd) when the template can't be parsed.
oriel_llama_chat * oriel_llama_chat_init(const llama_model * model, const char * tmpl, size_t tmpl_len, char ** err) {
    if (err) *err = nullptr;
    try {
        return new oriel_llama_chat{ model, common_chat_templates_init(model, tmpl ? std::string(tmpl, tmpl_len) : std::string()) };
    } catch (const std::exception & e) {
        set_error(err, e.what());
    } catch (...) {
        set_error(err, "unknown error");
    }
    return nullptr;
}

void oriel_llama_chat_free(oriel_llama_chat * chat) {
    delete chat;
}

// One answer to the OpenAI chat request `request` (`len` bytes: messages,
// tools, tool_choice, parallel_tool_calls, response_format,
// chat_template_kwargs, reasoning_effort), with thinking on or off, sampled with `sampling`.
// `*prompt` gets the rendered prompt (malloc'd; tokenize it with
// add_special and parse_special). Null with `*err` set on a request the
// template can't render.
oriel_llama_chat_turn * oriel_llama_chat_begin(oriel_llama_chat * chat, const char * request, size_t len, bool think, const oriel_llama_sampling * sampling, char ** prompt, char ** err) {
    if (err) *err = nullptr;
    if (prompt) *prompt = nullptr;
    oriel_llama_chat_turn * turn = nullptr;
    try {
        const auto body = common_json::parse(std::string(request, len));
        if (!body.contains("messages") || !body.at("messages").is_array()) {
            set_error(err, "missing messages");
            return nullptr;
        }
        common_chat_templates_inputs inputs;
        inputs.messages = common_chat_msgs_parse_oaicompat(body.at("messages"));
        if (body.contains("tools") && body.at("tools").is_array()) inputs.tools = common_chat_tools_parse_oaicompat(body.at("tools"));
        if (body.contains("tool_choice")) {
            const auto & tc  = body.at("tool_choice");
            // {"type":"function",...}: one function, which the template can't
            // single out; a call is still required.
            inputs.tool_choice = tc.is_string() ? common_chat_tool_choice_parse_oaicompat(tc.get<std::string>()) : COMMON_CHAT_TOOL_CHOICE_REQUIRED;
        }
        const auto caps = common_chat_templates_get_caps(chat->tmpls.get());
        const auto par  = caps.find("supports_parallel_tool_calls");
        inputs.parallel_tool_calls = body.contains("parallel_tool_calls") && body.at("parallel_tool_calls").is_boolean()
            ? body.at("parallel_tool_calls").get<bool>()
            : (par != caps.end() && par->second);
        inputs.json_schema          = json_schema_of(body);
        inputs.reasoning_format     = COMMON_REASONING_FORMAT_DEEPSEEK;
        inputs.enable_thinking      = think;
        inputs.chat_template_kwargs = template_kwargs(body);

        const auto params = common_chat_templates_apply(chat->tmpls.get(), inputs);

        turn        = new oriel_llama_chat_turn();
        turn->vocab = llama_model_get_vocab(chat->model);
        turn->stops = params.additional_stops;
        for (const auto & t : params.preserved_tokens) {
            const auto ids = common_tokenize(turn->vocab, t, false, true);
            if (ids.size() == 1) turn->preserved.insert(ids[0]);
        }

        common_params_sampling sp;
        sp.temp            = sampling->temperature;
        sp.top_p           = sampling->top_p;
        sp.top_k           = sampling->top_k;
        sp.min_p           = sampling->min_p;
        sp.penalty_present = sampling->presence_penalty;
        sp.penalty_freq    = sampling->frequency_penalty;
        sp.penalty_repeat  = sampling->repeat_penalty;
        sp.penalty_last_n  = sampling->penalty_last_n;
        sp.seed            = sampling->seed;
        if (!params.grammar.empty()) sp.grammar = common_grammar(COMMON_GRAMMAR_TYPE_TOOL_CALLS, params.grammar);
        sp.grammar_lazy      = params.grammar_lazy;
        sp.grammar_triggers  = sampler_triggers(turn->vocab, params.grammar_triggers, turn->preserved);
        sp.preserved_tokens  = turn->preserved;
        sp.generation_prompt = params.generation_prompt;
        if (sp.grammar_lazy && sp.grammar_triggers.empty()) sp.grammar_lazy = false;
        turn->sampler = common_sampler_init(chat->model, sp);
        if (!turn->sampler) {
            delete turn;
            set_error(err, "the template's grammar couldn't be compiled");
            return nullptr;
        }

        turn->parser                  = common_chat_parser_params(params);
        turn->parser.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;
        turn->parser.parse_tool_calls = !inputs.tools.empty() && inputs.tool_choice != COMMON_CHAT_TOOL_CHOICE_NONE;
        if (!params.parser.empty()) turn->parser.parser.load(params.parser);

        if (prompt) *prompt = dup_string(params.prompt);
        return turn;
    } catch (const std::exception & e) {
        set_error(err, e.what());
    } catch (...) {
        set_error(err, "unknown error");
    }
    delete turn;
    return nullptr;
}

// The next token (from the logits of the last decoded one), accepted.
llama_token oriel_llama_chat_sample(oriel_llama_chat_turn * turn, llama_context * ctx) {
    const llama_token tok = common_sampler_sample(turn->sampler, ctx, -1);
    common_sampler_accept(turn->sampler, tok, true);
    return tok;
}

// Add a generated token (not an end-of-generation one) to the answer. The
// reasoning and content it adds go to `*reasoning`/`*content` (malloc'd, or
// null when none). True when the answer hit one of the template's stop
// strings (it ends before it).
bool oriel_llama_chat_feed(oriel_llama_chat_turn * turn, llama_token tok, char ** reasoning, char ** content) {
    *reasoning = nullptr;
    *content   = nullptr;
    turn->text += common_token_to_piece(turn->vocab, tok, turn->preserved.count(tok) > 0);
    bool stopped = false;
    for (const auto & stop : turn->stops) {
        const auto at = turn->text.find(stop);
        if (!stop.empty() && at != std::string::npos) {
            turn->text.resize(at);
            stopped = true;
        }
    }
    std::string r, c;
    try {
        const auto next = common_chat_parse(turn->text.substr(0, complete_utf8(turn->text)), true, turn->parser);
        if (!next.empty()) take_diffs(turn, next, r, c);
    } catch (...) {
        // A partial parse can fail mid-structure: the next token retries.
    }
    if (!r.empty()) *reasoning = dup_string(r);
    if (!c.empty()) *content = dup_string(c);
    return stopped;
}

// The whole answer as an OpenAI message, JSON (malloc'd):
// {"role","content","reasoning_content","tool_calls":[{"name","arguments"}]}.
// The last reasoning and content not yet fed out go to `*reasoning`/`*content`.
// Text the parser can't read stays the content.
char * oriel_llama_chat_finish(oriel_llama_chat_turn * turn, char ** reasoning, char ** content) {
    *reasoning = nullptr;
    *content   = nullptr;
    common_chat_msg final_msg;
    try {
        final_msg = common_chat_parse(turn->text, false, turn->parser);
    } catch (...) {
        final_msg = turn->msg;
        if (final_msg.empty()) final_msg.content = turn->text;
    }
    std::string r, c;
    take_diffs(turn, final_msg, r, c);
    if (!r.empty()) *reasoning = dup_string(r);
    if (!c.empty()) *content = dup_string(c);
    try {
        return dup_string(message_json(final_msg).dump());
    } catch (...) {
        return nullptr;
    }
}

void oriel_llama_chat_end(oriel_llama_chat_turn * turn) {
    delete turn;
}

}
