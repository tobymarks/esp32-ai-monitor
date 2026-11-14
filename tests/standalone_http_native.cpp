#include "standalone_http.h"
#include <cassert>
#include <cstdio>
#include <string>
static int checks = 0;
static void valid(const std::string &wire, const std::string &expected) {
    for (size_t stride : {size_t(1), size_t(2), size_t(13), size_t(512), wire.size()}) {
        StandaloneHttpDecoder parser;
        for (size_t offset = 0; offset < wire.size(); offset += stride) {
            assert(parser.feed(wire.data() + offset, std::min(stride, wire.size() - offset)));
        }
        assert(parser.eof());
        assert(parser.complete());
        assert(parser.body() == expected);
        ++checks;
    }
}
static void invalid(const std::string &wire) {
    for (size_t stride : {size_t(1), size_t(17), wire.size()}) {
        StandaloneHttpDecoder parser;
        bool good = true;
        for (size_t offset = 0; good && offset < wire.size(); offset += stride)
            good = parser.feed(wire.data() + offset, std::min(stride, wire.size() - offset));
        assert(!good || !parser.eof());
        assert(parser.error());
        ++checks;
    }
}
int main() {
    valid("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}", "{}");
    valid("HTTP/1.1 200 OK\r\nX-API-Version2: 2\r\nX_Request_Id: request\r\n"
          "!#$%&'*+-.^_`|~0123456789: valid-token\r\nContent-Length: 2\r\n\r\n{}", "{}");
    for (const char *name : {"Bad Header", "Bad\tHeader", "Bad(Header)", "Bad/Header",
                             "Bad@Header", "Bad[Header]", "Bad=Header", "Bad?Header"})
        invalid(std::string("HTTP/1.1 200 OK\r\n") + name + ": x\r\nContent-Length: 2\r\n\r\n{}");
    valid("HTTP/1.0 200 OK\r\n\r\n[]", "[]");
    valid("HTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked\r\nContent-Encoding: "
          "identity\r\n\r\n1\r\n{\r\n1\r\n}\r\n0\r\n\r\n",
          "{}");
    valid("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\nX-Check: "
          "value\r\n\r\n",
          "{}");
    valid("HTTP/1.1 200 OK\r\nContent-Length: 8192\r\n\r\n" + std::string(8192, 'x'),
          std::string(8192, 'x'));
    valid("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1000\r\n" + std::string(4096, 'x') +
              "\r\n1000\r\n" + std::string(4096, 'y') + "\r\n0\r\n\r\n",
          std::string(4096, 'x') + std::string(4096, 'y'));
    for (const char *status :
         {"301 Moved", "302 Found", "401 Unauthorized", "500 Error", "2000 OK"})
        invalid(std::string("HTTP/1.1 ") + status +
                "\r\nLocation: https://other.org/\r\nContent-Length: 0\r\n\r\n");
    for (const char *headers :
         {"Content-Encoding: gzip", "Transfer-Encoding: gzip, chunked", "Content-Length: -1",
          "Content-Length: 8193", "Content-Length: 99999999999999999999999999999",
          "Content-Length: 1\r\nContent-Length: 1",
          "Content-Length: 1\r\nTransfer-Encoding: chunked", "Content-Length: two",
          "Bad Header: x"})
        invalid(std::string("HTTP/1.1 200 OK\r\n") + headers + "\r\n\r\nx");
    invalid("HTTP/1.1 200 OK\nContent-Length: 2\n\n{}");
    invalid("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{");
    invalid("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}x");
    invalid("HTTP/1.1 200 OK\r\n\r\n" + std::string(8193, 'x'));
    invalid("HTTP/1.1 200 OK\r\nX-Big: " + std::string(2048, 'x') + "\r\n\r\n");
    std::string headers = "HTTP/1.1 200 OK\r\n";
    for (int i = 0; i < 1000; ++i)
        headers += "X-A: data\r\n";
    invalid(headers + "\r\n");
    for (const char *chunk :
         {"2001\r\n", "ffffffff\r\n", "X\r\n", "2\r\n{", "2\r\n{}\r\n", "2\r\n{}XX\r\n0\r\n\r\n"})
        invalid(std::string("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n") + chunk);
    std::printf("standalone HTTP framing: %d fragmented/limit/error checks passed\n", checks);
}
