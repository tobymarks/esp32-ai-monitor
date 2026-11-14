#include "standalone_http.h"
#include <ctype.h>
#include <stdint.h>
#include <string.h>
static bool field_name_char(unsigned char c) {
    // RFC 9110 field-name = token (ASCII tchar), including digits and punctuation.
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') ||
           (c != 0 && strchr("!#$%&'*+-.^_`|~", c) != nullptr);
}
static std::string lower(std::string s) {
    for (char &c : s)
        c = tolower((unsigned char)c);
    return s;
}
bool StandaloneHttpDecoder::line() {
    if (line_.size() < 2 || line_[line_.size() - 2] != '\r')
        return fail("http_framing");
    line_.resize(line_.size() - 2);
    if (mode_ == Status) {
        if (line_.size() < 12 ||
            (line_.compare(0, 9, "HTTP/1.1 ") && line_.compare(0, 9, "HTTP/1.0 ")) ||
            line_.compare(9, 3, "200") || (line_.size() > 12 && line_[12] != ' '))
            return fail("http_status");
        mode_ = Headers;
    } else if (mode_ == Headers) {
        if (line_.empty()) {
            if (length_seen_ && chunked_)
                return fail("http_framing");
            mode_ = chunked_ ? ChunkSize : length_seen_ ? (remaining_ ? Fixed : Done) : UntilEof;
        } else {
            size_t colon = line_.find(':');
            if (colon == std::string::npos || !colon)
                return fail("http_header");
            std::string name = lower(line_.substr(0, colon));
            for (char c : name)
                if (!field_name_char(static_cast<unsigned char>(c)))
                    return fail("http_header");
            size_t start = colon + 1;
            while (start < line_.size() && (line_[start] == ' ' || line_[start] == '\t'))
                ++start;
            size_t end = line_.size();
            while (end > start && (line_[end - 1] == ' ' || line_[end - 1] == '\t'))
                --end;
            std::string value = lower(line_.substr(start, end - start));
            if (name == "content-encoding" && value != "identity")
                return fail("http_encoding");
            if (name == "content-length") {
                if (length_seen_ || value.empty())
                    return fail("http_framing");
                length_seen_ = true;
                remaining_ = 0;
                for (char c : value) {
                    if (c < '0' || c > '9')
                        return fail("http_framing");
                    remaining_ = remaining_ * 10 + c - '0';
                    if (remaining_ > 8192)
                        return fail("response_too_large");
                }
            }
            if (name == "transfer-encoding") {
                if (chunked_ || value != "chunked")
                    return fail("http_encoding");
                chunked_ = true;
            }
        }
    } else if (mode_ == ChunkSize) {
        if (line_.empty() || line_.size() > 8)
            return fail("http_framing");
        remaining_ = 0;
        for (char c : line_) {
            int n = c >= '0' && c <= '9'   ? c - '0'
                    : c >= 'a' && c <= 'f' ? c - 'a' + 10
                    : c >= 'A' && c <= 'F' ? c - 'A' + 10
                                           : -1;
            if (n < 0)
                return fail("http_framing");
            remaining_ = remaining_ * 16 + n;
            if (remaining_ > 8192 - body_.size())
                return fail("response_too_large");
        }
        mode_ = remaining_ ? ChunkData : Trailers;
    } else if (mode_ == ChunkEnd) {
        if (!line_.empty())
            return fail("http_framing");
        mode_ = ChunkSize;
    } else if (mode_ == Trailers) {
        if (line_.empty())
            mode_ = Done;
        else if (line_.find(':') == std::string::npos)
            return fail("http_framing");
    }
    line_.clear();
    return true;
}
bool StandaloneHttpDecoder::feed(const char *bytes, size_t count) {
    if (mode_ == Failed)
        return false;
    for (size_t i = 0; i < count; ++i) {
        if (mode_ == Done)
            return fail("http_trailing");
        if (mode_ == Fixed || mode_ == ChunkData || mode_ == UntilEof) {
            if (body_.size() >= 8192)
                return fail("response_too_large");
            body_ += bytes[i];
            if (mode_ != UntilEof && !--remaining_)
                mode_ = mode_ == Fixed ? Done : ChunkEnd;
        } else {
            if (++metadata_ > 8192 || line_.size() >= 2048)
                return fail("http_headers_too_large");
            char c = bytes[i];
            if ((unsigned char)c < 32 && c != '\r' && c != '\n' && c != '\t')
                return fail("http_header");
            line_ += c;
            if (c == '\n' && !line())
                return false;
        }
    }
    return true;
}
bool StandaloneHttpDecoder::eof() {
    if (mode_ == UntilEof)
        mode_ = Done;
    return mode_ == Done ? true : fail("http_incomplete");
}
