// Starts the real server on a random port and drives it over HTTP and
// Socket.IO, the same way the browser client in app/js/controllers.js does.

var test = require('node:test');
var assert = require('node:assert/strict');
var ioClient = require('socket.io-client');

var hatjitsu = require('../../server.js');

var describe = test.describe;
var it = test.it;
var before = test.before;
var after = test.after;
var afterEach = test.afterEach;

var ROOM_GONE = { error: 'Sorry, this room no longer exists ...' };

var baseUrl;
var clients = [];

function connect() {
  var socket = ioClient(baseUrl, { transports: ['websocket'], forceNew: true, reconnection: false });
  clients.push(socket);
  return new Promise(function(resolve, reject) {
    socket.once('connect', function() { resolve(socket); });
    socket.once('connect_error', reject);
  });
}

function nextEvent(socket, event) {
  return new Promise(function(resolve, reject) {
    var timer = setTimeout(function() {
      reject(new Error('Timed out waiting for "' + event + '"'));
    }, 2000);
    socket.once(event, function() {
      clearTimeout(timer);
      resolve();
    });
  });
}

function emit(socket, event, data) {
  return socket.timeout(2000).emitWithAck(event, data);
}

// Creates a room and joins it with a fresh client, like opening the app and clicking "create room".
async function createAndJoin(sessionId) {
  var socket = await connect();
  var roomUrl = await emit(socket, 'create room', {});
  var info = await emit(socket, 'join room', { roomUrl: roomUrl, sessionId: sessionId });
  return { socket: socket, roomUrl: roomUrl, info: info };
}

async function join(roomUrl, sessionId) {
  var socket = await connect();
  var info = await emit(socket, 'join room', { roomUrl: roomUrl, sessionId: sessionId });
  return { socket: socket, info: info };
}

function connectionFor(info, sessionId) {
  return info.connections.find(function(c) { return c.sessionId === sessionId; });
}

before(function() {
  return new Promise(function(resolve) {
    hatjitsu.server.listen(0, '127.0.0.1', function() {
      baseUrl = 'http://127.0.0.1:' + hatjitsu.server.address().port;
      resolve();
    });
  });
});

afterEach(function() {
  clients.forEach(function(socket) { socket.disconnect(); });
  clients = [];
});

after(function() {
  hatjitsu.io.close();
  return new Promise(function(resolve) { hatjitsu.server.close(resolve); });
});

describe('HTTP routes', function() {
  it('GET / renders the app with cache-busted scripts', async function() {
    var res = await fetch(baseUrl + '/');
    assert.equal(res.status, 200);
    var html = await res.text();
    assert.match(html, /ng-app="pokerApp"/);
    assert.match(html, /<script src="\/js\/app\.js\?v=\d+" type="text\/javascript"><\/script>/);
  });

  it('serves static assets', async function() {
    for (var asset of ['/js/app.js', '/js/controllers.js', '/css/app.css', '/partials/room.html', '/lib/angular/angular.min.js']) {
      var res = await fetch(baseUrl + asset);
      assert.equal(res.status, 200, asset);
    }
  });

  it('GET /styleguide renders', async function() {
    var res = await fetch(baseUrl + '/styleguide');
    assert.equal(res.status, 200);
  });

  it('GET /:id renders the app for an existing room', async function() {
    var room = await createAndJoin('http-session');
    var res = await fetch(baseUrl + '/' + room.roomUrl);
    assert.equal(res.status, 200);
    assert.match(await res.text(), /ng-app="pokerApp"/);
  });

  it('GET /:id redirects to / for an unknown room', async function() {
    var res = await fetch(baseUrl + '/00000x', { redirect: 'manual' });
    assert.equal(res.status, 302);
    assert.equal(res.headers.get('location'), '/');
  });

  it('GET /debug_state reports stats and rooms', async function() {
    var room = await createAndJoin('debug-session');
    var res = await fetch(baseUrl + '/debug_state');
    assert.equal(res.status, 200);
    var state = await res.json();
    assert.equal(typeof state.stats.connectionCount, 'number');
    assert.ok(state.stats.currentSocketCount >= 1);
    assert.ok(state.rooms.some(function(r) { return r.roomUrl === room.roomUrl; }));
  });
});

describe('Socket.IO room flow', function() {
  it('creates a room and makes the first visitor admin', async function() {
    var room = await createAndJoin('alice');
    assert.match(room.roomUrl, /^\d{5}$/);
    assert.equal(room.info.roomUrl, room.roomUrl);
    assert.equal(room.info.createAdmin, true);
    assert.equal(room.info.cardPack, 'goat');
    assert.deepEqual(room.info.connections, [
      { sessionId: 'alice', socketId: room.socket.id, vote: null, voter: true, voterName: null }
    ]);
  });

  it('notifies existing members when someone joins; later visitors are not admin', async function() {
    var alice = await createAndJoin('alice');
    var joined = nextEvent(alice.socket, 'room joined');

    var bob = await join(alice.roomUrl, 'bob');

    await joined;
    assert.equal(bob.info.createAdmin, false);
    assert.equal(bob.info.connections.length, 2);
  });

  it('returns an error when joining or querying an unknown room', async function() {
    var socket = await connect();
    assert.deepEqual(await emit(socket, 'join room', { roomUrl: 'nope', sessionId: 'x' }), ROOM_GONE);
    assert.deepEqual(await emit(socket, 'room info', { roomUrl: 'nope' }), ROOM_GONE);
  });

  it('runs a full voting round: vote, reveal, sort, reset', async function() {
    var alice = await createAndJoin('alice');
    var bob = await join(alice.roomUrl, 'bob');
    var roomUrl = alice.roomUrl;

    // Voting notifies the other members, not the voter
    var bobSeesVote = nextEvent(bob.socket, 'voted');
    assert.deepEqual(await emit(alice.socket, 'vote', { roomUrl: roomUrl, sessionId: 'alice', vote: '5' }), {});
    await bobSeesVote;

    var aliceSeesVote = nextEvent(alice.socket, 'voted');
    await emit(bob.socket, 'vote', { roomUrl: roomUrl, sessionId: 'bob', vote: '8' });
    await aliceSeesVote;

    var info = await emit(alice.socket, 'room info', { roomUrl: roomUrl });
    assert.equal(connectionFor(info, 'alice').vote, '5');
    assert.equal(connectionFor(info, 'bob').vote, '8');

    // Reveal goes to everyone, including the sender
    var revealA = nextEvent(alice.socket, 'reveal');
    var revealB = nextEvent(bob.socket, 'reveal');
    await emit(alice.socket, 'force reveal', { roomUrl: roomUrl });
    await Promise.all([revealA, revealB]);
    info = await emit(bob.socket, 'room info', { roomUrl: roomUrl });
    assert.equal(info.forcedReveal, true);

    var sorted = nextEvent(bob.socket, 'reveal');
    await emit(alice.socket, 'sort votes', { roomUrl: roomUrl });
    await sorted;
    info = await emit(bob.socket, 'room info', { roomUrl: roomUrl });
    assert.equal(info.alreadySorted, true);

    var resetA = nextEvent(alice.socket, 'vote reset');
    var resetB = nextEvent(bob.socket, 'vote reset');
    await emit(bob.socket, 'reset vote', { roomUrl: roomUrl });
    await Promise.all([resetA, resetB]);
    info = await emit(alice.socket, 'room info', { roomUrl: roomUrl });
    assert.equal(info.forcedReveal, false);
    assert.equal(info.alreadySorted, false);
    assert.ok(info.connections.every(function(c) { return c.vote === null; }));
  });

  it('withdraws a vote', async function() {
    var alice = await createAndJoin('alice');
    var bob = await join(alice.roomUrl, 'bob');

    await emit(alice.socket, 'vote', { roomUrl: alice.roomUrl, sessionId: 'alice', vote: '3' });
    var bobSeesUnvote = nextEvent(bob.socket, 'unvoted');
    assert.deepEqual(await emit(alice.socket, 'unvote', { roomUrl: alice.roomUrl, sessionId: 'alice' }), {});
    await bobSeesUnvote;

    var info = await emit(bob.socket, 'room info', { roomUrl: alice.roomUrl });
    assert.equal(connectionFor(info, 'alice').vote, null);
  });

  it('changes the card pack for everyone', async function() {
    var alice = await createAndJoin('alice');
    var bob = await join(alice.roomUrl, 'bob');

    var bobSeesChange = nextEvent(bob.socket, 'card pack set');
    alice.socket.emit('set card pack', { roomUrl: alice.roomUrl, cardPack: 'fibonacci' });
    await bobSeesChange;

    var info = await emit(bob.socket, 'room info', { roomUrl: alice.roomUrl });
    assert.equal(info.cardPack, 'fibonacci');
  });

  it('switches a member to observer and renames them', async function() {
    var alice = await createAndJoin('alice');
    var bob = await join(alice.roomUrl, 'bob');
    await emit(bob.socket, 'vote', { roomUrl: alice.roomUrl, sessionId: 'bob', vote: '13' });

    var statusChanged = nextEvent(alice.socket, 'voter status changed');
    await emit(bob.socket, 'toggle voter', { roomUrl: alice.roomUrl, sessionId: 'bob', voter: false });
    await statusChanged;

    statusChanged = nextEvent(alice.socket, 'voter status changed');
    await emit(bob.socket, 'change voter name', { roomUrl: alice.roomUrl, sessionId: 'bob', voterName: 'Bartholomew' });
    await statusChanged;

    var info = await emit(alice.socket, 'room info', { roomUrl: alice.roomUrl });
    var bobInfo = connectionFor(info, 'bob');
    assert.equal(bobInfo.voter, false);
    assert.equal(bobInfo.vote, null);
    assert.equal(bobInfo.voterName, 'Barthol');
  });

  it('returns an error for actions on an unknown room', async function() {
    var socket = await connect();
    var data = { roomUrl: 'nope', sessionId: 'x' };
    for (var event of ['vote', 'unvote', 'reset vote', 'force reveal', 'sort votes', 'toggle voter', 'change voter name']) {
      assert.deepEqual(await emit(socket, event, data), ROOM_GONE, event);
    }
  });

  it('removes a member who disconnects and keeps their vote when they reconnect', async function() {
    var alice = await createAndJoin('alice');
    var bob = await join(alice.roomUrl, 'bob');
    await emit(bob.socket, 'vote', { roomUrl: alice.roomUrl, sessionId: 'bob', vote: '2' });

    var left = nextEvent(alice.socket, 'room left');
    bob.socket.disconnect();
    await left;

    var info = await emit(alice.socket, 'room info', { roomUrl: alice.roomUrl });
    assert.equal(connectionFor(info, 'bob'), undefined);

    var bobAgain = await join(alice.roomUrl, 'bob');
    assert.equal(connectionFor(bobAgain.info, 'bob').vote, '2');
  });
});
