var test = require('node:test');
var assert = require('node:assert/strict');

var Lobby = require('../../lib/lobby.js').Lobby;
var fakes = require('../helpers/fakes.js');

var describe = test.describe;
var it = test.it;
var beforeEach = test.beforeEach;

var ROOM_GONE = { error: 'Sorry, this room no longer exists ...' };

describe('Lobby', function() {
  var io, lobby;

  beforeEach(function() {
    io = fakes.fakeIo();
    lobby = new Lobby(io);
  });

  describe('createUniqueURL', function() {
    it('returns five digits', function() {
      for (var i = 0; i < 50; i++) {
        assert.match(lobby.createUniqueURL(), /^\d{5}$/);
      }
    });
  });

  describe('createRoom', function() {
    it('creates a room with a five digit url', function() {
      var roomUrl = lobby.createRoom();
      assert.match(roomUrl, /^\d{5}$/);
      assert.equal(lobby.rooms[roomUrl].roomUrl, roomUrl);
    });

    it('uses the given prefix', function() {
      var roomUrl = lobby.createRoom('team');
      assert.match(roomUrl, /^team\d{5}$/);
    });

    it('removes empty rooms and keeps occupied ones', function() {
      var empty = lobby.createRoom();
      var occupied = lobby.createRoom();
      lobby.joinRoom(fakes.fakeSocket('s1'), { roomUrl: occupied, sessionId: 'a' });

      var created = lobby.createRoom();

      assert.equal(empty in lobby.rooms, false);
      assert.equal(occupied in lobby.rooms, true);
      assert.equal(created in lobby.rooms, true);
    });
  });

  describe('getRoom', function() {
    it('returns an existing room', function() {
      var roomUrl = lobby.createRoom();
      assert.equal(lobby.getRoom(roomUrl), lobby.rooms[roomUrl]);
    });

    it('returns an error for an unknown room', function() {
      assert.deepEqual(lobby.getRoom('nope'), ROOM_GONE);
    });
  });

  describe('joinRoom', function() {
    it('enters the room, joins the socket channel and notifies others', function() {
      var roomUrl = lobby.createRoom();
      var socket = fakes.fakeSocket('s1');

      var room = lobby.joinRoom(socket, { roomUrl: roomUrl, sessionId: 'a' });

      assert.equal(room, lobby.rooms[roomUrl]);
      assert.equal(room.getClientCount(), 1);
      assert.deepEqual(socket.rooms, [roomUrl]);
      assert.deepEqual(socket.broadcasted, [{ room: roomUrl, event: 'room joined' }]);
    });

    it('does not enter without a session id', function() {
      var roomUrl = lobby.createRoom();
      var socket = fakes.fakeSocket('s1');

      var room = lobby.joinRoom(socket, { roomUrl: roomUrl });

      assert.equal(room.getClientCount(), 0);
      assert.deepEqual(socket.rooms, []);
    });

    it('returns an error for an unknown room', function() {
      assert.deepEqual(lobby.joinRoom(fakes.fakeSocket('s1'), { roomUrl: 'nope', sessionId: 'a' }), ROOM_GONE);
    });

    it('returns an error without a room url', function() {
      assert.deepEqual(lobby.joinRoom(fakes.fakeSocket('s1'), { sessionId: 'a' }), ROOM_GONE);
    });
  });

  describe('broadcastDisconnect', function() {
    it('marks the socket as left and tells every room', function() {
      var socket = fakes.fakeSocket('s1');
      var roomA = lobby.createRoom();
      lobby.joinRoom(socket, { roomUrl: roomA, sessionId: 'a' });
      var roomB = lobby.createRoom();
      lobby.joinRoom(fakes.fakeSocket('s2'), { roomUrl: roomB, sessionId: 'b' });

      lobby.broadcastDisconnect(socket);

      assert.equal(lobby.rooms[roomA].getClientCount(), 0);
      assert.equal(lobby.rooms[roomB].getClientCount(), 1);
      assert.deepEqual(io.emitted.map(function(e) { return e.event; }), ['room left', 'room left']);
    });
  });
});
