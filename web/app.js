// Copyright 2026 Mattia Giambirtone & All Contributors
// SPDX-License-Identifier: Apache-2.0

import {Chess, DEFAULT_POSITION} from './vendor/chess.js';
import {BrowserEngine} from './engine.js';
import {GameClock, formatClock} from './clock.js';

const $ = id => document.getElementById(id);
const names = {k: 'king', q: 'queen', r: 'rook', b: 'bishop', n: 'knight', p: 'pawn'};
const files = 'abcdefgh';
const compact = new Intl.NumberFormat('en', {notation: 'compact', maximumFractionDigits: 1});
let game = new Chess();
let rootFen = DEFAULT_POSITION;
let history = [];
let cursor = 0;
let mode = 'play';
let player = 'w';
let orientation = 'w';
let selected = null;
let legal = [];
let analysisEnabled = true;
let playPaused = false;
let ready = false;
let failed = false;
let busy = false;
let revision = 0;
let newGame = true;
let bestMove = null;
let promotion = null;
let toastTimer;
let drag = null;
let suppressClick = false;
let clearingHash = false;
let hashSize = 64;
let clock = null;
let clockHistory = [null];
let timeout = null;
let customTime = {base: 300, increment: 3};

function pieceUrl(piece) {
    return `pieces/${piece.color}_${names[piece.type]}.svg`;
}

// Both outbound history and inbound bestmove/PV use Heimdall's king-to-rook UCI.
function moveUci(move) {
    if (move.isKingsideCastle()) return `${move.from}h${move.from[1]}`;
    if (move.isQueensideCastle()) return `${move.from}a${move.from[1]}`;
    return move.from + move.to + (move.promotion || '');
}

function decodeMove(board, uci) {
    return board.moves({verbose: true}).find(move => moveUci(move) === uci);
}

function positionCommand() {
    const moves = history.slice(0, cursor).map(moveUci).join(' ');
    return `position fen ${rootFen}${moves ? ` moves ${moves}` : ''}`;
}

function canMove() {
    if (game.isGameOver() || promotion || (mode === 'play' && (timeout || (clock && !ready)))) return false;
    return mode === 'analysis' || (game.turn() === player && cursor === history.length);
}

function squarePoint(square) {
    const x = files.indexOf(square[0]);
    const y = 8 - Number(square[1]);
    return orientation === 'w' ? [x * 100 + 50, y * 100 + 50] : [(7 - x) * 100 + 50, (7 - y) * 100 + 50];
}

function renderArrow() {
    const path = $('best-arrow');
    if (mode !== 'analysis' || !bestMove || selected) {
        path.setAttribute('d', '');
        return;
    }
    const from = squarePoint(bestMove.from);
    const to = squarePoint(bestMove.to);
    const length = Math.hypot(to[0] - from[0], to[1] - from[1]);
    const direction = [(to[0] - from[0]) / length, (to[1] - from[1]) / length];
    const normal = [-direction[1], direction[0]];
    const point = (distance, width) => `${from[0] + direction[0] * distance + normal[0] * width},${from[1] + direction[1] * distance + normal[1] * width}`;
    // One filled polygon avoids the marker/shaft seam and marker clipping.
    path.setAttribute('d', `M${point(12, 8)} L${point(length - 44, 8)} L${point(length - 44, 24)} L${point(length - 12, 0)} L${point(length - 44, -24)} L${point(length - 44, -8)} L${point(12, -8)} Z`);
}

function renderBoard() {
    const previous = cursor > 0 ? history[cursor - 1] : null;
    const squares = [];
    for (let row = 0; row < 8; row++) {
        for (let col = 0; col < 8; col++) {
            const file = orientation === 'w' ? col : 7 - col;
            const rank = orientation === 'w' ? 8 - row : row + 1;
            const square = files[file] + rank;
            const piece = game.get(square);
            const button = document.createElement('button');
            button.className = 'square';
            button.type = 'button';
            button.dataset.square = square;
            button.classList.toggle('dark', (file + rank) % 2 === 1);
            button.classList.toggle('occupied', Boolean(piece));
            button.classList.toggle('selected', selected === square);
            button.classList.toggle('last', previous?.from === square || previous?.to === square);
            button.classList.toggle('legal', legal.some(move => move.to === square));
            button.classList.toggle('check', piece?.type === 'k' && piece.color === game.turn() && game.isCheck());
            button.setAttribute('aria-label', `${square}${piece ? `, ${piece.color === 'w' ? 'white' : 'black'} ${names[piece.type]}` : ', empty'}`);
            button.setAttribute('aria-pressed', String(selected === square));
            if (piece) {
                const image = document.createElement('img');
                image.src = pieceUrl(piece);
                image.alt = '';
                image.draggable = false;
                button.append(image);
            }
            for (const [show, text, kind] of [[col === 0, rank, 'rank'], [row === 7, files[file], 'file']]) {
                if (show) {
                    const coordinate = document.createElement('span');
                    coordinate.className = `coordinate ${kind}`;
                    coordinate.textContent = text;
                    coordinate.setAttribute('aria-hidden', 'true');
                    button.append(coordinate);
                }
            }
            squares.push(button);
        }
    }
    $('board').replaceChildren(...squares);
    $('eval-bar').classList.toggle('flipped', orientation === 'b');
    renderArrow();
}

function renderPlayers() {
    for (const [location, color] of [['top', orientation === 'w' ? 'b' : 'w'], ['bottom', orientation]]) {
        const human = mode === 'play' && color === player;
        $(`${location}-name`).textContent = mode === 'analysis' ? (color === 'w' ? 'White' : 'Black') : (human ? 'You' : 'Heimdall');
        $(`${location}-detail`).textContent = mode === 'analysis' ? 'Position analysis' : `${human ? 'Your pieces' : 'The engine'} · ${color === 'w' ? 'White' : 'Black'}`;
        const avatar = $(`${location}-player`).querySelector('.avatar');
        avatar.className = `avatar ${human || mode === 'analysis' ? 'human-avatar' : 'engine-avatar'}`;
        avatar.replaceChildren();
        if (human || mode === 'analysis') avatar.textContent = human ? 'Y' : color.toUpperCase();
        else {
            const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
            svg.setAttribute('class', 'icon');
            const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
            use.setAttribute('href', '#i-rook');
            svg.append(use);
            avatar.append(svg);
        }
        $(`${location}-turn`).hidden = game.turn() !== color || game.isGameOver() || Boolean(clock && mode === 'play') || Boolean(timeout);
    }
    renderClocks();
}

function renderClocks() {
    const remaining = clock?.read();
    for (const [location, side] of [['top', orientation === 'w' ? 'b' : 'w'], ['bottom', orientation]]) {
        const element = $(`${location}-clock`);
        element.hidden = !clock || mode !== 'play';
        if (!remaining) continue;
        element.textContent = formatClock(remaining[side]);
        element.dataset.side = side;
        element.setAttribute('aria-label', `${side === 'w' ? 'White' : 'Black'} time remaining: ${element.textContent}`);
        element.classList.toggle('running', clock.running === side);
        element.classList.toggle('low', remaining[side] < 10000);
    }
}

function pauseClock() {
    clock?.pause();
    if (clock && cursor === history.length) clockHistory[cursor] = clock.read();
}

function checkFlag() {
    if (!clock || mode !== 'play' || timeout) return Boolean(timeout);
    const side = clock.expired || clock.running;
    if (!side) return false;
    if (clock.read()[side] > 0) return false;
    clock.pause();
    const opponent = side === 'w' ? 'b' : 'w';
    const pieces = game.board().flat().filter(piece => piece?.color === opponent && piece.type !== 'k');
    timeout = {side, draw: pieces.length === 0 || game.isInsufficientMaterial()};
    ++revision;
    engine.stop();
    busy = false;
    selected = null;
    legal = [];
    promotion = null;
    if ($('promotion-dialog').open) $('promotion-dialog').close('cancel');
    $('search-status').textContent = 'Game over';
    renderBoard();
    renderStatus();
    return true;
}

function syncClock() {
    if (!clock) return;
    if (checkFlag()) return;
    const running = mode === 'play' && ready && !failed && !game.isGameOver() && cursor === history.length && !playPaused && !clearingHash;
    if (running) { clock.start(game.turn()); checkFlag(); }
    else pauseClock();
    renderClocks();
}

function resetClock() {
    const control = $('time-control').value;
    if (control === 'untimed') clock = null;
    else {
        const [base, increment] = control === 'custom'
            ? [customTime.base, customTime.increment]
            : control.split('+').map(Number);
        clock = new GameClock(base * 1000, increment * 1000);
    }
    timeout = null;
    clockHistory = Array.from({length: history.length + 1}, () => clock?.read() || null);
}

function renderTimeSettings() {
    $('time-control').parentElement.hidden = mode !== 'play';
    $('think-time-field').hidden = mode !== 'play' || $('time-control').value !== 'untimed';
    $('custom-time').hidden = mode !== 'play' || $('time-control').value !== 'custom';
}

function goCommand() {
    if (mode === 'analysis') return 'go infinite';
    if (!clock) return `go movetime ${$('think-time').value}`;
    const remaining = clock.read();
    return `go wtime ${Math.max(1, Math.floor(remaining.w))} btime ${Math.max(1, Math.floor(remaining.b))} winc ${clock.increment} binc ${clock.increment}`;
}

function renderHistory() {
    const rows = new Map();
    history.forEach((move, index) => {
        const number = Number(move.before.split(' ')[5]);
        if (!rows.has(number)) {
            const row = document.createElement('div');
            row.className = 'move-row';
            const label = document.createElement('span');
            label.className = 'move-number';
            label.textContent = `${number}.`;
            row.append(label, document.createElement('span'), document.createElement('span'));
            rows.set(number, row);
        }
        const button = document.createElement('button');
        button.className = `move-entry${cursor === index + 1 ? ' current' : ''}`;
        button.textContent = move.san;
        button.dataset.ply = index + 1;
        button.setAttribute('aria-label', `Go to ${number}${move.color === 'w' ? '.' : '...'} ${move.san}`);
        rows.get(number).children[move.color === 'w' ? 1 : 2].replaceWith(button);
    });
    if (history.length) $('moves').replaceChildren(...rows.values());
    else {
        const empty = document.createElement('p');
        empty.className = 'empty-moves';
        empty.textContent = 'No moves yet';
        $('moves').replaceChildren(empty);
    }
    $('move-count').textContent = `${history.length} ${history.length === 1 ? 'move' : 'moves'}`;
    $('history-position').textContent = cursor ? `Move ${history[cursor - 1].before.split(' ')[5]} · ${cursor} / ${history.length}` : 'Starting position';
    $('history-start').disabled = $('history-prev').disabled = cursor === 0;
    $('history-end').disabled = $('history-next').disabled = cursor === history.length;
    $('undo').disabled = cursor === 0;
    if (cursor === history.length) $('moves').scrollTop = $('moves').scrollHeight;
}

function renderStatus() {
    let status = `${game.turn() === 'w' ? 'White' : 'Black'} to move`;
    let hint = mode === 'analysis' ? 'Move either side to explore the position.' : 'Click or drag a piece to make your move.';
    if (mode === 'play' && timeout) {
        status = timeout.draw ? 'Draw · time expired' : `${timeout.side === 'w' ? 'Black' : 'White'} wins on time`;
        hint = timeout.draw ? 'The opponent has insufficient mating material.' : `${timeout.side === 'w' ? 'White' : 'Black'} ran out of time.`;
    } else if (game.isCheckmate()) {
        status = `${game.turn() === 'w' ? 'Black' : 'White'} wins by checkmate`;
        hint = 'Game over.';
    } else if (game.isDraw()) {
        status = game.isStalemate() ? 'Draw by stalemate' : game.isThreefoldRepetition() ? 'Draw by repetition' : game.isInsufficientMaterial() ? 'Draw · insufficient material' : 'Draw · fifty-move rule';
        hint = 'Game over.';
    } else if (cursor !== history.length && mode === 'play') {
        status = 'Reviewing the game';
        hint = 'Return to the latest position to keep playing.';
    } else if (busy && mode === 'play') {
        status = 'Heimdall is thinking';
        hint = 'Looking for a good reply…';
    } else if (mode === 'play' && game.turn() !== player) {
        status = 'Heimdall to move';
        hint = playPaused ? 'Press play in Engine insight to resume.' : 'The engine will reply when it is ready.';
    } else if (game.isCheck()) {
        status += ' · check';
    }
    $('game-status').textContent = status;
    $('game-hint').textContent = hint;
    $('search-dot').classList.toggle('busy', busy);
    $('engine-toggle-icon').setAttribute('href', busy ? '#i-stop' : '#i-play');
    $('engine-toggle').setAttribute('aria-label', busy ? 'Stop engine' : mode === 'play' ? 'Resume engine' : 'Start analysis');
    $('engine-toggle').title = $('engine-toggle').getAttribute('aria-label');
    $('engine-toggle').disabled = !ready || failed || clearingHash || game.isGameOver() || (mode === 'play' && (timeout || game.turn() === player || cursor !== history.length));
    $('hash').disabled = !ready || failed;
    $('clear-hash').disabled = !ready || failed || clearingHash;
    renderPlayers();
}

function clearEvaluation() {
    bestMove = null;
    $('score').textContent = '—';
    $('score-description').textContent = 'Waiting for a position';
    $('depth').textContent = $('nodes').textContent = $('nps').textContent = '—';
    $('pv').textContent = mode === 'play' ? "Play a move to see the engine's best line." : 'The best continuation will appear here.';
    $('eval-white').style.height = '50%';
    $('eval-label').textContent = '0.0';
    $('eval-bar').setAttribute('aria-label', 'Position evaluation: unavailable');
    renderArrow();
}

function engineOptions() {
    return {threads: Number($('threads').value), hash: hashSize};
}

function scheduleSearch() {
    syncClock();
    const shouldSearch = !game.isGameOver() && (mode === 'analysis' ? analysisEnabled : !timeout && !playPaused && !clearingHash && game.turn() !== player && cursor === history.length);
    if (!ready || failed || !shouldSearch) {
        engine.stop();
        busy = false;
        $('search-status').textContent = failed ? 'Engine unavailable · reload to retry' : !ready ? 'Engine is loading…' : game.isGameOver() || (mode === 'play' && timeout) ? 'Game over' : 'Ready when you are';
        renderStatus();
        return;
    }
    busy = true;
    $('search-status').textContent = mode === 'analysis' ? 'Analyzing on your device…' : 'Finding a reply…';
    const context = {fen: game.fen(), turn: game.turn(), revision, mode};
    engine.search({position: positionCommand(), go: goCommand, ...engineOptions(), context, newGame});
    newGame = false;
    renderStatus();
}

function positionChanged({keepEvaluation = false} = {}) {
    ++revision;
    selected = null;
    legal = [];
    promotion = null;
    if ($('promotion-dialog').open) $('promotion-dialog').close('cancel');
    if (!keepEvaluation) clearEvaluation();
    renderBoard();
    renderHistory();
    scheduleSearch();
}

function applyMove(move, byEngine = false) {
    if (mode === 'play' && checkFlag()) return;
    if (clock && mode === 'play' && !clock.completeMove(game.turn())) {
        // A move delivered on or after flag fall must not receive increment.
        checkFlag();
        return;
    }
    history = history.slice(0, cursor);
    const played = game.move({from: move.from, to: move.to, promotion: move.promotion});
    history.push(played);
    cursor = history.length;
    clockHistory = clockHistory.slice(0, cursor);
    clockHistory.push(clock?.read() || null);
    positionChanged({keepEvaluation: byEngine});
}

function selectSquare(square) {
    if (!canMove()) return;
    const choices = legal.filter(move => move.to === square);
    if (selected && choices.length) {
        if (choices[0].promotion) choosePromotion(choices);
        else applyMove(choices[0]);
        return;
    }
    const piece = game.get(square);
    selected = selected === square ? null : piece?.color === game.turn() ? square : null;
    legal = selected ? game.moves({square: selected, verbose: true}) : [];
    renderBoard();
    if (selected) $('board').querySelector(`[data-square="${selected}"]`).focus({preventScroll: true});
}

function choosePromotion(choices) {
    promotion = choices;
    $('promotion-choices').replaceChildren(...choices.map(move => {
        const button = document.createElement('button');
        button.type = 'submit';
        button.value = move.promotion;
        button.setAttribute('aria-label', `Promote to ${names[move.promotion]}`);
        const image = document.createElement('img');
        image.src = pieceUrl({type: move.promotion, color: game.turn()});
        image.alt = names[move.promotion];
        button.append(image);
        return button;
    }));
    $('promotion-dialog').showModal();
}

function navigate(ply) {
    pauseClock();
    cursor = Math.max(0, Math.min(history.length, ply));
    game = new Chess(rootFen);
    for (const move of history.slice(0, cursor)) game.move({from: move.from, to: move.to, promotion: move.promotion});
    if (clock && clockHistory[cursor]) clock.restore(clockHistory[cursor]);
    timeout = null;
    positionChanged();
}

function resetGame() {
    game = new Chess();
    rootFen = DEFAULT_POSITION;
    history = [];
    cursor = 0;
    playPaused = false;
    newGame = true;
    resetClock();
    positionChanged();
}

function changeMode(next) {
    pauseClock();
    mode = next;
    $('mode-play').classList.toggle('active', mode === 'play');
    $('mode-analysis').classList.toggle('active', mode === 'analysis');
    $('mode-play').setAttribute('aria-pressed', String(mode === 'play'));
    $('mode-analysis').setAttribute('aria-pressed', String(mode === 'analysis'));
    $('mode-label').textContent = mode === 'play' ? 'PLAY HEIMDALL' : 'EXPLORE THE BOARD';
    // Keep the thread control available in either mode.
    $('play-settings').querySelector('.field-label').hidden = mode !== 'play';
    $('play-settings').querySelector('.side-choice').hidden = mode !== 'play';
    renderTimeSettings();
    if (mode === 'analysis') analysisEnabled = true;
    playPaused = false;
    positionChanged();
}

function toast(message) {
    clearTimeout(toastTimer);
    $('toast').textContent = message;
    $('toast').hidden = false;
    toastTimer = setTimeout(() => { $('toast').hidden = true; }, 2500);
}

function loadPosition() {
    const text = $('position-input').value.trim();
    try {
        if (!text) throw new Error('Paste a FEN position or a PGN game first.');
        const board = new Chess();
        if (text === 'startpos') board.reset();
        else if (text.includes('/') && !text.startsWith('[')) board.load(text);
        else board.loadPgn(text);
        const moves = board.history({verbose: true});
        const start = moves.length ? moves[0].before : board.fen();
        // Reject impossible setups before handing them to the native parser.
        const startBoard = new Chess(start);
        const other = startBoard.turn() === 'w' ? 'b' : 'w';
        const otherKing = startBoard.findPiece({type: 'k', color: other})[0];
        if (startBoard.isAttacked(otherKing, startBoard.turn())) throw new Error('The side that just moved cannot leave its king in check.');
        for (const color of ['w', 'b']) {
            const rank = color === 'w' ? '1' : '8';
            const rights = startBoard.getCastlingRights(color);
            for (const [side, file] of [['k', 'h'], ['q', 'a']]) {
                if (!rights[side]) continue;
                const king = startBoard.get(`e${rank}`);
                const rook = startBoard.get(`${file}${rank}`);
                if (king?.type !== 'k' || king.color !== color || rook?.type !== 'r' || rook.color !== color) {
                    throw new Error('Castling rights need the king and rook on their starting squares.');
                }
            }
        }
        rootFen = start;
        history = moves;
        cursor = moves.length;
        game = board;
        resetClock();
        newGame = true;
        $('position-error').textContent = '';
        changeMode('analysis');
    } catch (error) {
        $('position-error').textContent = error.message;
    }
}

const engine = new BrowserEngine({
    ready(maxThreads, hashRange) {
        ready = true;
        $('connection').classList.add('ready');
        $('connection-text').textContent = 'Engine online';
        const deviceThreads = Math.max(1, Math.floor(navigator.hardwareConcurrency || 1));
        const availableThreads = Math.min(maxThreads, deviceThreads);
        $('threads').replaceChildren(...Array.from({length: availableThreads}, (_, i) => new Option(String(i + 1), String(i + 1))));
        $('threads').title = `${deviceThreads} logical CPUs reported by the browser; engine limit ${maxThreads}`;
        $('hash').min = String(hashRange.min);
        $('hash').max = String(hashRange.max);
        hashSize = hashRange.default;
        $('hash').value = String(hashSize);
        scheduleSearch();
    },
    error(message) {
        failed = true;
        busy = false;
        pauseClock();
        $('connection').classList.remove('ready');
        $('connection').classList.add('error');
        $('connection-text').textContent = 'Engine unavailable';
        $('search-status').textContent = 'Engine unavailable · reload to retry';
        $('pv').textContent = message;
        renderStatus();
    },
    info(fields, context) {
        if (context.revision !== revision) return;
        for (const key of ['depth', 'nodes', 'nps']) {
            if (fields[key] !== undefined) $(key).textContent = key === 'depth' ? fields[key] : compact.format(fields[key]);
        }
        if (fields.score) {
            const score = fields.score.value * (context.turn === 'w' ? 1 : -1);
            const mate = fields.score.type === 'mate';
            $('score').textContent = mate ? `${score < 0 ? '−' : ''}M${Math.abs(score)}` : `${score > 0 ? '+' : ''}${(score / 100).toFixed(2)}`;
            const favored = score > 0 ? 'White' : 'Black';
            const description = mate ? `${favored} has mate in ${Math.abs(score)}` : Math.abs(score) < 25 ? 'An even position' : `${favored} has the edge`;
            $('score-description').textContent = description;
            const fraction = mate ? (score >= 0 ? 98 : 2) : Math.max(2, Math.min(98, 50 + 45 * Math.tanh(score / 400)));
            $('eval-white').style.height = `${fraction}%`;
            $('eval-label').textContent = mate ? `M${Math.abs(score)}` : (Math.abs(score) / 100).toFixed(1);
            $('eval-bar').setAttribute('aria-label', `Evaluation from White's perspective: ${$('score').textContent}. ${description}.`);
        }
        if (fields.pv) {
            const board = new Chess(context.fen);
            const san = [];
            bestMove = null;
            for (const uci of fields.pv.slice(0, 10)) {
                const move = decodeMove(board, uci);
                if (!move) break;
                if (!bestMove) bestMove = move;
                const number = board.fen().split(' ')[5];
                if (board.turn() === 'w') san.push(`${number}.`);
                else if (san.length === 0) san.push(`${number}…`);
                san.push(move.san);
                board.move({from: move.from, to: move.to, promotion: move.promotion});
            }
            $('pv').textContent = san.join(' ') || 'Looking for a continuation…';
            renderArrow();
        }
    },
    complete(uci, context) {
        if (context.revision !== revision) return;
        busy = false;
        $('search-status').textContent = 'Search complete';
        if (context.mode === 'play') {
            const move = decodeMove(game, uci);
            if (move) applyMove(move, true);
            else if (!game.isGameOver()) {
                playPaused = true;
                $('search-status').textContent = 'Unable to apply engine move';
                toast(`Unexpected engine move: ${uci}`);
            }
        }
        renderStatus();
    },
});

$('board').addEventListener('click', event => {
    if (suppressClick) { suppressClick = false; return; }
    const square = event.target.closest('[data-square]');
    if (square) selectSquare(square.dataset.square);
});
$('board').addEventListener('pointerdown', event => {
    if (event.button !== 0 || !canMove()) return;
    const square = event.target.closest('[data-square]');
    if (!square) return;
    const piece = game.get(square.dataset.square);
    if (piece?.color !== game.turn()) return;
    drag = {from: square.dataset.square, x: event.clientX, y: event.clientY, size: square.offsetWidth, piece, image: null};
});
window.addEventListener('pointermove', event => {
    if (!drag) return;
    if (!drag.image && Math.hypot(event.clientX - drag.x, event.clientY - drag.y) > 7) {
        selected = drag.from;
        legal = game.moves({square: selected, verbose: true});
        renderBoard();
        drag.image = document.createElement('img');
        drag.image.className = 'drag-piece';
        drag.image.src = pieceUrl(drag.piece);
        drag.image.style.width = drag.image.style.height = `${drag.size}px`;
        document.body.append(drag.image);
    }
    if (drag.image) {
        drag.image.style.left = `${event.clientX - drag.size / 2}px`;
        drag.image.style.top = `${event.clientY - drag.size / 2}px`;
    }
});
window.addEventListener('pointerup', event => {
    if (!drag) return;
    if (drag.image) {
        drag.image.remove();
        const square = document.elementFromPoint(event.clientX, event.clientY)?.closest('[data-square]');
        if (square && square.dataset.square !== drag.from) selectSquare(square.dataset.square);
        suppressClick = true;
        // A drop outside the board produces no click to consume.
        setTimeout(() => { suppressClick = false; }, 0);
    }
    drag = null;
});
window.addEventListener('pointercancel', () => { drag?.image?.remove(); drag = null; });
$('promotion-dialog').addEventListener('close', () => {
    const move = promotion?.find(choice => choice.promotion === $('promotion-dialog').returnValue);
    promotion = null;
    if (move) applyMove(move);
});
$('mode-play').addEventListener('click', () => changeMode('play'));
$('mode-analysis').addEventListener('click', () => changeMode('analysis'));
for (const [id, color] of [['side-white', 'w'], ['side-black', 'b']]) {
    $(id).addEventListener('click', () => {
        if (player === color) return;
        player = orientation = color;
        for (const [button, side] of [['side-white', 'w'], ['side-black', 'b']]) {
            $(button).classList.toggle('selected', side === player);
            $(button).setAttribute('aria-pressed', String(side === player));
        }
        resetGame();
    });
}
$('new-game').addEventListener('click', resetGame);
$('flip').addEventListener('click', () => { orientation = orientation === 'w' ? 'b' : 'w'; renderBoard(); renderPlayers(); });
$('undo').addEventListener('click', () => {
    let target = cursor - 1;
    if (mode === 'play' && target > 0 && history[target].color !== player) --target;
    history = history.slice(0, Math.max(0, target));
    playPaused = false;
    navigate(history.length);
});
$('moves').addEventListener('click', event => { const button = event.target.closest('[data-ply]'); if (button) navigate(Number(button.dataset.ply)); });
$('history-start').addEventListener('click', () => navigate(0));
$('history-prev').addEventListener('click', () => navigate(cursor - 1));
$('history-next').addEventListener('click', () => navigate(cursor + 1));
$('history-end').addEventListener('click', () => navigate(history.length));
function changeEngineOptions() {
    if (busy) scheduleSearch();
    else engine.configure(engineOptions());
}
$('threads').addEventListener('change', changeEngineOptions);
$('hash').addEventListener('change', () => {
    if (!$('hash').reportValidity()) {
        $('hash').value = String(hashSize);
        return;
    }
    hashSize = Number($('hash').value);
    changeEngineOptions();
});
$('clear-hash').addEventListener('click', async () => {
    clearingHash = true;
    busy = false;
    pauseClock();
    $('search-status').textContent = 'Clearing hash…';
    renderStatus();
    await engine.clearHash();
    clearingHash = false;
    if (!failed) {
        toast('Hash cleared');
        scheduleSearch();
    }
    renderStatus();
});
$('think-time').addEventListener('change', () => { if (busy) scheduleSearch(); });
$('time-control').addEventListener('change', () => { renderTimeSettings(); resetGame(); });
$('apply-time').addEventListener('click', () => {
    if ($('base-minutes').reportValidity() && $('increment-seconds').reportValidity()) {
        customTime = {base: Number($('base-minutes').value) * 60, increment: Number($('increment-seconds').value)};
        resetGame();
    }
});
$('engine-toggle').addEventListener('click', () => {
    if (mode === 'analysis') analysisEnabled = !busy;
    else playPaused = busy;
    scheduleSearch();
});
$('load-position').addEventListener('click', loadPosition);
$('copy-fen').addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(game.fen()); toast('Position copied'); }
    catch {
        $('position-panel').open = true;
        $('position-input').value = game.fen();
        $('position-input').focus();
        $('position-input').select();
        toast('Select and copy the position');
    }
});
$('download-pgn').addEventListener('click', () => {
    const full = new Chess(rootFen);
    for (const move of history) full.move({from: move.from, to: move.to, promotion: move.promotion});
    full.setHeader('Event', 'Wasmdall browser game');
    full.setHeader('White', mode === 'play' ? (player === 'w' ? 'Player' : 'Heimdall') : 'White');
    full.setHeader('Black', mode === 'play' ? (player === 'b' ? 'Player' : 'Heimdall') : 'Black');
    const result = mode === 'play' && timeout ? (timeout.draw ? '1/2-1/2' : timeout.side === 'w' ? '0-1' : '1-0') : full.isCheckmate() ? (full.turn() === 'w' ? '0-1' : '1-0') : full.isDraw() ? '1/2-1/2' : '*';
    if (clock) full.setHeader('TimeControl', `${clock.base / 1000}+${clock.increment / 1000}`);
    full.setHeader('Result', result);
    const url = URL.createObjectURL(new Blob([full.pgn()], {type: 'application/x-chess-pgn'}));
    const link = document.createElement('a');
    link.href = url;
    link.download = 'wasmdall.pgn';
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
});
document.addEventListener('keydown', event => {
    if (event.target.closest('input, textarea, select, dialog') || event.ctrlKey || event.metaKey || event.altKey) return;
    if (event.key === 'ArrowLeft') { event.preventDefault(); navigate(cursor - 1); }
    if (event.key === 'ArrowRight') { event.preventDefault(); navigate(cursor + 1); }
    if (event.key.toLowerCase() === 'f') $('flip').click();
    if (event.key === 'Escape') { selected = null; legal = []; renderBoard(); }
});
window.addEventListener('pagehide', () => engine.dispose());
window.addEventListener('pageshow', event => { if (event.persisted) window.location.reload(); });
renderBoard();
renderHistory();
renderStatus();
setInterval(() => { checkFlag(); renderClocks(); }, 100);
