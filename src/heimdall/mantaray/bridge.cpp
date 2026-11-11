// Copyright 2026 Mattia Giambirtone & All Contributors
// SPDX-License-Identifier: Apache-2.0
#include "bridge.h"
#include "backend.hpp"
#include <new>
#include <memory>
#include <string>
#include <mutex>

namespace HeimdallMR {
struct Board {
    HDBoard view;
    u64 Pieces(u08 side, Piece piece) const noexcept {
        return std::byteswap(view.pieces[side * 6 + static_cast<u08>(piece)]);
    }
    u64 Occupied() const noexcept {
        u64 bits = 0;
        for (int i = 0; i < 12; ++i) bits |= view.pieces[i];
        return std::byteswap(bits);
    }
    u08 King(u08 side) const noexcept { return std::countr_zero(Pieces(side, Piece::King)); }
    u08 At(u08 square) const noexcept {
        const auto p = view.mailbox[square ^ 56];
        return (p & 7) == 6 ? 12 : (p & 7) + (p >> 3) * 6;
    }
    u08 SideToMove() const noexcept { return view.stm; }
};
struct NetworkOwner {
    Net net;
    std::string bytes;
};
struct State {
    std::shared_ptr<NetworkOwner> weights;
    Stack stack;
    explicit State(std::shared_ptr<NetworkOwner> w) : weights(std::move(w)), stack(weights->net) {}
};
// Loading can be requested by book-augmentation workers concurrently. Share
// immutable weights; every live stack retains its own network across reloads.
std::mutex loadMutex;
std::shared_ptr<NetworkOwner> cached;
thread_local std::shared_ptr<NetworkOwner> selected;
}
using namespace HeimdallMR;

const char *hd_mr_load(const void *bytes, size_t size) {
    std::lock_guard lock(loadMutex);
    const std::string_view input(static_cast<const char *>(bytes), size);
    if (cached && cached->bytes == input) { selected = cached; return nullptr; }
    auto candidate = std::make_shared<NetworkOwner>();
    const auto result = candidate->net.Load({static_cast<const std::byte *>(bytes), size});
    if (!result) {
        static thread_local std::string error;
        error = std::string(result.Message()) + " (tensor " + std::to_string(result.Tensor)
            + ", index " + std::to_string(result.Index) + ")";
        return error.c_str();
    }
    candidate->bytes = input;
    selected = cached = std::move(candidate);
    return nullptr;
}
void *hd_mr_new(const void *source) {
    auto weights = source ? static_cast<const State *>(source)->weights : selected;
    return new (std::nothrow) State(std::move(weights));
}
void hd_mr_delete(void *s) { delete static_cast<State *>(s); }
void hd_mr_copy(void *d, const void *s) { *static_cast<State *>(d) = *static_cast<const State *>(s); }
void hd_mr_reset(void *s, HDBoard b) { static_cast<State *>(s)->stack.Reset(Board{b}); }
void hd_mr_push(void *s, HDBoard after, HDMove m) {
    PieceDelta delta;
    const u08 from = m.from ^ 56, to = m.to ^ 56;
    if (m.castle) {
        const bool ks = to > from;
        delta.Remove(Piece::King, m.side, from);
        delta.Remove(Piece::Rook, m.side, to);
        delta.Insert(Piece::King, m.side, (from & 56) | (ks ? 6 : 2));
        delta.Insert(Piece::Rook, m.side, (from & 56) | (ks ? 5 : 3));
    } else {
        if (m.captured != 6) delta.Remove(static_cast<Piece>(m.captured), m.side ^ 1, m.capture ^ 56);
        delta.Remove(static_cast<Piece>(m.piece), m.side, from);
        delta.Insert(static_cast<Piece>(m.promotion == 6 ? m.piece : m.promotion), m.side, to);
    }
    static_cast<State *>(s)->stack.Push(delta, Board{after});
}
void hd_mr_pop(void *s) { static_cast<State *>(s)->stack.Pop(); }
int32_t hd_mr_evaluate(void *s, HDBoard b) { return static_cast<State *>(s)->stack.Evaluate(Board{b}); }
int32_t hd_mr_fresh(void *s, HDBoard b) { return static_cast<State *>(s)->weights->net.Evaluate(Board{b}); }
const void *hd_mr_data(void *s) { return static_cast<State *>(s)->weights->bytes.data(); }
size_t hd_mr_size(void *s) { return static_cast<State *>(s)->weights->bytes.size(); }
int hd_mr_equal(void *a, void *b) {
    const auto &x = static_cast<State *>(a)->stack, &y = static_cast<State *>(b)->stack;
    return [&]<size_t... I>(std::index_sequence<I...>) {
        return ((std::ranges::equal(x.template Values<I>(0), y.template Values<I>(0)) &&
                 std::ranges::equal(x.template Values<I>(1), y.template Values<I>(1))) && ...);
    }(std::make_index_sequence<StackProgram.SlotCount>{});
}
