// Copyright 2026 Mattia Giambirtone & All Contributors
// SPDX-License-Identifier: Apache-2.0

// Serialize position/option changes behind the previous search's bestmove.
// Revision checks discard results from cancelled searches and obsolete requests.
export class BrowserEngine {
    constructor(callbacks) {
        this.callbacks = callbacks;
        this.worker = new Worker(new URL('heimdall.worker.js', import.meta.url));
        this.revision = 0;
        this.active = null;
        this.barriers = [];
        this.queue = Promise.resolve();
        this.maxThreads = 1;
        this.threads = 1;
        this.hash = 64;
        this.hashRange = {min: 1, max: 256, default: 64};
        this.initialized = false;
        this.failed = false;
        this.ready = new Promise((resolve, reject) => {
            this.resolveReady = resolve;
            this.rejectReady = reject;
        });
        // Initialization failures are also displayed when no search has been requested.
        this.ready.catch(() => {});
        this.worker.onmessage = ({data}) => this.receive(String(data));
        this.worker.onerror = event => this.fail(event.message || 'Unable to start the engine worker.');
        this.send('uci');
    }

    send(command) {
        this.worker.postMessage(command);
    }

    barrier() {
        const promise = new Promise((resolve, reject) => this.barriers.push({resolve, reject}));
        this.send('isready');
        return promise;
    }

    receive(line) {
        const threads = line.match(/^option name Threads .* max (\d+)$/);
        if (threads) this.maxThreads = Number(threads[1]);
        const hash = line.match(/^option name Hash type spin default (\d+) min (\d+) max (\d+)$/);
        if (hash) {
            this.hash = Number(hash[1]);
            this.hashRange = {default: this.hash, min: Number(hash[2]), max: Number(hash[3])};
        }
        if (line === 'uciok') {
            // Heimdall represents castling as king-to-rook, including in its PV.
            this.send('setoption name UCI_Chess960 value true');
            this.send('setoption name MoveOverhead value 30');
            this.send('setoption name EnableWeirdTCs value true');
            this.barrier().then(() => {
                this.initialized = true;
                this.resolveReady();
                this.callbacks.ready(this.maxThreads, this.hashRange);
            }).catch(error => this.fail(error.message));
        } else if (line === 'readyok') {
            this.barriers.shift()?.resolve();
        } else if (/Browser engine error:|^info string (?:Error|error)/.test(line)) {
            this.fail(line.replace(/^info string /, ''));
        } else if (line.startsWith('bestmove ')) {
            const active = this.active;
            this.active = null;
            if (!active) return;
            active.resolve();
            if (active.revision === this.revision) {
                this.callbacks.complete(line.split(/\s+/)[1], active.context);
            }
        } else if (line.startsWith('info depth ') && this.active?.revision === this.revision) {
            const fields = {};
            for (const key of ['depth', 'nodes', 'nps', 'time']) {
                const match = line.match(new RegExp(`\\b${key} (\\d+)`));
                if (match) fields[key] = Number(match[1]);
            }
            const score = line.match(/\bscore (cp|mate) (-?\d+)/);
            if (score) fields.score = {type: score[1], value: Number(score[2])};
            const pv = line.match(/\bpv (.+)$/);
            if (pv) fields.pv = pv[1].split(/\s+/);
            this.callbacks.info(fields, this.active.context);
        }
    }

    cancel() {
        if (!this.active) return Promise.resolve();
        if (!this.active.stopping) {
            this.active.stopping = true;
            this.send('stop');
        }
        return this.active.done;
    }

    stop() {
        ++this.revision;
        this.cancel();
    }

    applyOptions({threads, hash}) {
        if (threads !== this.threads) {
            this.send(`setoption name Threads value ${threads}`);
            this.threads = threads;
        }
        if (hash !== this.hash) {
            this.send(`setoption name Hash value ${hash}`);
            this.hash = hash;
        }
    }

    configure(options) {
        const revision = ++this.revision;
        this.cancel();
        this.queue = this.queue.then(async () => {
            await this.ready;
            if (this.failed || revision !== this.revision) return;
            await this.cancel();
            if (revision !== this.revision) return;
            this.applyOptions(options);
            await this.barrier();
        }).catch(error => this.fail(error.message));
        return this.queue;
    }

    clearHash() {
        ++this.revision;
        this.cancel();
        this.queue = this.queue.then(async () => {
            await this.ready;
            if (this.failed) return;
            await this.cancel();
            this.send('setoption name TTClear');
            await this.barrier();
        }).catch(error => this.fail(error.message));
        return this.queue;
    }

    search({position, go, threads, hash, context, newGame = false}) {
        const revision = ++this.revision;
        this.cancel();
        this.queue = this.queue.then(async () => {
            await this.ready;
            if (this.failed || revision !== this.revision) return;
            await this.cancel();
            if (revision !== this.revision) return;
            this.applyOptions({threads, hash});
            if (newGame) this.send('ucinewgame');
            this.send(position);
            await this.barrier();
            if (revision !== this.revision) return;
            const active = {revision, context, stopping: false};
            active.done = new Promise(resolve => { active.resolve = resolve; });
            this.active = active;
            this.send(typeof go === 'function' ? go() : go);
        }).catch(error => this.fail(error.message));
    }

    fail(message) {
        if (this.failed) return;
        this.failed = true;
        ++this.revision;
        this.rejectReady(new Error(message));
        for (const barrier of this.barriers.splice(0)) barrier.reject(new Error(message));
        this.active?.resolve();
        this.active = null;
        this.worker.terminate();
        this.callbacks.error(message);
    }

    dispose() {
        this.stop();
        this.worker.terminate();
    }
}
