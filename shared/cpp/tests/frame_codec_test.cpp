// Host test for the portable frame codec. Asserts the SAME golden vectors as
// proto/vectors.json and mac/Tests. Build & run: `make test` in this dir.
// No HarmonyOS / DevEco needed — plain clang++ on the Mac.
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "frame_codec.h"

using namespace superconnect;

static int g_failures = 0;

static std::vector<uint8_t> fromHex(const std::string& hex) {
    std::vector<uint8_t> out;
    for (std::size_t i = 0; i + 1 < hex.size(); i += 2) {
        out.push_back(static_cast<uint8_t>(std::stoi(hex.substr(i, 2), nullptr, 16)));
    }
    return out;
}

static std::string toHex(const std::vector<uint8_t>& bytes) {
    static const char* digits = "0123456789abcdef";
    std::string out;
    out.reserve(bytes.size() * 2);
    for (uint8_t b : bytes) {
        out.push_back(digits[b >> 4]);
        out.push_back(digits[b & 0x0f]);
    }
    return out;
}

static void check(bool cond, const std::string& msg) {
    if (cond) {
        std::printf("  ok   %s\n", msg.c_str());
    } else {
        std::printf("  FAIL %s\n", msg.c_str());
        ++g_failures;
    }
}

// Golden vectors — MUST stay identical to proto/vectors.json.
struct Vector {
    const char* name;
    uint8_t channel;
    uint8_t flags;
    const char* payloadHex;
    const char* frameHex;
};

static const Vector kVectors[] = {
    {"control-hi", 0, 0, "6869", "0000020000006869"},
    {"video-keyframe-deadbeef", 1, 1, "deadbeef", "010104000000deadbeef"},
    {"input-empty", 2, 0, "", "020000000000"},
    {"control-ping-json", 0, 0, "7b2274797065223a2270696e67227d",
     "00000f0000007b2274797065223a2270696e67227d"},
};

int main() {
    std::printf("== encode matches golden ==\n");
    for (const auto& v : kVectors) {
        auto frame = encodeFrame(v.channel, v.flags, fromHex(v.payloadHex));
        check(toHex(frame) == v.frameHex, std::string("encode ") + v.name);
    }

    std::printf("== decode matches golden ==\n");
    for (const auto& v : kVectors) {
        FrameDecoder dec;
        auto frames = dec.push(fromHex(v.frameHex));
        bool ok = frames.size() == 1 && frames[0].channel == v.channel &&
                  frames[0].flags == v.flags && toHex(frames[0].payload) == v.payloadHex;
        check(ok, std::string("decode ") + v.name);
    }

    std::printf("== decode handles fragmentation (1 byte at a time) ==\n");
    {
        FrameDecoder dec;
        auto full = fromHex("010104000000deadbeef");
        std::vector<Frame> collected;
        for (uint8_t b : full) {
            auto got = dec.push(&b, 1);
            collected.insert(collected.end(), got.begin(), got.end());
        }
        bool ok = collected.size() == 1 && collected[0].channel == 1 &&
                  collected[0].flags == 1 && toHex(collected[0].payload) == "deadbeef";
        check(ok, "fragmented frame reassembled");
    }

    std::printf("== decode handles coalescing (two frames in one read) ==\n");
    {
        FrameDecoder dec;
        auto two = fromHex("0000020000006869020000000000");
        auto frames = dec.push(two);
        bool ok = frames.size() == 2 && frames[0].channel == 0 && frames[1].channel == 2 &&
                  frames[1].payload.empty();
        check(ok, "two coalesced frames split");
    }

    if (g_failures == 0) {
        std::printf("\nALL C++ CONFORMANCE TESTS PASSED\n");
        return 0;
    }
    std::printf("\n%d FAILURE(S)\n", g_failures);
    return 1;
}
