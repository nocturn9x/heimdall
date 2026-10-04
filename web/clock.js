// Copyright 2026 Mattia Giambirtone & All Contributors
// SPDX-License-Identifier: Apache-2.0

// Charge monotonic elapsed time, including suspended or background tabs.
// Fischer increment is added only after a move completed before flag fall.
export class GameClock {
    constructor(baseMs, incrementMs, now = () => performance.now()) {
        this.base = Math.round(baseMs);
        this.remaining = {w: this.base, b: this.base};
        this.increment = Math.round(incrementMs);
        this.now = now;
        this.running = null;
        this.startedAt = null;
        this.expired = null;
    }

    read() {
        const remaining = {...this.remaining};
        if (this.running) {
            remaining[this.running] = Math.max(0, remaining[this.running] - (this.now() - this.startedAt));
        }
        return remaining;
    }

    pause() {
        if (!this.running) return;
        const side = this.running;
        this.remaining = this.read();
        this.running = null;
        this.startedAt = null;
        if (this.remaining[side] <= 0) this.expired = side;
    }

    start(side) {
        if (this.running === side || this.expired) return;
        this.pause();
        if (this.expired) return;
        if (this.remaining[side] <= 0) {
            this.expired = side;
            return;
        }
        this.running = side;
        this.startedAt = this.now();
    }

    completeMove(side) {
        this.pause();
        if (this.expired) return false;
        this.remaining[side] += this.increment;
        return true;
    }

    restore(remaining) {
        this.running = null;
        this.startedAt = null;
        this.expired = null;
        this.remaining = {...remaining};
    }
}

export function formatClock(milliseconds) {
    if (milliseconds < 10000) return (Math.max(0, Math.ceil(milliseconds / 100)) / 10).toFixed(1);
    const seconds = Math.ceil(milliseconds / 1000);
    return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}
