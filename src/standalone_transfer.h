#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// A single bounded RAM staging transaction. No writes occur until the caller
// verifies SHA-256, validates the profile, and commits a persistent record.
class StandaloneTransfer {
  public:
    static constexpr size_t max_bytes = 8192;
    static constexpr uint32_t ttl_ms = 60000;
    ~StandaloneTransfer() { reset(); }
    StandaloneTransfer() = default;
    StandaloneTransfer(const StandaloneTransfer &) = delete;
    StandaloneTransfer &operator=(const StandaloneTransfer &) = delete;
    bool active() const { return data_ != nullptr; }
    const char *data() const { return data_; }
    size_t size() const { return size_; }
    size_t received() const { return received_; }
    const char *digest() const { return digest_; }
    const char *transaction() const { return transaction_; }
    void reset() {
        free(data_);
        data_ = nullptr;
        size_ = received_ = 0;
        transaction_[0] = digest_[0] = 0;
    }
    void expire(uint32_t now) {
        if (active() && uint32_t(now - touched_) >= ttl_ms)
            reset();
    }
    bool begin(const char *tx, size_t bytes, const char *sha, uint32_t now, const char **error) {
        expire(now);
        if (active())
            return fail(error, "transfer_busy");
        if (!valid_id(tx) || !bytes || bytes > max_bytes || !valid_digest(sha))
            return fail(error, "transfer_invalid");
        data_ = static_cast<char *>(malloc(bytes + 1));
        if (!data_)
            return fail(error, "resource_limit");
        data_[0] = data_[bytes] = 0;
        size_ = bytes;
        received_ = 0;
        touched_ = now;
        strcpy(transaction_, tx);
        strcpy(digest_, sha);
        return true;
    }
    bool chunk(const char *tx, size_t offset, const char *bytes, size_t length, uint32_t now,
               const char **error) {
        expire(now);
        if (!matches(tx))
            return fail(error, "transfer_missing");
        if (!bytes || !length || length > 1024 || offset > received_ || offset > size_ ||
            length > size_ - offset)
            return fail(error, "transfer_offset");
        if (offset < received_) {
            if (length > received_ - offset || memcmp(data_ + offset, bytes, length))
                return fail(error, "transfer_conflict");
        } else {
            memcpy(data_ + offset, bytes, length);
            received_ += length;
            data_[received_] = 0;
        }
        touched_ = now;
        return true;
    }
    bool complete(const char *tx, uint32_t now, const char **error) {
        expire(now);
        if (!matches(tx))
            return fail(error, "transfer_missing");
        if (received_ != size_)
            return fail(error, "transfer_incomplete");
        return true;
    }

  private:
    char *data_ = nullptr;
    char transaction_[65] = {}, digest_[65] = {};
    size_t size_ = 0, received_ = 0;
    uint32_t touched_ = 0;
    bool matches(const char *tx) const { return active() && tx && !strcmp(tx, transaction_); }
    static bool fail(const char **error, const char *message) {
        if (error)
            *error = message;
        return false;
    }
    static bool valid_id(const char *tx) {
        if (!tx || !*tx || strlen(tx) > 64)
            return false;
        for (; *tx; ++tx)
            if (!((*tx >= 'a' && *tx <= 'z') || (*tx >= 'A' && *tx <= 'Z') ||
                  (*tx >= '0' && *tx <= '9') || *tx == '-'))
                return false;
        return true;
    }
    static bool valid_digest(const char *sha) {
        if (!sha || strlen(sha) != 64)
            return false;
        for (; *sha; ++sha)
            if (!((*sha >= '0' && *sha <= '9') || (*sha >= 'a' && *sha <= 'f')))
                return false;
        return true;
    }
};
