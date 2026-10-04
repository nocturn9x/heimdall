// Copyright 2026 Mattia Giambirtone & All Contributors
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {GameClock, formatClock} from '../web/clock.js';

function fixture(base = 60000, increment = 2000) {
    let time = 0;
    return {clock: new GameClock(base, increment, () => time), advance: ms => { time += ms; }};
}

test('charge only the active player and grant Fischer increment after a completed move', () => {
    const {clock, advance} = fixture();
    clock.start('w');
    advance(1234);
    assert.deepEqual(clock.read(), {w: 58766, b: 60000});
    assert.equal(clock.completeMove('w'), true);
    assert.deepEqual(clock.read(), {w: 60766, b: 60000});
    clock.start('b');
    advance(4321);
    assert.deepEqual(clock.read(), {w: 60766, b: 55679});
});

test('pause/resume does not charge time spent reviewing or paused', () => {
    const {clock, advance} = fixture();
    clock.start('w');
    advance(2500);
    clock.pause();
    advance(120000);
    assert.deepEqual(clock.read(), {w: 57500, b: 60000});
    clock.start('w');
    clock.start('w'); // UI refreshes must not restart the timer.
    advance(1500);
    assert.equal(clock.read().w, 56000);
});

test('a move at flag fall cannot gain increment or revive the clock', () => {
    for (const elapsed of [60000, 120000]) {
        const {clock, advance} = fixture();
        clock.start('b');
        advance(elapsed);
        assert.equal(clock.completeMove('b'), false);
        assert.equal(clock.expired, 'b');
        clock.start('w');
        assert.deepEqual(clock.read(), {w: 60000, b: 0});
        assert.equal(clock.running, null);
    }
});

test('elapsed time is charged even if no UI timer fired in a background tab', () => {
    const {clock, advance} = fixture(300000, 3000);
    clock.start('w');
    advance(301000);
    assert.equal(clock.read().w, 0);
    clock.pause();
    assert.equal(clock.expired, 'w');
});

test('restoring a history frame copies values and clears an expired state', () => {
    const {clock, advance} = fixture();
    clock.start('w');
    advance(60001);
    clock.pause();
    const snapshot = {w: 42000, b: 51000};
    clock.restore(snapshot);
    snapshot.w = 0;
    assert.deepEqual(clock.read(), {w: 42000, b: 51000});
    clock.start('b');
    advance(1000);
    assert.equal(clock.read().b, 50000);
    assert.equal(clock.expired, null);
});

test('restoring a zero clock cannot start play again', () => {
    const {clock} = fixture();
    clock.restore({w: 0, b: 60000});
    clock.start('w');
    assert.equal(clock.expired, 'w');
    assert.equal(clock.running, null);
});

test('display minutes and seconds, then tenths during the last ten seconds', () => {
    for (const [ms, expected] of [[300000, '5:00'], [299999, '5:00'], [60000, '1:00'], [10000, '0:10'], [9999, '10.0'], [9100, '9.1'], [1, '0.1'], [0, '0.0']]) {
        assert.equal(formatClock(ms), expected);
    }
});
