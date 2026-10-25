// Minimal stand-ins for socket.io objects that record emitted events.

function fakeIo() {
  var io = {
    emitted: [],
    sockets: {
      in: function(room) {
        return {
          emit: function(event) {
            io.emitted.push({ room: room, event: event });
          }
        };
      }
    }
  };
  return io;
}

function fakeSocket(id) {
  var socket = {
    id: id,
    rooms: [],
    broadcasted: [],
    join: function(room) {
      socket.rooms.push(room);
    },
    broadcast: {
      to: function(room) {
        return {
          emit: function(event) {
            socket.broadcasted.push({ room: room, event: event });
          }
        };
      }
    }
  };
  return socket;
}

module.exports = { fakeIo: fakeIo, fakeSocket: fakeSocket };
