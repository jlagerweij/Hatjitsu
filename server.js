
/**
 * Module dependencies.
 */
var _ = require('underscore')._;

var env = process.env.NODE_ENV || 'development';

var fs = require('fs')
var http = require('http');

var express = require('express');
var bodyParser = require('body-parser');
var errorhandler = require('errorhandler')
var methodOverride = require('method-override');
var morgan = require('morgan')
var compression = require('compression')

var app = express();
var server = http.createServer(app)
var socketIO = require('socket.io');
var io = socketIO(server, {
  transports : ['websocket', 'htmlfile', 'xhr-polling', 'jsonp-polling']
});
var lobbyClass = require('./lib/lobby.js');
var config = require('./config.js')[env];
var path = require('path');

var lobby = new lobbyClass.Lobby(io);

var statsConnectionCount = 0;
var statsDisconnectCount = 0;
var statsSocketCount = 0;
var statsSocketMessagesReceived = 0;

// Configuration

// Asset version used for cache busting in script tags
var assetVersion = Date.now();

app.set('views', __dirname + '/app');
app.set('view engine', 'ejs');
app.set('view options', {
    layout: false
});
app.use(morgan('combined', { skip: function() { return env === 'test'; } }));
app.use(bodyParser.json());
app.use(methodOverride());

if (env === 'development' || env === 'test') {
  app.use(express.static(__dirname + '/app'));
  app.use(errorhandler());
}

if (env === 'production') {
  var oneDay = 86400000;
  // app.use(assetsManagerMiddleware);
  app.use(compression())
  app.use(express.static(__dirname + '/app'));
}

// Add the view helper that renders script tags for local assets
app.locals.CDN = function(assets) {
  return [].concat(assets).map(function(asset) {
    return '<script src="' + asset + '?v=' + assetVersion + '" type="text/javascript"></script>';
  }).join('\n');
};

app.get('/', function(req, res) {
  res.render('index.ejs');
});

app.get('/debug_state', function(req, res) {
  res.json({
    "stats": {
      "connectionCount": statsConnectionCount,
      "disconnectCount": statsDisconnectCount,
      "currentSocketCount": statsSocketCount,
      "socketMessagesReceived": statsSocketMessagesReceived
    },
    "rooms": _.map(lobby.rooms, function(room, key) { return room.json() } )
  });
});

app.get('/styleguide', function(req, res) {
  res.render('styleguide.ejs');
});

app.get('/:id', function(req, res) {
  if (req.params.id in lobby.rooms) {
    res.render('index.ejs');
  } else {
   res.redirect('/');  
  }
});


// Only start listening when run directly (node server.js), so tests can require this module
if (require.main === module) {
  var port = process.env.app_port || 5000; // Use the port that Heroku provides or default to 5000
  server.listen(port, '0.0.0.0', function() {
    console.log("Express server listening on 0.0.0.0:%d in %s mode", port, app.settings.env);
  });
}




/* EVENT LISTENERS */

io.on('connection', function (socket) {

  statsConnectionCount++;
  statsSocketCount++;

  // console.log("On connect", socket.id);

  socket.on('disconnect', function () {
    statsDisconnectCount++;
    statsSocketCount--;
    // console.log("On disconnect", socket.id);
    lobby.broadcastDisconnect(socket);
  });
  
  socket.on('create room', function (data, callback) {
    statsSocketMessagesReceived++;
    // console.log("on create room", socket.id, data);
    callback(lobby.createRoom());
  });

  socket.on('join room', function (data, callback) {
    statsSocketMessagesReceived++;
    // console.log("on join room " + data.roomUrl, socket.id, data);
    var room = lobby.joinRoom(socket, data);
    if(room.error) {
      callback( { error: room.error } );
    } else {
      callback(room.info());
    }
  });

  socket.on('room info', function (data, callback) {
    statsSocketMessagesReceived++;
    // console.log("on room info for " + data.roomUrl, socket.id, data);
    var room = lobby.getRoom(data.roomUrl);
    // room = { error: "there was an error" };
    if (room.error) {
      callback( { error: room.error } );
    } else {
      callback(room.info());
    }
  });

  socket.on('set card pack', function (data, cardPack) {
    statsSocketMessagesReceived++;
    // console.log("on set card pack " + data.cardPack + " for " + data.roomUrl, socket.id, data);
    var room = lobby.getRoom(data.roomUrl);
    // console.log("error=" + room.error);
    if (!room.error) {
      room.setCardPack(data);
    }
  });

  socket.on('vote', function (data, callback) {
    statsSocketMessagesReceived++;
    // console.log("on vote " + data.vote + " received for " + data.roomUrl, socket.id, data);
    var room = lobby.getRoom(data.roomUrl);
    if (room.error) {
      callback( { error: room.error });
    } else {
      room.recordVote(socket, data);
      callback( {} );
    }
  });

  socket.on('unvote', function (data, callback) {
    statsSocketMessagesReceived++;
    // console.log("omn unvote received for " + data.roomUrl, socket.id, data);
    var room = lobby.getRoom(data.roomUrl);
    if (room.error) {
      callback( { error: room.error });
    } else {
      room.destroyVote(socket, data);
      callback( {} );
    }
  });

  socket.on('reset vote', function (data, callback) {
    statsSocketMessagesReceived++;
    // console.log("on reset vote  received for " + data.roomUrl, socket.id, data);
    var room = lobby.getRoom(data.roomUrl);
    if (room.error) {
      callback( { error: room.error });
    } else {
      room.resetVote();
      callback( {} );
    }
  });

  socket.on('force reveal', function (data, callback) {
    statsSocketMessagesReceived++;
    var room = lobby.getRoom(data.roomUrl);
    if (room.error) {
      callback( { error: room.error });
    } else {
      room.forceReveal();
      callback( {} );
    }
  });

  socket.on('sort votes', function (data, callback) {
    statsSocketMessagesReceived++;
    var room = lobby.getRoom(data.roomUrl);
    if (room.error) {
      callback( { error: room.error });
    } else {
      room.sortVotes();
      callback( {} );
    }
  });

  socket.on('toggle voter', function (data, callback) {
    statsSocketMessagesReceived++;
    // console.log("on toggle voter for " + data.roomUrl, socket.id, data);
    var room = lobby.getRoom(data.roomUrl);
    if (room.error) {
      callback( { error: room.error });
    } else {
      room.toggleVoter(data);
      callback( {} );
    }
  });

  socket.on('change voter name', function (data, callback) {
    statsSocketMessagesReceived++;
    // console.log("on change voter name for " + data.roomUrl, socket.id, data);
    var room = lobby.getRoom(data.roomUrl);
    if (room.error) {
      callback( { error: room.error });
    } else {
      room.changeVoterName(data);
      callback( {} );
    }
  });

});

module.exports = { app: app, server: server, io: io, lobby: lobby };
