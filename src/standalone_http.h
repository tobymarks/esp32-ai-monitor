#ifndef STANDALONE_HTTP_H
#define STANDALONE_HTTP_H
#include <string>
#include <stddef.h>
// Incremental HTTP/1 response decoder. TLS and I/O live in the worker; this
// parser caps actual decoded bytes, framing metadata and every header line.
class StandaloneHttpDecoder {
  public:
    bool feed(const char *bytes, size_t count);
    bool eof();
    bool complete() const { return mode_ == Done; }
    const char *error() const { return error_; }
    const std::string &body() const { return body_; }

  private:
    enum Mode {
        Status,
        Headers,
        Fixed,
        UntilEof,
        ChunkSize,
        ChunkData,
        ChunkEnd,
        Trailers,
        Done,
        Failed
    } mode_ = Status;
    std::string line_, body_;
    size_t metadata_ = 0, remaining_ = 0;
    bool length_seen_ = false, chunked_ = false;
    const char *error_ = nullptr;
    bool fail(const char *e) {
        error_ = e;
        mode_ = Failed;
        return false;
    }
    bool line();
};
#endif
