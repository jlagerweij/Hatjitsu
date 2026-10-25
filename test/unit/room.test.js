var test = require('node:test');
var assert = require('node:assert/strict');

var Room = require('../../lib/room.js').Room;
var fakes = require('../helpers/fakes.js');

var describe = test.describe;
var it = test.it;
var beforeEach = test.beforeEach;

describe('Room', function() {
  var io, room;

  beforeEach(function() {
    io = fakes.fakeIo();
    room = new Room(io, '12345');
  });

  describe('a new room', function() {
    it('has sensible defaults', function() {
      var json = room.json();
      assert.equal(json.roomUrl, '12345');
      assert.equal(json.cardPack, 'goat');
      assert.equal(json.forcedReveal, false);
      assert.equal(json.alreadySorted, false);
      assert.equal(json.hasAdmin, false);
      assert.deepEqual(json.connections, []);
      assert.equal(typeof json.createdAt, 'string');
    });
  });

  describe('info', function() {
    it('grants admin to the first caller only', function() {
      var first = room.info();
      assert.equal(first.createAdmin, true);
      assert.equal(first.hasAdmin, true);

      var second = room.info();
      assert.equal(second.createAdmin, false);
      assert.equal(second.hasAdmin, true);
    });
  });

  describe('enter and leave', function() {
    it('adds a connection as a voter without a vote', function() {
      room.enter(fakes.fakeSocket('s1'), { sessionId: 'a' });
      assert.deepEqual(room.json().connections, [
        { sessionId: 'a', socketId: 's1', vote: null, voter: true, voterName: null }
      ]);
      assert.equal(room.getClientCount(), 1);
    });

    it('keeps the existing vote when a session reconnects with a new socket', function() {
      room.enter(fakes.fakeSocket('s1'), { sessionId: 'a' });
      room.recordVote(fakes.fakeSocket('s1'), { sessionId: 'a', vote: '5' });
      room.enter(fakes.fakeSocket('s2'), { sessionId: 'a' });

      var connections = room.json().connections;
      assert.equal(connections.length, 1);
      assert.equal(connections[0].socketId, 's2');
      assert.equal(connections[0].vote, '5');
    });

    it('hides a connection that left but remembers it', function() {
      var socket = fakes.fakeSocket('s1');
      room.enter(socket, { sessionId: 'a' });
      room.leave(socket);

      assert.equal(room.getClientCount(), 0);
      assert.deepEqual(room.json().connections, []);
      assert.ok(room.connections.a, 'session is kept so it can rejoin');
    });

    it('ignores leave for an unknown socket', function() {
      room.enter(fakes.fakeSocket('s1'), { sessionId: 'a' });
      room.leave(fakes.fakeSocket('other'));
      assert.equal(room.getClientCount(), 1);
    });
  });

  describe('voting', function() {
    var socket;

    beforeEach(function() {
      socket = fakes.fakeSocket('s1');
      room.enter(socket, { sessionId: 'a' });
    });

    it('records a vote and notifies the other clients', function() {
      room.recordVote(socket, { sessionId: 'a', vote: '8' });
      assert.equal(room.connections.a.vote, '8');
      assert.deepEqual(socket.broadcasted, [{ room: '12345', event: 'voted' }]);
    });

    it('removes a vote and notifies the other clients', function() {
      room.recordVote(socket, { sessionId: 'a', vote: '8' });
      room.destroyVote(socket, { sessionId: 'a' });
      assert.equal(room.connections.a.vote, null);
      assert.deepEqual(socket.broadcasted[1], { room: '12345', event: 'unvoted' });
    });

    it('ignores a vote from an unknown session but still broadcasts', function() {
      room.recordVote(socket, { sessionId: 'unknown', vote: '8' });
      assert.equal(room.connections.unknown, undefined);
      assert.equal(room.connections.a.vote, null);
    });

    it('reset clears all votes, reveal and sort state', function() {
      room.enter(fakes.fakeSocket('s2'), { sessionId: 'b' });
      room.recordVote(socket, { sessionId: 'a', vote: '3' });
      room.recordVote(socket, { sessionId: 'b', vote: '5' });
      room.forceReveal();
      room.sortVotes();

      room.resetVote();

      assert.equal(room.connections.a.vote, null);
      assert.equal(room.connections.b.vote, null);
      assert.equal(room.forcedReveal, false);
      assert.equal(room.alreadySorted, false);
      assert.deepEqual(io.emitted.at(-1), { room: '12345', event: 'vote reset' });
    });
  });

  describe('reveal and sort', function() {
    it('force reveal sets the flag, clears sorting and emits reveal', function() {
      room.alreadySorted = true;
      room.forceReveal();
      assert.equal(room.forcedReveal, true);
      assert.equal(room.alreadySorted, false);
      assert.deepEqual(io.emitted, [{ room: '12345', event: 'reveal' }]);
    });

    it('sort votes sets the flag and emits reveal', function() {
      room.sortVotes();
      assert.equal(room.alreadySorted, true);
      assert.deepEqual(io.emitted, [{ room: '12345', event: 'reveal' }]);
    });
  });

  describe('card pack', function() {
    it('changes the card pack and notifies everyone', function() {
      room.setCardPack({ cardPack: 'fibonacci' });
      assert.equal(room.json().cardPack, 'fibonacci');
      assert.deepEqual(io.emitted, [{ room: '12345', event: 'card pack set' }]);
    });
  });

  describe('voter settings', function() {
    beforeEach(function() {
      room.enter(fakes.fakeSocket('s1'), { sessionId: 'a' });
    });

    it('turning voter off clears the vote', function() {
      room.connections.a.vote = '13';
      room.toggleVoter({ sessionId: 'a', voter: false });
      assert.equal(room.connections.a.voter, false);
      assert.equal(room.connections.a.vote, null);
      assert.deepEqual(io.emitted, [{ room: '12345', event: 'voter status changed' }]);
    });

    it('turning voter on keeps the vote', function() {
      room.connections.a.vote = '13';
      room.toggleVoter({ sessionId: 'a', voter: true });
      assert.equal(room.connections.a.voter, true);
      assert.equal(room.connections.a.vote, '13');
    });

    it('truncates voter names to 7 characters', function() {
      room.changeVoterName({ sessionId: 'a', voterName: 'Bartholomew' });
      assert.equal(room.connections.a.voterName, 'Barthol');
      assert.deepEqual(io.emitted, [{ room: '12345', event: 'voter status changed' }]);
    });

    it('clears the voter name when empty', function() {
      room.changeVoterName({ sessionId: 'a', voterName: 'Ann' });
      room.changeVoterName({ sessionId: 'a', voterName: '' });
      assert.equal(room.connections.a.voterName, null);
    });
  });
});
